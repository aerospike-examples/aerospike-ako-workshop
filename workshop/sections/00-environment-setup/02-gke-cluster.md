# Lab 0.2 — GKE Cluster Bootstrap

| Field | Value |
|-------|-------|
| Lab ID | `0.2` |
| Section | Environment Setup |
| Cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| Kubernetes | `${K8S_VERSION}` (default 1.35) |
| Node provisioning | GKE Standard node pools |
| Duration | ~15–30 min |
| Validation status | `draft` |

## Takeaway

Regional **GKE Standard** control plane in `${GCP_REGION}` spanning two zones. A small **system** node pool runs kube-system and AKO. **Per-AZ workload pools** `${NODEGROUP_NAME}-<zone>` (local NVMe block SSDs, `${NODE_TYPE}`) are created in step **0.2-nodes**. Lab 1.1 re-ensures the same pools after full reset.

GKE Autopilot is **not** supported (the nvme-bootstrap DaemonSet needs privileged access to raw local NVMe).

## Prerequisites

- Lab 0.1 complete (`CLOUD_PROVIDER=gke`, copy [`workshop.env.gke.example`](../../scripts/env/workshop.env.gke.example) → `workshop.env`)
- `gcloud` authenticated; `gke-gcloud-auth-plugin` installed; APIs `container.googleapis.com` and `compute.googleapis.com` enabled
- Quota in `${CLUSTER_ZONES}` for `${NODE_COUNT}`× `${NODE_TYPE}` now and `${NODE_COUNT}`× `${NODE_TYPE_VERTICAL}` in Lab 1.2, plus Local SSD (`${GKE_LOCAL_SSD_COUNT}` × 375 GiB per baseline node)

## Starting state

No GKE cluster, or existing cluster you intend to reuse.

## Steps

1. Source environment:

   ```bash
   cp scripts/env/workshop.env.gke.example scripts/env/workshop.env
   # set GCP_PROJECT
   source scripts/env/workshop.env
   ```

2. Create cluster (system pool only):

   ```bash
   ./scripts/setup/02-bootstrap-gke.sh
   ```

   **Expected:** Regional cluster; `kubectl get nodes` shows **system** nodes (`${GKE_SYSTEM_NODE_TYPE}` / default-pool), not Aerospike workload nodes.

3. Create workload node pools (step 0.2-nodes):

   ```bash
   ./scripts/setup/02-ensure-workload-nodepool.sh
   ```

   Same as EKS: execs `./scripts/labs/lab-nodes.sh 1.1 ensure`. Nodes are labelled `workshop.aerospike.com/node-pool=baseline`. Each pool attaches `${GKE_LOCAL_SSD_COUNT}` local NVMe disks (`--local-nvme-ssd-block-count`).

   **Expected:** `${NODE_COUNT}`× `${NODE_TYPE}` Ready across `${CLUSTER_ZONES}` (≥ `${MIN_NODES_PER_ZONE}` per zone).

4. Confirm namespace:

   ```bash
   kubectl get namespace aerospike
   ```

## Verify (pass/fail)

```bash
kubectl get nodes -o wide
kubectl get nodes -l workshop.aerospike.com/node-pool=baseline
```

**Pass:** GKE cluster reachable; `${NODE_COUNT}` workload nodes Ready, labelled `baseline`.

## Observe

- System pool has **no** `node-pool=baseline` label — Aerospike pods stay off it
- nvme-bootstrap still **partitions** each local SSD as one `p1` covering 0–100% (prime/GPT; no leftover overprovisioning)
- Lab 1.2/1.3 local-ssd claims are `250Gi` (v1) then `300Gi` (v2 / replacement) — both fit a ~375 GiB GKE local NVMe PV (and EKS 512 GiB partitions)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `GCP_PROJECT` missing | Copy `workshop.env.gke.example` and set the project id |
| Ran `02-bootstrap-eks.sh` with a GKE env | Expected — use `./scripts/setup/02-bootstrap-gke.sh` |
| API not enabled | `gcloud services enable container.googleapis.com compute.googleapis.com --project=$GCP_PROJECT` |
| `gke-gcloud-auth-plugin not found` / kubectl cannot download OpenAPI | `gcloud components install gke-gcloud-auth-plugin`, then `gcloud container clusters get-credentials ${CLUSTER_NAME} --region ${GCP_REGION}` |
| Local SSD quota | Request Local SSD + N2 CPUs in `${GCP_REGION}` |
| Autopilot cluster | Delete and recreate with `02-bootstrap-gke.sh` (Standard only) |

## Teardown / handoff

Cluster remains running. Proceed to AKO install (0.3). Workload nodes: step 0.2-nodes.

**EKS path:** [02-eks-cluster.md](02-eks-cluster.md) when `CLOUD_PROVIDER=eks`.

## Workshop artifacts

- Env: [scripts/env/workshop.env.gke.example](../../scripts/env/workshop.env.gke.example)
- Script: [`scripts/setup/02-bootstrap-gke.sh`](../../scripts/setup/02-bootstrap-gke.sh)

## References

- [`scripts/setup/02-bootstrap-gke.sh`](../../scripts/setup/02-bootstrap-gke.sh)
- [GKE Standard clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/types-of-clusters)
