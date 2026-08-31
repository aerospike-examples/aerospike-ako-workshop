#!/usr/bin/env bash
# Bootstrap main GKE Standard cluster (system node pool only).
# Workload pools: ./scripts/setup/02-ensure-workload-nodepool.sh (step 0.2-nodes)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env
apply_workshop_kubeconfig

if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
  echo "ERROR: 02-bootstrap-gke.sh requires CLOUD_PROVIDER=gke (got ${CLOUD_PROVIDER})" >&2
  echo "For EKS run: ./scripts/setup/02-bootstrap-eks.sh" >&2
  echo "Copy scripts/env/workshop.env.gke.example to scripts/env/workshop.env for GKE" >&2
  exit 1
fi

require_cmd gcloud
require_cmd kubectl

provider_bootstrap_main "${CLUSTER_NAME}" "${K8S_VERSION}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
ensure_kubecontext "${CLUSTER_NAME}"
assert_kubecontext "${CLUSTER_NAME}"

echo "Done. Workload nodepool: ./scripts/setup/02-ensure-workload-nodepool.sh (step 0.2-nodes)"
echo "System nodes:"
kubectl get nodes -o wide
