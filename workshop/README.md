# AKO Workshop Walkthrough Guide

Instructor-led walkthroughs for the **Aerospike Kubernetes Operator (AKO)** on **AWS EKS** (default) or **GKE Standard**.

## Audience

Kubernetes administrators and platform engineers new to AKO.

## Estimated duration

| Section | Duration |
|---------|----------|
| [0 — Environment Setup](sections/00-environment-setup/) | ~1–1.5 h (or pre-staged) |
| [1 — Scaling & Capacity](sections/01-scaling-and-capacity/) | ~2–2.5 h |
| [2 — Maintenance & Upgrade](sections/02-maintenance-and-upgrade/) | ~1.5–2 h |
| [3 — Security & Authentication](sections/03-security-and-authentication/) | ~1.5–2 h |
| [4 — All-flash Storage](sections/04-all-flash-storage/) (optional, dedicated cluster) | ~45 m–1 h |

## Deploy path selection

Pick **one path** at Section 0 and stay on it for the session:

| Path | Operator install | Cluster deploy | Lab changes |
|------|-----------------|----------------|-------------|
| **A — kubectl/OLM** (default) | OLM + OperatorHub | `kubectl apply -f manifests/` | Patch YAML |
| **B — Helm** | cert-manager + Helm chart | `helm upgrade -f helm/` | Values files |

See [instructor/path-selection-guide.md](instructor/path-selection-guide.md) and [Section 0 README](sections/00-environment-setup/README.md).

## Lab structure

Labs use consistent terminology — see the [lab walkthrough template](_templates/lab-walkthrough.md#lab-structure) for **setup step**, **Phase 0 — Prepare lab**, **Phase 1–N**, **Steps**, **baseline/vertical pool**, and **full/light reset**.

## Cloud provider

| Provider | Config | Node strategy |
|----------|--------|----------------|
| **EKS** (default) | `CLOUD_PROVIDER=eks` — copy [workshop.env.example](scripts/env/workshop.env.example) | `eksctl` or `karpenter` |
| **GKE Standard** | `CLOUD_PROVIDER=gke` — copy [workshop.env.gke.example](scripts/env/workshop.env.gke.example) | node pools only (`NODE_PROVISIONING=nodepool`) |

GKE Autopilot and Karpenter-on-GCP are not supported.

## Node provisioning

Pick **one** main-cluster node strategy at Section 0 (orthogonal to OLM/Helm):

| Mode | Config | Lab 2.5 blocklist | Lab 2.6 cluster |
|------|--------|---------------------|-----------------|
| **eksctl MNG** (default on EKS) | `NODE_PROVISIONING=eksctl` | Supported | eksctl MNG |
| **Karpenter** (EKS optional) | `NODE_PROVISIONING=karpenter` | **Not supported** | eksctl MNG (unchanged) |
| **GKE node pools** | `NODE_PROVISIONING=nodepool` | Supported | GKE node pools |

## Version pins

| Component | Workshop default | Config |
|-----------|------------------|--------|
| Aerospike Database (baseline) | **8.1.0** (`8.1.0.0` image tag) | `AEROSPIKE_VERSION` in [workshop.env.example](scripts/env/workshop.env.example) |
| Aerospike Database (post Lab 2.4) | **8.1.2** (`8.1.2.0` image tag) | `AEROSPIKE_UPGRADE_IMAGE` |
| AKO (install) | 4.2.0 | `AKO_VERSION_START` |
| AKO (post Lab 2.2) | 4.5.0 | `AKO_VERSION_TARGET` |
| AKO (Section 4 all-flash) | 4.5.0 | `ALL_FLASH_AKO_VERSION` |
| AKO cluster chart (Helm) | auto-detect installed operator | `AKO_CLUSTER_CHART_VERSION` (empty = auto) |
| Kubernetes (main) | 1.35 (env-driven) | `K8S_VERSION` in [workshop.env.example](scripts/env/workshop.env.example) |
| Kubernetes (upgrade lab) | 1.34 → 1.35 | `UPGRADE_LAB_K8S_VERSION_*` in [workshop.env.example](scripts/env/workshop.env.example) |

### AKO / Aerospike compatibility

| AKO | Max supported Aerospike |
|-----|-------------------------|
| 4.2.0–4.4.1 | 8.1.0.x |
| 4.5.0+ | 8.1.2.x |

Update patch tags each workshop season to match [enterprise image tags](https://hub.docker.com/r/aerospike/aerospike-server-enterprise/tags).

## Cluster architecture

| Cluster | Name | Purpose |
|---------|------|---------|
| **Main** | `my-cluster` | All labs except 2.6 and Section 4 (eksctl or Karpenter) |
| **Upgrade lab** (opt-in) | `my-cluster-k8s-upgrade` | Lab 2.6 control plane upgrade only (**eksctl MNG always**) |
| **All-flash** (opt-in) | `my-cluster-all-flash` | Section 4 only — index-on-flash nodes (`i8ge.3xlarge` / `n2-highmem-16`, **eksctl MNG or GKE node pool always**) |

**kubectl default context is `my-cluster`** for all labs except the 2.6 and Section 4 demo steps. Use `./scripts/lib/kubecontext.sh show` to verify.

Steps **0.7** and **0.8** are **opt-in** — `setup-all.sh` never creates those clusters by default. Run `--step 0.7` (or `--with-upgrade-lab`) for Lab 2.6, and `--step 0.8` for Section 4. Tear down upgrade-lab after Lab 2.6 with `--upgrade-lab-only` and all-flash after Lab 4.2 with `--all-flash-only`; end-of-course use `./scripts/cleanup-lab.sh` to delete **all** clusters.

Lab tables use the actual EKS cluster name (`my-cluster`), not the role label "Main".

## Lab registry

Machine-readable catalog: [LAB_REGISTRY.yaml](LAB_REGISTRY.yaml)

In the registry, `deploy_paths: [kubectl]` means **Path A** (OLM + `kubectl apply`); `[helm]` means **Path B** (Helm values).

### Recommended order

```text
0.1 → 0.2 → 0.3 → 0.4 → 0.5 → 0.6
→ 1.1 → 1.2 → 1.3
→ 2.1 → 2.2 (through AKO 4.5.0) → 1.4
→ 2.3 → 2.4 → 2.5
→ 3.1 → 3.2 → 3.3 → 3.4 → 3.5
optional, dedicated clusters: 0.7 → 2.6
optional, dedicated cluster: 0.8 → 4.1 → 4.2
```

Section **3** is part of the full curriculum (after **2.5**; Lab **3.1** light-resets the cluster for PKI/TLS). Lab **2.6** is optional, off by default, and uses the upgrade-lab cluster — run setup **0.7** (or `prepare-lab.sh 2.6`) only when teaching it; it may precede or follow Section 3.

Section **4** (all-flash) is optional, off by default, and fully self-contained on its own cluster: it only needs **0.6** plus setup step **0.8**, so it can be taught at any point after Section 0 without touching `my-cluster`.

Note: Lab **1.4** (replication factor) requires AKO **4.4.0+** — run after **2.2** reaches 4.4.1 (or complete the full ladder to 4.5.0). Lab **2.3** (on-demand operations) requires AKO **4.4.0+**. Lab **2.4** (DB upgrade to 8.1.2.x) requires AKO **4.5.0+**.

### Lab map

| ID | Title | Cluster | AKO min | Run after |
|----|-------|---------|---------|-----------|
| 0.1–0.6 | Environment setup (main cluster) | `my-cluster` | 4.2.0 (install) | — |
| 0.7 | Upgrade-lab cluster (Lab 2.6, opt-in) | `my-cluster-k8s-upgrade` | — | 0.6 |
| 0.8 | All-flash cluster (Section 4, opt-in) | `my-cluster-all-flash` | **4.5.0** | 0.6 |
| 1.1 | Horizontal scaling | `my-cluster` | 4.2.0 | 0.6 |
| 1.2 | Rack awareness, vertical scale & revision | `my-cluster` | 4.2.0 | 1.1 |
| 1.3 | Rack replacement | `my-cluster` | 4.2.0 | — (standalone) |
| 2.1 | akoctl (install, collectinfo) | `my-cluster` | — | 1.3 |
| 2.2 | Upgrade AKO | `my-cluster` | 4.2.0→4.5.0 | 2.1 |
| **1.4** | **Replication factor** | `my-cluster` | **4.4.0** | **2.2** |
| 2.3 | On-demand operations | `my-cluster` | 4.4.0 | 2.2 |
| 2.4 | Upgrade Aerospike DB | `my-cluster` | **4.5.0** | 2.3 |
| 2.5 | K8s node maintenance | `my-cluster` | **4.5.0** | 2.4 |
| 2.6 | K8s control plane upgrade (opt-in) | `my-cluster-k8s-upgrade` | — | 0.7 |
| 3.1 | Generate PKI keys and certificates | `my-cluster` | 4.2.0 | 0.6 |
| 3.2 | TLS only (encryption in transit) | `my-cluster` | 4.2.0 | 3.1 |
| 3.3 | mTLS and PKI authentication | `my-cluster` | 4.2.0 | 3.2 |
| 3.4 | Server certificate rotation | `my-cluster` | 4.2.0 | 3.3 |
| 3.5 | Live client credential rotation | `my-cluster` | 4.2.0 | 3.4 |
| 4.1 | Deploy an all-flash cluster | `my-cluster-all-flash` | **4.5.0** | 0.8 |
| 4.2 | Scale an all-flash cluster | `my-cluster-all-flash` | **4.5.0** | 4.1 |

## Quick start (instructor)

**Teaching flow** — run Section 0 labs step by step (see [Section 0 README](sections/00-environment-setup/README.md)):

```bash
cd workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
source scripts/env/workshop.env

./scripts/setup/setup-all.sh --step 0.1
./scripts/setup/setup-all.sh --step 0.2
./scripts/setup/setup-all.sh --step 0.2-nodes
./scripts/setup/setup-all.sh --step 0.3
./scripts/setup/setup-all.sh --step 0.4
./scripts/setup/setup-all.sh --step 0.5
./scripts/setup/setup-all.sh --step 0.6
```

Optional dedicated clusters (off by default):

```bash
./scripts/setup/setup-all.sh --step 0.7   # Lab 2.6
./scripts/setup/setup-all.sh --step 0.8   # Section 4
```

**Pre-staging shortcut** — main-cluster Section 0 steps in one command:

```bash
./scripts/setup/setup-all.sh
```

Include the Lab 2.6 upgrade-lab cluster in that run (parallel bootstrap with 0.2):

```bash
./scripts/setup/setup-all.sh --with-upgrade-lab
```

`--skip-upgrade-lab` is still accepted and is the default. Sequential bootstrap of main then upgrade-lab:

```bash
./scripts/setup/setup-all.sh --with-upgrade-lab --sequential
```

## Prerequisites

- **Instructor:** [instructor/client-prerequisites.md](instructor/client-prerequisites.md)
- **Trainees:** [prerequisites/README.md](prerequisites/README.md)

## Validation

Before delivery, run every lab end-to-end on EKS. See [validation/README.md](validation/README.md), [validation/walkthrough-checklist.md](validation/walkthrough-checklist.md), and [validation/karpenter-walkthrough.md](validation/karpenter-walkthrough.md) for the optional Karpenter path.

## Upcoming sections

Registered in `LAB_REGISTRY.yaml` as `future_sections` (IDs 05–07) — not yet implemented:

- Monitoring & Observability
- Backup & Restore
- Strong Consistency

## Official documentation

- [AKO docs home](https://docs.aerospike.com/cloud/kubernetes/operator)
- [Scaling](https://aerospike.com/docs/kubernetes/manage/configure/scaling)
- [Upgrade operator](https://aerospike.com/docs/kubernetes/manage/upgrade/upgrading-operator)

## Troubleshooting

### Diagnostic commands

Run from the `workshop/` directory unless noted.

**AKO operator**

```bash
# Live follow (controller reconcile loop)
kubectl -n operators logs -f deployment/aerospike-operator-controller-manager manager

# Snapshot (last 100 lines)
kubectl -n operators logs deployment/aerospike-operator-controller-manager manager --tail=100

kubectl -n operators get pods
kubectl -n operators rollout status deployment/aerospike-operator-controller-manager
```

**AerospikeCluster CR**

```bash
kubectl -n aerospike get aerospikecluster aerocluster -o jsonpath='{.status.phase}{"\n"}'
kubectl -n aerospike describe aerospikecluster aerocluster
```

**Pods and scheduling**

```bash
kubectl -n aerospike get pods -w
kubectl -n aerospike describe pod <name>
kubectl -n aerospike get events --sort-by='.lastTimestamp'
```

**Storage**

```bash
kubectl -n aerospike get pvc -o wide
kubectl get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,STATUS:.status.phase --no-headers | awk '$2 == "local-ssd"'
```

**Nodes**

```bash
kubectl get nodes -L workshop.aerospike.com/node-pool,node.kubernetes.io/instance-type
```

**Bundled check**

```bash
./scripts/verify-cluster.sh
```

**Support bundle** (full K8s/operator snapshot — see [Lab 2.1](sections/02-maintenance-and-upgrade/01-akoctl.md)):

```bash
mkdir -p /tmp/akoctl-lab
kubectl akoctl collectinfo -n aerospike,operators --path /tmp/akoctl-lab
```

### Common issues

| Issue | Check / fix |
|-------|-------------|
| EBS PVC Pending | EBS CSI IAM role and addon |
| Local disk not found | nvme-bootstrap DaemonSet init logs; partition symlinks in `/mnt/disks/` ([Lab 0.5](sections/00-environment-setup/05-storage-layer.md)) |
| CSV not Succeeded | OLM InstallPlan approval ([Lab 0.3 OLM](sections/00-environment-setup/03-install-ako-olm.md)) |
| Helm webhook errors | cert-manager installed (Path B) |
| CRD upgrade failures | Never `kubectl delete` CRDs — use `kubectl replace` |
| CR stuck `InProgress` | `describe aerospikecluster aerocluster`; AKO logs (`kubectl -n operators logs -f deployment/aerospike-operator-controller-manager manager`); `./scripts/verify-cluster.sh` |
| Pods `Pending` (scheduling) | `describe pod`; node pool labels; `./scripts/labs/lab-nodes.sh <lab> validate` |
| Pods `Pending` (PVC) | `get pvc -o wide`; `get pv -o custom-columns=NAME:.metadata.name,CLASS:.spec.storageClassName --no-headers \| awk '$2 == "local-ssd"'` |
| Migration / scale-down slow | Expected during rack revision/replacement or scale-down with data; watch AKO logs and `asadm` migrate stats |
| Operator `CrashLoopBackOff` | AKO logs; Path B: cert-manager; Path A: OLM CSV/InstallPlan |
| Safe eviction blocks drain | AKO webhook blocks drain only during active migration; local PVC pinning and PVC cleanup on node termination — see [Lab 2.5](sections/02-maintenance-and-upgrade/05-k8s-node-maintenance.md) |

## Security

- **`secrets/features.conf`** — Aerospike Enterprise license supplied by each instructor; **never committed** (gitignored)
- **Lab auth passwords** (`admin123`, `app123`, `exporter123`) — generic throwaway defaults for disposable EKS clusters; committed in `scripts/setup/07-deploy-secrets.sh` and documented in [secrets/README.md](secrets/README.md)
- **`.kube/`** — local kubeconfig files created during parallel cluster bootstrap (gitignored)

## Reset / teardown

| Goal | Script |
|------|--------|
| Remove Aerospike cluster only (keep nodegroups) | `./scripts/labs/teardown-cluster.sh` |
| Section 3 cleanup (cluster + TLS/PKI secrets + local `secrets/tls/`) | `./scripts/labs/teardown-section-3.sh` — see [Section 03 teardown](sections/03-security-and-authentication/README.md#teardown) |
| Remove database + all workload nodegroups/NodePools (keep EKS + AKO + storage) | `./scripts/reset-cluster.sh` |
| Delete entire EKS cluster(s) | `./scripts/cleanup-lab.sh` (default: **both** clusters deleted **in parallel**; Karpenter path drains bootstrap + workload pools first, ~15 min) |
| Delete upgrade-lab only (after Lab 2.6) | `./scripts/cleanup-lab.sh --upgrade-lab-only` |
| Delete all-flash cluster only (after Lab 4.2) | `./scripts/cleanup-lab.sh --all-flash-only` |
| Delete main cluster only | `./scripts/cleanup-lab.sh --main-only` |
| Sequential dual-cluster delete | `./scripts/cleanup-lab.sh --sequential` |

After `reset-cluster.sh`, re-create workload nodes with `./scripts/labs/prepare-lab.sh 1.1` (or `lab-nodes.sh 1.1 ensure`).
