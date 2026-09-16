#!/usr/bin/env bash
# Bootstrap main EKS cluster — dispatches on NODE_PROVISIONING (eksctl | karpenter).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env
apply_workshop_kubeconfig

if [[ "${CLOUD_PROVIDER}" != "eks" ]]; then
  echo "ERROR: 02-bootstrap-eks.sh requires CLOUD_PROVIDER=eks (got ${CLOUD_PROVIDER})" >&2
  echo "For GKE run: ./scripts/setup/02-bootstrap-gke.sh" >&2
  echo "Or copy scripts/env/workshop.env.gke.example to scripts/env/workshop.env and use setup-all.sh" >&2
  exit 1
fi

require_cmd eksctl
require_cmd kubectl
require_cmd aws

SETUP_DIR="$(dirname "$0")"
KARPENTER_DIR="${SETUP_DIR}/karpenter"

kc_args=()
if [[ -n "${KUBECONFIG:-}" ]]; then
  kc_args=(--kubeconfig "${KUBECONFIG}")
fi

case "${NODE_PROVISIONING}" in
  eksctl)
    echo "Creating EKS cluster ${CLUSTER_NAME} in ${AWS_REGION} (K8s ${K8S_VERSION}) — control plane only..."
    # ClusterConfig instead of CLI flags: the cluster service role needs a permissions
    # boundary in shared accounts, and eksctl only reads that from a config file.
    RENDERED_CONFIG="$(mktemp)"
    trap 'rm -f "${RENDERED_CONFIG}"' EXIT
    render_cluster_config "${CLUSTER_NAME}" "${AWS_REGION}" "${K8S_VERSION}" "${AWS_ZONES}" \
      > "${RENDERED_CONFIG}"
    eksctl create cluster -f "${RENDERED_CONFIG}" ${kc_args[@]+"${kc_args[@]}"}

    echo "Done. Workload nodepool: ./scripts/setup/02-ensure-workload-nodepool.sh (step 0.2-nodes)"
    ;;
  karpenter)
    echo "Creating EKS cluster ${CLUSTER_NAME} in ${AWS_REGION} (K8s ${K8S_VERSION}) — Karpenter path..."
    CLUSTER_CONFIG="${WORKSHOP_ROOT}/clusters/main-cluster-karpenter.yaml"
    if [[ ! -f "${CLUSTER_CONFIG}" ]]; then
      echo "ERROR: missing ${CLUSTER_CONFIG}" >&2
      exit 1
    fi
    require_cmd envsubst
    export CLUSTER_NAME AWS_REGION K8S_VERSION KARPENTER_SYSTEM_NODEGROUP
    export KARPENTER_SYSTEM_NODE_TYPE KARPENTER_SYSTEM_NODE_COUNT SSH_PUBLIC_KEY
    IFS=',' read -r NODE_ZONE_A NODE_ZONE_B _ <<< "${AWS_ZONES},,"
    export NODE_ZONE_A NODE_ZONE_B
    # Empty in accounts without a boundary policy — the template lines then render blank.
    # withOIDC on this path makes eksctl create the VPC CNI IRSA role too, so that role
    # must be declared explicitly to carry the boundary.
    IAM_SERVICE_ROLE_BOUNDARY="$(eksctl_iam_service_role_yaml)"
    IAM_CNI_SERVICE_ACCOUNT="$(eksctl_iam_cni_service_account_yaml)"
    IAM_NODEGROUP_BOUNDARY="$(eksctl_iam_nodegroup_yaml "    ")"
    export IAM_SERVICE_ROLE_BOUNDARY IAM_CNI_SERVICE_ACCOUNT IAM_NODEGROUP_BOUNDARY
    envsubst < "${CLUSTER_CONFIG}" | eksctl create cluster -f - ${kc_args[@]+"${kc_args[@]}"}

    echo "Installing Karpenter controller..."
    "${KARPENTER_DIR}/00-install-controller.sh"

    echo "System nodes:"
    kubectl get nodes -o wide
    echo "Done. Workload NodePool: ./scripts/setup/02-ensure-workload-nodepool.sh (step 0.2-nodes)"
    ;;
  *)
    echo "ERROR: NODE_PROVISIONING must be 'eksctl' or 'karpenter', got: ${NODE_PROVISIONING}" >&2
    exit 1
    ;;
esac

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
ensure_kubecontext "${CLUSTER_NAME}"
assert_kubecontext "${CLUSTER_NAME}"
