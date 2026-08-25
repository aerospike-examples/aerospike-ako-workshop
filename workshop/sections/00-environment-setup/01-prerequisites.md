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

   **Expected:** All checks print `OK`; exit code 0. Capacity pre-flight verifies `${MIN_NODES_PER_ZONE}` on-demand dry-runs per zone for both `${NODE_TYPE}` and `${NODE_TYPE_VERTICAL}`.

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
   OK  us-east-1c i8g.2xlarge: 2/2 on-demand dry-runs
   OK  us-east-1c i8g.4xlarge: 2/2 on-demand dry-runs
   ...
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
| EC2 capacity pre-flight fails (`InsufficientInstanceCapacity`) | Change `AWS_ZONES` in `workshop.env` to an AZ pair where both `i8g.2xlarge` and `i8g.4xlarge` pass `./scripts/setup/01b-check-ec2-capacity.sh`, then create the cluster |

## Workshop artifacts

- Environment template: [scripts/env/workshop.env.example](../../scripts/env/workshop.env.example)
- No manifest or Helm YAML in this step — client validation only.

## References

- [Instructor client prerequisites](../../instructor/client-prerequisites.md)

## Teardown / handoff

Proceed to [Lab 0.2 — EKS cluster](02-eks-cluster.md).
