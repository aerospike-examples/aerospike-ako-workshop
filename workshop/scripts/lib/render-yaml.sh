#!/usr/bin/env bash
# Render workshop YAML templates that use NODE_ZONE_A / NODE_ZONE_B.
# Requires load_env() to have run.

# Only enable errexit when executed directly; sourcing must not kill the parent shell.
if [[ -n "${BASH_VERSION:-}" ]]; then
  [[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  [[ "${(%):-%x}" == "${0}" ]] && set -euo pipefail
else
  set -euo pipefail
fi

if [[ -n "${BASH_VERSION:-}" ]]; then
  _LIB_SELF="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  _LIB_SELF="${(%):-%x}"
else
  _LIB_SELF="$0"
fi
source "$(dirname "${_LIB_SELF}")/common.sh"
unset _LIB_SELF

render_workshop_yaml() {
  local file="$1"
  require_cmd envsubst
  envsubst '$NODE_ZONE_A $NODE_ZONE_B' < "${file}"
}
