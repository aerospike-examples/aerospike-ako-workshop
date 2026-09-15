# Karpenter Path Walkthrough Checklist

Run the **full main-cluster curriculum** with `NODE_PROVISIONING=karpenter` before signing off the Karpenter path. Lab 2.6 still uses the separate upgrade-lab cluster on eksctl MNG.

Use [walkthrough-checklist.md](walkthrough-checklist.md) for the shared eksctl/Karpenter checklist (Section 0–2.6). This file lists **Karpenter-specific deltas only**.

Update [LAB_REGISTRY.yaml](../LAB_REGISTRY.yaml) `karpenter_validation` when complete (instructor sign-off workflow — do not change per-lab `validation_status` here).

## Pre-flight (Karpenter)

- [ ] `NODE_PROVISIONING=karpenter` in `workshop.env`
- [ ] `KARPENTER_CONSOLIDATION=Off` for live run (optional: `WhenEmpty` for consolidation demo)
- [ ] Helm 3.12+ installed
- [ ] EC2 quota for 4–8× `i8g.2xlarge` + 2× `t3.large` (baseline)
- [ ] EC2 quota for 4–8× `i8g.4xlarge` (Lab 1.2 Phase 2; up to 8 nodes with idle baseline pool)

## Section 0 deltas

- [ ] **0.2** Karpenter bootstrap — controller Ready; ≥4 i8g workload nodes ([02-eks-cluster-karpenter.md](../sections/00-environment-setup/02-eks-cluster-karpenter.md))
- [ ] **0.6** Secrets + validate — `08-validate-environment.sh` passes Karpenter gates

## Section 1 deltas

- [ ] **1.1** Observe `kubectl get nodeclaims -w` during scale 3→5→3
- [ ] **1.2** Additive 4xl NodePool; pods on `i8g.4xlarge`; revision v2; 2× `local-ssd` PVCs per pod

## Section 2 deltas

- [ ] **2.5** Karpenter maintenance — drain + Phase 4 NodeClaim replacement + PVC cleanup; **no blocklist**
- [ ] **2.5 add-on** — do-not-disrupt graduation discussion; three protection layers; `terminationGracePeriod` sizing (instructor-led)

## Path coverage (Karpenter + deploy path)

- [ ] Karpenter + Path A (OLM/kubectl)
- [ ] Karpenter + Path B (Helm) — if offering both deploy paths on Karpenter

## Sign-off

| Field | Value |
|-------|-------|
| Validator | |
| Date | |
| NODE_PROVISIONING | karpenter |
| KARPENTER_VERSION | |
| AKO version tested | |
| K8s version tested | |
| Notes | |

## Record in LAB_REGISTRY

After sign-off, set:

```yaml
karpenter_validation:
  status: validated   # or draft until run
  validated_on: YYYY-MM-DD
  validated_with:
    karpenter: "1.x.x"
    ako: "4.5.0"
    k8s: "1.35"   # match K8S_VERSION in workshop.env
  validator: "<name>"
```

Per-lab `validation_status` for Karpenter runs can be noted in lab entries' `validated_with.node_provisioning: karpenter`.
