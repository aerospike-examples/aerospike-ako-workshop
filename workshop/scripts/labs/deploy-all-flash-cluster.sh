#!/usr/bin/env bash
# Path A — deploy the all-flash AerospikeCluster with kubectl (Lab 4.1).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/all-flash.sh"
load_env
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext
require_cmd kubectl

manifest="$(all_flash_manifest_path)"
echo "Applying ${manifest#"${WORKSHOP_ROOT}/"} on ${ALL_FLASH_CLUSTER_NAME}..."
kubectl apply -f "${manifest}"

all_flash_wait_for_cluster "${ALL_FLASH_AEROSPIKE_SIZE}"
