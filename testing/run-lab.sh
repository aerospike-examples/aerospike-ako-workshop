#!/usr/bin/env bash
# testing/run-lab.sh <lab-id>
#
# Run a single lab's automated test standalone, e.g.:
#   ./testing/run-lab.sh 1.1
#
# Dispatches to testing/labs/<lab-id>.sh. Assumes the target EKS cluster/env
# is already bootstrapped (see testing/test-matrix.sh for full bootstrap).
set -euo pipefail
TESTING_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

list_available_labs() {
  local f
  for f in "${TESTING_ROOT}"/labs/*.sh; do
    [[ -f "${f}" ]] || continue
    f="$(basename "${f}")"
    printf '%s ' "${f%.sh}"
  done
}

LAB_ID="${1:-}"
if [[ -z "${LAB_ID}" ]]; then
  echo "Usage: $(basename "$0") <lab-id>" >&2
  echo "Available labs: $(list_available_labs)" >&2
  exit 1
fi

SCRIPT="${TESTING_ROOT}/labs/${LAB_ID}.sh"
if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: no automated test for lab ${LAB_ID}." >&2
  echo "Available labs: $(list_available_labs)" >&2
  echo "NOTE: Lab 2.6 (K8s control plane upgrade) is intentionally out of scope — it is tested separately on the upgrade-lab cluster." >&2
  echo "NOTE: Section 3 labs (3.1-3.5) chain in order — run 3.1 first (or run the full suite)." >&2
  echo "NOTE: Labs 4.1/4.2 (all-flash) run on the opt-in dedicated cluster — bootstrap it with setup-all.sh --step 0.8 first." >&2
  exit 1
fi

exec "${SCRIPT}"
