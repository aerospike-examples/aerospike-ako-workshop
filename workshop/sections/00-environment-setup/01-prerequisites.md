# Lab 0.1 — Prerequisites

| Field | Value |
|-------|-------|
| Lab ID | `0.1` |
| Section | Environment Setup |
| EKS cluster | — (client machine only) |
| Duration | ~15 min |
| Validation status | `draft` |

## Takeaway

The instructor client has all required tools, AWS access, and licensing files before touching EKS.

## Prerequisites

- macOS or Linux workstation (or bastion) with network access to AWS
- Aerospike Enterprise **feature-key file** (`features.conf`)
- AWS account (SSO or access keys) allowed to create EKS clusters, EC2 instances, CloudFormation stacks, and IAM roles

### What `01-validate-client.sh` checks

| Category | Checks |
|----------|--------|
| Required tools | `aws`, `kubectl`, `eksctl`, `git`, `curl`, `bash`, `krew` |
| Conditional tools | `helm` — when `DEPLOY_PATH=helm` **or** `NODE_PROVISIONING=karpenter` (Karpenter controller install) |
| Optional tools | `jq` (recommended), `akoctl` (installed in Lab 0.4) |
| AWS access | `aws sts get-caller-identity`; IAM permissions boundary per `IAM_PERMISSIONS_BOUNDARY`; EC2 key pair `${SSH_PUBLIC_KEY}` in `${AWS_REGION}` |
| Workshop files | `secrets/features.conf`; `vendor/storage/local_volume_provisioner_cleanup.yaml` and `local_volume_provisioner_cleanup_rbac.yaml` |
| Capacity | delegates to [`01b-check-ec2-capacity.sh`](../../scripts/setup/01b-check-ec2-capacity.sh) when everything above passes |

Presence and `--version` are what get verified — the script does not assert minimum tool versions, so check those against [client prerequisites](../../instructor/client-prerequisites.md) yourself.

## Steps

1. Clone the workshop repo and open the `workshop/` directory.

2. Copy environment template:

   ```bash
   cd workshop
   cp scripts/env/workshop.env.example scripts/env/workshop.env
   ```

   If the AWS account is shared with other people, set a unique `CLUSTER_NAME` (and `UPGRADE_LAB_CLUSTER_NAME`) — EKS and IAM names are account-global. If the account only permits role creation with a permissions boundary attached, leave `IAM_PERMISSIONS_BOUNDARY=auto` and set `IAM_PERMISSIONS_BOUNDARY_NAME` to that policy — see [client prerequisites](../../instructor/client-prerequisites.md#shared-aws-accounts-and-iam-permissions-boundaries).

3. Place feature-key file:

   ```bash
   mkdir -p secrets
   cp /path/to/your/features.conf secrets/features.conf
   ```

4. Run client validation (includes EC2 AZ capacity pre-flight for `i8g.2xlarge` and `i8g.4xlarge`):

   ```bash
   ./scripts/setup/01-validate-client.sh
   ```

   **Expected:** All checks print `OK`; exit code 0. Capacity pre-flight confirms each instance type is offered in every `AWS_ZONES` entry, runs `${MIN_NODES_PER_ZONE}` on-demand dry-runs per zone for both `${NODE_TYPE}` and `${NODE_TYPE_VERTICAL}`, and verifies the **Running On-Demand G and VT** quota is at least `NODE_COUNT × 2` (the Lab 1.2 peak of 4× `i8g.2xlarge` plus 4× `i8g.4xlarge`). An unreadable quota prints `SKIP` — verify it manually in that case.

   **Sample output:**

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

   Re-run capacity only: `./scripts/setup/01b-check-ec2-capacity.sh`

## Verify (pass/fail)

1. `aws sts get-caller-identity` returns Account, Arn, UserId
2. `kubectl krew version` succeeds (akoctl is optional here; install in Lab 0.4)
3. `secrets/features.conf` exists

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| AWS identity fails | `aws sso login` or `aws configure` |
| `FAIL IAM permissions boundary` | Account requires a boundary that was not found — ask your AWS admins for the policy name, or set `IAM_PERMISSIONS_BOUNDARY` to its ARN |
| `AlreadyExists` on cluster / nodegroup / IAM role | Name already used by someone else in the account — pick a unique `CLUSTER_NAME` |
| krew not found | https://krew.sigs.k8s.io/docs/user-guide/setup/install/ |
| features.conf missing | Obtain from Aerospike licensing portal |
| `FAIL helm` | Path B (`DEPLOY_PATH=helm`) or `NODE_PROVISIONING=karpenter` requires Helm on the client — install it or switch paths |
| `FAIL vendor/storage/...` | Vendored cleanup manifests missing from the repo checkout — re-clone or restore [`vendor/storage/`](../../vendor/storage/) |
| EC2 capacity pre-flight fails (`not offered in AZ` or `InsufficientInstanceCapacity`) | Change `AWS_ZONES` in `workshop.env` to an AZ pair where both `i8g.2xlarge` and `i8g.4xlarge` pass `./scripts/setup/01b-check-ec2-capacity.sh`, then create the cluster |
| `FAIL G/VT on-demand quota` | Quota is below `NODE_COUNT × 2` — request an increase for **Running On-Demand G and VT instances** before Lab 1.2, or lower `NODE_COUNT` |

## Workshop artifacts

- Environment template: [scripts/env/workshop.env.example](../../scripts/env/workshop.env.example)
- No manifest or Helm YAML in this step — client validation only.

## References

- [Instructor client prerequisites](../../instructor/client-prerequisites.md)

## Teardown / handoff

Proceed to Lab 0.2 — [eksctl managed nodegroups](02-eks-cluster.md) (`NODE_PROVISIONING=eksctl`, default) or [Karpenter](02-eks-cluster-karpenter.md) (`NODE_PROVISIONING=karpenter`).
