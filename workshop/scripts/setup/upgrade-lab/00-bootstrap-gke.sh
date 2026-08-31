#!/usr/bin/env bash
# Bootstrap upgrade-lab GKE cluster (Lab 2.6).
set -euo pipefail
UPGRADE_DIR="$(dirname "$0")"
source "${UPGRADE_DIR}/../../lib/common.sh"
load_env
apply_workshop_kubeconfig

if [[ "${CLOUD_PROVIDER}" != "gke" ]]; then
  echo "ERROR: 00-bootstrap-gke.sh requires CLOUD_PROVIDER=gke (got ${CLOUD_PROVIDER})" >&2
  echo "For EKS run: ./scripts/setup/upgrade-lab/00-bootstrap-eks.sh" >&2
  exit 1
fi

require_cmd gcloud
require_cmd kubectl

: "${UPGRADE_LAB_NODEGROUP_NAME:=ng-upgrade-lab}"

echo "Creating upgrade-lab GKE cluster ${UPGRADE_LAB_CLUSTER_NAME}..."
provider_bootstrap_upgrade_lab

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

ensure_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
assert_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
