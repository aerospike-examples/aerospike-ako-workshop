# Section 2 — Maintenance & Upgrade

## Section takeaway

AKO and the platform can be upgraded and maintained safely — operator upgrades, DB upgrades, node eviction, control plane upgrades, and on-demand operations each have distinct procedures.

## Prerequisites

Section 0 complete. Run `./scripts/labs/prepare-lab.sh 2.1` before Lab 2.1 (cluster baseline after Section 1; device storage default). Run `./scripts/labs/prepare-lab.sh 2.3` before Lab 2.3 if coming from Lab 1.4 or the cluster spec has drifted. Run `./scripts/labs/prepare-lab.sh 2.4` before Lab 2.4 if retrying the DB upgrade. Run `./scripts/labs/prepare-lab.sh 2.5` before Lab 2.5 (teardown + fresh maintenance cluster). Seed data in Lab 2.5 Phase 1 (`load-data.sh` or `prepare-lab.sh 2.5 --load-data`). Run `./scripts/labs/prepare-lab.sh 2.6` before Lab 2.6 (upgrade-lab cluster); seed with `load-data.sh --upgrade-lab` or `prepare-lab.sh 2.6 --load-data`. Default storage is device (`CLUSTER_STORAGE=disk`); use `--dim` for in-memory.

## Labs

| Lab | Title | Cluster | Duration | When |
|-----|-------|---------|----------|------|
| 2.1 | [akoctl — install, collectinfo](01-akoctl.md) | `my-cluster` | ~15m (+10m optional) | |
| 2.2 | [Upgrade AKO](02-upgrade-ako.md) | `my-cluster` | ~45–60m | |
| — | → then [Lab 1.4](../01-scaling-and-capacity/04-replication-factor.md) (replication factor) | `my-cluster` | ~15m | |
| 2.3 | [On-demand operations](03-on-demand-operations.md) | `my-cluster` | ~10m | |
| 2.4 | [Upgrade Aerospike DB](04-upgrade-aerospike-db.md) | `my-cluster` | ~20m | |
| 2.5 | [K8s node maintenance (eksctl)](05-k8s-node-maintenance.md) | `my-cluster` | ~25m | `NODE_PROVISIONING=eksctl` |
| 2.5 | [K8s node maintenance (Karpenter)](05-k8s-node-maintenance-karpenter.md) | `my-cluster` | ~25m (+15m add-on) | `NODE_PROVISIONING=karpenter` |
| 2.6 | [K8s control plane upgrade](06-k8s-control-plane-upgrade.md) | `my-cluster-k8s-upgrade` | ~45–60m | **Optional** — off by default |

**Curriculum:** Complete **2.2** (through AKO 4.4.1 minimum), then run **[Lab 1.4](../01-scaling-and-capacity/04-replication-factor.md)** before continuing to 2.3–2.5. Lab **2.6** is optional; run `./scripts/setup/setup-all.sh --step 0.7` (or `prepare-lab.sh 2.6`) only when teaching it.

## Instructor notes

See [instructor-notes.md](instructor-notes.md).
