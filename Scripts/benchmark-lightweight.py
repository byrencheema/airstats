#!/usr/bin/env python3
"""Compare AirStats collector work before and after a change.

This harness deliberately measures the public ``--probe`` path rather than a
synthetic loop. Each scenario starts the specified executable, samples the same
collectors three times, and records child wall time, CPU time, and peak RSS.
It is a collector-cost check, not a replacement for Instruments or Activity
Monitor: process startup and the host's current load are part of every result.

Examples:
    python3 Scripts/benchmark-lightweight.py \
      --executable /tmp/airstats-baseline/.../AirStats
    python3 Scripts/benchmark-lightweight.py \
      --executable .build/arm64-apple-macosx/release/AirStats --json after.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


SCENARIOS = {
    "menu": ("cpu", "memory", "system"),
    "panel": (
        "cpu", "memory", "gpu", "network", "disk", "power", "thermal", "processes", "system"
    ),
}


def run_once(executable: str, collectors: tuple[str, ...], repeats: int, interval: float) -> dict[str, float]:
    command = [
        "/usr/bin/time",
        "-lp",
        executable,
        "--probe",
        *collectors,
        "--repeat",
        str(repeats),
        "--interval",
        str(interval),
    ]
    completed = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if completed.returncode:
        error = completed.stderr.strip().splitlines()[-1:] or [f"exit {completed.returncode}"]
        raise RuntimeError(f"{' '.join(command)} failed: {error[0]}")
    metrics = dict(re.findall(r"^\s*(real|user|sys)\s+([0-9.]+)\s*$", completed.stderr, re.MULTILINE))
    rss_match = re.search(r"^\s*([0-9]+)\s+maximum resident set size$", completed.stderr, re.MULTILINE)
    if not rss_match or not {"real", "user", "sys"} <= metrics.keys():
        raise RuntimeError(f"could not parse /usr/bin/time output: {completed.stderr.strip()}")
    # macOS reports maximum resident size in bytes. Keep the raw value and convert only
    # for display. /usr/bin/time makes this a per-launch peak rather than a cumulative
    # process-wide high-water mark.
    return {
        "wall_seconds": float(metrics["real"]),
        "user_seconds": float(metrics["user"]),
        "system_seconds": float(metrics["sys"]),
        "peak_rss_bytes": int(rss_match.group(1)),
    }


def summarize(samples: list[dict[str, float]]) -> dict[str, float]:
    result: dict[str, float] = {"runs": len(samples)}
    for key in samples[0]:
        if key == "peak_rss_bytes":
            # Maximum RSS is already a high-water mark; median is less sensitive to
            # unrelated one-off allocations in one invocation.
            values = sorted(sample[key] for sample in samples)
            result[key] = values[len(values) // 2]
        else:
            result[key] = sum(sample[key] for sample in samples) / len(samples)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, help="AirStats executable to measure")
    parser.add_argument("--runs", type=int, default=5, help="measured launches per scenario")
    parser.add_argument("--repeat", type=int, default=3, help="probe samples per launch")
    parser.add_argument("--interval", type=float, default=0.2, help="seconds between probe samples")
    parser.add_argument("--scenario", action="append", choices=SCENARIOS, help="scenario(s) to run")
    parser.add_argument("--json", type=Path, help="also write machine-readable results here")
    args = parser.parse_args()
    if args.runs < 1 or args.repeat < 1 or args.interval < 0.05:
        parser.error("runs and repeat must be positive; interval must be at least 0.05")
    executable = os.path.abspath(args.executable)
    if not os.access(executable, os.X_OK):
        parser.error(f"not executable: {executable}")
    scenarios = args.scenario or list(SCENARIOS)

    # One warmup launch avoids measuring lazy dyld/filesystem work as the first result.
    for name in scenarios:
        run_once(executable, SCENARIOS[name], 2, args.interval)

    results = {
        "executable": executable,
        "runs": args.runs,
        "repeat": args.repeat,
        "interval_seconds": args.interval,
        "scenarios": {},
    }
    print(f"Executable: {executable}")
    print(f"Runs: {args.runs} launches/scenario, {args.repeat} probe samples, {args.interval:.2f}s interval")
    print("RSS is median peak resident size; CPU excludes the probe's sleep interval.")
    for name in scenarios:
        samples = [run_once(executable, SCENARIOS[name], args.repeat, args.interval) for _ in range(args.runs)]
        summary = summarize(samples)
        results["scenarios"][name] = {"collectors": SCENARIOS[name], "samples": samples, "summary": summary}
        print(
            f"{name:5} wall {summary['wall_seconds']:.3f}s  "
            f"cpu {(summary['user_seconds'] + summary['system_seconds']) * 1000:.1f}ms  "
            f"user {summary['user_seconds'] * 1000:.1f}ms  "
            f"sys {summary['system_seconds'] * 1000:.1f}ms  "
            f"rss {summary['peak_rss_bytes'] / 1024**2:.1f} MiB"
        )
    if args.json:
        args.json.write_text(json.dumps(results, indent=2) + "\n")
        print(f"Wrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
