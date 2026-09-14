# Section 04 — Instructor notes

## Timing

| Lab | Instructor time | Notes |
|-----|-----------------|-------|
| 0.8 (setup) | 25–40 min | Cluster create + first NVMe partition pass; run it **before** the session |
| 4.1 | 25–35 min | Most of it is reading the CR; the deploy itself is ~10 min |
| 4.2 | 25–35 min | 25M asbench load (~2–3 min); node pool growth still dominates wall clock |

Run setup step 0.8 ahead of time. A cold bootstrap on GKE partitions 16 disks per node, and on EKS the init container installs `parted` and `nvme-cli` before it touches a disk. Index slices stay raw; kubelet formats them when Lab 4.1 pods start.

## Before the session

- **Capacity.** `i8ge.3xlarge` is not offered in every AZ; check the all-flash zone before the day. On GKE, 16 Local SSDs per node × 4 nodes is 16 × 375 GiB × 4 — confirm the Local SSD quota in the region, not just the CPU quota.
- **Cost.** This is a *third* cluster on top of the main and upgrade-lab clusters, which is why `setup-all.sh` never creates it by default. Tear it down with `./scripts/cleanup-lab.sh --all-flash-only` as soon as Section 4 ends.
- **One node per pod.** `multiPodPerHost: false`, so `ALL_FLASH_NODE_COUNT_SCALED=4` must be within your quota even though Lab 4.1 only uses 3.
- **Seed data before 4.2.** Empty clusters migrate too fast to show the all-flash index shrinking on scale-out. Lab 4.2 loads **25M × 100 B** in about 2–3 minutes (`load-data.sh --all-flash`, `ALL_FLASH_LOAD_RECORDS` / `ALL_FLASH_LOAD_OBJECT_SIZE`). Tiny objects keep the demo about the flash index, not the data devices. Do not use bare `load-data.sh` — that hits the main cluster.

## Sizing the index — where 600 GiB and 16384 sprigs come from

All-flash allocates index space in **4 KiB pages per sprig**, not per record. With `partition-tree-sprigs: 16384` and 4096 partitions per namespace:

- Whole namespace: 4096 × 16384 × 4 KiB = **256 GiB** of index, minimum, spread over the cluster.
- Per node at RF 2 on 3 nodes: each node holds roughly two thirds of the partitions → about **170 GiB**.
- If one node is lost, the surviving two each hold every partition → **256 GiB** per node.

The 600 GiB `mounts-budget` therefore has headroom for a node failure and for records beyond the one-page-per-sprig floor. Lab 4.2's 25M objects make `index_flash_used_bytes` non-zero so trainees can watch it drop when a node is added — the talking point is still that the budget looks oversized relative to this lab's data.

`partition-tree-sprigs` is the sizing lever, and it is **locked at 16384** in this section. Raising it later requires a rolling **cold restart** of every node — the index files are rebuilt from the data devices. Mention it; do not demo it. See [Cold restart](https://aerospike.com/docs/database/manage/database/cold-restart).

## Pitfalls

- **The kernel settings are node-wide.** `vm.dirty_background_bytes=1` and `vm.dirty_expire_centisecs=1` make the kernel write back almost immediately, for every process on the node. That is fine on a dedicated all-flash cluster and is exactly why this section does not run on the main workshop cluster.
- **Unprivileged only works with the DaemonSet.** Aerospike 6.3+ can run all-flash unprivileged *if* the kernel parameters are already set. If a pod crashes at startup complaining about best practices, check that the node carries `workshop.aerospike.com/storage=all-flash` so `all-flash-sysctl` scheduled there. Last-resort fallback: set `podSpec.aerospikeContainer.securityContext.privileged: true` and let the server set the values itself.
- **Claims are smaller than slices on purpose.** After kubelet formats ext4, usable space must still cover `mounts-budget` (600 GiB), so the layouts cut 640 GiB (EKS) and 40 GiB (GKE) index slices.
- **Do not hand-edit the CR or values files.** All four are generated; re-run `scripts/labs/render-all-flash-manifests.py` (`--check` in CI) after changing sizes or volume counts.
- **First boot is slow.** Pods format and warm index mounts on first start. A 10-minute rollout is normal; it is not a hang.
- **Context drift.** Every script here switches to the all-flash cluster and restores the main context on exit. If a trainee interrupts a script mid-run, `./scripts/lib/kubecontext.sh main` puts them back.

## Skip paths

- Short on time or quota? Demo **4.1 only** and describe 4.2 — the scale mechanics are identical to Lab 1.1 apart from the node/PV prerequisite.
- No budget for a third cluster? Walk through [manifests/all-flash-cluster.yaml](../../manifests/all-flash-cluster.yaml) and [config/disk-layouts.yaml](../../config/disk-layouts.yaml) as a reading exercise, side by side with `manifests/disk-cluster.yaml`. The DRAM-vs-flash contrast is the lesson; the cluster is the proof.

## Contrast to reach for

| Question | Answer to give |
|----------|----------------|
| "When would I use this?" | Huge record counts with small records, where the DRAM index — not the data — is what caps the node. |
| "What does it cost?" | Latency. An index lookup that misses the page cache becomes a device read. |
| "Can I convert my cluster?" | Not in place with AKO: the index volumes cannot be added to a running CR. Build a new cluster and migrate with XDR or backup/restore. |
| "Why 64 GiB pods on a 96 GiB node?" | The index is no longer in DRAM. The remaining RAM is page cache for the index mounts, which the kernel manages outside the pod's request. |
