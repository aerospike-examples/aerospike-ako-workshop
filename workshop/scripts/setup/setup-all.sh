#!/usr/bin/env bash
# Orchestrate Section 0 setup (Labs 0.1–0.6 by default).
#
# Usage:
#   ./scripts/setup/setup-all.sh              # main cluster only (0.1–0.6)
#   ./scripts/setup/setup-all.sh --list
#   ./scripts/setup/setup-all.sh --step 0.4
#   ./scripts/setup/setup-all.sh --from 0.5
#   ./scripts/setup/setup-all.sh --with-upgrade-lab
#   ./scripts/setup/setup-all.sh --step 0.7    # opt-in Lab 2.6 cluster
#   ./scripts/setup/setup-all.sh --step 0.8    # opt-in Section 4 cluster
#   ./scripts/setup/setup-all.sh --sequential
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env

SETUP_DIR="$(dirname "$0")"
# Dedicated clusters (0.7 Lab 2.6, 0.8 Section 4) are off unless opted in.
INCLUDE_UPGRADE_LAB=false
SKIP_UPGRADE_LAB_EXPLICIT=false
SEQUENTIAL=false

STEP_NAMES=(0.1 0.2 0.2-nodes 0.3 0.4 0.5-ebs 0.5-local 0.6-secrets 0.6-validate 0.7-upgrade-lab 0.8-all-flash)
STEP_SCRIPTS=(
  01-validate-client.sh
  02-bootstrap-eks.sh
  02-ensure-workload-nodepool.sh
  03-install-ako.sh
  04-install-akoctl.sh
  05-setup-ebs-storage.sh
  06-setup-local-storage.sh
  07-deploy-secrets.sh
  08-validate-environment.sh
  upgrade-lab/setup-upgrade-lab.sh
  all-flash/setup-all-flash.sh
)
STEP_LABS=("0.1" "0.2" "0.2 (nodes)" "0.3" "0.4" "0.5 (Part A)" "0.5 (Part B)" "0.6 (Part A)" "0.6 (Part B)" "0.7 (upgrade-lab)" "0.8 (all-flash)")

UPGRADE_LAB_IDX=9
ALL_FLASH_IDX=10

MAIN_BOOTSTRAP_SCRIPT="02-bootstrap-eks.sh"
UPGRADE_BOOTSTRAP_SCRIPT="upgrade-lab/00-bootstrap-eks.sh"
if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
  MAIN_BOOTSTRAP_SCRIPT="02-bootstrap-gke.sh"
  UPGRADE_BOOTSTRAP_SCRIPT="upgrade-lab/00-bootstrap-gke.sh"
  STEP_SCRIPTS[1]="${MAIN_BOOTSTRAP_SCRIPT}"
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [--list | --step NAME | --from NAME] [--with-upgrade-lab] [--skip-upgrade-lab] [--sequential]

Run Section 0 platform setup (Labs 0.1–0.6 by default — main cluster only).

Step 0.7 (Lab 2.6 upgrade-lab) and step 0.8 (Section 4 all-flash) are opt-in
dedicated clusters. They are never part of a default run; create them with
--step 0.7 / --step 0.8, or pass --with-upgrade-lab to include 0.7 in a full
run (main + upgrade-lab bootstrap in parallel).

Steps:
EOF
  local i
  for i in "${!STEP_NAMES[@]}"; do
    printf "  %-12s Lab %s  →  %s\n" "${STEP_NAMES[$i]}" "${STEP_LABS[$i]}" "${STEP_SCRIPTS[$i]}"
  done
  cat <<EOF

Composite steps (run all sub-steps for a lab):
  0.5  →  0.5-ebs + 0.5-local
  0.6  →  0.6-secrets + 0.6-validate

Options:
  --list               List steps and exit
  --step NAME          Run one step (or composite 0.5 / 0.6)
  --from NAME          Resume from step through 0.6-validate (inclusive)
  --with-upgrade-lab   Include step 0.7 in a full run (parallel with 0.2)
  --skip-upgrade-lab   Accepted for compatibility; 0.7 is already off by default
  --sequential         With --with-upgrade-lab: bootstrap main then upgrade-lab

Examples:
  $(basename "$0")
  $(basename "$0") --with-upgrade-lab
  $(basename "$0") --sequential
  $(basename "$0") --step 0.7              # opt-in Lab 2.6 cluster
  $(basename "$0") --step 0.8              # opt-in Section 4 all-flash cluster
  $(basename "$0") --from 0.5-ebs
EOF
}

resolve_step_indices() {
  local name="$1"
  local i
  case "${name}" in
    0.5)
      echo "5 6"
      return 0
      ;;
    0.6)
      echo "7 8"
      return 0
      ;;
    0.7|0.7-upgrade-lab)
      echo "${UPGRADE_LAB_IDX}"
      return 0
      ;;
    0.8|0.8-all-flash)
      echo "${ALL_FLASH_IDX}"
      return 0
      ;;
  esac
  for i in "${!STEP_NAMES[@]}"; do
    if [[ "${STEP_NAMES[$i]}" == "${name}" ]]; then
      echo "${i}"
      return 0
    fi
  done
  echo "ERROR: unknown step '${name}'. Run with --list for valid steps." >&2
  return 1
}

run_step() {
  local idx="$1"
  local name="${STEP_NAMES[$idx]}"
  local script="${STEP_SCRIPTS[$idx]}"
  echo "=== Lab ${STEP_LABS[$idx]} — step ${name} (${script}) ==="
  "${SETUP_DIR}/${script}"
}

next_step_after_index() {
  local idx="$1"
  local next=$((idx + 1))
  if [[ "${next}" -le "${END_IDX}" ]]; then
    echo "${STEP_NAMES[$next]}"
  fi
}

print_continue_hint() {
  local last_idx="$1"
  local next
  next="$(next_step_after_index "${last_idx}")"
  if [[ -z "${next}" ]]; then
    return 0
  fi
  if [[ "${last_idx}" -ge "${MAIN_END_IDX}" ]]; then
    echo ""
    echo "Main-cluster setup is complete. Optional dedicated clusters (off by default):"
    echo "  ./scripts/setup/setup-all.sh --step 0.7   # Lab 2.6 upgrade-lab"
    echo "  ./scripts/setup/setup-all.sh --step 0.8   # Section 4 all-flash"
    return 0
  fi
  echo ""
  echo "Single-step mode stops here. Continue setup with:"
  echo "  ./scripts/setup/setup-all.sh --from ${next}"
}

run_upgrade_lab_post_bootstrap() {
  echo "=== Lab 0.7 (upgrade-lab) — step 0.7-upgrade-lab (upgrade-lab/setup-upgrade-lab-post-bootstrap.sh) ==="
  "${SETUP_DIR}/upgrade-lab/setup-upgrade-lab-post-bootstrap.sh"
}

run_parallel_bootstrap() {
  local main_kc upgrade_kc
  local need_main=false need_upgrade=false
  local pid_main="" pid_upgrade="" r1=0 r2=0

  main_kc="$(kubeconfig_path_for_cluster "${CLUSTER_NAME}")"
  upgrade_kc="$(kubeconfig_path_for_cluster "${UPGRADE_LAB_CLUSTER_NAME}")"

  if ! cluster_exists "${CLUSTER_NAME}"; then
    need_main=true
  fi
  if ! cluster_exists "${UPGRADE_LAB_CLUSTER_NAME}"; then
    need_upgrade=true
  fi

  if [[ "${need_main}" == false && "${need_upgrade}" == false ]]; then
    echo "Both $(provider_display_name) clusters already exist — merging kubeconfigs"
    merge_kubeconfig_into_default "${main_kc}"
    merge_kubeconfig_into_default "${upgrade_kc}"
    ensure_main_kubecontext
    return 0
  fi

  echo "=== Parallel $(provider_display_name) bootstrap (main + upgrade-lab) ==="

  if [[ "${need_main}" == true ]]; then
    (
      run_with_log_prefix "[main-bootstrap]" \
        env WORKSHOP_KUBECONFIG="${main_kc}" "${SETUP_DIR}/${MAIN_BOOTSTRAP_SCRIPT}"
    ) &
    pid_main=$!
  else
    echo "Main cluster ${CLUSTER_NAME} already exists — skipping bootstrap"
  fi

  if [[ "${need_upgrade}" == true ]]; then
    (
      run_with_log_prefix "[upgrade-bootstrap]" \
        env WORKSHOP_KUBECONFIG="${upgrade_kc}" "${SETUP_DIR}/${UPGRADE_BOOTSTRAP_SCRIPT}"
    ) &
    pid_upgrade=$!
  else
    echo "Upgrade-lab cluster ${UPGRADE_LAB_CLUSTER_NAME} already exists — skipping bootstrap"
  fi

  if [[ -n "${pid_main}" ]]; then
    wait "${pid_main}" || r1=$?
  fi
  if [[ -n "${pid_upgrade}" ]]; then
    wait "${pid_upgrade}" || r2=$?
  fi

  if [[ "${r1}" -ne 0 || "${r2}" -ne 0 ]]; then
    echo "ERROR: parallel bootstrap failed (main=${r1}, upgrade-lab=${r2})" >&2
    echo "Partial clusters may remain — run ./scripts/cleanup-lab.sh --yes to reset" >&2
    exit 1
  fi

  merge_kubeconfig_into_default "${main_kc}"
  merge_kubeconfig_into_default "${upgrade_kc}"
  ensure_main_kubecontext
}

use_parallel_bootstrap() {
  [[ "${SEQUENTIAL}" == false && "${INCLUDE_UPGRADE_LAB}" == true && "${START_IDX}" -eq 0 && "${MODE}" == "all" ]]
}

MODE=all
START_IDX=0
MAIN_END_IDX=8   # 0.6-validate — last step of a default run
# 0.7 and 0.8 are opt-in dedicated clusters.
END_IDX="${MAIN_END_IDX}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      usage
      exit 0
      ;;
    --skip-upgrade-lab)
      SKIP_UPGRADE_LAB_EXPLICIT=true
      INCLUDE_UPGRADE_LAB=false
      shift
      ;;
    --with-upgrade-lab)
      INCLUDE_UPGRADE_LAB=true
      shift
      ;;
    --sequential)
      SEQUENTIAL=true
      shift
      ;;
    --step)
      [[ $# -ge 2 ]] || { echo "ERROR: --step requires a step name" >&2; usage >&2; exit 1; }
      MODE=step
      STEP_ARG="$2"
      shift 2
      ;;
    --from)
      [[ $# -ge 2 ]] || { echo "ERROR: --from requires a step name" >&2; usage >&2; exit 1; }
      MODE=from
      FROM_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${INCLUDE_UPGRADE_LAB}" == true ]]; then
  END_IDX="${UPGRADE_LAB_IDX}"
fi

if [[ "${MODE}" == "step" ]]; then
  if [[ "${SKIP_UPGRADE_LAB_EXPLICIT}" == true && "${STEP_ARG}" == 0.7* ]]; then
    echo "ERROR: --skip-upgrade-lab is set; refusing to run step ${STEP_ARG}" >&2
    exit 1
  fi
  INDICES="$(resolve_step_indices "${STEP_ARG}")" || exit 1
echo "=== AKO Training Environment Setup (CLOUD_PROVIDER=${CLOUD_PROVIDER}, DEPLOY_PATH=${DEPLOY_PATH}, NODE_PROVISIONING=${NODE_PROVISIONING}) ==="
  for idx in ${INDICES}; do
    run_step "${idx}"
  done
  echo "=== Step ${STEP_ARG} complete ==="
  # Hint using the last index from a composite step (e.g. 0.5 → 0.5-local).
  last_idx="${idx}"
  print_continue_hint "${last_idx}"
  exit 0
fi

if [[ "${MODE}" == "from" ]]; then
  START_IDX="$(resolve_step_indices "${FROM_ARG}")" || exit 1
  if [[ "${START_IDX}" == *" "* ]]; then
    echo "ERROR: --from requires a single step name, not composite ${FROM_ARG}" >&2
    exit 1
  fi
  # --from 0.7 or 0.8 opts in to a dedicated-cluster step a default run skips.
  if [[ "${START_IDX}" -gt "${END_IDX}" ]]; then
    END_IDX="${START_IDX}"
  fi
fi

echo "=== AKO Training Environment Setup (CLOUD_PROVIDER=${CLOUD_PROVIDER}, DEPLOY_PATH=${DEPLOY_PATH}, NODE_PROVISIONING=${NODE_PROVISIONING}) ==="
if [[ "${END_IDX}" -ge "${UPGRADE_LAB_IDX}" ]]; then
  echo "Note: including step 0.7-upgrade-lab"
else
  echo "Note: skipping step 0.7-upgrade-lab (opt-in — --step 0.7 or --with-upgrade-lab)"
fi
if [[ "${END_IDX}" -ge "${ALL_FLASH_IDX}" ]]; then
  echo "Note: including step 0.8-all-flash"
else
  echo "Note: skipping step 0.8-all-flash (opt-in — --step 0.8)"
fi
if [[ "${SEQUENTIAL}" == true ]]; then
  echo "Note: sequential cluster bootstrap (--sequential)"
fi

if use_parallel_bootstrap; then
  run_step 0
  run_parallel_bootstrap
  run_step 2
  for ((i = 3; i <= 8; i++)); do
    run_step "${i}"
  done
  run_upgrade_lab_post_bootstrap
else
  for ((i = START_IDX; i <= END_IDX; i++)); do
    run_step "${i}"
  done
fi

echo "=== Environment setup complete ==="
