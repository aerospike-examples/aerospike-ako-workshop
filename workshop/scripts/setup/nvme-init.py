#!/usr/bin/env python3
"""NVMe bootstrap init — partition and symlink local disks for the provisioner."""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "ERROR: PyYAML not installed — init image must include python3-pyyaml",
        file=sys.stderr,
    )
    sys.exit(1)

HOST = Path("/host")
CONFIG = Path("/config/disk-layouts.yaml")
DISKS_DIR = HOST / "mnt" / "disks"
LEGACY_BOOTSTRAP_MARKER_DIR = DISKS_DIR / ".nvme-bootstrap"
BOOTSTRAP_MARKER_DIR = HOST / "var" / "lib" / "workshop" / "nvme-bootstrap"
DEV_DIR = Path("/dev")

INSTANCE_STORE_PATTERNS = (
    "Amazon EC2 NVMe Instance Storage",
    "Microsoft NVMe Direct Disk",
    "nvme_card",
)


def run(cmd: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    if shutil.which(cmd[0]) is None:
        if check:
            raise FileNotFoundError(f"required command not found: {cmd[0]}")
        print(f"skip missing command: {cmd[0]}")
        return subprocess.CompletedProcess(cmd, returncode=127, stdout="", stderr="")
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def gcp_machine_type() -> str | None:
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1/instance/machine-type",
        headers={"Metadata-Flavor": "Google"},
    )
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.read().decode().strip().rsplit("/", 1)[-1]
    except OSError:
        return None


def detect_instance_type() -> str:
    gcp = gcp_machine_type()
    if gcp:
        return gcp
    return imds_instance_type()


def imds_instance_type() -> str:
    """Read instance type from EC2 IMDSv2 (stdlib only — avoids curl/curl-minimal dnf conflicts)."""
    token_req = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
    )
    with urllib.request.urlopen(token_req, timeout=10) as resp:
        token = resp.read().decode().strip()
    type_req = urllib.request.Request(
        "http://169.254.169.254/latest/meta-data/instance-type",
        headers={"X-aws-ec2-metadata-token": token},
    )
    with urllib.request.urlopen(type_req, timeout=10) as resp:
        return resp.read().decode().strip()


def discover_instance_store_devices() -> list[str]:
    """Find local instance-store NVMe devices (same approach as as_disk_k8s.sh)."""
    listing = run(["nvme", "list"], check=False).stdout
    devices: list[str] = []
    seen: set[str] = set()

    for line in listing.splitlines():
        if not any(pattern in line for pattern in INSTANCE_STORE_PATTERNS):
            continue
        parts = line.split()
        if not parts:
            continue
        device_path = parts[0]
        if not device_path.startswith("/dev/"):
            continue
        name = Path(device_path).name
        if name in seen:
            continue
        if not (DEV_DIR / name).exists():
            continue
        seen.add(name)
        devices.append(name)

    print(f"discovered instance-store devices: {devices}")
    return devices


def parse_size_gib(value: str) -> float | None:
    match = re.fullmatch(r"(\d+(?:\.\d+)?)GiB", value.strip())
    if not match:
        return None
    return float(match.group(1))


def disk_size_bytes(device: str) -> int:
    path = DEV_DIR / device
    if not path.exists():
        return 0
    return int(run(["blockdev", "--getsize64", str(path)]).stdout.strip())


LAYOUT_TOLERANCE_GIB = 1.0


def cap_end(device: str, start: str, end: str) -> str:
    """Cap partition end to disk size. Layout `end` values are absolute boundaries, not sizes."""
    del start  # kept for call-site clarity; boundary capping uses end vs disk size only
    if end == "100%":
        return end
    end_gib = parse_size_gib(end)
    if end_gib is None:
        return end
    disk_gib = disk_size_bytes(device) / (1024**3)
    if end_gib > disk_gib:
        return "100%"
    return end


def parse_parted_size_gib(value: str) -> float | None:
    match = re.fullmatch(r"([\d.]+)(GiB|MiB|kiB|kB|B)", value.strip())
    if not match:
        return None
    amount = float(match.group(1))
    unit = match.group(2)
    if unit == "GiB":
        return amount
    if unit == "MiB":
        return amount / 1024
    if unit in ("kiB", "kB"):
        return amount / (1024**2)
    return amount / (1024**3)


def parse_layout_start_gib(start: str) -> float | None:
    if start.endswith("%"):
        if start == "0%":
            return 0.0
        return None
    return parse_size_gib(start)


def parse_layout_end_gib(device: str, end: str) -> float | None:
    if end == "100%":
        return disk_size_bytes(device) / (1024**3)
    return parse_size_gib(end)


def get_existing_partitions(device: str) -> list[dict[str, float | int]]:
    dev_path = DEV_DIR / device
    if not dev_path.exists():
        return []
    result = run(
        ["parted", "-s", "-m", str(dev_path), "unit", "GiB", "print"],
        check=False,
    )
    if result.returncode != 0:
        return []

    partitions: list[dict[str, float | int]] = []
    for line in result.stdout.splitlines():
        fields = line.rstrip(";").split(":")
        if not fields or not fields[0].isdigit():
            continue
        start_gib = parse_parted_size_gib(fields[1])
        end_gib = parse_parted_size_gib(fields[2])
        if start_gib is None or end_gib is None:
            continue
        partitions.append(
            {
                "number": int(fields[0]),
                "start_gib": start_gib,
                "end_gib": end_gib,
            }
        )
    partitions.sort(key=lambda item: int(item["number"]))
    return partitions


def layout_matches(device: str, partitions_spec: list[dict]) -> bool:
    existing = get_existing_partitions(device)
    expected_count = len(partitions_spec)
    if len(existing) != expected_count:
        print(
            f"layout mismatch on {device}: expected {expected_count} partitions, "
            f"found {len(existing)}"
        )
        return False

    for spec, part in zip(partitions_spec, existing):
        number = int(spec["number"])
        if int(part["number"]) != number:
            print(
                f"layout mismatch on {device}: expected partition {number}, "
                f"found {part['number']}"
            )
            return False

        start_gib = parse_layout_start_gib(spec["start"])
        end_gib = parse_layout_end_gib(device, spec["end"])
        if start_gib is None or end_gib is None:
            print(f"layout mismatch on {device}: invalid spec {spec}")
            return False

        if abs(float(part["start_gib"]) - start_gib) > LAYOUT_TOLERANCE_GIB:
            print(
                f"layout mismatch on {device}p{number}: start "
                f"{part['start_gib']:.2f}GiB != {start_gib:.2f}GiB"
            )
            return False
        if abs(float(part["end_gib"]) - end_gib) > LAYOUT_TOLERANCE_GIB:
            print(
                f"layout mismatch on {device}p{number}: end "
                f"{part['end_gib']:.2f}GiB != {end_gib:.2f}GiB"
            )
            return False

    return True


def log_partition_table(device: str) -> None:
    dev_path = DEV_DIR / device
    result = run(
        ["parted", "-s", str(dev_path), "unit", "GiB", "print"],
        check=False,
    )
    if result.stdout.strip():
        print(result.stdout.rstrip())


def bootstrap_marker_path(device: str) -> Path:
    return BOOTSTRAP_MARKER_DIR / device


def remove_legacy_bootstrap_markers() -> None:
    """Drop markers from /mnt/disks so the block provisioner does not scan them."""
    if not LEGACY_BOOTSTRAP_MARKER_DIR.is_dir():
        return
    print(f"removing legacy bootstrap markers from {LEGACY_BOOTSTRAP_MARKER_DIR}")
    shutil.rmtree(LEGACY_BOOTSTRAP_MARKER_DIR)


def write_bootstrap_marker(device: str) -> None:
    marker = bootstrap_marker_path(device)
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text("ok\n")


def partition_path(device: str, number: int) -> Path:
    return DEV_DIR / f"{device}p{number}"


def partition_is_ready(device: str, number: int) -> bool:
    part = partition_path(device, number)
    link = DISKS_DIR / f"{device}p{number}"
    return part.exists() and link.is_symlink() and link.resolve() == part.resolve()


def all_partitions_ready(device: str, partitions_spec: list[dict]) -> bool:
    return all(
        partition_is_ready(device, int(spec["number"]))
        for spec in partitions_spec
    )


def device_bootstrap_complete(device: str, partitions_spec: list[dict]) -> bool:
    if not bootstrap_marker_path(device).exists():
        return False
    if not layout_matches(device, partitions_spec):
        return False
    return all_partitions_ready(device, partitions_spec)


def any_partition_ready(device: str, partitions_spec: list[dict]) -> bool:
    return any(
        partition_is_ready(device, int(spec["number"]))
        for spec in partitions_spec
    )


def wipe_gpt(device: str) -> None:
    dev_path = DEV_DIR / device
    print(f"wiping partition table on {device}")
    run(["parted", "-a", "opt", "--script", str(dev_path), "mklabel", "gpt"])
    run(["partprobe", str(dev_path)], check=False)
    run(["udevadm", "settle"], check=False)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if not device_has_partitions(device):
            return
        time.sleep(0.2)
    print(f"WARN: partitions still present on {device} after wipe")


def ensure_gpt_label(device: str) -> None:
    dev_path = DEV_DIR / device
    result = run(["parted", "-s", str(dev_path), "print"], check=False)
    if "Partition Table:" not in result.stdout:
        print(f"creating GPT label on {device}")
        run(["parted", "-a", "opt", "--script", str(dev_path), "mklabel", "gpt"])
        run(["partprobe", str(dev_path)], check=False)
        run(["udevadm", "settle"], check=False)


def wait_for_partition(device: str, number: int, timeout_sec: float = 15) -> None:
    part = partition_path(device, number)
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        if part.exists():
            return
        time.sleep(0.2)
    print(f"WARN: timed out waiting for {part.name}")


def device_has_partitions(device: str) -> bool:
    return any(partition_path(device, number).exists() for number in range(1, 10))


def create_gpt_partition(device: str, number: int, start: str, end: str) -> None:
    dev_path = DEV_DIR / device
    end = cap_end(device, start, end)
    print(f"creating {device}p{number}: {start} -> {end}")
    run(
        [
            "parted", "-a", "opt", "--script", str(dev_path),
            "mkpart", "primary", start, end,
        ]
    )
    run(["partprobe", str(dev_path)], check=False)
    run(["udevadm", "settle"], check=False)
    wait_for_partition(device, number)


def apply_partition_layout(device: str, partitions_spec: list[dict]) -> None:
    if device_bootstrap_complete(device, partitions_spec):
        print(f"bootstrap complete for {device}, skipping")
        return

    if all_partitions_ready(device, partitions_spec) and layout_matches(device, partitions_spec):
        print(f"all partitions ready for {device}, skipping bootstrap")
        write_bootstrap_marker(device)
        return

    allocated = any_partition_ready(device, partitions_spec)

    if layout_matches(device, partitions_spec):
        print(f"partition layout matches for {device}, skipping repartition")
    elif allocated:
        print(f"some partitions already allocated on {device}, creating missing only")
        ensure_gpt_label(device)
        for spec in partitions_spec:
            number = int(spec["number"])
            if partition_is_ready(device, number) or partition_path(device, number).exists():
                print(f"skipping allocated partition {device}p{number}")
                continue
            create_gpt_partition(
                device,
                number,
                spec["start"],
                spec["end"],
            )
    else:
        wipe_gpt(device)
        for spec in partitions_spec:
            create_gpt_partition(
                device,
                int(spec["number"]),
                spec["start"],
                spec["end"],
            )

    for spec in partitions_spec:
        symlink_partition(device, int(spec["number"]))

    write_bootstrap_marker(device)
    log_partition_table(device)


def symlink_partition(device: str, number: int) -> None:
    name = f"{device}p{number}"
    target = Path(f"/dev/{name}")
    link = DISKS_DIR / name
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() and link.resolve() == target:
        return
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(str(target))
    print(f"symlink {link} -> {target}")


def resolve_instance_store(layout: dict, stores: list[str]) -> str | None:
    selector = layout.get("instance_store", "first")
    if selector in ("first", "largest"):
        if not stores:
            return None
        if selector == "largest":
            return max(stores, key=disk_size_bytes)
        return stores[0]
    if isinstance(selector, int):
        return stores[selector] if 0 <= selector < len(stores) else None
    if isinstance(selector, str) and (DEV_DIR / selector).exists():
        return selector
    return None


def resolve_instance_stores(layout: dict, stores: list[str], *, default: str = "all") -> list[str]:
    selector = layout.get("instance_store", default)
    if selector == "all":
        return stores
    device = resolve_instance_store({**layout, "instance_store": selector}, stores)
    return [device] if device else []


def whole_device_ready(device: str) -> bool:
    path = DEV_DIR / device
    link = DISKS_DIR / device
    return path.exists() and link.is_symlink() and link.resolve() == path.resolve()


def whole_device_bootstrap(devices: list[str]) -> None:
    DISKS_DIR.mkdir(parents=True, exist_ok=True)
    for device in devices:
        path = DEV_DIR / device
        if not path.exists():
            continue
        if whole_device_ready(device) and bootstrap_marker_path(device).exists():
            print(f"whole device {device} already bootstrapped, skipping")
            continue
        link = DISKS_DIR / device
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(f"/dev/{device}")
        print(f"symlink whole device {link} -> /dev/{device}")
        write_bootstrap_marker(device)


def load_layout_for_instance_type(config_path: Path, instance_type: str) -> dict:
    with config_path.open() as handle:
        config = yaml.safe_load(handle)
    layouts = config.get("layouts") or {}
    return layouts.get(instance_type) or layouts.get("default") or {}


def expected_pvs_per_node(layout: dict) -> int | None:
    """Expected local-ssd PV count per node for a disk layout entry."""
    if layout.get("mode") == "whole-device":
        selector = layout.get("instance_store", "all")
        if selector == "all":
            devices = layout.get("instance_store_devices")
            if devices is None:
                return None
            return int(devices)
        return 1

    partitions = layout.get("partitions") or []
    if not partitions:
        return None

    per_device = len(partitions)
    selector = layout.get("instance_store", "first")
    if selector == "all":
        devices = layout.get("instance_store_devices")
        if devices is None:
            return None
        return per_device * int(devices)
    return per_device


def load_layout() -> tuple[str, dict]:
    with CONFIG.open() as handle:
        config = yaml.safe_load(handle)
    force = (config.get("force_layout") or "").strip()
    layouts = config.get("layouts") or {}
    instance_type = force or detect_instance_type()
    layout = layouts.get(instance_type) or layouts.get("default") or {}
    print(
        f"instance-type={instance_type} "
        f"layout={'partitioned' if layout.get('partitions') else layout.get('mode', 'default')}"
    )
    return instance_type, layout


def partitioned_bootstrap(layout: dict, stores: list[str]) -> None:
    devices = resolve_instance_stores(layout, stores, default="first")
    if not devices:
        print("no instance-store device found for partitioned layout")
        return

    DISKS_DIR.mkdir(parents=True, exist_ok=True)
    for device in devices:
        print(f"partitioning instance-store device {device}")
        apply_partition_layout(device, layout.get("partitions") or [])


def bootstrap_main() -> int:
    if not DEV_DIR.is_dir():
        print("no /dev — skipping")
        return 0

    remove_legacy_bootstrap_markers()

    _, layout = load_layout()
    stores = discover_instance_store_devices()
    if not stores:
        print("no instance-store NVMe devices found — skipping")
        return 0

    if layout.get("mode") == "whole-device":
        devices = resolve_instance_stores(layout, stores)
        whole_device_bootstrap(devices)
    elif layout.get("partitions"):
        partitioned_bootstrap(layout, stores)
    else:
        print("no matching layout")
        return 0

    print("disk bootstrap summary:")
    run(["ls", "-la", str(DISKS_DIR)], check=False)
    return 0


def cli_main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="NVMe bootstrap and layout helpers")
    parser.add_argument(
        "--expected-pvs-per-node",
        action="store_true",
        help="Print expected local-ssd PV count per node for --instance-type",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG,
        help="Path to disk-layouts.yaml",
    )
    parser.add_argument(
        "--instance-type",
        help="Instance type layout key (e.g. i8g.2xlarge)",
    )
    args = parser.parse_args(argv)

    if args.expected_pvs_per_node:
        if not args.instance_type:
            print("ERROR: --instance-type is required with --expected-pvs-per-node", file=sys.stderr)
            return 1
        if not args.config.is_file():
            print(f"ERROR: config file not found: {args.config}", file=sys.stderr)
            return 1
        layout = load_layout_for_instance_type(args.config, args.instance_type)
        count = expected_pvs_per_node(layout)
        if count is not None:
            print(count)
        return 0

    return bootstrap_main()


def main() -> int:
    return cli_main()


if __name__ == "__main__":
    sys.exit(main())
