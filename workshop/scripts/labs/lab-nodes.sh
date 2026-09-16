#!/usr/bin/env bash
# Ensure or validate workload nodes for Section 1 labs.
#
# Usage:
#   ./scripts/labs/lab-nodes.sh <lab> ensure|validate [options]
#
# Options:
#   --scale-up       Lab 1.1: scale workload pool to 5 nodes (eksctl) or trigger scale (karpenter)
#   --vertical       Lab 1.2/1.3: add 4xl pool alongside existing 2xl (mid-lab vertical scale)
#   --replace-zone   Lab 2.5 Phase 2 optional: scale +1 in the maintenance target node's AZ before drain (requires --node)
#   --node=<name>    Kubernetes node name for --replace-zone (Lab 2.5)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/zone-check.sh"
source "$(dirname "$0")/../lib/local-storage.sh"
source "$(dirname "$0")/../lib/nodepool-zones.sh"
load_env
ensure_main_kubecontext

LAB_ID="${1:?Usage: lab-nodes.sh <lab-id> ensure|validate [--scale-up|--vertical|--replace-zone --node=<name>]}"
ACTION="${2:?Usage: lab-nodes.sh <lab-id> ensure|validate [--scale-up|--vertical|--replace-zone --node=<name>]}"
shift 2 || true

SCALE_UP=false
VERTICAL=false
REPLACE_ZONE=false
TARGET_NODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale-up) SCALE_UP=true; shift ;;
    --vertical) VERTICAL=true; shift ;;
    --replace-zone) REPLACE_ZONE=true; shift ;;
    --node=*)
      TARGET_NODE="${1#*=}"
      shift
      ;;
    --node)
      shift
      TARGET_NODE="${1:?--node requires a node name}"
      shift
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      exit 1
      ;;
  esac
done

require_cmd kubectl
if [[ "${CLOUD_PROVIDER}" == "eks" ]]; then
  require_cmd eksctl
  resolve_iam_boundary_arn >/dev/null
fi

KARPENTER_DIR="${WORKSHOP_ROOT}/scripts/setup/karpenter"
NODE_WAIT_TIMEOUT=900
NVME_WAIT_TIMEOUT=1800

count_baseline_nodes_ready() {
  kubectl get nodes -l "workshop.aerospike.com/node-pool=baseline,node.kubernetes.io/instance-type=${NODE_TYPE}" \
    --no-headers 2>/dev/null | grep -c ' Ready ' || true
}

count_2xl_nodes_ready() {
  count_baseline_nodes_ready
}

count_4xl_nodes_ready() {
  kubectl get nodes -l "workshop.aerospike.com/node-pool=vertical,node.kubernetes.io/instance-type=${NODE_TYPE_VERTICAL}" \
    --no-headers 2>/dev/null | grep -c ' Ready ' || true
}

count_workload_nodes_ready() {
  if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
    kubectl get nodes -l 'workshop.aerospike.com/workload=aerospike' --no-headers 2>/dev/null \
      | grep -c ' Ready ' || true
  else
    local ready_2xl ready_4xl
    ready_2xl="$(count_2xl_nodes_ready)"
    ready_4xl="$(count_4xl_nodes_ready)"
    echo $((ready_2xl + ready_4xl))
  fi
}

eksctl_nodegroup_exists() {
  local name="$1"
  eksctl get nodegroup --cluster="${CLUSTER_NAME}" --region="${AWS_REGION}" --name="${name}" >/dev/null 2>&1
}

wait_2xl_nodes() {
  local expected="$1"
  local deadline=$((SECONDS + NODE_WAIT_TIMEOUT))
  while true; do
    local ready
    ready="$(count_2xl_nodes_ready)"
    echo "  2xl nodes Ready: ${ready}/${expected}"
    if [[ "${ready}" -ge "${expected}" ]]; then
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: timed out waiting for ${expected}× ${NODE_TYPE} nodes" >&2
      kubectl get nodes -o wide
      exit 1
    fi
    sleep 15
  done
}

wait_4xl_nodes() {
  local expected="$1"
  local deadline=$((SECONDS + NODE_WAIT_TIMEOUT))
  while true; do
    local ready
    ready="$(count_4xl_nodes_ready)"
    echo "  4xl nodes Ready: ${ready}/${expected}"
    if [[ "${ready}" -ge "${expected}" ]]; then
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: timed out waiting for ${expected}× ${NODE_TYPE_VERTICAL} nodes" >&2
      kubectl get nodes -o wide
      exit 1
    fi
    sleep 15
  done
}

wait_eksctl_nodegroup_ready() {
  local ng_name="$1"
  local expected="$2"
  local deadline=$((SECONDS + NODE_WAIT_TIMEOUT))
  while true; do
    local ready
    ready="$(kubectl get nodes -l "alpha.eksctl.io/nodegroup-name=${ng_name}" --no-headers 2>/dev/null \
      | grep -c ' Ready ' || true)"
    echo "  ${ng_name} nodes Ready: ${ready}/${expected}"
    if [[ "${ready}" -ge "${expected}" ]]; then
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: timed out waiting for nodegroup ${ng_name}" >&2
      kubectl get nodes -o wide
      exit 1
    fi
    sleep 15
  done
}

label_eksctl_nodegroup_pool() {
  local ng_name="$1"
  local pool_label="$2"
  echo "Labeling nodegroup ${ng_name} nodes: workshop.aerospike.com/node-pool=${pool_label}"
  kubectl get nodes -l "alpha.eksctl.io/nodegroup-name=${ng_name}" -o name 2>/dev/null \
    | while read -r node; do
        kubectl label "${node}" "workshop.aerospike.com/node-pool=${pool_label}" --overwrite
      done
}

ensure_eksctl_nodegroup_in_zone() {
  local name="$1"
  local node_type="$2"
  local zone="$3"
  local count="$4"
  local pool_label="${5:-}"

  if eksctl_nodegroup_exists "${name}"; then
    echo "Nodegroup ${name} exists — scaling to ${count}..."
    eksctl scale nodegroup \
      --cluster="${CLUSTER_NAME}" \
      --region="${AWS_REGION}" \
      --name="${name}" \
      --nodes="${count}"
  else
    local labels=""
    if [[ -n "${pool_label}" ]]; then
      labels="workshop.aerospike.com/node-pool=${pool_label}"
    fi
    echo "Creating nodegroup ${name} (${node_type} × ${count} in ${zone})..."
    # Config file rather than CLI flags: the node instance role needs a permissions
    # boundary in shared accounts, and eksctl only reads that from a config file.
    local ng_config
    ng_config="$(mktemp)"
    render_managed_nodegroup_config \
      "${CLUSTER_NAME}" "${AWS_REGION}" "${name}" "${node_type}" "${zone}" \
      "${count}" 1 8 "${labels}" > "${ng_config}"
    eksctl create nodegroup -f "${ng_config}"
    rm -f "${ng_config}"
  fi
  wait_eksctl_nodegroup_ready "${name}" "${count}"
  if [[ -n "${pool_label}" ]]; then
    label_eksctl_nodegroup_pool "${name}" "${pool_label}"
  fi
}

ensure_eksctl_pools_per_zone() {
  local base_name="$1"
  local node_type="$2"
  local total_count="$3"
  local pool_label="${4:-}"

  read_aws_zones_array
  local num_zones="${#AWS_ZONES_ARRAY[@]}"
  local zone idx=0 ng_name count pid
  local -a pids=()

  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    ng_name="$(pool_name_for_zone "${base_name}" "${zone}")"
    count="$(nodes_for_zone "${total_count}" "${idx}" "${num_zones}")"
    if eksctl_nodegroup_exists "${ng_name}"; then
      ensure_eksctl_nodegroup_in_zone "${ng_name}" "${node_type}" "${zone}" "${count}" "${pool_label}"
    else
      ( ensure_eksctl_nodegroup_in_zone "${ng_name}" "${node_type}" "${zone}" "${count}" "${pool_label}" ) &
      pids+=($!)
    fi
    idx=$((idx + 1))
  done
  if ((${#pids[@]} > 0)); then
    for pid in "${pids[@]}"; do
      wait "${pid}"
    done
  fi
}

ensure_gke_pools_per_zone() {
  local base_name="$1"
  local node_type="$2"
  local total_count="$3"
  local pool_label="${4:-}"
  local ssd_count="${5:-${GKE_LOCAL_SSD_COUNT}}"

  read_aws_zones_array
  local num_zones="${#AWS_ZONES_ARRAY[@]}"
  local zone idx=0 ng_name count
  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    ng_name="$(pool_name_for_zone "${base_name}" "${zone}")"
    count="$(nodes_for_zone "${total_count}" "${idx}" "${num_zones}")"
    provider_ensure_nodepool_in_zone "${CLUSTER_NAME}" "${ng_name}" "${node_type}" \
      "${zone}" "${count}" "${pool_label}" "${ssd_count}"
    idx=$((idx + 1))
  done
}

ensure_managed_pools_per_zone() {
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    ensure_gke_pools_per_zone "$@"
  else
    ensure_eksctl_pools_per_zone "$@"
  fi
}

# Map workshop alias Off -> WhenEmpty + long consolidateAfter (Karpenter 1.11+ has no Off enum).
# Must run in the parent shell — export inside $(...) subshells does not persist.
resolve_karpenter_consolidation() {
  CONSOLIDATE_AFTER="30m"
  if [[ "${KARPENTER_CONSOLIDATION}" == "Off" ]]; then
    export KARPENTER_CONSOLIDATION="WhenEmpty"
    CONSOLIDATE_AFTER="720h"
  fi
}

apply_karpenter_ec2nodeclass() {
  require_cmd envsubst
  export CLUSTER_NAME AWS_REGION KARPENTER_NODECLASS_NAME
  export KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
  echo "Applying Karpenter EC2NodeClass ${KARPENTER_NODECLASS_NAME}..."
  envsubst < "${KARPENTER_DIR}/01-ec2nodeclass-i8g.yaml" | kubectl apply -f -
}

apply_karpenter_nodepool_in_zone() {
  local zone="$1"
  local vertical="${2:-false}"
  local consolidate_after="$3"

  require_cmd envsubst
  export CLUSTER_NAME AWS_REGION KARPENTER_CONSOLIDATION KARPENTER_NODECLASS_NAME
  export KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
  export NODE_ZONE="${zone}"

  local base_name template
  if [[ "${vertical}" == true ]]; then
    base_name="${KARPENTER_NODEPOOL_VERTICAL_NAME}"
    export NODE_TYPE_VERTICAL
    template="${KARPENTER_DIR}/02-nodepool-aerospike-vertical-zone.yaml"
  else
    base_name="${KARPENTER_NODEPOOL_NAME}"
    export NODE_TYPE
    template="${KARPENTER_DIR}/02-nodepool-aerospike-zone.yaml"
  fi
  export KARPENTER_NODEPOOL_ZONE_NAME
  KARPENTER_NODEPOOL_ZONE_NAME="$(pool_name_for_zone "${base_name}" "${zone}")"

  echo "Applying NodePool ${KARPENTER_NODEPOOL_ZONE_NAME} (zone ${zone})..."
  envsubst '${KARPENTER_NODEPOOL_ZONE_NAME} ${NODE_ZONE} ${NODE_TYPE} ${NODE_TYPE_VERTICAL} ${KARPENTER_NODECLASS_NAME} ${KARPENTER_CONSOLIDATION}' \
    < "${template}" | kubectl apply -f -
  kubectl patch nodepool "${KARPENTER_NODEPOOL_ZONE_NAME}" --type=merge \
    -p "{\"spec\":{\"disruption\":{\"consolidateAfter\":\"${consolidate_after}\"}}}" 2>/dev/null || true
}

apply_karpenter_pools_per_zone() {
  local vertical="${1:-false}"
  resolve_karpenter_consolidation
  local consolidate_after="${CONSOLIDATE_AFTER}"

  read_aws_zones_array
  local zone pid
  local -a pids=()
  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    ( apply_karpenter_nodepool_in_zone "${zone}" "${vertical}" "${consolidate_after}" ) &
    pids+=($!)
  done
  if ((${#pids[@]} > 0)); then
    for pid in "${pids[@]}"; do
      wait "${pid}"
    done
  fi
}

karpenter_bootstrap_deployment_name() {
  local prefix="$1"
  local zone="$2"
  echo "${prefix}-$(zone_resource_suffix "${zone}")"
}

delete_karpenter_bootstrap_deployments() {
  local prefix="$1"
  read_aws_zones_array
  local zone name
  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    name="$(karpenter_bootstrap_deployment_name "${prefix}" "${zone}")"
    kubectl delete deployment "${name}" -n kube-system --ignore-not-found
  done
}

verify_karpenter_nodepools_per_zone() {
  local vertical="${1:-false}"
  local pool_base
  if [[ "${vertical}" == true ]]; then
    pool_base="${KARPENTER_NODEPOOL_VERTICAL_NAME}"
  else
    pool_base="${KARPENTER_NODEPOOL_NAME}"
  fi

  read_aws_zones_array
  local zone pool_name zone_req
  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    pool_name="$(pool_name_for_zone "${pool_base}" "${zone}")"
    if ! kubectl get nodepool "${pool_name}" >/dev/null 2>&1; then
      echo "ERROR: NodePool ${pool_name} missing — run ./scripts/setup/karpenter/01-reset-workload-nodepools.sh then re-apply" >&2
      exit 1
    fi
    zone_req="$(kubectl get nodepool "${pool_name}" -o jsonpath='{.spec.template.spec.requirements[?(@.key=="topology.kubernetes.io/zone")].values[0]}' 2>/dev/null || true)"
    if [[ "${zone_req}" != "${zone}" ]]; then
      echo "ERROR: NodePool ${pool_name} zone requirement is '${zone_req:-<none>}' (expected ${zone}) — reset and re-apply NodePools" >&2
      exit 1
    fi
  done
}

count_pool_nodes_in_zone() {
  local zone="$1"
  local instance_type="$2"
  local pool_base_name="$3"
  local pool_name
  pool_name="$(pool_name_for_zone "${pool_base_name}" "${zone}")"
  kubectl get nodes -l "topology.kubernetes.io/zone=${zone},node.kubernetes.io/instance-type=${instance_type},karpenter.sh/nodepool=${pool_name}" \
    --no-headers 2>/dev/null | grep -c ' Ready ' || true
}

karpenter_pool_needs_rebalance() {
  local instance_type="$1"
  local total_count="$2"
  local pool_base_name="$3"

  read_aws_zones_array
  local num_zones="${#AWS_ZONES_ARRAY[@]}"
  local zone idx=0 target current
  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    target="$(nodes_for_zone "${total_count}" "${idx}" "${num_zones}")"
    current="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"
    if [[ "${current}" -ne "${target}" ]]; then
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

wait_karpenter_nodes_in_zone() {
  local zone="$1"
  local instance_type="$2"
  local pool_base_name="$3"
  local target="$4"
  local pool_name
  pool_name="$(pool_name_for_zone "${pool_base_name}" "${zone}")"
  local deadline=$((SECONDS + NODE_WAIT_TIMEOUT))
  while true; do
    local ready
    ready="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"
    echo "  ${pool_name} nodes Ready in ${zone}: ${ready}/${target}"
    if [[ "${ready}" -ge "${target}" ]]; then
      return 0
    fi
    if [[ "${SECONDS}" -gt "${deadline}" ]]; then
      echo "ERROR: timed out waiting for ${target}× ${instance_type} in ${zone} (NodePool ${pool_name})" >&2
      kubectl get nodes -o wide
      exit 1
    fi
    sleep 15
  done
}

terminate_excess_nodeclaims_in_zone() {
  local pool_base_name="$1"
  local zone="$2"
  local instance_type="$3"
  local target="$4"
  local nodepool_name current claim node prev
  nodepool_name="$(pool_name_for_zone "${pool_base_name}" "${zone}")"
  current="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"
  while [[ "${current}" -gt "${target}" ]]; do
    local excess=$((current - target))
    echo "Terminating ${excess} excess NodeClaim(s) in ${zone} (${nodepool_name}: ${current} > ${target})..."
    claim="$(kubectl get nodeclaims -l "karpenter.sh/nodepool=${nodepool_name}" \
      -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${claim}" ]]; then
      node="$(kubectl get nodes -l "topology.kubernetes.io/zone=${zone},karpenter.sh/nodepool=${nodepool_name},node.kubernetes.io/instance-type=${instance_type}" \
        -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${node}" ]]; then
        claim="$(kubectl get nodeclaims -o jsonpath="{.items[?(@.status.nodeName==\"${node}\")].metadata.name}" 2>/dev/null || true)"
      fi
    fi
    if [[ -z "${claim}" ]]; then
      echo "ERROR: could not find NodeClaim to terminate in ${nodepool_name} (${zone})" >&2
      kubectl get nodeclaims,nodes -o wide 2>/dev/null || true
      exit 1
    fi
    echo "  Deleting NodeClaim ${claim}..."
    kubectl delete nodeclaim "${claim}" --wait=true --timeout=180s
    prev="${current}"
    local claim_deadline=$((SECONDS + NODE_WAIT_TIMEOUT))
    while [[ "${SECONDS}" -lt "${claim_deadline}" ]]; do
      current="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"
      if [[ "${current}" -lt "${prev}" ]] || [[ "${current}" -le "${target}" ]]; then
        break
      fi
      echo "  Waiting for node count in ${zone} to drop (${current} > ${target})..."
      sleep 10
    done
    current="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"
    if [[ "${current}" -ge "${prev}" ]] && [[ "${current}" -gt "${target}" ]]; then
      echo "ERROR: node count in ${zone} did not decrease after deleting NodeClaim ${claim}" >&2
      kubectl get nodeclaims,nodes -o wide 2>/dev/null || true
      exit 1
    fi
  done
}

apply_karpenter_bootstrap_deployment() {
  local deployment_prefix="$1"
  local zone="$2"
  local nodepool_name="$3"
  local instance_type="$4"
  local replicas="$5"
  local dep_name app_label="${deployment_prefix}"

  dep_name="$(karpenter_bootstrap_deployment_name "${deployment_prefix}" "${zone}")"
  echo "Bootstrap ${dep_name}: ${replicas} pod(s) in ${zone} via NodePool ${nodepool_name} (${instance_type})..."
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${dep_name}
  namespace: kube-system
  labels:
    app: ${app_label}
    workshop.aerospike.com/zone: $(zone_resource_suffix "${zone}")
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: ${app_label}
      workshop.aerospike.com/zone: $(zone_resource_suffix "${zone}")
  template:
    metadata:
      labels:
        app: ${app_label}
        workshop.aerospike.com/zone: $(zone_resource_suffix "${zone}")
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: ${instance_type}
        karpenter.sh/nodepool: ${nodepool_name}
      tolerations:
        - operator: Exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: topology.kubernetes.io/zone
                    operator: In
                    values:
                      - ${zone}
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: ${app_label}
                  workshop.aerospike.com/zone: $(zone_resource_suffix "${zone}")
              topologyKey: kubernetes.io/hostname
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
EOF
}

ensure_karpenter_pools_per_zone() {
  local pool_base_name="$1"
  local instance_type="$2"
  local total_count="$3"
  local deployment_prefix="$4"
  local vertical="${5:-false}"

  apply_karpenter_ec2nodeclass
  apply_karpenter_pools_per_zone "${vertical}"
  verify_karpenter_nodepools_per_zone "${vertical}"

  read_aws_zones_array
  local num_zones="${#AWS_ZONES_ARRAY[@]}"
  local zone idx=0 target pool_name current

  for zone in "${AWS_ZONES_ARRAY[@]}"; do
    [[ -z "${zone}" ]] && continue
    target="$(nodes_for_zone "${total_count}" "${idx}" "${num_zones}")"
    pool_name="$(pool_name_for_zone "${pool_base_name}" "${zone}")"
    current="$(count_pool_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}")"

    apply_karpenter_bootstrap_deployment "${deployment_prefix}" "${zone}" "${pool_name}" \
      "${instance_type}" "${target}"

    if [[ "${current}" -gt "${target}" ]]; then
      terminate_excess_nodeclaims_in_zone "${pool_base_name}" "${zone}" "${instance_type}" "${target}"
    fi

    wait_karpenter_nodes_in_zone "${zone}" "${instance_type}" "${pool_base_name}" "${target}"
    idx=$((idx + 1))
  done

  delete_karpenter_bootstrap_deployments "${deployment_prefix}"
  echo "OK  Karpenter NodePools active (${total_count} target across ${num_zones} zone(s), ${instance_type})"
}

apply_karpenter_baseline_pool() {
  local total_count="${1:-${NODE_COUNT}}"
  ensure_karpenter_pools_per_zone "${KARPENTER_NODEPOOL_NAME}" "${NODE_TYPE}" "${total_count}" \
    "karpenter-bootstrap" false
}

ensure_karpenter_baseline_pool() {
  local count="${1:-${NODE_COUNT}}"
  if karpenter_pool_needs_rebalance "${NODE_TYPE}" "${count}" "${KARPENTER_NODEPOOL_NAME}"; then
    ensure_karpenter_pools_per_zone "${KARPENTER_NODEPOOL_NAME}" "${NODE_TYPE}" "${count}" \
      "karpenter-bootstrap" false
  else
    apply_karpenter_ec2nodeclass
    apply_karpenter_pools_per_zone false
    verify_karpenter_nodepools_per_zone false
    echo "OK  Karpenter baseline NodePools active with $(count_2xl_nodes_ready) Ready nodes"
  fi
}

apply_karpenter_vertical_pool() {
  local total_count="${1:-${NODE_COUNT}}"
  ensure_karpenter_pools_per_zone "${KARPENTER_NODEPOOL_VERTICAL_NAME}" "${NODE_TYPE_VERTICAL}" "${total_count}" \
    "karpenter-vertical-bootstrap" true
}

ensure_karpenter_vertical_pool() {
  local count="${1:-${NODE_COUNT}}"
  if karpenter_pool_needs_rebalance "${NODE_TYPE_VERTICAL}" "${count}" "${KARPENTER_NODEPOOL_VERTICAL_NAME}"; then
    ensure_karpenter_pools_per_zone "${KARPENTER_NODEPOOL_VERTICAL_NAME}" "${NODE_TYPE_VERTICAL}" "${count}" \
      "karpenter-vertical-bootstrap" true
  else
    apply_karpenter_pools_per_zone true
    verify_karpenter_nodepools_per_zone true
    echo "OK  Karpenter vertical NodePools active with $(count_4xl_nodes_ready) Ready nodes"
  fi
}

wait_nvme_bootstrap() {
  wait_nvme_bootstrap_ready "$1" "${NVME_WAIT_TIMEOUT}"
}

maybe_wait_nvme_bootstrap() {
  local nodes_before="$1"
  local expected="$2"
  if ! kubectl -n kube-system get ds nvme-bootstrap >/dev/null 2>&1; then
    return 0
  fi
  local nodes_after ready desired
  nodes_after="$(count_2xl_nodes_ready)"
  ready="$(nvme_bootstrap_ready)"
  desired="$(nvme_bootstrap_desired)"
  if [[ "${nodes_after}" -gt "${nodes_before}" ]] || [[ "${ready:-0}" -lt "${desired:-0}" ]] || [[ "${ready:-0}" -lt "${expected}" ]]; then
    wait_nvme_bootstrap "${expected}"
  else
    echo "OK  nvme-bootstrap already Ready (${ready}/${desired})"
  fi
}

ensure_2xl_pool() {
  local count="${NODE_COUNT}"
  local nodes_before
  nodes_before="$(count_2xl_nodes_ready)"
  echo "=== Ensuring 2xl workload pool (${NODE_TYPE} × ${count}, per-AZ) ==="

  if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
    ensure_karpenter_baseline_pool "${count}"
  else
    ensure_managed_pools_per_zone "${NODEGROUP_NAME}" "${NODE_TYPE}" "${count}" "baseline" "${GKE_LOCAL_SSD_COUNT:-3}"
  fi

  print_zone_distribution "${NODE_TYPE}"
  if ! assert_multi_az_nodes fail "${NODE_TYPE}"; then
    if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
      echo "ERROR: multi-AZ distribution failed — re-run ./scripts/labs/prepare-lab.sh ${LAB_ID}" >&2
      echo "       Or: ./scripts/reset-cluster.sh --yes && ./scripts/labs/prepare-lab.sh ${LAB_ID}" >&2
    else
      echo "ERROR: multi-AZ distribution failed — run ./scripts/reset-cluster.sh --yes then prepare-lab.sh" >&2
    fi
    exit 1
  fi

  maybe_wait_nvme_bootstrap "${nodes_before}" "${count}"
  if [[ "${LAB_ID}" == "1.2" ]]; then
    ensure_local_ssd_pvs_for_pool "${NODE_TYPE}" "$(count_2xl_nodes_ready)" "baseline (${NODE_TYPE})"
  fi
}

replace_zone_for_maintenance_node() {
  local node_name="$1"

  if [[ -z "${node_name}" ]]; then
    echo "ERROR: --replace-zone requires --node=<kubernetes-node-name>" >&2
    exit 1
  fi

  if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
    echo "SKIP --replace-zone on Karpenter: same-AZ replacement is handled by NodeClaim delete."
    echo "      See workshop/sections/02-maintenance-and-upgrade/05-k8s-node-maintenance-karpenter.md Phase 4"
    return 0
  fi

  if ! kubectl get node "${node_name}" >/dev/null 2>&1; then
    echo "ERROR: node ${node_name} not found" >&2
    exit 1
  fi

  local target_zone ng_name current target_count nodes_before pool_label_key
  pool_label_key="$(provider_node_pool_label_key)"
  target_zone="$(kubectl get node "${node_name}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
  if [[ -z "${target_zone}" ]]; then
    echo "ERROR: could not read topology.kubernetes.io/zone from node ${node_name}" >&2
    exit 1
  fi

  ng_name="$(kubectl get node "${node_name}" -o go-template --template="{{index .metadata.labels \"${pool_label_key}\"}}")"
  if [[ -z "${ng_name}" ]]; then
    ng_name="$(pool_name_for_zone "${NODEGROUP_NAME}" "${target_zone}")"
  fi

  current="$(kubectl get nodes -l "${pool_label_key}=${ng_name}" --no-headers 2>/dev/null \
    | grep -c ' Ready ' || true)"
  target_count=$((current + 1))
  nodes_before="$(count_2xl_nodes_ready)"

  echo "=== Lab 2.5: scale ${ng_name} in ${target_zone} (${current} → ${target_count} Ready) ==="
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    provider_ensure_nodepool_in_zone "${CLUSTER_NAME}" "${ng_name}" "${NODE_TYPE}" \
      "${target_zone}" "${target_count}" "baseline" "${GKE_LOCAL_SSD_COUNT}"
  else
    ensure_eksctl_nodegroup_in_zone "${ng_name}" "${NODE_TYPE}" "${target_zone}" "${target_count}" "baseline"
  fi
  maybe_wait_nvme_bootstrap "${nodes_before}" "${NODE_COUNT}"
  echo "OK  ${ng_name} scaled to ${target_count} node(s) in ${target_zone}"
  kubectl get nodes -l "${pool_label_key}=${ng_name}" -o wide
}

scale_up_2xl() {
  local target=5
  local nodes_before
  nodes_before="$(count_2xl_nodes_ready)"
  echo "=== Scaling baseline pool to ${target} nodes (per-AZ) ==="
  if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
    apply_karpenter_baseline_pool "${target}"
  else
    ensure_managed_pools_per_zone "${NODEGROUP_NAME}" "${NODE_TYPE}" "${target}" "baseline" "${GKE_LOCAL_SSD_COUNT:-3}"
  fi
  maybe_wait_nvme_bootstrap "${nodes_before}" "${target}"
}

ensure_vertical_4xl() {
  local nodes_before
  nodes_before="$(count_4xl_nodes_ready)"
  echo "=== Vertical scale: add ${NODE_TYPE_VERTICAL} pool per AZ (keep ${NODE_TYPE} pool) ==="

  if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
    ensure_karpenter_vertical_pool "${NODE_COUNT}"
  else
    ensure_managed_pools_per_zone "${NODEGROUP_NAME_VERTICAL}" "${NODE_TYPE_VERTICAL}" "${NODE_COUNT}" "vertical" "${GKE_LOCAL_SSD_COUNT_VERTICAL:-6}"
  fi

  print_zone_distribution "${NODE_TYPE_VERTICAL}"
  validate_4xl_pool
  maybe_wait_nvme_bootstrap "${nodes_before}" "${NODE_COUNT}"
  if [[ "${LAB_ID}" == "1.2" ]]; then
    ensure_local_ssd_pvs_for_pool "${NODE_TYPE_VERTICAL}" "${NODE_COUNT}" "vertical (${NODE_TYPE_VERTICAL})"
  fi
}

validate_2xl_pool() {
  local expected="${1:-${NODE_COUNT}}"
  local exact="${2:-false}"
  echo "=== Validating baseline pool (expect ${expected}× ${NODE_TYPE} Ready, multi-AZ) ==="
  local ready
  ready="$(count_2xl_nodes_ready)"
  if [[ "${ready}" -lt "${expected}" ]]; then
    echo "FAIL only ${ready}× ${NODE_TYPE} nodes Ready (need ${expected})" >&2
    kubectl get nodes -o wide
    exit 1
  fi
  if [[ "${exact}" == true && "${ready}" -gt "${expected}" ]]; then
    echo "FAIL ${ready}× ${NODE_TYPE} nodes Ready (expected ${expected}) — run prepare-lab.sh to scale down" >&2
    kubectl get nodes -o wide
    exit 1
  fi
  print_zone_distribution "${NODE_TYPE}"
  if [[ "${expected}" -ge "${MIN_NODES_PER_ZONE}" ]] && ! assert_multi_az_nodes fail "${NODE_TYPE}"; then
    if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
      echo "Hint: re-run ./scripts/labs/prepare-lab.sh ${LAB_ID} (Karpenter will rebalance per-AZ NodePools)" >&2
    fi
    echo "Hint: run ./scripts/reset-cluster.sh --yes && ./scripts/labs/prepare-lab.sh ${LAB_ID}" >&2
    exit 1
  fi
  echo "OK  ${ready}× ${NODE_TYPE} Ready"
}

validate_4xl_pool() {
  echo "=== Validating 4xl pool (expect ${NODE_COUNT}× ${NODE_TYPE_VERTICAL} Ready, multi-AZ) ==="
  local ready
  ready="$(count_4xl_nodes_ready)"
  if [[ "${ready}" -lt "${NODE_COUNT}" ]]; then
    echo "FAIL only ${ready}× ${NODE_TYPE_VERTICAL} nodes Ready (need ${NODE_COUNT})" >&2
    kubectl get nodes -o wide
    exit 1
  fi
  print_zone_distribution "${NODE_TYPE_VERTICAL}"
  if ! assert_multi_az_nodes fail "${NODE_TYPE_VERTICAL}"; then
    if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
      echo "Hint: re-run ./scripts/labs/lab-nodes.sh ${LAB_ID} ensure --vertical (Karpenter will rebalance per-AZ NodePools)" >&2
    fi
    echo "Hint: run ./scripts/reset-cluster.sh --yes && ./scripts/labs/prepare-lab.sh ${LAB_ID}" >&2
    exit 1
  fi
  echo "OK  ${ready}× ${NODE_TYPE_VERTICAL} Ready"
}

validate_min_nodes() {
  local min="$1"
  echo "=== Validating ≥${min} workload nodes ==="
  local ready
  ready="$(count_workload_nodes_ready)"
  if [[ "${ready}" -lt "${min}" ]]; then
    echo "FAIL only ${ready} workload nodes Ready (need ${min})" >&2
    exit 1
  fi
  echo "OK  ${ready} workload nodes Ready"
}

case "${LAB_ID}:${ACTION}" in
  1.1:ensure)
    if [[ "${VERTICAL}" == true ]]; then
      echo "ERROR: --vertical is for labs 1.2 and 1.3 only" >&2
      exit 1
    fi
    if [[ "${SCALE_UP}" == true ]]; then
      ensure_2xl_pool
      scale_up_2xl
    else
      ensure_2xl_pool
    fi
    ;;
  1.1:validate)
    if [[ "${SCALE_UP}" == true ]]; then
      validate_2xl_pool 5
    else
      validate_2xl_pool "${NODE_COUNT}"
    fi
    ;;
  1.2:ensure)
    if [[ "${VERTICAL}" == true ]]; then
      ensure_vertical_4xl
    else
      ensure_2xl_pool
    fi
    ;;
  1.2:validate)
    if [[ "${VERTICAL}" == true ]]; then
      validate_4xl_pool
      validate_lab_1_2_vertical_local_storage
    else
      validate_2xl_pool "${NODE_COUNT}" true
      validate_lab_1_2_baseline_local_storage
    fi
    ;;
  1.3:ensure)
    if [[ "${VERTICAL}" == true ]]; then
      ensure_vertical_4xl
    else
      ensure_2xl_pool
    fi
    ;;
  1.3:validate)
    if [[ "${VERTICAL}" == true ]]; then
      validate_4xl_pool
    else
      validate_2xl_pool "${NODE_COUNT}" true
    fi
    ;;
  1.4:ensure)
    ensure_2xl_pool
    ;;
  1.4:validate)
    validate_min_nodes 3
    ;;
  2.5:ensure)
    if [[ "${REPLACE_ZONE}" != true ]]; then
      echo "ERROR: lab 2.5 ensure requires --replace-zone --node=<name>" >&2
      exit 1
    fi
    replace_zone_for_maintenance_node "${TARGET_NODE}"
    ;;
  *)
    echo "ERROR: unsupported lab/action: ${LAB_ID} ${ACTION}" >&2
    exit 1
    ;;
esac

echo "lab-nodes.sh ${LAB_ID} ${ACTION} complete."
