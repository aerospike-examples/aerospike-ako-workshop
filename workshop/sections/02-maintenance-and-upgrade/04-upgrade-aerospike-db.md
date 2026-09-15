# Lab 2.4 — Upgrade Aerospike DB

| Field | Value |
|-------|-------|
| Lab ID | `2.4` |
| Section | Maintenance & Upgrade |
| Cluster | `my-cluster` |
| AKO min version | `4.5.0` |
| Aerospike baseline | 3-node on **8.1.0.x** (device storage default; same as `deploy-cluster.sh`) |
| Deploy path | both |
| Duration | ~20 min |
| Validation status | `draft` |
| Official docs | [Upgrade Aerospike](https://aerospike.com/docs/kubernetes/install/deploy/upgrade-aerospike/) |

## Takeaway

Aerospike DB upgrade = change `spec.image`; AKO performs a **rolling restart** of pods one node at a time.

## Prerequisites

- Lab 2.3 complete (on-demand operations on **8.1.0.x**)
- Lab 2.2 complete through **4.5.0** (required for **8.1.2.x** support)
- Cluster Running on **8.1.0.x** with no `spec.operations` on the CR

**Compatibility:** AKO 4.2.0–4.4.1 supports Aerospike up to **8.1.0.x** only. AKO **4.5.0** adds support for **8.1.2.x** — run this lab only after the 4.5.0 upgrade step in Lab 2.2. See the [AKO / Aerospike compatibility table](../../README.md#ako--aerospike-compatibility).

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.image}{"\n"}{.status.phase}{"\n"}'
kubectl -n aerospike get pods
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.operations}{"\n"}'
```

**Expected:** Image `aerospike/aerospike-server-enterprise:8.1.0.0` (or current 8.1.0.x patch); phase `Completed`; 3/3 pods `Running`; empty `spec.operations`.

If the cluster image or config does not match, redeploy the baseline first:

```bash
./scripts/labs/deploy-cluster.sh           # Path A
./scripts/labs/deploy-cluster-helm.sh      # Path B
```

## Phase 0 — Prepare lab

After **Lab 2.3**, the CR may still carry `spec.operations`. AKO cannot apply an image change together with an operations change — reset to a clean baseline before upgrading.

If you ran **[Lab 1.4](../01-scaling-and-capacity/04-replication-factor.md)**, the cluster may be at RF=3. If Lab 2.4 was attempted before, the image may already be on **8.1.2.x**. Reset to a clean baseline (**8.1.0.x**, RF=2, no operations):

```bash
./scripts/labs/prepare-lab.sh 2.4
```

**Expected:** Prior `aerocluster` deleted; fresh 3-node cluster on **8.1.0.x**; phase `Completed`.

Use `./scripts/labs/prepare-lab.sh 2.4 --skip-reset` only if the baseline is already on **8.1.0.x** and Running.

Confirm starting state:

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.image}{"\n"}'
kubectl -n aerospike get pods
kubectl run -it --rm aerospike-tool-rf -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show config like replication-factor"
```

**Pass:** Image `aerospike/aerospike-server-enterprise:8.1.0.0` (or current 8.1.0.x patch); 3/3 pods `Running`; all nodes report `replication-factor 2`.

## Optional — continuous workload (Terminal B)

Open a **second terminal window**. If the cluster has no records yet, load data first with `./scripts/labs/load-data.sh` in Terminal A, then start throughput:

```bash
./scripts/labs/run-lab-workload.sh start
```

Watch TPS in Terminal B (`status` tails `--debug` output). Perform Phase 1 below in Terminal A. When finished:

```bash
./scripts/labs/run-lab-workload.sh stop
```

## Background

| Mechanism | Effect |
|-----------|--------|
| `spec.image` change | AKO rolling-restarts pods sequentially to the new Aerospike version |
| [Lab 2.3](03-on-demand-operations.md) operations | Restart pods **without** changing `spec.image` — different API |

Unlike on-demand operations, the upgrade manifest changes **only** the image tag (plus the full cluster spec required by AKO). The workshop values already pin **8.1.2.0**.

---

## Phase 1 — Upgrade to 8.1.2.x

### Path A — kubectl

1. Record current image:

   ```bash
   kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.image}'
   ```

   **Expected:** `aerospike/aerospike-server-enterprise:8.1.0.0` (or current 8.1.0.x patch).

2. Apply the upgrade manifest (image already set to **8.1.2.0**; edit tag if using a different patch):

   ```bash
   kubectl apply -f manifests/disk-aerospike-upgrade.yaml
   kubectl -n aerospike get pods -w
   ```

   **Expected:** Sequential pod restarts; all pods reach `Running`.

3. Wait for reconciliation:

   ```bash
   kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed \
     aerospikecluster/aerocluster --timeout=900s
   ```

   **Expected:** Phase `Completed`.

### Path B — Helm

Chart `--version` must match the installed AKO operator — see [Lab 2.3 — Helm chart version (Path B)](03-on-demand-operations.md#helm-chart-version-path-b). Prefer the workshop script over raw `helm upgrade`:

```bash
./scripts/labs/apply-aerospike-upgrade-helm.sh
kubectl -n aerospike get pods -w
kubectl -n aerospike wait --for=jsonpath='{.status.phase}'=Completed \
  aerospikecluster/aerocluster --timeout=900s
```

**Expected:** Rolling pod restarts; image tag **8.1.2.x**; phase `Completed`.

Optional advanced (edit `image.tag` in values, then manual upgrade):

```bash
source scripts/env/workshop.env
source scripts/lib/common.sh
load_env
helm upgrade aerocluster aerospike/aerospike-cluster \
  -n aerospike \
  -f helm/base-disk-cluster-values.yaml \
  -f helm/overlay-aerospike-upgrade-values.yaml \
  --version="$(resolve_cluster_helm_chart_version)"
```

---

## Verify (pass/fail)

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.spec.image}{"\n"}{.status.phase}{"\n"}'
kubectl -n aerospike get pods -o wide
```

**Pass:** Image tag on **8.1.2.x** line; phase `Completed`; 3/3 pods `Running`.

Optional — confirm build and unchanged replication factor:

```bash
kubectl exec -n aerospike aerocluster-0-0 -c aerospike-server -- \
  asinfo -U admin -P admin123 -v build

kubectl run -it --rm aerospike-tool-rf -n aerospike --restart=Never \
  --image=aerospike/aerospike-tools:latest -- \
  asadm -h aerocluster -U admin -P admin123 -e "show config like replication-factor"
```

**Pass:** Build reports **8.1.2.x**; all nodes still report `replication-factor 2` (unless you intentionally changed RF in Lab 1.4).

## Observe

- One pod at a time restarted during the rolling upgrade
- Cluster remains available during the upgrade (if running workload in Terminal B, TPS may dip briefly per pod)
- CR `status.phase` transitions `InProgress` → `Completed`
- Contrast with [Lab 2.3](03-on-demand-operations.md) — operations restart processes without changing `spec.image`

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Webhook: cannot change image with operations | Run `./scripts/labs/prepare-lab.sh 2.4` to clear `spec.operations` and reset baseline |
| Upgrade rejected / unsupported DB version | Confirm operator ≥ 4.5.0 (`prepare-lab.sh 2.4` runs `validate_ako_min_version`); complete Lab 2.2 ladder to 4.5.0 |
| Helm chart version mismatch | Use `./scripts/labs/apply-aerospike-upgrade-helm.sh` or see [Lab 2.3 — Helm chart version](03-on-demand-operations.md#helm-chart-version-path-b) |
| Pods stuck / CR InProgress | `kubectl -n aerospike describe aerospikecluster aerocluster`; operator logs |
| RF drift after Lab 1.4 | Re-run `./scripts/labs/prepare-lab.sh 2.4` for RF=2 baseline before upgrading |

## Handoff

Proceed to Lab 2.5 — pick one guide from the [Section 2 README](README.md#labs) by `NODE_PROVISIONING`:

- **eksctl:** [K8s Worker Node Maintenance](05-k8s-node-maintenance.md)
- **Karpenter:** [K8s Worker Node Maintenance (Karpenter)](05-k8s-node-maintenance-karpenter.md)

Cluster should be on **8.1.2.x** with phase `Completed`.

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Upgrade to 8.1.2.x:**
  - Path A: [manifests/disk-aerospike-upgrade.yaml](../../manifests/disk-aerospike-upgrade.yaml) (default) · [manifests/dim-aerospike-upgrade.yaml](../../manifests/dim-aerospike-upgrade.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) or [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) (`--dim`) + [helm/overlay-aerospike-upgrade-values.yaml](../../helm/overlay-aerospike-upgrade-values.yaml)

## References

- [Upgrade Aerospike DB](https://aerospike.com/docs/kubernetes/install/deploy/upgrade-aerospike/)
- [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh)
