#!/usr/bin/env bash
# Switch or display kubectl context for training clusters.
#
# Usage:
#   ./scripts/lib/kubecontext.sh main
#   ./scripts/lib/kubecontext.sh upgrade-lab
#   ./scripts/lib/kubecontext.sh all-flash
#   ./scripts/lib/kubecontext.sh show
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_env

usage() {
  cat <<EOF
Usage: $(basename "$0") <main|upgrade-lab|all-flash|show>

Switch kubectl to the main training cluster, the Lab 2.6 upgrade-lab cluster,
or the Section 4 all-flash cluster.

  main          ${CLUSTER_NAME}
  upgrade-lab   ${UPGRADE_LAB_CLUSTER_NAME}
  all-flash     ${ALL_FLASH_CLUSTER_NAME}
  show          Print current context and cluster (no switch)
EOF
}

case "${1:-}" in
  main)
    ensure_main_kubecontext
    ;;
  upgrade-lab)
    ensure_upgrade_lab_kubecontext
    ;;
  all-flash)
    ensure_all_flash_kubecontext
    ;;
  show)
    require_cmd kubectl
    echo "context: $(current_kube_context)"
    echo "cluster: $(current_kube_cluster)"
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
esac
