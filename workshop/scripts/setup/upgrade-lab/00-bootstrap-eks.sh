#!/usr/bin/env bash
set -euo pipefail
UPGRADE_DIR="$(dirname "$0")"
source "${UPGRADE_DIR}/../../lib/common.sh"
load_env
apply_workshop_kubeconfig
require_cmd eksctl

: "${UPGRADE_LAB_NODEGROUP_NAME:=ng-upgrade-lab}"

# eksctl create cluster accepts --kubeconfig; create nodegroup does not — use KUBECONFIG env (set above).
eksctl_cluster_kc_args=()
if [[ -n "${KUBECONFIG:-}" ]]; then
  eksctl_cluster_kc_args=(--kubeconfig "${KUBECONFIG}")
fi

echo "Creating upgrade-lab EKS cluster ${UPGRADE_LAB_CLUSTER_NAME}..."
# ClusterConfig instead of CLI flags: the cluster service role needs a permissions
# boundary in shared accounts, and eksctl only reads that from a config file.
CLUSTER_CONFIG="$(mktemp)"
trap 'rm -f "${CLUSTER_CONFIG}"' EXIT
render_cluster_config "${UPGRADE_LAB_CLUSTER_NAME}" "${AWS_REGION}" \
  "${UPGRADE_LAB_K8S_VERSION_START}" "${AWS_ZONES}" > "${CLUSTER_CONFIG}"
eksctl create cluster -f "${CLUSTER_CONFIG}" \
  ${eksctl_cluster_kc_args[@]+"${eksctl_cluster_kc_args[@]}"}

"${UPGRADE_DIR}/ensure-nodegroup.sh"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

ensure_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
assert_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
