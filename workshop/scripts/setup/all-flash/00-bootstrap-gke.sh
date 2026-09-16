#!/usr/bin/env bash
# Bootstrap the dedicated all-flash GKE cluster (Section 4).
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
apply_workshop_kubeconfig

if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
  echo "ERROR: 00-bootstrap-gke.sh requires CLOUD_PROVIDER=gke (got ${CLOUD_PROVIDER})" >&2
  echo "For EKS run: ./scripts/setup/all-flash/00-bootstrap-eks.sh" >&2
  exit 1
fi

require_cmd gcloud
require_cmd kubectl

echo "Creating all-flash GKE cluster ${ALL_FLASH_CLUSTER_NAME}..."
echo "  node pool ${ALL_FLASH_NODEGROUP_NAME}: ${ALL_FLASH_NODE_TYPE} × ${ALL_FLASH_NODE_COUNT}"
echo "  local NVMe per node: ${ALL_FLASH_GKE_LOCAL_SSD_COUNT} × 375 GiB (raw block)"
provider_bootstrap_all_flash

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

ensure_kubecontext "${ALL_FLASH_CLUSTER_NAME}"
assert_kubecontext "${ALL_FLASH_CLUSTER_NAME}"
