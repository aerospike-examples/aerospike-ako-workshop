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

check "aws" "aws --version" "Install AWS CLI v2"
check "kubectl" "kubectl version --client" "Install kubectl matching cluster version"
check "eksctl" "eksctl version" "Install eksctl 0.190+"
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

check "AWS identity" "aws sts get-caller-identity" "Configure AWS credentials"

# Accounts that mandate a permissions boundary deny CreateRole without it, so catch that here
# rather than mid-bootstrap in CloudFormation. Shared accounts also collide on EKS/IAM names.
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
if [[ -n "${CALLER_ARN}" ]]; then
  echo "OK  AWS caller: ${CALLER_ARN}"
  BOUNDARY_ARN="$(resolve_iam_boundary_arn)"
  if [[ -n "${BOUNDARY_ARN}" ]]; then
    echo "OK  IAM permissions boundary: ${BOUNDARY_ARN}"
    if [[ "${CLUSTER_NAME}" == "my-cluster" ]]; then
      echo "WARN CLUSTER_NAME is the default 'my-cluster' — use a unique name in a shared AWS account"
    fi
    if [[ "${UPGRADE_LAB_CLUSTER_NAME}" == "my-cluster-k8s-upgrade" ]]; then
      echo "WARN UPGRADE_LAB_CLUSTER_NAME is the default — use a unique name in a shared AWS account"
    fi
  elif [[ "${IAM_PERMISSIONS_BOUNDARY}" == "off" ]]; then
    if [[ "${CALLER_ARN}" == *shared-account-powerusers* ]]; then
      echo "WARN IAM_PERMISSIONS_BOUNDARY=off but this looks like a shared account — role creation will be denied"
    else
      echo "SKIP IAM permissions boundary (IAM_PERMISSIONS_BOUNDARY=off)"
    fi
  elif [[ "${IAM_PERMISSIONS_BOUNDARY}" == "required" || "${CALLER_ARN}" == *shared-account-powerusers* ]]; then
    echo "FAIL IAM permissions boundary — ${IAM_PERMISSIONS_BOUNDARY_NAME} not found in this account"
    echo "     This account requires a boundary on every role: ask your AWS admins to publish it,"
    echo "     or set IAM_PERMISSIONS_BOUNDARY to the correct policy ARN in scripts/env/workshop.env"
    fail=1
  else
    echo "SKIP IAM permissions boundary (${IAM_PERMISSIONS_BOUNDARY_NAME} not present in this account)"
  fi
fi

check "SSH key" "aws ec2 describe-key-pairs --region ${AWS_REGION} --key-names ${SSH_PUBLIC_KEY}" \
  "Create EC2 key pair ${SSH_PUBLIC_KEY} in ${AWS_REGION}"

FEATURES="$(features_conf_path)"
if [[ -f "${FEATURES}" ]]; then
  echo "OK  features.conf at ${FEATURES}"
else
  echo "FAIL features.conf — copy Aerospike feature-key to ${WORKSHOP_ROOT}/secrets/features.conf"
  echo "${FEATURES}"
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo ""
  if ! "$(dirname "$0")/01b-check-ec2-capacity.sh"; then
    fail=1
  fi
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "Client validation passed."
else
  echo "Client validation failed. See instructor/client-prerequisites.md"
  exit 1
fi
