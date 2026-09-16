# Lab 3.3 — mTLS and PKI Authentication

| Field              | Value |
| ------------------ | ----- |
| Lab ID             | `3.3` |
| Section            | Security & Authentication |
| Cluster            | `my-cluster` |
| Aerospike cluster  | `aerocluster` |
| AKO min version    | `4.2.0` |
| Aerospike baseline | 3-node **8.1.0.0** with mTLS → PKI → **PKIOnly** |
| Deploy path        | both |
| Duration           | ~30 min |
| Validation status  | `draft` |

## Takeaway

Escalate service TLS to **mTLS** (client cert required), then migrate from password auth to **PKI** and finally **`PKIOnly`**.

## Prerequisites

- Lab **3.2** (cluster on standard-auth TLS)

## Node requirements

| Item | Value |
|------|-------|
| Instance | `i8g.2xlarge` baseline pool (same as Section 1) |
| Reset | **Skip** (default) — escalates mTLS on existing cluster; reuses node pools |
| Node pools | Unchanged from Labs 3.1–3.2 |

## Phase A — Deploy mTLS + connect with password

Lab **3.2** is the prep (standard-auth TLS). Upgrade in place to mTLS:

**What:** Deploy mTLS cluster config (client cert required on port 4333).
**Credential / mode:** mTLS enabled; password auth still available until Phase C.
**Run:**

```bash
./scripts/labs/deploy-cluster-tls-mtls.sh        # Path A
./scripts/labs/deploy-cluster-tls-mtls-helm.sh   # Path B
```

**Expect:** Cluster reaches `phase=Completed`; `tls-authenticate-client: any` active.

### Deploy note — schema change vs cert content

Changes in this lab to `network.tls[]`, `tls-authenticate-client`, or `authMode: PKIOnly` are **CR schema changes** → AKO performs a **rolling restart** of Aerospike pods.

Later labs (**3.4** and **3.5**) rotate **certificate file content** or revoke by serial number — a different mechanism, mostly **hitless at the Aerospike layer** (server file reload and PKI overlap/blacklist). Keep this distinction in mind when comparing rolling restarts here to uninterrupted workload in Lab 3.4.

`aerocluster` is a headless Kubernetes Service (`ClusterIP: None`) — it only resolves inside the cluster network, not from your workstation. Run `asadm` from a short-lived debug pod with the CA and app client cert secrets mounted; `--rm --attach` prints output and cleans up the pod automatically.

**What:** Connect with client cert **and** password — both are required in this phase.
**Credential / mode:** mTLS port **4333**; client cert `app.pem` (`tls-client-app-secret`) + password (`app` / `app123`).
**Run:**

```bash
kubectl -n aerospike run aerospike-tool-mtls --rm --attach --restart=Never \
  --image=aerospike/aerospike-tools:latest \
  --overrides='{"spec":{"containers":[{"name":"aerospike-tool-mtls","image":"aerospike/aerospike-tools:latest",
    "command":["asadm"],
    "args":["-h","aerocluster:aerocluster:4333","--tls-enable","--tls-cafile","/etc/aerospike/tls/ca/cacert.pem","--tls-certfile","/etc/aerospike/tls/client/app.pem","--tls-keyfile","/etc/aerospike/tls/client/app.key","-U","app","-P","app123","-e","info"],
    "volumeMounts":[{"name":"tls-ca","mountPath":"/etc/aerospike/tls/ca","readOnly":true},{"name":"tls-client-app","mountPath":"/etc/aerospike/tls/client","readOnly":true}]}],
    "volumes":[{"name":"tls-ca","secret":{"secretName":"tls-ca-secret"}},{"name":"tls-client-app","secret":{"secretName":"tls-client-app-secret"}}]}}'
```

**Expect:** `info` succeeds — client cert and password both accepted.

**Negative check (Phase A):** Retry the Lab 3.2 TLS-only command (CA + password, **no client cert**). Connection should **fail** — mTLS now requires a client cert.

## Phase B — PKI auth (no password)

**What:** Authenticate using the client cert as identity — no password.
**Credential / mode:** mTLS port **4333**; client cert `app.pem` + `--auth PKI` (no `-U`/`-P`).
**Run:**

```bash
kubectl -n aerospike run aerospike-tool-pki --rm --attach --restart=Never \
  --image=aerospike/aerospike-tools:latest \
  --overrides='{"spec":{"containers":[{"name":"aerospike-tool-pki","image":"aerospike/aerospike-tools:latest",
    "command":["asadm"],
    "args":["-h","aerocluster:aerocluster:4333","--tls-enable","--tls-cafile","/etc/aerospike/tls/ca/cacert.pem","--tls-certfile","/etc/aerospike/tls/client/app.pem","--tls-keyfile","/etc/aerospike/tls/client/app.key","--auth","PKI","-e","info"],
    "volumeMounts":[{"name":"tls-ca","mountPath":"/etc/aerospike/tls/ca","readOnly":true},{"name":"tls-client-app","mountPath":"/etc/aerospike/tls/client","readOnly":true}]}],
    "volumes":[{"name":"tls-ca","secret":{"secretName":"tls-ca-secret"}},{"name":"tls-client-app","secret":{"secretName":"tls-client-app-secret"}}]}}'
```

**Expect:** `info` succeeds without a password — cert CN (`app`) is the identity.

**What:** Start background workload using PKI auth.
**Credential / mode:** `tls-client-app-secret` / `app.pem` via `--pki` flag.
**Run:**

```bash
./scripts/labs/run-lab-workload.sh --pki start
./scripts/labs/load-data.sh --pki
```

**Expect:** asbench Job running; TPS reported in logs with no auth errors.

## Phase C — PKIOnly

**What:** Remove password auth path for all users — PKI cert is the only way in.
**Credential / mode:** Same client certs; CR change sets `authMode: PKIOnly` (no `secretName` on users).
**Run:**

```bash
./scripts/labs/deploy-cluster-tls-mtls-pki-only.sh        # Path A
./scripts/labs/deploy-cluster-tls-mtls-pki-only-helm.sh   # Path B
```

Confirm PKI login for `admin` in a **second terminal** before applying — `PKIOnly` is **one-way**.

PKIOnly users must not set `secretName` — identity comes from the client cert CN, not a password secret. AKO's admission webhook rejects any user that specifies both.

**Negative check (Phase C):** Retry the Phase A command (client cert + password `-P app123`). Login should fail with `No credential or bad credential` — password path removed.

**Expect:** Password login fails for migrated users; PKI login succeeds; exporter sidecar scrapes metrics on `:9145`.

## Verify

| Phase | Credential used | Pass criteria |
|-------|-----------------|---------------|
| A | Client cert `app.pem` + password | Client cert required; password still works |
| B | Client cert `app.pem` only (`--auth PKI`) | `--auth PKI` succeeds without `-P` |
| C | Client cert only (PKIOnly) | Password rejected; PKI works; exporter healthy |

## Workshop artifacts

Workshop YAML used in this lab (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **mTLS (Phase A/B):**
  - Path A: [manifests/disk-cluster-tls-mtls.yaml](../../manifests/disk-cluster-tls-mtls.yaml) (default) · [manifests/dim-cluster-tls-mtls.yaml](../../manifests/dim-cluster-tls-mtls.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) + [helm/overlay-disk-cluster-tls-mtls-values.yaml](../../helm/overlay-disk-cluster-tls-mtls-values.yaml) (default) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) + [helm/overlay-dim-cluster-tls-mtls-values.yaml](../../helm/overlay-dim-cluster-tls-mtls-values.yaml) (`--dim`)
- **PKIOnly (Phase C):**
  - Path A: [manifests/disk-cluster-tls-mtls-pki-only.yaml](../../manifests/disk-cluster-tls-mtls-pki-only.yaml) (default) · [manifests/dim-cluster-tls-mtls-pki-only.yaml](../../manifests/dim-cluster-tls-mtls-pki-only.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) + [helm/overlay-disk-cluster-tls-mtls-pki-only-values.yaml](../../helm/overlay-disk-cluster-tls-mtls-pki-only-values.yaml) (default) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) + [helm/overlay-dim-cluster-tls-mtls-pki-only-values.yaml](../../helm/overlay-dim-cluster-tls-mtls-pki-only-values.yaml) (`--dim`)
- Deploy scripts: [scripts/labs/deploy-cluster-tls-mtls.sh](../../scripts/labs/deploy-cluster-tls-mtls.sh) · [scripts/labs/deploy-cluster-tls-mtls-helm.sh](../../scripts/labs/deploy-cluster-tls-mtls-helm.sh) · [scripts/labs/deploy-cluster-tls-mtls-pki-only.sh](../../scripts/labs/deploy-cluster-tls-mtls-pki-only.sh) · [scripts/labs/deploy-cluster-tls-mtls-pki-only-helm.sh](../../scripts/labs/deploy-cluster-tls-mtls-pki-only-helm.sh)
- Workload: [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh) · [scripts/labs/load-data.sh](../../scripts/labs/load-data.sh)

## References

- [PKI authentication](https://aerospike.com/docs/server/operations/configure/security/pki/)
- [Prometheus exporter PKI](https://aerospike.com/docs/tools/monitorstack/)
