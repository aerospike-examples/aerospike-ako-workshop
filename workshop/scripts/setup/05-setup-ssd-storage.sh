#!/usr/bin/env bash
# StorageClass `ssd` — network-attached disk for the Aerospike workdir
# (EBS CSI on EKS; GCE PD CSI on GKE).
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
load_env
ensure_main_kubecontext

provider_setup_ssd_storage "${CLUSTER_NAME}"
