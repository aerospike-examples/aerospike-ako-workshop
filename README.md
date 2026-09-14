# Aerospike AKO Workshop

Private instructor-led workshop materials for the **Aerospike Kubernetes Operator (AKO)** on AWS EKS (default) or GKE Standard.

## Quick start

**EKS (default):**

```bash
git clone git@github.com:realmgic/aerospike-ako-workshop.git
cd aerospike-ako-workshop/workshop
cp scripts/env/workshop.env.example scripts/env/workshop.env
cp /path/to/your/features.conf secrets/features.conf   # license — not in repo
./scripts/setup/01-validate-client.sh
```

**GKE Standard:**

```bash
cd aerospike-ako-workshop/workshop
cp scripts/env/workshop.env.gke.example scripts/env/workshop.env
# set GCP_PROJECT
cp /path/to/your/features.conf secrets/features.conf
./scripts/setup/01-validate-client.sh
```

Full walkthrough guide: [workshop/README.md](workshop/README.md)

## Prerequisites

- AWS account with EKS permissions **or** a GCP project with GKE Standard permissions
- Aerospike Enterprise `features.conf` (from licensing portal)
- Tools listed in [workshop/instructor/client-prerequisites.md](workshop/instructor/client-prerequisites.md)

## Repository layout

```text
aerospike-ako-workshop/
├── README.md          # this file
├── testing/           # automated lab test harness (labs 1.1–2.5, 3.1–3.5, 4.1–4.2; see testing/run-lab.sh)
└── workshop/          # all lab guides, manifests, scripts
```

Everything needed to run the workshop lives under `workshop/`. The `testing/` directory runs scripted end-to-end checks against a live cluster (Section 0, Lab 2.6, and Section 4 are opt-in / standalone). See [testing/README.md](testing/README.md).

## Sections

| Section | Cluster |
|---------|---------|
| [0 — Environment Setup](workshop/sections/00-environment-setup/) | `my-cluster` |
| [1 — Scaling & Capacity](workshop/sections/01-scaling-and-capacity/) | `my-cluster` |
| [2 — Maintenance & Upgrade](workshop/sections/02-maintenance-and-upgrade/) | `my-cluster` (Lab 2.6 optional: `my-cluster-k8s-upgrade`) |
| [3 — Security & Authentication](workshop/sections/03-security-and-authentication/) | `my-cluster` |
| [4 — All-flash Storage](workshop/sections/04-all-flash-storage/) (optional) | `my-cluster-all-flash` (opt-in, setup step 0.8) |
