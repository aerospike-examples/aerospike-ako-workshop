#!/usr/bin/env bash
# Upgrade-lab post-bootstrap: AKO, akoctl, secrets, local storage (disk), Aerospike (Lab 2.6 prep).
set -euo pipefail
UPGRADE_DIR="$(dirname "$0")"
SETUP_DIR="$(cd "${UPGRADE_DIR}/.." && pwd)"
source "${UPGRADE_DIR}/../../lib/common.sh"
source "${UPGRADE_DIR}/../../lib/cluster-storage.sh"
load_env
export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${UPGRADE_LAB_CLUSTER_NAME}")"
apply_workshop_kubeconfig

restore_main_kubecontext() {
  if cluster_exists "${CLUSTER_NAME}"; then
    export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${CLUSTER_NAME}")"
    apply_workshop_kubeconfig
    ensure_kubecontext "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    echo "Restored kubectl context to main cluster: ${CLUSTER_NAME}"
  fi
}
trap restore_main_kubecontext EXIT

echo "=== Upgrade-lab post-bootstrap ==="
export CLUSTER_NAME="${UPGRADE_LAB_CLUSTER_NAME}"
ensure_upgrade_lab_kubecontext

if ! kubectl get csv -n "${OPERATOR_NAMESPACE}" 2>/dev/null | grep -q aerospike-kubernetes-operator; then
  "${UPGRADE_DIR}/01-install-ako.sh"
else
  echo "AKO already installed on upgrade-lab — skipping 01-install-ako.sh"
fi

# akoctl is a client-side plugin, but `akoctl auth create` grants RBAC per cluster:
# the operator ServiceAccount must exist in this cluster's namespace too, or the
# StatefulSet cannot create pods.
if ! command -v kubectl-akoctl >/dev/null 2>&1 ||
   ! kubectl -n "${NAMESPACE}" get serviceaccount aerospike-operator-controller-manager >/dev/null 2>&1; then
  "${UPGRADE_DIR}/../04-install-akoctl.sh"
else
  echo "akoctl installed and namespace RBAC present — skipping 04-install-akoctl.sh"
fi

# Same secrets as the main cluster (features.conf + lab auth passwords) — always
# re-apply so upgrade-lab stays in sync after partial setup or main-cluster refresh.
echo "Deploying secrets on upgrade-lab (same source as main cluster)..."
"${UPGRADE_DIR}/02-setup-storage-secrets.sh"

upgrade_lab_storage="$(resolve_cluster_storage 2.6)"
echo "Upgrade-lab cluster storage: ${upgrade_lab_storage} ($(cluster_storage_reason 2.6 "${upgrade_lab_storage}"))"

expected_engine="device"
[[ "${upgrade_lab_storage}" == dim ]] && expected_engine="memory"

if [[ "${upgrade_lab_storage}" == disk ]]; then
  echo "Setting up local storage on upgrade-lab..."
  "${SETUP_DIR}/06-setup-local-storage.sh"
fi

if kubectl -n "${NAMESPACE}" get aerospikecluster aerocluster >/dev/null 2>&1; then
  existing_engine="$(cluster_storage_engine_type)"
  if [[ "${existing_engine}" == "${expected_engine}" ]]; then
    echo "AerospikeCluster aerocluster already exists on upgrade-lab (${existing_engine}) — skipping deploy"
    echo "=== Upgrade-lab ready for Lab 2.6 ==="
    exit 0
  fi
  echo "Existing aerocluster uses ${existing_engine} — redeploying for ${upgrade_lab_storage} storage..."
  kubectl delete aerospikecluster aerocluster -n "${NAMESPACE}" --ignore-not-found
  wait_for_cluster_gone 300 || true
fi

"${UPGRADE_DIR}/03-deploy-cluster.sh"

echo "=== Upgrade-lab ready for Lab 2.6 ==="
