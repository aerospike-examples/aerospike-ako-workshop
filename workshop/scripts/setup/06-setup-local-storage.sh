#!/usr/bin/env bash
# Local NVMe provisioner + automated disk bootstrap (nvme-bootstrap DaemonSet)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/local-storage.sh"
load_env

ensure_target_kubecontext

# load_env points NODE_TYPE/NVME_DISK_LAYOUT at the all-flash values (index
# Filesystem slices + data block slices) whenever CLUSTER_NAME is the all-flash cluster.
if [[ "${CLUSTER_NAME}" == "${ALL_FLASH_CLUSTER_NAME}" ]]; then
  echo "All-flash cluster: layout ${NVME_DISK_LAYOUT} on ${NODE_TYPE}"
fi

require_cmd kubectl

SETUP_DIR="$(dirname "$0")"
VENDOR_STORAGE="$(vendor_storage_dir)"
MANIFESTS_DIR="${WORKSHOP_ROOT}/manifests"
DISK_LAYOUTS="${WORKSHOP_ROOT}/config/disk-layouts.yaml"
LAYOUT_RENDERED="$(mktemp)"

kubectl apply -f "${VENDOR_STORAGE}/local_storage_class.yaml"
# local-ssd-fs stays unused unless a layout defines index (fstype) slices.
kubectl apply -f "${VENDOR_STORAGE}/local_fs_storage_class.yaml"
kubectl apply -f "${MANIFESTS_DIR}/aerospike_local_volume_provisioner.yaml"

for f in local_volume_provisioner_cleanup_rbac.yaml local_volume_provisioner_cleanup.yaml; do
  if [[ ! -f "${VENDOR_STORAGE}/${f}" ]]; then
    echo "ERROR: required file missing: ${VENDOR_STORAGE}/${f}" >&2
    exit 1
  fi
  kubectl apply -f "${VENDOR_STORAGE}/${f}"
done

# Render disk layout ConfigMap (optional NVME_DISK_LAYOUT override)
: "${NVME_DISK_LAYOUT:=}"
if [[ ! -f "${DISK_LAYOUTS}" ]]; then
  echo "ERROR: disk layout file missing: ${DISK_LAYOUTS}" >&2
  exit 1
fi
sed "s/^force_layout:.*$/force_layout: \"${NVME_DISK_LAYOUT}\"/" "${DISK_LAYOUTS}" > "${LAYOUT_RENDERED}"

# The DaemonSet mounts nvme-disk-layouts by name, so a changed layout (or
# nvme-init.py) only reaches the disks once the init container runs again.
bootstrap_needs_rollout=0
if kubectl -n kube-system get cm nvme-disk-layouts >/dev/null 2>&1; then
  live_layouts="$(kubectl -n kube-system get cm nvme-disk-layouts \
    -o jsonpath='{.data.disk-layouts\.yaml}' 2>/dev/null || true)"
  live_script="$(kubectl -n kube-system get cm nvme-disk-layouts \
    -o jsonpath='{.data.nvme-init\.py}' 2>/dev/null || true)"
  if [[ "${live_layouts}" != "$(cat "${LAYOUT_RENDERED}")" ]] ||
     [[ "${live_script}" != "$(cat "${SETUP_DIR}/nvme-init.py")" ]]; then
    bootstrap_needs_rollout=1
  fi
fi

kubectl create configmap nvme-disk-layouts \
  --from-file=disk-layouts.yaml="${LAYOUT_RENDERED}" \
  --from-file=nvme-init.py="${SETUP_DIR}/nvme-init.py" \
  -n kube-system \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "${LAYOUT_RENDERED}"

echo "Applying NVMe bootstrap DaemonSet..."
kubectl apply -f "${SETUP_DIR}/nvme-bootstrap-daemonset.yaml"

if [[ "${bootstrap_needs_rollout}" -eq 1 ]] && kubectl -n kube-system get ds nvme-bootstrap >/dev/null 2>&1; then
  echo "Disk layout or nvme-init.py changed — restarting nvme-bootstrap to re-run init..."
  kubectl -n kube-system rollout restart ds/nvme-bootstrap
  kubectl -n kube-system rollout status ds/nvme-bootstrap --timeout="${NVME_WAIT_TIMEOUT}s"
  prune_stale_whole_device_pvs "${NVME_DISK_LAYOUT:-${NODE_TYPE}}"
fi

ready="$(nvme_bootstrap_ready)"
desired="$(nvme_bootstrap_desired)"
if [[ "${desired}" -gt 0 ]]; then
  wait_nvme_bootstrap_ready "${desired}"
  ensure_baseline_local_ssd_pvs_for_setup
else
  echo "nvme-bootstrap not scheduled yet — run step 0.2-nodes first; PV check runs in 0.6 validation."
fi

kubectl -n kube-system get ds nvme-bootstrap 2>/dev/null || true
echo "Local storage manifests applied (NODE_PROVISIONING=${NODE_PROVISIONING})."
