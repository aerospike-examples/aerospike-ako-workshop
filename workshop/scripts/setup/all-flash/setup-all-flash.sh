#!/usr/bin/env bash
# Setup step 0.8 — dedicated all-flash cluster for Section 4.
#
# Opt-in: setup-all.sh does not run this by default (it is a third cluster).
#   ./scripts/setup/setup-all.sh --step 0.8
#   ./scripts/setup/all-flash/setup-all-flash.sh
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

echo "=== All-flash cluster setup (Section 4) ==="
echo "Cluster:   ${ALL_FLASH_CLUSTER_NAME} ($(provider_display_name))"
echo "Nodes:     ${ALL_FLASH_NODE_TYPE} × ${ALL_FLASH_NODE_COUNT} (max ${ALL_FLASH_NODE_COUNT_SCALED} for Lab 4.2)"
echo "AKO:       ${ALL_FLASH_AKO_VERSION}  (Lab 4.1 deploys Aerospike)"
echo ""

export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"

if cluster_exists "${ALL_FLASH_CLUSTER_NAME}"; then
  echo "Cluster ${ALL_FLASH_CLUSTER_NAME} already exists — skipping bootstrap"
  ensure_all_flash_kubecontext
  "${ALL_FLASH_DIR}/ensure-nodegroup.sh"
else
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    "${ALL_FLASH_DIR}/00-bootstrap-gke.sh"
  else
    "${ALL_FLASH_DIR}/00-bootstrap-eks.sh"
  fi
fi

"${ALL_FLASH_DIR}/setup-all-flash-post-bootstrap.sh"
merge_kubeconfig_into_default "$(kubeconfig_path_for_cluster "${ALL_FLASH_CLUSTER_NAME}")"
