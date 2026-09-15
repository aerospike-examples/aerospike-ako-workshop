# Lab 0.8 — All-flash Cluster (for Section 4)

| Field | Value |
|-------|-------|
| Lab ID | `0.8` |
| Section | Environment Setup |
| Cluster | `${ALL_FLASH_CLUSTER_NAME}` (default `my-cluster-all-flash`) |
| Kubernetes | `${K8S_VERSION}` (same as the main cluster) |
| AKO | `${ALL_FLASH_AKO_VERSION}` (default `4.5.0`) — not the Lab 0.3 `AKO_VERSION_START` pin |
| Node provisioning | **EKS:** eksctl MNG always (independent of `NODE_PROVISIONING`). **GKE:** node pool always. |
| Aerospike cluster | none — Lab 4.1 deploys `aerocluster` |
| Deploy path | Follows `DEPLOY_PATH` (unlike Lab 0.7) |
| Duration | ~25–40 min |
| Validation status | `draft` |

## Takeaway

An **opt-in third cluster** whose nodes carry large local NVMe split into index and data slices, with the kernel settings all-flash requires, so Section 4 can run `index-type: flash` without changing anything about the main workshop cluster.

## Opt-in

A default `setup-all.sh` run creates the **main cluster only**. Step 0.8 is never part of it — this cluster uses large NVMe instances and is only needed for Section 4:

```bash
./scripts/setup/setup-all.sh --step 0.8
```

Or invoke the script directly:

```bash
./scripts/setup/all-flash/setup-all-flash.sh
```

`prepare-lab.sh 4.1` also bootstraps it when it is missing, so trainees who jump straight to Section 4 are not stuck.

## Prerequisites

- Lab 0.6 complete on the main cluster (this step reuses `secrets/features.conf`)
- Quota for `${ALL_FLASH_NODE_COUNT_SCALED}`× `${ALL_FLASH_NODE_TYPE}` (4 by default — Lab 4.2 adds the 4th node), **on top of** the main cluster (and the upgrade-lab cluster if you also opted into Lab 2.6)
- On GKE: Local SSD quota for `${ALL_FLASH_GKE_LOCAL_SSD_COUNT}` × 375 GiB per node

| Cloud | Machine | CPU / RAM | Local flash | Arch |
|-------|---------|-----------|-------------|------|
| AWS EKS | `i8ge.3xlarge` | 12 vCPU / 96 GiB | 1 × 7500 GB (~6985 GiB usable) | arm64 |
| GCP GKE | `n2-highmem-16` | 16 vCPU / 128 GiB | 16 × 375 GiB Local SSD | amd64 |

`i8ge.3xlarge` is not offered in every AZ — check availability in `NODE_ZONE` before the session. On GKE the node pool is created with `--local-nvme-ssd-block=count=16`, which attaches the disks as **raw NVMe block** devices; `--ephemeral-storage-local-ssd` would RAID them together for kubelet and make them unusable as Aerospike devices.

## Steps

1. Run the step:

   ```bash
   ./scripts/setup/setup-all.sh --step 0.8
   ```

2. Watch what [`setup-all-flash.sh`](../../scripts/setup/all-flash/setup-all-flash.sh) does — each stage is skipped when already satisfied, so re-runs are safe:

   | Stage | Detail |
   |-------|--------|
   | Bootstrap | **EKS:** rendered ClusterConfig at `${K8S_VERSION}` ([`00-bootstrap-eks.sh`](../../scripts/setup/all-flash/00-bootstrap-eks.sh)). **GKE:** `gcloud` Standard cluster ([`00-bootstrap-gke.sh`](../../scripts/setup/all-flash/00-bootstrap-gke.sh)). Node pool `${ALL_FLASH_NODEGROUP_NAME}`, nodes labelled `workshop.aerospike.com/node-pool=baseline` and `workshop.aerospike.com/storage=all-flash` |
   | AKO | [`01-install-ako.sh`](../../scripts/setup/all-flash/01-install-ako.sh) → OLM or Helm at `${ALL_FLASH_AKO_VERSION}` (default 4.5.0), following `DEPLOY_PATH` |
   | akoctl | Reuses [`04-install-akoctl.sh`](../../scripts/setup/04-install-akoctl.sh) |
   | Secrets | [`02-setup-storage-secrets.sh`](../../scripts/setup/all-flash/02-setup-storage-secrets.sh) → same [`07-deploy-secrets.sh`](../../scripts/setup/07-deploy-secrets.sh) as the main cluster |
   | Block storage | `ssd` StorageClass (EBS CSI / GCE PD CSI) for the Aerospike work directory |
   | Kernel + NVMe | [`03-setup-local-storage.sh`](../../scripts/setup/all-flash/03-setup-local-storage.sh) → [`all-flash-sysctl`](../../manifests/all-flash-sysctl-daemonset.yaml) DaemonSet, then [`06-setup-local-storage.sh`](../../scripts/setup/06-setup-local-storage.sh) with the all-flash layout |

   **Expected:** ends with `=== All-flash cluster ready for Lab 4.1 (no AerospikeCluster yet) ===` followed by `Restored kubectl context to main cluster: ${CLUSTER_NAME}`. Aerospike itself is [Lab 4.1](../04-all-flash-storage/01-deploy-all-flash.md).

3. Confirm your context came back:

   ```bash
   ./scripts/lib/kubecontext.sh show
   ```

   **Expected:** `${CLUSTER_NAME}` — the restore runs on exit even if the step failed partway.

## What the storage layer does differently here

`06-setup-local-storage.sh` detects the all-flash cluster by name and switches to `ALL_FLASH_NVME_DISK_LAYOUT` instead of the instance type's main-curriculum layout. That layout marks one partition per disk with `fstype: ext4`, and [`nvme-init.py`](../../scripts/setup/nvme-bootstrap/nvme-init.py) then:

- symlinks that partition into `/mnt/disks-fs/<device>p<n>` (Filesystem discovery dir)
- symlinks the remaining partitions into `/mnt/disks` as before

local-volume-provisioner publishes the first group as **Filesystem** PVs on `local-ssd-fs` (`fsType: ext4`) and the second as **Block** PVs on `local-ssd`. Kubelet formats the index devices when the AerospikeCluster PVC uses `volumeMode: Filesystem` — nvme-bootstrap does not mkfs. Both classes exist on every cluster; `local-ssd-fs` simply stays empty where no layout defines index slices.

| Cloud | Per node |
|-------|----------|
| EKS | 1 × 640 GiB index slice + 5 × 1024 GiB data slices (~1225 GiB left unpartitioned) |
| GKE | 16 × 40 GiB index slices + 16 × ~335 GiB data slices |

## Verify (pass/fail)

```bash
./scripts/lib/kubecontext.sh all-flash
kubectl get nodes -L workshop.aerospike.com/storage
kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAP:.spec.capacity.storage | sort -k2
kubectl -n aerospike get aerospikecluster
./scripts/lib/kubecontext.sh main
```

**Pass:** `${ALL_FLASH_NODE_COUNT}` nodes Ready and labelled `all-flash`; both `local-ssd` and `local-ssd-fs` PVs present; **no** `aerocluster` yet; context returned to the main cluster.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| No `local-ssd-fs` PVs | `kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=40` — look for `symlink ... /mnt/disks-fs/`; then `kubectl -n aerospike rollout restart ds/local-volume-provisioner` |
| `nvme-bootstrap` not scheduled | Its node affinity lists instance types; `${ALL_FLASH_NODE_TYPE}` must be in [`nvme-bootstrap-daemonset.yaml`](../../scripts/setup/nvme-bootstrap/nvme-bootstrap-daemonset.yaml) |
| Pods crash on start | `kubectl -n kube-system logs ds/all-flash-sysctl -c set-sysctls` — all five `vm.*` values must be set on that node |
| `i8ge.3xlarge` capacity error | Pick another zone with `NODE_ZONE` / `ALL_FLASH_NODE_ZONE`, or change `ALL_FLASH_NODE_TYPE` (and add a matching layout key) |
| Want it gone | `./scripts/cleanup-lab.sh --all-flash-only` |

## Not covered here

The all-flash namespace itself → [Lab 4.1](../04-all-flash-storage/01-deploy-all-flash.md).

## Teardown / handoff

The cluster stays up for Section 4. Delete it on its own afterwards:

```bash
./scripts/cleanup-lab.sh --all-flash-only
```

## Workshop artifacts

- **EKS** reference config: [clusters/all-flash-cluster.yaml](../../clusters/all-flash-cluster.yaml) (documentation only — bootstrap renders its own ClusterConfig)
- **GKE:** [`00-bootstrap-gke.sh`](../../scripts/setup/all-flash/00-bootstrap-gke.sh) — no checked-in ClusterConfig
- Scripts: [`scripts/setup/all-flash/`](../../scripts/setup/all-flash/)
- Kernel settings: [manifests/all-flash-sysctl-daemonset.yaml](../../manifests/all-flash-sysctl-daemonset.yaml)
- Layouts: [scripts/setup/nvme-bootstrap/disk-layouts.yaml](../../scripts/setup/nvme-bootstrap/disk-layouts.yaml) — `i8ge.3xlarge-all-flash`, `n2-highmem-16-all-flash`
- Storage class: [vendor/storage/local_fs_storage_class.yaml](../../vendor/storage/local_fs_storage_class.yaml)
- Environment: `ALL_FLASH_*` keys in [workshop.env.example](../../scripts/env/workshop.env.example) (EKS) or [workshop.env.gke.example](../../scripts/env/workshop.env.gke.example) (GKE)

## References

- [All-flash storage configuration for Aerospike on Kubernetes](https://aerospike.com/docs/kubernetes/manage/storage/all-flash)
- [Best practices for Aerospike and Linux — All-Flash deployment](https://aerospike.com/docs/database/learn/best-practices/)
