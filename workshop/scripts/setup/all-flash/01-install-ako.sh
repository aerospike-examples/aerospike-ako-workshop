#!/usr/bin/env bash
# Install AKO on the all-flash cluster at ALL_FLASH_AKO_VERSION (default 4.5.0).
# Unlike the upgrade-lab cluster this honors DEPLOY_PATH, so Section 4 stays on
# the same Path A / Path B the trainee picked. load_env remaps AKO_VERSION_START
# once CLUSTER_NAME is the all-flash cluster.
set -euo pipefail
ALL_FLASH_DIR="$(dirname "$0")"
SETUP_DIR="$(cd "${ALL_FLASH_DIR}/.." && pwd)"
source "${ALL_FLASH_DIR}/../../lib/common.sh"
load_env
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext

echo "Installing AKO ${ALL_FLASH_AKO_VERSION} on ${ALL_FLASH_CLUSTER_NAME} (DEPLOY_PATH=${DEPLOY_PATH})..."

# OLM skip logic treats any ladder CSV as "already installed". Section 4 is not
# on that ladder — drop a stale older CSV so startingCSV can pin 4.5.0.
if [[ "${DEPLOY_PATH}" == "olm" ]]; then
  target_csv="aerospike-kubernetes-operator.v${ALL_FLASH_AKO_VERSION}"
  target_phase="$(kubectl get csv -n "${OPERATOR_NAMESPACE}" "${target_csv}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${target_phase}" != "Succeeded" ]]; then
    stale="$(kubectl get csv -n "${OPERATOR_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | grep aerospike-kubernetes-operator || true)"
    if [[ -n "${stale}" ]]; then
      echo "Replacing existing AKO CSV(s) so all-flash can pin ${ALL_FLASH_AKO_VERSION}:"
      echo "${stale}"
      kubectl delete subscription aerospike-kubernetes-operator -n "${OPERATOR_NAMESPACE}" --ignore-not-found
      while IFS= read -r csv; do
        [[ -z "${csv}" ]] && continue
        kubectl delete csv "${csv}" -n "${OPERATOR_NAMESPACE}" --ignore-not-found
      done <<< "${stale}"
    fi
  fi
fi

case "${DEPLOY_PATH}" in
  olm)
    "${SETUP_DIR}/olm/setup-all-olm.sh"
    ;;
  helm)
    "${SETUP_DIR}/helm/setup-all-helm.sh"
    ;;
  *)
    echo "ERROR: DEPLOY_PATH must be 'olm' or 'helm', got: ${DEPLOY_PATH}" >&2
    exit 1
    ;;
esac

echo "AKO ${ALL_FLASH_AKO_VERSION} install complete on ${ALL_FLASH_CLUSTER_NAME} (DEPLOY_PATH=${DEPLOY_PATH})."
