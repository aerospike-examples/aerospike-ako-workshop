#!/usr/bin/env bash
# All-flash post-bootstrap: AKO, akoctl, secrets, index+data NVMe slices.
# Does not deploy Aerospike — that is Lab 4.1.
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${ALL_FLASH_CLUSTER_NAME}")"
apply_workshop_kubeconfig

# Captured before CLUSTER_NAME is pointed at the all-flash cluster below.
MAIN_CLUSTER_NAME="${CLUSTER_NAME}"
restore_main_kubecontext() {
  if cluster_exists "${MAIN_CLUSTER_NAME}"; then
    export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${MAIN_CLUSTER_NAME}")"
    apply_workshop_kubeconfig
    ensure_kubecontext "${MAIN_CLUSTER_NAME}" >/dev/null 2>&1 || true
    echo "Restored kubectl context to main cluster: ${MAIN_CLUSTER_NAME}"
  fi
}
trap restore_main_kubecontext EXIT

echo "=== All-flash post-bootstrap ==="
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext

ako_at_pin=0
if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  ako_ver="$(helm list -n "${OPERATOR_NAMESPACE}" -f "^${HELM_OPERATOR_RELEASE}$" -o json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print((d[0].get('app_version') or '') if d else '')" \
    2>/dev/null || true)"
  [[ "${ako_ver}" == "${ALL_FLASH_AKO_VERSION}" ]] && ako_at_pin=1
else
  ako_phase="$(kubectl get csv -n "${OPERATOR_NAMESPACE}" \
    "aerospike-kubernetes-operator.v${ALL_FLASH_AKO_VERSION}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "${ako_phase}" == "Succeeded" ]] && ako_at_pin=1
fi
if [[ "${ako_at_pin}" -eq 0 ]]; then
  "${ALL_FLASH_DIR}/01-install-ako.sh"
else
  echo "AKO ${ALL_FLASH_AKO_VERSION} already installed on all-flash cluster — skipping 01-install-ako.sh"
fi

# akoctl is a client-side plugin, but `akoctl auth create` grants RBAC per cluster:
# the operator ServiceAccount must exist in this cluster's namespace too, or the
# StatefulSet cannot create pods.
if ! command -v kubectl-akoctl >/dev/null 2>&1 ||
   ! kubectl -n "${NAMESPACE}" get serviceaccount aerospike-operator-controller-manager >/dev/null 2>&1; then
  "${ALL_FLASH_DIR}/../04-install-akoctl.sh"
else
  echo "akoctl installed and namespace RBAC present — skipping 04-install-akoctl.sh"
fi

# Same secrets as the main cluster (features.conf + lab auth passwords).
echo "Deploying secrets on all-flash cluster (same source as main cluster)..."
"${ALL_FLASH_DIR}/02-setup-storage-secrets.sh"

# Block storage class `ssd` for the Aerospike work directory (EBS on EKS, PD on GKE).
echo "Setting up block storage class on all-flash cluster..."
provider_setup_block_storage "${ALL_FLASH_CLUSTER_NAME}"

"${ALL_FLASH_DIR}/03-setup-local-storage.sh"

echo "=== All-flash cluster ready for Lab 4.1 (no AerospikeCluster yet) ==="
