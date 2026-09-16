# Lab 3.5 — Live Client Credential Rotation

| Field              | Value |
| ------------------ | ----- |
| Lab ID             | `3.5` |
| Section            | Security & Authentication |
| Cluster            | `my-cluster` |
| Aerospike cluster  | `aerocluster` |
| AKO min version    | `4.2.0` |
| Aerospike baseline | 3-node **8.1.0.0** mTLS + PKIOnly (continues from Lab 3.4) |
| Deploy path        | both |
| Duration           | ~25 min |
| Validation status  | `draft` |

## Takeaway

Rotate client credentials with **overlap**: deploy v2 cert, roll workload, then **`cert-blacklist`** to revoke v1 — authentication stays available throughout the overlap window.

## Background

Client credential rotation is an **Aerospike PKI procedure** on top of K8s secret delivery:

1. **Overlap** — v1 and v2 are both signed by the same CA, same CN (`app`), different serials. Aerospike accepts both until v1 is revoked.
2. **Roll clients to v2** — patch `tls-client-app-secret` and restart the workload Job so it mounts the new cert material.
3. **Revoke v1** — set `network.tls[].cert-blacklist` with the v1 serial. This is native **Aerospike** revocation, not an AKO feature.

[`apply-cert-blacklist.sh`](../../scripts/labs/apply-cert-blacklist.sh) **appends** the v1 serial to **`revoked.txt`** (preserving prior lines) and patches **`tls-cert-blacklist-secret`**. Step 4 then applies the blacklist **cluster spec** (blacklist volume + `network.tls[].cert-blacklist`) on your deploy path — Path A or Path B deploy scripts below. First-time blacklist setup may reconcile differently from a pure secret patch in Lab 3.4.

**Scope:** this lab rotates the **`app`** client cert only. `admin`, `exporter`, and `ako-operator` use separate secrets and are not rotated here.

### Secret updates and pod recreation

Not every step in this lab affects Aerospike DB pods the same way:

| Step | What changes | Aerospike DB pods recreated? | What restarts instead |
|------|----------------|------------------------------|------------------------|
| `rotate-client-cert.sh --save-v1` | `tls-client-app-secret` data | **No** — app client secret is not mounted on DB pods | Nothing (overlap: v1 still valid server-side) |
| `rotate-client-workload.sh` | Workload picks up v2 from Secret | **No** | **asbench Job** stop/start (intentional) |
| `apply-cert-blacklist.sh` | `tls-cert-blacklist-secret` data only | **No** — blacklist secret is not on DB pods until Step 4 deploy | Nothing |
| `deploy-cluster-tls-mtls-blacklist*.sh` | Blacklist volume + `network.tls[].cert-blacklist` | **Possibly yes** — first-time blacklist is a **CR schema change** | AKO may rolling-restart to apply new volume/config |

Patching `tls-client-app-secret` alone follows the same Kubernetes pattern as Lab 3.4: the kubelet updates mounted files on pods that reference the Secret. The workshop workload Job is restarted separately so asbench reads the new cert — that is **client** pod recreation, not an AKO-driven DB pod roll.

### What the rotation scripts do

Steps 1–2 use two lab wrappers (not AKO rotation APIs):

#### `rotate-client-cert.sh [--save-v1]`

| Flag / step | Behavior |
|-------------|----------|
| `--save-v1` (this lab) | Copy `app.pem`/`app.key` → `app-v1.pem`/`app-v1.key`; create/update **`tls-client-app-v1-secret`** for Step 3 overlap demo |
| (always) | [`generate-workshop-pki.sh --client-app-only`](../../scripts/setup/tls/generate-workshop-pki.sh) → new `app.pem`/`app.key` on the workstation |
| (always) | `kubectl apply` **`tls-client-app-secret`** with v2 material (same secret name) |

- **Does not** restart the asbench Job — the running workload still uses v1 until Step 2.
- **Does not** mount the app client secret on DB pods (see table above).
- Without `--save-v1`, the script still patches v2 into the secret and prints a hint to run `rotate-client-workload.sh`.

#### `rotate-client-workload.sh`

- [`run-lab-workload.sh stop`](../../scripts/labs/run-lab-workload.sh) (tolerates failure if already stopped).
- [`run-lab-workload.sh --pki start`](../../scripts/labs/run-lab-workload.sh) so the Job remounts **`tls-client-app-secret`** (v2).
- **Only** the asbench Job restarts; Aerospike DB pods are untouched (TPS may dip briefly).

```text
rotate-client-cert.sh --save-v1 → tls-client-app-v1-secret + tls-client-app-secret (v2)
rotate-client-workload.sh       → asbench Job stop/start (reads v2 secret)
```

### What Step 4 does

Step 4 runs **only after** Steps 2–3 prove v2 works and v1 still authenticates during overlap. It closes the overlap window by revoking v1 **server-side** via Aerospike **`network.tls[].cert-blacklist`** — not by deleting the old secret or rotating the CA. The v1 PEM can remain in **`tls-client-app-v1-secret`**; the server rejects client connections whose cert serial appears in `revoked.txt`.

**1.** [`apply-cert-blacklist.sh`](../../scripts/labs/apply-cert-blacklist.sh) — blacklist file + secret only:

| Order | Action | Effect |
|-------|--------|--------|
| 1 | Read cert path (`--cert`, default `secrets/tls/app-v1.pem`) | Must exist (from Step 1 `--save-v1`) |
| 2 | `openssl x509 … -serial` → normalized hex serial | Printed to stdout for verification |
| 3 | Append serial to **`secrets/tls/revoked.txt`**; `kubectl apply` **`tls-cert-blacklist-secret`** | Delivers updated blacklist file to the cluster (one hex serial per line) |

**2.** Deploy blacklist cluster spec (path-specific — see [Deploy path](#deploy-path)):

| Order | Action | Effect |
|-------|--------|--------|
| 4 | Path A: [`deploy-cluster-tls-mtls-blacklist.sh`](../../scripts/labs/deploy-cluster-tls-mtls-blacklist.sh) · Path B: [`deploy-cluster-tls-mtls-blacklist-helm.sh`](../../scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh) | Adds volume mount + `network.tls[].cert-blacklist` (does **not** re-run on serial-only updates) |

The blacklist manifest (vs PKI-only from Lab 3.3) adds:

- Storage volume **`tls-cert-blacklist`** — mounts `tls-cert-blacklist-secret` at `/etc/aerospike/tls/blacklist`
- `aerospikeConfig.network.tls[].cert-blacklist: /etc/aerospike/tls/blacklist/revoked.txt`

- **Not** a rotate script — does not regenerate certs or patch `tls-client-app-secret`.
- **Is** a **CR spec change** — AKO may **rolling-restart** DB pods on first blacklist apply (see table above); unlike Lab 3.4 secret-only patches.
- Blacklists **only** the serial from `--cert` (v1 in this lab); v2 is unaffected.

```text
apply-cert-blacklist.sh → revoked.txt → tls-cert-blacklist-secret
deploy-cluster-tls-mtls-blacklist*.sh → volume + cert-blacklist config → v1 serial rejected on server
```

## Why access is preserved

- **Order matters:** prove v2 works **before** blacklisting v1. The overlap window is intentional.
- **Auth continuity:** during overlap, either certificate authenticates as user `app`. Apply the blacklist only after the v2 workload connects successfully.
- **Same CA and CN** — clients keep the same trust store and username mapping; only the certificate serial changes.

## Prerequisites

- Lab **3.4** (or **3.3** with PKI workload running)

## Node requirements

| Item | Value |
|------|-------|
| Instance | `i8g.2xlarge` baseline pool (same as Section 1) |
| Reset | **Skip** (default) — client cert overlap on live cluster; reuses node pools |
| Node pools | Unchanged from Labs 3.1–3.4 |

## Deploy path

Stay on the **same path** you chose in Section 0 (`DEPLOY_PATH` in [workshop.env](../../scripts/env/workshop.env.example) — see [Section 00 README](../00-environment-setup/README.md)).

- **Steps 1–3:** identical for Path A and Path B (client Secret patches + asbench Job restart).
- **Step 4:** (1) [`apply-cert-blacklist.sh`](../../scripts/labs/apply-cert-blacklist.sh) — serial + `tls-cert-blacklist-secret` only; (2) blacklist **cluster spec** on your path:

```bash
./scripts/labs/deploy-cluster-tls-mtls-blacklist.sh        # Path A
./scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh   # Path B
```

Run step (2) once when enabling blacklist on the cluster (after step 1 in the same Step 4). Re-running step (1) with a corrected serial does not require step (2) again if the blacklist volume and `network.tls[].cert-blacklist` are already applied.

## Phase 0 — Prepare lab

**What:** Start PKI workload on the current (v1) client cert before rotation.
**Credential / mode:** Client cert `app.pem` (v1) via `--pki`.
**Run:**

```bash
./scripts/labs/prepare-lab.sh 3.5 --skip-reset
./scripts/labs/run-lab-workload.sh --pki start
```

**Expect:** asbench Job running with v1 cert; steady TPS.

## Steps

### Step 1 — Save v1, generate v2

**What:** Copy current cert to `app-v1.pem`; generate new `app.pem` (v2); patch `tls-client-app-secret`. See [What the rotation scripts do](#what-the-rotation-scripts-do).
**Credential / mode:** v1 saved to `secrets/tls/app-v1.pem` + `tls-client-app-v1-secret`; v2 active in `tls-client-app-secret`.
**Run:**

```bash
./scripts/setup/tls/rotate-client-cert.sh --save-v1
```

The script saves v1, deploys `tls-client-app-v1-secret`, generates v2, and patches `tls-client-app-secret`. Compare serials:

```bash
echo "v1 (saved):" && openssl x509 -in secrets/tls/app-v1.pem -noout -serial
echo "v2 (active):" && openssl x509 -in secrets/tls/app.pem -noout -serial
```

**Expect:** Two different serials; script confirms "Server accepts both until blacklist is applied". Workload still uses v1 until Step 2.

### Step 2 — Roll workload to v2

**What:** Stop and restart the asbench Job so it mounts v2 from `tls-client-app-secret`. See [What the rotation scripts do](#what-the-rotation-scripts-do).
**Credential / mode:** Workload switches from v1 (`app-v1.pem`) to v2 (`app.pem`).
**Run:**

```bash
./scripts/labs/rotate-client-workload.sh
./scripts/labs/run-lab-workload.sh status
```

**Expect:** TPS resumes with no auth errors — workload now authenticates with v2. Server still accepts v1 too (overlap window open).

### Step 2b — Confirm v2 with asadm

**What:** Interactive PKI login using **v2** cert material from the cluster secret (same trust path as production clients mounting `tls-client-app-secret`).
**Credential / mode:** Client cert **v2** from **`tls-client-app-secret`**; PKI on port **4333** (same as Lab 3.3).
**Run:**

```bash
kubectl -n aerospike run aerospike-tool-v2 --rm --attach --restart=Never \
  --image=aerospike/aerospike-tools:latest \
  --overrides='{"spec":{"containers":[{"name":"aerospike-tool-v2","image":"aerospike/aerospike-tools:latest",
    "command":["asadm"],
    "args":["-h","aerocluster:aerocluster:4333","--tls-enable","--tls-cafile","/etc/aerospike/tls/ca/cacert.pem","--tls-certfile","/etc/aerospike/tls/client/app.pem","--tls-keyfile","/etc/aerospike/tls/client/app.key","--auth","PKI","-e","info"],
    "volumeMounts":[{"name":"tls-ca","mountPath":"/etc/aerospike/tls/ca","readOnly":true},{"name":"tls-client-app","mountPath":"/etc/aerospike/tls/client","readOnly":true}]}],
    "volumes":[{"name":"tls-ca","secret":{"secretName":"tls-ca-secret"}},{"name":"tls-client-app","secret":{"secretName":"tls-client-app-secret"}}]}}'
```

**Expect:** `info` succeeds — v2 serial authenticates as user `app`. Step 3 next proves v1 **also** still works during overlap.

### Step 3 — Prove overlap: v1 still works

**What:** Connect with the **saved v1 cert** while the v2 workload from Step 2 is still running — proves both serials are valid server-side.
**Credential / mode:** Client cert **v1** (`app-v1.pem` from `tls-client-app-v1-secret`); PKI auth only.
**Run:**

```bash
kubectl -n aerospike run aerospike-tool-v1 --rm --attach --restart=Never \
  --image=aerospike/aerospike-tools:latest \
  --overrides='{"spec":{"containers":[{"name":"aerospike-tool-v1","image":"aerospike/aerospike-tools:latest",
    "command":["asadm"],
    "args":["-h","aerocluster:aerocluster:4333","--tls-enable","--tls-cafile","/etc/aerospike/tls/ca/cacert.pem","--tls-certfile","/etc/aerospike/tls/client/app.pem","--tls-keyfile","/etc/aerospike/tls/client/app.key","--auth","PKI","-e","info"],
    "volumeMounts":[{"name":"tls-ca","mountPath":"/etc/aerospike/tls/ca","readOnly":true},{"name":"tls-client-v1","mountPath":"/etc/aerospike/tls/client","readOnly":true}]}],
    "volumes":[{"name":"tls-ca","secret":{"secretName":"tls-ca-secret"}},{"name":"tls-client-v1","secret":{"secretName":"tls-client-app-v1-secret"}}]}}'
```

**Expect:** PKI login succeeds with v1 — overlap confirmed. Both v1 and v2 authenticate as user `app` at the same time.

### Step 4 — Blacklist v1 serial

**What:** Revoke v1 server-side: blacklist secret, then deploy path-specific cluster spec. See [What Step 4 does](#what-step-4-does).
**Credential / mode:** Server rejects v1 serial; v2 still trusted.
**Run:**

```bash
./scripts/labs/apply-cert-blacklist.sh --cert secrets/tls/app-v1.pem
cat secrets/tls/revoked.txt

./scripts/labs/deploy-cluster-tls-mtls-blacklist.sh        # Path A
./scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh   # Path B
```

**Expect:** Script prints the blacklisted serial (matches v1 from Step 1). `revoked.txt` contains that serial. Deploy script reconciles blacklist volume + `network.tls[].cert-blacklist` (brief rolling restart possible on first apply). v2 workload and Step 2b asadm remain valid. Step 5 re-proves v1 is rejected.

### Step 5 — Prove v1 rejected

**What:** Re-run the **same** Step 3 command — v1 should now fail.
**Credential / mode:** Client cert **v1** (`app-v1.pem`) — same as Step 3.
**Run:** Repeat the `kubectl run aerospike-tool-v1 …` command from Step 3.

**Expect:** Login **fails** (`Not able to connect` or auth error). v2 workload from Step 2 still running — run `./scripts/labs/run-lab-workload.sh status` to confirm TPS. Optionally re-run the Step 2b `aerospike-tool-v2` command — v2 PKI login should still succeed.

## Verify

| Step | Check | Pass criteria |
|------|-------|---------------|
| 1 | Two serials exist | v1 and v2 serials differ; script confirms overlap window |
| 2 | Workload on v2 | TPS resumes after Job restart; no auth errors |
| 2b | v2 asadm | `info` succeeds with `tls-client-app-secret` (v2 serial) |
| 3 | Overlap proof | v1 PKI login **succeeds** while v2 workload runs |
| 4 | Blacklist applied | Script prints v1 serial; `revoked.txt` matches v1 serial |
| 5 | v1 revoked | Same Step 3 command **fails**; v2 workload (and optional Step 2b asadm) still healthy |

True zero-TPS client rollover would require overlapping clients (two Jobs) or application-level reconnect logic — out of scope for this lab.

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| v1 still works after blacklist | Wrong serial in `revoked.txt` — re-run `apply-cert-blacklist.sh` with correct `--cert` path |
| Aerospike pods rolled during client cert patch | Unexpected if only `tls-client-app-secret` changed — check for accidental CR edits |
| Aerospike pods rolled during blacklist step | Expected on first blacklist CR apply — plan for brief reconcile; auth overlap should cover client access |
| Blacklist has no effect on Path B cluster | Used Path A `kubectl apply` on a Helm-managed release, or skipped deploy script after secret — run [`deploy-cluster-tls-mtls-blacklist-helm.sh`](../../scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh) |

## Workshop artifacts

- [scripts/setup/tls/rotate-client-cert.sh](../../scripts/setup/tls/rotate-client-cert.sh) — overlap rotation (use `--save-v1`)
- [scripts/labs/rotate-client-workload.sh](../../scripts/labs/rotate-client-workload.sh) — restart Job with new secret
- [scripts/labs/apply-cert-blacklist.sh](../../scripts/labs/apply-cert-blacklist.sh) — append serial to `revoked.txt` + `tls-cert-blacklist-secret` (no cluster spec change)
- [scripts/labs/run-lab-workload.sh](../../scripts/labs/run-lab-workload.sh) — background PKI workload (`--pki`)

Workshop YAML used in Step 4 (Path A = `kubectl apply`; Path B = `helm upgrade -f`):

- **Cert blacklist (Step 4):**
  - Path A: [manifests/disk-cluster-tls-mtls-blacklist.yaml](../../manifests/disk-cluster-tls-mtls-blacklist.yaml) (default) · [manifests/dim-cluster-tls-mtls-blacklist.yaml](../../manifests/dim-cluster-tls-mtls-blacklist.yaml) (`--dim`)
  - Path B: [helm/base-disk-cluster-values.yaml](../../helm/base-disk-cluster-values.yaml) + [helm/overlay-disk-cluster-tls-mtls-blacklist-values.yaml](../../helm/overlay-disk-cluster-tls-mtls-blacklist-values.yaml) (default) · [helm/base-dim-cluster-values.yaml](../../helm/base-dim-cluster-values.yaml) + [helm/overlay-dim-cluster-tls-mtls-blacklist-values.yaml](../../helm/overlay-dim-cluster-tls-mtls-blacklist-values.yaml) (`--dim`)
- Deploy scripts: [scripts/labs/deploy-cluster-tls-mtls-blacklist.sh](../../scripts/labs/deploy-cluster-tls-mtls-blacklist.sh) · [scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh](../../scripts/labs/deploy-cluster-tls-mtls-blacklist-helm.sh)

## Teardown

End of Section 3: run [`teardown-section-3.sh`](../../scripts/labs/teardown-section-3.sh) (documented in [Section 03 README](README.md#teardown)). Default removes in-cluster TLS secrets and workstation `secrets/tls/` — trainees need `generate-workshop-pki.sh` before the next 3.x run. Auth secrets from Lab 0.6 stay in the cluster.

## References

- [Certificate blacklist](https://aerospike.com/docs/server/operations/configure/security/pki/)
