# Lab 2.6 — K8s Control Plane Upgrade

| Field | Value |
|-------|-------|
| Lab ID | `2.6` |
| Section | Maintenance & Upgrade |
| EKS cluster | **`my-cluster-k8s-upgrade` only** |
| K8s upgrade | `1.31 → 1.32` (from `UPGRADE_LAB_K8S_VERSION_*` in workshop.env) |
| Aerospike baseline | 3-node device storage on local-ssd **Running before upgrade** (`--dim` for in-memory) |
| Node provisioning | eksctl MNG only (upgrade-lab cluster) |
| Duration | ~45–60 min (mostly waiting) |
| Validation status | `draft` |
| Official docs | [EKS cluster upgrade](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html) |

## Takeaway

A live Aerospike cluster keeps running during an EKS control plane upgrade — but you must still upgrade the node group afterward to align kubelet versions.

**On GKE:** the same scripts call `gcloud container clusters upgrade` (control plane, then node pool). Versions look like `1.32.x-gke.y`; prefix match against `UPGRADE_LAB_K8S_VERSION_TARGET` is enough.

EKS upgrade is **two phases**:

1. **Control plane** — API server, etcd, and core controllers move to the target Kubernetes version. Worker nodes and Aerospike pods keep running on the old kubelet.
2. **Node group** — EKS rolls each worker (launch new → drain → cordon → terminate old). This is where [Lab 2.5](05-k8s-node-maintenance.md) concepts apply: safe eviction during migration, local-ssd PVC lifecycle, and pod reschedule onto fresh instance store.

## Continuity from Lab 2.5

Lab 2.5 demonstrated **manual** worker maintenance (`kubectl drain`, safe eviction webhook, node termination, PVC cleanup). Lab 2.6 shows the **same worker-level mechanics** triggered automatically by EKS during a managed node group upgrade.

The upgrade-lab cluster is separate from `my-cluster`. Safe eviction enabled during Lab 2.5 on the main cluster does **not** carry over — verify or enable it on upgrade-lab before the node group phase (see [Verify safe pod eviction](#verify-safe-pod-eviction-recommended)).

## Prerequisites

- Upgrade-lab cluster created during Section 0 step **0.7**, or pre-staged before this lab (see **Phase 0** below)
- Lab 2.5 complete (conceptual — worker drain, migration, local storage)
- `./scripts/lib/kubecontext.sh show` → upgrade-lab cluster before every command in this lab

## How EKS upgrade affects Aerospike

| Phase | What EKS changes | Aerospike impact |
|-------|------------------|------------------|
| Control plane | API server, etcd, scheduler to target K8s | Pods stay `Running`; brief `kubectl` API delays possible |
| Node group (default strategy) | Rolling worker replacement — new kubelet + AMI | Per-node drain → CR may go `InProgress`; local-ssd pods restart on new nodes |

**Do not scale down Aerospike** during either phase. Let EKS drain handle pod movement — the same production guidance as Lab 2.5, but orchestrated by the managed node group instead of manual `kubectl drain`.

Cross-reference: [Lab 2.5 — three-layer maintenance model](05-k8s-node-maintenance.md#takeaway).

> **`--dim` path:** In-memory clusters have no local-ssd PVC pinning. Abbreviate Phase 4 PVC observe steps; migration during node replacement is faster.

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
./scripts/lib/kubecontext.sh show
./scripts/labs/prepare-lab.sh 2.6 --skip-reset   # validate only if already staged
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" --query cluster.version
```

**Pass:** Context is `my-cluster-k8s-upgrade`; 3/3 `Running`; EKS version `${UPGRADE_LAB_K8S_VERSION_START}` (default `1.31`).

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

Upgrade-lab installs AKO via OLM ([`01-install-ako.sh`](../../scripts/setup/upgrade-lab/01-install-ako.sh)), which does **not** enable safe pod eviction by default. During the node group phase, EKS drains each worker — the same eviction path Lab 2.5 demonstrated.

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
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" \
  --query 'cluster.{version:version,status:status}' --output table
kubectl get nodes -o custom-columns=NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,READY:.status.conditions[-1].type
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
aws eks describe-addon-versions --kubernetes-version "${UPGRADE_LAB_K8S_VERSION_TARGET}" \
  --addon-name vpc-cni --query 'addons[0].addonVersions[0].compatibilities' --output table
```

**Pass:** Cluster `ACTIVE` at `${UPGRADE_LAB_K8S_VERSION_START}`; 3/3 Aerospike `Running`; CR `Completed`; node kubelets match the start version.

> **Production note:** Scan for deprecated APIs (e.g. [pluto](https://github.com/FairwindsOps/pluto)) before upgrading. Not required in the workshop.

## Phase 3 — Control plane upgrade

Use **two terminals**. The control plane upgrade does **not** restart Aerospike pods — workers stay on the old kubelet until Phase 4.

### 3a — Start upgrade (Terminal A)

```bash
./scripts/setup/upgrade-lab/upgrade-control-plane.sh
```

**What runs:**

1. `eksctl upgrade cluster --version ${UPGRADE_LAB_K8S_VERSION_TARGET} --approve`
2. AWS upgrades control plane components (API server, etcd, core controllers)
3. `aws eks wait cluster-active` (~10–20 min)

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
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" \
  --query 'cluster.{version:version,status:status,update:update}' --output table
```

**Pass during CP upgrade:**

- 3/3 pods stay `Running`
- CR stays `Completed` (brief `InProgress` is unusual but acceptable)
- Workload TPS may dip during API blips but should recover
- Terminal A prints `Control plane upgrade complete.` when `cluster-active` returns

## Phase 4 — Node group upgrade

After the control plane reaches the target version, upgrade workers so kubelet and AMI align. **First Aerospike pod restarts happen here**, not during Phase 3.

### 4a — Start node group upgrade (Terminal A)

```bash
./scripts/setup/upgrade-lab/upgrade-nodegroup.sh
```

**What EKS does** ([managed node update behavior](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html)):

1. Selects node(s) to upgrade (parallelism per node group `updateConfig`)
2. **Default strategy:** launches replacement node(s) first, then drains old node(s)
3. For each old node: respect PDBs → evict pods → cordon → wait 60s → terminate via Auto Scaling Group
4. Repeats until all nodes run the target kubelet/AMI
5. Scale-down phase returns the ASG to the original desired count

The script runs `eksctl upgrade nodegroup` then `aws eks wait nodegroup-active` (~15–25 min for 3 nodes).

### 4b — Observe during rolling worker upgrade (Terminal B)

```bash
# Node replacement progress
kubectl get nodes -l "alpha.eksctl.io/nodegroup-name=${UPGRADE_LAB_NODEGROUP_NAME}" -o wide -w
```

Ctrl+C once all nodes show the target kubelet version. Then watch Aerospike:

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

**Pass during nodegroup upgrade:**

- Nodes transition to target kubelet version one-by-one
- Aerospike ends at 3/3 `Running` and CR `Completed`
- Workload TPS recovers after each pod move
- Terminal A prints `Nodegroup upgrade complete.`

## Phase 5 — Post-upgrade validation

```bash
./scripts/setup/upgrade-lab/validate-post-upgrade.sh
```

Additional manual checks:

```bash
aws eks describe-cluster --name "${UPGRADE_LAB_CLUSTER_NAME}" --query cluster.version
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl run -it --rm aerospike-tool-verify -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "info"
```

**Pass:** EKS `${UPGRADE_LAB_K8S_VERSION_TARGET}`; all kubelets on target minor; 3/3 `Running`; CR `Completed`; `cluster_size=3` in asadm output.

## Verify (pass/fail)

| Check | Expected |
|-------|----------|
| EKS cluster version | `${UPGRADE_LAB_K8S_VERSION_TARGET}` |
| Node kubelet versions | Target minor on all workers |
| Aerospike pods | 3/3 `Running` |
| CR phase | `Completed` |
| Cluster membership | `cluster_size=3` via asadm |

## Observe

- EKS console upgrade progress (control plane, then node group)
- **No unplanned Aerospike restarts during control plane upgrade** (Phase 3)
- Pod restarts and possible migration during **node group upgrade** (Phase 4)
- Safe eviction may delay drain while migration is active (Lab 2.5 webhook behavior)
- Continuous workload TPS through both phases (Terminal B)
- local-ssd PVC cleanup and pod reschedule on new nodes (device storage)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `load-data.sh` hits wrong cluster | Use `--upgrade-lab`; verify with `./scripts/lib/kubecontext.sh show` |
| CP upgrade stuck in `UPDATING` | `aws eks describe-cluster … --query cluster.update`; wait or check EKS console |
| Nodegroup upgrade `PodEvictionFailure` | Safe eviction blocking during migration — wait for CR `Completed`; never `--force` in demo |
| Pods `Pending` after node replace | Check local-ssd PVs + cleanup controller ([Lab 0.5](../00-environment-setup/05-storage-layer.md)); wait ~60s |
| K8s version already at TARGET | Cluster upgraded in a prior run — recreate upgrade-lab or adjust `UPGRADE_LAB_K8S_VERSION_*` |
| Wrong kubectl context | `./scripts/lib/kubecontext.sh upgrade-lab` |
| Migration completes too fast to observe | Increase data load (`MIGRATION_LOAD_RECORDS`) in Phase 1 |
| No webhook during nodegroup drain | Enable safe pod eviction on upgrade-lab (see above) |

## Not covered here

- Manual worker drain → [Lab 2.5](05-k8s-node-maintenance.md)
- AKO upgrade → [Lab 2.2](02-upgrade-ako.md)

## Teardown

After Lab 2.6 demo, if continuing with main-cluster labs:

```bash
./scripts/cleanup-lab.sh --upgrade-lab-only --yes
./scripts/lib/kubecontext.sh main
```

End of full training (delete **both** clusters in parallel):

```bash
./scripts/cleanup-lab.sh --yes
```

Use `--sequential` to delete one cluster at a time.

## Workshop artifacts

- EKS reference config: [clusters/upgrade-lab-cluster.yaml](../../clusters/upgrade-lab-cluster.yaml)
- **Baseline Aerospike cluster (3 nodes):**
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (default) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)

## References

- [eksctl cluster upgrade](https://docs.aws.amazon.com/eks/latest/eksctl/cluster-upgrade.html)
- [EKS managed node update behavior](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-update-behavior.html)
- [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh)
- [scripts/setup/upgrade-lab/upgrade-control-plane.sh](../../scripts/setup/upgrade-lab/upgrade-control-plane.sh)
- [scripts/setup/upgrade-lab/upgrade-nodegroup.sh](../../scripts/setup/upgrade-lab/upgrade-nodegroup.sh)
- [scripts/setup/upgrade-lab/validate-post-upgrade.sh](../../scripts/setup/upgrade-lab/validate-post-upgrade.sh)
