# Lab 1.4 — Change Replication Factor

| Field              | Value                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| Lab ID             | `1.4`                                                                                           |
| Section            | Scaling & Capacity                                                                              |
| Run after          | **[Lab 2.2](../02-maintenance-and-upgrade/02-upgrade-ako.md)** (AKO 4.4.0+)                     |
| Cluster            | `my-cluster`                                                                                    |
| Aerospike cluster  | `aerocluster`                                                                                   |
| AKO min version    | **4.4.0**                                                                                       |
| Aerospike baseline | 3-node on per-AZ baseline pools (device storage default; same as Lab 1.1 / 2.2), RF=2           |
| Deploy path        | both                                                                                            |
| Duration           | ~15 min                                                                                         |
| Validation status  | `draft`                                                                                         |
| Official docs      | [Replication factor](https://aerospike.com/docs/kubernetes/manage/configure/replication-factor) |

## Takeaway

For AP namespaces, AKO **4.4.0+** applies `replication-factor` changes dynamically — **no rolling restart** — when `enableDynamicConfigUpdate: true`. Scale **up and down** by changing **only** RF for **one** namespace per apply.

## Prerequisites

- **Lab 2.2 complete** — AKO at 4.4.0 or later
- Aerospike Database 6.0+
- AP namespace only (not SC)

## Node requirements

| Item     | Value                                                                                                                               |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Instance | `${NODE_TYPE}` × 4 on baseline pool (EKS `i8g.2xlarge` / GKE `n2-highmem-8`; `${NODEGROUP_NAME}-<zone>` or `${KARPENTER_NODEPOOL_NAME}-<zone>`; ≥3 required for dim cluster) |
| Reset    | **Light** (database only — keeps baseline pool)                                                                                     |

## Phase 0 — Prepare lab

```bash
./scripts/labs/prepare-lab.sh 1.4
```

**Expected:** Light reset tears down any existing Aerospike cluster; baseline pool remains; 4× `${NODE_TYPE}` Ready with `node-pool=baseline`.

If continuing directly from **Lab 2.2** with the dim cluster still Running and RF=2, skip the reset:

```bash
./scripts/labs/prepare-lab.sh 1.4 --skip-reset
```

## Starting state

```bash
kubectl get csv -n operators
# or
helm list -n operators
```

**Pass:** AKO version ≥ 4.4.0.

## Deploy baseline

Same cluster baseline as Lab 1.1 / 2.2 (RF=2 in namespace `test`):

```bash
./scripts/labs/deploy-cluster.sh           # Path A
# or: ./scripts/labs/deploy-dim-cluster.sh   # in-memory

./scripts/labs/deploy-cluster-helm.sh      # Path B
```

**Expected:** 3 pods Running on nodes with `node-pool=baseline`; RF=2 in CR status.

Skip this section if you used `--skip-reset` and the cluster from Lab 2.2 is already Running with RF=2.

## Steps

### Path A — kubectl

1. Confirm RF=2 (CR and Aerospike runtime):
  ```bash
   kubectl -n aerospike describe aerospikecluster aerocluster | grep -i replication
   kubectl run -it --rm aerospike-tool-rf -n aerospike --restart=Never \
     --image=aerospike/aerospike-tools:latest -- \
     asadm -h aerocluster -U admin -P admin123 -e "show config like replication-factor"
  ```
   **Pass:** CR shows RF=2; all nodes report `replication-factor 2`.
2. Apply **only** RF change (2 → 3) — device storage (default) or in-memory (`--dim`):

  **Device storage (default):**
  ```bash
   kubectl apply -f manifests/disk-replication-factor-rf3.yaml
  ```

  **In-memory (`CLUSTER_STORAGE=dim` or after `prepare-lab.sh 1.4 --dim`):**
  ```bash
   kubectl apply -f manifests/dim-replication-factor-rf3.yaml
  ```
   **Expected:** No pod rolling restart; operator reconciles config.
3. Verify RF=3 in CR status and on nodes.
4. Scale down — reapply the baseline manifest (RF 3 → 2):
  ```bash
   ./scripts/labs/deploy-cluster.sh
  ```
   **Expected:** RF drops to 2 immediately; no pod rolling restart.
5. Verify RF=2 in CR status and on nodes (same pods as before step 2).

### Path B — Helm

Baseline (if not already deployed):

```bash
./scripts/labs/deploy-cluster-helm.sh
```

RF change (2 → 3) — chart `--version` matches installed AKO (see [Lab 2.3 Helm chart version](../02-maintenance-and-upgrade/03-on-demand-operations.md#helm-chart-version-path-b)):

**Device storage (default):**
```bash
source scripts/env/workshop.env
source scripts/lib/common.sh
load_env
helm upgrade aerocluster aerospike/aerospike-cluster \
  -n aerospike \
  -f helm/base-disk-cluster-values.yaml \
  -f helm/overlay-disk-replication-factor-rf3-values.yaml \
  --version="$(resolve_cluster_helm_chart_version)"
```

**In-memory:**
```bash
source scripts/env/workshop.env
source scripts/lib/common.sh
load_env
helm upgrade aerocluster aerospike/aerospike-cluster \
  -n aerospike \
  -f helm/base-dim-cluster-values.yaml \
  -f helm/overlay-dim-replication-factor-rf3-values.yaml \
  --version="$(resolve_cluster_helm_chart_version)"
```

Scale down — reapply baseline (RF 3 → 2):

```bash
./scripts/labs/deploy-cluster-helm.sh
```

**Expected:** RF drops to 2 immediately; no pod rolling restart.

## Verify (pass/fail)

```bash
./scripts/labs/lab-nodes.sh 1.4 validate
```

1. After step 3 (RF=3): CR status shows RF=3 for namespace `test`; all nodes report `replication-factor 3`.
2. After scale down: CR status shows RF=2 for namespace `test`; all nodes report `replication-factor 2`.
3. Pods remain `Running` throughout (same pod names/ages as before the RF changes).
4. asadm (after scale down):
  ```bash
   kubectl run -it --rm aerospike-tool -n aerospike --restart=Never \
     --image=aerospike/aerospike-tools:latest -- \
     asadm -h aerocluster -U admin -P admin123 -e "show config like replication-factor"
  ```
   **Pass:** All nodes report `replication-factor 2`.

## Constraints

| Rule          | Detail                                 |
| ------------- | -------------------------------------- |
| Change scope  | Only `replication-factor` in one apply |
| Namespaces    | One namespace per update               |
| Not supported | SC namespaces; combined config changes |

## Troubleshooting

- Mixed RF during node restart → allow AKO to converge
- Reconciler stuck → see [dynamic config docs](https://aerospike.com/docs/kubernetes/manage/configure/dynamic-config)

## Curriculum note

Listed in Section 1 but **run after Lab 2.2** despite section number.

## Teardown / handoff

Continue to [Lab 2.3](../02-maintenance-and-upgrade/03-on-demand-operations.md). Run `./scripts/reset-cluster.sh --yes` only when done for the day or before a hard wipe.

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Baseline (3 nodes, RF=2):**
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (default) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)
- **Change RF to 3:**
  - Path A: [manifests/disk-replication-factor-rf3.yaml](../../manifests/disk-replication-factor-rf3.yaml) (default) · [manifests/dim-replication-factor-rf3.yaml](../../manifests/dim-replication-factor-rf3.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) + [helm/overlay-disk-replication-factor-rf3-values.yaml](../../helm/overlay-disk-replication-factor-rf3-values.yaml) (default) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) + [helm/overlay-dim-replication-factor-rf3-values.yaml](../../helm/overlay-dim-replication-factor-rf3-values.yaml) (`--dim`)

## References

- [Replication factor](https://aerospike.com/docs/kubernetes/manage/configure/replication-factor)
- [Release notes KO-485](https://aerospike.com/docs/kubernetes/release/release-notes/)

