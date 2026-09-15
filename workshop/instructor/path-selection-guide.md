# Path Selection Guide

Pick **one deploy path** at Section 0 and stay on it for the entire training session.

Also pick **one node provisioning path** for the main cluster (`my-cluster`) and do not switch mid-session.

## Path A — kubectl / OLM (default)

**Use when:**

- Automated bootstrap via [`scripts/setup/setup-all.sh`](../scripts/setup/setup-all.sh)
- Teaching OperatorHub and InstallPlan lifecycle
- Audience works with OpenShift or OLM-centric platforms

**Lab changes:** `kubectl apply -f manifests/`

**AKO upgrades:** OLM InstallPlan approval per version (Lab 2.2)

## Path B — Helm

**Use when:**

- Audience deploys everything via Helm
- Teaching values-driven config and `helm diff`
- GitOps workflows (see [AKO deployment docs](https://aerospike.com/docs/kubernetes/manage/deploy/deploy-aerospike-cluster))

**Lab changes:** `helm upgrade -f helm/*-values.yaml`

**AKO upgrades:** CRD replace + `helm upgrade --version` per step (Lab 2.2)

## Node provisioning — eksctl MNG (default)

**Use when:**

- Teaching classic EKS managed nodegroups
- Demonstrating `k8sNodeBlockList` in Lab 2.5 (eksctl-only)
- Simplest bootstrap; uses workshop setup scripts

**Bootstrap:** `./scripts/setup/02-bootstrap-eks.sh` with `NODE_PROVISIONING=eksctl`

**Local NVMe init:** `nvme-bootstrap` DaemonSet (automatic on every node, same as Karpenter)

## Node provisioning — Karpenter (optional)

**Use when:**

- Audience runs Karpenter or cluster autoscaler patterns in production
- Teaching dynamic node provisioning during scale-up labs
- Full main curriculum including rack labs (`ssd` workdir + `local-ssd` block namespace data on i8g nodes)

**Rack labs (1.2, 1.3):** both end on the vertical `i8g.4xlarge` pool (`workshop.aerospike.com/node-pool=vertical`). Lab 1.2 uses rack **revision** (same rack IDs); Lab 1.3 uses rack **replacement** (racks 3+4 replace 1+2) — standalone, does not require 1.2 v2.

**Bootstrap:** `./scripts/setup/02-bootstrap-eks.sh` with `NODE_PROVISIONING=karpenter`

**Local NVMe init:** `nvme-bootstrap` DaemonSet (automatic on every new node)

**Not supported on Karpenter path:**

- Lab 2.5 **`k8sNodeBlockList`** — incompatible with Karpenter node affinity ([AKO #305](https://github.com/aerospike/aerospike-kubernetes-operator/issues/305)). Use drain + safe eviction only.
- Lab 2.6 upgrade-lab cluster — always eksctl MNG (separate cluster)

**Lab 2.5 Karpenter add-on (~15m):** optional instructor discussion on graduating from `karpenter.sh/do-not-disrupt` to voluntary disruption — see [05-k8s-node-maintenance-karpenter.md](../sections/02-maintenance-and-upgrade/05-k8s-node-maintenance-karpenter.md#add-on--graduating-from-do-not-disrupt-to-karpenter-native-disruption-15-min). Covers `terminationGracePeriod` sizing (workshop default 600s).

**During live demos:** set `KARPENTER_CONSOLIDATION=Off` in `workshop.env` to reduce node churn.

## Do not mix paths mid-session

| Operation | Path A | Path B |
|-----------|--------|--------|
| Operator install | OLM | Helm + cert-manager |
| Cluster deploy | kubectl apply | helm install/upgrade |
| Operator upgrade | InstallPlan | CRD replace + helm upgrade |
| Teardown | kubectl delete CR | helm uninstall |

| Operation | eksctl MNG | Karpenter |
|-----------|------------|-----------|
| Node bootstrap | Fixed MNG i8g×4 | NodePool + min 4 i8g |
| NVMe disk init | nvme-bootstrap DS | nvme-bootstrap DS |
| Scale-up observe | ASG/MNG only | `kubectl get nodeclaims -w` |
| Lab 2.5 blocklist | Yes | **No** |
| Lab 2.6 cluster | eksctl MNG | eksctl MNG (unchanged) |

## Environment variables

```bash
# workshop.env
DEPLOY_PATH=olm              # olm | helm
NODE_PROVISIONING=eksctl     # eksctl | karpenter
```

[setup-all.sh](../scripts/setup/setup-all.sh) dispatches on lab step and `DEPLOY_PATH`. [02-bootstrap-eks.sh](../scripts/setup/02-bootstrap-eks.sh) dispatches on `NODE_PROVISIONING`.
