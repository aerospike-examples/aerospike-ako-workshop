#!/usr/bin/env bash
# testing/test-all-labs.sh
#
# Single-configuration orchestrator: runs every non-optional lab from 1.1
# through 3.5 (curriculum order, per workshop/LAB_REGISTRY.yaml — Labs 2.6 and
# 4.1/4.2 are out of scope and never invoked) against whatever environment is
# already bootstrapped (Section 0 / setup-all.sh) and configured (workshop.env).
# Section 3 (3.1-3.5) is part of the curriculum and always runs.
#
# Section 4 (all-flash) runs on its own opt-in cluster, so it is not part of
# this suite: bootstrap with setup-all.sh --step 0.8, then
# ./testing/run-lab.sh 4.1 && ./testing/run-lab.sh 4.2.
#
# Usage:
#   ./testing/test-all-labs.sh [--run-id <id>] [--resume]
#
#   --run-id <id>   Name for this run's directory under testing/runs/ (default:
#                   timestamp, e.g. 20260718-210500)
#   --resume        Resume an existing --run-id from its last passed lab
#                   (reads testing/runs/<id>/.checkpoint)
#
# On the first failing lab: stops immediately (fail-fast — later labs depend
# on earlier state, e.g. 1.4/2.3/2.4 need 2.2's AKO version, and 3.2-3.5 each
# build on the cluster state left by the prior 3.x lab), writes
# report.md with the failure, and exits non-zero. The live cluster is left
# up for debugging (nothing here tears anything down — that's test-matrix.sh's
# job).
set -uo pipefail
TESTING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Curriculum order for this automation, per workshop/LAB_REGISTRY.yaml
# curriculum_order — starts at 1.1, runs Section 3 (3.1-3.5), and skips the labs
# that live on their own cluster: 2.6 (K8s control plane upgrade, upgrade-lab)
# and 4.1/4.2 (all-flash, opt-in dedicated cluster).
LAB_ORDER=(1.1 1.2 1.3 2.1 2.2 1.4 2.3 2.4 2.5 3.1 3.2 3.3 3.4 3.5)

RUN_ID=""
RESUME=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--run-id <id>] [--resume]

  --run-id <id>   Name for this run's directory under testing/runs/
  --resume        Resume an existing --run-id from its last passed lab
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --run-id requires a value" >&2; exit 1; }
      RUN_ID="$2"
      shift 2
      ;;
    --resume) RESUME=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${RUN_ID}" ]]; then
  RUN_ID="$(date +%Y%m%d-%H%M%S)"
fi

RUN_DIR="${TESTING_ROOT}/runs/${RUN_ID}"
LOG_DIR="${RUN_DIR}/logs"
CHECKPOINT="${RUN_DIR}/.checkpoint"
REPORT="${RUN_DIR}/report.md"
SUMMARY_JSON="${RUN_DIR}/summary.json"
export TEST_RUN_ARTIFACTS_DIR="${RUN_DIR}/artifacts"

mkdir -p "${LOG_DIR}" "${TEST_RUN_ARTIFACTS_DIR}"

if [[ "${RESUME}" == true && ! -f "${CHECKPOINT}" ]]; then
  echo "ERROR: --resume given but no checkpoint found at ${CHECKPOINT}" >&2
  exit 1
fi

already_passed() {
  local lab="$1"
  [[ -f "${CHECKPOINT}" ]] && grep -qxF "${lab}" "${CHECKPOINT}"
}

mark_passed() {
  echo "$1" >> "${CHECKPOINT}"
}

declare -A LAB_STATUS
declare -A LAB_DURATION

echo "=== testing/test-all-labs.sh — run-id=${RUN_ID} resume=${RESUME} ==="
echo "Log dir: ${LOG_DIR}"
echo "Labs: ${LAB_ORDER[*]}"
echo ""

overall_start="${SECONDS}"
failed_lab=""

for lab in "${LAB_ORDER[@]}"; do
  if [[ "${RESUME}" == true ]] && already_passed "${lab}"; then
    echo "SKIP  Lab ${lab} (already passed per checkpoint)"
    LAB_STATUS["${lab}"]="SKIPPED (resume)"
    LAB_DURATION["${lab}"]=0
    continue
  fi

  echo "--- Lab ${lab}: starting ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ---"
  lab_start="${SECONDS}"
  log_file="${LOG_DIR}/${lab}.log"

  if "${TESTING_ROOT}/run-lab.sh" "${lab}" > "${log_file}" 2>&1; then
    lab_duration=$((SECONDS - lab_start))
    LAB_STATUS["${lab}"]="PASS"
    LAB_DURATION["${lab}"]="${lab_duration}"
    mark_passed "${lab}"
    echo "PASS  Lab ${lab} (${lab_duration}s) — log: ${log_file}"
  else
    lab_duration=$((SECONDS - lab_start))
    LAB_STATUS["${lab}"]="FAIL"
    LAB_DURATION["${lab}"]="${lab_duration}"
    failed_lab="${lab}"
    echo "FAIL  Lab ${lab} (${lab_duration}s) — log: ${log_file}" >&2
    echo "--- Last 40 lines of ${log_file}: ---" >&2
    tail -n 40 "${log_file}" >&2
    break
  fi
done

overall_duration=$((SECONDS - overall_start))

{
  echo "# Test-all-labs report — run-id: ${RUN_ID}"
  echo ""
  echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Total duration: ${overall_duration}s"
  echo ""
  echo "| Lab | Status | Duration (s) | Log |"
  echo "|-----|--------|---------------|-----|"
  for lab in "${LAB_ORDER[@]}"; do
    status="${LAB_STATUS[${lab}]:-NOT RUN}"
    duration="${LAB_DURATION[${lab}]:-0}"
    echo "| ${lab} | ${status} | ${duration} | logs/${lab}.log |"
  done
  echo ""
  if [[ -n "${failed_lab}" ]]; then
    echo "**Result: FAIL at Lab ${failed_lab}.** Remaining labs not run (fail-fast)."
    echo ""
    echo "Resume after fixing the issue with:"
    echo ""
    echo '```bash'
    echo "./testing/test-all-labs.sh --run-id ${RUN_ID} --resume"
    echo '```'
  else
    echo "**Result: PASS — all labs completed.**"
  fi
} > "${REPORT}"

{
  echo "{"
  echo "  \"run_id\": \"${RUN_ID}\","
  echo "  \"duration_seconds\": ${overall_duration},"
  echo "  \"result\": \"$( [[ -n "${failed_lab}" ]] && echo FAIL || echo PASS )\","
  echo "  \"failed_lab\": \"${failed_lab}\","
  echo "  \"labs\": {"
  first=true
  for lab in "${LAB_ORDER[@]}"; do
    [[ "${first}" == true ]] && first=false || echo ","
    printf '    "%s": {"status": "%s", "duration_seconds": %s}' \
      "${lab}" "${LAB_STATUS[${lab}]:-NOT RUN}" "${LAB_DURATION[${lab}]:-0}"
  done
  echo ""
  echo "  }"
  echo "}"
} > "${SUMMARY_JSON}"

echo ""
echo "Report: ${REPORT}"
echo "Summary: ${SUMMARY_JSON}"

if [[ -n "${failed_lab}" ]]; then
  echo "=== test-all-labs: FAIL (stopped at Lab ${failed_lab}) ==="
  exit 1
fi

echo "=== test-all-labs: PASS (all labs completed in ${overall_duration}s) ==="
