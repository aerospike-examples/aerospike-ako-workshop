# Lab 2.6 — K8s Control Plane Upgrade

| Field | Value |
|-------|-------|
| Lab ID | `2.6` |
| Section | Maintenance & Upgrade |
| Cluster | **`${UPGRADE_LAB_CLUSTER_NAME}` only** (default `my-cluster-k8s-upgrade`) |
| K8s upgrade | `${UPGRADE_LAB_K8S_VERSION_START}` → `${UPGRADE_LAB_K8S_VERSION_TARGET}` (default `1.34 → 1.35`) |
| Aerospike baseline | 3-node device storage on local-ssd **Running before upgrade** (`--dim` for in-memory) |
| Node provisioning | **EKS:** eksctl MNG always (independent of main `NODE_PROVISIONING`). **GKE:** node pool always. |
| Duration | ~45–60 min (mostly waiting) |
| Validation status | `draft` |
| Official docs | [EKS cluster upgrade](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html) · [GKE cluster upgrades](https://cloud.google.com/kubernetes-engine/docs/how-to/upgrading-a-cluster) |

## Takeaway

A live Aerospike cluster keeps running during a managed Kubernetes **control plane** upgrade — but you must still upgrade the **worker pool** afterward to align kubelet versions.

The upgrade is **two phases** on both EKS and GKE:

1. **Control plane** — API server, etcd, and core controllers move to the target Kubernetes version. Worker nodes and Aerospike pods keep running on the old kubelet.
2. **Node pool** — the managed service rolls each worker (launch new → drain → cordon → terminate old). This is where [Lab 2.5](05-k8s-node-maintenance.md) concepts apply: safe eviction during migration, local-ssd PVC lifecycle, and pod reschedule onto fresh instance store.

**EKS vs GKE (same scripts, different CLI):**

| | EKS | GKE |
|---|-----|-----|
| Control plane | `eksctl upgrade cluster` | `gcloud container clusters upgrade --master` |
| Workers | `eksctl upgrade nodegroup` | `gcloud container clusters upgrade --node-pool` |
| Cluster status when Ready | `ACTIVE` | `RUNNING` |
| Reported version | `1.35` | `1.35.x-gke.y` — prefix match against `UPGRADE_LAB_K8S_VERSION_TARGET` is enough |

`upgrade-control-plane.sh` and `upgrade-nodegroup.sh` dispatch on `CLOUD_PROVIDER`. Do not mix `aws`/`eksctl` observe commands into a GKE session (or the reverse).

## Continuity from Lab 2.5

Lab 2.5 demonstrated **manual** worker maintenance (`kubectl drain`, safe eviction webhook, node termination, PVC cleanup). Lab 2.6 shows the **same worker-level mechanics** triggered automatically during a managed node pool upgrade.

The upgrade-lab cluster is separate from `my-cluster`. Safe eviction enabled during Lab 2.5 on the main cluster does **not** carry over — verify or enable it on upgrade-lab before the node pool phase (see [Verify safe pod eviction](#verify-safe-pod-eviction-recommended)).

## Prerequisites

- Upgrade-lab cluster created with setup step **0.7** (off by default — `./scripts/setup/setup-all.sh --step 0.7`, or `prepare-lab.sh 2.6` in Phase 0)
- Lab 2.5 complete (conceptual — worker drain, migration, local storage)
- `./scripts/lib/kubecontext.sh show` → upgrade-lab cluster before every command in this lab

## How the upgrade affects Aerospike

| Phase | What the platform changes | Aerospike impact |
|-------|---------------------------|------------------|
| Control plane | API server, etcd, scheduler to target K8s | Pods stay `Running`; brief `kubectl` API delays possible |
| Node pool (default surge strategy) | Rolling worker replacement — new kubelet + machine image | Per-node drain → CR may go `InProgress`; local-ssd pods restart on new nodes |

**Do not scale down Aerospike** during either phase. Let the managed drain handle pod movement — the same production guidance as Lab 2.5, but orchestrated by the node pool instead of manual `kubectl drain`.

Cross-reference: [Lab 2.5 — three-layer maintenance model](05-k8s-node-maintenance.md#takeaway).

> **`--dim` path:** In-memory clusters have no local-ssd PVC pinning. Abbreviate Phase 4 PVC observe steps; migration during node replacement is faster.

> **GKE `default-pool`:** Upgrade-lab GKE clusters also have a small system pool (`GKE_SYSTEM_NODEGROUP`, no local SSD). This lab upgrades **`${UPGRADE_LAB_NODEGROUP_NAME}`** (Aerospike workers) only. System-pool kubelets may stay on the start minor; that is expected and not part of the Aerospike demo.

## Phase 0 — Prepare lab

```bash
./scripts/labs/prepare-lab.sh 2.6
```

Or switch context manually:

```bash
./scripts/lib/kubecontext.sh upgrade-lab
```

**Expected:** Upgrade-lab cluster exists; 3 Aerospike pods `Running` before starting demo.

Confirm starting state:

```bash
source scripts/env/workshop.env
./scripts/lib/kubecontext.sh show
./scripts/labs/prepare-lab.sh 2.6 --skip-reset   # validate only if already staged
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster

# EKS
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" --query cluster.version

# GKE
gcloud container clusters describe "${UPGRADE_LAB_CLUSTER_NAME}" \
  --region "${GCP_REGION}" --project "${GCP_PROJECT}" \
  --format='value(currentMasterVersion)'
```

**Pass:** Context is `${UPGRADE_LAB_CLUSTER_NAME}`; 3/3 `Running`; control plane at `${UPGRADE_LAB_K8S_VERSION_START}` (default `1.34`; GKE may print `1.34.x-gke.y`).

## Phase 1 — Seed data + continuous workload

An empty cluster makes availability hard to prove during a long upgrade. Load records and start throughput in a second terminal — same pattern as Labs 2.4 and 2.5.

**Option A — load after Phase 0:**

```bash
./scripts/lib/kubecontext.sh upgrade-lab
./scripts/labs/load-data.sh --upgrade-lab
```

**Option B — combine prepare + load:**

```bash
./scripts/labs/prepare-lab.sh 2.6 --load-data
```

Verify data is present:

```bash
kubectl run -it --rm aerospike-tool-ns -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U app -P app123 -e "info"
```

**Pass:** Non-zero objects in namespace `test`.

**Terminal B — start continuous workload:**

```bash
./scripts/lib/kubecontext.sh upgrade-lab
./scripts/labs/run-lab-workload.sh --upgrade-lab start
```

Watch throughput during Phases 3–4:

```bash
./scripts/labs/run-lab-workload.sh --upgrade-lab status
```

Stop when finished (Phase 5):

```bash
./scripts/labs/run-lab-workload.sh --upgrade-lab stop
```

## Verify safe pod eviction (recommended)

Upgrade-lab installs AKO via OLM ([`01-install-ako.sh`](../../scripts/setup/upgrade-lab/01-install-ako.sh)), which does **not** enable safe pod eviction by default. During the node pool phase, the platform drains each worker — the same eviction path Lab 2.5 demonstrated.

Patch the subscription if you have not already (same command as [Lab 2.5 Path A](05-k8s-node-maintenance.md#path-a--olm)):

```bash
kubectl -n operators patch subscription aerospike-kubernetes-operator \
  --type='merge' \
  -p '{"spec":{"config":{"env":[{"name":"ENABLE_SAFE_POD_EVICTION","value":"true"}]}}}'
kubectl -n operators rollout status deployment/aerospike-operator-controller-manager --timeout=120s
kubectl get validatingwebhookconfiguration | grep aerospikeeviction
```

**Pass:** `ENABLE_SAFE_POD_EVICTION=true`; eviction validating webhook listed; controller Ready.

## Phase 2 — Pre-upgrade checks

```bash
source scripts/env/workshop.env
./scripts/lib/kubecontext.sh show
kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,READY:.status.conditions[-1].type
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
```

**EKS — cluster + addon compatibility:**

```bash
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" \
  --query 'cluster.{version:version,status:status}' --output table
aws eks describe-addon-versions --kubernetes-version "${UPGRADE_LAB_K8S_VERSION_TARGET}" \
  --addon-name vpc-cni --query 'addons[0].addonVersions[0].compatibilities' --output table
```

**GKE — cluster:**

```bash
gcloud container clusters describe "${UPGRADE_LAB_CLUSTER_NAME}" \
  --region "${GCP_REGION}" --project "${GCP_PROJECT}" \
  --format='table(currentMasterVersion,currentNodeVersion,status)'
```

**Pass:** Cluster Ready (`ACTIVE` / `RUNNING`) at `${UPGRADE_LAB_K8S_VERSION_START}`; 3/3 Aerospike `Running`; CR `Completed`; Aerospike-pool kubelets match the start minor.

> **Production note:** Scan for deprecated APIs (e.g. [pluto](https://github.com/FairwindsOps/pluto)) before upgrading. Not required in the workshop.

## Phase 3 — Control plane upgrade

Use **two terminals**. The control plane upgrade does **not** restart Aerospike pods — workers stay on the old kubelet until Phase 4.

### 3a — Start upgrade (Terminal A)

```bash
./scripts/setup/upgrade-lab/upgrade-control-plane.sh
```

**What runs:**

**EKS**

1. `eksctl upgrade cluster --version ${UPGRADE_LAB_K8S_VERSION_TARGET} --approve`
2. AWS upgrades control plane components (API server, etcd, core controllers)
3. `aws eks wait cluster-active` (~10–20 min)

**GKE**

1. `gcloud container clusters upgrade --master --cluster-version=${UPGRADE_LAB_K8S_VERSION_TARGET} --quiet`
2. GKE upgrades the control plane in place (~10–20 min; the command blocks until done)

### 3b — Observe Aerospike (Terminal B)

While Terminal A waits:

```bash
watch -n5 'kubectl -n aerospike get pods; kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath="{.status.phase}{\"\\n\"}"'
```

Or poll manually:

```bash
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
./scripts/labs/run-lab-workload.sh --upgrade-lab status
```

Mid-upgrade cluster status (Terminal A or B):

```bash
source scripts/env/workshop.env

# EKS
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" \
  --query 'cluster.{version:version,status:status}' --output table

# GKE
gcloud container clusters describe "${UPGRADE_LAB_CLUSTER_NAME}" \
  --region "${GCP_REGION}" --project "${GCP_PROJECT}" \
  --format='table(currentMasterVersion,status)'
```

**Pass during CP upgrade:**

- 3/3 pods stay `Running`
- CR stays `Completed` (brief `InProgress` is unusual but acceptable)
- Workload TPS may dip during API blips but should recover
- Terminal A prints `Control plane upgrade complete.`

## Phase 4 — Node pool upgrade

After the control plane reaches the target version, upgrade workers so kubelet and machine image align. **First Aerospike pod restarts happen here**, not during Phase 3.

### 4a — Start node pool upgrade (Terminal A)

```bash
./scripts/setup/upgrade-lab/upgrade-nodegroup.sh
```

**What the platform does** ([EKS managed node update](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html), [GKE node-pool upgrade](https://cloud.google.com/kubernetes-engine/docs/how-to/upgrading-a-cluster#upgrading_node_pools)):

1. Selects node(s) to upgrade (surge / `updateConfig` parallelism)
2. **Default surge strategy:** launches replacement node(s) first, then drains old node(s)
3. For each old node: respect PDBs → evict pods → cordon → terminate
4. Repeats until all pool nodes run the target kubelet/image
5. Scale-down / surge cleanup returns the pool to the original desired count

The script waits until the pool is Ready (~15–25 min for 3 Aerospike workers).

### 4b — Observe during rolling worker upgrade (Terminal B)

```bash
# Node replacement progress (workshop label is set on both EKS MNG and GKE pools)
kubectl get nodes -l "workshop.aerospike.com/node-pool=baseline" -o wide -w
```

Ctrl+C once all Aerospike-pool nodes show the target kubelet minor. Then watch Aerospike:

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl -n aerospike get pods -o wide
```

If CR goes `InProgress` — same signals as [Lab 2.5 Phase 2c](05-k8s-node-maintenance.md#2c--observe-during-migration):

```bash
kubectl run -it --rm aerospike-tool-migrate -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show stat like migrate"
```

Device storage — local-ssd PVC lifecycle (same pattern as Lab 2.5 Phase 4):

```bash
kubectl -n aerospike get pvc -o wide
kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster -o wide -w
```

**Pass during node pool upgrade:**

- Aerospike-pool nodes transition to the target kubelet version one-by-one
- Aerospike ends at 3/3 `Running` and CR `Completed`
- Workload TPS recovers after each pod move
- Terminal A prints `Node pool upgrade complete.`

## Phase 5 — Post-upgrade validation

```bash
./scripts/setup/upgrade-lab/validate-post-upgrade.sh
```

Additional manual checks:

```bash
source scripts/env/workshop.env
kubectl get nodes -l "workshop.aerospike.com/node-pool=baseline" \
  -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl run -it --rm aerospike-tool-verify -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "info"

# EKS
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" --query cluster.version

# GKE
gcloud container clusters describe "${UPGRADE_LAB_CLUSTER_NAME}" \
  --region "${GCP_REGION}" --project "${GCP_PROJECT}" \
  --format='value(currentMasterVersion)'
```

**Pass:** Control plane at `${UPGRADE_LAB_K8S_VERSION_TARGET}` (GKE prefix match); Aerospike-pool kubelets on the target minor; 3/3 `Running`; CR `Completed`; `cluster_size=3` in asadm output.

## Verify (pass/fail)

| Check | Expected |
|-------|----------|
| Control plane version | `${UPGRADE_LAB_K8S_VERSION_TARGET}` (GKE: `1.35.x-gke.y`) |
| Aerospike-pool kubelets | Target minor on `${UPGRADE_LAB_NODEGROUP_NAME}` workers |
| Aerospike pods | 3/3 `Running` |
| CR phase | `Completed` |
| Cluster membership | `cluster_size=3` via asadm |

## Observe

- Cloud console upgrade progress (control plane, then Aerospike node pool)
- **No unplanned Aerospike restarts during control plane upgrade** (Phase 3)
- Pod restarts and possible migration during **node pool upgrade** (Phase 4)
- Safe eviction may delay drain while migration is active (Lab 2.5 webhook behavior)
- Continuous workload TPS through both phases (Terminal B)
- local-ssd PVC cleanup and pod reschedule on new nodes (device storage)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `load-data.sh` hits wrong cluster | Use `--upgrade-lab`; verify with `./scripts/lib/kubecontext.sh show` |
| CP upgrade stuck `UPDATING` / `RECONCILING` | Wait; EKS: `aws eks describe-cluster`; GKE: `gcloud container clusters describe` / GKE console |
| Node pool upgrade `PodEvictionFailure` | Safe eviction blocking during migration — wait for CR `Completed`; never `--force` in demo |
| Pods `Pending` after node replace | Check local-ssd PVs + cleanup controller ([Lab 0.5](../00-environment-setup/05-storage-layer.md)); wait ~60s |
| K8s version already at TARGET | Cluster upgraded in a prior run — recreate upgrade-lab or adjust `UPGRADE_LAB_K8S_VERSION_*` |
| GKE: `cluster-version` not available | Pick a valid `${UPGRADE_LAB_K8S_VERSION_TARGET}` patch from `gcloud container get-server-config --region "${GCP_REGION}" --flatten=validMasterVersions --format='value(validMasterVersions)'` |
| Wrong kubectl context | `./scripts/lib/kubecontext.sh upgrade-lab` |
| Migration completes too fast to observe | Increase data load (`MIGRATION_LOAD_RECORDS`) in Phase 1 |
| No webhook during node pool drain | Enable safe pod eviction on upgrade-lab (see above) |

## Not covered here

- Manual worker drain → [Lab 2.5](05-k8s-node-maintenance.md)
- AKO upgrade → [Lab 2.2](02-upgrade-ako.md)
- GKE system `default-pool` kubelet upgrade (optional after the Aerospike pool)

## Teardown

After Lab 2.6 demo, if continuing with main-cluster labs:

```bash
./scripts/cleanup-lab.sh --upgrade-lab-only --yes
./scripts/lib/kubecontext.sh main
```

End of full training (delete **all** workshop clusters in parallel):

```bash
./scripts/cleanup-lab.sh --yes
```

Use `--sequential` to delete one cluster at a time.

## Workshop artifacts

- **EKS** reference config: [clusters/upgrade-lab-cluster.yaml](../../clusters/upgrade-lab-cluster.yaml)
- **GKE:** [`00-bootstrap-gke.sh`](../../scripts/setup/upgrade-lab/00-bootstrap-gke.sh)
- **Baseline Aerospike cluster (3 nodes):**
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (default) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)

## References

- [eksctl cluster upgrade](https://docs.aws.amazon.com/eks/latest/eksctl/cluster-upgrade.html)
- [EKS managed node update behavior](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html)
- [GKE cluster upgrades](https://cloud.google.com/kubernetes-engine/docs/how-to/upgrading-a-cluster)
- [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh)
- [scripts/setup/upgrade-lab/upgrade-control-plane.sh](../../scripts/setup/upgrade-lab/upgrade-control-plane.sh)
- [scripts/setup/upgrade-lab/upgrade-nodegroup.sh](../../scripts/setup/upgrade-lab/upgrade-nodegroup.sh)
- [scripts/setup/upgrade-lab/validate-post-upgrade.sh](../../scripts/setup/upgrade-lab/validate-post-upgrade.sh)
