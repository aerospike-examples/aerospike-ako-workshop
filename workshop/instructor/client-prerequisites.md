# Instructor Guide: Client Prerequisites

This document applies to the **machine running the training** (instructor laptop or bastion) — not EKS nodes or trainee machines.

## Who needs what

| Role | Client tools |
|------|--------------|
| **Instructor** | Full tool set below |
| **Trainee** (observe-only) | None; optional kubectl for hands-on |
| **Pre-stager** | Same as instructor |

## Tool matrix

| Tool | Path A | Path B | Min version | Verify |
|------|:------:|:------:|-------------|--------|
| AWS CLI | required (EKS) | required (EKS) | 2.x | `aws sts get-caller-identity` |
| gcloud | required (GKE) | required (GKE) | current | `gcloud auth print-access-token` |
| kubectl | required | required | 1.28+ | `kubectl version --client` |
| eksctl | required (EKS) | required (EKS) | 0.190+ | `eksctl version` |
| git | required | required | 2.x | `git --version` |
| bash | required | required | 4.x | — |
| curl | required | required | — | `curl --version` |
| Helm | — | required | 3.12+ | `helm version` |
| Helm (Karpenter) | — | if `NODE_PROVISIONING=karpenter` | 3.12+ | `helm version` |
| krew | required | required | 0.4+ | `kubectl krew version` |
| akoctl | optional | optional | latest | Installed in Lab 0.4; `kubectl krew list \| grep akoctl` |
| jq | recommended | recommended | 1.6+ | `jq --version` |
| OpenSSH | required | required | — | `ssh -V` |

## AWS prerequisites

| Requirement | Verify |
|-------------|--------|
| AWS credentials configured (SSO: `aws sso login`) | `aws sts get-caller-identity` |
| IAM for EKS, EC2, IAM, CloudFormation | Caller ARN printed by `./scripts/setup/01-validate-client.sh` |
| Permissions boundary, if the account requires one | `01-validate-client.sh` prints the resolved ARN — see [below](#shared-aws-accounts-and-iam-permissions-boundaries) |
| Unique `CLUSTER_NAME` / `UPGRADE_LAB_CLUSTER_NAME` when the account is shared | EKS + IAM names are account-global |
| EC2 key pair in region | `aws ec2 describe-key-pairs --region us-east-1` |
| Quota: 4× i8g.2xlarge (main eksctl baseline) | Service Quotas console |
| Quota: 4× i8g.4xlarge (Lab 1.2 vertical scale overlap) | Service Quotas console |
| Quota: 4–8× i8g.2xlarge (main Karpenter min/max) | Service Quotas console |
| Quota: 4–8× i8g.4xlarge (Lab 1.2 Karpenter vertical scale) | Service Quotas console |
| Quota: 3× i8g.2xlarge (upgrade-lab) | Service Quotas console |
| EC2 AZ capacity: `i8g.2xlarge` + `i8g.4xlarge` in each `AWS_ZONES` entry | `./scripts/setup/01b-check-ec2-capacity.sh` (also runs from `01-validate-client.sh`) |
| Karpenter IAM (controller + node roles) | Created by `scripts/setup/karpenter/00-install-controller.sh` |
| feature-key file (`features.conf`) | File at `secrets/features.conf` |
| kubeconfig for both clusters (Lab 2.6) | `./scripts/lib/kubecontext.sh show` |

## Shared AWS accounts and IAM permissions boundaries

Many organizations only allow IAM role creation when an org-defined **permissions boundary** is attached, so `eksctl create cluster` fails outright without one. Aerospike-run workshops are an example: department accounts are shared, instructors assume `shared-account-powerusers-v2`, and that role is denied `CreateRole` unless the role carries the account-local `shared-power-users-boundary` policy.

Bootstrap handles this automatically: with `IAM_PERMISSIONS_BOUNDARY=auto` (default) the scripts look for that policy in the current account and attach it to every role they create — the EKS cluster service role, node instance roles, the VPC CNI and EBS CSI IRSA roles, and the Karpenter controller/node roles. Accounts with no such policy behave exactly as before.

| Setting in `scripts/env/workshop.env` | Effect |
|---------------------------------------|--------|
| `IAM_PERMISSIONS_BOUNDARY=auto` | Attach `IAM_PERMISSIONS_BOUNDARY_NAME` when it exists in the account (default) |
| `IAM_PERMISSIONS_BOUNDARY=required` | Same lookup, but fail client validation when the policy cannot be found |
| `IAM_PERMISSIONS_BOUNDARY=off` | Never attach — accounts with no boundary requirement |
| `IAM_PERMISSIONS_BOUNDARY=arn:aws:iam::<account-id>:policy/<name>` | Attach that policy verbatim |

Set `IAM_PERMISSIONS_BOUNDARY_NAME` to your organization's boundary policy name (default `shared-power-users-boundary`).

When the account is shared with other people, also set a unique `CLUSTER_NAME` (and `UPGRADE_LAB_CLUSTER_NAME`) before bootstrap — EKS cluster names, nodegroup names, and IAM role names are account-global. No lab needs IAM users, groups, or access keys, which such accounts typically deny.

## GCP / GKE prerequisites

Use [workshop.env.gke.example](../scripts/env/workshop.env.gke.example) (`CLOUD_PROVIDER=gke`). GKE **Standard** only — Autopilot cannot run the local-NVMe DaemonSet.

| Requirement | Verify |
|-------------|--------|
| `gcloud` authenticated | `gcloud auth print-access-token` |
| `GCP_PROJECT` set | `01-validate-client.sh` |
| APIs enabled | `gcloud services enable container.googleapis.com compute.googleapis.com --project=$GCP_PROJECT` |
| Quota: N2 CPUs + Local SSD GB in `${GCP_REGION}` | IAM/quotas console — baseline `n2-highmem-8` ×4 + vertical `n2-highmem-16` ×4 + upgrade-lab ×3 |
| Unique `CLUSTER_NAME` in a shared project | GKE cluster names are project-global |

## Repo layout on client

```text
aerospike-ako-workshop/
└── workshop/
    ├── scripts/env/workshop.env          # local copy from workshop.env.example (or workshop.env.gke.example)
    ├── secrets/features.conf             # NOT in git — instructor-supplied license
    ├── vendor/storage/                   # vendored storage manifests
    └── .kube/                            # isolated kubeconfigs (gitignored)
```

## Pre-class runbook

**Step-by-step** (recommended when validating each lab):

```bash
cd workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
source scripts/env/workshop.env

./scripts/setup/setup-all.sh --step 0.1
./scripts/setup/setup-all.sh --step 0.2
./scripts/setup/setup-all.sh --step 0.3
./scripts/setup/setup-all.sh --step 0.4
./scripts/setup/setup-all.sh --step 0.5
./scripts/setup/setup-all.sh --step 0.6
```

**Pre-staging shortcut** (all Section 0 steps):

```bash
cd workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
./scripts/setup/setup-all.sh
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Wrong kubectl context | `./scripts/lib/kubecontext.sh main` or `./scripts/lib/kubecontext.sh upgrade-lab` |
| Expired AWS creds | Refresh SSO (`aws sso login`) or `aws configure` |
| `AccessDenied` / CloudFormation `CREATE_FAILED` on an IAM role | Boundary missing: check `01-validate-client.sh` output and that `IAM_PERMISSIONS_BOUNDARY` is not `off` when the account requires one |
| `AlreadyExists` on cluster, nodegroup, or IAM role | Name already used by someone else in the account — pick a unique `CLUSTER_NAME` |
| krew not in PATH | Add `~/.krew/bin` to PATH |
| Helm repo 404 in browser | Use CLI only — browser URL may 404 |

## Hands-on variant

Minimum trainee tools: kubectl + shared kubeconfig, or read-only AWS if trainees only observe.

## Install links

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [gcloud](https://cloud.google.com/sdk/docs/install)
- [eksctl](https://eksctl.io/installation/)
- [krew](https://krew.sigs.k8s.io/docs/user-guide/setup/install/)
- [AKO scaling — Karpenter + local volumes](https://aerospike.com/docs/kubernetes/manage/configure/scaling)
- [Helm](https://helm.sh/docs/intro/install/)
