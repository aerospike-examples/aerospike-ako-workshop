#!/usr/bin/env bash
# testing/labs/1.2.sh — Lab 1.2: Rack Awareness, Vertical Scaling & Rack Revision
#
# Non-optional path: deploy rack v1 baseline -> assert baseline placement ->
# add vertical node pool -> apply v2 revision (nodeSelector+mem+storage bump)
# -> assert vertical placement, 2 local-ssd PVCs/pod, CR Completed.
set -euo pipefail
LAB_ID="1.2"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-env.sh"

"${LABS}/prepare-lab.sh" 1.2

if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
  # shellcheck disable=SC1091
  source "${WORKSHOP_ROOT}/scripts/lib/zone-check.sh"
  assert_multi_az_nodes fail "${NODE_TYPE}" || fail_lab "Lab 1.2: baseline pool multi-AZ distribution mismatch after prepare"
  log_pass "baseline pool multi-AZ distribution OK (${NODE_TYPE})"
fi

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  "${LABS}/deploy-rack-cluster-helm.sh"
else
  "${LABS}/deploy-rack-cluster.sh"
fi

wait_pods_running "aerospike.com/cr=aerocluster" 4 600
wait_cr_phase Completed 600
"${LABS}/lab-nodes.sh" 1.2 validate

v1_pod="$(first_pod_matching '\-v1\-')"
assert_not_empty "${v1_pod}" "baseline (v1) pod found"
selector="$(pod_field "${v1_pod}" '{.spec.nodeSelector.workshop\.aerospike\.com/node-pool}')"
mem="$(pod_field "${v1_pod}" '{.spec.containers[?(@.name=="aerospike-server")].resources.limits.memory}')"
assert_eq "${selector}" "baseline" "Phase 1 nodeSelector (${v1_pod})" || fail_lab "Lab 1.2 Phase 1 nodeSelector mismatch"
assert_eq "${mem}" "54Gi" "Phase 1 memory limit (${v1_pod})" || fail_lab "Lab 1.2 Phase 1 memory mismatch"

"${LABS}/lab-nodes.sh" 1.2 ensure --vertical
"${LABS}/lab-nodes.sh" 1.2 validate --vertical

if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
  assert_multi_az_nodes fail "${NODE_TYPE_VERTICAL}" || fail_lab "Lab 1.2: vertical pool multi-AZ distribution mismatch"
  log_pass "vertical pool multi-AZ distribution OK (${NODE_TYPE_VERTICAL})"
fi

if [[ "${DEPLOY_PATH}" == "helm" ]]; then
  "${LABS}/deploy-rack-cluster-v2-revision-helm.sh"
else
  "${LABS}/deploy-rack-cluster-v2-revision.sh"
fi

wait_pods_running "aerospike.com/cr=aerocluster" 4 1200
wait_cr_phase Completed 1200

v2_pod="$(first_pod_matching '\-v2\-')"
assert_not_empty "${v2_pod}" "vertical (v2) pod found"
selector2="$(pod_field "${v2_pod}" '{.spec.nodeSelector.workshop\.aerospike\.com/node-pool}')"
mem2="$(pod_field "${v2_pod}" '{.spec.containers[?(@.name=="aerospike-server")].resources.limits.memory}')"
assert_eq "${selector2}" "vertical" "Phase 3 nodeSelector (${v2_pod})" || fail_lab "Lab 1.2 Phase 3 nodeSelector mismatch"
assert_eq "${mem2}" "115Gi" "Phase 3 memory limit (${v2_pod})" || fail_lab "Lab 1.2 Phase 3 memory mismatch"

bound_local_ssd="$(count_bound_local_ssd_pvcs)"
if [[ "${bound_local_ssd}" -ge 8 ]]; then
  log_pass "local-ssd PVCs bound: ${bound_local_ssd} (>= 8, 2 per pod x 4 pods)"
else
  fail_lab "expected >= 8 bound local-ssd PVCs (2/pod x 4 pods), got ${bound_local_ssd}"
fi

"${LABS}/lab-nodes.sh" 1.2 validate --vertical
assert_eq "$(cr_phase)" "Completed" "final CR phase" || fail_lab "Lab 1.2 final CR phase mismatch"

echo "=== Lab 1.2: PASS ==="
