# Lab 0.6 — Secrets and Validate Platform

| Field | Value |
|-------|-------|
| Lab ID | `0.6` |
| Section | Environment Setup |
| Cluster | `${CLUSTER_NAME}` (default `my-cluster`) |
| Aerospike cluster | — (none yet) |
| Duration | ~10 min |
| Validation status | `draft` |

## Takeaway

Secrets are deployed and the platform is validated — **no AerospikeCluster yet**; labs deploy their own baseline.

## Prerequisites

- Lab 0.5 complete
- `secrets/features.conf` exists

## Steps

1. Deploy secrets:

   ```bash
   ./scripts/setup/07-deploy-secrets.sh
   ```

   **Expected:** Four secrets in the `${NAMESPACE}` (default `aerospike`) namespace:

   | Secret | Contents |
   |--------|----------|
   | `aerospike-secret` | `features.conf` feature-key file |
   | `auth-secret` | password `admin123` |
   | `auth-app-secret` | password `app123` |
   | `auth-exporter-secret` | password `exporter123` |

   The script creates the namespace if needed and copies `FEATURES_CONF_PATH` into `secrets/features.conf` when it is sourced from elsewhere.

2. Run environment validation:

   ```bash
   ./scripts/setup/08-validate-environment.sh
   ```

   **Expected:** Exit code 0; message "Environment ready for lab sections." Validation covers, in order:

   - Karpenter controller Ready (only when `NODE_PROVISIONING=karpenter`)
   - `${NODE_COUNT}` Ready nodes labelled `workshop.aerospike.com/node-pool=baseline`, distributed across more than one AZ
   - `nvme-bootstrap` DaemonSet present and `local-volume-node-cleanup-controller` Ready
   - local-ssd PV count for the baseline pool — restarts the local-volume-provisioner only if the count is short
   - operator health: CSV `Succeeded` (`DEPLOY_PATH=olm`) or Helm release present (`helm`)
   - StorageClasses `ssd` and `local-ssd`
   - akoctl krew plugin installed
   - secrets `aerospike-secret`, `auth-secret`, `auth-app-secret` (it does not check `auth-exporter-secret`)
   - no `AerospikeCluster` in the namespace — a leftover cluster is a `WARN`, not a failure

## Verify (pass/fail)

1. Secrets exist:

   ```bash
   kubectl -n aerospike get secrets
   ```

2. No cluster deployed yet on the **main** cluster:

   ```bash
   kubectl -n aerospike get aerospikecluster
   ```

   **Pass:** No resources (or empty list). Step 0.7 does deploy `aerocluster`, but only on the separate upgrade-lab cluster.

3. Operator healthy (from 0.3).

4. Workload nodes Ready (from step 0.2-nodes):

   ```bash
   kubectl get nodes -L workshop.aerospike.com/node-pool,node.kubernetes.io/instance-type
   ```

   **Pass:** `${NODE_COUNT}`× `${NODE_TYPE}` nodes Ready.

5. Local-ssd PVs discovered:

   ```bash
   kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,STATUS:.status.phase --no-headers | awk '$2 == "local-ssd"'
   ```

   **Pass:** PV count matches instance-type layout × `${NODE_COUNT}` (e.g. EKS: 12 PVs for 4× i8g.2xlarge; GKE: 12 PVs for 4× n2-highmem-8 — 3 local NVMe × 4 nodes).

## Observe

- `aerospike-secret` contains feature-key file for Enterprise
- Section 1/2 labs call `deploy-cluster.sh` (default storage), `deploy-dim-cluster.sh`, or rack deploy scripts

## Teardown / handoff

**Main cluster ready.** The script closes with `Run ./scripts/labs/prepare-lab.sh 1.1 to start Section 1 (full reset + re-ensure nodes)`.

- Unless you passed `--skip-upgrade-lab`, finish [Lab 0.7 — upgrade-lab cluster](07-upgrade-lab-cluster.md) next
- Then proceed to [Section 1 — Scaling & Capacity](../01-scaling-and-capacity/README.md)

## Workshop artifacts

- No AerospikeCluster manifest in this step — secrets via [`scripts/setup/07-deploy-secrets.sh`](../../scripts/setup/07-deploy-secrets.sh)
- Baseline cluster files used in Section 1 (for reference) — selected by `CLUSTER_STORAGE` (`disk` default, `dim` for in-memory):
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)

## References

- [`scripts/setup/07-deploy-secrets.sh`](../../scripts/setup/07-deploy-secrets.sh)
