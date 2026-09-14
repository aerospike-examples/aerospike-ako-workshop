#!/usr/bin/env bash
# All-flash local storage: index (Filesystem PVs, kubelet formats) + data (raw
# block) slices on every local NVMe disk, plus the vm.dirty_* / min_free_kbytes
# kernel settings the server requires for index-type flash.
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
SETUP_DIR="$(cd "${ALL_FLASH_DIR}/.." && pwd)"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
source "${ALL_FLASH_DIR}/../../lib/local-storage.sh"
load_env
export WORKSHOP_KUBECONFIG="$(kubeconfig_path_for_cluster "${ALL_FLASH_CLUSTER_NAME}")"
apply_workshop_kubeconfig
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext
require_cmd kubectl

MANIFESTS_DIR="${WORKSHOP_ROOT}/manifests"

echo "=== All-flash kernel settings (index on flash) ==="
kubectl apply -f "${MANIFESTS_DIR}/all-flash-sysctl-daemonset.yaml"
kubectl -n kube-system rollout status ds/all-flash-sysctl --timeout=300s

echo "=== All-flash local NVMe layout ==="
# 06-setup-local-storage.sh applies both the local-ssd (block) and local-ssd-fs
# (filesystem) classes, and picks the all-flash partition layout because
# CLUSTER_NAME is the all-flash cluster.
"${SETUP_DIR}/06-setup-local-storage.sh"

echo "=== All-flash PV inventory ==="
ensure_all_flash_local_pvs "${ALL_FLASH_NODE_COUNT}"
