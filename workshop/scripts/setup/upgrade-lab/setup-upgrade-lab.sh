#!/usr/bin/env bash
set -euo pipefail
UPGRADE_DIR="$(dirname "$0")"
source "${UPGRADE_DIR}/../../lib/common.sh"
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

echo "=== Upgrade-lab cluster setup ==="
export CLUSTER_NAME="${UPGRADE_LAB_CLUSTER_NAME}"

if cluster_exists "${UPGRADE_LAB_CLUSTER_NAME}"; then
  echo "Cluster ${UPGRADE_LAB_CLUSTER_NAME} already exists — skipping bootstrap"
  ensure_upgrade_lab_kubecontext
  "${UPGRADE_DIR}/ensure-nodegroup.sh"
else
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    "${UPGRADE_DIR}/00-bootstrap-gke.sh"
  else
    "${UPGRADE_DIR}/00-bootstrap-eks.sh"
  fi
fi

"${UPGRADE_DIR}/setup-upgrade-lab-post-bootstrap.sh"
