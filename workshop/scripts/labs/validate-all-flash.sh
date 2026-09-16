#!/usr/bin/env bash
# Verify the all-flash cluster really runs its primary index on flash (Labs 4.1 / 4.2).
#
# Usage: ./scripts/labs/validate-all-flash.sh [expected-pod-count]
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/all-flash.sh"
load_env
export CLUSTER_NAME="${ALL_FLASH_CLUSTER_NAME}"
ensure_all_flash_kubecontext
require_cmd kubectl

EXPECTED_PODS="${1:-${ALL_FLASH_AEROSPIKE_SIZE}}"
fail=0

echo "=== All-flash validation (${ALL_FLASH_CLUSTER_NAME}, expecting ${EXPECTED_PODS} pods) ==="

phase="$(all_flash_cluster_phase)"
running="$(all_flash_pods_running)"
kubectl -n "${NAMESPACE}" get pods -l aerospike.com/cr=aerocluster -o wide

if [[ "${phase}" == "Completed" ]]; then
  echo "OK  AerospikeCluster phase Completed"
else
  echo "FAIL AerospikeCluster phase ${phase} (expected Completed)" >&2
  fail=1
fi

if [[ "${running:-0}" -ge "${EXPECTED_PODS}" ]]; then
  echo "OK  ${running}/${EXPECTED_PODS} Aerospike pods Running"
else
  echo "FAIL ${running}/${EXPECTED_PODS} Aerospike pods Running" >&2
  fail=1
fi

cr_index_type="$(kubectl -n "${NAMESPACE}" get aerospikecluster aerocluster \
  -o jsonpath='{.spec.aerospikeConfig.namespaces[0].index-type.type}' 2>/dev/null || echo missing)"
if [[ "${cr_index_type}" == "flash" ]]; then
  echo "OK  CR index-type.type=flash"
else
  echo "FAIL CR index-type.type=${cr_index_type} (expected flash)" >&2
  fail=1
fi

all_flash_validate_pvcs "${EXPECTED_PODS}" || fail=1
all_flash_validate_index_flash || fail=1

cluster_size="$(all_flash_service_stat cluster_size)"
if [[ "${cluster_size}" == "${EXPECTED_PODS}" ]]; then
  echo "OK  asinfo cluster_size=${cluster_size}"
else
  echo "FAIL asinfo cluster_size=${cluster_size:-unknown} (expected ${EXPECTED_PODS})" >&2
  fail=1
fi

if [[ "${fail}" -eq 0 ]]; then
  echo "All-flash validation: PASS"
else
  echo "All-flash validation: FAIL" >&2
  exit 1
fi
