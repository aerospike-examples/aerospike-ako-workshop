#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
load_env

ensure_upgrade_lab_kubecontext

: "${UPGRADE_LAB_NODEGROUP_NAME:=ng-upgrade-lab}"

echo "Upgrading node pool ${UPGRADE_LAB_NODEGROUP_NAME} to K8s ${UPGRADE_LAB_K8S_VERSION_TARGET}..."
provider_upgrade_nodes "${UPGRADE_LAB_CLUSTER_NAME}" "${UPGRADE_LAB_NODEGROUP_NAME}" "${UPGRADE_LAB_K8S_VERSION_TARGET}"
echo "Node pool upgrade complete."
