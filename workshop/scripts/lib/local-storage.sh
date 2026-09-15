#!/usr/bin/env bash
# Shared helpers for local NVMe storage (nvme-bootstrap + local-volume-provisioner).

: "${NVME_WAIT_TIMEOUT:=1800}"
: "${LOCAL_VOLUME_PROVISIONER_RESTART_TIMEOUT:=120}"
: "${LOCAL_VOLUME_PROVISIONER_SETTLE_SECS:=10}"
: "${LOCAL_SSD_STORAGE_CLASS:=local-ssd}"
: "${LOCAL_SSD_FS_STORAGE_CLASS:=local-ssd-fs}"

# PV field selectors only support metadata.name/namespace; filter by
# spec.storageClassName client-side (local-volume-provisioner does not set a label).
_local_ssd_pv_filter() {
  local mode="$1"
  local storage_class="${2:-${LOCAL_SSD_STORAGE_CLASS}}"
  python3 -c "
import json, sys

storage_class = sys.argv[1]
mode = sys.argv[2]
items = [
    pv for pv in json.load(sys.stdin).get('items', [])
    if pv.get('spec', {}).get('storageClassName') == storage_class
]
if mode == 'count':
    print(len(items))
elif mode == 'names':
    print('\n'.join(pv['metadata']['name'] for pv in items))
elif mode == 'node-hosts':
    for pv in items:
        terms = (
            pv.get('spec', {})
            .get('nodeAffinity', {})
            .get('required', {})
            .get('nodeSelectorTerms', [])
        )
        if not terms:
            continue
        exprs = terms[0].get('matchExpressions', [])
        if exprs and exprs[0].get('values'):
            print(exprs[0]['values'][0])
" "${storage_class}" "${mode}"
}

kubectl_get_local_ssd_pvs() {
  kubectl get pv -o json | _local_ssd_pv_filter names
}

nvme_bootstrap_desired() {
  kubectl -n kube-system get ds nvme-bootstrap -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0
}

nvme_bootstrap_ready() {
  kubectl -n kube-system get ds nvme-bootstrap -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0
}

wait_nvme_bootstrap_ready() {
  local expected_nodes="${1:-$(nvme_bootstrap_desired)}"
  local timeout="${2:-${NVME_WAIT_TIMEOUT}}"

  if ! kubectl -n kube-system get ds nvme-bootstrap >/dev/null 2>&1; then
    return 0
  fi

  local ready desired
  ready="$(nvme_bootstrap_ready)"
  desired="$(nvme_bootstrap_desired)"
  if [[ "${desired:-0}" -eq 0 ]]; then
    return 0
  fi

  echo "Waiting for nvme-bootstrap on i8g nodes (timeout ${timeout}s)..."
  local deadline=$((SECONDS + timeout))
  while true; do
    ready="$(nvme_bootstrap_ready)"
    desired="$(nvme_bootstrap_desired)"
    echo "  nvme-bootstrap Ready: ${ready}/${desired}"
    if [[ "${ready:-0}" -ge "${expected_nodes}" ]] && [[ "${ready}" == "${desired}" ]] && [[ "${desired}" -gt 0 ]]; then
      echo "OK  nvme-bootstrap Ready on all scheduled nodes"
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: nvme-bootstrap did not become Ready in time" >&2
      kubectl -n kube-system get pods -l app.kubernetes.io/name=nvme-bootstrap -o wide
      exit 1
    fi
    sleep 15
  done
}

restart_local_volume_provisioner() {
  local timeout="${1:-${LOCAL_VOLUME_PROVISIONER_RESTART_TIMEOUT}}"

  if ! kubectl -n aerospike get ds local-volume-provisioner >/dev/null 2>&1; then
    echo "WARN local-volume-provisioner DaemonSet missing — skipping restart"
    return 0
  fi

  echo "Restarting local-volume-provisioner so it discovers nvme-bootstrap disks..."
  kubectl -n aerospike rollout restart ds/local-volume-provisioner
  kubectl -n aerospike rollout status ds/local-volume-provisioner --timeout="${timeout}s"
  echo "OK  local-volume-provisioner restarted"
}

count_local_ssd_pvs() {
  kubectl get pv -o json | _local_ssd_pv_filter count
}

nvme_bootstrap_dir() {
  echo "${WORKSHOP_ROOT}/scripts/setup/nvme-bootstrap"
}

disk_layouts_config() {
  echo "$(nvme_bootstrap_dir)/disk-layouts.yaml"
}

nvme_init_script() {
  echo "$(nvme_bootstrap_dir)/nvme-init.py"
}

expected_local_ssd_pvs_for_instance_type() {
  local instance_type="$1"
  local config script
  config="$(disk_layouts_config)"
  script="$(nvme_init_script)"
  if [[ -z "${instance_type}" || ! -f "${config}" || ! -f "${script}" ]]; then
    echo ""
    return 0
  fi
  python3 "${script}" --expected-pvs-per-node \
    --config "${config}" --instance-type "${instance_type}" 2>/dev/null || echo ""
}

expected_local_ssd_pvs_per_node() {
  expected_local_ssd_pvs_for_instance_type "${NVME_DISK_LAYOUT:-${NODE_TYPE:-}}"
}

layout_mode_for_instance_type() {
  local instance_type="$1"
  local config script
  config="$(disk_layouts_config)"
  script="$(nvme_init_script)"
  if [[ -z "${instance_type}" || ! -f "${config}" || ! -f "${script}" ]]; then
    echo ""
    return 0
  fi
  python3 "${script}" --layout-mode \
    --config "${config}" --instance-type "${instance_type}" 2>/dev/null || echo ""
}

# local-volume-provisioner never retracts a PV whose backing path disappears, so
# switching a node from the whole-device layout to a partitioned one leaves an
# Available PV for the entire disk overlapping the new partition PVs. Delete those
# before Aerospike can bind one. Only unbound PVs are touched.
prune_stale_whole_device_pvs() {
  local layout_key="${1:-${NVME_DISK_LAYOUT:-${NODE_TYPE:-}}}"
  local stale pv

  if [[ "$(layout_mode_for_instance_type "${layout_key}")" != "partitioned" ]]; then
    return 0
  fi

  stale="$(kubectl get pv -o json 2>/dev/null | python3 -c "
import json, re, sys

classes = {'${LOCAL_SSD_STORAGE_CLASS}', '${LOCAL_SSD_FS_STORAGE_CLASS}'}
for pv in json.load(sys.stdin).get('items', []):
    spec = pv.get('spec', {})
    if spec.get('storageClassName') not in classes:
        continue
    if pv.get('status', {}).get('phase') != 'Available':
        continue
    path = spec.get('local', {}).get('path', '')
    if path and not re.search(r'p\d+\$', path):
        print(pv['metadata']['name'])
" || true)"

  while IFS= read -r pv; do
    [[ -z "${pv}" ]] && continue
    echo "Deleting stale whole-device PV ${pv} (partitioned layout ${layout_key})"
    kubectl delete pv "${pv}" --ignore-not-found
  done <<< "${stale}"
}

count_local_ssd_pvs_for_instance_type() {
  local instance_type="$1"
  local pv_hosts node count_on_node total=0

  pv_hosts="$(kubectl get pv -o json | _local_ssd_pv_filter node-hosts 2>/dev/null || true)"

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    count_on_node="$(printf '%s\n' "${pv_hosts}" | grep -cxF "${node}" || true)"
    total=$((total + count_on_node))
  done < <(
    kubectl get nodes -l "node.kubernetes.io/instance-type=${instance_type}" --no-headers 2>/dev/null \
      | awk '$2=="Ready" {print $1}'
  )
  echo "${total}"
}

ensure_local_ssd_pvs_for_pool() {
  local instance_type="$1"
  local node_count="$2"
  local pool_label="$3"
  # Layout key defaults to the instance type; the all-flash pool overrides it
  # because its layout is selected by name, not by machine shape.
  local layout_key="${4:-$1}"
  local per_node expected actual

  if [[ "${node_count:-0}" -eq 0 ]]; then
    return 0
  fi

  per_node="$(expected_local_ssd_pvs_for_instance_type "${layout_key}")"
  if [[ -z "${per_node}" ]]; then
    echo "SKIP ${pool_label}: unknown expected PV count for ${layout_key}"
    return 0
  fi

  expected=$((node_count * per_node))
  actual="$(count_local_ssd_pvs_for_instance_type "${instance_type}")"

  if [[ "${actual}" -ge "${expected}" ]]; then
    echo "OK  ${pool_label}: ${actual} local-ssd PVs (expected ~${expected})"
    return 0
  fi

  echo "WARN ${pool_label}: ${actual}/${expected} local-ssd PVs — waiting for nvme-bootstrap..."
  wait_nvme_bootstrap_ready "$(nvme_bootstrap_desired)" 300

  actual="$(count_local_ssd_pvs_for_instance_type "${instance_type}")"
  if [[ "${actual}" -ge "${expected}" ]]; then
    echo "OK  ${pool_label}: ${actual} local-ssd PVs (expected ~${expected})"
    return 0
  fi

  echo "WARN ${pool_label}: ${actual}/${expected} local-ssd PVs — restarting provisioner..."
  restart_local_volume_provisioner
  sleep "${LOCAL_VOLUME_PROVISIONER_SETTLE_SECS}"

  actual="$(count_local_ssd_pvs_for_instance_type "${instance_type}")"
  if [[ "${actual}" -ge "${expected}" ]]; then
    echo "OK  ${pool_label}: ${actual} local-ssd PVs after provisioner restart (expected ~${expected})"
    return 0
  fi

  echo "FAIL ${pool_label}: local-ssd PVs not available (${actual}/${expected} for ${node_count}× ${instance_type})" >&2
  echo "  Check: kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName --no-headers | awk '\$2 == \"local-ssd\"'" >&2
  echo "  Check: kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=30" >&2
  return 1
}

count_baseline_workload_nodes() {
  kubectl get nodes -l "workshop.aerospike.com/node-pool=baseline" --no-headers 2>/dev/null \
    | grep -c Ready || true
}

ensure_baseline_local_ssd_pvs_for_setup() {
  local node_count
  node_count="$(count_baseline_workload_nodes)"
  if [[ "${node_count}" -gt 0 ]]; then
    ensure_local_ssd_pvs_for_pool "${NODE_TYPE}" "${node_count}" "baseline" \
      "${NVME_DISK_LAYOUT:-${NODE_TYPE}}"
  else
    echo "SKIP local-ssd PV check (no baseline workload nodes yet)"
  fi
}

# --- Section 4 all-flash -----------------------------------------------------
# The all-flash layout publishes two PV families per node: raw block data slices
# (local-ssd) and index slices (local-ssd-fs, volumeMode Filesystem — kubelet formats).

expected_index_mounts_per_node() {
  local instance_type="${ALL_FLASH_NVME_DISK_LAYOUT:-}"
  local config script
  config="$(disk_layouts_config)"
  script="$(nvme_init_script)"
  if [[ -z "${instance_type}" || ! -f "${config}" || ! -f "${script}" ]]; then
    echo ""
    return 0
  fi
  python3 "${script}" --expected-index-mounts-per-node \
    --config "${config}" --instance-type "${instance_type}" 2>/dev/null || echo ""
}

count_index_mount_pvs() {
  kubectl get pv -o json | _local_ssd_pv_filter count "${LOCAL_SSD_FS_STORAGE_CLASS}"
}

ensure_all_flash_local_pvs() {
  local node_count="${1:-${ALL_FLASH_NODE_COUNT}}"
  local fail=0 per_node expected actual

  # Data slices reuse the shared block-PV wait/restart logic.
  ensure_local_ssd_pvs_for_pool "${ALL_FLASH_NODE_TYPE}" "${node_count}" \
    "all-flash data (${ALL_FLASH_NODE_TYPE})" "${ALL_FLASH_NVME_DISK_LAYOUT}" || fail=1

  per_node="$(expected_index_mounts_per_node)"
  if [[ -z "${per_node}" || "${per_node}" -eq 0 ]]; then
    echo "SKIP all-flash index mounts: no fstype slices in layout ${ALL_FLASH_NVME_DISK_LAYOUT}"
    return "${fail}"
  fi

  expected=$((node_count * per_node))
  actual="$(count_index_mount_pvs)"
  if [[ "${actual:-0}" -lt "${expected}" ]]; then
    echo "WARN all-flash index mounts: ${actual}/${expected} — restarting provisioner..."
    restart_local_volume_provisioner
    sleep "${LOCAL_VOLUME_PROVISIONER_SETTLE_SECS}"
    actual="$(count_index_mount_pvs)"
  fi

  if [[ "${actual:-0}" -ge "${expected}" ]]; then
    echo "OK  all-flash index mounts: ${actual} ${LOCAL_SSD_FS_STORAGE_CLASS} PVs (expected ${expected})"
    return "${fail}"
  fi

  echo "FAIL all-flash index mounts: ${actual}/${expected} ${LOCAL_SSD_FS_STORAGE_CLASS} PVs for ${node_count} node(s)" >&2
  echo "  Check: kubectl -n kube-system logs ds/nvme-bootstrap -c init-nvme --tail=40" >&2
  echo "  Check: kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAP:.spec.capacity.storage" >&2
  return 1
}

validate_lab_1_2_baseline_local_storage() {
  ensure_local_ssd_pvs_for_pool "${NODE_TYPE}" "$(count_2xl_nodes_ready)" "baseline (${NODE_TYPE})"
}

validate_lab_1_2_vertical_local_storage() {
  ensure_local_ssd_pvs_for_pool "${NODE_TYPE_VERTICAL}" "$(count_4xl_nodes_ready)" "vertical (${NODE_TYPE_VERTICAL})"
}
