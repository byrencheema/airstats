# Lightweight benchmark

This is a repeatable collector-cost check for changes that affect AirStats' core
promise of being lightweight. It exercises the shipped `--probe` entry point in a
release build, rather than a synthetic loop. Each scenario launches the executable
five times; each launch takes three samples at 0.20 seconds. The harness reports
per-launch wall time, child CPU time (sleep excluded), and median peak RSS. Results
include process startup and the current host load, so they are useful for comparing
the same machine before and after a change and are not portable Activity Monitor
claims. Use `python3 Scripts/benchmark-lightweight.py --help` for options.

The longer comparison was run with:

```sh
python3 Scripts/benchmark-lightweight.py --executable <release-app>/Contents/MacOS/AirStats \
  --runs 3 --repeat 31 --interval 1 --json <results>.json
```

The `menu` source set means CPU, memory, and system; the `panel` source set means
all nine collectors. These names describe probe inputs, not an opened panel or a
measured menu-bar process. The probe does not exercise `SamplingCore`,
`MetricsEngine`, `ThresholdMonitor`, or UI rendering.

## Baseline

The baseline was built from the complete dirty working tree on 2026-09-11 before
runtime/UI implementation agents edited the source. The immutable snapshot and app
are preserved at `/tmp/airstats-baseline-20260911` for this review.

| Source set | Collectors | Mean wall | Mean child CPU | Median peak RSS |
| --- | --- | ---: | ---: | ---: |
| menu | CPU, memory, system | 0.432 s | 8 ms | 14.7 MiB |
| panel | CPU, memory, GPU, network, disk, power, thermal, processes, system | 0.780 s | 78 ms | 24.6 MiB |

The baseline release Performance suite also passed all 19 tests. A prior full local
test run had one pre-existing live fan minimum failure in
`Tests/AirStatKitTests/CollectorContractTests.swift`; the suite is hardware-sensitive.

For a longer collector-only run, the same scenarios used three launches with 31
samples at a one-second interval (30 seconds of sampling per launch). This removes
most of the short probe's startup-to-work ratio, while still bypassing the app's
`SamplingCore`, `MetricsEngine`, `ThresholdMonitor`, and UI surfaces.

| Source set | Mean wall | Mean child CPU | Median peak RSS |
| --- | ---: | ---: | ---: |
| menu | 30.230 s | 26.7 ms | 14.6 MiB |
| panel | 30.993 s | 293.3 ms | 24.3 MiB |

Baseline executable SHA-256: `cace19fb0704443f920e11396e9a8eeb5dc9cb6bac8b2dc9d86382c852d74f7f`.
Raw results: `/tmp/airstats-baseline-collector-30s.json`.

## After implementation

The same command and scenario options produced these after values. Keep the baseline
values above unchanged.

| Source set | Mean wall | Mean child CPU | Median peak RSS | Change |
| --- | ---: | ---: | ---: | ---: |
| menu | 30.247 s | 30.0 ms | 13.8 MiB | +12.4% CPU |
| panel | 31.033 s | 303.3 ms | 24.2 MiB | +3.4% CPU |

After executable SHA-256: `424f5a271988700ed23d7c763651998833ebdfbca418f26d9162fbe2f84e89ce`.
Raw results: `/tmp/airstats-after-collector-30s-final.json`.

The small CPU differences are within the coarse 10ms resolution of `/usr/bin/time`
and host variability, and these probes do not cover the scheduler or notification
observer changes. They should not be presented as an app-idle regression or proof of
an idle improvement.

## Scheduler micro-benchmark

The collector probe cannot observe `SourceSlot`, because `--probe` constructs
collectors directly. For scheduler coverage, `Scripts/benchmark-scheduler.py` extracts
the actual `SourceSlot` body from each supplied source root, adds minimal stubs for its
collector protocol and value types, compiles it, and runs it with a deterministic
source. It simulates 300 one-second ticks and counts `collect` calls. It also checks a
healthy source and a 50-tick suspension window (ticks 100–149), so normal cadence
and suspension gating remain unchanged.

Run it with:

```sh
python3 Scripts/benchmark-scheduler.py \
  --source-root /tmp/airstats-baseline-20260911 \
  --source-root .
```

| Source root | Healthy calls | Failure calls | Suspended calls |
| --- | ---: | ---: | ---: |
| baseline snapshot | 300 | 300 | 250 |
| current working tree | 300 | 9 | 250 |

This isolates the retry behavior and is not a wall-time or energy measurement. The
current policy attempts at ticks 0, 2, 6, 14, 30, 62, 122, 182, and 242, then waits
for the next bounded retry; a later success clears the delay in the production slot.
