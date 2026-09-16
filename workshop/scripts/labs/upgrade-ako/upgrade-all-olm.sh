#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
load_env
ensure_main_kubecontext

UPGRADE_DIR="$(dirname "$0")"
VERSIONS="${UPGRADE_DIR}/versions.env"
if [[ ! -f "${VERSIONS}" ]]; then
  VERSIONS="${UPGRADE_DIR}/versions.env.example"
fi
# shellcheck disable=SC1090
source "${VERSIONS}"

IFS=',' read -ra LADDER <<< "${AKO_UPGRADE_LADDER}"
STEPS=("${LADDER[@]:1}")

for i in "${!STEPS[@]}"; do
  ver="${STEPS[$i]}"
  echo "=== Upgrade step: ${ver} ($((i + 1))/${#STEPS[@]}) ==="
  if ! "${UPGRADE_DIR}/upgrade-step-olm.sh" "${ver}"; then
    echo "ERROR: ladder stopped at ${ver} — remaining steps were not run" >&2
    for remaining in "${STEPS[@]:i}"; do
      echo "  ./scripts/labs/upgrade-ako/upgrade-step-olm.sh ${remaining}" >&2
    done
    exit 1
  fi
done

echo "=== Ladder complete: ${STEPS[*]} ==="
