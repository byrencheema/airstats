import AppKit
import AirStatKit
import AirStatUI

/// `AirStats --render` writes PNGs of every surface without needing a screen or a
/// Screen Recording grant, using deterministic fixture data.
enum RenderCLI {

    static func run(_ arguments: [String]) {
        var surfaces: [OffscreenRenderer.Surface] = []
        var scenarios: [OffscreenRenderer.Scenario] = []
        var scales: [CGFloat] = []
        var appearances: [Bool] = []
        var outputDirectory = URL(fileURLWithPath: "render", isDirectory: true)
        var settings = AirStatKit.Settings()

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--out":
                index += 1
                guard let path = arguments[safe: index], !path.isEmpty else {
                    FileHandle.standardError.write(Data("--out wants a directory\n".utf8))
                    exit(2)
                }
                outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
            case "--scale":
                index += 1
                // Bounded, not just parsed. `Double("1e400")` is `+infinity`, and the
                // pixel count it produces is an `Int(_:)` conversion that traps rather
                // than saturating — a typo in a flag should not be a crash.
                guard let value = Double(arguments[safe: index] ?? ""),
                      value.isFinite, value > 0, value <= 8 else {
                    FileHandle.standardError.write(Data("--scale wants a number in 0...8\n".utf8))
                    exit(2)
                }
                scales.append(CGFloat(value))
            case "--light": appearances.append(false)
            case "--dark": appearances.append(true)
            // The colour a user picks is already carried on Request.settings and read
            // by MenuBarRenderModel and the desktop widget; only a way to say so was missing.
            // The panel ignores it on purpose, it is monochrome by design.
            case "--tint":
                index += 1
                guard let color = themeColor(from: arguments[safe: index] ?? "") else {
                    FileHandle.standardError.write(Data("--tint wants #RRGGBB or r,g,b in 0...1\n".utf8))
                    exit(2)
                }
                settings.theme.setAllColors(color)
            // The desktop widget's shape is decided by two settings a reviewer cannot reach
            // from the command line otherwise, and its worst case (nine modules,
            // expanded) is exactly the one worth looking at.
            case "--expanded":
                settings.desktopWidget.isCompact = false
            case "--modules":
                index += 1
                let names = (arguments[safe: index] ?? "").split(separator: ",")
                let parsed = names.compactMap { PanelModule(rawValue: String($0)) }
                guard parsed.count == names.count, !parsed.isEmpty else {
                    FileHandle.standardError.write(Data("--modules wants a comma-separated list of module names\n".utf8))
                    exit(2)
                }
                var seen: Set<PanelModule> = []
                settings.desktopWidget.modules = parsed.filter { seen.insert($0).inserted }
            case "--scenario":
                index += 1
                guard let scenario = OffscreenRenderer.Scenario(rawValue: arguments[safe: index] ?? "") else {
                    let known = OffscreenRenderer.Scenario.allCases.map(\.rawValue).joined(separator: ", ")
                    FileHandle.standardError.write(Data("--scenario wants one of: \(known)\n".utf8))
                    exit(2)
                }
                scenarios.append(scenario)
            default:
                if let surface = OffscreenRenderer.Surface(rawValue: arguments[index]) {
                    surfaces.append(surface)
                } else {
                    FileHandle.standardError.write(Data("unknown argument '\(arguments[index])'\n".utf8))
                    exit(2)
                }
            }
            index += 1
        }

        // Default to the full matrix: every surface, every state, both appearances,
        // both backing scales. That is what a visual reviewer needs to see at once.
        if surfaces.isEmpty { surfaces = OffscreenRenderer.Surface.allCases }
        if scenarios.isEmpty { scenarios = OffscreenRenderer.Scenario.allCases }
        if appearances.isEmpty { appearances = [false, true] }
        if scales.isEmpty { scales = [1, 2] }

        // Rendering AppKit and SwiftUI views needs a running NSApplication even
        // though nothing is ever shown, so the app is brought up as an accessory
        // and torn down as soon as the images are written.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        MainActor.assumeIsolated {
            var written = 0
            var failures: [String] = []
            for surface in surfaces {
                for scenario in scenarios {
                    for isDark in appearances {
                        for scale in scales {
                            let request = OffscreenRenderer.Request(
                                surface: surface, scenario: scenario,
                                isDark: isDark, scale: scale, settings: settings)
                            do {
                                let url = try OffscreenRenderer.render(request, to: outputDirectory)
                                print(url.path)
                                written += 1
                            } catch {
                                failures.append("\(request.fileName): \(error)")
                            }
                        }
                    }
                }
            }
            print("\nwrote \(written) image(s) to \(outputDirectory.path)")
            for failure in failures {
                FileHandle.standardError.write(Data("FAILED \(failure)\n".utf8))
            }
            if !failures.isEmpty { exit(1) }
        }
    }
}

/// Accepts `#4C8DFF`, `4C8DFF` or `0.3,0.55,1`, so a colour can be pasted from either
/// a design tool or the settings file without conversion.
private func themeColor(from text: String) -> ThemeColor? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)

    if trimmed.contains(",") {
        let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return ThemeColor(red: parts[0], green: parts[1], blue: parts[2])
    }

    let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    return ThemeColor(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
