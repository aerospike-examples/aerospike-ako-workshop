# Lab 2.5 — K8s Worker Node Maintenance

> **Node provisioning:** This guide is for `NODE_PROVISIONING=eksctl`. If you use Karpenter, use [Lab 2.5 — K8s Worker Node Maintenance (Karpenter)](05-k8s-node-maintenance-karpenter.md) instead — do not mix guides mid-session.

| Field              | Value                                                                             |
| ------------------ | --------------------------------------------------------------------------------- |
| Lab ID             | `2.5`                                                                             |
| Section            | Maintenance & Upgrade                                                             |
| EKS cluster        | `my-cluster`                                                                      |
| AKO min version    | `4.5.0`                                                                           |
| Aerospike baseline | 3-node device storage on local-ssd (**8.1.2.x**); in-memory with `--dim`          |
| Deploy path        | both                                                                              |
| Node provisioning  | **eksctl**                                                                        |
| Duration           | ~25 min                                                                           |
| Validation status  | `draft`                                                                           |
| Official docs      | [Node maintenance](https://aerospike.com/docs/kubernetes/manage/node-maintenance) |

## Takeaway

Three layers govern worker node maintenance with local storage:

1. **Safe eviction** blocks `kubectl drain` **only while Aerospike migration is active** (CR `InProgress`, non-zero migrate stats). Without active migration, drain proceeds.
2. **local-ssd PVCs** bind to a node — the pod cannot reschedule elsewhere until those claims are deleted. With `spec.storage.localStorageClasses` set (workshop baseline), AKO may delete local PVCs during planned drain instead; if not, pinning is the fallback constraint after drain completes.
3. **Node termination** triggers the PVC cleanup controller (Lab 0.5) to remove orphaned claims; the replacement pod schedules on a new node with fresh local storage in the same AZ.

## Prerequisites

- Lab 2.4 complete (DB upgrade to **8.1.2.x**; implies AKO **4.5.0**)
- [Safe pod eviction enabled](#enable-safe-pod-eviction-required) on the operator — **disabled by default** in AKO ([docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#safe-pod-eviction-webhook))
- 3-node cluster `Running`; phase `Completed` (device storage by default)

## Enable safe pod eviction (required)

AKO's [safe pod eviction webhook](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#safe-pod-eviction-webhook) intercepts pod eviction API calls from `kubectl drain`. When migration is active, the webhook denies eviction and AKO migrates data safely. When migration is **not** active, drain proceeds — local PVC node affinity is the next constraint.

**This feature is disabled by default.** Without it, Phase 2 drain is never blocked by the webhook regardless of migration state.

**Workshop defaults:**

| Path         | Enabled at install?                                                                                           | Action before Lab 2.5                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| **A — OLM**  | **No** — not set by `./scripts/setup/03-install-ako.sh`                                                       | Patch subscription with `ENABLE_SAFE_POD_EVICTION=true` (below)                          |
| **B — Helm** | Yes — `safePodEviction.enable=true` in [helm/operator-values.yaml](../../helm/operator-values.yaml) (Lab 0.3) | Verify below; re-apply values if AKO was upgraded without `-f helm/operator-values.yaml` |

### Path A — OLM

Patch the Subscription to set `ENABLE_SAFE_POD_EVICTION=true` ([Aerospike docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#enabling-safe-pod-eviction)):

```bash
kubectl -n operators patch subscription aerospike-kubernetes-operator \
  --type='merge' \
  -p '{"spec":{"config":{"env":[{"name":"ENABLE_SAFE_POD_EVICTION","value":"true"}]}}}'
```

Wait for OLM to reconcile and the operator deployment to roll out.

### Path B — Helm

Re-apply workshop operator values (safe after Lab 2.2 AKO upgrades):

```bash
source scripts/env/workshop.env
helm upgrade "${HELM_OPERATOR_RELEASE}" aerospike/aerospike-kubernetes-operator \
  -n "${OPERATOR_NAMESPACE}" \
  --reuse-values \
  -f helm/operator-values.yaml
```

Or set explicitly per [Aerospike docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#enabling-safe-pod-eviction):

```yaml
safePodEviction:
  enable: "true"
  timeoutSeconds: "20"   # webhook response wait per eviction request, not migration budget
```

### Verify

Both paths — workshop script (uses the correct operator deployment name for OLM vs Helm):

```bash
source scripts/env/workshop.env
./scripts/labs/verify-safe-pod-eviction.sh
```

**Expected:** `ENABLE_SAFE_POD_EVICTION=true`; a validating webhook with a `pods/eviction` rule (typically `aerospike-operator-validating-webhook-configuration` on Helm); controller Ready.

If the webhook is missing after Lab 2.2, re-apply [helm/operator-values.yaml](../../helm/operator-values.yaml) — `upgrade-step-helm.sh` does not merge workshop values.

#### Path A — manual (OLM)

```bash
kubectl -n operators get deployment aerospike-operator-controller-manager \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' \
  | grep ENABLE_SAFE_POD_EVICTION

kubectl get validatingwebhookconfiguration -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .webhooks[*].rules[*].resources}{.}{" "}{end}{"\n"}{end}' \
  | grep 'pods/eviction'

kubectl -n operators rollout status deployment/aerospike-operator-controller-manager --timeout=120s
```

#### Path B — manual (Helm)

```bash
source scripts/env/workshop.env

kubectl -n "${OPERATOR_NAMESPACE}" get deployment "${HELM_OPERATOR_RELEASE}" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"\n"}{end}' \
  | grep ENABLE_SAFE_POD_EVICTION

helm get values "${HELM_OPERATOR_RELEASE}" -n "${OPERATOR_NAMESPACE}" -o yaml | grep -A2 safePodEviction

kubectl get validatingwebhookconfiguration -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .webhooks[*].rules[*].resources}{.}{" "}{end}{"\n"}{end}' \
  | grep 'pods/eviction'

kubectl -n "${OPERATOR_NAMESPACE}" rollout status "deployment/${HELM_OPERATOR_RELEASE}" --timeout=120s
```

**Expected:** Same as above — deployment name is `${HELM_OPERATOR_RELEASE}` (default `aerospike-kubernetes-operator`), not `aerospike-operator-controller-manager`.

## Phase 0 — Prepare lab

Tears down existing `aerocluster` if present and deploys fresh maintenance baseline (clears Lab 2.3 operations):

```bash
./scripts/labs/prepare-lab.sh 2.5
```

**Expected:** `prepare-lab.sh` completes; cluster redeployed for maintenance baseline.

## Phase 1 — Seed data (make migration visible)

An empty cluster migrates too fast to observe (especially in-memory — use `--dim` or pre-load data). Load records using the `app` user (`read` + `write` roles; secret `auth-app-secret` / password `app123`), defined in the maintenance baseline manifest.

**Option A — load after Phase 0:**

```bash
./scripts/labs/load-data.sh
```

**Option B — combine deploy + load** (skip Phase 0 if using this):

```bash
./scripts/labs/prepare-lab.sh 2.5 --load-data
```

Tunable via env when using Option A (increase if migration completes too quickly):

| Variable                     | Default   | Purpose                       |
| ---------------------------- | --------- | ----------------------------- |
| `MIGRATION_LOAD_RECORDS`     | `5000000` | Record count                  |
| `MIGRATION_LOAD_OBJECT_SIZE` | `1024`    | Bytes per object (`-o S1024`) |
| `MIGRATION_LOAD_THREADS`     | `64`      | asbench threads (`-z`)        |

Verify data is present:

```bash
kubectl run -it --rm aerospike-tool-ns -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U app -P app123 -e "info"
```

**Pass:** Non-zero objects in namespace `test` (see `asadm` output).

If you used Option B (`--load-data`), skip Option A and proceed to Phase 2 after verifying data is present.

## How local storage affects drain

Before draining, understand why local storage behaves differently from network-attached `ssd` volumes:

| Volume         | StorageClass                 | Node loss / drain behavior                   |
| -------------- | ---------------------------- | -------------------------------------------- |
| Workdir        | `ssd` (network-attached)     | Detaches and reattaches on another node      |
| Namespace data | `local-ssd` (instance store) | **Pinned** to the node via PVC node affinity |

**local-ssd PVCs cannot move.** A pod with a bound local PVC stays on that node (or enters `Pending`) until the claim is deleted. This is independent of the eviction webhook.

**AKO** `localStorageClasses`**:** The maintenance baseline sets `spec.storage.localStorageClasses: [local-ssd]` so AKO deletes local PVCs during planned migration ([Aerospike docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#using-kubectl-drain)).

**PVC cleanup controller:** When a worker node is terminated, the `local-volume-node-cleanup-controller` (Lab 0.5) deletes orphaned `local-ssd` PVCs after a 60s delay — see [Lab 0.5 instructor demo](../00-environment-setup/05-storage-layer.md#instructor-demo--local-pvc-cleanup-on-node-failure).

> `--dim` **path:** In-memory clusters have no local PVC pinning. Migration is faster; use abbreviated observe steps in Phases 2–3 and skip Phase 4 (no instance-store cleanup needed).

## Phase 2 — Drain + observe (core demo)

Use **two terminals** for the primary path. The webhook blocks drain **only while migration is active**.

### 2a — Capture pod placement

Drain the node hosting `aerocluster-0-0` and confirm the cluster is ready:

```bash
kubectl -n aerospike get pods -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}{.spec.image}{"\n"}'
NODE=$(kubectl -n aerospike get pod aerocluster-0-0 -o jsonpath='{.spec.nodeName}')
echo "Maintenance target node (aerocluster-0-0): ${NODE}"
```

**Expected:** 3 pods `Running`; CR phase `Completed`; image `8.1.2.x`; no `spec.operations` in CR; `$NODE` is the worker running `aerocluster-0-0`.

### 2 optional (eksctl) — Add same-AZ capacity before drain

Recommended to demonstrate production-style replacement: scale the per-AZ nodegroup where `aerocluster-0-0` lives **before** the first drain. When AKO rolls the pod during drain (Path B) or after Phase 4 terminates the cordoned worker, a schedulable node with fresh local storage already exists in the correct AZ. No manual `kubectl delete pvc`.

```bash
source scripts/env/workshop.env
./scripts/labs/lab-nodes.sh 2.5 ensure --replace-zone --node="$NODE"
```

The script prints the target zone and nodegroup. Confirm an extra Ready node in that AZ:

```bash
TARGET_ZONE=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
kubectl get nodes -l "topology.kubernetes.io/zone=${TARGET_ZONE},workshop.aerospike.com/node-pool=baseline" -o wide
```

**Pass:** Nodegroup in `$TARGET_ZONE` has +1 Ready node. Then continue with **2b**.

### 2b — First drain + migration

**Terminal A:**

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

**Expected:** Webhook denial message for the Aerospike pod (eviction blocked while migration is active), or drain errors until migration completes.

### 2c — Observe during migration

Run in **Terminal B** while Terminal A is still waiting or reporting eviction denied:

```bash
# Pod on the drained node — Running or Terminating as AKO rolls it
kubectl -n aerospike get pod -o wide --field-selector spec.nodeName="$NODE"

# CR unstable during migration
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'

# Safe eviction annotation (may be absent once pod is Terminating)
kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster --field-selector spec.nodeName="$NODE" \
  -o custom-columns='NAME:.metadata.name,EVICTION-BLOCKED:.metadata.annotations.aerospike\.com/eviction-blocked'

# Active migration in Aerospike
kubectl run -it --rm aerospike-tool-migrate -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show stat like migrate"
```

**Pass (during active migration):**

- Terminal A shows webhook denial for `aerocluster-0-0` (or similar)
- CR phase `InProgress`
- asadm shows non-zero migrate tx/rx (or decreasing pending)
- Pod on `$NODE` may be `Running` or `Terminating` — both are valid while AKO migrates

Re-run Terminal B commands every few seconds until CR returns to `Completed`.

### 2d — Retry drain after Completed

Once migration finishes:

```bash
kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed aerospikecluster/aerocluster --timeout=900s
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
kubectl -n aerospike get pods -o wide
```

**Pass:** Node cordoned (`SchedulingDisabled`); Aerospike pod gone from `$NODE` or still present if local PVC has not been released yet.

### 2 optional (instructor) — Force visible drain block

Use when Phase 2b migration finishes too fast to observe the webhook denial, or to explicitly prove **drain is blocked only while migration is active**.

Prerequisite: `$NODE` hosts `aerocluster-0-0` (Aerospike node 0). Identify Aerospike node IDs before starting:

```bash
kubectl run -it --rm aerospike-tool-nodes -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show stat like node"
```

**Step 1 — Slow migration and quiesce node 3**

Replace `<node-3-id>` with the node ID from `show stat like node` (third cluster member — e.g. `A2` in a 3-node cluster):

```bash
# Slow migrations so the drain block window is long enough to observe
asadm -h aerocluster -U admin -P admin123 -e \
  "manage config namespace test param migrate-fill-delay to 3600"

# Quiesce node 3
asadm -h aerocluster -U admin -P admin123 -e \
  "enable; manage quiesce with <node-3-id>; manage recluster; info"
```

**Step 2 — Drain and observe block**

Terminal A:

```bash
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

Terminal B (while drain waits):

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl run -it --rm aerospike-tool-migrate -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show stat like migrate"
kubectl -n aerospike get pod aerocluster-0-0 -o wide
```

**Pass:** Webhook denial in Terminal A; CR `InProgress`; non-zero migrate stats; `aerocluster-0-0` still on `$NODE`.

**Step 3 — Un-quiesce node 3; watch node 0 terminate**

```bash
asadm -h aerocluster -U admin -P admin123 -e \
  "enable; manage quiesce with <node-3-id> undo; manage recluster; info"

# Restore default migrate-fill-delay when done
asadm -h aerocluster -U admin -P admin123 -e \
  "manage config namespace test param migrate-fill-delay to 0"
```

Watch `aerocluster-0-0` transition to `Terminating` and leave `$NODE` as migration completes and AKO rolls the pod. Then continue with Phase 2d.

## Phase 3 — PVC pinning observe

After Phase 2d, the cordoned node and `aerocluster-0-0` placement depend on whether AKO removed local PVCs during drain. Run the observe commands below — you may see **Path A** (pinning) or **Path B** (AKO-managed delete).

```bash
kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}{"\n"}'
kubectl -n aerospike get pod aerocluster-0-0 -o wide
kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster -o wide --field-selector spec.nodeName="$NODE"
kubectl -n aerospike get pvc -o wide
kubectl -n aerospike describe pod aerocluster-0-0 | tail -20
```

**Path A — PVC pinning (classic):**

- Node is cordoned (`true`)
- `aerocluster-0-0` still on `$NODE` or `Pending`
- local-ssd PVC bound with node affinity to `$NODE`
- Pod cannot schedule elsewhere until the claim is deleted

**Path B — AKO-managed delete (workshop baseline with** `localStorageClasses`**):**

- Node is cordoned
- No local-ssd PVC with affinity to `$NODE` (AKO deleted claims during drain)
- `aerocluster-0-0` `Running` on a different node — empty instance store, accepting migrations
- CR may have been `InProgress` briefly; should return to `Completed`

**Expected behavior:** Drain succeeded for the Kubernetes node. Proceed to Phase 4 to replace the cordoned worker. If Path B, pinning did not occur — Phase 4 still terminates the drained instance and confirms the pod stays healthy.

## Phase 4 — Node termination + PVC cleanup (device storage)

Simulate completing node maintenance — terminate the cordoned worker and let the PVC cleanup controller free any orphaned claims.

```bash
INSTANCE_ID=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
kubectl delete node "$NODE"
aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "$INSTANCE_ID"
```

Watch cleanup and reschedule:

```bash
# Watch PVCs and pods
kubectl -n aerospike get pvc -w
kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster -o wide -w
```

Wait for replacement node:

```bash
kubectl get nodes -w
```

Ctrl+C once a replacement node is `Ready`. `nvme-bootstrap` initializes NVMe on the new instance (Lab 0.5).

**Pass:** Orphaned local-ssd PVCs removed; replacement `aerocluster-0-0` pod `Running` on a new node; CR `Completed`. If you ran [Phase 2 optional (eksctl)](#2-optional-eksctl--add-same-az-capacity-before-drain), the pod should land on the **new** node in `$TARGET_ZONE` after terminate and ~60s cleanup delay.

## Alternate — k8sNodeBlockList (eksctl path only)

> **Karpenter sessions:** skip this section. Use [05-k8s-node-maintenance-karpenter.md](05-k8s-node-maintenance-karpenter.md) instead. `k8sNodeBlockList` uses node hostname affinity incompatible with Karpenter ([AKO #305](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305)).

Same migration observation pattern, triggered via CR blocklist instead of drain webhook. Data must be loaded (Phase 1) first.

### Path A — kubectl

1. Edit `manifests/disk-node-blocklist.yaml` (or `manifests/dim-node-blocklist.yaml` with `--dim`) — set `k8sNodeBlockList` to `$NODE`.
2. Apply and watch:
  ```bash
   kubectl apply -f manifests/disk-node-blocklist.yaml
   kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
   kubectl -n aerospike get pod -o wide --field-selector spec.nodeName="$NODE" -w
  ```
   Ctrl+C once pods have moved off `$NODE` or CR reaches `Completed`.
3. Wait for migration:
  ```bash
   kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed aerospikecluster/aerocluster --timeout=900s
  ```

### Path B — Helm

1. Edit `helm/overlay-node-blocklist-values.yaml` — set `k8sNodeBlockList` to `$NODE`.
2. Apply and watch (chart `--version` must match installed AKO — same resolver as `deploy-cluster-maintenance-helm.sh`):
  ```bash
   source scripts/env/workshop.env
   source scripts/lib/common.sh
   load_env
   helm upgrade aerocluster aerospike/aerospike-cluster \
     -n aerospike \
     -f helm/base-disk-cluster-values.yaml \
     -f helm/overlay-cluster-maintenance-values.yaml \
     -f helm/overlay-node-blocklist-values.yaml \
     --version="$(resolve_cluster_helm_chart_version)"
   kubectl -n aerospike get pod -o wide --field-selector spec.nodeName="$NODE" -w
  ```
3. Wait for migration:
  ```bash
   kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed aerospikecluster/aerocluster --timeout=900s
  ```

### Observe (blocklist)

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.k8sNodeBlockList}{"\n"}'
kubectl -n aerospike get pods -o wide
```

**Expected:** Blocklist contains `$NODE`; CR `InProgress` during migration; no Aerospike pods on `$NODE` after `Completed`. Local PVC cleanup follows the same Phase 4 pattern if the node is terminated.

## Verify (pass/fail)

```bash
kubectl -n aerospike get pods -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl get nodes
```

**Pass:** All Aerospike pods `Running`; CR `Completed`; maintenance target node replaced or uncordoned; cluster schedulable.

## Observe

- Safe eviction webhook denies eviction API **only while migration is active**
- Without active migration, drain cordons the node; local PVC node affinity prevents pod reschedule (unless AKO deletes local claims via `localStorageClasses`)
- Optional Phase 2 (eksctl): scale same-AZ nodegroup before drain — no manual PVC deletion
- Node termination → PVC cleanup controller → pod reschedules on fresh local storage
- Blocklist triggers AKO-driven rolling migration (hostname affinity — eksctl only)
- Cluster stays available during migration

## Teardown / restore

### Skip Phase 4 (time-constrained sessions)

Return the cordoned node to the scheduling pool without terminating the instance:

```bash
kubectl uncordon "$NODE"
kubectl get node "$NODE"
kubectl -n aerospike get pods -o wide
```

**Expected:** Node `Ready`, `SchedulingEnabled`. Aerospike pods remain on other nodes.

### Clear blocklist (if blocklist path was used)

Skip if only the drain path was demonstrated.

**Path A — kubectl:**

```bash
kubectl -n aerospike patch aerospikecluster aerocluster --type=json \
  -p='[{"op": "remove", "path": "/spec/k8sNodeBlockList"}]'
kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed aerospikecluster/aerocluster --timeout=900s
```

**Path B — Helm:**

```bash
source scripts/env/workshop.env
source scripts/lib/common.sh
load_env
helm upgrade aerocluster aerospike/aerospike-cluster \
  -n aerospike \
  -f helm/base-disk-cluster-values.yaml \
  -f helm/overlay-cluster-maintenance-values.yaml \
  --version="$(resolve_cluster_helm_chart_version)" \
  --set k8sNodeBlockList=null
kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed aerospikecluster/aerocluster --timeout=900s
```

### Handoff

Proceed to [Lab 2.6](06-k8s-control-plane-upgrade.md). Aerospike cluster should remain `Running`; worker nodes should be schedulable.

## Troubleshooting

| Symptom                                         | Fix                                                                                                                                      |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Migration completes too fast to observe         | Increase `MIGRATION_LOAD_RECORDS` (e.g. `8000000`); or use [Phase 2 optional (instructor)](#2-optional-instructor--force-visible-drain-block)   |
| Drain not blocked / no webhook denial           | Confirm `ENABLE_SAFE_POD_EVICTION=true`; migration may have finished — use Phase 2 optional                                              |
| Drain succeeds but pod stuck on cordoned node   | Expected Path A (local PVC pinning) — proceed to Phase 4 terminate (same-AZ capacity should already exist if [Phase 2 optional (eksctl)](#2-optional-eksctl--add-same-az-capacity-before-drain) was run) |
| Pod already Running on another node after drain | Expected Path B (AKO `localStorageClasses`) — proceed to Phase 4 terminate to replace cordoned worker                                    |
| local-ssd PVC Pending                           | Re-run `./scripts/setup/08-validate-environment.sh`; confirm baseline local-ssd PVs                                                      |
| No `eviction-blocked` annotation                | Normal once pod is Terminating; check CR phase and migrate stats instead                                                                 |
| PVC not cleaned up after node delete            | Check cleanup controller logs; wait 60s (`--pvc-deletion-delay=60s`)                                                                     |
| CR stays `InProgress`                           | Check operator logs; wait for migrate stats to reach zero                                                                                |
| Force delete bypasses webhook                   | Never use `--force` in production demo                                                                                                   |
| Blocklist changes cluster profile               | Use updated blocklist manifest matching your storage (`disk-node-blocklist.yaml` default)                                                |

## Not covered here

- Control plane upgrade → [Lab 2.6](06-k8s-control-plane-upgrade.md)

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Maintenance cluster (8.1.2.x, extended grace period):**
  - Path A: [manifests/disk-cluster-maintenance.yaml](../../manifests/disk-cluster-maintenance.yaml) (default) · [manifests/dim-cluster-maintenance.yaml](../../manifests/dim-cluster-maintenance.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-cluster-maintenance-values.yaml](../../helm/overlay-cluster-maintenance-values.yaml)
- **Node blocklist (eksctl path only):**
  - Path A: [manifests/disk-node-blocklist.yaml](../../manifests/disk-node-blocklist.yaml) (default) · [manifests/dim-node-blocklist.yaml](../../manifests/dim-node-blocklist.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-cluster-maintenance-values.yaml](../../helm/overlay-cluster-maintenance-values.yaml) + [helm/overlay-node-blocklist-values.yaml](../../helm/overlay-node-blocklist-values.yaml)

## References

- [scripts/labs/load-data.sh](../../scripts/labs/load-data.sh)
- [scripts/labs/lab-nodes.sh](../../scripts/labs/lab-nodes.sh) — Phase 2 optional `--replace-zone` (Lab 2.5)
- [Node maintenance](https://aerospike.com/docs/kubernetes/manage/node-maintenance)
- [Lab 0.5 — local PVC cleanup](../00-environment-setup/05-storage-layer.md#instructor-demo--local-pvc-cleanup-on-node-failure)

