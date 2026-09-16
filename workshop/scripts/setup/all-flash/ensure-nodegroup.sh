#!/usr/bin/env bash
# Ensure the all-flash node pool exists at the requested size and nodes are Ready.
#
# Usage:
#   ./scripts/setup/all-flash/ensure-nodegroup.sh [node-count]
#
# Lab 4.2 calls this with ${ALL_FLASH_NODE_COUNT_SCALED} to add the 4th node.
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
apply_workshop_kubeconfig
require_cmd kubectl

NODE_COUNT_WANTED="${1:-${ALL_FLASH_NODE_COUNT}}"
NODE_COUNT_MAX="${ALL_FLASH_NODE_COUNT_SCALED}"
if [[ "${NODE_COUNT_WANTED}" -gt "${NODE_COUNT_MAX}" ]]; then
  NODE_COUNT_MAX="${NODE_COUNT_WANTED}"
fi

if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
  require_cmd gcloud
  provider_ensure_all_flash_nodes "${NODE_COUNT_WANTED}"
  exit 0
fi

require_cmd eksctl

all_flash_nodegroup_exists() {
  eksctl get nodegroup \
    --cluster "${ALL_FLASH_CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --name "${ALL_FLASH_NODEGROUP_NAME}" >/dev/null 2>&1
}

wait_all_flash_nodes() {
  local expected="$1"
  local timeout="${2:-900}"
  local elapsed=0 ready

  echo "Waiting for ${expected} all-flash node(s) Ready (timeout ${timeout}s)..."
  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    ready="$(kubectl get nodes -l "alpha.eksctl.io/nodegroup-name=${ALL_FLASH_NODEGROUP_NAME}" --no-headers 2>/dev/null \
      | awk '$2=="Ready"{c++} END{print c+0}')"
    echo "  ${ALL_FLASH_NODEGROUP_NAME} nodes Ready: ${ready}/${expected}"
    if [[ "${ready}" -ge "${expected}" ]]; then
      kubectl get nodes -o wide
      return 0
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "ERROR: timed out waiting for all-flash nodes" >&2
  kubectl get nodes -o wide 2>/dev/null || true
  eksctl get nodegroup --cluster "${ALL_FLASH_CLUSTER_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  exit 1
}

label_all_flash_nodes() {
  echo "Labeling nodegroup ${ALL_FLASH_NODEGROUP_NAME} nodes: node-pool=baseline, storage=all-flash"
  kubectl get nodes -l "alpha.eksctl.io/nodegroup-name=${ALL_FLASH_NODEGROUP_NAME}" -o name 2>/dev/null \
    | while read -r node; do
        kubectl label "${node}" "workshop.aerospike.com/node-pool=baseline" --overwrite
        kubectl label "${node}" "workshop.aerospike.com/storage=all-flash" --overwrite
      done
}

if all_flash_nodegroup_exists; then
  echo "Nodegroup ${ALL_FLASH_NODEGROUP_NAME} already exists on ${ALL_FLASH_CLUSTER_NAME}"
  current="$(eksctl get nodegroup --cluster "${ALL_FLASH_CLUSTER_NAME}" --region "${AWS_REGION}" \
    --name "${ALL_FLASH_NODEGROUP_NAME}" -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("DesiredCapacity") or 0)' 2>/dev/null || echo 0)"
  if [[ "${current:-0}" -lt "${NODE_COUNT_WANTED}" ]]; then
    echo "Scaling ${ALL_FLASH_NODEGROUP_NAME} from ${current} to ${NODE_COUNT_WANTED}..."
    eksctl scale nodegroup \
      --cluster "${ALL_FLASH_CLUSTER_NAME}" \
      --region "${AWS_REGION}" \
      --name "${ALL_FLASH_NODEGROUP_NAME}" \
      --nodes "${NODE_COUNT_WANTED}" \
      --nodes-max "${NODE_COUNT_MAX}"
  fi
else
  echo "Creating nodegroup ${ALL_FLASH_NODEGROUP_NAME} on ${ALL_FLASH_CLUSTER_NAME} (${ALL_FLASH_NODE_TYPE} × ${NODE_COUNT_WANTED})..."
  # Config file rather than CLI flags: the node instance role needs a permissions
  # boundary in shared accounts, and eksctl only reads that from a config file.
  NG_CONFIG="$(mktemp)"
  trap 'rm -f "${NG_CONFIG}"' EXIT
  render_managed_nodegroup_config \
    "${ALL_FLASH_CLUSTER_NAME}" \
    "${AWS_REGION}" \
    "${ALL_FLASH_NODEGROUP_NAME}" \
    "${ALL_FLASH_NODE_TYPE}" \
    "${ALL_FLASH_NODE_ZONE:-${NODE_ZONE}}" \
    "${NODE_COUNT_WANTED}" \
    "${NODE_COUNT_WANTED}" \
    "${NODE_COUNT_MAX}" \
    "workshop.aerospike.com/node-pool=baseline,workshop.aerospike.com/storage=all-flash" > "${NG_CONFIG}"
  eksctl create nodegroup -f "${NG_CONFIG}"
fi

wait_all_flash_nodes "${NODE_COUNT_WANTED}"
label_all_flash_nodes
