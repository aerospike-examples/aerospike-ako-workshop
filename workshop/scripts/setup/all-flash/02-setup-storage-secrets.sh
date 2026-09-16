#!/usr/bin/env bash
# Secrets for the all-flash cluster — delegates to 07-deploy-secrets.sh (same as main cluster).
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${ALL_FLASH_CLUSTER_NAME}")"
apply_workshop_kubeconfig
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext
"${ALL_FLASH_DIR}/../07-deploy-secrets.sh"
