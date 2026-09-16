# Walkthrough Validation

Run a full end-to-end walkthrough of every lab on a real EKS environment before delivery.

## Process

1. **Draft** — guide written; `validation_status: draft` in [LAB_REGISTRY.yaml](../LAB_REGISTRY.yaml)
2. **Walkthrough run** — instructor executes every step; note drift in the guide
3. **Fix** — update commands and expected outputs until reproducible
4. **Sign-off** — set `validation_status: validated`, `validated_on` date, and `validated_with` AKO/K8s versions
5. **Refresh** — after AKO or EKS version bumps, re-run affected labs; mark `needs-refresh` until done

## Prerequisites for validation

- Main cluster `my-cluster`:
  - **eksctl path:** baseline per-AZ pools from step 0.2-nodes; vertical pool in Lab 1.2 Phase 2; K8s version from `K8S_VERSION` (default 1.35)
  - **Karpenter path:** system MNG; per-AZ baseline NodePools from step 0.2-nodes; vertical pool `${KARPENTER_NODEPOOL_VERTICAL_NAME}-<zone>` in Lab 1.2 Phase 2 — see [karpenter-walkthrough.md](karpenter-walkthrough.md)
- Upgrade-lab cluster `my-cluster-k8s-upgrade` (3× `i8g.2xlarge` on EKS or 3× `n2-highmem-8` on GKE; K8s versions from `UPGRADE_LAB_K8S_VERSION_*`) for Lab 2.6 only — **always eksctl MNG / GKE node pool**, and only when validating that optional lab (setup step 0.7)
- All-flash cluster `my-cluster-all-flash` (3→4× `i8ge.3xlarge` on EKS or `n2-highmem-16` + 16 Local SSDs on GKE) for Section 4 only — **always eksctl MNG / GKE node pool**, and only when validating that optional section (setup step 0.8)
- Valid `features.conf` at path referenced in `scripts/setup/07-deploy-secrets.sh`
- Both deploy paths (OLM/Helm) validated separately (or document N/A)
- Both node provisioning paths (eksctl/Karpenter) validated separately for main cluster

## Node provisioning validation matrix

| Path | Checklist | Registry key |
|------|-----------|--------------|
| eksctl MNG | [walkthrough-checklist.md](walkthrough-checklist.md) | default |
| Karpenter | [karpenter-walkthrough.md](karpenter-walkthrough.md) | `karpenter_validation` in LAB_REGISTRY |

## Tools

```bash
# Run a lab's verify script block (when defined)
./scripts/validation/run-lab-verify.sh 1.1

# Shared cluster health check
./scripts/verify-cluster.sh

# Lint: confirm every script's relative `source` path resolves
./scripts/validation/validate-script-paths.sh

# Section 4 only: assert the running server has its index on flash
./scripts/labs/validate-all-flash.sh          # 4.1 baseline (3 pods)
./scripts/labs/validate-all-flash.sh 4        # after 4.2
```

## Recording results

Update the lab entry in `LAB_REGISTRY.yaml`:

```yaml
validation_status: validated
validated_on: "2026-07-14"
validated_with:
  ako: "4.5.0"
  k8s: "1.35"   # match K8S_VERSION in workshop.env
  node_provisioning: karpenter   # when applicable
```

For Karpenter path sign-off, also update the `karpenter_validation` block at the bottom of `LAB_REGISTRY.yaml`.

Optionally save command output under `validation/expected/` for diff during refresh.

See [walkthrough-checklist.md](walkthrough-checklist.md) for per-lab checkboxes.
