# Lab 0.7 — Upgrade-lab Cluster (for Lab 2.6)

| Field | Value |
|-------|-------|
| Lab ID | `0.7` |
| Section | Environment Setup |
| EKS cluster | `${UPGRADE_LAB_CLUSTER_NAME}` (default `my-cluster-k8s-upgrade`) |
| Kubernetes | `${UPGRADE_LAB_K8S_VERSION_START}` (default 1.31 → 1.32 in Lab 2.6) |
| Node provisioning | eksctl MNG **always** — independent of `NODE_PROVISIONING` |
| Aerospike cluster | `aerocluster`, `${UPGRADE_LAB_AEROSPIKE_SIZE}` nodes (default 3) |
| Deploy path | OLM **always** — independent of `DEPLOY_PATH` |
| Duration | ~15–25 min post-bootstrap |
| Validation status | `draft` |

## Takeaway

A second, self-contained EKS cluster on an older Kubernetes version, already running AKO and an Aerospike cluster, so Lab 2.6 can upgrade a control plane without touching the main workshop cluster.

## Prerequisites

- Lab 0.6 complete on the main cluster
- `secrets/features.conf` present (same file as the main cluster)
- Capacity for `${UPGRADE_LAB_NODE_COUNT}`× `${UPGRADE_LAB_NODE_TYPE}` in `${NODE_ZONE}`, on top of the main cluster's nodes

## Starting state

Either of:

- **Default (parallel) run:** `setup-all.sh` already created the upgrade-lab EKS cluster alongside step 0.2, so only the post-bootstrap work remains
- **Nothing yet:** no upgrade-lab cluster exists

## Steps

1. Run step 0.7:

   ```bash
   ./scripts/setup/setup-all.sh --step 0.7
   ```

   Or invoke the script directly:

   ```bash
   ./scripts/setup/upgrade-lab/setup-upgrade-lab.sh
   ```

   [`setup-upgrade-lab.sh`](../../scripts/setup/upgrade-lab/setup-upgrade-lab.sh) creates the cluster with [`00-bootstrap-eks.sh`](../../scripts/setup/upgrade-lab/00-bootstrap-eks.sh) when it does not exist, or just re-ensures the nodegroup when it does, then hands off to the post-bootstrap script. A default full `setup-all.sh` skips straight to [`setup-upgrade-lab-post-bootstrap.sh`](../../scripts/setup/upgrade-lab/setup-upgrade-lab-post-bootstrap.sh), because the parallel bootstrap already built the cluster.

2. Watch what the post-bootstrap script does — each stage is skipped when already satisfied, so re-runs are safe:

   | Stage | Detail |
   |-------|--------|
   | Bootstrap | Rendered ClusterConfig at `${UPGRADE_LAB_K8S_VERSION_START}`; nodegroup `ng-upgrade-lab` (`${UPGRADE_LAB_NODE_COUNT}`× `${UPGRADE_LAB_NODE_TYPE}` in `${NODE_ZONE}`), nodes labelled `workshop.aerospike.com/node-pool=baseline`; namespace `${NAMESPACE}` created |
   | AKO | [`01-install-ako.sh`](../../scripts/setup/upgrade-lab/01-install-ako.sh) → the **OLM** installer, even when `DEPLOY_PATH=helm` |
   | akoctl | Reuses [`04-install-akoctl.sh`](../../scripts/setup/04-install-akoctl.sh) for namespace RBAC |
   | Secrets | [`02-setup-storage-secrets.sh`](../../scripts/setup/upgrade-lab/02-setup-storage-secrets.sh) → same [`07-deploy-secrets.sh`](../../scripts/setup/07-deploy-secrets.sh) as the main cluster, always re-applied |
   | Local NVMe | [`06-setup-local-storage.sh`](../../scripts/setup/06-setup-local-storage.sh), only when the resolved storage for lab 2.6 is `disk` (the `CLUSTER_STORAGE` default) |
   | Aerospike | [`03-deploy-cluster.sh`](../../scripts/setup/upgrade-lab/03-deploy-cluster.sh) → `kubectl apply` of [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) or [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml); an existing `aerocluster` with the wrong storage engine is deleted and redeployed |

   **Expected:** ends with `=== Upgrade-lab ready for Lab 2.6 ===` followed by `Restored kubectl context to main cluster: ${CLUSTER_NAME}`.

3. Confirm your context came back to the main cluster:

   ```bash
   ./scripts/lib/kubecontext.sh show
   ```

   **Expected:** `${CLUSTER_NAME}` (default `my-cluster`) — the context restore runs on exit even if the step failed partway.

## Verify (pass/fail)

```bash
./scripts/lib/kubecontext.sh upgrade-lab
kubectl get nodes
kubectl -n aerospike get aerospikecluster aerocluster
./scripts/lib/kubecontext.sh main
```

**Pass:** `${UPGRADE_LAB_NODE_COUNT}` nodes Ready on Kubernetes `${UPGRADE_LAB_K8S_VERSION_START}`; `aerocluster` phase `Completed`; context returned to the main cluster.

## Observe

- Two clusters now exist. Every lab except 2.6 runs on `${CLUSTER_NAME}`, so always check your context before demonstrating
- This is the only cluster in the workshop where Section 0 leaves an Aerospike cluster running — the main cluster stays empty until labs deploy their own baseline
- Path B (Helm) sessions still get OLM and a kubectl-applied cluster here; the upgrade-lab exists to exercise a control plane upgrade, not the deploy path

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Want to defer the cost | `./scripts/setup/setup-all.sh --skip-upgrade-lab`, then `./scripts/labs/prepare-lab.sh 2.6` before Lab 2.6. With that flag set, `--step 0.7` is refused |
| Parallel bootstrap failed | Partial clusters may remain — `./scripts/cleanup-lab.sh --yes` resets, then re-run setup |
| Nodegroup timeout | `ensure-nodegroup.sh` waits 900s then dumps nodes and nodegroups; check `${UPGRADE_LAB_NODE_TYPE}` capacity in `${NODE_ZONE}` |
| `aerocluster` redeploying unexpectedly | `CLUSTER_STORAGE` (or a `CLUSTER_STORAGE_*_LABS` override for 2.6) changed since the last run, so the storage engine no longer matches |
| kubectl still on the upgrade-lab cluster | `./scripts/lib/kubecontext.sh main` |

## Not covered here

The control plane upgrade itself → [Lab 2.6](../02-maintenance-and-upgrade/06-k8s-control-plane-upgrade.md).

## Teardown / handoff

Cluster stays running until Lab 2.6. Afterwards, delete it on its own with `./scripts/cleanup-lab.sh --upgrade-lab-only`.

Proceed to [Section 1 — Scaling & Capacity](../01-scaling-and-capacity/README.md).

## Workshop artifacts

- EKS reference config: [clusters/upgrade-lab-cluster.yaml](../../clusters/upgrade-lab-cluster.yaml) (documentation only — bootstrap renders its own ClusterConfig)
- Aerospike manifests: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml)
- Environment: `UPGRADE_LAB_*` keys in [scripts/env/workshop.env.example](../../scripts/env/workshop.env.example)

## References

- [`scripts/setup/upgrade-lab/`](../../scripts/setup/upgrade-lab/)
- [Updating an EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html)
