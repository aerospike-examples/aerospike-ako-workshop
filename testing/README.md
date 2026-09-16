# AKO Workshop — Automated Lab Test Harness

Scripted end-to-end checks that run the workshop labs against a **live EKS
or GKE** environment and assert pass/fail, replacing the guides' interactive
"watch until it looks done" steps with timeout-bound polling and assertions.

## Scope

| Labs | Status |
|------|--------|
| `1.1`–`1.4`, `2.1`–`2.5`, `3.1`–`3.5` | Automated ([labs/](labs/)), part of the full suite |
| `4.1`–`4.2` (all-flash) | Automated, but **excluded from the full suite** — they need the opt-in all-flash cluster, so run them standalone |
| Section 0 (bootstrap) | **Manual** — handled by `workshop/scripts/setup/setup-all.sh` (the harness assumes it already ran) |
| Lab `2.6` (K8s control plane upgrade) | **Manual** — separate upgrade-lab cluster; use the guide + `workshop/scripts/setup/upgrade-lab/validate-post-upgrade.sh` |

Section 3 (Security & Authentication) is part of the curriculum and always runs
as part of the full suite.

## Layout

```text
testing/
├── run-lab.sh          # run one lab: ./testing/run-lab.sh 3.3
├── test-all-labs.sh    # run the full curriculum in order (single config)
├── test-matrix.sh      # bootstrap + full suite across 3 configs, then teardown
├── labs/<id>.sh        # one script per lab
└── lib/
    ├── lab-env.sh      # sources workshop libs + load_env (every lab sources this)
    ├── wait-helpers.sh # polling + assertions + plain-TCP asadm
    └── tls-helpers.sh  # TLS/PKI asadm + secret helpers (Section 3 only)
```

## Prerequisites

- A bootstrapped environment from `workshop/scripts/setup/setup-all.sh`
  (Section 0) and a configured `workshop/scripts/env/workshop.env`
  (`DEPLOY_PATH`, `NODE_PROVISIONING` / `CLOUD_PROVIDER`, region, etc.).
- `kubectl`, `helm`, and the matching cloud CLI (`aws` or `gcloud`) on the workstation.

GKE matrix cells (not mixed in the same `test-matrix.sh` run as EKS): `olm:gke` / `helm:gke` with `CLOUD_PROVIDER=gke` and `NODE_PROVISIONING=nodepool`.

## Usage

### Run a single lab

```bash
./testing/run-lab.sh 1.1
./testing/run-lab.sh 3.3
```

Assumes the target cluster is already bootstrapped. Section 3 labs chain in
order — run `3.1` first (it generates the PKI and TLS secrets the later 3.x
labs depend on). Each `3.x` script also fails fast with a clear message if the
required predecessor state is missing.

### Run the all-flash labs (Section 4)

```bash
./workshop/scripts/setup/setup-all.sh --step 0.8   # once: dedicated all-flash cluster
./testing/run-lab.sh 4.1
./testing/run-lab.sh 4.2
```

`4.1`/`4.2` set `LAB_CLUSTER=all-flash`, so `lib/lab-env.sh` switches to the
`${ALL_FLASH_CLUSTER_NAME}` kubeconfig instead of the main cluster. `4.2`
depends on the baseline `4.1` left running and grows the node pool from 3 to 4
before scaling the CR, so allow ~20 extra minutes for node provisioning.

### Run the full suite (single config)

```bash
./testing/test-all-labs.sh [--run-id <id>] [--resume]
```

Runs `1.1 … 3.5` in curriculum order (Labs 2.6 and 4.1/4.2 excluded — both live
on their own clusters). Fail-fast: on the
first failing lab it stops, leaves the cluster up for debugging, and writes
`testing/runs/<id>/report.md`. Resume after a fix with `--resume`.

### Run the full config matrix

```bash
./testing/test-matrix.sh [--matrix-id <id>] \
  [--configs olm:eksctl,helm:eksctl,helm:karpenter]
```

For each `DEPLOY_PATH:NODE_PROVISIONING` config: writes `workshop.env` →
`setup-all.sh` (main cluster only; Lab 2.6 / Section 4 stay off) → full lab suite → teardown on success.
Real EKS infra: ~6-8h per config, ~18-24h total. Run under `nohup`.

## Mapping to the manual checklist

These automated runs are the scripted equivalent of the manual
[walkthrough-checklist.md](../workshop/validation/walkthrough-checklist.md).
After a green matrix run, update `validated_status` / `validated_on` in
[LAB_REGISTRY.yaml](../workshop/LAB_REGISTRY.yaml).

## Notes on Section 3 (TLS/PKI)

- `tls-helpers.sh` mounts the workshop TLS secrets into short-lived `asadm`
  pods for TLS-password, mTLS-password, and PKI auth, plus negative checks.
- The plain-TCP `run_asadm` (admin/admin123 on port 3000) does **not** work
  once the cluster is `PKIOnly` (Lab 3.3 Phase C onward) — Section 3 uses the
  `tls-helpers.sh` variants instead.
- Lab 3.1 clears any stale local `secrets/tls/revoked.txt` at start so a
  previous failed 3.5 run cannot blacklist an outdated serial.
- Between matrix configs the whole EKS cluster (and its secrets) is deleted, so
  no in-cluster Section 3 secret cleanup is required.
