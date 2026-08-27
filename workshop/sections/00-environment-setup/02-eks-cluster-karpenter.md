# Lab 0.2 — EKS Cluster Bootstrap (Karpenter)

| Field | Value |
|-------|-------|
| Lab ID | `0.2` |
| Section | Environment Setup |
| EKS cluster | `my-cluster` |
| Node provisioning | **Karpenter** |
| Duration | ~40 min |
| Validation status | `draft` |

## Takeaway

A Karpenter-managed EKS cluster with a **system** managed nodegroup for the controller. **Per-AZ workload NodePools** `${KARPENTER_NODEPOOL_NAME}-<zone>` (4× `i8g.2xlarge` total) are created in step **0.2-nodes** before AKO install. Lab 1.2 Phase 2 adds **`${KARPENTER_NODEPOOL_VERTICAL_NAME}-<zone>`** (vertical pool) alongside the baseline pools.

## Prerequisites

- Lab 0.1 complete
- EC2 key pair `${SSH_PUBLIC_KEY}` exists in `${AWS_REGION}`
- Quota for **4–8×** `i8g.2xlarge` plus 2× `t3.large` system nodes
- Quota for **4–8×** `i8g.4xlarge` during Lab 1.2 Phase 2 (may run **8 nodes** total with idle baseline pool)
- Helm on the client (controller install) — `01-validate-client.sh` checks that `helm version` runs when `NODE_PROVISIONING=karpenter`, but does not assert a minimum version; Helm 3.12+ is recommended

## Starting state

`NODE_PROVISIONING=karpenter` in [workshop.env.example](../../scripts/env/workshop.env.example).

## Steps

1. Source environment:

   ```bash
   source scripts/env/workshop.env
   export NODE_PROVISIONING=karpenter
   ```

2. Create cluster and install Karpenter controller:

   ```bash
   ./scripts/setup/02-bootstrap-eks.sh
   ```

   Bootstrap applies [main-cluster-karpenter.yaml](../../clusters/main-cluster-karpenter.yaml) through `envsubst`, then calls [`karpenter/00-install-controller.sh`](../../scripts/setup/karpenter/00-install-controller.sh) directly, which installs the controller from the Helm OCI chart `public.ecr.aws/karpenter/karpenter` at `${KARPENTER_VERSION}` (default **1.11.2**). [`karpenter/setup-all-karpenter.sh`](../../scripts/setup/karpenter/setup-all-karpenter.sh) exists for standalone use but is **not** part of this step.

   **Expected:**
   - eksctl creates cluster + `${KARPENTER_SYSTEM_NODEGROUP}` (`${KARPENTER_SYSTEM_NODE_COUNT}`× `${KARPENTER_SYSTEM_NODE_TYPE}`, `CriticalAddonsOnly` taint) in the **first AZ only** (`${NODE_ZONE_A}`)
   - CoreDNS and metrics-server schedule on system nodes via declarative addon config in [main-cluster-karpenter.yaml](../../clusters/main-cluster-karpenter.yaml)
   - Karpenter controller Running in `${KARPENTER_NAMESPACE}` (default `karpenter`)
   - **No** workload nodes yet (system nodes only)

3. Create workload NodePool (step 0.2-nodes):

   ```bash
   ./scripts/setup/02-ensure-workload-nodepool.sh
   ```

   This wrapper execs `./scripts/labs/lab-nodes.sh 1.1 ensure`, which applies the EC2NodeClass and per-AZ NodePools, schedules bootstrap Deployments to force provisioning, and waits up to 900s (15 min) for nodes to join.

   **Expected:** `${NODE_COUNT}`× `${NODE_TYPE}` workload nodes Ready across `${AWS_ZONES}` (≥ `${MIN_NODES_PER_ZONE}` per zone).

4. Confirm controller:

   ```bash
   kubectl -n karpenter get deploy karpenter
   kubectl get nodes
   ```

   **Expected:** Karpenter Ready; `${NODE_COUNT}` workload nodes plus system nodes.

5. Confirm namespace:

   ```bash
   kubectl get namespace aerospike
   ```

## Verify (pass/fail)

```bash
kubectl -n karpenter get deploy karpenter
kubectl get nodes
kubectl get nodepool -o custom-columns=NAME:.metadata.name,POLICY:.spec.disruption.consolidationPolicy,AFTER:.spec.disruption.consolidateAfter
kubectl get nodes -l workshop.aerospike.com/workload=aerospike -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,POOL:.metadata.labels.karpenter\\.sh/nodepool
```

**Pass:** Karpenter Ready; `${NODE_COUNT}` workload nodes Ready (per-AZ NodePools `${KARPENTER_NODEPOOL_NAME}-*`); each node's `karpenter.sh/nodepool` matches its zone pool name.

The `POLICY` / `AFTER` columns show the applied Karpenter API values, so with the workshop `Off` alias expect `WhenEmpty` and `720h` — never a literal `Off`. Default `workshop.env` ships `KARPENTER_CONSOLIDATION=WhenEmpty`, whose NodePool YAML uses `consolidateAfter: 30m`.

Reference config: [clusters/main-cluster-karpenter.yaml](../../clusters/main-cluster-karpenter.yaml)

## Observe

- System nodes carry taint `CriticalAddonsOnly=true:NoSchedule` — OLM and AKO schedule on untainted workload nodes (they need `i8g` instance types anyway)
- Per-AZ workload NodePools applied in step **0.2-nodes**; Lab 1.1 re-ensures after full reset via `prepare-lab.sh 1.1`

## Recover partial NodePool state

If NodePool apply failed (e.g. `consolidationPolicy: Off`) or bootstrap pods show zone mismatches, reset and re-apply:

```bash
./scripts/setup/karpenter/01-reset-workload-nodepools.sh
./scripts/setup/02-ensure-workload-nodepool.sh
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Bootstrap stuck at `0/N` nodes; bootstrap pods `Pending`; NodeClaim events `InsufficientCapacityError` / `InsufficientInstanceCapacity` in one AZ | AWS on-demand capacity for `${NODE_TYPE}` is exhausted in that AZ — wait/retry (script waits up to 15 min), or `./scripts/setup/karpenter/01-reset-workload-nodepools.sh` then re-run `02-ensure-workload-nodepool.sh`. If persistent, set `AWS_ZONES` in `workshop.env` to a pair where `./scripts/setup/01b-check-ec2-capacity.sh` passes for **both** `${NODE_TYPE}` and `${NODE_TYPE_VERTICAL}`, then rebuild the cluster |
| Bootstrap appears stuck; terminal shows JSON in a pager (`less`) | AWS CLI pager blocked the script — workshop scripts disable it via `AWS_PAGER=""` in `load_env()`; or run `export AWS_PAGER=""` before bootstrap |
| Controller Pending | Ensure system MNG exists; Karpenter Helm values use `nodeSelector: role=system` + `CriticalAddonsOnly` toleration |
| No NodeClaims in Lab 1.1 | Check controller logs; verify subnet/SG discovery tags |
| Bootstrap pod zone mismatch (`us-east-1c` vs `us-east-1d`) | Partial NodePool state — run [01-reset-workload-nodepools.sh](../../scripts/setup/karpenter/01-reset-workload-nodepools.sh), then re-run `02-ensure-workload-nodepool.sh`; verify each NodePool's zone requirement |
| NodeClaims `Launched` but nodes never join (`Registered=Unknown`, `Node not registered with cluster`) | `KarpenterNodeRole-${CLUSTER_NAME}` missing from EKS access entries — re-run `./scripts/setup/karpenter/00-install-controller.sh` (creates `EC2_LINUX` access entry), or: `aws eks create-access-entry --cluster-name ${CLUSTER_NAME} --principal-arn arn:aws:iam::<account>:role/KarpenterNodeRole-${CLUSTER_NAME} --type EC2_LINUX` |
| NodeClaims `Launched` but `Registered=Unknown`; `KarpenterNodeRole-${CLUSTER_NAME}` has no attached policies | Re-run `./scripts/setup/karpenter/00-install-controller.sh` (idempotently attaches worker/CNI/ECR/SSM policies), or manually attach those four AWS managed policies, then reset NodePools and re-run `02-ensure-workload-nodepool.sh` |
| Helm install error: `ServiceAccount "karpenter" ... exists and cannot be imported ... managed-by" must equal "Helm"` | Cluster/IAM already created by a prior run of this step; `00-install-controller.sh` sets `serviceAccount.create=false` so Helm reuses the eksctl-created IRSA ServiceAccount instead of conflicting with it. Just re-run `./scripts/setup/karpenter/00-install-controller.sh` — do not re-run cluster creation |
| Karpenter pods `CrashLoopBackOff` with DNS lookup errors to `ec2.<region>.amazonaws.com`, and `coredns` addon shows `DEGRADED`/pods `Pending` | CoreDNS must tolerate `CriticalAddonsOnly` on system nodes — declarative config is in `main-cluster-karpenter.yaml` for **new** clusters. On **existing** clusters with the old `role=system` taint, rebuild the cluster or one-time: `aws eks update-addon --cluster-name ${CLUSTER_NAME} --addon-name coredns --resolve-conflicts OVERWRITE --configuration-values '{"tolerations":[{"key":"CriticalAddonsOnly","operator":"Exists"},{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]}'` then wait for addon active |
| `metrics-server` pods `Pending` / addon shows `DEGRADED` with `untolerated taint` | Same as coredns — use declarative addon config on new clusters; on existing clusters update the metrics-server addon tolerations similarly |
| NodePool apply fails: `consolidationPolicy: Unsupported value: "Off"` | Karpenter 1.11+ only accepts `WhenEmpty` or `WhenEmptyOrUnderutilized`. `Off` is a **workshop alias** in `workshop.env` — `lab-nodes.sh` maps it to `WhenEmpty` + `720h consolidateAfter` at apply time. Reset NodePools and re-run `02-ensure-workload-nodepool.sh` after updating scripts |
| `multi-AZ distribution failed` after `prepare-lab.sh 1.2` (e.g. 1+3 instead of 2+2 on baseline or vertical) | Baseline: re-run `prepare-lab.sh 1.2 --skip-reset` (scripts rebalance per-AZ via NodeClaim termination). Vertical (`i8g.4xlarge`): re-run `lab-nodes.sh 1.2 ensure --vertical`. Or `reset-cluster.sh --yes` then `prepare-lab.sh 1.2` |

## Instructor notes

- Set `KARPENTER_CONSOLIDATION=Off` during class to limit consolidation churn (workshop alias — not a Karpenter API value; scripts apply `WhenEmpty` + `720h consolidateAfter`)
- Lab 2.6 upgrade-lab cluster stays on **eksctl MNG** — not this path
- For cleanest bootstrap, rebuild clusters created before the `CriticalAddonsOnly` system taint change rather than patching addons one-by-one

## Not covered here

eksctl managed nodegroup path → [02-eks-cluster.md](02-eks-cluster.md)

## Workshop artifacts

- EKS cluster config: [clusters/main-cluster-karpenter.yaml](../../clusters/main-cluster-karpenter.yaml) (applied via `envsubst` in bootstrap)
- Karpenter manifests: [scripts/setup/karpenter/01-ec2nodeclass-i8g.yaml](../../scripts/setup/karpenter/01-ec2nodeclass-i8g.yaml), [scripts/setup/karpenter/02-nodepool-aerospike-zone.yaml](../../scripts/setup/karpenter/02-nodepool-aerospike-zone.yaml), [scripts/setup/karpenter/02-nodepool-aerospike-vertical-zone.yaml](../../scripts/setup/karpenter/02-nodepool-aerospike-vertical-zone.yaml)

## References

- [Karpenter on AWS](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- [AKO scaling — Karpenter + local volumes](https://aerospike.com/docs/kubernetes/manage/configure/scaling)
