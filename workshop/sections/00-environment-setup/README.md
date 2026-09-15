# Section 0 — Environment Setup

## Section takeaway

You can stand up a complete lab platform — cluster (EKS or GKE), AKO, storage layers, and secrets — that all downstream labs reuse without re-explaining infrastructure.

## Setup steps

| Step | Guide | Duration |
|------|-------|----------|
| 0.1 | [Prerequisites](01-prerequisites.md) | ~15m |
| 0.2 | Cluster — [EKS eksctl](02-eks-cluster.md) / [EKS Karpenter](02-eks-cluster-karpenter.md) / [GKE Standard](02-gke-cluster.md) | ~15–25m |
| 0.2-nodes | Baseline per-AZ workload pools | ~10–15m |
| 0.3 | Install AKO — [OLM](03-install-ako-olm.md) or [Helm](03-install-ako-helm.md) | ~20m |
| 0.4 | [akoctl](04-install-akoctl.md) | ~10m |
| 0.5 | [Storage layer](05-storage-layer.md) | ~25m |
| 0.6 | [Secrets and validation](06-secrets-and-validation.md) | ~10m |
| 0.7 | [Upgrade-lab cluster (Lab 2.6)](07-upgrade-lab-cluster.md) — **opt-in**, off by default | ~15–25m |
| 0.8 | [All-flash cluster (Section 4)](08-all-flash-cluster.md) — **opt-in**, off by default | ~25–35m |

## Dedicated clusters (off by default)

A default `./scripts/setup/setup-all.sh` run creates **only the main cluster** (steps 0.1–0.6). Lab 2.6 and Section 4 each need their own cluster and are not part of that run:

```bash
./scripts/setup/setup-all.sh --step 0.7   # Lab 2.6 upgrade-lab
./scripts/setup/setup-all.sh --step 0.8   # Section 4 all-flash
# or include 0.7 in a full run (main + upgrade-lab bootstrap in parallel):
./scripts/setup/setup-all.sh --with-upgrade-lab
```

`--step 0.7` runs the full [`upgrade-lab/setup-upgrade-lab.sh`](../../scripts/setup/upgrade-lab/setup-upgrade-lab.sh), which bootstraps the cluster if it does not exist. `--with-upgrade-lab` creates the upgrade-lab cluster with [`upgrade-lab/00-bootstrap-eks.sh`](../../scripts/setup/upgrade-lab/00-bootstrap-eks.sh) or [`upgrade-lab/00-bootstrap-gke.sh`](../../scripts/setup/upgrade-lab/00-bootstrap-gke.sh) alongside step 0.2, then finishes 0.7 with [`upgrade-lab/setup-upgrade-lab-post-bootstrap.sh`](../../scripts/setup/upgrade-lab/setup-upgrade-lab-post-bootstrap.sh). `--sequential` with `--with-upgrade-lab` bootstraps main first, then upgrade-lab. Individual `--step` runs are never parallel.

| Choose Path A (OLM) when… | Choose Path B (Helm) when… |
|---------------------------|------------------------------|
| Teaching OperatorHub/OLM lifecycle | Audience uses Helm for all K8s deploys |
| Automated bootstrap via [`setup-all.sh`](../../scripts/setup/setup-all.sh) | Teaching values-driven / GitOps workflows |
| OpenShift/OLM-centric environments | Need `helm upgrade` rollback and diff |

See [instructor/path-selection-guide.md](../../instructor/path-selection-guide.md).

## Cloud provider and node provisioning

Pick **one** cloud and **one** node strategy at Section 0 (orthogonal to OLM/Helm):

| Cloud | Env file | Node provisioning |
|-------|----------|-------------------|
| **EKS** (default) | [`workshop.env.example`](../../scripts/env/workshop.env.example) | `eksctl` (default) or `karpenter` |
| **GKE Standard** | [`workshop.env.gke.example`](../../scripts/env/workshop.env.gke.example) | `nodepool` only (Karpenter is AWS-only) |

| Choose eksctl MNG when… | Choose Karpenter when… | Choose GKE node pools when… |
|-------------------------|-------------------------|------------------------------|
| Teaching classic EKS nodegroups | Audience uses Karpenter in production | Delivering the workshop on GCP |
| Demoing `k8sNodeBlockList` (Lab 2.5) | Teaching dynamic node provisioning | Same labs as EKS eksctl (no Autopilot) |
| Simplest EKS bootstrap | Full main curriculum on autoscaled i8g | Local NVMe via `--local-nvme-ssd-block=count=…` |

On EKS, Lab 2.6 upgrade-lab always uses eksctl MNG. On GKE it uses a GKE node pool. Do not run `02-bootstrap-eks.sh` when `CLOUD_PROVIDER=gke` (or the reverse) — the scripts refuse the mismatch.

## What Section 0 does NOT do

- Does **not** deploy an Aerospike cluster on the main cluster — labs deploy their own baseline
- Does **not** cover scaling, upgrades, or maintenance — Sections 1 and 2

Step **0.7** and step **0.8** are **not** part of a full `setup-all.sh` run. 0.7 builds the upgrade-lab cluster for Lab 2.6; 0.8 builds a third cluster for Section 4 (all-flash) on large NVMe instances. Run them only when you teach those optional labs:

```bash
./scripts/setup/setup-all.sh --step 0.7    # or prepare-lab.sh 2.6
./scripts/setup/setup-all.sh --step 0.8    # or prepare-lab.sh 4.1
```

Unlike 0.7, step 0.8 **honors `DEPLOY_PATH`**, so Path A/B stay consistent through Labs 4.1–4.2. Details: [Lab 0.7](07-upgrade-lab-cluster.md), [Lab 0.8](08-all-flash-cluster.md).

The upgrade-lab is a complete, ready-to-upgrade environment: AKO is installed **via OLM regardless of `DEPLOY_PATH`**, the same secrets as the main cluster are applied, local-ssd is provisioned when the resolved storage for lab 2.6 is `disk` (the `CLUSTER_STORAGE` default), and an `AerospikeCluster` named `aerocluster` is deployed with `kubectl apply`. Scripts restore your kubectl context to `${CLUSTER_NAME}` afterwards.

## Step-by-step setup (teaching flow)

Run each setup step individually — setup script numbers (`01`–`08`) map to step IDs via `--list`:

```bash
cd workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
# GKE: cp scripts/env/workshop.env.gke.example scripts/env/workshop.env
source scripts/env/workshop.env

./scripts/setup/setup-all.sh --step 0.1
./scripts/setup/setup-all.sh --step 0.2
./scripts/setup/setup-all.sh --step 0.2-nodes
./scripts/setup/setup-all.sh --step 0.3
./scripts/setup/setup-all.sh --step 0.4
./scripts/setup/setup-all.sh --step 0.5    # ssd StorageClass + local NVMe
./scripts/setup/setup-all.sh --step 0.6    # secrets + validate
# optional dedicated clusters (off by default):
./scripts/setup/setup-all.sh --step 0.7    # upgrade-lab (Lab 2.6) — see 07-upgrade-lab-cluster.md
./scripts/setup/setup-all.sh --step 0.8    # all-flash cluster (Section 4) — see 08-all-flash-cluster.md
```

Or invoke scripts directly:

```bash
./scripts/setup/01-validate-client.sh
./scripts/setup/02-bootstrap-eks.sh    # or 02-bootstrap-gke.sh when CLOUD_PROVIDER=gke
./scripts/setup/02-ensure-workload-nodepool.sh
./scripts/setup/03-install-ako.sh
./scripts/setup/04-install-akoctl.sh
./scripts/setup/05-setup-ebs-storage.sh
./scripts/setup/06-setup-local-storage.sh
./scripts/setup/07-deploy-secrets.sh
./scripts/setup/08-validate-environment.sh
./scripts/setup/upgrade-lab/setup-upgrade-lab.sh
```

See `./scripts/setup/setup-all.sh --list` for the full step → script mapping.

### Step IDs and resume

`--step` also accepts the atomic IDs behind the composites, and `--from` resumes a full run at any step (single-step runs print the exact `--from` command to continue with):

| Step ID | Script |
|---------|--------|
| `0.5` | composite: `0.5-ebs` + `0.5-local` |
| `0.5-ebs` | [`05-setup-ebs-storage.sh`](../../scripts/setup/05-setup-ebs-storage.sh) — EKS: EBS CSI + `ssd`; GKE: PD CSI StorageClass `ssd` |
| `0.5-local` | [`06-setup-local-storage.sh`](../../scripts/setup/06-setup-local-storage.sh) |
| `0.6` | composite: `0.6-secrets` + `0.6-validate` |
| `0.6-secrets` | [`07-deploy-secrets.sh`](../../scripts/setup/07-deploy-secrets.sh) |
| `0.6-validate` | [`08-validate-environment.sh`](../../scripts/setup/08-validate-environment.sh) |
| `0.7` / `0.7-upgrade-lab` | [`upgrade-lab/setup-upgrade-lab.sh`](../../scripts/setup/upgrade-lab/setup-upgrade-lab.sh) — opt-in, `--step`/`--from`/`--with-upgrade-lab` |
| `0.8` / `0.8-all-flash` | [`all-flash/setup-all-flash.sh`](../../scripts/setup/all-flash/setup-all-flash.sh) — opt-in, `--step`/`--from` only |

```bash
./scripts/setup/setup-all.sh --step 0.5-ebs     # StorageClass ssd only, skip local NVMe
./scripts/setup/setup-all.sh --from 0.5-local   # resume through 0.6
```

## Quick orchestration (pre-staging shortcut)

Run all Section 0 steps in one command:

```bash
cd workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
# GKE: cp scripts/env/workshop.env.gke.example scripts/env/workshop.env
# Edit DEPLOY_PATH, NODE_PROVISIONING (EKS), GCP_PROJECT (GKE), and paths

./scripts/setup/setup-all.sh
```

Lab 2.6 and Section 4 stay off. Opt in when you need them:

```bash
./scripts/setup/setup-all.sh --with-upgrade-lab   # include 0.7 in this run
./scripts/setup/setup-all.sh --step 0.7           # Lab 2.6 cluster only
./scripts/setup/setup-all.sh --step 0.8           # Section 4 cluster only
```

## Instructor notes

See [instructor-notes.md](instructor-notes.md).

## Workshop artifacts

- **EKS** reference configs: [clusters/main-cluster.yaml](../../clusters/main-cluster.yaml) · [clusters/upgrade-lab-cluster.yaml](../../clusters/upgrade-lab-cluster.yaml) · [clusters/all-flash-cluster.yaml](../../clusters/all-flash-cluster.yaml) — documentation only. Bootstrap scripts render their own ClusterConfig from `workshop.env` and run `eksctl create cluster -f`; the Karpenter path is the one exception, applying [clusters/main-cluster-karpenter.yaml](../../clusters/main-cluster-karpenter.yaml) through `envsubst`.
- **GKE** has no checked-in ClusterConfig — [`02-bootstrap-gke.sh`](../../scripts/setup/02-bootstrap-gke.sh) calls `gcloud` from [`workshop.env.gke.example`](../../scripts/env/workshop.env.gke.example). Guide: [02-gke-cluster.md](02-gke-cluster.md).
- **Baseline Aerospike cluster (3 nodes)** — selected by `CLUSTER_STORAGE` (`disk` default, `dim` for in-memory), not a script flag:
  - Path A: [manifests/disk-cluster.yaml](../../manifests/disk-cluster.yaml) · [manifests/dim-cluster.yaml](../../manifests/dim-cluster.yaml)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml)

