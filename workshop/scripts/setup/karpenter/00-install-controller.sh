#!/usr/bin/env bash
# Install Karpenter controller (Helm) with IRSA on the main cluster.
set -euo pipefail
source "$(dirname "$0")/../../lib/common.sh"
load_env
ensure_main_kubecontext

require_cmd aws
require_cmd eksctl
require_cmd helm
require_cmd kubectl

ACCOUNT_ID="$(aws_account_id)"
CLUSTER_ENDPOINT="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "cluster.endpoint" --output text)"
NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
CONTROLLER_ROLE_NAME="KarpenterControllerRole-${CLUSTER_NAME}"
CONTROLLER_POLICY_NAME="KarpenterControllerPolicy-${CLUSTER_NAME}"

echo "Installing Karpenter ${KARPENTER_VERSION} on ${CLUSTER_NAME}..."

# Discovery tags for subnets and cluster security group
CLUSTER_SG="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)"
aws ec2 create-tags --region "${AWS_REGION}" \
  --resources "${CLUSTER_SG}" \
  --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" 2>/dev/null || true

for subnet in $(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
  --query "cluster.resourcesVpcConfig.subnetIds[]" --output text); do
  aws ec2 create-tags --region "${AWS_REGION}" \
    --resources "${subnet}" \
    --tags "Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}" 2>/dev/null || true
done

# Node IAM role + instance profile
KARPENTER_NODE_POLICIES=(
  AmazonEKSWorkerNodePolicy
  AmazonEKS_CNI_Policy
  AmazonEC2ContainerRegistryReadOnly
  AmazonSSMManagedInstanceCore
)
set_iam_boundary_cli_args
if ! aws iam get-role --role-name "${NODE_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${NODE_ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    ${IAM_BOUNDARY_CLI_ARGS[@]+"${IAM_BOUNDARY_CLI_ARGS[@]}"} >/dev/null
  aws iam create-instance-profile --instance-profile-name "${NODE_ROLE_NAME}" >/dev/null 2>&1 || true
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${NODE_ROLE_NAME}" \
    --role-name "${NODE_ROLE_NAME}" 2>/dev/null || true
fi
for pol in "${KARPENTER_NODE_POLICIES[@]}"; do
  aws iam attach-role-policy --role-name "${NODE_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/${pol}"
done
echo "Ensured ${#KARPENTER_NODE_POLICIES[@]} policies on ${NODE_ROLE_NAME}"

# EKS must authorize the Karpenter node role to register worker nodes (access entries API).
# EC2_LINUX type grants system:nodes group automatically — do not associate AmazonEKSNodeRole
# (that policy is only for STANDARD-type access entries).
NODE_ROLE_ARN="$(aws iam get-role --role-name "${NODE_ROLE_NAME}" --query Role.Arn --output text)"
echo "Ensuring EKS access entry for Karpenter node role ${NODE_ROLE_ARN}..."
if ! aws eks describe-access-entry \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --principal-arn "${NODE_ROLE_ARN}" >/dev/null 2>&1; then
  aws eks create-access-entry \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --principal-arn "${NODE_ROLE_ARN}" \
    --type EC2_LINUX \
    --no-cli-pager >/dev/null
  echo "Created EKS access entry for ${NODE_ROLE_ARN}"
fi

# Controller IAM policy
if ! aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${CONTROLLER_POLICY_NAME}" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "${CONTROLLER_POLICY_NAME}" \
    --policy-document file://"${WORKSHOP_ROOT}/scripts/setup/karpenter/karpenter-controller-policy.json" >/dev/null
fi

# Config file rather than CLI flags: the IRSA role needs a permissions boundary in
# shared accounts, and eksctl only reads that from a config file.
IRSA_CONFIG="$(mktemp)"
render_iamserviceaccount_config \
  "${CLUSTER_NAME}" \
  "${AWS_REGION}" \
  karpenter \
  "${KARPENTER_NAMESPACE}" \
  "${CONTROLLER_ROLE_NAME}" \
  "arn:aws:iam::${ACCOUNT_ID}:policy/${CONTROLLER_POLICY_NAME}" \
  false > "${IRSA_CONFIG}"
eksctl create iamserviceaccount -f "${IRSA_CONFIG}" \
  --override-existing-serviceaccounts \
  --approve
rm -f "${IRSA_CONFIG}"

# Toleration/nodeSelector for the tainted system nodegroup must be set at install time, not
# patched afterward: with --wait, helm blocks until pods schedule, and pods can't schedule
# without these until a post-install patch runs — a deadlock. Bake them into the values instead.
SCHEDULING_VALUES="$(mktemp)"
trap 'rm -f "${SCHEDULING_VALUES}"' EXIT
cat > "${SCHEDULING_VALUES}" <<EOF
nodeSelector:
  role: system
tolerations:
  - key: CriticalAddonsOnly
    operator: Exists
EOF

# serviceAccount.create=false — the eksctl-created IRSA ServiceAccount above is reused as-is;
# creating it again via Helm conflicts with eksctl's ownership metadata. serviceAccount.name
# must also be set explicitly: without it the chart falls back to the "default" SA (no IRSA),
# which crash-loops on 403s since it has no AWS permissions.
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "controller.resources.requests.cpu=1" \
  --set "controller.resources.requests.memory=1Gi" \
  --set "controller.resources.limits.cpu=1" \
  --set "controller.resources.limits.memory=1Gi" \
  -f "${SCHEDULING_VALUES}" \
  --wait

echo "Karpenter controller Ready. Node role: ${NODE_ROLE_NAME}"
