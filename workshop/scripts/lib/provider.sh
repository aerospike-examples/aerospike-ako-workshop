#!/usr/bin/env bash
# Load the cloud-provider plugin (eks | gke). Sourced from load_env() after
# CLOUD_PROVIDER is set. Azure would add providers/aks.sh and a case arm.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
  echo "ERROR: provider.sh must be sourced after common.sh (SCRIPT_DIR unset)" >&2
  return 1 2>/dev/null || exit 1
fi

_PROVIDER_DIR="${SCRIPT_DIR}/providers"
case "${CLOUD_PROVIDER}" in
  eks)
    # shellcheck source=providers/eks.sh
    source "${_PROVIDER_DIR}/eks.sh"
    ;;
  gke)
    # shellcheck source=providers/gke.sh
    source "${_PROVIDER_DIR}/gke.sh"
    ;;
  *)
    echo "ERROR: unsupported CLOUD_PROVIDER=${CLOUD_PROVIDER} (use eks or gke)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
unset _PROVIDER_DIR
