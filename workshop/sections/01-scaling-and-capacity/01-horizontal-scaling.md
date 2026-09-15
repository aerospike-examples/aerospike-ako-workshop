# Lab 1.1 — Horizontal Scaling

| Field              | Value                                                                     |
| ------------------ | ------------------------------------------------------------------------- |
| Lab ID             | `1.1`                                                                     |
| Section            | Scaling & Capacity                                                        |
| Cluster            | `my-cluster`                                                              |
| Aerospike cluster  | `aerocluster`                                                             |
| AKO min version    | `4.2.0`                                                                   |
| Aerospike baseline | 3-node device storage on local-ssd (default; `--dim` for in-memory)     |
| Deploy path        | both                                                                      |
| Node provisioning  | both                                                                      |
| Duration           | ~30–45 min (includes data load)                                           |
| Validation status  | `draft`                                                                   |
| Official docs      | [Scaling](https://aerospike.com/docs/kubernetes/manage/configure/scaling) |

## Takeaway

`spec.size` (Path A) / `replicas` (Path B) controls pod count; AKO adds or removes pods to match.

## Prerequisites

- Section 0 complete
- Secrets deployed

## Node requirements

| Item | Value |
|------|-------|
| Instance | `${NODE_TYPE}` × 4 (EKS `i8g.2xlarge` / GKE `n2-highmem-8`) |
| Reset | **Full** |
| Nodegroups | 2 × `${NODEGROUP_NAME}-<zone>` (eksctl / GKE) or 2 × `${KARPENTER_NODEPOOL_NAME}-<zone>` (Karpenter) |
| Scale-up | 5 nodes temporarily (3+2 across zones) |

## Phase 0 — Prepare lab

```bash
./scripts/labs/prepare-lab.sh 1.1
```

**Expected:** 4 workload nodes `Ready` across `${CLUSTER_ZONES}` (`${NODE_TYPE}`); nvme-bootstrap Ready on those nodes.

## Deploy baseline

```bash
./scripts/labs/deploy-cluster.sh              # Path A (default storage from workshop.env)
# or: ./scripts/labs/deploy-dim-cluster.sh     # explicit in-memory
# or: kubectl apply -f manifests/disk-cluster.yaml

./scripts/labs/deploy-cluster-helm.sh         # Path B
# or: ./scripts/labs/deploy-dim-cluster-helm.sh
```

**Expected:** 3 pods Running; CR phase `Completed`.

## Load data (before scaling)

Load **5M records × 1 KB** so scale-up rebalance and scale-down migration are visible (~5–15 min):

```bash
./scripts/labs/load-data.sh
```

Verify with `asadm -e "info"` (non-zero objects in namespace `test`).

## Background

Horizontal scaling changes cluster capacity by adjusting the number of Aerospike pods. AKO updates the StatefulSet and manages rack distribution when racks are configured.

The cluster uses `multiPodPerHost: false`, so each Aerospike pod requires its own Kubernetes node. Scaling Aerospike 3→5 needs 5 nodes. The workshop environment does not install Cluster Autoscaler — on the eksctl / GKE node-pool path you scale the node group before applying the scale-up manifest (Karpenter provisions nodes automatically; see **Observe** below).

## Steps

### Connect to the cluster (asadm)

```bash
kubectl run -it --rm aerospike-tool -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show stat like cluster_size"
```

**Expected:** All nodes report `cluster_size` **3**.

### Manual scale nodes before Aerospike scale-up

Skip on Karpenter if you prefer to watch auto-provision on Pending pods (see **Observe**).

```bash
./scripts/labs/lab-nodes.sh 1.1 ensure --scale-up
./scripts/labs/lab-nodes.sh 1.1 validate --scale-up
```

**Expected:** 5 nodes `Ready` before applying the scale-up manifest.

### Path A — kubectl

1. Scale up Aerospike to 5 nodes:
   ```bash
   kubectl apply -f manifests/disk-cluster-scale-5.yaml
   kubectl -n aerospike get pods -w
   ```
   **Expected:** 5 pods reach `Running`; CR `Completed`; observe data rebalancing onto new nodes (`asadm -e "show stat like migrate"`).
2. Scale down to 3 — re-apply the baseline manifest:
   ```bash
   kubectl apply -f manifests/disk-cluster.yaml
   kubectl -n aerospike get pods -w
   ```
   **Expected:** AKO waits for migration before pods terminate; CR may show `InProgress`; then 3 pods remain and CR `Completed`.

### Path B — Helm

1. Scale up Aerospike to 5 nodes:

   ```bash
   source scripts/env/workshop.env
   source scripts/lib/common.sh
   load_env
   helm upgrade aerocluster aerospike/aerospike-cluster \
     -n aerospike \
     -f helm/base-disk-cluster-values.yaml \
     -f helm/overlay-cluster-scale-5-values.yaml \
     --version="$(resolve_cluster_helm_chart_version)"
   kubectl -n aerospike get pods -w
   ```

   **Expected:** 5 pods reach `Running`; release status `deployed`; observe data rebalancing onto new nodes.

2. Scale down to 3 — re-apply the baseline values:

   ```bash
   helm upgrade aerocluster aerospike/aerospike-cluster \
     -n aerospike -f helm/base-disk-cluster-values.yaml \
     --version="$(resolve_cluster_helm_chart_version)"
   kubectl -n aerospike get pods -w
   ```

   **Expected:** AKO waits for migration before pods terminate; then 3 pods remain; release status `deployed`.

## Verify (pass/fail)

```bash
./scripts/labs/lab-nodes.sh 1.1 validate
kubectl -n aerospike get pods -l aerospike.com/cr=aerocluster --no-headers | wc -l
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}'
```

**Pass:** Pod count = 3; phase `Completed`.

## Observe

- New pods created with sequential index
- Scale-up: partitions rebalance onto new nodes (`asadm -e "show stat like migrate"`)
- Scale-down: AKO waits for records to migrate off departing nodes before pods terminate (empty cluster scale-down is immediate)

### Karpenter path (`NODE_PROVISIONING=karpenter`)

```bash
kubectl get nodeclaims,nodes          # snapshot (both types)
kubectl get nodeclaims -w             # live watch — `-w` accepts one resource type only
```

**Expected:** Pending pods trigger new NodeClaims; nodes join with label `workshop.aerospike.com/node-pool=baseline` (also `workshop.aerospike.com/workload=aerospike` on Karpenter NodePools).

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Pods `Pending`; insufficient memory/ports | Run `lab-nodes.sh 1.1 ensure --scale-up`; `kubectl describe pod <name>` |
| Scale-down stuck | Check CR events; watch migration in `asadm`; wait for AKO to finish migrating records off removed nodes |

## Not covered here

Vertical scaling + rack revision → [Lab 1.2](02-rack-awareness-vertical-revision.md)

## Teardown / handoff

Next lab: `./scripts/labs/prepare-lab.sh 1.2` (light reset — keeps nodes; **scales pool back to 4**).

Or `./scripts/reset-cluster.sh --yes` if done for the day.

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Baseline (3 nodes):**
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (default) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)
- **Scale to 5 nodes:**
  - Path A: [manifests/disk-cluster-scale-5.yaml](../../manifests/disk-cluster-scale-5.yaml) (default) · [manifests/dim-cluster-scale-5.yaml](../../manifests/dim-cluster-scale-5.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-cluster-scale-5-values.yaml](../../helm/overlay-cluster-scale-5-values.yaml)

## References

- [Scaling](https://aerospike.com/docs/kubernetes/manage/configure/scaling)
- [scripts/labs/load-data.sh](../../scripts/labs/load-data.sh)
