#!/usr/bin/env bash
# testing/labs/4.2.sh — Lab 4.2: Scale an all-flash cluster (3 -> 4)
#
# Runs on the dedicated all-flash cluster and depends on 4.1 having deployed the
# baseline. Grows the node pool, scales the CR, then re-asserts that the new pod
# got both its block data volumes and its filesystem index mounts.
set -euo pipefail
LAB_ID="4.2"
LAB_CLUSTER="all-flash"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-env.sh"
# shellcheck disable=SC1091
source "${WORKSHOP_ROOT}/scripts/lib/all-flash.sh"

"${LABS}/prepare-lab.sh" 4.2

baseline_phase="$(all_flash_cluster_phase)"
if [[ "${baseline_phase}" != "Completed" ]]; then
  fail_lab "Lab 4.2 needs the 4.1 baseline: AerospikeCluster phase is ${baseline_phase} (run ./testing/run-lab.sh 4.1 first)"
fi

log_info "Baseline before scale:"
kubectl -n "${NAMESPACE}" get pods -l aerospike.com/cr=aerocluster -o wide

log_info "Scaling ${ALL_FLASH_AEROSPIKE_SIZE} -> ${ALL_FLASH_AEROSPIKE_SIZE_SCALED} all-flash pods..."
"${LABS}/scale-all-flash-cluster.sh" "${ALL_FLASH_AEROSPIKE_SIZE_SCALED}"

wait_pods_running "aerospike.com/cr=aerocluster" "${ALL_FLASH_AEROSPIKE_SIZE_SCALED}" 1800
wait_cr_phase Completed 1200

log_info "Post-scale migrate stats (evidence):"
run_asadm "show stat like migrate" || true

"${LABS}/validate-all-flash.sh" "${ALL_FLASH_AEROSPIKE_SIZE_SCALED}" \
  || fail_lab "Lab 4.2 all-flash validation failed after scale"

index_type="$(all_flash_namespace_stat index-type)"
assert_eq "${index_type}" "flash" "namespace index-type after scale" \
  || fail_lab "Lab 4.2 primary index is not on flash after scale"

running="$(all_flash_pods_running)"
assert_eq "${running}" "${ALL_FLASH_AEROSPIKE_SIZE_SCALED}" "final pod count" \
  || fail_lab "Lab 4.2 final pod count mismatch"
assert_eq "$(all_flash_cluster_phase)" "Completed" "final CR phase" \
  || fail_lab "Lab 4.2 final CR phase mismatch"

echo "=== Lab 4.2: PASS ==="
