#!/usr/bin/env bash
# testing/labs/2.5.sh — Lab 2.5: K8s Worker Node Maintenance
#
# Non-optional path only: enable safe pod eviction -> seed data -> capture the
# node hosting aerocluster-0-0 -> drain (best-effort first attempt, since the
# webhook may or may not catch active migration depending on timing) -> wait
# for migration to settle -> retry drain (must succeed) -> terminate the node
# (eksctl: kubectl delete node + EC2 terminate; GKE: kubectl delete node +
# gcloud compute instances delete; karpenter: delete nodeclaim)
# -> wait for PVC cleanup + pod reschedule + CR Completed.
#
# Excluded (optional/instructor-led): eksctl same-AZ pre-scale, node-blocklist
# alternate path, "force visible drain block" quiesce demo, Karpenter
# do-not-disrupt add-on.
set -euo pipefail
LAB_ID="2.5"
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../lib/lab-env.sh"

enable_safe_pod_eviction() {
  log_info "Enabling safe pod eviction (DEPLOY_PATH=${DEPLOY_PATH})..."
  if [[ "${DEPLOY_PATH}" == "helm" ]]; then
    ensure_helm_repo
    helm upgrade "${HELM_OPERATOR_RELEASE}" aerospike/aerospike-kubernetes-operator \
      --namespace "${OPERATOR_NAMESPACE}" \
      --reuse-values \
      -f "${WORKSHOP_ROOT}/helm/operator-values.yaml"
  else
    kubectl -n "${OPERATOR_NAMESPACE}" patch subscription aerospike-kubernetes-operator \
      --type='merge' \
      -p '{"spec":{"config":{"env":[{"name":"ENABLE_SAFE_POD_EVICTION","value":"true"}]}}}'
  fi
  kubectl -n "${OPERATOR_NAMESPACE}" rollout status "deployment/$(ako_operator_deployment_name)" --timeout=180s
}

verify_safe_pod_eviction() {
  "${LABS}/verify-safe-pod-eviction.sh"
}

enable_safe_pod_eviction
verify_safe_pod_eviction

"${LABS}/prepare-lab.sh" 2.5 --load-data

wait_pods_running "aerospike.com/cr=aerocluster" 3 600
wait_cr_phase Completed 600
assert_contains "$(cr_image)" "8.1.2" "maintenance baseline DB image" || fail_lab "Lab 2.5: expected 8.1.2.x maintenance baseline image"

log_info "Data presence evidence (namespace test, app/app123):"
run_asadm "info"

NODE="$(pod_node aerocluster-0-0)"
assert_not_empty "${NODE}" "maintenance target node captured" || fail_lab "Lab 2.5: could not determine node hosting aerocluster-0-0"
log_info "Maintenance target node (aerocluster-0-0): ${NODE}"

log_info "First drain attempt (best-effort — webhook may deny while migration is active)..."
kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=120s || \
  log_warn "first drain did not complete within 120s (expected if migration is active or already finished quickly)"

wait_cr_phase Completed 900
log_info "Migrate stats after settling (evidence):"
run_asadm "show stat like migrate"

log_info "Retry drain after migration settled (must succeed)..."
if ! kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=300s; then
  fail_lab "Lab 2.5: retry drain failed after migration settled"
fi

unschedulable="$(kubectl get node "${NODE}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)"
assert_eq "${unschedulable}" "true" "node ${NODE} cordoned" || fail_lab "Lab 2.5: node not cordoned after drain"

if [[ "${NODE_PROVISIONING}" == "karpenter" ]]; then
  log_info "Karpenter path: deleting NodeClaim for ${NODE}..."
  claim="$(kubectl get nodeclaims -o jsonpath="{.items[?(@.status.nodeName==\"${NODE}\")].metadata.name}" 2>/dev/null)"
  assert_not_empty "${claim}" "NodeClaim for ${NODE} found" || fail_lab "Lab 2.5: could not find NodeClaim for ${NODE}"
  kubectl delete nodeclaim "${claim}"
elif [[ "${CLOUD_PROVIDER}" == "gke" ]]; then
  log_info "GKE path: deleting Compute Engine VM backing ${NODE}..."
  instance_id="$(kubectl get node "${NODE}" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||')"
  zone="$(kubectl get node "${NODE}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)"
  assert_not_empty "${instance_id}" "GCE instance name for ${NODE}" || fail_lab "Lab 2.5: could not resolve GCE instance name for ${NODE}"
  assert_not_empty "${zone}" "GCE zone for ${NODE}" || fail_lab "Lab 2.5: could not resolve topology zone for ${NODE}"
  kubectl delete node "${NODE}"
  gcloud compute instances delete "${instance_id}" --zone="${zone}" --project="${GCP_PROJECT}" --quiet
else
  log_info "eksctl path: terminating EC2 instance backing ${NODE}..."
  instance_id="$(kubectl get node "${NODE}" -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*/||')"
  assert_not_empty "${instance_id}" "EC2 instance ID for ${NODE}" || fail_lab "Lab 2.5: could not resolve EC2 instance ID for ${NODE}"
  kubectl delete node "${NODE}"
  aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids "${instance_id}"
fi

wait_node_gone "${NODE}" 300
wait_pod_moved_off_node aerocluster-0-0 "${NODE}" 900
wait_pvc_cleanup "${NODE}" 180 || true
wait_cr_phase Completed 300

wait_pods_running "aerospike.com/cr=aerocluster" 3 300
kubectl get nodes -o wide
assert_eq "$(cr_phase)" "Completed" "final CR phase" || fail_lab "Lab 2.5 final CR phase mismatch"

echo "=== Lab 2.5: PASS ==="
