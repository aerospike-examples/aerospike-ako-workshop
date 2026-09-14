#!/usr/bin/env bash
# Google GKE Standard provider — gcloud.

_gke_require() {
  require_cmd gcloud
  if [[ -z "${GCP_PROJECT:-}" || "${GCP_PROJECT}" == "your-gcp-project" ]]; then
    echo "ERROR: set GCP_PROJECT in scripts/env/workshop.env (copy workshop.env.gke.example)" >&2
    exit 1
  fi
  : "${GCP_REGION:=us-central1}"
}

_gke_location_args() {
  echo --region "${GCP_REGION}" --project "${GCP_PROJECT}"
}

provider_display_name() {
  echo "GKE"
}

provider_kubeconfig_hint() {
  local cluster_name="$1"
  echo "gcloud container clusters get-credentials ${cluster_name} --region ${GCP_REGION} --project ${GCP_PROJECT}"
}

provider_cluster_exists() {
  local name="$1"
  _gke_require
  gcloud container clusters describe "${name}" $(_gke_location_args) >/dev/null 2>&1
}

provider_update_kubeconfig() {
  local cluster_name="$1"
  _gke_require
  gcloud container clusters get-credentials "${cluster_name}" \
    $(_gke_location_args) >/dev/null
}

provider_delete_cluster() {
  local name="$1"
  _gke_require
  echo "Deleting GKE cluster ${name}..."
  gcloud container clusters delete "${name}" $(_gke_location_args) --quiet
}

provider_control_plane_version() {
  local name="$1"
  _gke_require
  gcloud container clusters describe "${name}" $(_gke_location_args) \
    --format='value(currentMasterVersion)' 2>/dev/null || echo unknown
}

provider_control_plane_status() {
  local name="$1"
  _gke_require
  gcloud container clusters describe "${name}" $(_gke_location_args) \
    --format='value(status)' 2>/dev/null || echo unknown
}

# GKE reports versions like 1.31.6-gke.1064000 — treat prefix match as success.
provider_version_matches() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" || "${actual}" == "${expected}."* || "${actual}" == "${expected}-"* ]]
}

provider_upgrade_control_plane() {
  local name="$1"
  local version="$2"
  _gke_require
  echo "Upgrading GKE control plane ${name} to ${version}..."
  gcloud container clusters upgrade "${name}" \
    $(_gke_location_args) \
    --master \
    --cluster-version="${version}" \
    --quiet
}

provider_upgrade_nodes() {
  local cluster_name="$1"
  local ng_name="$2"
  local version="$3"
  _gke_require
  echo "Upgrading GKE node pool ${ng_name} on ${cluster_name} to ${version}..."
  gcloud container clusters upgrade "${cluster_name}" \
    $(_gke_location_args) \
    --node-pool="${ng_name}" \
    --cluster-version="${version}" \
    --quiet
}

provider_setup_block_storage() {
  require_cmd kubectl
  local storage_yaml
  storage_yaml="$(vendor_storage_dir)/gke_ssd_storage_class.yaml"
  if [[ ! -f "${storage_yaml}" ]]; then
    echo "ERROR: ${storage_yaml} not found." >&2
    exit 1
  fi
  kubectl apply -f "${storage_yaml}"
  kubectl get storageclass ssd
  echo "Expected: StorageClass ssd exists (pd.csi.storage.gke.io / pd-ssd)."
}

provider_node_pool_label_key() {
  echo "cloud.google.com/gke-nodepool"
}

_gke_node_locations_csv() {
  echo "${CLUSTER_ZONES}"
}

_gke_num_zones() {
  local -a z=()
  IFS=',' read -ra z <<< "${CLUSTER_ZONES}"
  echo "${#z[@]}"
}

_gke_nodes_per_zone() {
  local total="$1"
  local num_zones
  num_zones="$(_gke_num_zones)"
  if [[ "${num_zones}" -lt 1 ]]; then
    echo "${total}"
    return
  fi
  echo $(( (total + num_zones - 1) / num_zones ))
}

_gke_create_cluster_with_system_pool() {
  local name="$1"
  local k8s_version="$2"
  _gke_require
  local sys_per_zone
  sys_per_zone="$(_gke_nodes_per_zone "${GKE_SYSTEM_NODE_COUNT}")"

  echo "Creating GKE Standard cluster ${name} in ${GCP_REGION} (K8s ${k8s_version})..."
  echo "  system pool ${GKE_SYSTEM_NODEGROUP}: ${GKE_SYSTEM_NODE_TYPE} × ${GKE_SYSTEM_NODE_COUNT} (no local SSD)"

  gcloud container clusters create "${name}" \
    $(_gke_location_args) \
    --cluster-version="${k8s_version}" \
    --node-locations="$(_gke_node_locations_csv)" \
    --machine-type="${GKE_SYSTEM_NODE_TYPE}" \
    --num-nodes="${sys_per_zone}" \
    --disk-type=pd-ssd \
    --disk-size=50 \
    --enable-ip-alias \
    --enable-autorepair \
    --no-enable-autoupgrade \
    --quiet
}

provider_bootstrap_main() {
  local name="${1:-${CLUSTER_NAME}}"
  local k8s_version="${2:-${K8S_VERSION}}"
  _gke_require
  if provider_cluster_exists "${name}"; then
    echo "GKE cluster ${name} already exists — skipping create"
  else
    _gke_create_cluster_with_system_pool "${name}" "${k8s_version}"
  fi
  provider_update_kubeconfig "${name}"
}

_gke_nodepool_exists() {
  local cluster_name="$1"
  local pool_name="$2"
  gcloud container node-pools describe "${pool_name}" \
    --cluster="${cluster_name}" \
    $(_gke_location_args) >/dev/null 2>&1
}

_gke_wait_pool_nodes() {
  local pool_name="$1"
  local expected="$2"
  local label_key
  label_key="$(provider_node_pool_label_key)"
  local deadline=$((SECONDS + 900))
  local ready
  while true; do
    ready="$(kubectl get nodes -l "${label_key}=${pool_name}" --no-headers 2>/dev/null \
      | grep -c ' Ready ' || true)"
    echo "  ${pool_name} nodes Ready: ${ready}/${expected}"
    if [[ "${ready}" -ge "${expected}" ]]; then
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: timed out waiting for node pool ${pool_name}" >&2
      kubectl get nodes -o wide
      exit 1
    fi
    sleep 15
  done
}

_gke_label_pool_nodes() {
  local pool_name="$1"
  local pool_label="$2"
  local label_key
  label_key="$(provider_node_pool_label_key)"
  echo "Labeling pool ${pool_name} nodes: workshop.aerospike.com/node-pool=${pool_label}"
  kubectl get nodes -l "${label_key}=${pool_name}" -o name 2>/dev/null \
    | while read -r node; do
        kubectl label "${node}" "workshop.aerospike.com/node-pool=${pool_label}" --overwrite
        kubectl label "${node}" "workshop.aerospike.com/workload=aerospike" --overwrite
      done
}

# Create or resize a single-zone GKE node pool with local NVMe block SSDs.
provider_ensure_nodepool_in_zone() {
  local cluster_name="$1"
  local pool_name="$2"
  local node_type="$3"
  local zone="$4"
  local count="$5"
  local pool_label="${6:-}"
  local ssd_count="${7:-${GKE_LOCAL_SSD_COUNT}}"
  _gke_require
  require_cmd kubectl

  if _gke_nodepool_exists "${cluster_name}" "${pool_name}"; then
    echo "Node pool ${pool_name} exists — resizing to ${count}..."
    gcloud container clusters resize "${cluster_name}" \
      $(_gke_location_args) \
      --node-pool="${pool_name}" \
      --num-nodes="${count}" \
      --quiet
  else
    local labels="workshop.aerospike.com/workload=aerospike"
    if [[ -n "${pool_label}" ]]; then
      labels="${labels},workshop.aerospike.com/node-pool=${pool_label}"
    fi
    echo "Creating node pool ${pool_name} (${node_type} × ${count} in ${zone}, ${ssd_count} local NVMe)..."
    gcloud container node-pools create "${pool_name}" \
      --cluster="${cluster_name}" \
      $(_gke_location_args) \
      --machine-type="${node_type}" \
      --node-locations="${zone}" \
      --num-nodes="${count}" \
      --local-nvme-ssd-block-count="${ssd_count}" \
      --disk-type=pd-ssd \
      --disk-size=50 \
      --node-labels="${labels}" \
      --enable-autorepair \
      --no-enable-autoupgrade \
      --quiet
  fi
  _gke_wait_pool_nodes "${pool_name}" "${count}"
  if [[ -n "${pool_label}" ]]; then
    _gke_label_pool_nodes "${pool_name}" "${pool_label}"
  fi
}

provider_ensure_upgrade_lab_nodes() {
  local zone="${UPGRADE_LAB_NODE_ZONE:-${NODE_ZONE:-${NODE_ZONE_A}}}"
  provider_ensure_nodepool_in_zone \
    "${UPGRADE_LAB_CLUSTER_NAME}" \
    "${UPGRADE_LAB_NODEGROUP_NAME}" \
    "${UPGRADE_LAB_NODE_TYPE}" \
    "${zone}" \
    "${UPGRADE_LAB_NODE_COUNT}" \
    "baseline" \
    "${GKE_LOCAL_SSD_COUNT}"
}

provider_bootstrap_upgrade_lab() {
  local name="${UPGRADE_LAB_CLUSTER_NAME}"
  _gke_require
  if provider_cluster_exists "${name}"; then
    echo "GKE cluster ${name} already exists — skipping create"
    provider_update_kubeconfig "${name}"
  else
    _gke_create_cluster_with_system_pool "${name}" "${UPGRADE_LAB_K8S_VERSION_START}"
    provider_update_kubeconfig "${name}"
  fi
  provider_ensure_upgrade_lab_nodes
}

# All-flash node pool: ALL_FLASH_GKE_LOCAL_SSD_COUNT local NVMe disks per node, each
# later split by nvme-bootstrap into an index (ext4) and a data (raw block) partition.
provider_ensure_all_flash_nodes() {
  local count="${1:-${ALL_FLASH_NODE_COUNT}}"
  local zone="${ALL_FLASH_NODE_ZONE:-${NODE_ZONE:-${NODE_ZONE_A}}}"
  provider_ensure_nodepool_in_zone \
    "${ALL_FLASH_CLUSTER_NAME}" \
    "${ALL_FLASH_NODEGROUP_NAME}" \
    "${ALL_FLASH_NODE_TYPE}" \
    "${zone}" \
    "${count}" \
    "baseline" \
    "${ALL_FLASH_GKE_LOCAL_SSD_COUNT}"
  _gke_label_all_flash_pool_nodes
}

_gke_label_all_flash_pool_nodes() {
  local label_key
  label_key="$(provider_node_pool_label_key)"
  kubectl get nodes -l "${label_key}=${ALL_FLASH_NODEGROUP_NAME}" -o name 2>/dev/null \
    | while read -r node; do
        kubectl label "${node}" "workshop.aerospike.com/storage=all-flash" --overwrite
      done
}

provider_bootstrap_all_flash() {
  local name="${ALL_FLASH_CLUSTER_NAME}"
  _gke_require
  if provider_cluster_exists "${name}"; then
    echo "GKE cluster ${name} already exists — skipping create"
    provider_update_kubeconfig "${name}"
  else
    _gke_create_cluster_with_system_pool "${name}" "${K8S_VERSION}"
    provider_update_kubeconfig "${name}"
  fi
  provider_ensure_all_flash_nodes
}

provider_validate_client() {
  _PROVIDER_FAIL=0
  _gke_check() {
    if eval "$2" >/dev/null 2>&1; then
      echo "OK  $1"
    else
      echo "FAIL $1 — $3"
      _PROVIDER_FAIL=1
    fi
  }

  _gke_check "gcloud" "gcloud version --format='value(core)'" "Install Google Cloud SDK (gcloud)"
  if [[ -z "${GCP_PROJECT:-}" || "${GCP_PROJECT}" == "your-gcp-project" ]]; then
    echo "FAIL GCP_PROJECT — set it in scripts/env/workshop.env (copy workshop.env.gke.example)"
    _PROVIDER_FAIL=1
  else
    echo "OK  GCP_PROJECT=${GCP_PROJECT}"
  fi
  _gke_check "gcloud auth" "gcloud auth print-access-token" "Run: gcloud auth login && gcloud auth application-default login"
  if [[ -n "${GCP_PROJECT:-}" && "${GCP_PROJECT}" != "your-gcp-project" ]]; then
    _gke_check "container API" "gcloud services list --enabled --project=${GCP_PROJECT} --filter=container.googleapis.com --format='value(config.name)' | grep -q container" \
      "Enable: gcloud services enable container.googleapis.com compute.googleapis.com --project=${GCP_PROJECT}"
  fi

  echo "NOTE  GKE Standard quotas: N2 CPUs (baseline ${NODE_TYPE} + vertical ${NODE_TYPE_VERTICAL}) and Local SSD"
  echo "      (${GKE_LOCAL_SSD_COUNT} disks/baseline node, ${GKE_LOCAL_SSD_COUNT_VERTICAL} disks/vertical node; 375 GiB each)"
  echo "NOTE  Autopilot is not supported (local NVMe DaemonSet). Use GKE Standard."

  [[ "${_PROVIDER_FAIL}" -eq 0 ]]
}
