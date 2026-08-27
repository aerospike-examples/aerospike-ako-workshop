# Lab 0.3 — Install AKO (Path B: Helm)

| Field | Value |
|-------|-------|
| Lab ID | `0.3` |
| Section | Environment Setup |
| EKS cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| AKO version | `${AKO_VERSION_START}` — default `4.2.0` |
| cert-manager | `v1.14.4` |
| Deploy path | B (Helm) |
| Duration | ~20 min |
| Validation status | `draft` |

## Takeaway

AKO is installed via Helm at `${AKO_VERSION_START}` (default **4.2.0**) with cert-manager and safe pod eviction enabled.

## Prerequisites

- Lab 0.2 and step **0.2-nodes** complete — unlike the OLM path, the Helm scripts do not wait for Ready nodes, so cert-manager and the operator need schedulable workload nodes already present
- `DEPLOY_PATH=helm` in workshop.env
- Helm on the client — `01-validate-client.sh` runs `helm version` but does not assert a minimum; Helm 3.12+ is recommended

## Steps

1. Install cert-manager and AKO:

   ```bash
   ./scripts/setup/03-install-ako.sh
   ```

   With `DEPLOY_PATH=helm` this dispatches to [`helm/setup-all-helm.sh`](../../scripts/setup/helm/setup-all-helm.sh), which:

   1. applies cert-manager **v1.14.4** from the upstream release manifest and waits up to 300s for its pods ([`helm/00-install-cert-manager.sh`](../../scripts/setup/helm/00-install-cert-manager.sh))
   2. adds/updates the Helm repo `${HELM_REPO}` (`https://aerospike.github.io/aerospike-kubernetes-enterprise`)
   3. runs `helm upgrade --install ${HELM_OPERATOR_RELEASE} aerospike/aerospike-kubernetes-operator -n ${OPERATOR_NAMESPACE} --create-namespace --version=${AKO_VERSION_START} -f helm/operator-values.yaml`
   4. waits on `rollout status deployment/${HELM_OPERATOR_RELEASE}`

2. Verify Helm release:

   ```bash
   helm list -n operators
   ```

   **Expected:** `aerospike-kubernetes-operator` at chart version `4.2.0`, status `deployed`.

3. Verify operator pods:

   ```bash
   kubectl -n operators get pods
   ```

   **Expected:** Controller manager `Running`.

## Verify (pass/fail)

```bash
helm list -n operators
```

**Pass:** Release `aerospike-kubernetes-operator` is `deployed` and the CHART column contains `${AKO_VERSION_START}` (default `4.2.0`). With `jq` installed (optional in Lab 0.1): `helm list -n operators -o json | jq '.[0].chart'`.

Key values in [helm/operator-values.yaml](../../helm/operator-values.yaml): `watchNamespaces=aerospike`, `safePodEviction.enable=true`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Webhook errors on CR apply | Wait for cert-manager pods Ready |
| Helm repo 404 in browser | Normal — use `helm repo add` CLI only |

## Not covered here

OLM install → [03-install-ako-olm.md](03-install-ako-olm.md)

## Teardown / handoff

Proceed to [Lab 0.4 — akoctl](04-install-akoctl.md).

## Workshop artifacts

- Path B: [helm/operator-values.yaml](../../helm/operator-values.yaml)

## References

- [Install AKO via Helm](https://aerospike.com/docs/kubernetes/install/helm/)
