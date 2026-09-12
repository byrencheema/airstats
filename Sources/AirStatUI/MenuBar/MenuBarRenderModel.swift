import Foundation
import AirStatKit

/// One value of a readout: the number, the widest string it can ever become, and the
/// series behind it.
///
/// Network and disk are inherently *two* numbers, so a readout is modelled as one or
/// two of these rather than as one string. The concatenation that used to happen here
/// — `"↓ 2.4 MB/s  ↑ 340 KB/s"` — is gone: it was why fixed width did not hold, since
/// its width tracked the live value and no reserved string could bound it.
public struct MenuBarLine: Equatable, Sendable {
    /// Single-character direction marker ("↓", "↑", "R", "W"). Only set on paired
    /// readouts, where the two numbers would otherwise be indistinguishable.
    public var glyph: String?
    /// The value, already formatted and unit-suffixed.
    public var valueText: String
    /// Widest string this line can produce. Reserving it is what stops the menu bar
    /// shuffling every time a value crosses from 9% to 10% or KB/s to MB/s.
    public var widestText: String
    /// Oldest-to-newest samples for graph styles, normalised to 0...1.
    public var series: [Float]

    public init(glyph: String? = nil, valueText: String, widestText: String,
                series: [Float] = []) {
        self.glyph = glyph
        self.valueText = valueText
        self.widestText = widestText
        self.series = series
    }
}

/// One readout, reduced to exactly what the drawing code needs.
///
/// Deliberately free of AppKit and of the snapshot types: the view does no
/// interpretation, and this model can be unit-tested without a screen.
public struct MenuBarItemRender: Equatable, Sendable {
    public var id: UUID
    public var style: MenuBarDisplayStyle
    /// The colour the user chose for this metric, or nil if they have left it alone.
    ///
    /// Carried as data rather than resolved in the view from the theme, because the
    /// status item redraws only when this model changes: a view that read the palette
    /// itself would keep drawing yesterday's colour until some *other* field moved.
    public var tint: ThemeColor?
    /// Short caption such as "CPU", drawn beside the readout. Only ever set for the
    /// styles that draw no number of their own, and only when the user asks for it.
    public var caption: String?
    public var primary: MenuBarLine
    /// Second value, set only for the two-number metrics.
    public var secondary: MenuBarLine?
    /// Set when the metric is unavailable; the view greys the readout and shows a dash.
    public var isUnavailable: Bool
    public var symbolName: String?
    public var accessibilityLabel: String
    /// Charge as 0...1, for the `.battery` style. Nil on every other readout.
    ///
    /// The three battery fields travel here for the same reason `tint` does, and the
    /// reason matters more for these: the status item redraws only when this model
    /// changes, so a battery drawn from a value the view fetched itself would keep
    /// showing the charge from whenever some *other* readout last moved.
    public var batteryCharge: Double?
    /// Power is going in. Drawn as a bolt over the fill.
    public var isBatteryCharging: Bool
    /// Charge at or below `MenuBarItemRender.lowBatteryFraction` and not charging.
    /// Carried rather than recomputed in the view so the threshold lives in one place.
    public var isBatteryLow: Bool
    /// The digits drawn inside the shell: whole percent, and no percent sign.
    ///
    /// The sign is dropped because there is nothing else a number inside a battery could
    /// be a proportion of, and at nine points inside a 24-point shell it is a character
    /// that costs a third of the width to say something the shape already says. Carried
    /// as text rather than derived from `batteryCharge` in the view for the usual
    /// reason: the view does no interpretation, and rounding is interpretation.
    public var batteryValueText: String?

    /// Where the indicator turns red. 20% is where macOS itself first warns.
    public static let lowBatteryFraction = 0.20

    public init(id: UUID, style: MenuBarDisplayStyle,
                tint: ThemeColor? = nil, caption: String?,
                primary: MenuBarLine, secondary: MenuBarLine? = nil,
                isUnavailable: Bool, symbolName: String?,
                accessibilityLabel: String,
                batteryCharge: Double? = nil,
                isBatteryCharging: Bool = false,
                isBatteryLow: Bool = false,
                batteryValueText: String? = nil) {
        self.id = id
        self.style = style
        self.tint = tint
        self.caption = caption
        self.primary = primary
        self.secondary = secondary
        self.isUnavailable = isUnavailable
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.batteryCharge = batteryCharge
        self.isBatteryCharging = isBatteryCharging
        self.isBatteryLow = isBatteryLow
        self.batteryValueText = batteryValueText
    }

}

/// Everything the status item needs to draw one frame.
public struct MenuBarRenderModel: Equatable, Sendable {
    public var items: [MenuBarItemRender]
    public var spacing: Double
    public var usesMonospacedDigits: Bool
    public var usesFixedWidth: Bool
    public var emphasizesValues: Bool
    public var isStale: Bool

    public var accessibilityDescription: String {
        items.map(\.accessibilityLabel).joined(separator: ", ")
    }

    public init(snapshot: SystemSnapshot,
                history: MetricHistory,
                settings: Settings,
                isStale: Bool) {
        let formatter = MetricFormatter(settings: settings.general)
        self.spacing = MenuBarSettings.itemSpacing
        self.usesMonospacedDigits = MenuBarSettings.usesMonospacedDigits
        self.usesFixedWidth = MenuBarSettings.usesFixedWidth
        self.emphasizesValues = settings.menuBar.emphasizesValues
        self.isStale = isStale

        var rendered: [MenuBarItemRender] = []
        rendered.reserveCapacity(settings.menuBar.items.count)
        for config in settings.menuBar.enabledItems {
            rendered.append(MenuBarRenderModel.render(config: config,
                                                      snapshot: snapshot,
                                                      history: history,
                                                      formatter: formatter,
                                                      settings: settings))
        }
        self.items = rendered
    }

    /// Builds one readout. Every enabled item produces one: nothing here decides an
    /// item is not worth drawing, because a readout that comes and goes on its own is
    /// the thing that makes the whole bar shuffle.
    private static func render(config: MenuBarItemConfig,
                               snapshot: SystemSnapshot,
                               history: MetricHistory,
                               formatter: MetricFormatter,
                               settings: Settings) -> MenuBarItemRender {
        let metric = config.metric
        let dash = MetricFormatter.unavailable
        let widest = formatter.widestSample(for: metric)

        var valueText = dash
        var seriesKey: SeriesKey?
        var unavailable = true
        // Named, not a bare "unavailable": VoiceOver reads the whole item as one string,
        // and three anonymous "unavailable"s in a row say nothing about what is missing.
        var accessibilityValue = "\(metric.label) unavailable"
        // Set only by the two-number metrics; its presence is what makes the readout
        // stack rather than run on.
        var secondary: MenuBarLine?
        // Set only by the battery metric, whose indicator style draws the charge as a
        // shape instead of as digits.
        var battery: BatteryState?

        switch metric {
        case .cpuUsage:
            if let cpu = snapshot.cpu.value {
                let busy = cpu.total.busy
                valueText = formatter.percent(busy)
                unavailable = false
                accessibilityValue = "CPU \(valueText)"
            }
            seriesKey = .cpuTotal

        case .cpuTemperature:
            if let temp = snapshot.thermal.value?.cpuCelsius {
                valueText = formatter.temperature(temp)
                unavailable = false
                accessibilityValue = "CPU temperature \(valueText)"
            }
            seriesKey = .cpuTemperature

        case .cpuFrequency:
            // No public API reports Apple Silicon core frequency; leave it explicit.
            break

        case .memoryUsage:
            if let mem = snapshot.memory.value {
                valueText = formatter.percent(mem.usedFraction)
                unavailable = false
                accessibilityValue = "Memory \(valueText)"
            }
            seriesKey = .memoryUsed

        case .memoryPressure:
            if let mem = snapshot.memory.value {
                valueText = formatter.percent(mem.pressureFraction)
                unavailable = false
                accessibilityValue = "Memory pressure \(valueText)"
            }
            seriesKey = .memoryPressure

        case .gpuUsage:
            if let util = snapshot.gpu.value?.primary?.utilization {
                valueText = formatter.percent(util)
                unavailable = false
                accessibilityValue = "GPU \(valueText)"
            }
            seriesKey = .gpuUtilization

        case .networkThroughput:
            // Compact form ("2.4MB") rather than the full one ("2.4 MB/s"). Two full
            // rates side by side are 130 points of menu bar for one readout; the arrow
            // already says this is a flow, and the panel and the accessibility label
            // both still carry the units in full.
            let rateWidest = MenuBarRenderModel.widestCompactNetworkRate(formatter)
            var uploadText = dash
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.downloadBytesPerSecond, compact: true)
                uploadText = formatter.networkRate(net.uploadBytesPerSecond, compact: true)
                unavailable = false
                accessibilityValue = "Network down \(formatter.networkRate(net.downloadBytesPerSecond)), "
                    + "up \(formatter.networkRate(net.uploadBytesPerSecond))"
            }
            // Down and up share one scale so the two stacked graphs are comparable;
            // normalising each to its own peak would make a trickle of upload look
            // identical to a saturated link.
            let pair = jointlyNormalized(history, .networkDownload, .networkUpload)
            secondary = MenuBarLine(glyph: "↑", valueText: uploadText,
                                    widestText: rateWidest, series: pair.1)
            return finish(config: config, caption: nil,
                          primary: MenuBarLine(glyph: "↓", valueText: valueText,
                                               widestText: rateWidest, series: pair.0),
                          secondary: secondary,
                          unavailable: unavailable, accessibility: accessibilityValue,
                          settings: settings)

        case .networkUpload:
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.uploadBytesPerSecond)
                unavailable = false
                accessibilityValue = "Network upload \(valueText)"
            }
            seriesKey = .networkUpload

        case .networkDownload:
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.downloadBytesPerSecond)
                unavailable = false
                accessibilityValue = "Network download \(valueText)"
            }
            seriesKey = .networkDownload

        case .diskActivity:
            let rateWidest = MenuBarRenderModel.widestCompactDiskRate(formatter)
            var writeText = dash
            if let disk = snapshot.disk.value {
                valueText = formatter.diskRate(disk.readBytesPerSecond, compact: true)
                writeText = formatter.diskRate(disk.writeBytesPerSecond, compact: true)
                unavailable = false
                accessibilityValue = "Disk read \(formatter.diskRate(disk.readBytesPerSecond)), "
                    + "write \(formatter.diskRate(disk.writeBytesPerSecond))"
            }
            let pair = jointlyNormalized(history, .diskRead, .diskWrite)
            secondary = MenuBarLine(glyph: "W", valueText: writeText,
                                    widestText: rateWidest, series: pair.1)
            return finish(config: config, caption: nil,
                          primary: MenuBarLine(glyph: "R", valueText: valueText,
                                               widestText: rateWidest, series: pair.0),
                          secondary: secondary,
                          unavailable: unavailable, accessibility: accessibilityValue,
                          settings: settings)

        case .diskFree:
            if let root = snapshot.disk.value?.rootVolume {
                valueText = formatter.storage(root.availableBytes)
                unavailable = false
                accessibilityValue = "Disk free \(valueText)"
            }

        case .battery:
            if let power = snapshot.power.value, let pct = power.percentage {
                valueText = formatter.percentValue(pct)
                unavailable = false
                let charge = min(max(pct / 100, 0), 1)
                let isLow = !power.isCharging && charge <= MenuBarItemRender.lowBatteryFraction
                // Rounded off the clamped charge rather than off the raw percentage, so
                // the digits and the fill can never disagree about how full it is.
                battery = BatteryState(charge: charge, isCharging: power.isCharging,
                                       isLow: isLow,
                                       valueText: String(Int((charge * 100).rounded())))
                // The indicator style takes the digits off the screen, so this is the
                // only place the exact charge is still stated. It says everything the
                // shape says: the number, that power is going in, that it is low.
                accessibilityValue = "Battery \(valueText)"
                if power.isCharging {
                    accessibilityValue += ", charging"
                } else if isLow {
                    accessibilityValue += ", low"
                }
            }
            seriesKey = .batteryPercent

        case .batteryTime:
            if let power = snapshot.power.value {
                let remaining = power.isCharging ? power.timeToFull : power.timeToEmpty
                if let remaining {
                    valueText = formatter.duration(remaining)
                    unavailable = false
                    accessibilityValue = "Battery time \(valueText)"
                }
            }

        case .systemPower:
            if let watts = snapshot.power.value?.systemWatts {
                valueText = formatter.watts(watts)
                unavailable = false
                accessibilityValue = "System power \(valueText)"
            }
            seriesKey = .systemWatts

        case .fanSpeed:
            if let fan = snapshot.thermal.value?.fans.first {
                valueText = formatter.rpm(fan.currentRPM)
                unavailable = false
                accessibilityValue = "Fan \(valueText)"
            }
            seriesKey = .fanRPM

        case .uptime:
            if let system = snapshot.system.value {
                valueText = formatter.compactUptime(system.uptime)
                unavailable = false
                accessibilityValue = "Uptime \(valueText)"
            }
        }

        let series = seriesKey.map { normalizedSeries(history, key: $0) } ?? []
        return finish(config: config, caption: caption(for: config),
                      primary: MenuBarLine(valueText: valueText, widestText: widest,
                                           series: series),
                      secondary: nil,
                      unavailable: unavailable, accessibility: accessibilityValue,
                      settings: settings, battery: battery)
    }

    /// What the battery indicator draws, gathered in one place so the three fields can
    /// only ever be set together.
    private struct BatteryState {
        var charge: Double
        var isCharging: Bool
        var isLow: Bool
        var valueText: String
    }

    private static func finish(config: MenuBarItemConfig,
                               caption: String?,
                               primary: MenuBarLine,
                               secondary: MenuBarLine?,
                               unavailable: Bool,
                               accessibility: String,
                               settings: Settings,
                               battery: BatteryState? = nil) -> MenuBarItemRender {
        MenuBarItemRender(
            id: config.id,
            style: config.style,
            // Only a colour the user actually picked. The shipped metric colours stay
            // out of the menu bar: it is a monochrome surface that Apple's own extras
            // never colour, and a CPU readout that is blue because blue is what CPU
            // charts happen to be is noise the user never asked for.
            tint: settings.theme.color(for: config.metric.requiredSource),
            caption: caption,
            primary: primary,
            secondary: secondary,
            isUnavailable: unavailable,
            symbolName: symbolName(for: config.metric),
            accessibilityLabel: accessibility,
            batteryCharge: battery?.charge,
            isBatteryCharging: battery?.isCharging ?? false,
            isBatteryLow: battery?.isLow ?? false,
            batteryValueText: battery?.valueText
        )
    }

    /// A caption is a static word that never changes, and on a surface this scarce a
    /// static word is the most expensive thing on it. So it is strictly what the user
    /// asked for — `showsCaption`, and nothing else, decides.
    ///
    /// The exceptions are the two styles that already name their metric with a glyph:
    /// "CPU" beside a CPU icon says it twice, and "BATT" beside the system's own battery
    /// indicator says it to the one audience on earth that did not need telling.
    private static func caption(for config: MenuBarItemConfig) -> String? {
        guard config.style.supportsCaption, config.showsCaption else { return nil }
        return captionText(for: config.metric)
    }

    /// The short label a metric is captioned with. Public so the settings pane can
    /// quote the exact string the menu bar will draw rather than describing it.
    public static func captionText(for metric: MenuBarMetric) -> String? {
        switch metric {
        case .cpuUsage: return "CPU"
        case .cpuTemperature: return "TEMP"
        case .cpuFrequency: return "FREQ"
        case .memoryUsage: return "MEM"
        case .memoryPressure: return "PRESS"
        case .gpuUsage: return "GPU"
        case .networkThroughput: return nil
        case .networkUpload: return "NET ↑"
        case .networkDownload: return "NET ↓"
        case .diskActivity: return nil
        case .diskFree: return "FREE"
        case .battery: return "BATT"
        case .batteryTime: return "LEFT"
        case .systemPower: return "PWR"
        case .fanSpeed: return "FAN"
        case .uptime: return "UP"
        }
    }

    /// Graph series normalised to 0...1. Unbounded metrics (throughput) scale to
    /// their own peak in the window so the shape stays legible at any magnitude.
    private static func normalizedSeries(_ history: MetricHistory, key: SeriesKey) -> [Float] {
        let ring = history[key]
        guard ring.count > 1 else { return [] }
        let values = ring.values
        // Already 0...1, so there is no peak to find and nothing to scale against.
        if key.isNormalized {
            return values.map { min(max($0, 0), 1) }
        }
        let peak = max(peak(of: values), .leastNonzeroMagnitude)
        return values.map { min(max($0 / peak, 0), 1) }
    }

    /// Two unbounded series scaled against their shared peak, so the pair can be read
    /// against each other rather than each against itself.
    private static func jointlyNormalized(_ history: MetricHistory,
                                          _ first: SeriesKey,
                                          _ second: SeriesKey) -> ([Float], [Float]) {
        let a = history[first]
        let b = history[second]
        guard a.count > 1 || b.count > 1 else { return ([], []) }
        let lhs = a.values
        let rhs = b.values
        let peak = max(max(peak(of: lhs), peak(of: rhs)), .leastNonzeroMagnitude)
        let scale = { (values: [Float]) in values.map { min(max($0 / peak, 0), 1) } }
        return (scale(lhs), scale(rhs))
    }

    /// Largest sample, taken from the copy the graph already needs rather than from the
    /// ring, and answering 0 for an empty series exactly as `SampleRing.maximum` does.
    ///
    /// This is the whole of the saving. `ring.maximum` reaches every sample through the
    /// ring's wrapping subscript, which pays a bounds precondition, a branch and a
    /// modulo per element and does not inline in a debug build: 277 µs over an hour of
    /// history, against 23 µs for the identical 1802 samples read contiguously. The
    /// samples have to be copied out for the graph regardless, so the peak comes out of
    /// that copy and the history is walked once per readout instead of twice.
    ///
    /// Iterating the buffer, not indexing it: at `-Onone` the iterator is precompiled
    /// stdlib code while `buffer[index]` is a call per element, which costs 10x. The
    /// obvious-looking `values.max()` is worse again, and worse in release too.
    private static func peak(of values: [Float]) -> Float {
        values.withUnsafeBufferPointer { buffer in
            guard !buffer.isEmpty else { return Float(0) }
            var peak = -Float.greatestFiniteMagnitude
            for value in buffer { peak = max(peak, value) }
            return peak
        }
    }

    /// The widest string the compact rate form can produce, generated *through* the
    /// formatter so it follows the user's bits-versus-bytes and binary-versus-decimal
    /// choices instead of assuming them.
    private static func widestCompactNetworkRate(_ formatter: MetricFormatter) -> String {
        let probe = formatter.networkUnit == .bits
            ? 999 * 1_000_000 / 8.0
            : 999 * pow(formatter.byteStyle.base, 2)
        return formatter.networkRate(probe, compact: true)
    }

    private static func widestCompactDiskRate(_ formatter: MetricFormatter) -> String {
        formatter.diskRate(999 * pow(formatter.byteStyle.base, 2), compact: true)
    }

    private static func symbolName(for metric: MenuBarMetric) -> String? {
        switch metric {
        case .cpuUsage, .cpuFrequency: return "cpu"
        case .cpuTemperature: return "thermometer.medium"
        case .memoryUsage, .memoryPressure: return "memorychip"
        case .gpuUsage: return "cube.transparent"
        case .networkThroughput, .networkUpload, .networkDownload: return "network"
        case .diskActivity, .diskFree: return "internaldrive"
        case .battery, .batteryTime: return "battery.100"
        case .systemPower: return "bolt"
        case .fanSpeed: return "fan"
        case .uptime: return "clock"
        }
    }
}
