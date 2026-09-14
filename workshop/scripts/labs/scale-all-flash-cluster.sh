#!/usr/bin/env bash
# Lab 4.2 — scale the all-flash cluster (default 3 -> 4), growing the node pool first.
#
# Usage: ./scripts/labs/scale-all-flash-cluster.sh [size]
set -euo pipefail
SCRIPT_DIR_LABS="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR_LABS}/../lib/common.sh"
source "${SCRIPT_DIR_LABS}/../lib/all-flash.sh"
load_env
require_cmd kubectl

SIZE="${1:-${ALL_FLASH_AEROSPIKE_SIZE_SCALED}}"

echo "=== Scaling all-flash cluster to ${SIZE} pods (DEPLOY_PATH=${DEPLOY_PATH}) ==="

# multiPodPerHost is false, so every pod needs its own node with its own NVMe slices.
"${WORKSHOP_ROOT}/scripts/setup/all-flash/ensure-nodegroup.sh" "${SIZE}"

export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext

echo "Waiting for the new node's index and data PVs to be published..."
source "${SCRIPT_DIR_LABS}/../lib/local-storage.sh"
ensure_all_flash_local_pvs "${SIZE}"

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  "${SCRIPT_DIR_LABS}/deploy-all-flash-cluster-helm.sh" "$(all_flash_scale_overlay_path)"
else
  kubectl -n "${NAMESPACE}" patch aerospikecluster aerocluster \
    --type=merge -p "{\"spec\":{\"size\":${SIZE}}}"
  all_flash_wait_for_cluster "${SIZE}"
fi

"${SCRIPT_DIR_LABS}/validate-all-flash.sh" "${SIZE}"
