#!/usr/bin/env bash
# EBS CSI + eks_ssd storage class
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env
ensure_main_kubecontext

require_cmd aws
require_cmd eksctl
require_cmd kubectl

STORAGE_YAML="$(vendor_storage_dir)/eks_ssd_storage_class.yaml"

if [[ ! -f "${STORAGE_YAML}" ]]; then
  echo "ERROR: ${STORAGE_YAML} not found." >&2
  exit 1
fi

kubectl apply -f "${STORAGE_YAML}"

oidc_id=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
echo "OIDC provider id: ${oidc_id}"

eksctl utils associate-iam-oidc-provider --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" --approve

# IAM role names are account-global, so scope it to the cluster — colleagues sharing an
# AWS account would otherwise fight over one AmazonEKS_EBS_CSI_DriverRole.
EBS_CSI_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole-${CLUSTER_NAME}"

# Config file rather than CLI flags: the IRSA role needs a permissions boundary in
# shared accounts, and eksctl only reads that from a config file.
IRSA_CONFIG="$(mktemp)"
trap 'rm -f "${IRSA_CONFIG}"' EXIT
render_iamserviceaccount_config \
  "${CLUSTER_NAME}" \
  "${AWS_REGION}" \
  ebs-csi-controller-sa \
  kube-system \
  "${EBS_CSI_ROLE_NAME}" \
  arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  true > "${IRSA_CONFIG}"
eksctl create iamserviceaccount -f "${IRSA_CONFIG}" --approve

account_id="$(aws_account_id)"
eksctl create addon --name aws-ebs-csi-driver --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --service-account-role-arn "arn:aws:iam::${account_id}:role/${EBS_CSI_ROLE_NAME}" --force

kubectl get storageclass ssd
echo "Expected: StorageClass ssd exists."
