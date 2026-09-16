#!/usr/bin/env bash
# testing/labs/4.1.sh — Lab 4.1: Deploy an all-flash cluster
#
# Runs on the dedicated all-flash cluster (${ALL_FLASH_CLUSTER_NAME}), not the
# main curriculum cluster: prepare -> deploy (Path A or B) -> assert CR phase,
# pod count, block + filesystem PVCs, and asinfo index-type=flash.
set -euo pipefail
LAB_ID="4.1"
LAB_CLUSTER="all-flash"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-env.sh"
# shellcheck disable=SC1091
source "${WORKSHOP_ROOT}/scripts/lib/all-flash.sh"

"${LABS}/prepare-lab.sh" 4.1

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  "${LABS}/deploy-all-flash-cluster-helm.sh"
else
  "${LABS}/deploy-all-flash-cluster.sh"
fi

wait_pods_running "aerospike.com/cr=aerocluster" "${ALL_FLASH_AEROSPIKE_SIZE}" 1200
wait_cr_phase Completed 900

"${LABS}/validate-all-flash.sh" "${ALL_FLASH_AEROSPIKE_SIZE}" \
  || fail_lab "Lab 4.1 all-flash validation failed"

log_info "Index-on-flash evidence:"
all_flash_asinfo "namespace/${ALL_FLASH_AEROSPIKE_NAMESPACE}" | tr ';' '\n' | grep -E '^index-type|^index_flash' || true

index_type="$(all_flash_namespace_stat index-type)"
assert_eq "${index_type}" "flash" "namespace index-type" \
  || fail_lab "Lab 4.1 primary index is not on flash"

running="$(all_flash_pods_running)"
assert_eq "${running}" "${ALL_FLASH_AEROSPIKE_SIZE}" "final pod count" \
  || fail_lab "Lab 4.1 final pod count mismatch"
assert_eq "$(all_flash_cluster_phase)" "Completed" "final CR phase" \
  || fail_lab "Lab 4.1 final CR phase mismatch"

echo "=== Lab 4.1: PASS ==="
