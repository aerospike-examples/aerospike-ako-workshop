#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
load_env
ensure_main_kubecontext

EXPECTED="${1:?Usage: verify-ako-version.sh <version>}"

CSV_EXPECTED="aerospike-kubernetes-operator.v${EXPECTED}"
# A CSV phase is not monotonic: OLM keeps reconciling after the first Succeeded
# (webhook certs, replaced-CSV garbage collection, deployment re-check) and drops
# back to Installing while it does. Poll instead of sampling the phase once.
VERIFY_TIMEOUT="${AKO_VERIFY_TIMEOUT:-300}"

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  helm list -n "${OPERATOR_NAMESPACE}" | grep "${HELM_OPERATOR_RELEASE}"
else
  _installed=""
  _current=""
  _state=""
  _phase=""

  _sub_status_field() {
    kubectl get subscription aerospike-kubernetes-operator -n "${OPERATOR_NAMESPACE}" \
      -o jsonpath="{.status.$1}" 2>/dev/null || true
  }

  _read_olm_state() {
    _installed="$(_sub_status_field installedCSV)"
    _current="$(_sub_status_field currentCSV)"
    _state="$(_sub_status_field state)"
    _phase="$(kubectl get csv -n "${OPERATOR_NAMESPACE}" "${CSV_EXPECTED}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  }

  # An unapproved InstallPlan never resolves on its own — no point polling for it.
  _has_unapproved_installplan() {
    local found
    found="$(kubectl get installplan -n "${OPERATOR_NAMESPACE}" --no-headers 2>/dev/null \
      | awk -v target="${CSV_EXPECTED}" '$2 == target && $4 == "false" {print $1}' | head -1)"
    [[ -n "${found}" ]]
  }

  _installed_is_past_expected() {
    local installed_version
    installed_version="$(_ako_version_from_csv_name "${_installed}")"
    [[ -z "${installed_version}" || "${installed_version}" == "${EXPECTED}" ]] && return 1
    [[ "$(printf '%s\n' "${EXPECTED}" "${installed_version}" | sort -V | head -1)" == "${EXPECTED}" ]]
  }

  _fail() {
    echo "ERROR: $1" >&2
    echo "  subscription: installedCSV=${_installed:-missing} currentCSV=${_current:-missing} state=${_state:-unknown}" >&2
    echo "  csv ${CSV_EXPECTED}: phase=${_phase:-missing}" >&2
    if [[ "${_current}" == "${CSV_EXPECTED}" && -z "${_phase}" ]]; then
      echo "NOTE: OLM resolved ${EXPECTED} but the CSV is not installed yet (UpgradePending)." >&2
      echo "      Approve the pending InstallPlan:" >&2
      echo "        ./scripts/labs/upgrade-ako/upgrade-step-olm.sh ${EXPECTED}" >&2
    elif [[ "${_current}" != "${CSV_EXPECTED}" && "${_phase}" == "Succeeded" ]]; then
      echo "NOTE: CSV ${CSV_EXPECTED} still shows Succeeded from a prior step, but OLM has moved on." >&2
      echo "      Continue the ladder from ${_installed#aerospike-kubernetes-operator.v} or reinstall AKO at ${AKO_VERSION_START}." >&2
    fi
    kubectl get csv -n "${OPERATOR_NAMESPACE}" | grep aerospike || true
    kubectl get installplan -n "${OPERATOR_NAMESPACE}" | grep aerospike || true
    exit 1
  }

  _deadline=$((SECONDS + VERIFY_TIMEOUT))
  while :; do
    _read_olm_state

    if [[ "${_installed}" == "${CSV_EXPECTED}" && "${_phase}" == "Succeeded" ]]; then
      break
    fi

    if _installed_is_past_expected; then
      _fail "AKO is past ${EXPECTED} (installedCSV=${_installed}) — the ladder cannot go back"
    fi

    if [[ -z "${_phase}" ]] && _has_unapproved_installplan; then
      _fail "InstallPlan for ${CSV_EXPECTED} is waiting for manual approval"
    fi

    if [[ "${SECONDS}" -ge "${_deadline}" ]]; then
      if [[ "${_installed}" != "${CSV_EXPECTED}" ]]; then
        _fail "AKO not at ${EXPECTED} after ${VERIFY_TIMEOUT}s"
      fi
      _fail "AKO installedCSV is ${EXPECTED} but CSV phase=${_phase:-missing} after ${VERIFY_TIMEOUT}s"
    fi

    echo "  Waiting for ${CSV_EXPECTED} to settle (installedCSV=${_installed:-missing}, phase=${_phase:-missing})..."
    sleep 10
  done

  kubectl get csv -n "${OPERATOR_NAMESPACE}" | grep "${CSV_EXPECTED}"
fi

kubectl -n "${NAMESPACE}" get aerospikecluster aerocluster -o jsonpath='{.status.phase}' 2>/dev/null && echo || true
echo "Expected AKO version: ${EXPECTED}; Aerospike cluster should remain Completed."
