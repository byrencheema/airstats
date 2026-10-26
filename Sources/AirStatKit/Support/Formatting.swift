import Foundation

/// All number-to-string conversion in AirStat.
///
/// Centralised for two reasons: the menu bar must not jitter as digit counts change,
/// and every readout must respect the user's unit choices. Formatters are cached —
/// constructing a `NumberFormatter` per frame is a measurable cost at 1 Hz across a
/// dozen readouts.
public struct MetricFormatter: Sendable {

    public var byteStyle: ByteUnitStyle
    public var networkUnit: NetworkRateUnit
    public var temperatureUnit: TemperatureUnit
    public var showsPercentSign: Bool

    public init(byteStyle: ByteUnitStyle = .decimal,
                networkUnit: NetworkRateUnit = .bytes,
                temperatureUnit: TemperatureUnit = .celsius,
                showsPercentSign: Bool = true) {
        self.byteStyle = byteStyle
        self.networkUnit = networkUnit
        self.temperatureUnit = temperatureUnit
        self.showsPercentSign = showsPercentSign
    }

    public init(settings: GeneralSettings) {
        self.init(byteStyle: settings.byteUnitStyle,
                  networkUnit: settings.networkRateUnit,
                  temperatureUnit: settings.temperatureUnit,
                  showsPercentSign: settings.showsPercentSign)
    }

    /// Rendered when a value is genuinely unknown. An em dash, not "0" and not "N/A":
    /// it reads as "nothing here" without shouting, matching macOS conventions.
    public static let unavailable = "—"

    // MARK: Percentages

    /// `fraction` is 0...1. Width is stable: always the same digit count for a
    /// given `decimals`, so menu bar text never reflows.
    public func percent(_ fraction: Double, decimals: Int = 0) -> String {
        guard fraction.isFinite else { return Self.unavailable }
        let clamped = max(0, min(1, fraction)) * 100
        let body = fixed(clamped, decimals: decimals)
        return showsPercentSign ? body + "%" : body
    }

    /// For values already expressed as 0...100.
    public func percentValue(_ value: Double, decimals: Int = 0) -> String {
        guard value.isFinite else { return Self.unavailable }
        let body = fixed(max(0, min(100, value)), decimals: decimals)
        return showsPercentSign ? body + "%" : body
    }

    /// CPU percentages per process can legitimately exceed 100 (multi-threaded),
    /// so this one does not clamp.
    public func unclampedPercent(_ value: Double, decimals: Int = 1) -> String {
        guard value.isFinite else { return Self.unavailable }
        let body = fixed(max(0, value), decimals: decimals)
        return showsPercentSign ? body + "%" : body
    }

    // MARK: Bytes

    private static let binaryUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Physical memory, always base-1024.
    ///
    /// Apple quotes RAM in binary units while still writing "GB": this Mac reports
    /// `hw.memsize` = 19,327,352,832 bytes and Apple calls it 18 GB. Formatting memory
    /// decimally would render it "19.3 GB", which no Apple surface anywhere agrees with.
    /// So memory ignores the user's byte-unit preference — that preference exists for
    /// storage, where the convention genuinely differs.
    public func memory(_ value: UInt64, decimals: Int? = nil) -> String {
        format(Double(value), base: 1024, decimals: decimals)
    }

    public func memory(_ value: Double, decimals: Int? = nil) -> String {
        format(value, base: 1024, decimals: decimals)
    }

    /// Disk capacity, honouring the user's preference and defaulting to decimal.
    ///
    /// Finder, Disk Utility and System Settings all report storage decimally: this Mac's
    /// container is 494,384,795,648 bytes and Finder calls it 494 GB. Reporting 460 GB
    /// because we divided by 1024 would look like a bug to anyone cross-checking.
    public func storage(_ value: UInt64, decimals: Int? = nil) -> String {
        format(Double(value), base: byteStyle.base, decimals: decimals)
    }

    public func storage(_ value: Double, decimals: Int? = nil) -> String {
        format(value, base: byteStyle.base, decimals: decimals)
    }

    /// Generic byte formatting for anything that is neither RAM nor disk capacity
    /// (transfer totals, per-process footprints). Follows the user's preference.
    public func bytes(_ value: UInt64, forceUnit: Int? = nil, decimals: Int? = nil) -> String {
        bytes(Double(value), forceUnit: forceUnit, decimals: decimals)
    }

    public func bytes(_ value: Double, forceUnit: Int? = nil, decimals: Int? = nil) -> String {
        guard value.isFinite, value >= 0 else { return Self.unavailable }
        let base = byteStyle.base
        var magnitude = value
        var unitIndex = 0
        if let forceUnit {
            unitIndex = min(max(forceUnit, 0), Self.binaryUnits.count - 1)
            magnitude = value / pow(base, Double(unitIndex))
        } else {
            while magnitude >= base && unitIndex < Self.binaryUnits.count - 1 {
                magnitude /= base
                unitIndex += 1
            }
        }
        let places = decimals ?? Self.naturalDecimals(for: magnitude, unitIndex: unitIndex)
        return "\(fixed(magnitude, decimals: places)) \(Self.binaryUnits[unitIndex])"
    }

    /// Shared scaling used by `memory`, `storage` and `bytes`.
    private func format(_ value: Double, base: Double, decimals: Int?) -> String {
        guard value.isFinite, value >= 0 else { return Self.unavailable }
        var magnitude = value
        var unitIndex = 0
        while magnitude >= base && unitIndex < Self.binaryUnits.count - 1 {
            magnitude /= base
            unitIndex += 1
        }
        let places = decimals ?? Self.naturalDecimals(for: magnitude, unitIndex: unitIndex)
        return "\(fixed(magnitude, decimals: places)) \(Self.binaryUnits[unitIndex])"
    }

    /// Bytes without the unit suffix, when the caption already carries it.
    public func byteValue(_ value: Double, unitIndex: Int, decimals: Int? = nil) -> String {
        guard value.isFinite, value >= 0 else { return Self.unavailable }
        let magnitude = value / pow(byteStyle.base, Double(unitIndex))
        let places = decimals ?? Self.naturalDecimals(for: magnitude, unitIndex: unitIndex)
        return fixed(magnitude, decimals: places)
    }

    /// Bytes below 10 get one decimal; larger values get none. Keeps every readout
    /// to roughly three significant characters, which is what makes a column of
    /// numbers scan cleanly.
    private static func naturalDecimals(for magnitude: Double, unitIndex: Int) -> Int {
        if unitIndex == 0 { return 0 }            // whole bytes
        if magnitude < 10 { return 1 }
        return 0
    }

    // MARK: Rates

    /// Network throughput, honouring the bits-vs-bytes preference.
    public func networkRate(_ bytesPerSecond: Double, compact: Bool = false) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return Self.unavailable }
        switch networkUnit {
        case .bytes:
            return dataRate(bytesPerSecond, units: ["B/s", "KB/s", "MB/s", "GB/s"], compact: compact)
        case .bits:
            return dataRate(bytesPerSecond * 8, units: ["bps", "Kbps", "Mbps", "Gbps"],
                            base: 1000, compact: compact)
        }
    }

    /// Disk throughput is always in bytes — bits are a networking convention.
    public func diskRate(_ bytesPerSecond: Double, compact: Bool = false) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return Self.unavailable }
        return dataRate(bytesPerSecond, units: ["B/s", "KB/s", "MB/s", "GB/s"], compact: compact)
    }

    private func dataRate(_ value: Double, units: [String], base: Double? = nil,
                          compact: Bool) -> String {
        let b = base ?? byteStyle.base
        var magnitude = value
        var unitIndex = 0
        while magnitude >= b && unitIndex < units.count - 1 {
            magnitude /= b
            unitIndex += 1
        }
        // Exactly zero is worth showing as a clean "0", not "0.0".
        if unitIndex == 0 && magnitude < 1 { return compact ? "0 \(units[0])" : "0 \(units[0])" }
        let places = magnitude < 10 && unitIndex > 0 ? 1 : 0
        let number = fixed(magnitude, decimals: places)
        return compact ? number + units[unitIndex].replacingOccurrences(of: "/s", with: "")
                       : number + " " + units[unitIndex]
    }

    // MARK: Temperature

    public func temperature(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let celsius, celsius.isFinite else { return Self.unavailable }
        let value = temperatureUnit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return fixed(value, decimals: decimals) + temperatureUnit.suffix
    }

    /// Degrees without the unit, for dense layouts where the caption says "°C".
    public func temperatureValue(_ celsius: Double?, decimals: Int = 0) -> String {
        guard let celsius, celsius.isFinite else { return Self.unavailable }
        let value = temperatureUnit == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return fixed(value, decimals: decimals)
    }

    // MARK: Time

    /// Battery time remaining and similar. "2:45" style, or "45m" when under an hour.
    public func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0, let total = Self.whole(seconds) else { return Self.unavailable }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes))" }
        return "\(minutes)m"
    }

    /// Uptime, in the "12d 4h" register Apple uses in About This Mac.
    public func uptime(_ seconds: TimeInterval) -> String {
        guard seconds >= 0, let total = Self.whole(seconds.rounded(.down)) else { return Self.unavailable }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public func compactUptime(_ seconds: TimeInterval) -> String {
        guard seconds >= 0, let total = Self.whole(seconds.rounded(.down)) else { return Self.unavailable }
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }

    // MARK: Misc

    public func rpm(_ value: Double?) -> String {
        guard let value, value >= 0, let whole = Self.whole(value) else { return Self.unavailable }
        return "\(whole) RPM"
    }

    public func watts(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return Self.unavailable }
        return fixed(abs(value), decimals: decimals) + " W"
    }

    public func frequency(_ megahertz: Double?) -> String {
        guard let megahertz, megahertz.isFinite, megahertz > 0 else { return Self.unavailable }
        if megahertz >= 1000 { return fixed(megahertz / 1000, decimals: 2) + " GHz" }
        return fixed(megahertz, decimals: 0) + " MHz"
    }

    public func count(_ value: Int) -> String {
        Self.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: Primitives

    /// Fixed-decimal rendering that always uses the locale's decimal separator but
    /// never groups — grouping separators in a 3-character menu bar readout are noise.
    public func fixed(_ value: Double, decimals: Int) -> String {
        // The bound applies at every decimal count, not just zero. `String(format:)`
        // does not trap on 1.8e308, it renders all 309 digits of it, and a readout
        // three hundred characters wide is its own kind of broken.
        guard let whole = Self.whole(value) else { return Self.unavailable }
        if decimals == 0 { return String(whole) }
        let rounded = String(format: "%.\(decimals)f", value)
        let separator = Locale.current.decimalSeparator ?? "."
        return separator == "." ? rounded : rounded.replacingOccurrences(of: ".", with: separator)
    }

    /// `Int(_:)` traps rather than saturating, and it traps on plenty of *finite*
    /// doubles: anything past 9.2 * 10^18 is out of range. A sensor that misreads —
    /// an SMC fan channel returning garbage, a boot time from a machine whose clock
    /// jumped — hands us exactly such a number, and a readout is not worth a crash.
    /// Nothing this large is a real reading, so it formats as "no reading" instead.
    private static func whole(_ value: Double) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, rounded.magnitude < 9.2e18 else { return nil }
        return Int(rounded)
    }

    private static let integerFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// The widest string this formatter can produce for a metric, used to reserve
    /// menu bar width so items never shift as values change.
    public func widestSample(for metric: MenuBarMetric) -> String {
        switch metric {
        case .cpuUsage, .memoryUsage, .gpuUsage, .memoryPressure, .battery, .diskUsage:
            return showsPercentSign ? "100%" : "100"
        case .cpuTemperature:
            return temperatureUnit == .fahrenheit ? "212°F" : "100°C"
        case .cpuFrequency:
            return "4.05 GHz"
        case .networkThroughput, .networkUpload, .networkDownload:
            return networkUnit == .bits ? "999 Mbps" : "999 MB/s"
        case .diskActivity:
            return "999 MB/s"
        case .diskFree:
            return "999 GB"
        case .batteryTime:
            return "12:59"
        case .systemPower:
            return "99.9 W"
        case .fanSpeed:
            return "9999 RPM"
        case .uptime:
            return "999d"
        }
    }
}
