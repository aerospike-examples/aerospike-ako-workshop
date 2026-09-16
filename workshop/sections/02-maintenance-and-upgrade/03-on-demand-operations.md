# Lab 2.3 — On-Demand Operations

| Field | Value |
|-------|-------|
| Lab ID | `2.3` |
| Section | Maintenance & Upgrade |
| Cluster | `my-cluster` |
| AKO min version | `4.4.0` |
| Aerospike baseline | 3-node on **8.1.0.x** (device storage default; same as `deploy-cluster.sh`) |
| Deploy path | both |
| Duration | ~10 min |
| Validation status | `draft` |
| Official docs | [On-demand operations](https://aerospike.com/docs/kubernetes/manage/configure/on-demand-operations) |

## Takeaway

`spec.operations` triggers targeted **PodRestart** (cold) or **WarmRestart** actions without changing `spec.image` or other cluster parameters. AKO allows **at most one** operation entry in the CR at a time.

## Prerequisites

- Lab 2.2 complete (AKO **4.4.0+**)
- Cluster Running on **8.1.0.x** with the same spec as [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (e.g. `./scripts/labs/deploy-cluster.sh`)
- AKO rejects applying `spec.operations` together with any other spec change (image, storage, namespace config, etc.) — operation manifests differ **only** by the `operations` block

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.image}{"\n"}'
kubectl -n aerospike get pods
```

**Expected:** Image `aerospike/aerospike-server-enterprise:8.1.0.0`; 3/3 pods `Running`; phase `Completed`.

If the cluster image or config does not match, redeploy the baseline first:

```bash
./scripts/labs/deploy-cluster.sh           # Path A
./scripts/labs/deploy-cluster-helm.sh      # Path B
```

### Helm chart version (Path B)

The `aerospike-cluster` chart `--version` must **match the installed AKO operator**, not the Lab 0.3 install pin.

| Variable | Purpose |
|----------|---------|
| `AKO_VERSION_START` | Operator **install** pin (Lab 0.3 only) |
| `AKO_VERSION_TARGET` | Curriculum **end-state** after the full Lab 2.2 ladder (4.5.0) — not a substitute for chart `--version` |
| `AKO_CLUSTER_CHART_VERSION` | Optional override; if unset, scripts read the **installed operator** (4.4.1 or 4.5.0 after Lab 2.2) |

After Lab 2.2, your operator may be **4.4.1** (short path) or **4.5.0** (full ladder). Workshop Helm scripts call `resolve_cluster_helm_chart_version()` to pick the right chart version automatically.

Manual `helm upgrade` steps for each operation are under **Part 1** and **Part 2** Path B below.

## Optional — continuous workload (Terminal B)

Open a **second terminal window**. Seed data if needed (`./scripts/labs/load-data.sh`), then:

```bash
./scripts/labs/run-lab-workload.sh start
```

Run Part 1 and Part 2 in Terminal A while watching throughput in Terminal B (`status`). Stop when done:

```bash
./scripts/labs/run-lab-workload.sh stop
```

## Background

| Operation | `kind` | Effect |
|-----------|--------|--------|
| Warm restart | `WarmRestart` | Aerospike process reloads in place; **database node uptime resets**, **pod uptime does not** |
| Cold restart | `PodRestart` | Pod deleted and recreated; process exits fully |

Both manifests carry the full cluster spec (use `disk-pod-*-op.yaml` by default or `pod-*-op.yaml` with `--dim`) plus a single `operations` entry. Optional `podList` scopes the operation to named pods; omit it to affect all pods (workshop default).

---

## Part 1 — WarmRestart

### Path A — kubectl

```bash
kubectl apply -f manifests/disk-pod-warm-restart-op.yaml
kubectl -n aerospike get pods -w
kubectl -n aerospike describe aerospikecluster aerocluster | grep -A10 Operations
```

**Expected:** Warm restart runs on all pods; pods are **not** deleted; cluster stays available. **Database node uptime** (Aerospike) resets; **pod uptime** (`status.startTime`) does not — the clearest signal that the process reloaded inside the existing pod.

### Path B — Helm

```bash
./scripts/labs/apply-pod-warm-restart-op-helm.sh
kubectl -n aerospike get pods -w
```

**Expected:** Warm restart runs on all pods; pods are **not** deleted; cluster stays available. **Database node uptime** (Aerospike) resets; **pod uptime** (`status.startTime`) does not.

### Manual equivalent (Helm)

The script runs `helm upgrade --install aerocluster` with the correct values file and chart `--version`. To run the same upgrade by hand (device storage default):

```bash
source scripts/env/workshop.env   # NAMESPACE, HELM_CLUSTER_RELEASE, etc.
source scripts/lib/common.sh
load_env

helm repo add aerospike "${HELM_REPO}" 2>/dev/null || true
helm repo update

helm upgrade --install "${HELM_CLUSTER_RELEASE}" aerospike/aerospike-cluster \
  --namespace "${NAMESPACE}" \
  --version="$(resolve_cluster_helm_chart_version)" \
  -f helm/base-disk-cluster-values.yaml \
  -f helm/overlay-pod-warm-restart-op-values.yaml

kubectl -n aerospike get pods -w
kubectl -n aerospike describe aerospikecluster aerocluster | grep -A10 Operations
```

In-memory variant: use `-f helm/base-dim-cluster-values.yaml -f helm/overlay-pod-warm-restart-op-values.yaml` (with `--dim` / `CLUSTER_STORAGE=dim`).

**Expected:** Same as Path A — operation reconciles; phase returns `Completed`.

### Optional — single-pod scope

To warm-restart one pod only, add `podList` under `operations` (see [AKO config reference](https://aerospike.com/docs/kubernetes/reference/config-reference)):

```yaml
operations:
  - kind: WarmRestart
    id: warm-restart-1
    podList:
      - aerocluster-0-0
```

---

## Part 2 — PodRestart (cold restart)

Wait until Part 1 completes (`kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}'` → `Completed`).

Apply the cold-restart manifest (replaces the operation `kind` / `id` in the same CR):

### Path A — kubectl

```bash
kubectl apply -f manifests/disk-pod-restart-op.yaml
kubectl -n aerospike get pods -w
kubectl -n aerospike describe aerospikecluster aerocluster | grep -A10 Operations
```

**Expected:** Pods restart sequentially; operation status progresses to complete in the CR; cluster phase returns `Completed`.

### Path B — Helm

```bash
./scripts/labs/apply-pod-restart-op-helm.sh
kubectl -n aerospike get pods -w
```

**Expected:** Pods restart sequentially; operation status progresses to complete in the CR; cluster phase returns `Completed`.

### Manual equivalent (Helm)

The script runs `helm upgrade --install aerocluster` with the correct values file and chart `--version`. To run the same upgrade by hand (device storage default):

```bash
source scripts/env/workshop.env   # NAMESPACE, HELM_CLUSTER_RELEASE, etc.
source scripts/lib/common.sh
load_env

helm repo add aerospike "${HELM_REPO}" 2>/dev/null || true
helm repo update

helm upgrade --install "${HELM_CLUSTER_RELEASE}" aerospike/aerospike-cluster \
  --namespace "${NAMESPACE}" \
  --version="$(resolve_cluster_helm_chart_version)" \
  -f helm/base-disk-cluster-values.yaml \
  -f helm/overlay-pod-restart-op-values.yaml

kubectl -n aerospike get pods -w
kubectl -n aerospike describe aerospikecluster aerocluster | grep -A10 Operations
```

In-memory variant: use `-f helm/base-dim-cluster-values.yaml -f helm/overlay-pod-restart-op-values.yaml` (with `--dim` / `CLUSTER_STORAGE=dim`).

**Expected:** Same as Path A — sequential pod restarts; operation completes; phase `Completed`.

---

## Verify (pass/fail)

After each part:

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl -n aerospike get pods -o wide
```

**Pass:** Phase `Completed`; 3/3 pods `Running`.

Compare restart behavior after Part 1 (**WarmRestart**):

```bash
# Pod uptime — should be unchanged from before WarmRestart (same startTime)
kubectl -n aerospike get pod aerocluster-0-0 -o jsonpath='{.metadata.name}{" startTime="}{.status.startTime}{"\n"}'

# Database node uptime — should reset (low seconds) after WarmRestart
kubectl exec -n aerospike aerocluster-0-0 -c aerospike-server -- \
  asinfo -v 'statistics' | tr ';' '\n' | grep '^uptime'
```

**Pass (WarmRestart):** `startTime` on the pod is old; `uptime` from `asinfo` is recently reset (near zero compared to pre-operation value).

After Part 2 (**PodRestart**):

```bash
# PodRestart: container start time resets (pod may have new UID)
kubectl -n aerospike get pod aerocluster-0-0 -o jsonpath='{.status.startTime}{"\n"}{.status.containerStatuses[?(@.name=="aerospike-server")].restartCount}{"\n"}'
```

**Pass (PodRestart):** Recent `startTime` and/or elevated `restartCount` — contrast with Part 1, where the pod object was unchanged while Aerospike reloaded in place.

## Observe

- **WarmRestart** vs **PodRestart** — warm keeps the pod running; cold deletes the pod
- **WarmRestart:** Aerospike **node uptime** resets; Kubernetes **pod uptime** (`startTime`) does not — process reload inside the same pod
- Difference from image upgrade ([Lab 2.4](04-upgrade-aerospike-db.md)) — operations do not change `spec.image`
- Only one `spec.operations` entry allowed at a time; apply the next manifest after the prior operation completes
- Operator logs show operation reconciliation

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Operation stuck / not starting | Confirm prior operation finished; CR has only one `operations` entry |
| Apply rejected after Part 1 | Wait for phase `Completed` before applying cold-restart manifest |
| Webhook: cannot change Operations with image update | Operation manifest spec must match the running cluster — redeploy with `./scripts/labs/deploy-cluster.sh` (or Helm equivalent) so image and config align before applying operations |
| Cluster spec drift | Manifests mirror `disk-cluster.yaml` (`8.1.0.0`, device namespace) — re-run `./scripts/labs/deploy-cluster.sh` if needed |

## Handoff

Proceed to [Lab 2.4](04-upgrade-aerospike-db.md).

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Baseline (3 nodes, 8.1.0.x):**
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) (default) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)
- **WarmRestart operation:**
  - Path A: [manifests/disk-pod-warm-restart-op.yaml](../../manifests/disk-pod-warm-restart-op.yaml) (default) · [manifests/dim-pod-warm-restart-op.yaml](../../manifests/dim-pod-warm-restart-op.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-pod-warm-restart-op-values.yaml](../../helm/overlay-pod-warm-restart-op-values.yaml)
- **PodRestart operation:**
  - Path A: [manifests/disk-pod-restart-op.yaml](../../manifests/disk-pod-restart-op.yaml) (default) · [manifests/dim-pod-restart-op.yaml](../../manifests/dim-pod-restart-op.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-pod-restart-op-values.yaml](../../helm/overlay-pod-restart-op-values.yaml)

## References

- [On-demand operations](https://aerospike.com/docs/kubernetes/manage/configure/on-demand-operations)
- [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh)
