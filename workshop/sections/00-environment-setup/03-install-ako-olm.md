# Lab 0.3 — Install AKO (Path A: OLM)

| Field | Value |
|-------|-------|
| Lab ID | `0.3` |
| Section | Environment Setup |
| EKS cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| AKO version | `${AKO_VERSION_START}` — default `4.2.0` (intentionally older for Lab 2.2) |
| OLM version | `${OLM_VERSION}` (default `v0.43.0`) |
| Deploy path | A (kubectl/OLM) |
| Duration | ~20 min |
| Validation status | `draft` |

## Takeaway

AKO is installed via OLM at version **4.2.0**, watching the `aerospike` namespace.

## Prerequisites

- Lab 0.2 and step **0.2-nodes** complete (schedulable workload nodes available)
- `DEPLOY_PATH=olm` in workshop.env

## Steps

1. Install AKO:

   ```bash
   ./scripts/setup/03-install-ako.sh
   ```

   With `DEPLOY_PATH=olm` this dispatches to [`olm/setup-all-olm.sh`](../../scripts/setup/olm/setup-all-olm.sh), which:

   1. clones the `aerospike-kubernetes-operator` repo to `${OPERATOR_REPO}` if it is missing — a local reference copy, not the source of this install
   2. installs OLM `${OLM_VERSION}` from the upstream release `install.sh` when it is not already Ready, first waiting up to 600s for a Ready node so `olm-operator` can schedule (this is why step 0.2-nodes must come first)
   3. creates namespace `${OPERATOR_NAMESPACE}` (default `operators`)
   4. skips the install when a CSV from the Lab 2.2 upgrade ladder is already `Succeeded` — including versions newer than the start pin
   5. creates Subscription `aerospike-kubernetes-operator` (channel `stable`, `startingCSV` pinned to `${AKO_VERSION_START}`, `installPlanApproval: Manual`)
   6. **approves the pending InstallPlan itself** (up to 300s) and waits for the CSV to reach `Succeeded` (up to 600s)

2. Confirm the CSV the script already waited for:

   ```bash
   kubectl get csv -n operators aerospike-kubernetes-operator.v4.2.0
   ```

   **Expected:** PHASE `Succeeded`. Add `-w` to watch the reconcile live when demonstrating; substitute your `${AKO_VERSION_START}` if it differs from `4.2.0`.

3. Verify operator pod:

   ```bash
   kubectl -n operators get pods
   kubectl -n operators logs deployment/aerospike-operator-controller-manager --tail=20
   ```

   **Expected:** Controller manager pod `Running`; logs show webhook registration.

## Verify (pass/fail)

```bash
kubectl get csv -n operators | grep aerospike-kubernetes-operator.v4.2.0
```

**Pass:** CSV exists with phase `Succeeded`.

## Observe

- OLM creates Subscription `aerospike-kubernetes-operator` and an InstallPlan in the `operators` namespace
- Approval is `Manual` so the stable channel head cannot pull in a newer operator — the script approves only the pinned InstallPlan
- Operator version pinned to `${AKO_VERSION_START}` for the upgrade ladder in Lab 2.2 (`AKO_UPGRADE_LADDER`: 4.3.0 → 4.4.1 → 4.5.0)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| CSV NotFound / wrong version | OperatorHub stable head may be newer than `${AKO_VERSION_START}`. Script pins `startingCSV`; if an earlier run left a stale subscription, delete it: `kubectl delete subscription -n operators aerospike-kubernetes-operator --ignore-not-found` then re-run `./scripts/setup/03-install-ako.sh` |
| CSV Pending | The script already approves pending InstallPlans (up to 300s). Manual fallback: `kubectl get installplan -n operators` then `kubectl patch installplan <name> -n operators --type merge -p '{"spec":{"approved":true}}'` |
| Operator pod CrashLoop | Check logs; verify cluster has sufficient resources |

## Not covered here

Helm install → [03-install-ako-helm.md](03-install-ako-helm.md)

## Teardown / handoff

Proceed to [Lab 0.4 — akoctl](04-install-akoctl.md).

## Workshop artifacts

- Path A (this guide): OLM install via OperatorHub — no workshop manifest
- Path B equivalent: [helm/operator-values.yaml](../../helm/operator-values.yaml) — see [03-install-ako-helm.md](03-install-ako-helm.md)

## References

- [Install AKO via OLM](https://aerospike.com/docs/kubernetes/install/olm/)
