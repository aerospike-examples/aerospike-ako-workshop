# Section 1 — Scaling & Capacity

## Section takeaway

AKO scales Aerospike clusters horizontally, vertically, across racks, and adjusts replication — each operation has distinct CR fields and observable behavior.

## Lab flow

| Lab | Profile | Notes |
|-----|---------|-------|
| 1.1 | Device storage cluster (default; `--dim` for in-memory) | Horizontal scale only |
| 1.2–1.3 | Hybrid storage (`ssd` workdir + `local-ssd`) | Rack labs always use device block storage — `--dim` does not apply |
| 1.4 | Replication factor (deferred) | **Run after [Lab 2.2](../02-maintenance-and-upgrade/02-upgrade-ako.md)** |

## Reset-and-redeploy flow

Default: **light reset** between Section 1 labs (1.2–1.4). Lab **1.1** runs a **full reset** (same as default `prepare-lab.sh 1.1`). Use **full reset** only for cold start or recovery.

| Lab | Reset | Command |
|-----|-------|---------|
| 1.1 | Full | `./scripts/labs/prepare-lab.sh 1.1` |
| 1.2 | Light | `./scripts/labs/prepare-lab.sh 1.2` (keeps nodes; scales baseline pool 5 → 4) |
| 1.3 | Light | `./scripts/labs/prepare-lab.sh 1.3` (standalone replacement; baseline pool, then vertical pool in lab) |
| 1.4 | Light | `./scripts/labs/prepare-lab.sh 1.4` (after Lab 2.2; keeps baseline pool) |

Continuing 1.1 → 1.2 in one session: light reset only — no nodepool delete/recreate.

**Recovery** (cold start or broken state):

```bash
./scripts/reset-cluster.sh --yes
./scripts/labs/prepare-lab.sh <lab-id>
```

`prepare-lab.sh <lab> --full` is shorthand for full reset + ensure.

## Labs

| Lab | Title | Duration | Run order |
|-----|-------|----------|-----------|
| 1.1 | [Horizontal scaling](01-horizontal-scaling.md) | ~15m | — |
| 1.2 | [Rack awareness, vertical scale & revision](02-rack-awareness-vertical-revision.md) | ~60m | After 1.1 |
| 1.3 | [Rack replacement](03-rack-replacement.md) | ~30m | Standalone |
| 1.4 | [Replication factor](04-replication-factor.md) | ~15m | **After [Lab 2.2](../02-maintenance-and-upgrade/02-upgrade-ako.md)** |

**Note:** Lab 1.4 is listed in Section 1 but requires AKO **4.4.0+** — do not run until [Lab 2.2](../02-maintenance-and-upgrade/02-upgrade-ako.md) completes the 4.4.1 upgrade step.

## Karpenter observe (optional)

When `NODE_PROVISIONING=karpenter`, watch node provisioning during scale-up labs:

```bash
kubectl get nodeclaims,nodes          # snapshot (both types)
kubectl get nodeclaims -w             # live watch — `-w` accepts one resource type only
kubectl get nodes -l workshop.aerospike.com/node-pool=baseline -w
```

Labs 1.1, 1.2 (vertical scale), and 1.3 are the best demos for Karpenter provisioning new workload nodes.

## Instructor notes

See [instructor-notes.md](instructor-notes.md).
