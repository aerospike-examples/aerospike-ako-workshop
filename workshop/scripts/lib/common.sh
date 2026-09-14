#!/usr/bin/env bash
# Shared helpers for workshop scripts.

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
SCRIPT_DIR="$(cd "$(dirname "${_LIB_SELF}")" && pwd)"
unset _LIB_SELF
WORKSHOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ensure_noninteractive_cli() {
  export AWS_PAGER=""
  export AWS_CLI_AUTO_PROMPT=off
  export KUBE_PAGER=""
}

load_env() {
  # Preserve CLUSTER_NAME when a wrapper targets upgrade-lab (or another cluster)
  # before re-sourcing workshop.env — otherwise shared scripts hit the main cluster.
  local preserve_cluster="${CLUSTER_NAME:-}"
  local env_file="${WORKSHOP_ROOT}/scripts/env/workshop.env"
  if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
  else
    # shellcheck disable=SC1090
    source "${WORKSHOP_ROOT}/scripts/env/workshop.env.example"
    echo "Note: using workshop.env.example — copy to workshop.env for production runs" >&2
  fi
  if [[ -n "${preserve_cluster}" ]]; then
    CLUSTER_NAME="${preserve_cluster}"
  fi
  : "${CLUSTER_NAME:=my-cluster}"
  : "${CLOUD_PROVIDER:=eks}"
  : "${AWS_REGION:=us-east-1}"
  : "${GCP_PROJECT:=}"
  : "${GCP_REGION:=us-central1}"
  : "${NAMESPACE:=aerospike}"
  : "${OPERATOR_NAMESPACE:=operators}"
  : "${OPERATOR_REPO:=aerospike-kubernetes-operator}"
  : "${DEPLOY_PATH:=olm}"
  case "${CLOUD_PROVIDER}" in
    eks|gke) ;;
    *)
      echo "ERROR: CLOUD_PROVIDER must be eks or gke (got: ${CLOUD_PROVIDER})" >&2
      exit 1
      ;;
  esac
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    : "${NODE_PROVISIONING:=nodepool}"
    if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
      echo "ERROR: NODE_PROVISIONING=karpenter is AWS-only; GKE uses NODE_PROVISIONING=nodepool" >&2
      exit 1
    fi
    if [[ "${NODE_PROVISIONING}" != "nodepool" ]]; then
      echo "ERROR: GKE requires NODE_PROVISIONING=nodepool (got: ${NODE_PROVISIONING})" >&2
      exit 1
    fi
    : "${GKE_SYSTEM_NODEGROUP:=default-pool}"
    : "${GKE_SYSTEM_NODE_TYPE:=e2-standard-4}"
    : "${GKE_SYSTEM_NODE_COUNT:=2}"
    : "${GKE_LOCAL_SSD_COUNT:=3}"
    : "${GKE_LOCAL_SSD_COUNT_VERTICAL:=6}"
  else
    : "${NODE_PROVISIONING:=eksctl}"
  fi
  : "${KARPENTER_VERSION:=1.11.2}"
  : "${KARPENTER_NAMESPACE:=karpenter}"
  : "${KARPENTER_CONSOLIDATION:=WhenEmpty}"
  case "${KARPENTER_CONSOLIDATION}" in
    Off|WhenEmpty|WhenEmptyOrUnderutilized) ;;
    *)
      echo "ERROR: KARPENTER_CONSOLIDATION must be Off, WhenEmpty, or WhenEmptyOrUnderutilized (got: ${KARPENTER_CONSOLIDATION})" >&2
      exit 1
      ;;
  esac
  : "${KARPENTER_SYSTEM_NODEGROUP:=ng-system}"
  : "${KARPENTER_SYSTEM_NODE_TYPE:=t3.large}"
  : "${KARPENTER_SYSTEM_NODE_COUNT:=2}"
  : "${KARPENTER_NODEPOOL_NAME:=aerospike-i8g}"
  : "${KARPENTER_NODEPOOL_VERTICAL_NAME:=aerospike-i8g-4xl}"
  : "${KARPENTER_NODECLASS_NAME:=aerospike-i8g}"
  : "${NVME_DISK_LAYOUT:=}"
  : "${NODE_TYPE_VERTICAL:=i8g.4xlarge}"
  : "${NODEGROUP_NAME:=ng-aerospike}"
  : "${NODEGROUP_NAME_VERTICAL:=ng-aerospike-4xl}"
  : "${AWS_ZONES:=us-east-1c,us-east-1d}"
  if [[ -n "${CLUSTER_ZONES:-}" ]]; then
    AWS_ZONES="${CLUSTER_ZONES}"
  else
    CLUSTER_ZONES="${AWS_ZONES}"
  fi
  : "${MIN_NODES_PER_ZONE:=2}"
  : "${UPGRADE_LAB_CLUSTER_NAME:=my-cluster-k8s-upgrade}"
  : "${UPGRADE_LAB_NODEGROUP_NAME:=ng-upgrade-lab}"
  : "${UPGRADE_LAB_K8S_VERSION_START:=1.31}"
  : "${UPGRADE_LAB_K8S_VERSION_TARGET:=1.32}"
  : "${UPGRADE_LAB_NODE_COUNT:=3}"
  : "${UPGRADE_LAB_NODE_TYPE:=i8g.2xlarge}"
  : "${UPGRADE_LAB_AEROSPIKE_SIZE:=3}"
  # All-flash cluster (Section 4 only) — dedicated cluster, opt-in setup step 0.8.
  : "${ALL_FLASH_CLUSTER_NAME:=my-cluster-all-flash}"
  : "${ALL_FLASH_NODEGROUP_NAME:=ng-all-flash}"
  : "${ALL_FLASH_AEROSPIKE_SIZE:=3}"
  : "${ALL_FLASH_AEROSPIKE_SIZE_SCALED:=4}"
  : "${ALL_FLASH_NODE_COUNT:=${ALL_FLASH_AEROSPIKE_SIZE}}"
  : "${ALL_FLASH_NODE_COUNT_SCALED:=${ALL_FLASH_AEROSPIKE_SIZE_SCALED}}"
  # 600 GiB primary index per node: EKS one 640 GiB slice; GKE 16× 40 GiB slices.
  : "${ALL_FLASH_INDEX_MOUNTS_BUDGET:=644245094400}"
  if [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
    : "${ALL_FLASH_NODE_TYPE:=n2-highmem-16}"
    : "${ALL_FLASH_GKE_LOCAL_SSD_COUNT:=16}"
    : "${ALL_FLASH_NVME_DISK_LAYOUT:=${ALL_FLASH_NODE_TYPE}-all-flash}"
  else
    : "${ALL_FLASH_NODE_TYPE:=i8ge.3xlarge}"
    : "${ALL_FLASH_GKE_LOCAL_SSD_COUNT:=16}"
    : "${ALL_FLASH_NVME_DISK_LAYOUT:=${ALL_FLASH_NODE_TYPE}-all-flash}"
  fi
  # Section 4 is not on the Lab 2.2 upgrade ladder; install AKO at this pin.
  : "${ALL_FLASH_AKO_VERSION:=4.5.0}"
  # Lab 4.2 seeds tiny records so the flash index (not the data device) is the story.
  : "${ALL_FLASH_LOAD_RECORDS:=25000000}"
  : "${ALL_FLASH_LOAD_OBJECT_SIZE:=100}"
  # Scripts shared with the main curriculum (06-setup-local-storage.sh) read
  # NODE_TYPE/NVME_DISK_LAYOUT. Apply the all-flash values here rather than in the
  # caller: helpers such as ensure_target_kubecontext re-run load_env, which would
  # re-source workshop.env over a caller-side override.
  if [[ "${CLUSTER_NAME}" == "${ALL_FLASH_CLUSTER_NAME}" ]]; then
    NODE_TYPE="${ALL_FLASH_NODE_TYPE}"
    NVME_DISK_LAYOUT="${ALL_FLASH_NVME_DISK_LAYOUT}"
    AKO_VERSION_START="${ALL_FLASH_AKO_VERSION}"
    MIGRATION_LOAD_RECORDS="${ALL_FLASH_LOAD_RECORDS}"
    MIGRATION_LOAD_OBJECT_SIZE="${ALL_FLASH_LOAD_OBJECT_SIZE}"
  fi
  : "${CLUSTER_STORAGE:=disk}"
  : "${CLUSTER_STORAGE_DIM_LABS:=}"
  : "${CLUSTER_STORAGE_DISK_LABS:=}"
  : "${FEATURES_CONF_PATH:=secrets/features.conf}"
  : "${HELM_OPERATOR_RELEASE:=aerospike-kubernetes-operator}"
  : "${HELM_CLUSTER_RELEASE:=aerocluster}"
  : "${AKO_VERSION_START:=4.2.0}"
  : "${AKO_CLUSTER_CHART_VERSION:=}"
  : "${IAM_PERMISSIONS_BOUNDARY:=auto}"
  : "${IAM_PERMISSIONS_BOUNDARY_NAME:=shared-power-users-boundary}"
  case "${IAM_PERMISSIONS_BOUNDARY}" in
    auto|off|required|arn:aws:iam::*) ;;
    *)
      echo "ERROR: IAM_PERMISSIONS_BOUNDARY must be auto, off, required, or a policy ARN (got: ${IAM_PERMISSIONS_BOUNDARY})" >&2
      exit 1
      ;;
  esac

  IFS=',' read -r NODE_ZONE_A NODE_ZONE_B _ <<< "${CLUSTER_ZONES},,"
  export NODE_ZONE_A NODE_ZONE_B CLUSTER_ZONES AWS_ZONES CLOUD_PROVIDER
  ensure_noninteractive_cli
  # shellcheck source=provider.sh
  source "${SCRIPT_DIR}/provider.sh"
}

aws_account_id() {
  if [[ -z "${WORKSHOP_AWS_ACCOUNT_ID:-}" ]]; then
    WORKSHOP_AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
    export WORKSHOP_AWS_ACCOUNT_ID
  fi
  echo "${WORKSHOP_AWS_ACCOUNT_ID}"
}

# Many organizations only permit IAM role creation when an org-defined permissions boundary
# is attached — for example the shared-power-users-boundary policy published into Aerospike's
# shared accounts, where the shared-account-powerusers-v2 role is denied CreateRole without it.
#
# auto (default) — attach ${IAM_PERMISSIONS_BOUNDARY_NAME} when it exists in this account
# required       — same lookup, but 01-validate-client.sh fails when it cannot be resolved
# off            — never attach (accounts with no boundary requirement)
# <policy ARN>   — attach verbatim
#
# Prints the boundary ARN, or nothing when no boundary applies. Result is cached for the
# process (and exported for subshells) so repeated calls cost no extra AWS API calls.
resolve_iam_boundary_arn() {
  if [[ -n "${IAM_BOUNDARY_RESOLVED:-}" ]]; then
    echo "${IAM_PERMISSIONS_BOUNDARY_ARN:-}"
    return 0
  fi

  local setting="${IAM_PERMISSIONS_BOUNDARY:-auto}" arn="" account="" candidate=""
  case "${setting}" in
    off|"")
      ;;
    auto|required)
      account="$(aws_account_id)"
      if [[ -n "${account}" ]]; then
        candidate="arn:aws:iam::${account}:policy/${IAM_PERMISSIONS_BOUNDARY_NAME}"
        if aws iam get-policy --policy-arn "${candidate}" >/dev/null 2>&1; then
          arn="${candidate}"
        fi
      fi
      ;;
    *)
      # load_env rejects anything else, so this is a literal ARN.
      arn="${setting}"
      ;;
  esac

  IAM_PERMISSIONS_BOUNDARY_ARN="${arn}"
  IAM_BOUNDARY_RESOLVED=1
  export IAM_PERMISSIONS_BOUNDARY_ARN IAM_BOUNDARY_RESOLVED
  echo "${arn}"
}

# Sets IAM_BOUNDARY_CLI_ARGS for `aws iam create-role` (empty when no boundary applies).
set_iam_boundary_cli_args() {
  local arn
  arn="$(resolve_iam_boundary_arn)"
  IAM_BOUNDARY_CLI_ARGS=()
  if [[ -n "${arn}" ]]; then
    IAM_BOUNDARY_CLI_ARGS=(--permissions-boundary "${arn}")
  fi
}

# eksctl honors permissions boundaries only from a ClusterConfig file, never from CLI flags:
# https://docs.aws.amazon.com/eks/latest/eksctl/iam-permissions-boundary.html
# These helpers emit the YAML fragments (nothing when no boundary applies).

# Fragment for ClusterConfig `iam:` — cluster service role (2-space indent).
eksctl_iam_service_role_yaml() {
  local arn
  arn="$(resolve_iam_boundary_arn)"
  [[ -z "${arn}" ]] && return 0
  printf '  serviceRolePermissionsBoundary: "%s"\n' "${arn}"
}

# Fragment for a managedNodeGroups[] entry — instance role ($1 = item key indent).
eksctl_iam_nodegroup_yaml() {
  local indent="${1:-    }" arn
  arn="$(resolve_iam_boundary_arn)"
  [[ -z "${arn}" ]] && return 0
  printf '%siam:\n%s  instanceRolePermissionsBoundary: "%s"\n' "${indent}" "${indent}" "${arn}"
}

# Fragment for ClusterConfig `iam:` — declares the VPC CNI IRSA role that eksctl otherwise
# creates implicitly (and unbounded) whenever withOIDC is true.
eksctl_iam_cni_service_account_yaml() {
  local arn
  arn="$(resolve_iam_boundary_arn)"
  [[ -z "${arn}" ]] && return 0
  cat <<EOF
  serviceAccounts:
    - metadata:
        name: aws-node
        namespace: kube-system
      attachPolicyARNs:
        - arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
      permissionsBoundary: "${arn}"
EOF
}

# Render a ClusterConfig for `eksctl create cluster -f` (control plane only, no nodegroups).
# withOIDC stays false to match the CLI default this replaces — the OIDC provider is
# associated later in step 0.5 (05-setup-ebs-storage.sh).
render_cluster_config() {
  local cluster="$1" region="$2" k8s_version="$3" zones="$4"
  local zone

  cat <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${cluster}
  region: ${region}
  version: "${k8s_version}"
availabilityZones:
EOF
  local -a zone_list=()
  IFS=',' read -ra zone_list <<< "${zones}"
  for zone in "${zone_list[@]}"; do
    [[ -z "${zone}" ]] && continue
    echo "  - ${zone}"
  done
  echo "iam:"
  echo "  withOIDC: false"
  eksctl_iam_service_role_yaml
}

# Render a single managed nodegroup ClusterConfig for `eksctl create nodegroup -f`.
# labels is comma-separated key=value (may be empty).
render_managed_nodegroup_config() {
  local cluster="$1" region="$2" ng_name="$3" node_type="$4" zone="$5"
  local desired="$6" min="$7" max="$8" labels="${9:-}"
  local label

  cat <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${cluster}
  region: ${region}
managedNodeGroups:
  - name: ${ng_name}
    instanceType: ${node_type}
    desiredCapacity: ${desired}
    minSize: ${min}
    maxSize: ${max}
    availabilityZones:
      - ${zone}
    ssh:
      allow: true
      publicKeyName: ${SSH_PUBLIC_KEY}
EOF
  if [[ -n "${labels}" ]]; then
    echo "    labels:"
    local -a label_list=()
    IFS=',' read -ra label_list <<< "${labels}"
    for label in "${label_list[@]}"; do
      [[ -z "${label}" ]] && continue
      printf '      %s: "%s"\n' "${label%%=*}" "${label#*=}"
    done
  fi
  eksctl_iam_nodegroup_yaml "    "
}

# Render a ClusterConfig for `eksctl create iamserviceaccount -f` (one IRSA role).
render_iamserviceaccount_config() {
  local cluster="$1" region="$2" sa_name="$3" sa_namespace="$4" role_name="$5"
  local policy_arn="$6" role_only="${7:-false}"
  local boundary
  boundary="$(resolve_iam_boundary_arn)"

  cat <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${cluster}
  region: ${region}
iam:
  withOIDC: true
  serviceAccounts:
    - metadata:
        name: ${sa_name}
        namespace: ${sa_namespace}
      roleName: ${role_name}
      roleOnly: ${role_only}
      attachPolicyARNs:
        - ${policy_arn}
EOF
  if [[ -n "${boundary}" ]]; then
    printf '      permissionsBoundary: "%s"\n' "${boundary}"
  fi
}

# OLM installs deployment/aerospike-operator-controller-manager; Helm uses release name.
ako_operator_deployment_name() {
  if [[ "${DEPLOY_PATH}" == "helm" ]]; then
    echo "${HELM_OPERATOR_RELEASE}"
  else
    echo "aerospike-operator-controller-manager"
  fi
}

# Parse semver from aerospike-kubernetes-operator.v4.4.1 or chart name suffix.
_ako_version_from_csv_name() {
  local csv_name="$1"
  sed -En 's/^aerospike-kubernetes-operator\.v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' <<< "${csv_name}"
}

# Parse semver from aerospike-kubernetes-operator-4.4.1 Helm chart string.
_ako_version_from_helm_chart() {
  local chart="$1"
  sed -En 's/^aerospike-kubernetes-operator-([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' <<< "${chart}"
}

# Return installed AKO operator version (e.g. 4.4.1), or empty if unknown.
installed_ako_version() {
  local version="" chart="" csv="" installed=""
  if [[ "${DEPLOY_PATH:-olm}" == "helm" ]]; then
    if command -v helm >/dev/null 2>&1; then
      if command -v jq >/dev/null 2>&1; then
        chart="$(helm list -n "${OPERATOR_NAMESPACE}" -o json 2>/dev/null \
          | jq -r --arg n "${HELM_OPERATOR_RELEASE}" '.[] | select(.name==$n) | .chart // empty' 2>/dev/null || true)"
      else
        chart="$(helm list -n "${OPERATOR_NAMESPACE}" 2>/dev/null \
          | awk -v rel="${HELM_OPERATOR_RELEASE}" '$1 == rel { print $NF }' | head -1)"
      fi
      version="$(_ako_version_from_helm_chart "${chart}")"
    fi
  else
    installed="$(kubectl get subscription aerospike-kubernetes-operator -n "${OPERATOR_NAMESPACE}" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    version="$(_ako_version_from_csv_name "${installed}")"
    if [[ -z "${version}" && -n "${installed}" ]]; then
      version="$(kubectl get csv "${installed}" -n "${OPERATOR_NAMESPACE}" \
        -o jsonpath='{.spec.version}' 2>/dev/null || true)"
    fi
  fi
  echo "${version}"
}

# aerospike-cluster chart --version: override, then installed operator, then install pin.
resolve_cluster_helm_chart_version() {
  if [[ -n "${AKO_CLUSTER_CHART_VERSION:-}" ]]; then
    echo "${AKO_CLUSTER_CHART_VERSION}"
    return 0
  fi
  local installed
  installed="$(installed_ako_version)"
  if [[ -n "${installed}" ]]; then
    echo "${installed}"
    return 0
  fi
  echo "Note: could not detect installed AKO — using AKO_VERSION_START (${AKO_VERSION_START}) for cluster chart" >&2
  echo "${AKO_VERSION_START}"
}

# Fail if installed AKO is below minimum (semver compare via sort -V).
validate_ako_min_version() {
  local min_version="$1" installed=""
  installed="$(installed_ako_version)"
  if [[ -z "${installed}" ]]; then
    echo "ERROR: could not detect installed AKO version (complete Lab 0.3 / 2.2 first)" >&2
    return 1
  fi
  if [[ "$(printf '%s\n' "${min_version}" "${installed}" | sort -V | head -1)" == "${min_version}" ]]; then
    echo "OK  AKO ${installed} (required >= ${min_version})"
    return 0
  fi
  echo "ERROR: AKO ${installed} is below required ${min_version} — complete Lab 2.2 upgrade ladder first" >&2
  return 1
}

features_conf_path() {
  load_env
  local path="${FEATURES_CONF_PATH}"
  if [[ "${path}" != /* ]]; then
    path="${WORKSHOP_ROOT}/${path}"
  fi
  echo "${path}"
}

vendor_storage_dir() {
  echo "${WORKSHOP_ROOT}/vendor/storage"
}

operator_repo_path() {
  load_env
  if [[ -d "${WORKSHOP_ROOT}/.vendor/${OPERATOR_REPO}" ]]; then
    echo "${WORKSHOP_ROOT}/.vendor/${OPERATOR_REPO}"
  else
    echo "${WORKSHOP_ROOT}/.vendor/${OPERATOR_REPO}"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

cluster_exists() {
  provider_cluster_exists "$1"
}

workshop_kubeconfig_dir() {
  load_env
  local dir="${WORKSHOP_ROOT}/.kube"
  mkdir -p "${dir}"
  echo "${dir}"
}

kubeconfig_path_for_cluster() {
  local cluster_name="$1"
  echo "$(workshop_kubeconfig_dir)/${cluster_name}.yaml"
}

default_kubeconfig_path() {
  echo "${KUBECONFIG:-${HOME}/.kube/config}"
}

apply_workshop_kubeconfig() {
  if [[ -n "${WORKSHOP_KUBECONFIG:-}" ]]; then
    mkdir -p "$(dirname "${WORKSHOP_KUBECONFIG}")"
    export KUBECONFIG="${WORKSHOP_KUBECONFIG}"
  fi
}

merge_kubeconfig_into_default() {
  local src="$1"
  local dest
  dest="$(default_kubeconfig_path)"

  if [[ ! -f "${src}" ]]; then
    return 0
  fi

  require_cmd kubectl
  mkdir -p "$(dirname "${dest}")"
  if [[ ! -f "${dest}" ]]; then
    cp "${src}" "${dest}"
    echo "Merged kubeconfig: ${src} → ${dest}"
    return 0
  fi

  local merged="${dest}.merged.$$"
  KUBECONFIG="${dest}:${src}" kubectl config view --flatten > "${merged}"
  mv "${merged}" "${dest}"
  echo "Merged kubeconfig: ${src} → ${dest}"
}

cleanup_workshop_kubeconfig_files() {
  local dir
  dir="$(workshop_kubeconfig_dir 2>/dev/null || true)"
  if [[ -n "${dir}" && -d "${dir}" ]]; then
    rm -f "${dir}"/*.yaml 2>/dev/null || true
    echo "Removed isolated kubeconfig files under ${dir}"
  fi
}

with_kubeconfig() {
  local kc="$1"
  shift
  (
    export KUBECONFIG="${kc}"
    "$@"
  )
}

run_with_log_prefix() {
  local prefix="$1"
  shift
  "$@" 2>&1 | sed "s/^/${prefix} /"
}

current_kube_cluster() {
  kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || true
}

current_kube_context() {
  kubectl config current-context 2>/dev/null || true
}

ensure_kubecontext() {
  local cluster_name="$1"
  require_cmd kubectl

  if ! cluster_exists "${cluster_name}"; then
    echo "ERROR: $(provider_display_name) cluster '${cluster_name}' not found" >&2
    echo "Create it first or check UPGRADE_LAB_CLUSTER_NAME / CLUSTER_NAME in workshop.env" >&2
    exit 1
  fi

  provider_update_kubeconfig "${cluster_name}"
  echo "kubectl context: $(current_kube_context) (cluster: $(current_kube_cluster))"
}

assert_kubecontext() {
  local expected_cluster="$1"
  local current_cluster
  current_cluster="$(current_kube_cluster)"

  if [[ "${current_cluster}" != *"${expected_cluster}"* ]]; then
    echo "ERROR: kubectl is not targeting '${expected_cluster}' (current cluster: ${current_cluster:-unknown})" >&2
    echo "Run: $(provider_kubeconfig_hint "${expected_cluster}")" >&2
    exit 1
  fi
}

ensure_main_kubecontext() {
  load_env
  ensure_kubecontext "${CLUSTER_NAME}"
  assert_kubecontext "${CLUSTER_NAME}"
}

ensure_upgrade_lab_kubecontext() {
  load_env
  ensure_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
  assert_kubecontext "${UPGRADE_LAB_CLUSTER_NAME}"
}

ensure_all_flash_kubecontext() {
  load_env
  ensure_kubecontext "${ALL_FLASH_CLUSTER_NAME}"
  assert_kubecontext "${ALL_FLASH_CLUSTER_NAME}"
}

ensure_target_kubecontext() {
  load_env
  if [[ "${CLUSTER_NAME}" == "${UPGRADE_LAB_CLUSTER_NAME}" ]]; then
    ensure_upgrade_lab_kubecontext
  elif [[ "${CLUSTER_NAME}" == "${ALL_FLASH_CLUSTER_NAME}" ]]; then
    ensure_all_flash_kubecontext
  else
    ensure_main_kubecontext
  fi
}

delete_kubecontext_for_cluster() {
  local cluster_name="$1"
  local ctx
  while IFS= read -r ctx; do
    [[ -z "${ctx}" ]] && continue
    if [[ "${ctx}" == *"${cluster_name}"* ]]; then
      kubectl config delete-context "${ctx}" >/dev/null 2>&1 || true
      echo "Removed kubeconfig context: ${ctx}"
    fi
  done < <(kubectl config get-contexts -o name 2>/dev/null || true)
}
