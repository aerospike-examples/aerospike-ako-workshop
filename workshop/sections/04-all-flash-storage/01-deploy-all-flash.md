# Lab 4.1 — Deploy an All-flash Cluster

| Field | Value |
|-------|-------|
| Lab ID | `4.1` |
| Section | All-flash Storage |
| Cluster | `${ALL_FLASH_CLUSTER_NAME}` (default `my-cluster-all-flash`) — **not** the main workshop cluster |
| Aerospike cluster | `aerocluster`, `${ALL_FLASH_AEROSPIKE_SIZE}` nodes (default 3) |
| AKO min version | `4.5.0` (`ALL_FLASH_AKO_VERSION`) |
| Aerospike baseline | none — this lab deploys it |
| Deploy path | A (kubectl) / B (Helm) — follows `DEPLOY_PATH` |
| Duration | ~25–35 min |
| Validation status | `draft` |
| Official docs | [AKO all-flash](https://aerospike.com/docs/kubernetes/manage/storage/all-flash) · [Primary index on flash](https://aerospike.com/docs/database/manage/namespace/primary-index) |

## Takeaway

An all-flash namespace moves the **primary index** from DRAM onto local NVMe, so index capacity is bought with disk rather than RAM — at the cost of a filesystem volume per index mount, kernel `vm.dirty_*` settings on every node, and a `partition-tree-sprigs` value you cannot change without a cold restart.

## Prerequisites

- Setup step **0.8** (the all-flash cluster) — `prepare-lab.sh 4.1` runs it for you if the cluster is missing
- `secrets/features.conf` present (same file as the main cluster)
- Capacity for `${ALL_FLASH_NODE_COUNT}`× `${ALL_FLASH_NODE_TYPE}`, plus one spare for Lab 4.2

This lab is **independent of Sections 1–3**. Nothing you do here touches `${CLUSTER_NAME}`.

## Why a separate cluster

| | Main cluster (`disk` labs) | All-flash cluster (Section 4) |
|---|---|---|
| Primary index | DRAM, sized by `indexes-memory-budget` (57 GiB pods) | Local NVMe, sized by `index-type.mounts-budget` (600 GiB/node) |
| Namespace storage | `storage-engine.type: device`, 1 block volume | `storage-engine.type: device`, 5 (EKS) or 16 (GKE) block volumes |
| Extra volumes | none | one Filesystem volume per index mount |
| Node kernel | defaults | `vm.dirty_*` + `vm.min_free_kbytes` set by a DaemonSet |
| Pod memory | 57 GiB | 64 GiB — index is on NVMe, not in DRAM |

AKO cannot add or remove the index volumes in place, and the `vm.dirty_*` settings apply to the whole kernel, not just Aerospike. Both reasons are why Section 4 gets its own cluster instead of mutating `aerocluster` on `${CLUSTER_NAME}`.

## Phase 0 — Prepare lab

```bash
./scripts/labs/prepare-lab.sh 4.1
```

This bootstraps the all-flash **Kubernetes** cluster when it is missing (setup step 0.8: AKO, secrets, NVMe slices — not Aerospike). If the cluster already exists it removes any leftover `aerocluster` and re-checks the NVMe slices, then leaves `kubectl` pointed at the all-flash cluster. Add `--skip-reset` to keep an existing cluster untouched.

## Starting state

```bash
./scripts/lib/kubecontext.sh all-flash
kubectl get nodes -L workshop.aerospike.com/storage
kubectl -n aerospike get aerospikecluster
```

**Expected:** `${ALL_FLASH_NODE_COUNT}` nodes labelled `storage=all-flash`; no `aerocluster` yet.

## Background

An Aerospike namespace normally keeps its whole primary index in DRAM — 64 bytes per record, which is what caps record count per node. With `index-type: flash`, the server instead memory-maps the index into files on mounted NVMe filesystems, so the ceiling becomes disk capacity. That trade only pays off for **large record counts with small records**; every index read that misses the page cache becomes a device read, so all-flash is slower per-operation than a DRAM index.

Two things make it work on Kubernetes:

1. **Two PV families per pod.** Data slices stay raw `Block` volumes on `local-ssd`. Index volumes are `Filesystem` PVCs on `local-ssd-fs`; [nvme-bootstrap](../../scripts/setup/nvme-bootstrap-daemonset.yaml) only partitions and symlinks those slices under `/mnt/disks-fs`. local-volume-provisioner publishes them with `volumeMode: Filesystem` and `fsType: ext4`, and **kubelet formats them** when the pod binds — the same path AKO already declares on the CR. Every local NVMe disk is partitioned into both roles — see [config/disk-layouts.yaml](../../config/disk-layouts.yaml).
2. **Kernel settings on every node.** A root server sets `vm.dirty_bytes`, `vm.dirty_background_bytes`, `vm.dirty_expire_centisecs`, and `vm.dirty_writeback_centisecs` itself; AKO runs the server unprivileged, so [all-flash-sysctl-daemonset.yaml](../../manifests/all-flash-sysctl-daemonset.yaml) sets them (plus `vm.min_free_kbytes=1310720`) before Aerospike starts. Without them the node refuses to start an all-flash namespace.

### What the CR looks like

```yaml
    namespaces:
      - name: test
        replication-factor: 2
        partition-tree-sprigs: 16384
        index-type:
          type: flash
          mounts:
            - /mnt/index/1        # one per Filesystem volume
          mounts-budget: 644245094400   # 600 GiB of index per node
        storage-engine:
          type: device
          devices:
            - /dev/data/local1    # one per Block volume
```

There is deliberately **no `indexes-memory-budget`** — that setting sizes a DRAM index and does not apply here.

### Per-cloud layout

| | AWS EKS (`i8ge.3xlarge`) | GCP GKE (`n2-highmem-16` + 16 Local SSD) |
|---|---|---|
| Local NVMe | 1 × 7500 GB (~6985 GiB usable) | 16 × 375 GiB |
| Index slices | 1 × 640 GiB (kubelet formats ext4) → claims **600Gi** | 16 × 40 GiB (kubelet formats ext4) → claims **37.5 GiB** each |
| Data slices | 5 × 1024 GiB → claims **1000Gi** each | 16 × ~335 GiB → claims **300Gi** each |
| Unprovisioned | ~1225 GiB left off the partition table | none (remainder of each disk is the data slice) |
| Index per node | 600 GiB | 600 GiB |

The slices are larger than the claims so that after kubelet formats ext4 there is still room for `mounts-budget` (600 GiB of index per node).

## Steps

### Path A — kubectl

1. Read the manifest for your cloud before applying it:

   ```bash
   # EKS
   less manifests/all-flash-cluster.yaml
   # GKE
   less manifests/all-flash-cluster-gke.yaml
   ```

   Note the paired volumes (`ns-data-*` Block, `ns-index-*` Filesystem) and `localStorageClasses` listing both `local-ssd` and `local-ssd-fs`.

2. Deploy:

   ```bash
   ./scripts/labs/deploy-all-flash-cluster.sh
   ```

   The script picks the right manifest for `CLOUD_PROVIDER` and waits for reconciliation. The equivalent raw command is `kubectl apply -f manifests/all-flash-cluster.yaml`.

   **Expected:** `aerospikecluster.asdb.aerospike.com/aerocluster created`, then pods reaching Running one at a time.

### Path B — Helm

1. Deploy with the all-flash base values:

   ```bash
   ./scripts/labs/deploy-all-flash-cluster-helm.sh
   ```

   It resolves `helm/base-all-flash-cluster-values.yaml` (EKS) or `helm/base-all-flash-cluster-gke-values.yaml` (GKE) and installs the `aerospike-cluster` chart at the operator's version.

   **Expected:** Release `aerocluster` status `deployed`; same pod rollout as Path A.

### Both paths

2. Watch the rollout — first start is slower than the disk labs because each pod formats and warms its index mounts:

   ```bash
   kubectl -n aerospike get pods -w
   ```

## Verify (pass/fail)

1. Run the bundled check:

   ```bash
   ./scripts/labs/validate-all-flash.sh
   ```

   **Pass:** ends with `All-flash validation: PASS` — CR phase `Completed`, 3 pods Running, data and index PVCs bound, `asinfo index-type=flash`, `cluster-size=3`.

2. Confirm the index really is on flash, from the server rather than the CR:

   ```bash
   kubectl run asinfo-check -n aerospike --restart=Never --rm -i \
     --image=aerospike/aerospike-tools:latest -- \
     asinfo -h aerocluster -U admin -P admin123 -v 'namespace/test' \
     | tr ';' '\n' | grep -E 'index-type|index_flash'
   ```

   **Pass:** `index-type=flash`, `index-type.mounts-budget=644245094400`, and `index_flash_used_bytes` greater than zero.

3. Confirm both PV families are bound:

   ```bash
   kubectl -n aerospike get pvc -l aerospike.com/cr=aerocluster \
     -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,SIZE:.spec.resources.requests.storage
   ```

   **Pass:** on EKS 15 `local-ssd` + 3 `local-ssd-fs` claims Bound; on GKE 48 + 48.

4. Confirm the kernel settings the namespace depends on:

   ```bash
   kubectl -n kube-system logs ds/all-flash-sysctl -c set-sysctls --tail=10
   ```

   **Pass:** `vm.dirty_bytes = 16777216`, `vm.dirty_background_bytes = 1`, `vm.dirty_expire_centisecs = 1`, `vm.dirty_writeback_centisecs = 10`, `vm.min_free_kbytes = 1310720`.

## Observe

- Pod memory requests are **64 GiB** against 96–128 GiB nodes. In the disk labs the pods ask for 57 GiB because the index lives in DRAM; here the index is on NVMe and the remaining RAM is page cache the kernel manages.
- `index_flash_used_bytes` grows in 4 KiB pages per sprig, not per record. With `partition-tree-sprigs: 16384` a namespace reserves at least one 4 KiB page per sprig per partition it owns, which is why the 600 GiB budget is generous for a 3-node lab.
- Each pod's index mounts are node-local. A pod cannot move to another node and keep its index — the same constraint as the block data volumes.

## Troubleshooting

For AKO logs and general diagnostics, see [Troubleshooting](../../README.md#troubleshooting) in the workshop README.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Index PVCs stay `Pending` | No `local-ssd-fs` PVs on the node | `kubectl get pv \| grep local-ssd-fs`; then `kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=40` — look for `symlink ... /mnt/disks-fs/` |
| Index PVC Pending with PVs present | Claim larger than the published slice | Compare `kubectl get pv` capacity with the claim; index PVs should be the raw partition size (EKS ~640Gi) |
| Pod `CrashLoopBackOff`, log says best practice failed | `vm.dirty_*` not set on that node | Check the node has `workshop.aerospike.com/storage=all-flash`, then `kubectl -n kube-system rollout restart ds/all-flash-sysctl` |
| Pods Pending, nodes look fine | `multiPodPerHost: false` needs one node per pod | `kubectl get nodes -l workshop.aerospike.com/node-pool=baseline`; grow the pool with `./scripts/setup/all-flash/ensure-nodegroup.sh <count>` |
| Wrong cluster | `kubectl` drifted back to the main cluster | `./scripts/lib/kubecontext.sh all-flash` |

## Teardown / handoff

Leave the cluster running for [Lab 4.2](02-scale-all-flash.md). When Section 4 is done:

```bash
./scripts/cleanup-lab.sh --all-flash-only
```

## Not covered here

- Converting an existing DRAM-index cluster to all-flash in place — AKO cannot add the index volumes to a running CR
- Secondary index on flash (`sindex-type flash`), which uses the same kernel settings but a different stanza
- Raising `partition-tree-sprigs`, which needs a rolling cold restart → see [instructor-notes.md](instructor-notes.md)

## Workshop artifacts

- Path A: [manifests/all-flash-cluster.yaml](../../manifests/all-flash-cluster.yaml) (EKS) · [manifests/all-flash-cluster-gke.yaml](../../manifests/all-flash-cluster-gke.yaml) (GKE)
- Path B: [helm/base-all-flash-cluster-values.yaml](../../helm/base-all-flash-cluster-values.yaml) (EKS) · [helm/base-all-flash-cluster-gke-values.yaml](../../helm/base-all-flash-cluster-gke-values.yaml) (GKE)
- Kernel settings: [manifests/all-flash-sysctl-daemonset.yaml](../../manifests/all-flash-sysctl-daemonset.yaml)
- Disk layouts: [config/disk-layouts.yaml](../../config/disk-layouts.yaml) (`i8ge.3xlarge-all-flash`, `n2-highmem-16-all-flash`)
- Storage classes: [vendor/storage/local_storage_class.yaml](../../vendor/storage/local_storage_class.yaml) · [vendor/storage/local_fs_storage_class.yaml](../../vendor/storage/local_fs_storage_class.yaml)
- Both CRs and both value files are generated — edit [scripts/labs/render-all-flash-manifests.py](../../scripts/labs/render-all-flash-manifests.py), not the YAML

## References

- [All-flash storage configuration for Aerospike on Kubernetes](https://aerospike.com/docs/kubernetes/manage/storage/all-flash)
- [Primary index configuration](https://aerospike.com/docs/database/manage/namespace/primary-index)
- [Best practices for Aerospike and Linux — All-Flash deployment](https://aerospike.com/docs/database/learn/best-practices/)
