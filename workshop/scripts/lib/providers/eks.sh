#!/usr/bin/env bash
# AWS EKS provider — eksctl / aws CLI.

provider_display_name() {
  echo "EKS"
}

provider_kubeconfig_hint() {
  local cluster_name="$1"
  echo "aws eks update-kubeconfig --name ${cluster_name} --region ${AWS_REGION}"
}

provider_cluster_exists() {
  local name="$1"
  eksctl get cluster --name "${name}" --region "${AWS_REGION}" >/dev/null 2>&1
}

provider_update_kubeconfig() {
  local cluster_name="$1"
  require_cmd aws
  if [[ -n "${KUBECONFIG:-}" ]]; then
    aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" --kubeconfig "${KUBECONFIG}" >/dev/null
  else
    aws eks update-kubeconfig --name "${cluster_name}" --region "${AWS_REGION}" >/dev/null
  fi
}

provider_delete_cluster() {
  local name="$1"
  require_cmd eksctl
  echo "Deleting EKS cluster ${name}..."
  eksctl delete cluster --name "${name}" --region "${AWS_REGION}" --wait
}

provider_control_plane_version() {
  local name="$1"
  require_cmd aws
  aws eks describe-cluster --name "${name}" --region "${AWS_REGION}" \
    --query 'cluster.version' --output text 2>/dev/null || echo unknown
}

provider_control_plane_status() {
  local name="$1"
  require_cmd aws
  aws eks describe-cluster --name "${name}" --region "${AWS_REGION}" \
    --query 'cluster.status' --output text 2>/dev/null || echo unknown
}

provider_version_matches() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]]
}

provider_upgrade_control_plane() {
  local name="$1"
  local version="$2"
  require_cmd eksctl
  require_cmd aws
  echo "Upgrading EKS control plane ${name} to ${version}..."
  eksctl upgrade cluster --name "${name}" --region "${AWS_REGION}" --version "${version}" --approve
  aws eks wait cluster-active --name "${name}" --region "${AWS_REGION}"
}

provider_upgrade_nodes() {
  local cluster_name="$1"
  local ng_name="$2"
  local version="$3"
  require_cmd eksctl
  require_cmd aws
  echo "Upgrading EKS nodegroup ${ng_name} on ${cluster_name} to ${version}..."
  eksctl upgrade nodegroup \
    --cluster "${cluster_name}" \
    --region "${AWS_REGION}" \
    --name "${ng_name}" \
    --kubernetes-version "${version}"
  aws eks wait nodegroup-active \
    --cluster-name "${cluster_name}" \
    --nodegroup-name "${ng_name}" \
    --region "${AWS_REGION}"
}

provider_setup_block_storage() {
  local cluster_name="${1:-${CLUSTER_NAME}}"
  require_cmd aws
  require_cmd eksctl
  require_cmd kubectl

  local storage_yaml
  storage_yaml="$(vendor_storage_dir)/eks_ssd_storage_class.yaml"
  if [[ ! -f "${storage_yaml}" ]]; then
    echo "ERROR: ${storage_yaml} not found." >&2
    exit 1
  fi
  kubectl apply -f "${storage_yaml}"

  local oidc_id
  oidc_id=$(aws eks describe-cluster --name "${cluster_name}" --region "${AWS_REGION}" \
    --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
  echo "OIDC provider id: ${oidc_id}"

  eksctl utils associate-iam-oidc-provider --cluster "${cluster_name}" --region "${AWS_REGION}" --approve

  local ebs_csi_role_name="AmazonEKS_EBS_CSI_DriverRole-${cluster_name}"
  local irsa_config
  irsa_config="$(mktemp)"
  render_iamserviceaccount_config \
    "${cluster_name}" \
    "${AWS_REGION}" \
    ebs-csi-controller-sa \
    kube-system \
    "${ebs_csi_role_name}" \
    arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    true > "${irsa_config}"
  eksctl create iamserviceaccount -f "${irsa_config}" --approve
  rm -f "${irsa_config}"

  local account_id
  account_id="$(aws_account_id)"
  eksctl create addon --name aws-ebs-csi-driver --cluster "${cluster_name}" --region "${AWS_REGION}" \
    --service-account-role-arn "arn:aws:iam::${account_id}:role/${ebs_csi_role_name}" --force

  kubectl get storageclass ssd
  echo "Expected: StorageClass ssd exists."
}

provider_node_pool_label_key() {
  echo "alpha.eksctl.io/nodegroup-name"
}

provider_validate_client() {
  _PROVIDER_FAIL=0
  _eks_check() {
    if eval "$2" >/dev/null 2>&1; then
      echo "OK  $1"
    else
      echo "FAIL $1 — $3"
      _PROVIDER_FAIL=1
    fi
  }

  _eks_check "aws" "aws --version" "Install AWS CLI v2"
  _eks_check "eksctl" "eksctl version" "Install eksctl 0.190+"
  _eks_check "AWS identity" "aws sts get-caller-identity" "Configure AWS credentials"

  local caller_arn boundary_arn
  caller_arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
  if [[ -n "${caller_arn}" ]]; then
    echo "OK  AWS caller: ${caller_arn}"
    boundary_arn="$(resolve_iam_boundary_arn)"
    if [[ -n "${boundary_arn}" ]]; then
      echo "OK  IAM permissions boundary: ${boundary_arn}"
      if [[ "${CLUSTER_NAME}" == "my-cluster" ]]; then
        echo "WARN CLUSTER_NAME is the default 'my-cluster' — use a unique name in a shared AWS account"
      fi
      if [[ "${UPGRADE_LAB_CLUSTER_NAME}" == "my-cluster-k8s-upgrade" ]]; then
        echo "WARN UPGRADE_LAB_CLUSTER_NAME is the default — use a unique name in a shared AWS account"
      fi
    elif [[ "${IAM_PERMISSIONS_BOUNDARY}" == "off" ]]; then
      if [[ "${caller_arn}" == *shared-account-powerusers* ]]; then
        echo "WARN IAM_PERMISSIONS_BOUNDARY=off but this looks like a shared account — role creation will be denied"
      else
        echo "SKIP IAM permissions boundary (IAM_PERMISSIONS_BOUNDARY=off)"
      fi
    elif [[ "${IAM_PERMISSIONS_BOUNDARY}" == "required" || "${caller_arn}" == *shared-account-powerusers* ]]; then
      echo "FAIL IAM permissions boundary — ${IAM_PERMISSIONS_BOUNDARY_NAME} not found in this account"
      echo "     This account requires a boundary on every role: ask your AWS admins to publish it,"
      echo "     or set IAM_PERMISSIONS_BOUNDARY to the correct policy ARN in scripts/env/workshop.env"
      _PROVIDER_FAIL=1
    else
      echo "SKIP IAM permissions boundary (${IAM_PERMISSIONS_BOUNDARY_NAME} not present in this account)"
    fi
  fi

  _eks_check "SSH key" "aws ec2 describe-key-pairs --region ${AWS_REGION} --key-names ${SSH_PUBLIC_KEY}" \
    "Create EC2 key pair ${SSH_PUBLIC_KEY} in ${AWS_REGION}"

  if [[ "${_PROVIDER_FAIL}" -ne 0 ]]; then
    return 1
  fi

  local setup_dir
  setup_dir="$(cd "${WORKSHOP_ROOT}/scripts/setup" && pwd)"
  if [[ -x "${setup_dir}/01b-check-ec2-capacity.sh" ]]; then
    if ! "${setup_dir}/01b-check-ec2-capacity.sh"; then
      return 1
    fi
  fi
  return 0
}
