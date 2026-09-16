#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
load_env

ensure_upgrade_lab_kubecontext

echo "Upgrading control plane ${UPGRADE_LAB_CLUSTER_NAME} to ${UPGRADE_LAB_K8S_VERSION_TARGET}..."
provider_upgrade_control_plane "${UPGRADE_LAB_CLUSTER_NAME}" "${UPGRADE_LAB_K8S_VERSION_TARGET}"
echo "Control plane upgrade complete."
