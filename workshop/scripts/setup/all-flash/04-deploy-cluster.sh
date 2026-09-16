#!/usr/bin/env bash
# Deploy the all-flash AerospikeCluster (Lab 4.1 Path A/B). Used by Lab 4.1
# scripts and by prepare-lab 4.2 when the 4.1 baseline is missing — not by setup 0.8.
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
LABS_DIR="$(cd "${ALL_FLASH_DIR}/../../labs" && pwd)"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${ALL_FLASH_CLUSTER_NAME}")"
apply_workshop_kubeconfig
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  "${LABS_DIR}/deploy-all-flash-cluster-helm.sh"
else
  "${LABS_DIR}/deploy-all-flash-cluster.sh"
fi
