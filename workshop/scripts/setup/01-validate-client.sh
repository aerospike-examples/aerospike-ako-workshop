#!/usr/bin/env bash
# Pre-flight checks on instructor client machine (before Section 0)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "OK  $1"
  else
    echo "FAIL $1 — $3"
    fail=1
  fi
}

echo "Cloud provider: ${CLOUD_PROVIDER} ($(provider_display_name))"

check "kubectl" "kubectl version --client" "Install kubectl matching cluster version"
check "git" "git --version" "Install git"
check "curl" "curl --version" "Install curl"
check "bash" "bash --version" "Install bash 4+"

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  check "helm" "helm version" "Install Helm 3.12+ (required for Path B)"
fi

if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
  check "helm" "helm version" "Install Helm 3.12+ (required for Karpenter controller)"
  if helm search repo karpenter 2>/dev/null | grep -q karpenter || true; then
    echo "OK  helm (Karpenter OCI install uses public.ecr.aws/karpenter/karpenter)"
  fi
fi

check "krew" "kubectl krew version" "Install krew: https://krew.sigs.k8s.io"
if kubectl krew list 2>/dev/null | grep -q akoctl; then
  echo "OK  akoctl"
else
  echo "SKIP akoctl (optional — installed in Lab 0.4 via ./scripts/setup/04-install-akoctl.sh)"
fi

command -v jq >/dev/null 2>&1 && echo "OK  jq (optional)" || echo "SKIP jq (optional, recommended)"

VENDOR_STORAGE="$(vendor_storage_dir)"
for f in local_volume_provisioner_cleanup.yaml local_volume_provisioner_cleanup_rbac.yaml; do
  if [[ -f "${VENDOR_STORAGE}/${f}" ]]; then
    echo "OK  vendor/storage/${f}"
  else
    echo "FAIL vendor/storage/${f} missing — required for local PVC cleanup"
    fail=1
  fi
done

FEATURES="$(features_conf_path)"
if [[ -f "${FEATURES}" ]]; then
  echo "OK  features.conf at ${FEATURES}"
else
  echo "FAIL features.conf — copy Aerospike feature-key to ${WORKSHOP_ROOT}/secrets/features.conf"
  echo "${FEATURES}"
  fail=1
fi

if ! provider_validate_client; then
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "Client validation passed."
else
  echo "Client validation failed. See instructor/client-prerequisites.md"
  exit 1
fi
