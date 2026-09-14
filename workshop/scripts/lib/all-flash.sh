#!/usr/bin/env bash
# Shared helpers for the Section 4 all-flash cluster.
#
# Source after common.sh + load_env. EKS and GKE need different CR/values files
# because the disk layouts differ (5 data + 1 index vs 16 + 16).

all_flash_manifest_path() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    echo "${WORKSHOP_ROOT}/manifests/all-flash-cluster-gke.yaml"
  else
    echo "${WORKSHOP_ROOT}/manifests/all-flash-cluster.yaml"
  fi
}

all_flash_values_path() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    echo "${WORKSHOP_ROOT}/helm/base-all-flash-cluster-gke-values.yaml"
  else
    echo "${WORKSHOP_ROOT}/helm/base-all-flash-cluster-values.yaml"
  fi
}

all_flash_scale_overlay_path() {
  echo "${WORKSHOP_ROOT}/helm/overlay-all-flash-scale-4-values.yaml"
}

all_flash_cluster_phase() {
  kubectl -n "${NAMESPACE}" get aerospikecluster aerocluster \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo missing
}

all_flash_pods_running() {
  kubectl -n "${NAMESPACE}" get pods -l aerospike.com/cr=aerocluster \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '
}

all_flash_wait_for_cluster() {
  local expected="${1:-${ALL_FLASH_AEROSPIKE_SIZE}}"
  local timeout="${2:-900}"
  local deadline=$((SECONDS + timeout))
  local phase running error_streak=0

  echo "Waiting for all-flash AerospikeCluster phase Completed with ${expected} pods (timeout ${timeout}s)..."
  while (( SECONDS < deadline )); do
    phase="$(all_flash_cluster_phase)"
    running="$(all_flash_pods_running)"
    if [[ "${phase}" == "Completed" ]] && [[ "${running:-0}" -ge "${expected}" ]]; then
      echo "OK  all-flash cluster Ready (${running}/${expected} pods, phase ${phase})"
      return 0
    fi
    echo "  phase=${phase}, pods Running=${running:-0}/${expected}"
    if [[ "${phase}" == "Error" ]]; then
      error_streak=$((error_streak + 1))
      if [[ "${error_streak}" -ge 2 ]]; then
        echo "FAIL AerospikeCluster phase Error — AKO reconcile did not complete" >&2
        kubectl -n "${NAMESPACE}" get events --field-selector involvedObject.name=aerocluster \
          --sort-by='.lastTimestamp' 2>/dev/null | tail -5 >&2 || true
        echo "Common causes: index PVCs unbound (local-ssd-fs PVs missing) or vm.dirty_* not set on the node." >&2
        return 1
      fi
    else
      error_streak=0
    fi
    sleep 15
  done

  echo "FAIL timed out waiting for all-flash cluster (${timeout}s)" >&2
  kubectl -n "${NAMESPACE}" get aerospikecluster,pods,pvc 2>/dev/null || true
  return 1
}

# asinfo through a throwaway tools pod — same approach as validate-post-upgrade.sh.
all_flash_asinfo() {
  local command="$1"
  kubectl run "aerospike-tool-af-$$-${RANDOM}" -n "${NAMESPACE}" --restart=Never \
    --image=aerospike/aerospike-tools:latest --rm -i -- \
    asinfo -h aerocluster -U admin -P admin123 -v "${command}" 2>/dev/null || true
}

# Aerospike namespace (not the Kubernetes one) that the all-flash CR defines.
: "${ALL_FLASH_AEROSPIKE_NAMESPACE:=test}"

all_flash_namespace_stat() {
  local key="$1"
  all_flash_asinfo "namespace/${ALL_FLASH_AEROSPIKE_NAMESPACE}" \
    | tr ';' '\n' | sed -n "s/^${key}=//p" | tr -d '[:space:]'
}

# Service-level stats live in the `statistics` command — cluster_size and friends
# are fields of it, not info commands of their own.
all_flash_service_stat() {
  local key="$1"
  all_flash_asinfo statistics \
    | tr ';' '\n' | sed -n "s/^${key}=//p" | tr -d '[:space:]'
}

# Confirms the running server — not just the CR — has its primary index on flash.
all_flash_validate_index_flash() {
  local fail=0 index_type mounts_budget used

  index_type="$(all_flash_namespace_stat index-type)"
  if [[ "${index_type}" == "flash" ]]; then
    echo "OK  asinfo index-type=flash"
  else
    echo "FAIL asinfo index-type=${index_type:-unknown} (expected flash)" >&2
    fail=1
  fi

  mounts_budget="$(all_flash_namespace_stat index-type.mounts-budget)"
  if [[ "${mounts_budget}" == "${ALL_FLASH_INDEX_MOUNTS_BUDGET}" ]]; then
    echo "OK  asinfo index-type.mounts-budget=${mounts_budget} (600 GiB/node)"
  else
    echo "WARN asinfo index-type.mounts-budget=${mounts_budget:-unknown} (expected ${ALL_FLASH_INDEX_MOUNTS_BUDGET})"
  fi

  used="$(all_flash_namespace_stat index_flash_used_bytes)"
  echo "    index_flash_used_bytes=${used:-0}"

  return "${fail}"
}

# Every pod must have its data (Block) and index (Filesystem) PVCs bound.
all_flash_validate_pvcs() {
  local expected_pods="${1:-${ALL_FLASH_AEROSPIKE_SIZE}}"
  local per_pod_data per_pod_index bound_data bound_index fail=0

  per_pod_data="$(python3 "${WORKSHOP_ROOT}/scripts/setup/nvme-init.py" --expected-pvs-per-node \
    --config "${WORKSHOP_ROOT}/config/disk-layouts.yaml" \
    --instance-type "${ALL_FLASH_NVME_DISK_LAYOUT}" 2>/dev/null || echo 0)"
  per_pod_index="$(python3 "${WORKSHOP_ROOT}/scripts/setup/nvme-init.py" --expected-index-mounts-per-node \
    --config "${WORKSHOP_ROOT}/config/disk-layouts.yaml" \
    --instance-type "${ALL_FLASH_NVME_DISK_LAYOUT}" 2>/dev/null || echo 0)"

  local pvc_table
  pvc_table="$(kubectl -n "${NAMESPACE}" get pvc -l aerospike.com/cr=aerocluster \
    -o custom-columns=STATUS:.status.phase,CLASS:.spec.storageClassName --no-headers 2>/dev/null || true)"
  bound_data="$(awk '$1=="Bound" && $2=="local-ssd" {c++} END{print c+0}' <<< "${pvc_table}")"
  bound_index="$(awk '$1=="Bound" && $2=="local-ssd-fs" {c++} END{print c+0}' <<< "${pvc_table}")"

  if [[ "${bound_data}" -ge $((expected_pods * per_pod_data)) ]]; then
    echo "OK  ${bound_data} local-ssd data PVCs bound (${per_pod_data}/pod × ${expected_pods})"
  else
    echo "FAIL ${bound_data}/$((expected_pods * per_pod_data)) local-ssd data PVCs bound" >&2
    fail=1
  fi

  if [[ "${bound_index}" -ge $((expected_pods * per_pod_index)) ]]; then
    echo "OK  ${bound_index} local-ssd-fs index PVCs bound (${per_pod_index}/pod × ${expected_pods})"
  else
    echo "FAIL ${bound_index}/$((expected_pods * per_pod_index)) local-ssd-fs index PVCs bound" >&2
    fail=1
  fi

  return "${fail}"
}
