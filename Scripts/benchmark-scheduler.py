#!/usr/bin/env python3
"""Compile and compare SourceSlot directly from one or more source roots.

SourceSlot is private to SamplingCore.swift, so this wrapper extracts only that class
and supplies minimal stubs for its collector protocol and value types. The extracted
class is compiled for each source root and run against deterministic 1-second ticks;
the benchmark therefore follows source changes instead of maintaining a duplicate
state-machine implementation.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import tempfile
from pathlib import Path


STUBS = r"""
import Foundation

struct TestDuration {
    let seconds: Double
    static func seconds(_ value: Double) -> TestDuration { TestDuration(seconds: value) }
}
struct TestInstant: Comparable {
    let seconds: Double
    static func < (lhs: TestInstant, rhs: TestInstant) -> Bool { lhs.seconds < rhs.seconds }
    func advanced(by duration: TestDuration) -> TestInstant {
        TestInstant(seconds: seconds + duration.seconds)
    }
}
enum CollectorID: Hashable { case stub }
enum SamplingActivity {
    case menuBar
    var isSampling: Bool { true }
    var cadenceMultiplier: Double { 1 }
}
struct SampleContext {
    let elapsed: TimeInterval
    let isFirstSample: Bool
    let activity: SamplingActivity
    let didWakeFromSleep: Bool
}
struct ReadFailure: Equatable { let isPermanent: Bool }
enum MetricState<Value: Equatable>: Equatable {
    case value(Value)
    case failure(ReadFailure)
    static var pending: Self { .failure(ReadFailure(isPermanent: false)) }
}
protocol MetricSource {
    associatedtype Output: Equatable
    var identifier: CollectorID { get }
    var preferredInterval: TimeInterval { get }
    func start()
    func stop()
    func collect(context: SampleContext) -> MetricState<Output>
}
enum Monotonic {
    // The runner advances exactly one second per tick, so this is the elapsed value
    // expected by SourceSlot without sleeping for 300 seconds.
    static func seconds(since instant: TestInstant) -> TimeInterval { 1 }
}
final class StubSource: MetricSource {
    typealias Output = Int
    let identifier: CollectorID = .stub
    let preferredInterval: TimeInterval = 1
    var result: MetricState<Int>
    var collectCount = 0
    init(result: MetricState<Int>) { self.result = result }
    func start() {}
    func stop() {}
    func collect(context: SampleContext) -> MetricState<Int> {
        collectCount += 1
        return result
    }
}
"""

RUNNER_TEMPLATE = r"""
func runHealthy{index}(_ enabled: (Int) -> Bool) -> Int {{
    let source = StubSource(result: .value(1))
    let slot = Slot{index}(source)
    for tick in 0..<{ticks} {{
        _ = slot.tick(now: TestInstant(seconds: Double(tick)), activity: .menuBar,
                      isEnabled: enabled(tick), baseInterval: 1,
                      didWakeFromSleep: false)
    }}
    return source.collectCount
}}
func runFailure{index}() -> Int {{
    let source = StubSource(result: .failure(ReadFailure(isPermanent: false)))
    let slot = Slot{index}(source)
    for tick in 0..<{ticks} {{
        _ = slot.tick(now: TestInstant(seconds: Double(tick)), activity: .menuBar,
                      isEnabled: true, baseInterval: 1,
                      didWakeFromSleep: false)
    }}
    return source.collectCount
}}
let suspended{index}: (Int) -> Bool = {{ tick in
    !({suspend_start}..<{suspend_end}).contains(tick)
}}
print("root{index} healthy enabled=\(runHealthy{index}({{ _ in true }}))")
print(" failure=\(runFailure{index}()), suspended=\(runHealthy{index}(suspended{index}))")
"""


def source_body(root: Path, class_name: str) -> str:
    path = root / "Sources/AirStatKit/Core/SamplingCore.swift"
    source = path.read_text()
    start = source.index("final class SourceSlot")
    end = source.index("\n/// Owns every collector", start)
    body = source[start:end]
    body = body.replace("final class SourceSlot", f"final class {class_name}", 1)
    return body.replace("ContinuousClock.Instant", "TestInstant")


def run(root: Path, index: int, ticks: int, suspend_start: int, suspend_end: int) -> tuple[str, str]:
    class_name = f"Slot{index}"
    runner = RUNNER_TEMPLATE.format(index=index, ticks=ticks,
                                    suspend_start=suspend_start, suspend_end=suspend_end)
    with tempfile.TemporaryDirectory(prefix="airstats-scheduler-") as directory:
        directory_path = Path(directory)
        swift = directory_path / "benchmark.swift"
        binary = directory_path / "benchmark"
        swift.write_text(STUBS + "\n" + source_body(root, class_name) + "\n" + runner)
        compile_result = subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)],
                                        capture_output=True, text=True)
        if compile_result.returncode:
            raise RuntimeError(compile_result.stderr.strip())
        output = subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout
    match = re.search(r"healthy enabled=(\d+)\s+failure=(\d+), suspended=(\d+)", output)
    if not match:
        raise RuntimeError(f"unexpected benchmark output: {output}")
    return match.groups()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", action="append", type=Path, required=True,
                        help="source root containing Sources/AirStatKit/Core/SamplingCore.swift (repeatable)")
    parser.add_argument("--ticks", type=int, default=300)
    parser.add_argument("--suspend-start", type=int, default=100)
    parser.add_argument("--suspend-end", type=int, default=150)
    args = parser.parse_args()
    if len(args.source_root) < 2:
        parser.error("provide at least two --source-root values to compare")
    if args.ticks < 1 or not 0 <= args.suspend_start < args.suspend_end <= args.ticks:
        parser.error("ticks and suspension bounds are invalid")

    print("source root                         healthy  failure  suspended")
    for root_index, root in enumerate(args.source_root):
        healthy, failure, suspended = run(root.resolve(), root_index, args.ticks,
                                          args.suspend_start, args.suspend_end)
        print(f"{str(root.resolve()):35} {healthy:>7} {failure:>8} {suspended:>10}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
