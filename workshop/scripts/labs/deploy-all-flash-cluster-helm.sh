#!/usr/bin/env bash
# Path B — deploy the all-flash AerospikeCluster with Helm (Lab 4.1).
#
# Pass extra value files as arguments, e.g. the Lab 4.2 scale overlay.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/all-flash.sh"
load_env
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext
require_cmd helm

value_args=(-f "$(all_flash_values_path)")
expected_size="${ALL_FLASH_AEROSPIKE_SIZE}"
for extra in "$@"; do
  value_args+=(-f "${extra}")
  if [[ "${extra}" == *"scale-4"* ]]; then
    expected_size="${ALL_FLASH_AEROSPIKE_SIZE_SCALED}"
  fi
done

chart_version="$(resolve_cluster_helm_chart_version)"

helm repo add aerospike "${HELM_REPO}" 2>/dev/null || true
helm repo update

helm upgrade --install "${HELM_CLUSTER_RELEASE}" aerospike/aerospike-cluster \
  --namespace "${NAMESPACE}" --create-namespace \
  --version="${chart_version}" \
  "${value_args[@]}"

all_flash_wait_for_cluster "${expected_size}"
