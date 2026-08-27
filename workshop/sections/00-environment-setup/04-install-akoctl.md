# Lab 0.4 — Install akoctl and RBAC

| Field | Value |
|-------|-------|
| Lab ID | `0.4` |
| Section | Environment Setup |
| EKS cluster | `my-cluster` |
| Deploy path | both |
| Duration | ~10 min |
| Validation status | `draft` |

## Takeaway

`kubectl akoctl auth create` grants AKO the namespace RBAC needed to deploy Aerospike clusters.

## Prerequisites

- Lab 0.3 complete (AKO installed)
- krew installed on the client (checked in Lab 0.1; the script fails fast without it)

## Steps

1. Install akoctl via krew:

   ```bash
   ./scripts/setup/04-install-akoctl.sh
   ```

   The script adds the krew index `akoctl` from `https://github.com/aerospike/aerospike-kubernetes-operator-ctl.git`, installs or upgrades the `akoctl/akoctl` plugin, and then runs `kubectl akoctl auth create -n ${NAMESPACE}` for you — no separate RBAC command is needed.

2. Verify plugin:

   ```bash
   kubectl krew list | grep akoctl
   ```

   **Expected:** `akoctl` listed.

3. Confirm RoleBindings in aerospike namespace:

   ```bash
   kubectl get rolebinding,clusterrolebinding -n aerospike | grep aerospike
   ```

   **Expected:** Bindings created by akoctl.

## Verify (pass/fail)

```bash
kubectl akoctl auth create -n aerospike
```

**Pass:** Command succeeds (idempotent if already created).

## Observe

- akoctl creates RBAC for operator service account in target namespace
- Same step required for both OLM and Helm paths

## Teardown / handoff

Proceed to [Lab 0.5 — Storage layer](05-storage-layer.md).

For a full akoctl walkthrough (`collectinfo` log collection; optional configuration flags and auth), see [Lab 2.1](../02-maintenance-and-upgrade/01-akoctl.md) after a cluster is deployed.

## Workshop artifacts

- No workshop manifest or Helm YAML — RBAC via [`scripts/setup/04-install-akoctl.sh`](../../scripts/setup/04-install-akoctl.sh) only.

## References

- [akoctl](https://aerospike.com/docs/kubernetes/manage/akoctl/)
