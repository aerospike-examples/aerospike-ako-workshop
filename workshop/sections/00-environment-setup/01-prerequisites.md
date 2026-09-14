# Lab 0.1 — Prerequisites

| Field | Value |
|-------|-------|
| Lab ID | `0.1` |
| Section | Environment Setup |
| Cluster | — (client machine only) |
| Duration | ~15 min |
| Validation status | `draft` |

## Takeaway

The instructor client has all required tools, cloud access, and licensing files before creating the cluster.

## Prerequisites

- macOS or Linux workstation (or bastion)
- Aerospike Enterprise **feature-key file** (`features.conf`)
- **EKS (default):** AWS account allowed to create EKS clusters, EC2, CloudFormation, and IAM roles
- **GKE:** GCP project with GKE Standard + Compute; copy [`workshop.env.gke.example`](../../scripts/env/workshop.env.gke.example) instead of the EKS example

### What `01-validate-client.sh` checks

| Category | Checks |
|----------|--------|
| Required tools | `kubectl`, `git`, `curl`, `bash`, `krew`; plus **EKS:** `aws`, `eksctl` **or GKE:** `gcloud` |
| Conditional tools | `helm` — when `DEPLOY_PATH=helm` **or** `NODE_PROVISIONING=karpenter` |
| Optional tools | `jq` (recommended), `akoctl` (installed in Lab 0.4) |
| Cloud access | EKS: STS, IAM boundary, EC2 key pair, i8g capacity. GKE: `gcloud auth`, `GCP_PROJECT`, Container API |
| Workshop files | `secrets/features.conf`; `vendor/storage/local_volume_provisioner_cleanup.yaml` and `local_volume_provisioner_cleanup_rbac.yaml` |

Presence and `--version` are what get verified — the script does not assert minimum tool versions, so check those against [client prerequisites](../../instructor/client-prerequisites.md) yourself.

## Steps

1. Clone the workshop repo and open the `workshop/` directory.

2. Copy environment template:

   ```bash
   cd workshop
   cp scripts/env/workshop.env.example scripts/env/workshop.env
   # GKE: cp scripts/env/workshop.env.gke.example scripts/env/workshop.env
   ```

   If the cloud account is shared, set a unique `CLUSTER_NAME` (and `UPGRADE_LAB_CLUSTER_NAME`). On **EKS**, cluster and IAM names are account-global; if the account only permits role creation with a permissions boundary attached, leave `IAM_PERMISSIONS_BOUNDARY=auto` — see [client prerequisites](../../instructor/client-prerequisites.md#shared-aws-accounts-and-iam-permissions-boundaries). On **GKE**, cluster names are project-global; set `GCP_PROJECT` in `workshop.env`.

3. Place feature-key file:

   ```bash
   mkdir -p secrets
   cp /path/to/your/features.conf secrets/features.conf
   ```

4. Run client validation:

   ```bash
   ./scripts/setup/01-validate-client.sh
   ```

   **Expected:** All checks print `OK`; exit code 0. The first line is `Cloud provider: eks (EKS)` or `Cloud provider: gke (GKE)`.

   **EKS** also runs EC2 AZ capacity pre-flight for `${NODE_TYPE}` and `${NODE_TYPE_VERTICAL}` in every `AWS_ZONES` entry, plus **Running On-Demand G and VT** quota (`NODE_COUNT × 2` at Lab 1.2 peak). Re-run capacity only: `./scripts/setup/01b-check-ec2-capacity.sh`.

   **GKE** checks `gcloud` auth, `GCP_PROJECT`, and the Container API. It prints quota hints (N2 CPUs, Local SSD) rather than dry-running instance creates.

   **Sample EKS output:**

   ```text
   OK  aws
   OK  kubectl
   OK  eksctl
   ...
   OK  AWS caller: arn:aws:sts::123456789012:assumed-role/shared-account-powerusers-v2/you
   OK  IAM permissions boundary: arn:aws:iam::123456789012:policy/shared-power-users-boundary
   ...
   === EC2 capacity pre-flight (us-east-1, zones: us-east-1c,us-east-1d) ===
   OK  us-east-1c i8g.2xlarge offered in AZ
   OK  us-east-1c i8g.4xlarge offered in AZ
   OK  us-east-1c i8g.2xlarge: 2/2 on-demand dry-runs
   OK  us-east-1c i8g.4xlarge: 2/2 on-demand dry-runs
   ...
   OK  G/VT on-demand quota 128 (need >= 8 at Lab 1.2 peak)
   EC2 capacity pre-flight passed.
   Client validation passed.
   ```

   Re-run EKS capacity only: `./scripts/setup/01b-check-ec2-capacity.sh`

## Verify (pass/fail)

1. **EKS:** `aws sts get-caller-identity` returns Account, Arn, UserId. **GKE:** `gcloud auth print-access-token` succeeds and `GCP_PROJECT` is set.
2. `kubectl krew version` succeeds (akoctl is optional here; install in Lab 0.4)
3. `secrets/features.conf` exists

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| AWS identity fails | `aws sso login` or `aws configure` |
| `FAIL GCP_PROJECT` / gcloud auth | Copy `workshop.env.gke.example`, set `GCP_PROJECT`, run `gcloud auth login` |
| Container API not enabled | `gcloud services enable container.googleapis.com compute.googleapis.com --project=$GCP_PROJECT` |
| `FAIL IAM permissions boundary` | Account requires a boundary that was not found — ask your AWS admins for the policy name, or set `IAM_PERMISSIONS_BOUNDARY` to its ARN |
| `AlreadyExists` on cluster / nodegroup / IAM role | Name already used by someone else in the account — pick a unique `CLUSTER_NAME` |
| krew not found | https://krew.sigs.k8s.io/docs/user-guide/setup/install/ |
| features.conf missing | Obtain from Aerospike licensing portal |
| `FAIL helm` | Path B (`DEPLOY_PATH=helm`) or `NODE_PROVISIONING=karpenter` requires Helm on the client — install it or switch paths |
| `FAIL vendor/storage/...` | Vendored cleanup manifests missing from the repo checkout — re-clone or restore [`vendor/storage/`](../../vendor/storage/) |
| EC2 capacity pre-flight fails (`not offered in AZ` or `InsufficientInstanceCapacity`) | Change `AWS_ZONES` in `workshop.env` to an AZ pair where both `i8g.2xlarge` and `i8g.4xlarge` pass `./scripts/setup/01b-check-ec2-capacity.sh`, then create the cluster |
| `FAIL G/VT on-demand quota` | Quota is below `NODE_COUNT × 2` — request an increase for **Running On-Demand G and VT instances** before Lab 1.2, or lower `NODE_COUNT` |

## Workshop artifacts

- Environment templates: [scripts/env/workshop.env.example](../../scripts/env/workshop.env.example) (EKS) · [scripts/env/workshop.env.gke.example](../../scripts/env/workshop.env.gke.example) (GKE)
- No manifest or Helm YAML in this step — client validation only.

## References

- [Instructor client prerequisites](../../instructor/client-prerequisites.md)

## Teardown / handoff

Proceed to Lab 0.2 — [EKS eksctl](02-eks-cluster.md) (`CLOUD_PROVIDER=eks`, `NODE_PROVISIONING=eksctl`, default), [EKS Karpenter](02-eks-cluster-karpenter.md) (`NODE_PROVISIONING=karpenter`), or [GKE Standard](02-gke-cluster.md) (`CLOUD_PROVIDER=gke`).
