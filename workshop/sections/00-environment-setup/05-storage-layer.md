# Lab 0.5 — Storage Layer

| Field | Value |
|-------|-------|
| Lab ID | `0.5` |
| Section | Environment Setup |
| Cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| Node provisioning | eksctl, Karpenter, or GKE node pools (same NVMe bootstrap DaemonSet) |
| Duration | ~25 min |
| Validation status | `draft` |

## Takeaway

Block storage (`ssd` StorageClass) and local NVMe provisioning are ready for rack and device labs. NVMe disks are partitioned once per node; disk wiping is handled by the local provisioner and AKO init containers.

**Section 1 rack labs (1.2, 1.3):** use hybrid storage — `ssd` for the workdir filesystem volume (EBS on EKS, Persistent Disk on GKE); `local-ssd` block volumes (`/dev/data/local1`, `/dev/data/local2`) for namespace device storage. Vertical scale uses 2 block PVCs per pod (`multiPodPerHost: false`): EKS `i8g.4xlarge` (6× 512 GiB partitions) or GKE `n2-highmem-16` (6× full-disk `p1`).

## Init responsibility split

Three layers handle local NVMe storage — each runs once at its lifecycle stage:

| Layer | When it runs | Method |
|-------|--------------|--------|
| **nvme-bootstrap** DaemonSet | Once per new workload node — partitions and symlinks into `/mnt/disks` | No blkdiscard in the init; skips already-allocated partitions. EKS: sliced i8g layouts with leftover. GKE: one `p1` covering 0–100% (prime/GPT, no leftover) |
| **local-volume-provisioner** | When a local-ssd PVC/PV is released | `blockCleanerCommand: blkdiscard.sh` |
| **AKO init container** | When a pod first attaches a local-ssd block volume | `initMethod: blkdiscardWithHeaderCleanup` (blkdiscard + 8MiB zero header; requires AKO 4.1.0+) |

`ssd` workdir volumes (`storageClass: ssd`) use AKO defaults for filesystem PVCs and are unaffected by this split.

**On GKE:** `05-setup-ebs-storage.sh` only applies StorageClass `ssd` (`pd.csi.storage.gke.io` / `pd-ssd`). Local NVMe still uses nvme-bootstrap: one GPT partition (`p1`, 0–100%) per disk — no leftover overprovisioning. Lab 1.2/1.3 `512Gi` claims render as `GKE_LOCAL_SSD_PVC_SIZE` (default `340Gi`).

## Prerequisites

- Lab 0.4 complete
- Vendored cleanup manifests under [`vendor/storage/`](../../vendor/storage/) (`local_volume_provisioner_cleanup*.yaml`) — checked by `01-validate-client.sh`

## Steps — Block storage `ssd` (Part A)

1. Set up the `ssd` StorageClass (and EBS CSI on EKS):

   ```bash
   ./scripts/setup/05-setup-ebs-storage.sh
   ```

   **EKS:** applies [`vendor/storage/eks_ssd_storage_class.yaml`](../../vendor/storage/eks_ssd_storage_class.yaml), associates the cluster OIDC provider, creates the IRSA role `AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}` for `ebs-csi-controller-sa`, and installs the `aws-ebs-csi-driver` addon.

   **GKE:** applies [`vendor/storage/gke_ssd_storage_class.yaml`](../../vendor/storage/gke_ssd_storage_class.yaml) only (GCE PD CSI is already on the cluster). No Workload Identity or addon install.

2. Verify:

   ```bash
   kubectl get storageclass ssd
   ```

   **Expected (EKS):** StorageClass `ssd` (default class) with provisioner `kubernetes.io/aws-ebs` and `type: gp2`. The vendored class uses the in-tree provisioner; the EBS CSI driver addon backs it through CSI migration.

   **Expected (GKE):** StorageClass `ssd` (default class) with provisioner `pd.csi.storage.gke.io` and `type: pd-ssd`.

## Steps — Local NVMe (Part B)

Both EKS (eksctl and Karpenter) and GKE node pools use the same **`nvme-bootstrap` DaemonSet** — no manual node-shell step.

1. Deploy local volume provisioner, cleanup controller, and NVMe bootstrap:

   ```bash
   ./scripts/setup/06-setup-local-storage.sh
   ```

   The script applies the `local-ssd` StorageClass, the provisioner, and the cleanup RBAC/controller, then renders ConfigMap `nvme-disk-layouts` in `kube-system` from [`config/disk-layouts.yaml`](../../config/disk-layouts.yaml) plus `nvme-init.py` (applying the `NVME_DISK_LAYOUT` override), applies the DaemonSet, and waits up to `NVME_WAIT_TIMEOUT` (default 1800s) for bootstrap pods. If no baseline nodes exist yet it skips the PV check and defers it to step 0.6.

2. Verify provisioner pods:

   ```bash
   kubectl -n aerospike get pods -l app=local-volume-provisioner
   ```

   **Expected:** Provisioner pods `Running` in namespace `aerospike`.

3. Verify NVMe bootstrap and cleanup controller:

   ```bash
   kubectl -n kube-system get ds nvme-bootstrap
   kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=30
   kubectl -n kube-system get deploy local-volume-node-cleanup-controller
   ```

4. Verify partitioned disk symlinks on a workload node:

   ```bash
   kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=40
   ```

   Look for `discovered instance-store devices:` and `symlink` lines in the init log.

   **Expected on i8g.4xlarge (EKS):** Symlinks to `<instance-store>p1` through `p6` on the first local SSD (6× 512 GiB; remainder unallocated for overprovisioning).

   **Expected on i8g.8xlarge (EKS):** Symlinks to `p1` through `p6` on **each** discovered instance-store NVMe (2 disks × 6× 512 GiB = 12 partitions).

   **Expected on i8g.2xlarge (EKS):** Symlinks to `<instance-store>p1`, `p2`, `p3` (3× 512 GiB partitions).

   **Expected on n2-highmem-8 (GKE):** One `p1` symlink per local NVMe (3 disks × full device). **n2-highmem-16:** 6× `p1` (one per disk).

5. Verify local-ssd PVs (script restarts the provisioner only if PV count is short):

   ```bash
   kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,STATUS:.status.phase --no-headers | awk '$2 == "local-ssd"'
   ```

   **Expected:** One PV per partition symlink — **EKS:** 3× ~512Gi per i8g.2xlarge, 6× per i8g.4xlarge, 12× per i8g.8xlarge. **GKE:** 3× ~349Gi per n2-highmem-8, 6× per n2-highmem-16 (multiply by `${NODE_COUNT}` workload nodes).

## Disk layouts

Layouts are defined in [`config/disk-layouts.yaml`](../../config/disk-layouts.yaml). The bootstrap init container reads the instance type from EC2 IMDS or GCP metadata and applies the matching layout.

| Instance type | NVMe total | Exposed partitions |
|---------------|------------|-------------------|
| i8g.2xlarge | 1900 GB | 3× 512 GiB on first instance-store NVMe (`p1`, `p2`, `p3`) |
| i8g.4xlarge | 3750 GB | 6× 512 GiB on first instance-store NVMe (`p1`–`p6`) |
| i8g.8xlarge | 2× local SSD | 6× 512 GiB per disk (`p1`–`p6` on each; 12 total) |
| n2-highmem-8 | 3× 375 GB local NVMe | 1× full-disk `p1` per disk (3 PVs; no leftover) |
| n2-highmem-16 | 6× 375 GB local NVMe | 1× full-disk `p1` per disk (6 PVs; no leftover) |
| other | auto-detect | whole-device symlinks on all instance-store NVMe (fallback) |

Override layout for testing with `NVME_DISK_LAYOUT=i8g.4xlarge` in `workshop.env`.

When adding a layout with `instance_store: all`, set `instance_store_devices` in [`config/disk-layouts.yaml`](../../config/disk-layouts.yaml) so setup validation can compute expected local-ssd PV counts (`len(partitions) × instance_store_devices`). Example: `i8g.8xlarge` uses `instance_store_devices: 2` for 2 local SSDs × 6 partitions = 12 PVs per node.

## Instructor demo — local PVC cleanup on node failure

Optional demo after Part B (uses [`manifests/local-ssd-demo.yaml`](../../manifests/local-ssd-demo.yaml)):

1. Deploy the local-storage demo cluster:

   ```bash
   kubectl apply -f manifests/local-ssd-demo.yaml
   kubectl -n aerospike get pvc -o wide
   ```

   **Expected:** Block PVCs bound to specific nodes (`local-ssd` StorageClass).

2. Note which node hosts a pod with local PVCs:

   ```bash
   kubectl -n aerospike get pods -o wide
   NODE=<node-with-local-pvc>
   ```

3. Simulate node loss (instructor only — destructive):

   ```bash
   kubectl delete node "$NODE"
   ```

4. Watch cleanup controller delete orphaned PVCs (~60s delay):

   ```bash
   kubectl -n kube-system logs deploy/local-volume-node-cleanup-controller -f
   kubectl -n aerospike get pvc -w
   ```

   **Expected:** PVCs with node affinity to the deleted node are removed. Pods enter `Pending` waiting for replacement storage.

5. Discuss: `ssd` PVCs survive node loss (EBS or PD); local `local-ssd` PVCs do not — plan capacity and replication accordingly.

6. Tear down the demo cluster before Lab 0.6 or Section 1 — this demo uses AerospikeCluster CR name `local-ssd-demo`, not the `aerocluster` name used in later labs:

   ```bash
   kubectl delete -f manifests/local-ssd-demo.yaml
   ```

   **Expected:** No `AerospikeCluster` resources remain in the `aerospike` namespace.

## Verify (pass/fail)

- `kubectl get sc ssd` and `kubectl get sc local-ssd` exist
- `nvme-bootstrap` DaemonSet Ready on all nodes
- `local-volume-node-cleanup-controller` deployment Ready
- Local volume provisioner running in `aerospike` namespace
- `kubectl get pv ... awk '$2 == "local-ssd"'` shows expected count (EKS: 3× per i8g.2xlarge, 6× per i8g.4xlarge, 12× per i8g.8xlarge; GKE: 3× per n2-highmem-8, 6× per n2-highmem-16)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| EBS / PD PVC Pending | **EKS:** verify EBS CSI IAM role and addon. **GKE:** `kubectl get sc ssd` must show `pd.csi.storage.gke.io` |
| No local-ssd PVs after setup | Re-run `./scripts/setup/06-setup-local-storage.sh` or `./scripts/setup/08-validate-environment.sh` (both restart the provisioner only if PV count is short) |
| nvme-bootstrap not Ready | Check privileged init logs; re-run `06-setup-local-storage.sh` |
| No partition symlinks | Confirm instance type in `disk-layouts.yaml`; check IMDS (EKS) or GCP metadata (GKE) from the node |
| Cleanup controller not deleting PVCs | Verify `--storageclass-names=local-ssd` and controller pod logs |
| Wrong partition count | Set `NVME_DISK_LAYOUT` or update `config/disk-layouts.yaml` |
| Wrong PV sizes (stale partition table) | Delete local-ssd PVs and PVCs. On each affected node, remove bootstrap markers: `rm -rf /var/lib/workshop/nvme-bootstrap` (legacy: `/mnt/disks/.nvme-bootstrap`). Replace the node (fresh instance store / local SSD) or manually wipe GPT only when no PVs are bound. Re-run `06-setup-local-storage.sh`. Expect EKS ~512Gi slices (3× i8g.2xlarge, 6× i8g.4xlarge) or GKE ~349Gi full-disk `p1` (3× n2-highmem-8, 6× n2-highmem-16). |
| nvme-bootstrap re-runs on every lab | Expected only when new workload nodes join the pool. Reused nodes skip bootstrap via markers in `/var/lib/workshop/nvme-bootstrap/`. |
| Provisioner logs: `.nvme-bootstrap` filesystem mode | Harmless on old nodes until nvme-bootstrap re-runs; re-apply storage setup (`06-setup-local-storage.sh`) or restart nvme-bootstrap pods to migrate markers off `/mnt/disks`. |
| Provisioner logs: `nvme0n1p1: no such file or directory` | Symlinks exist but provisioner cannot resolve `/dev` targets — re-apply `manifests/aerospike_local_volume_provisioner.yaml` (mounts host `/dev`) and restart the DaemonSet. Confirm nvme-bootstrap finished: `kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=30`. |

## Teardown / handoff

Proceed to [Lab 0.6 — Secrets and validation](06-secrets-and-validation.md).

## Workshop artifacts

Setup manifests (Path A only — no Helm pairs):

- [manifests/aerospike_local_volume_provisioner.yaml](../../manifests/aerospike_local_volume_provisioner.yaml)
- [manifests/local-ssd-demo.yaml](../../manifests/local-ssd-demo.yaml) (optional instructor demo)
- [scripts/setup/nvme-bootstrap-daemonset.yaml](../../scripts/setup/nvme-bootstrap-daemonset.yaml)
- [config/disk-layouts.yaml](../../config/disk-layouts.yaml)
- Vendored EBS / GKE PD / local storage: [vendor/storage/](../../vendor/storage/)

## References

- Vendored storage manifests: [`vendor/storage/`](../../vendor/storage/) (provenance in [`vendor/storage/README.md`](../../vendor/storage/README.md))
- Training-local provisioner: [`manifests/aerospike_local_volume_provisioner.yaml`](../../manifests/aerospike_local_volume_provisioner.yaml)
- [SIG local volume node cleanup controller](https://github.com/kubernetes-sigs/sig-storage-local-static-provisioner/blob/master/docs/node-cleanup-controller.md)
