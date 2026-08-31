#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/nodepool-zones.sh"
source "$(dirname "$0")/lib/karpenter-teardown.sh"
load_env
require_cmd kubectl
if [[ "${CLOUD_PROVIDER}" == "eks" ]]; then
  require_cmd eksctl
  require_cmd aws
else
  require_cmd gcloud
fi

KARPENTER_IAM_TEARDOWN="$(dirname "$0")/setup/karpenter/99-teardown-controller-iam.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--main-only | --upgrade-lab-only] [--yes] [--sequential]

Delete training cluster(s) ($(provider_display_name)).

Default (no flags): delete BOTH clusters in parallel:
  - ${UPGRADE_LAB_CLUSTER_NAME} (upgrade-lab)
  - ${CLUSTER_NAME} (main)

If NODE_PROVISIONING=karpenter, deleting the main cluster also:
  - Removes Aerospike workloads (best-effort), bootstrap Deployments, and NodePools/NodeClaims
  - Waits up to ~15 min for workload nodes to terminate, then sweeps orphaned EC2 instances
  - Removes the raw IAM role/policy from scripts/setup/karpenter/00-install-controller.sh
    (not tracked by eksctl, so cluster deletion alone would leak them)

Options:
  --main-only          Delete main cluster only
  --upgrade-lab-only   Delete upgrade-lab cluster only (after Lab 2.6)
  --yes                Skip confirmation prompt
  --sequential         Delete both clusters one at a time (upgrade-lab, then main)
  -h, --help           Show this help
EOF
}

main_only=false
upgrade_only=false
assume_yes=false
sequential=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --main-only) main_only=true ;;
    --upgrade-lab-only) upgrade_only=true ;;
    --yes) assume_yes=true ;;
    --sequential) sequential=true ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "${main_only}" == true && "${upgrade_only}" == true ]]; then
  echo "ERROR: --main-only and --upgrade-lab-only are mutually exclusive" >&2
  exit 1
fi

clusters=()
if [[ "${upgrade_only}" == true ]]; then
  clusters=("${UPGRADE_LAB_CLUSTER_NAME}")
elif [[ "${main_only}" == true ]]; then
  clusters=("${CLUSTER_NAME}")
else
  clusters=("${UPGRADE_LAB_CLUSTER_NAME}" "${CLUSTER_NAME}")
fi

use_parallel_teardown() {
  [[ "${#clusters[@]}" -gt 1 && "${sequential}" == false ]]
}

print_teardown_plan() {
  echo "=== Teardown plan ==="
  echo "Provider: $(provider_display_name) (${CLOUD_PROVIDER})"
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    echo "Region: ${GCP_REGION}  project: ${GCP_PROJECT}"
  else
    echo "Region: ${AWS_REGION}"
  fi
  if use_parallel_teardown; then
    echo "Mode:   parallel delete"
  else
    echo "Mode:   sequential delete"
  fi
  echo ""
  local name
  for name in "${clusters[@]}"; do
    if cluster_exists "${name}"; then
      echo "  DELETE  ${name} (exists)"
    else
      echo "  SKIP    ${name} (not found)"
    fi
  done
}

confirm_teardown() {
  if [[ "${assume_yes}" == true ]]; then
    return 0
  fi
  print_teardown_plan
  echo ""
  read -r -p "Proceed with cluster deletion? [y/N] " reply
  case "${reply}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

# Karpenter is only ever used on the main cluster (upgrade-lab stays on eksctl MNG).
is_karpenter_main_cluster() {
  local name="$1"
  [[ "${NODE_PROVISIONING}" == "karpenter" && "${name}" == "${CLUSTER_NAME}" ]]
}

prepare_karpenter_cluster_kubeconfig() {
  local name="$1"
  local kc
  kc="$(kubeconfig_path_for_cluster "${name}")"
  if ! aws eks update-kubeconfig --name "${name}" --region "${AWS_REGION}" --kubeconfig "${kc}" >/dev/null 2>&1; then
    echo "[delete-${name}] Could not reach cluster to drain Karpenter workload — skipping pre-drain (post-delete orphan sweep will still run)"
    return 1
  fi
  export KUBECONFIG="${kc}"
  return 0
}

drain_karpenter_before_delete() {
  local name="$1"
  if ! prepare_karpenter_cluster_kubeconfig "${name}"; then
    return 0
  fi
  export KARPENTER_TEARDOWN_LOG_PREFIX="[delete-${name}] "
  teardown_aerospike_workloads_best_effort
  drain_karpenter_workload_for_teardown "${name}" delete
}

delete_cluster_async() {
  local name="$1"
  (
    if is_karpenter_main_cluster "${name}"; then
      drain_karpenter_before_delete "${name}"
    fi
    echo "[delete-${name}] Deleting $(provider_display_name) cluster ${name}..."
    provider_delete_cluster "${name}" || exit 1
    echo "[delete-${name}] Deleted ${name}"
    if is_karpenter_main_cluster "${name}"; then
      sweep_orphan_karpenter_instances "${name}"
      if [[ -x "${KARPENTER_IAM_TEARDOWN}" ]]; then
        KARPENTER_TEARDOWN_LOG_PREFIX="[delete-${name}] " "${KARPENTER_IAM_TEARDOWN}" || true
      fi
    fi
  )
}

delete_cluster_sequential() {
  local name="$1"
  if ! cluster_exists "${name}"; then
    echo "Skipping ${name} — cluster not found"
    skipped+=("${name}")
    return 0
  fi
  delete_cluster_async "${name}"
  delete_kubecontext_for_cluster "${name}"
  deleted+=("${name}")
}

confirm_teardown
echo ""

deleted=()
skipped=()
to_delete=()
for name in "${clusters[@]}"; do
  if cluster_exists "${name}"; then
    to_delete+=("${name}")
  else
    skipped+=("${name}")
    echo "Skipping ${name} — cluster not found"
  fi
done

if [[ ${#to_delete[@]} -eq 0 ]]; then
  echo "No clusters to delete."
elif use_parallel_teardown; then
  echo "=== Parallel $(provider_display_name) teardown ==="
  pids=()
  for name in "${to_delete[@]}"; do
    delete_cluster_async "${name}" &
    pids+=($!)
  done
  fail=0
  for pid in "${pids[@]}"; do
    wait "${pid}" || fail=1
  done
  if [[ "${fail}" -ne 0 ]]; then
    echo "ERROR: one or more cluster deletions failed" >&2
    exit 1
  fi
  for name in "${to_delete[@]}"; do
    delete_kubecontext_for_cluster "${name}"
    deleted+=("${name}")
  done
  cleanup_workshop_kubeconfig_files
else
  for name in "${to_delete[@]}"; do
    delete_cluster_sequential "${name}"
  done
fi

echo ""
echo "=== Cleanup complete ==="
if [[ ${#deleted[@]} -gt 0 ]]; then
  echo "Deleted: ${deleted[*]}"
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (not found): ${skipped[*]}"
fi
if [[ ${#deleted[@]} -eq 0 ]]; then
  echo "No clusters were deleted."
fi
