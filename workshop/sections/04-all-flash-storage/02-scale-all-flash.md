# Lab 4.2 — Scale an All-flash Cluster

| Field | Value |
|-------|-------|
| Lab ID | `4.2` |
| Section | All-flash Storage |
| Cluster | `${ALL_FLASH_CLUSTER_NAME}` (default `my-cluster-all-flash`) |
| Aerospike cluster | `aerocluster`, `${ALL_FLASH_AEROSPIKE_SIZE}` → `${ALL_FLASH_AEROSPIKE_SIZE_SCALED}` nodes (3 → 4) |
| AKO min version | `4.5.0` (`ALL_FLASH_AKO_VERSION`) |
| Aerospike baseline | all-flash 3-node cluster from Lab 4.1 |
| Deploy path | A (kubectl) / B (Helm) — follows `DEPLOY_PATH` |
| Duration | ~25–35 min |
| Validation status | `draft` |
| Official docs | [Scaling](https://aerospike.com/docs/kubernetes/manage/configure/scaling) · [AKO all-flash](https://aerospike.com/docs/kubernetes/manage/storage/all-flash) |

## Takeaway

Scaling an all-flash cluster is the same `spec.size` change as any other cluster — the difference is that each new pod needs a node whose NVMe has **already been partitioned into index and data slices**, so the node pool and the local PVs have to be ready before AKO can place the pod.

## Prerequisites

- [Lab 4.1](01-deploy-all-flash.md) complete: 3-pod all-flash cluster, phase `Completed`
- Headroom for a 4th `${ALL_FLASH_NODE_TYPE}` node in the all-flash zone

## Phase 0 — Prepare lab

```bash
./scripts/labs/prepare-lab.sh 4.2
```

Bootstraps the Kubernetes cluster if it is missing (setup step 0.8), deploys the Lab 4.1 Aerospike baseline if `aerocluster` is absent, then validates the 3-pod starting state.

## Starting state

```bash
./scripts/lib/kubecontext.sh all-flash
kubectl -n aerospike get aerospikecluster aerocluster
kubectl get nodes -l workshop.aerospike.com/node-pool=baseline
```

**Expected:** phase `Completed`, `spec.size` 3, 3 nodes.

## Load data (before scaling)

Load **25M records × 100 bytes** on the 3-node cluster so scale-out migrations and the drop in `index_flash_used_bytes` are visible (~2–3 min). Tiny objects keep this an **index** workload: 25M primary-index entries, about 2.5 GB of payload.

```bash
./scripts/labs/load-data.sh --all-flash
```

The script targets `${ALL_FLASH_CLUSTER_NAME}` (not the main workshop cluster). Override count or size with `ALL_FLASH_LOAD_RECORDS` / `ALL_FLASH_LOAD_OBJECT_SIZE` in `workshop.env`.

**Expected:** asbench Job completes; `asadm -e "info namespace"` shows roughly 25M objects in `test` (RF 2, so `objects` per node is a share of that). Capture `index_flash_used_bytes` now — it should drop after Step 4.

## Background

`multiPodPerHost: false` means one Aerospike pod per node, and every pod claims node-local PVs. Scaling to 4 therefore has three ordered requirements:

1. A 4th node exists in the all-flash pool (`eksctl scale nodegroup` / `gcloud container clusters resize`).
2. `nvme-bootstrap` has partitioned that node's NVMe — index slices symlinked under `/mnt/disks-fs`, data slices under `/mnt/disks` — and local-volume-provisioner has published both PV families for it.
3. Only then does `spec.size: 4` have somewhere to land.

Skip step 1 or 2 and the new pod sits `Pending` on unbound PVCs. [`scale-all-flash-cluster.sh`](../../scripts/labs/scale-all-flash-cluster.sh) does all three in order; the steps below show them separately so you can watch each one.

## Steps

### Step 1 — Grow the node pool (both paths)

```bash
./scripts/setup/all-flash/ensure-nodegroup.sh 4
```

**Expected:** `ng-all-flash nodes Ready: 4/4`. The node is labelled `workshop.aerospike.com/node-pool=baseline` and `workshop.aerospike.com/storage=all-flash`.

### Step 2 — Watch the new node get its slices (both paths)

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=nvme-bootstrap -o wide
kubectl -n kube-system get pods -l app.kubernetes.io/name=all-flash-sysctl -o wide
kubectl get pv --sort-by=.spec.storageClassName \
  -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAP:.spec.capacity.storage,STATUS:.status.phase
```

**Expected:** both DaemonSets have a Running pod on the new node; the `local-ssd` and `local-ssd-fs` PV counts each grow by one node's worth (EKS 5 and 1; GKE 16 and 16).

First partitioning on a fresh node takes several minutes — the init container installs `parted`, `nvme-cli`, and PyYAML before it touches a disk. Index devices are formatted later, when the Aerospike pod binds the Filesystem PVC.

### Step 3 — Scale the cluster

#### Path A — kubectl

Edit `spec.size` from `3` to `4` in the manifest for your cloud and re-apply:

```bash
# manifests/all-flash-cluster.yaml (EKS) or manifests/all-flash-cluster-gke.yaml (GKE)
kubectl apply -f manifests/all-flash-cluster.yaml
```

Or patch it in place without editing the file:

```bash
kubectl -n aerospike patch aerospikecluster aerocluster --type=merge -p '{"spec":{"size":4}}'
```

**Expected:** `aerospikecluster.asdb.aerospike.com/aerocluster configured`.

#### Path B — Helm

```bash
./scripts/labs/deploy-all-flash-cluster-helm.sh helm/overlay-all-flash-scale-4-values.yaml
```

The overlay only sets `replicas: 4`; everything else still comes from the base values file.

**Expected:** Release `aerocluster` upgraded, revision incremented.

#### Scripted equivalent (either path)

```bash
./scripts/labs/scale-all-flash-cluster.sh
```

Loads 25M × 100 B records, then runs Steps 1–3 for your `DEPLOY_PATH`, and finishes with the validation below. Skip the load-data command above if you use this script.

### Step 4 — Watch reconciliation

```bash
kubectl -n aerospike get pods -w
```

**Expected:** `aerocluster-0-3` appears, binds its data and index PVCs, and reaches Running. Migrations then rebalance partitions onto it.

## Verify (pass/fail)

1. Pre-scale object count (if you loaded data by hand, do this before Step 1):

   ```bash
   kubectl run asinfo-objects -n aerospike --restart=Never --rm -i \
     --image=aerospike/aerospike-tools:latest -- \
     asadm -h aerocluster -U admin -P admin123 -e "info namespace"
   ```

   **Pass:** `test` shows objects on the order of 25 million cluster-wide before the size bump.

2. Validation script at the new size:

   ```bash
   ./scripts/labs/validate-all-flash.sh 4
   ```

   **Pass:** `All-flash validation: PASS` — phase `Completed`, 4 pods Running, `asinfo cluster-size=4`, index-type still `flash`.

3. The new pod has both volume kinds:

   ```bash
   kubectl -n aerospike get pvc -l aerospike.com/cr=aerocluster \
     -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,STATUS:.status.phase \
     | grep -- '-3'
   ```

   **Pass:** the 4th pod's claims include `local-ssd` data volumes and at least one `local-ssd-fs` index volume, all `Bound`.

4. Migrations finish:

   ```bash
   kubectl run asinfo-migrations -n aerospike --restart=Never --rm -i \
     --image=aerospike/aerospike-tools:latest -- \
     asadm -h aerocluster -U admin -P admin123 -e "info namespace"
   ```

   **Pass:** `Migrations` reaches 0 across all four nodes.

## Observe

- `index_flash_used_bytes` per node **drops** after the scale-out: each node now owns fewer partitions, so it needs fewer index pages. That is the all-flash equivalent of index DRAM pressure falling when you add a node.
- The `mounts-budget` stays 600 GiB per node — it is a per-node ceiling, not a cluster total, so it does not change when the cluster grows.
- `partition-tree-sprigs` is **unchanged** at 16384. Sizing an all-flash index depends on it, but raising it is a cold-restart operation and is deliberately out of scope — see [instructor-notes.md](instructor-notes.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 4th pod `Pending`, PVCs unbound | `nvme-bootstrap` has not finished on the new node | `kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=40`; re-run `./scripts/setup/all-flash/03-setup-local-storage.sh` |
| 4th pod `Pending`, no PVC events | No 4th node | `./scripts/setup/all-flash/ensure-nodegroup.sh 4` |
| 4th pod crashes on start | `all-flash-sysctl` has not run there | `kubectl -n kube-system rollout status ds/all-flash-sysctl` |
| Node pool will not grow past 3 | `maxSize` on the managed nodegroup | `ALL_FLASH_NODE_COUNT_SCALED` sets `maxSize` at create time; `eksctl scale nodegroup --nodes-max 4` fixes an existing one |
| Migrations never settle | Still moving data | All-flash migrations are device-bound; give them time before declaring failure |
| asbench Job hits the main cluster | Forgot `--all-flash` | `./scripts/lib/kubecontext.sh show` then `./scripts/labs/load-data.sh --all-flash` |

## Teardown / handoff

Section 4 ends here. Delete the dedicated cluster on its own:

```bash
./scripts/cleanup-lab.sh --all-flash-only
```

Scaling back down (4 → 3) works the same way in reverse, but the node pool keeps its 4th node until you resize it.

## Not covered here

- Rack awareness on all-flash → the mechanics are the same as [Lab 1.2](../01-scaling-and-capacity/02-rack-awareness-vertical-revision.md)
- Vertical scaling (changing the machine type), which would re-partition every disk
- `partition-tree-sprigs` increases (cold restart)

## Workshop artifacts

- Path A: [manifests/all-flash-cluster.yaml](../../manifests/all-flash-cluster.yaml) · [manifests/all-flash-cluster-gke.yaml](../../manifests/all-flash-cluster-gke.yaml) (`spec.size` 3 → 4)
- Path B: [helm/overlay-all-flash-scale-4-values.yaml](../../helm/overlay-all-flash-scale-4-values.yaml) over the base values
- Scripts: [load-data.sh](../../scripts/labs/load-data.sh) (`--all-flash`) · [scale-all-flash-cluster.sh](../../scripts/labs/scale-all-flash-cluster.sh) · [ensure-nodegroup.sh](../../scripts/setup/all-flash/ensure-nodegroup.sh) · [validate-all-flash.sh](../../scripts/labs/validate-all-flash.sh)

## References

- [Scaling an Aerospike cluster with AKO](https://aerospike.com/docs/kubernetes/manage/configure/scaling)
- [Primary index on flash sizing](https://aerospike.com/docs/database/manage/namespace/primary-index)
- [Cold restart](https://aerospike.com/docs/database/manage/database/cold-restart)
