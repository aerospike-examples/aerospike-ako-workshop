# Lab 0.2 — EKS Cluster Bootstrap

| Field | Value |
|-------|-------|
| Lab ID | `0.2` |
| Section | Environment Setup |
| EKS cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| Kubernetes | `${K8S_VERSION}` (default 1.33) |
| Node provisioning | eksctl (this guide) |
| Duration | ~15–30 min |
| Validation status | `draft` |

**GKE path:** this guide is EKS-only. When `CLOUD_PROVIDER=gke`, use [02-gke-cluster.md](02-gke-cluster.md) (`./scripts/setup/02-bootstrap-gke.sh`). Running this script with a GKE env file fails on purpose.

## Takeaway

EKS control plane in `us-east-1` spanning two availability zones. **Per-AZ workload pools** `${NODEGROUP_NAME}-<zone>` (2× `${MIN_NODES_PER_ZONE}` nodes each, `${NODE_TYPE}`) are created in step **0.2-nodes** before AKO install. Lab 1.1 re-ensures the same pools after full reset.

## Prerequisites

- Lab 0.1 complete
- EC2 key pair `${SSH_PUBLIC_KEY}` exists in `${AWS_REGION}`
- Capacity across `AWS_ZONES` (default: `us-east-1c`, `us-east-1d`) for `${NODE_COUNT}`× `${NODE_TYPE}` now and `${NODE_COUNT}`× `${NODE_TYPE_VERTICAL}` in Lab 1.2 — G/VT quota of at least `NODE_COUNT × 2`, pre-flighted in Lab 0.1

## Starting state

No EKS cluster, or existing cluster you intend to reuse.

## Steps

1. Source environment:

   ```bash
   source scripts/env/workshop.env
   ```

2. Create cluster (control plane only):

   ```bash
   ./scripts/setup/02-bootstrap-eks.sh
   ```

   The script renders an eksctl ClusterConfig from `CLUSTER_NAME`, `AWS_REGION`, `K8S_VERSION`, and `AWS_ZONES`, runs `eksctl create cluster -f` against it, and creates namespace `${NAMESPACE}`. The OIDC provider is associated later, in step 0.5.

   **Expected:** eksctl completes; `kubectl get nodes` shows **no** workload nodes yet.

3. Create workload nodepool (step 0.2-nodes):

   ```bash
   ./scripts/setup/02-ensure-workload-nodepool.sh
   ```

   This is a thin wrapper — it execs `./scripts/labs/lab-nodes.sh 1.1 ensure`, so the same per-AZ pools are created here and re-ensured by `prepare-lab.sh 1.1` later. Nodes are labelled `workshop.aerospike.com/node-pool=baseline`, which is what step 0.6 validation counts.

   **Expected:** `${NODE_COUNT}`× `${NODE_TYPE}` nodes Ready across `${AWS_ZONES}` (≥ `${MIN_NODES_PER_ZONE}` per zone).

4. Confirm namespace:

   ```bash
   kubectl get namespace aerospike
   ```

   **Expected:** Namespace `aerospike` exists.

## Verify (pass/fail)

```bash
kubectl get nodes -o wide
```

**Pass:** EKS cluster reachable; `${NODE_COUNT}` workload nodes Ready (per-AZ nodegroups `${NODEGROUP_NAME}-*`, labelled `workshop.aerospike.com/node-pool=baseline`).

Reference config: [clusters/main-cluster.yaml](../../clusters/main-cluster.yaml) (documentation only — the script renders its own ClusterConfig)

## Observe

- Per-AZ workload nodegroups `${NODEGROUP_NAME}-<zone>` are created in step **0.2-nodes**; Lab 1.1 re-ensures after full reset via `prepare-lab.sh 1.1`
- Vertical scale to `i8g.4xlarge` happens in Lab 1.2

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Key pair not found | Create in EC2 or update `SSH_PUBLIC_KEY` in workshop.env |
| `InsufficientInstanceCapacity` in an AZ | Set `AWS_ZONES` to a pair where both `${NODE_TYPE}` and `${NODE_TYPE_VERTICAL}` pass `./scripts/setup/01b-check-ec2-capacity.sh`, then re-create |
| Nodes never reach `${NODE_COUNT}` | Check G/VT on-demand quota (`01b-check-ec2-capacity.sh`); re-run `02-ensure-workload-nodepool.sh` — it is idempotent |
| `AlreadyExists` on cluster / nodegroup / IAM role | Name taken in the shared account — set a unique `CLUSTER_NAME` |

## Teardown / handoff

Cluster remains running. Proceed to AKO install (0.3). Workload nodes: step 0.2-nodes (or `./scripts/setup/setup-all.sh --step 0.2-nodes`).

**Karpenter path:** see [02-eks-cluster-karpenter.md](02-eks-cluster-karpenter.md) when `NODE_PROVISIONING=karpenter`.
**GKE path:** see [02-gke-cluster.md](02-gke-cluster.md) when `CLOUD_PROVIDER=gke`.

## Workshop artifacts

- EKS reference config: [clusters/main-cluster.yaml](../../clusters/main-cluster.yaml) — documentation only, never applied. [`scripts/setup/02-bootstrap-eks.sh`](../../scripts/setup/02-bootstrap-eks.sh) renders an equivalent ClusterConfig from `workshop.env` into a temp file and runs `eksctl create cluster -f` (a config file is required because shared accounts need a permissions boundary on the cluster service role).

## References

- [`scripts/setup/02-bootstrap-eks.sh`](../../scripts/setup/02-bootstrap-eks.sh)
- [Amazon EKS getting started](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html)
