#!/usr/bin/env bash
# Load records into the cluster (asbench insert).
#
# Usage:
#   ./scripts/labs/load-data.sh [--upgrade-lab] [--all-flash] [--tls] [--pki]
#
# Defaults: 5M × 1 KB on the main (or upgrade-lab) cluster; 25M × 100 B on all-flash.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/asbench-tls.sh"
load_env
require_cmd kubectl

UPGRADE_LAB=false
ALL_FLASH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-lab) UPGRADE_LAB=true ;;
    --all-flash) ALL_FLASH=true ;;
    --tls) AEROSPIKE_TLS_MODE=tls ;;
    --pki) AEROSPIKE_TLS_MODE=pki ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--upgrade-lab] [--all-flash] [--tls] [--pki]

Load records into the Aerospike cluster via asbench insert.
  --upgrade-lab   Target the Lab 2.6 upgrade-lab cluster
  --all-flash     Target the Section 4 cluster (25M × 100 B records by default)
  --tls / --pki   Use service TLS (4333) with password or PKI auth
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "${UPGRADE_LAB}" == true && "${ALL_FLASH}" == true ]]; then
  echo "ERROR: --upgrade-lab and --all-flash are mutually exclusive" >&2
  exit 1
fi

# Target the all-flash cluster through CLUSTER_NAME rather than local variables:
# load_env swaps in the ALL_FLASH_LOAD_* sizes for it, and helpers below re-run
# load_env, which would re-source workshop.env over any override set here.
if [[ "${ALL_FLASH}" == true ]]; then
  export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
  load_env
fi

: "${MIGRATION_LOAD_NAMESPACE:=test}"
: "${MIGRATION_LOAD_RECORDS:=5000000}"
: "${MIGRATION_LOAD_OBJECT_SIZE:=1024}"
: "${MIGRATION_LOAD_THREADS:=64}"
: "${MIGRATION_LOAD_DURATION:=0}"
: "${AEROSPIKE_AUTH_USER:=app}"
: "${AEROSPIKE_AUTH_PASSWORD:=app123}"

ensure_target_kubecontext() {
  if [[ "${ALL_FLASH}" == true ]]; then
    ensure_all_flash_kubecontext
  elif [[ "${UPGRADE_LAB}" == true ]]; then
    ensure_upgrade_lab_kubecontext
  else
    ensure_main_kubecontext
  fi
}

validate_cluster_exists() {
  if kubectl -n "${NAMESPACE}" get aerospikecluster aerocluster >/dev/null 2>&1; then
    echo "OK  AerospikeCluster aerocluster exists"
    return 0
  fi
  echo "ERROR: AerospikeCluster aerocluster not found in namespace ${NAMESPACE}" >&2
  exit 1
}

run_asbench_pod() {
  local host tls_args=() auth_args=() job_name="asbench-load-$$"
  host="$(asbench_host_arg)"
  read_args_into tls_args < <(build_asbench_tls_args)
  read_args_into auth_args < <(asbench_auth_args)

  local job_file
  job_file="$(mktemp)"
  trap 'rm -f "${job_file}"' RETURN

  {
    cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
EOF
    tls_job_volumes_yaml
    cat <<EOF
      containers:
        - name: asbench
          image: aerospike/aerospike-tools:latest
EOF
    tls_job_volume_mounts_yaml
    cat <<EOF
          command:
            - asbench
            - -h
            - ${host}
EOF
    for arg in "${auth_args[@]+"${auth_args[@]}"}"; do printf '            - "%s"\n' "${arg}"; done
    cat <<EOF
            - -n
            - ${MIGRATION_LOAD_NAMESPACE}
            - -k
            - "${MIGRATION_LOAD_RECORDS}"
            - -o
            - S${MIGRATION_LOAD_OBJECT_SIZE}
            - -w
            - I
            - -z
            - "${MIGRATION_LOAD_THREADS}"
            # - --batch-write-size
            # - "50"
            - --debug
EOF
    if [[ "${MIGRATION_LOAD_DURATION}" -gt 0 ]]; then
      printf '            - -T\n            - "%s"\n' "${MIGRATION_LOAD_DURATION}"
    fi
    for arg in "${tls_args[@]+"${tls_args[@]}"}"; do printf '            - "%s"\n' "${arg}"; done
  } > "${job_file}"

  kubectl apply -f "${job_file}"
  kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${job_name}" --timeout=3600s
  kubectl -n "${NAMESPACE}" logs "job/${job_name}"
  kubectl -n "${NAMESPACE}" delete job "${job_name}" --ignore-not-found
}

print_namespace_stats() {
  echo "=== Namespace ${MIGRATION_LOAD_NAMESPACE} stats ==="
  local host tls_args=() auth_args=()
  host="$(asbench_host_arg)"
  read_args_into tls_args < <(build_asbench_tls_args)
  read_args_into auth_args < <(asbench_auth_args)
  kubectl run "aerospike-tool-stats-$$" -n "${NAMESPACE}" --restart=Never \
    --image=aerospike/aerospike-tools:latest --rm -i -- \
    asadm -h "${host}" "${auth_args[@]+"${auth_args[@]}"}" "${tls_args[@]+"${tls_args[@]}"}" -e "info" 2>/dev/null || true
}

ensure_target_kubecontext

echo "=== Load data (TLS mode: ${AEROSPIKE_TLS_MODE}) ==="
validate_cluster_exists
echo "Loading ${MIGRATION_LOAD_RECORDS} records into namespace ${MIGRATION_LOAD_NAMESPACE}..."
run_asbench_pod
print_namespace_stats
echo "=== Data load complete ==="
