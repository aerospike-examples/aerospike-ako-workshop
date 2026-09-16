# Section 2 — Instructor Notes

## Timing

| Lab | Duration | Notes |
|-----|----------|-------|
| 2.1 | ~15m (+10m optional) | Install verify, collectinfo tarball; optional: global flags, auth |
| 2.2 | ~30–40m | Three steps: 4.3.0 → 4.4.1 → 4.5.0; demo one step live |
| 2.3 | ~10m | WarmRestart then PodRestart (cold) on 8.1.0.x cluster (match deploy-cluster.sh); optional Terminal B `run-lab-workload.sh` |
| 2.4 | ~20m | Rolling DB upgrade 8.1.0.x → 8.1.2.x (requires AKO 4.5.0); start `run-lab-workload.sh` in Terminal B before image apply |
| 2.5 (eksctl / GKE node pool) | ~25m | Drain demo: migration-gated webhook block; Phase 3 Path A/B; optional same-AZ nodegroup scale before drain; Phase 4 EC2 terminate or `gcloud compute instances delete` + PVC cleanup; optional blocklist alternate; optional asadm quiesce step |
| 2.5 (Karpenter) | ~25m (+15m add-on) | Same drain + Phase 3 story; Phase 4: primary NodeClaim delete **or** alternate manual EC2 terminate (same as eksctl); optional Karpenter disruption add-on; no blocklist |
| 2.6 | ~45–60m | Two-phase upgrade (EKS MNG or GKE node pool): CP (~10–20m) then worker pool (~15–25m); Phase 1 seed + Terminal B workload recommended; node pool = Lab 2.5 drain mechanics at scale |

## AKO upgrade (2.2)

- **Never skip versions** in production — enforce ladder in `versions.env`
- Keep cluster Running throughout — key demo point
- DB stays at **8.1.0.x** during AKO upgrade (AKO 4.2.0–4.4.1 max); 8.1.2.x comes in Lab 2.4 after 4.5.0
- Per-step timing ~15–20 min (OLM wait)

## Lab 2.6 (control plane)

- **Separate cluster only** — `./scripts/lib/kubecontext.sh upgrade-lab` or `./scripts/labs/prepare-lab.sh 2.6`
- **Two-phase story** — Phase 3 (CP): pods stay Running, no kubelet change; Phase 4 (node pool): first Aerospike restarts, Lab 2.5 mechanics (drain, migration, local-ssd PVC cleanup)
- **Bridge from Lab 2.5** — frame the managed pool upgrade as automated rolling drain; safe eviction on upgrade-lab is OLM-default off — patch subscription before Phase 4 (same as Lab 2.5 Path A)
- **Phase 1 seed data** — `load-data.sh --upgrade-lab` or `prepare-lab.sh 2.6 --load-data`; empty cluster makes availability demo weak
- **Terminal B recommended** — `./scripts/labs/run-lab-workload.sh --upgrade-lab start` before Phase 3; watch TPS through CP blips and node-pool pod moves; stop after Phase 5
- **Two-terminal observe** — Terminal A: upgrade scripts; Terminal B: pods, CR phase, migrate stats (Phase 4), PVC watch (device storage)
- **Timing** — CP `upgrade-control-plane.sh` (~10–20m; EKS waits `cluster-active`, GKE `gcloud … --master` blocks); node pool `upgrade-nodegroup.sh` (~15–25m for 3 Aerospike workers)
- **GKE** — versions look like `1.35.x-gke.y` (prefix match); only `${UPGRADE_LAB_NODEGROUP_NAME}` is upgraded, not `default-pool`
- Do not scale down Aerospike during either phase
- After Lab 2.6 (keep main cluster): `./scripts/cleanup-lab.sh --upgrade-lab-only --yes` then `./scripts/lib/kubecontext.sh main`
- End of full training: `./scripts/cleanup-lab.sh --yes` (both clusters)

## Lab 2.5 (node maintenance)

Pick **one** guide by `NODE_PROVISIONING` — [eksctl](05-k8s-node-maintenance.md) or [Karpenter](05-k8s-node-maintenance-karpenter.md). Shared teaching points apply to both paths.

- **Enable safe pod eviction first** — verify `ENABLE_SAFE_POD_EVICTION=true` on the operator before the drain demo ([Aerospike docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#enabling-safe-pod-eviction)); OLM installs do not set this by default
- **Pre-load data (Phase 1)** — empty cluster migrates too fast (especially `--dim`); run `load-data.sh` (Option A) or `prepare-lab.sh 2.5 --load-data` (Option B)
- **Three-layer story** — (1) webhook blocks drain only while migration active; (2) after drain, Path A = local-ssd PVC pins pod on cordoned node, Path B = AKO `localStorageClasses` deletes claims and pod reschedules empty; (3) node termination → PVC cleanup controller → pod on fresh local storage in same AZ
- **Two-terminal demo** — Terminal A: `kubectl drain`; Terminal B: CR `InProgress`, migrate stats, pod on `$NODE` (`Running` or `Terminating` both valid)
- If migration window is too short, use Phase 2 optional (instructor) in the active guide (`migrate-fill-delay` 3600 + quiesce node 3)
- **Phase 4 required (device storage)** — terminate/replace node, watch PVC cleanup controller, confirm pod reschedules
- **`CLUSTER_STORAGE_DIM_LABS=2.5`** — disk default everywhere except Lab 2.5 stays in-memory for faster drain demos

### Lab 2.5 — eksctl / GKE node pool path

- **Phase 2 optional** — `./scripts/labs/lab-nodes.sh 2.5 ensure --replace-zone --node=$NODE` after 2a, before first drain; pre-provisions same-AZ capacity for pod reschedule during drain or after Phase 4 terminate
- **Phase 4** — EKS: `aws ec2 terminate-instances`; GKE: `gcloud compute instances delete` (capture instance name + zone **before** `kubectl delete node`)
- **Alternate demo** — optional `k8sNodeBlockList` section (this guide; Karpenter incompatible)

### Lab 2.5 — Karpenter path

- **Phase 4** — primary: delete NodeClaim for drained node; alternate: manual EC2 terminate (same as eksctl). Karpenter provisions same-zone replacement automatically (no manual nodegroup scale-up)
- **Never** demo blocklist ([AKO #305](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305))
- **Add-on (~15m):** run after drain demo when audience is planning to allow voluntary Karpenter disruption
  - Frame customer's `do-not-disrupt` approach as valid Phase 1, not the long-term target
  - Walk the three layers: `do-not-disrupt` → safe eviction → `terminationGracePeriod`
  - Show live NodePool grace value: `kubectl get nodepool … -o jsonpath='{.spec.template.spec.terminationGracePeriod}'`
  - Emphasize AKO docs: Karpenter **force-deletes** after grace period — 600s workshop default is a starting point, not production gospel
  - Do **not** live-demo removing `do-not-disrupt` or enabling consolidation during class unless on a throwaway cluster

## Pitfalls

| Issue | Mitigation |
|-------|------------|
| Section 1 cluster blocks deploy | Run `./scripts/labs/prepare-lab.sh 2.1` — tears down `aerocluster` and deploys baseline (device default) |
| Lab 1.4 / prior 2.4 wrong starting state | Run `./scripts/labs/prepare-lab.sh 2.4` — resets to **8.1.0.x** baseline before DB upgrade |
| Lab 2.3 operations / spec drift | Run `./scripts/labs/prepare-lab.sh 2.3` — redeploys **8.1.0.x** baseline before on-demand operations |
| CRD delete during Helm upgrade | Never delete CRDs — use replace |
| Force drain | Never demo `--force` |
| Wrong cluster context | `./scripts/lib/kubecontext.sh show`; main labs use `./scripts/labs/prepare-lab.sh <lab>` |
| Wrong cluster after 2.6 / Section 0.7 | `./scripts/lib/kubecontext.sh main` |
| `load-data.sh` on upgrade-lab hits main cluster | Use `load-data.sh --upgrade-lab` |
| EKS version unsupported | Adjust START/TARGET to (latest-1)→latest |
| DB 8.1.2.x before AKO 4.5.0 | Baseline manifests use 8.1.0.x; upgrade only in Lab 2.4 |

## Curriculum order

Emphasize: **2.2 → 1.4 → 2.3–2.5**. Lab **2.6** is optional and off by default.

## Skip paths

- Pre-stage AKO at 4.5.0; demo one upgrade step only
- Skip 2.6 unless you opted into setup step 0.7 — default `setup-all.sh` does not create the upgrade-lab cluster
