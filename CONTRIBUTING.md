# Contributing

AirStats has a few opinions. They are here so a pull request does not have to find them
in review.

## Getting set up

You need macOS 14 or later and the Swift 6 toolchain that ships with Xcode 16.

```sh
git clone <your fork>
cd airstats
swift build
swift test
Scripts/build.sh          # debug .app bundle
Scripts/build.sh release  # optimised .app bundle
```

To run your build, quit the running copy, replace `/Applications/AirStats.app` with the
one the script prints, and launch it.

## Before you open a pull request

Run these:

```sh
swift build
swift test
.build/debug/AirStats --probe            # sanity check the collectors on your Mac
.build/debug/AirStats --render           # PNGs of every surface, in ./render
```

If you touched anything that draws, attach the relevant render. If you touched a
collector, say what you diffed its output against.

`--probe` prints raw collector output, so you can check it against `top`, `vm_stat`,
`netstat -ib`, `ioreg` and `pmset`. `--render` draws the menu bar, panel, desktop widget and
settings from fixture data at both appearances and both backing scales. Neither needs a
screen. `NSVisualEffectView` renders nothing offscreen, though, so a render shows layout
and SwiftUI drawing only: materials and translucency can only be judged on screen.

The fan minimum-RPM contract test can fail for a second while a fan spins down, so
re-run before you investigate. `swift build` sometimes reports success while linking
stale objects, so if an edit does not reach the binary, delete `.build` and build
again.

## House rules

**Never show a number the machine did not report.** A missing sensor renders as a dash
and an unsupported metric is greyed out with the reason attached. Never substitute a
zero, a guess or a last-known value. A sparkline with fewer than two samples draws
nothing, since a flat line reads as a metric pinned at zero.

**Comments explain why, not what.** A comment earns its place by recording the
measurement, the platform bug or the rejected alternative behind the code. If you removed
a comment's reason, remove the comment.

**Keep AirStatKit free of UI.** It imports Foundation, IOKit and the rest of the system,
never SwiftUI or AppKit. The tests and `--probe` run in a windowless process.

**Match the design system.** Spacing, type and colour come from `Design` in
`Sources/AirStatUI/Design/DesignSystem.swift`. Add a token there rather than a literal at
the call site.

## Commits

One change per commit. Conventional Commits, on one line:

```
feat: colour menu bar readouts from the metric palette
fix: keep the panel on screen when the status item is hidden
perf: draw charts as shapes instead of Canvas
```

## Reporting a bug

Include your Mac model, your macOS version, and the output of `AirStats --probe` for the
metric that misbehaved. Sensor coverage varies across Macs more than anything else here,
so that output is often the whole report.
