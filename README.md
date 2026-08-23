<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.png">
  <img src="docs/logo-light.png" alt="" width="104">
</picture>

<h3>AirStats</h3>

An ultra lightweight macOS system monitor.

<hr width="140">

</div>

AirStats is a system monitor for the Mac menu bar. It reads CPU, memory, GPU, network,
disk, battery, temperature, process and host statistics from the kernel and shows them in
three places: the menu bar itself, a panel that drops down when you click the status item,
and a desktop widget you can leave on screen.

It is built to be genuinely light. A menu bar monitor runs all day, every day, so AirStats
holds a few megabytes and a fraction of a percent of one core rather than the tens of
megabytes its peers take. It has no Dock icon, and reads the system through Mach, IOKit,
sysctl and CoreWLAN.

## Requirements

- macOS 14 or later
- Apple silicon

## Install

Download it from [airstats.app](https://airstats.app), open the dmg and drag the app to
Applications. It is signed and notarized, so it opens with no warning.

Or with Homebrew:

```sh
brew install --cask byrencheema/tap/airstats
```

AirStats updates itself with [Sparkle](https://sparkle-project.org). It asks airstats.app
once a week whether a newer version exists, and installs one only when you say so. Both of
those can be turned off in General settings.

## Build from source

You need the Swift 6 toolchain that ships with Xcode 16.

```sh
Scripts/build.sh release
cp -R .build/arm64-apple-macosx/release/AirStats.app /Applications/
open /Applications/AirStats.app
```

`Scripts/build.sh` wraps the SwiftPM binary in a `.app` bundle, copies `Sparkle.framework`
into `Contents/Frameworks`, and signs it ad hoc. macOS grants a status item only to a
signed bundle with `LSUIElement` set. Run the script with no argument for a debug build.

An ad-hoc signature is enough to run a build you made yourself, and not enough to travel:
macOS refuses an ad-hoc bundle that arrived over the internet. `Scripts/release.sh` is what
produces the download above, signing with a Developer ID certificate and stapling Apple's
notarization ticket to the `.dmg`.

## Source layout

| Path | What lives there |
| --- | --- |
| `Sources/AirStatKit` | Collectors, the sampling engine, settings, formatting. No UI. |
| `Sources/AirStatUI` | Menu bar drawing, panel, desktop widget, settings window, charts, design system. |
| `Sources/AirStats` | The executable, app delegate, and the probe and render commands. |
| `Tests/AirStatKitTests` | Contract tests for the collectors, plus settings and formatting. |
| `Scripts/build.sh` | Builds the binary and assembles the `.app`. |
| `Scripts/release.sh` | Signs, notarizes and packages the `.dmg` that ships. |
| `Scripts/appcast.py` | Writes a release into the appcast Sparkle reads. |
| `Scripts/benchmark.py` | Samples the menu bar monitors on your Mac over one shared window. |

`AirStatKit` never imports SwiftUI or AppKit, which is what lets the tests and the probe
run in a windowless process.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the checks to run before a pull request and the
house rules.

## License

MIT. See [LICENSE](LICENSE).
