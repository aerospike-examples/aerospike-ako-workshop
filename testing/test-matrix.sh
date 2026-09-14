#!/usr/bin/env bash
# testing/test-matrix.sh
#
# Top-level driver: runs the full lab suite (testing/test-all-labs.sh) for
# each of the 3 target configurations, sequentially, reusing one environment:
#
#   1. olm  + eksctl
#   2. helm + eksctl
#   3. helm + karpenter
#
# Lab 2.6 (K8s control plane upgrade) is out of scope — the upgrade-lab cluster is
# opt-in (setup-all.sh --step 0.7 / --with-upgrade-lab) and is never created by a
# default bootstrap. Section 4 (all-flash) is likewise out of scope: setup step
# 0.8 is opt-in, so 4.1/4.2 are validated separately with ./testing/run-lab.sh.
#
# For each config: write workshop/scripts/env/workshop.env (DEPLOY_PATH /
# NODE_PROVISIONING only — this is the one workshop-owned file every run
# customizes; it's gitignored and instructor-editable by design) -> bootstrap
# (setup-all.sh --skip-upgrade-lab) -> run full lab suite -> on success,
# tear down (cleanup-lab.sh --main-only --yes) and continue; on failure, STOP
# the whole matrix immediately and leave the cluster up for debugging.
#
# Usage:
#   ./testing/test-matrix.sh [--matrix-id <id>] [--configs olm:eksctl,helm:eksctl,helm:karpenter]
#
# This launches real EKS infrastructure (~6-8h per config with Section 3,
# ~18-24h total across all three). Run as a background/nohup process, not
# interactively.
set -uo pipefail
TESTING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP_ROOT="$(cd "${TESTING_ROOT}/../workshop" && pwd)"
ENV_FILE="${WORKSHOP_ROOT}/scripts/env/workshop.env"
ENV_EXAMPLE="${WORKSHOP_ROOT}/scripts/env/workshop.env.example"

DEFAULT_CONFIGS="olm:eksctl,helm:eksctl,helm:karpenter"
CONFIGS="${DEFAULT_CONFIGS}"
MATRIX_ID=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--matrix-id <id>] [--configs <deploy:provisioning,...>]

  --matrix-id <id>   Name for this matrix run's directory under testing/runs/
                      (default: timestamp, e.g. matrix-20260718-210500)
  --configs <list>   Comma-separated deploy:provisioning pairs to run, in
                      order (default: ${DEFAULT_CONFIGS})

Each config runs: write workshop.env -> setup-all.sh --skip-upgrade-lab ->
test-all-labs.sh -> cleanup-lab.sh --main-only --yes (on success).

On failure, the matrix stops immediately; the live cluster is left up for
debugging. Resume with:
  1. Fix the issue
  2. ./workshop/scripts/cleanup-lab.sh --main-only --yes   (or retry in place:
     ./testing/test-all-labs.sh --run-id <failed-run-id> --resume)
  3. Re-run this script with --configs starting from the failed config onward
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --matrix-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --matrix-id requires a value" >&2; exit 1; }
      MATRIX_ID="$2"
      shift 2
      ;;
    --configs)
      [[ $# -ge 2 ]] || { echo "ERROR: --configs requires a value" >&2; exit 1; }
      CONFIGS="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${MATRIX_ID}" ]]; then
  MATRIX_ID="matrix-$(date +%Y%m%d-%H%M%S)"
fi

MATRIX_DIR="${TESTING_ROOT}/runs/${MATRIX_ID}"
mkdir -p "${MATRIX_DIR}"

write_workshop_env() {
  local deploy_path="$1" node_provisioning="$2"

  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "No existing workshop.env — seeding from workshop.env.example"
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  fi

  # Preserve every other setting (SSH key, AWS region, etc.) — only flip the
  # two knobs this matrix is testing.
  sed -i.bak -E \
    -e "s/^DEPLOY_PATH=.*/DEPLOY_PATH=${deploy_path}/" \
    -e "s/^NODE_PROVISIONING=.*/NODE_PROVISIONING=${node_provisioning}/" \
    "${ENV_FILE}"
  rm -f "${ENV_FILE}.bak"

  echo "workshop.env set: DEPLOY_PATH=${deploy_path} NODE_PROVISIONING=${node_provisioning}"
}

IFS=',' read -ra CONFIG_LIST <<< "${CONFIGS}"

echo "=== testing/test-matrix.sh — matrix-id=${MATRIX_ID} ==="
echo "Configs: ${CONFIG_LIST[*]}"
echo "Matrix dir: ${MATRIX_DIR}"
echo ""

config_run_ids=()
config_names=()
config_results=()
failed_config=""

for config in "${CONFIG_LIST[@]}"; do
  deploy_path="${config%%:*}"
  node_provisioning="${config##*:}"
  run_id="${MATRIX_ID}-${deploy_path}-${node_provisioning}"

  echo ""
  echo "############################################################"
  echo "# Config: DEPLOY_PATH=${deploy_path} NODE_PROVISIONING=${node_provisioning}  (run-id: ${run_id})"
  echo "############################################################"

  write_workshop_env "${deploy_path}" "${node_provisioning}"

  echo "--- Bootstrapping environment (setup-all.sh --skip-upgrade-lab) ---"
  if ! "${WORKSHOP_ROOT}/scripts/setup/setup-all.sh" --skip-upgrade-lab \
      > "${MATRIX_DIR}/${run_id}-setup.log" 2>&1; then
    echo "ERROR: setup-all.sh failed for config ${config} — see ${MATRIX_DIR}/${run_id}-setup.log" >&2
    tail -n 60 "${MATRIX_DIR}/${run_id}-setup.log" >&2
    failed_config="${config}"
    config_names+=("${config}")
    config_run_ids+=("${run_id}")
    config_results+=("SETUP FAILED")
    break
  fi

  echo "--- Running full lab suite (test-all-labs.sh) ---"
  config_names+=("${config}")
  config_run_ids+=("${run_id}")
  if "${TESTING_ROOT}/test-all-labs.sh" --run-id "${run_id}"; then
    config_results+=("PASS")
    echo "--- Config ${config} PASSED — tearing down (cleanup-lab.sh --main-only --yes) ---"
    "${WORKSHOP_ROOT}/scripts/cleanup-lab.sh" --main-only --yes
  else
    config_results+=("FAIL")
    failed_config="${config}"
    echo "ERROR: lab suite failed for config ${config} (run-id ${run_id}) — see ${TESTING_ROOT}/runs/${run_id}/report.md" >&2
    echo "Cluster left up for debugging (no teardown on failure)." >&2
    break
  fi
done

SUMMARY="${MATRIX_DIR}/matrix-summary.md"
{
  echo "# Test matrix summary — matrix-id: ${MATRIX_ID}"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "Cross-check against [walkthrough-checklist.md](../../../workshop/validation/walkthrough-checklist.md) for the manual sign-off equivalent."
  echo ""
  echo "| Config | Run ID | Result | Report |"
  echo "|--------|--------|--------|--------|"
  for i in "${!config_names[@]}"; do
    echo "| ${config_names[$i]} | ${config_run_ids[$i]} | ${config_results[$i]} | runs/${config_run_ids[$i]}/report.md |"
  done
  echo ""
  if [[ -n "${failed_config}" ]]; then
    echo "**Result: FAIL at config ${failed_config}.** Remaining configs not run."
    echo ""
    echo "To resume once fixed:"
    echo ""
    echo '```bash'
    echo "./workshop/scripts/cleanup-lab.sh --main-only --yes   # if a cluster was left up"
    echo "./testing/test-matrix.sh --matrix-id ${MATRIX_ID} --configs <remaining configs from ${failed_config} onward>"
    echo '```'
  else
    echo "**Result: PASS — all ${#config_names[@]} configs completed successfully.**"
  fi
} > "${SUMMARY}"

echo ""
echo "Matrix summary: ${SUMMARY}"

if [[ -n "${failed_config}" ]]; then
  echo "=== test-matrix: FAIL (stopped at config ${failed_config}) ==="
  exit 1
fi

echo "=== test-matrix: PASS (all configs completed) ==="
