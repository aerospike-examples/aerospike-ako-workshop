# Lab 2.5 — K8s Worker Node Maintenance (Karpenter)

> **Node provisioning:** This guide is for `NODE_PROVISIONING=karpenter`. If you use eksctl MNG, use [Lab 2.5 — K8s Worker Node Maintenance](05-k8s-node-maintenance.md) instead — do not mix guides mid-session.

| Field | Value |
|-------|-------|
| Lab ID | `2.5` |
| Section | Maintenance & Upgrade |
| Cluster | `my-cluster` |
| Node provisioning | **Karpenter** |
| AKO min version | `4.5.0` |
| Aerospike baseline | 3-node device storage on local-ssd (**8.1.2.x**); in-memory with `--dim` |
| Deploy path | both |
| Duration | ~25 min (+ optional ~15 min add-on) |
| Validation status | `draft` |
| Official docs | [Node maintenance](https://aerospike.com/docs/kubernetes/manage/node-maintenance) |

## Takeaway

On Karpenter, use **drain + AKO safe eviction** for planned node maintenance. Safe eviction blocks drain **only while Aerospike migration is active**; without active migration, drain cordons the node. **local-ssd PVCs** pin pods to the node until claims are cleared — node termination triggers the PVC cleanup controller and pod rescheduling on a replacement NodeClaim.

For **Karpenter-initiated** disruption (consolidation, drift/AMI rollouts), pair safe eviction with a correctly sized **`terminationGracePeriod`** — do not rely on `k8sNodeBlockList` ([AKO #305](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305)).

## Prerequisites

- `NODE_PROVISIONING=karpenter`
- Lab 2.4 complete — cluster on **8.1.2.x** (device storage default; in-memory with `--dim`)
- Safe pod eviction enabled on the operator (complete [Enable safe pod eviction](#enable-safe-pod-eviction-required) below) — **disabled by default** in AKO
- NodePool `terminationGracePeriod` ≥600s (configured in bootstrap)
- Cluster `Running`; phase `Completed`

## Enable safe pod eviction (required)

AKO's [safe pod eviction webhook](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#safe-pod-eviction-webhook) intercepts pod eviction API calls from `kubectl drain`. When migration is active, the webhook denies eviction and AKO migrates data safely. When migration is **not** active, drain proceeds — local PVC node affinity is the next constraint.

**This feature is disabled by default.** Without it, Phase 2 drain is never blocked by the webhook regardless of migration state.

**Workshop defaults:**

| Path | Enabled at install? | Action before Lab 2.5 |
|------|---------------------|------------------------|
| **A — OLM** | **No** — not set by `./scripts/setup/03-install-ako.sh` | Patch subscription with `ENABLE_SAFE_POD_EVICTION=true` (below) |
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

An empty cluster migrates too fast to observe during drain (especially in-memory — use `--dim` or pre-load data). Load records using the `app` user (`read` + `write` roles; secret `auth-app-secret` / password `app123`), defined in the maintenance baseline manifest.

**Option A — load after Phase 0:**

```bash
./scripts/labs/load-data.sh
```

**Option B — combine deploy + load** (skip Phase 0 if using this):

```bash
./scripts/labs/prepare-lab.sh 2.5 --load-data
```

Tunable via env when using Option A (increase if migration completes too quickly):

| Variable | Default | Purpose |
|----------|---------|---------|
| `MIGRATION_LOAD_RECORDS` | `5000000` | Record count |
| `MIGRATION_LOAD_OBJECT_SIZE` | `1024` | Bytes per object (`-o S1024`) |
| `MIGRATION_LOAD_THREADS` | `64` | asbench threads (`-z`) |

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

| Volume | StorageClass | Node loss / drain behavior |
|--------|--------------|----------------------------|
| Workdir | `ssd` (network-attached) | Detaches and reattaches on another node |
| Namespace data | `local-ssd` (instance store) | **Pinned** to the node via PVC node affinity |

**local-ssd PVCs cannot move.** A pod with a bound local PVC stays on that node (or enters `Pending`) until the claim is deleted. This is independent of the eviction webhook.

**AKO** `localStorageClasses`**: The maintenance baseline sets `spec.storage.localStorageClasses: [local-ssd]` so AKO deletes local PVCs during planned migration ([Aerospike docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance/#using-kubectl-drain)).

**PVC cleanup controller:** When a worker node is terminated, the `local-volume-node-cleanup-controller` (Lab 0.5) deletes orphaned `local-ssd` PVCs after a 60s delay — see [Lab 0.5 instructor demo](../00-environment-setup/05-storage-layer.md#instructor-demo--local-pvc-cleanup-on-node-failure).

> `--dim` **path:** In-memory clusters have no local PVC pinning. Migration is faster; use abbreviated observe steps in Phases 2–3 and skip Phase 4 (no instance-store cleanup needed).

## Phase 2 — Drain + observe (core demo)

Use **two terminals** for the primary path. The webhook blocks drain **only while migration is active**.

On Karpenter, **Phase 4 NodeClaim replacement** provisions same-zone capacity automatically — no manual nodegroup scale-up before drain.

### 2a — Capture pod placement

Drain the node hosting `aerocluster-0-0` and confirm the cluster is ready:

```bash
kubectl -n aerospike get pods -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}{.spec.image}{"\n"}'
NODE=$(kubectl -n aerospike get pod aerocluster-0-0 -o jsonpath='{.spec.nodeName}')
echo "Maintenance target node (aerocluster-0-0): ${NODE}"
```

**Expected:** 3 pods `Running`; CR phase `Completed`; image `8.1.2.x`; no `spec.operations` in CR; `$NODE` is the worker running `aerocluster-0-0`.

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

## Phase 4 — Node termination + PVC cleanup

Simulate completing node maintenance — terminate the cordoned worker and let the PVC cleanup controller free any orphaned claims. See [Lab 2.5 eksctl Phase 4](05-k8s-node-maintenance.md#phase-4--node-termination--pvc-cleanup-device-storage) for the equivalent manual terminate commands on the ASG path.

Pick **one** termination method below (both reach the same pass criteria).

### 4a — Primary: NodeClaim delete (Karpenter-native)

Replace the drained worker via Karpenter NodeClaim lifecycle:

1. Delete the NodeClaim for `$NODE`:

   ```bash
   CLAIM=$(kubectl get nodeclaims -o jsonpath="{.items[?(@.status.nodeName==\"${NODE}\")].metadata.name}")
   kubectl delete nodeclaim "$CLAIM"
   ```

2. Watch NodeClaim termination and replacement:

   ```bash
   kubectl get nodeclaims,nodes          # snapshot (both types)
   kubectl get nodeclaims -w             # live watch — `-w` accepts one resource type only
   ```

3. Watch PVC cleanup and pod reschedule:

   ```bash
   kubectl -n kube-system logs deploy/local-volume-node-cleanup-controller -f
   kubectl -n aerospike get pvc -w
   kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster -o wide -w
   ```

### 4b — Alternate: Manual EC2 termination (same as eksctl)

Same outcome as [eksctl Phase 4](05-k8s-node-maintenance.md#phase-4--node-termination--pvc-cleanup-device-storage): terminate the cordoned worker and let the PVC cleanup controller free orphaned claims. Use when you want the **same demo steps as the ASG/eksctl lab**, or to show node-loss + cleanup-controller behavior without using the NodeClaim API.

```bash
source scripts/env/workshop.env
INSTANCE_ID=$(kubectl get node "$NODE" -o jsonpath='{.spec.providerID}' | sed 's|.*/||')
kubectl delete node "$NODE"
aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "$INSTANCE_ID"
```

Watch cleanup and reschedule:

```bash
kubectl -n aerospike get pvc -w
kubectl -n aerospike get pod -l aerospike.com/cr=aerocluster -o wide -w
```

Wait for replacement node:

```bash
kubectl get nodes -w
kubectl get nodeclaims -w
```

**Karpenter notes (manual path):**

- Do **not** use `kubectl delete node --force` — bypasses AKO safe eviction webhook.
- Orphaned NodeClaim may linger briefly after instance termination; Karpenter reconciles it automatically.
- Same ~60s PVC cleanup delay via `local-volume-node-cleanup-controller` (Lab 0.5).
- Karpenter still provisions a same-zone replacement when the rescheduling pod needs capacity (may already exist if nominated earlier).

### Pass (both paths)

**Pass:** Orphaned local-ssd PVCs removed; replacement node `Ready` (Karpenter-provisioned); `aerocluster-0-0` pod `Running` on new node; CR `Completed`.

Ctrl+C once replacement is stable. `nvme-bootstrap` initializes NVMe on the new instance (Lab 0.5).

## Steps — Observe Karpenter disruption (optional demo)

After Phase 4, optionally show broader Karpenter node lifecycle:

1. Watch NodeClaim termination:

   ```bash
   kubectl get nodeclaims,nodes          # snapshot (both types)
   kubectl get nodeclaims -w             # live watch — `-w` accepts one resource type only
   ```

2. Optionally delete a NodeClaim to trigger replacement:

   ```bash
   CLAIM=$(kubectl get nodeclaims -o jsonpath='{.items[0].metadata.name}')
   kubectl delete nodeclaim "$CLAIM"
   ```

   **Expected:** Karpenter provisions replacement i8g node; `nvme-bootstrap` DaemonSet initializes NVMe.

3. Discuss NodePool disruption and grace settings:

   ```bash
   kubectl get nodepool "${KARPENTER_NODEPOOL_NAME}" -o yaml | grep -E 'disruption:|terminationGracePeriod|expireAfter'
   ```

   Note `terminationGracePeriod` — covered in the [add-on](#terminationgraceperiod--workshop-baseline-and-production-sizing) below.

   **Do not** force-delete nodes — bypasses AKO safe eviction webhook.

## Add-on — Graduating from `do-not-disrupt` to Karpenter-native disruption (~15 min)

> **Instructor-led discussion.** Run after the drain demo when the audience manages Karpenter + Aerospike in production and is planning to allow voluntary Karpenter disruption (consolidation, drift, AMI rollouts). No live cluster changes required unless you choose to demo consolidation policy inspection.

Many teams start with **`karpenter.sh/do-not-disrupt`** on Aerospike pods to block Karpenter from voluntarily picking those nodes for consolidation or drift. That is a common, conservative **Phase 1** — but it is not a long-term strategy: it blocks cost optimization, AMI drift, and automated node lifecycle. The goal of this add-on is to show how to **graduate safely** using the same AKO protections demonstrated in the drain path above.

### Three layers — complementary, not interchangeable

| Layer | Mechanism | Blocks what | Does **not** block |
|-------|-----------|-------------|-------------------|
| **1 — Karpenter opt-out** | `karpenter.sh/do-not-disrupt` on pod (or node) | Voluntary consolidation and drift | Expiration, Spot interruption, manual `kubectl delete node`, node repair |
| **2 — AKO safe eviction** | `safePodEviction.enable=true` (operator webhook) | Premature **API eviction** until Aerospike migration completes | Karpenter **force-delete** after grace period elapses |
| **3 — Karpenter force ceiling** | NodePool `spec.template.spec.terminationGracePeriod` | *(Does not block — sets max wait before force termination)* | N/A — this is the upper bound on how long layer 2 has to finish |

AKO's [node maintenance docs](https://aerospike.com/docs/kubernetes/manage/node-maintenance) warn that Karpenter uses a **Drain → Wait → Force-Delete** flow: the safe eviction webhook can deny the initial eviction, but Karpenter will **force-terminate** pods once `terminationGracePeriod` expires. Size that period for your **worst-case Aerospike migration**, not for a typical drain.

```mermaid
sequenceDiagram
    participant K as Karpenter
    participant API as Kubernetes API
    participant AKO as AKO safe eviction webhook
    participant AS as Aerospike pod

    K->>API: Evict pod (consolidation / drift / drain)
    API->>AKO: Validate eviction
    AKO-->>API: Deny (migration in progress)
    Note over AS: AKO migrates data until CR reaches Completed
    K->>API: Retry eviction
    API->>AKO: Validate eviction
    AKO-->>API: Allow
    API->>AS: Pod terminates gracefully

    Note over K,AS: If migration exceeds terminationGracePeriod
    K->>AS: Force-delete pod (bypasses webhook)
```

### `terminationGracePeriod` — workshop baseline and production sizing

Workshop NodePools set **`terminationGracePeriod: 600s`** (10 minutes) at bootstrap:

```yaml
# workshop/scripts/setup/karpenter/02-nodepool-aerospike-zone.yaml
spec:
  template:
    spec:
      expireAfter: 720h
      terminationGracePeriod: 600s   # max wait before Karpenter force-deletes
  disruption:
    consolidationPolicy: WhenEmpty   # set KARPENTER_CONSOLIDATION=Off in workshop.env for demo-safe minimal churn
    consolidateAfter: 30m
```

Inspect the live value on any Aerospike NodePool:

```bash
kubectl get nodepool -l workshop.aerospike.com/workload=aerospike \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.terminationGracePeriod}{"\n"}{end}'
```

**How to think about sizing:**

| Factor | Guidance |
|--------|----------|
| **What it controls** | Maximum time Karpenter waits on a blocking eviction (including AKO-denied evictions) before **force-deleting** the pod |
| **What it does *not* control** | AKO `safePodEviction.timeoutSeconds` — that is per-request webhook response time, not migration budget |
| **Workshop default (600s)** | Reasonable starting point for a 3-node cluster; validate in **your** environment |
| **Production rule of thumb** | Set ≥ measured P99 migration time under load + pod startup/index rebuild buffer; err high for local-storage / large-index clusters |
| **Pair with `expireAfter`** | If pods carry `do-not-disrupt`, Karpenter docs require `terminationGracePeriod` when using `expireAfter` — otherwise nodes can stick indefinitely |

**Sizing exercise (discussion, not a lab step):**

1. Run a controlled drain (primary path above) and time CR `Completed`:

   ```bash
   time kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed \
     aerospikecluster/aerocluster --timeout=900s
   ```

2. Add headroom (e.g. 2× measured migration) for concurrent consolidations or degraded nodes.
3. Patch NodePool only after review — example (do **not** run live in class without a maintenance window):

   ```bash
   kubectl patch nodepool "${KARPENTER_NODEPOOL_NAME}-us-east-1c" --type=merge \
     -p '{"spec":{"template":{"spec":{"terminationGracePeriod":"900s"}}}}'
   ```

### Graduation path — Phase 1 → Phase 3

| Phase | Configuration | When to use |
|-------|---------------|-------------|
| **1 — Block voluntary disruption** | `karpenter.sh/do-not-disrupt: "true"` on Aerospike pods; `KARPENTER_CONSOLIDATION=Off` or `WhenEmpty` + long `consolidateAfter`; monitoring | Initial Karpenter adoption; validating migration behavior |
| **2 — Enable AKO protection** | `safePodEviction.enable=true`; `terminationGracePeriod` sized from measurements; keep `do-not-disrupt` until Phase 2 is validated | Before removing annotations — safe eviction alone is insufficient without grace period headroom |
| **3 — Allow selective disruption** | Remove `do-not-disrupt` from Aerospike pods; enable `consolidationPolicy: WhenEmpty`; tune `consolidateAfter`; use **manual drain** for planned maintenance | Steady state — cost optimization + AMI drift with AKO migration gating |

**Phase 1 — audit current protection (read-only):**

```bash
# Pods opted out of voluntary Karpenter disruption
kubectl get pods -n aerospike -l aerospike.com/cr=aerocluster \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.karpenter\.sh/do-not-disrupt}{"\n"}{end}'

# NodePool disruption + grace settings
kubectl get nodepool -o custom-columns=\
NAME:.metadata.name,\
CONSOLIDATION:.spec.disruption.consolidationPolicy,\
CONSOLIDATE_AFTER:.spec.disruption.consolidateAfter,\
GRACE:.spec.template.spec.terminationGracePeriod,\
EXPIRE:.spec.template.spec.expireAfter
```

**Phase 3 — controlled rollout checklist (production, not live demo):**

1. Confirm safe pod eviction is enabled: `./scripts/labs/verify-safe-pod-eviction.sh`
2. Measure worst-case migration time; set `terminationGracePeriod` accordingly.
3. Enable `WhenEmpty` consolidation on one NodePool; keep `do-not-disrupt` on other pools until validated.
4. Watch for `aerospike.com/eviction-blocked` and CR phase during first consolidation events.
5. Alert on force-delete / unexpected pod restarts — indicates grace period too short.
6. **Planned maintenance** (patching, hardware, node retirement): always prefer **cordon + drain** (primary path above), not reliance on consolidation.

### What `do-not-disrupt` does not protect against

Even with annotations, these can still terminate nodes — safe eviction + grace period still apply, but Karpenter will not skip the event:

| Event | Blocked by `do-not-disrupt`? | Mitigation |
|-------|------------------------------|------------|
| Consolidation / drift | Yes (voluntary) | Remove annotation in Phase 3 when ready |
| `expireAfter` node expiry | **No** | Size `terminationGracePeriod`; plan replacement |
| Spot / scheduled interruption | **No** | On-demand capacity; rack awareness |
| Manual `kubectl delete node` | **No** | Use drain; never `--force` |
| AMI drift (EC2NodeClass update) | Partially — nodes with annotated pods excluded unless grace period applies | Coordinate AMI rollouts with maintenance windows |

Workshop EC2NodeClass tracks **`al2023@latest`** (`01-ec2nodeclass-i8g.yaml`). Production AMI rollouts should be treated as **planned maintenance**: drain nodes hosting Aerospike pods, or validate Phase 3 protections before allowing drift.

### Key messages for the customer conversation

- **`do-not-disrupt` is a valid safety rail**, not an anti-pattern — but plan to graduate.
- **Safe eviction and `do-not-disrupt` are complementary** — neither replaces the other.
- **`terminationGracePeriod` is the force-delete ceiling** — if migration exceeds it, Aerospike pods can be force-deleted and you risk reindex/cold-start penalties.
- **Planned maintenance → drain**; **automated lifecycle → safe eviction + grace period + gradual consolidation enablement**.

## Verify (pass/fail)

```bash
kubectl -n aerospike get pods -o wide
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl get nodes
```

**Pass:** Webhook denied drain during active migration; node cordoned after CR `Completed`; local PVCs cleaned up after Phase 4 (NodeClaim delete or manual EC2 terminate); Aerospike pods `Running` on other nodes; CR `Completed`. No `k8sNodeBlockList` applied.

## Observe

- Safe eviction webhook denies eviction API **only while migration is active**
- Without active migration, drain cordons the node; local PVC node affinity prevents pod reschedule (unless AKO deletes local claims via `localStorageClasses`)
- NodeClaim deletion or manual EC2 terminate → PVC cleanup controller → pod reschedules on fresh local storage in the same AZ
- Karpenter provisions replacement capacity automatically — no manual nodegroup scale-up
- `k8sNodeBlockList` is **not supported** on Karpenter ([AKO #305](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305))
- Cluster stays available during migration

## What NOT to demo on Karpenter

| Technique | Status |
|-----------|--------|
| `kubectl drain` + safe eviction | **Supported** |
| `k8sNodeBlockList` | **Unsupported** |
| `kubectl delete node --force` | **Never** — bypasses webhook |

### Handoff

Proceed to [Lab 2.6](06-k8s-control-plane-upgrade.md). Aerospike cluster should remain `Running`; worker nodes should be schedulable.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Migration completes too fast to observe | Increase `MIGRATION_LOAD_RECORDS` (e.g. `8000000`); or use [Phase 2 optional (instructor)](#2-optional-instructor--force-visible-drain-block) |
| Drain not blocked / no webhook denial | Confirm `ENABLE_SAFE_POD_EVICTION=true` via `./scripts/labs/verify-safe-pod-eviction.sh`; migration may have finished — use Phase 2 optional (instructor) |
| Drain succeeds but pod stuck on cordoned node | Expected Path A (local PVC pinning) — proceed to Phase 4 (NodeClaim delete or manual EC2 terminate) |
| Pod already Running on another node after drain | Expected Path B (AKO `localStorageClasses`) — proceed to Phase 4 |
| local-ssd PVC Pending | Re-run `./scripts/setup/08-validate-environment.sh`; confirm baseline local-ssd PVs |
| No `eviction-blocked` annotation | Normal once pod is Terminating; check CR phase and migrate stats instead |
| PVC not cleaned up after node delete | Check cleanup controller logs; wait 60s |
| Node not terminating after drain | Check PDB; verify `terminationGracePeriod` |
| Replacement node missing NVMe | Verify `nvme-bootstrap` DaemonSet Ready |
| Consolidation removes nodes mid-lab | Set `KARPENTER_CONSOLIDATION=Off` |
| Pod force-deleted during consolidation | `terminationGracePeriod` too short — increase and re-measure migration time |
| Node stuck after `do-not-disrupt` + `expireAfter` | Ensure `terminationGracePeriod` is set ([Karpenter disruption docs](https://karpenter.sh/docs/concepts/disruption/)) |
| Over-use of `do-not-disrupt` (>~30% of pods) | Audit quarterly; blocks consolidation and AMI drift efficiency |

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Maintenance cluster (8.1.2.x, extended grace period):**
  - Path A: [manifests/disk-cluster-maintenance.yaml](../../manifests/disk-cluster-maintenance.yaml) (default) · [manifests/dim-cluster-maintenance.yaml](../../manifests/dim-cluster-maintenance.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-cluster-maintenance-values.yaml](../../helm/overlay-cluster-maintenance-values.yaml)

## References

- [scripts/labs/load-data.sh](../../scripts/labs/load-data.sh)
- [scripts/labs/verify-safe-pod-eviction.sh](../../scripts/labs/verify-safe-pod-eviction.sh)
- [Node maintenance](https://aerospike.com/docs/kubernetes/manage/node-maintenance)
- [AKO #305 — blocklist + Karpenter](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305)
- [Karpenter — Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [Lab 0.5 — local PVC cleanup](../00-environment-setup/05-storage-layer.md#instructor-demo--local-pvc-cleanup-on-node-failure)
