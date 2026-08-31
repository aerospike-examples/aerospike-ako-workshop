#!/usr/bin/env bash
# Block storage class named `ssd` (EBS CSI on EKS; GCE PD CSI on GKE).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env
ensure_main_kubecontext

provider_setup_block_storage "${CLUSTER_NAME}"
