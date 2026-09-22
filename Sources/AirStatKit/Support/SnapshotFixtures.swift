import Foundation

/// Deterministic system snapshots for rendering, previews and tests.
///
/// Visual review needs data that does not change between runs, or every screenshot
/// diff is dominated by the CPU having moved 3%. These fixtures also let the UI be
/// exercised in states that are hard to produce on demand — a failing sensor, a
/// disk that is nearly full, a machine with no battery — which is exactly where
/// layout tends to break.
public enum SnapshotFixtures {

    /// A busy but unremarkable laptop. The default for visual review.
    public static var nominal: SystemSnapshot {
        SystemSnapshot(
            cpu: .value(cpu(busy: 0.34)),
            memory: .value(memory(usedFraction: 0.57, pressure: 0.32)),
            gpu: .value(gpu(utilization: 0.18)),
            network: .value(network(down: 2_400_000, up: 340_000)),
            disk: .value(disk(read: 8_400_000, write: 1_200_000, usedFraction: 0.71)),
            power: .value(power(percent: 76, charging: false)),
            thermal: .value(thermal(cpuTemp: 52, fanRPM: 1_820)),
            processes: .value(processes()),
            system: .value(system()),
            capturedAt: referenceDate
        )
    }

    /// Everything under stress: the state where colour, thresholds and wide numbers
    /// all have to hold up at once.
    public static var underLoad: SystemSnapshot {
        SystemSnapshot(
            cpu: .value(cpu(busy: 0.97)),
            memory: .value(memory(usedFraction: 0.94, pressure: 0.88)),
            gpu: .value(gpu(utilization: 0.99)),
            network: .value(network(down: 118_000_000, up: 44_000_000)),
            disk: .value(disk(read: 940_000_000, write: 512_000_000, usedFraction: 0.97)),
            power: .value(power(percent: 8, charging: false)),
            thermal: .value(thermal(cpuTemp: 99, fanRPM: 6_400)),
            processes: .value(processes(topCPU: 412.6)),
            system: .value(system()),
            capturedAt: referenceDate
        )
    }

    /// A machine where several sources are genuinely unavailable. Proves the UI
    /// degrades honestly instead of rendering zeros.
    public static var degraded: SystemSnapshot {
        SystemSnapshot(
            cpu: .value(cpu(busy: 0.12)),
            memory: .value(memory(usedFraction: 0.41, pressure: 0.20)),
            gpu: .failure(.unsupported("No GPU utilisation source on this Mac")),
            network: .failure(.failed("No active network interface")),
            disk: .value(disk(read: 0, write: 0, usedFraction: 0.33)),
            power: .value(desktopPower()),
            thermal: .failure(.unsupported("Temperature sensors are not readable on this Mac")),
            processes: .failure(.denied("Process information requires additional permission")),
            system: .value(system()),
            capturedAt: referenceDate
        )
    }

    /// Plugged in and taking a charge, on an otherwise quiet machine.
    ///
    /// Its own scenario because charging is a *drawing* state, not just a number: the
    /// menu bar battery grows a bolt, and nothing else in `nominal` or `underLoad` puts
    /// it there. Charging from low rather than from full, so the bolt has to be legible
    /// against the shell as well as against the fill.
    public static var charging: SystemSnapshot {
        SystemSnapshot(
            cpu: .value(cpu(busy: 0.21)),
            memory: .value(memory(usedFraction: 0.48, pressure: 0.26)),
            gpu: .value(gpu(utilization: 0.07)),
            network: .value(network(down: 640_000, up: 91_000)),
            disk: .value(disk(read: 2_100_000, write: 480_000, usedFraction: 0.71)),
            power: .value(power(percent: 34, charging: true)),
            thermal: .value(thermal(cpuTemp: 47, fanRPM: 1_460)),
            processes: .value(processes(topCPU: 18.4)),
            system: .value(system()),
            capturedAt: referenceDate
        )
    }

    /// Nothing sampled yet — the first frame after launch.
    public static var pending: SystemSnapshot { SystemSnapshot() }

    /// Every optional field the app charts or watches, filled in at once.
    ///
    /// `nominal` is shaped like a real Apple Silicon laptop, and on that hardware a
    /// couple of fields are genuinely never populated — `systemWatts` most of all, which
    /// `PowerCollector` deliberately leaves nil. That makes `nominal` the wrong fixture
    /// for asking whether every series is wired up, because a series nobody remembered
    /// to record and a series this Mac cannot measure look identical from the outside.
    /// This one closes those gaps so coverage tests can tell the two apart. It is not a
    /// plausible machine and should not be used for visual review.
    public static var fullyPopulated: SystemSnapshot {
        var snapshot = nominal
        if var power = snapshot.power.value {
            power.systemWatts = 18.4
            snapshot.power = .value(power)
        }
        return snapshot
    }

    public static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)

    // MARK: Builders

    public static func cpu(busy: Double) -> CPUSnapshot {
        let user = busy * 0.62
        let system = busy * 0.38
        // Cores fan out around the aggregate so per-core bars are not a flat wall.
        let perCore = (0..<11).map { index -> CPULoad in
            let jitter = [0.82, 1.14, 0.71, 1.28, 0.94, 1.06, 0.88, 1.21, 0.77, 1.09, 0.98][index]
            let coreBusy = min(1, busy * jitter)
            return CPULoad(user: coreBusy * 0.62, system: coreBusy * 0.38,
                           idle: 1 - coreBusy, nice: 0)
        }
        return CPUSnapshot(
            total: CPULoad(user: user, system: system, idle: 1 - busy, nice: 0),
            perCore: perCore,
            coreKinds: Array(repeating: .efficiency, count: 6) + Array(repeating: .performance, count: 5),
            loadAverage: LoadAverage(one: busy * 11, five: busy * 8.4, fifteen: busy * 6.1),
            processCount: 648,
            threadCount: 2_314,
            performanceBusy: min(1, busy * 1.12),
            efficiencyBusy: min(1, busy * 0.74)
        )
    }

    public static func memory(usedFraction: Double, pressure: Double) -> MemorySnapshot {
        let total: UInt64 = 19_327_352_832
        let used = UInt64(Double(total) * usedFraction)
        let wired = UInt64(Double(used) * 0.18)
        let compressed = UInt64(Double(used) * 0.36)
        let app = used - wired - compressed
        let cached = UInt64(Double(total - used) * 0.52)
        return MemorySnapshot(
            totalBytes: total,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: cached,
            freeBytes: total - used - cached,
            usedBytes: used,
            memoryPressure: pressure > 0.8 ? .critical : (pressure > 0.6 ? .warning : .normal),
            pressureFraction: pressure,
            swapUsedBytes: UInt64(Double(3_221_225_472) * pressure * 0.6),
            swapTotalBytes: 3_221_225_472,
            pageInsPerSecond: pressure * 840,
            pageOutsPerSecond: pressure * 120,
            swapInsPerSecond: pressure > 0.7 ? pressure * 45 : 0,
            swapOutsPerSecond: pressure > 0.7 ? pressure * 18 : 0,
            compressionsPerSecond: pressure * 610,
            decompressionsPerSecond: pressure * 430
        )
    }

    public static func gpu(utilization: Double) -> GPUSnapshot {
        GPUSnapshot(devices: [
            GPUDevice(id: "builtin", name: "Apple M3 Pro",
                      utilization: utilization,
                      vramUsedBytes: UInt64(Double(13_958_643_712) * utilization * 0.42),
                      vramTotalBytes: 13_958_643_712,
                      isBuiltIn: true, isRemovable: false, coreCount: 14,
                      hasUnifiedMemory: true)
        ], primaryDeviceID: "builtin")
    }

    public static func network(down: Double, up: Double) -> NetworkSnapshot {
        NetworkSnapshot(
            uploadBytesPerSecond: up,
            downloadBytesPerSecond: down,
            totalUploadBytes: 646_857_585,
            totalDownloadBytes: 1_920_994_388,
            sessionUploadBytes: 18_400_221,
            sessionDownloadBytes: 92_118_744,
            interfaces: [
                NetworkInterfaceStats(name: "en0", displayName: "Wi-Fi", type: .wifi,
                                      isActive: true,
                                      uploadBytesPerSecond: up, downloadBytesPerSecond: down,
                                      totalUploadBytes: 646_857_585,
                                      totalDownloadBytes: 1_920_994_388,
                                      ipv4: "10.0.0.69"),
            ],
            primaryInterfaceName: "en0",
            connectionType: .wifi,
            wifi: WiFiInfo(ssid: "Sunnyvale", bssid: nil, rssi: -46, noise: -92,
                           channel: 6, band: "2.4 GHz", transmitRateMbps: 229,
                           security: "WPA3 Personal"),
            localIPv4: "10.0.0.69",
            // A documentation-range address (RFC 5737), so the fixture shows the row the
            // opt-in lookup fills in without any machine's real address in the source.
            publicIP: .value("203.0.113.42"),
            isVPNActive: false
        )
    }

    public static func disk(read: Double, write: Double, usedFraction: Double) -> DiskSnapshot {
        let total: UInt64 = 494_384_795_648
        let free = UInt64(Double(total) * (1 - usedFraction))
        return DiskSnapshot(
            volumes: [
                VolumeInfo(id: "root", name: "Macintosh HD", path: "/",
                           totalBytes: total, freeBytes: free,
                           availableBytes: free + 42_000_000_000,
                           purgeableBytes: 42_000_000_000,
                           isInternal: true, isRemovable: false, isRoot: true,
                           isEjectable: false, fileSystem: "APFS", bsdName: "disk3s1s1"),
                VolumeInfo(id: "ext", name: "Backup", path: "/Volumes/Backup",
                           totalBytes: 2_000_398_934_016, freeBytes: 412_316_860_416,
                           availableBytes: 412_316_860_416, purgeableBytes: 0,
                           isInternal: false, isRemovable: true, isRoot: false,
                           isEjectable: true, fileSystem: "APFS", bsdName: "disk5s2"),
            ],
            readBytesPerSecond: read,
            writeBytesPerSecond: write,
            readOpsPerSecond: read / 65_536,
            writeOpsPerSecond: write / 65_536,
            totalReadBytes: 207_374_182_400,
            totalWriteBytes: 40_802_189_312
        )
    }

    public static func power(percent: Double, charging: Bool) -> PowerSnapshot {
        var power = PowerSnapshot(
            hasBattery: true,
            percentage: percent,
            isCharging: charging,
            isPluggedIn: charging,
            isFullyCharged: false,
            timeToEmpty: charging ? nil : 60 * (38 + percent * 4.2),
            timeToFull: charging ? 60 * 47 : nil,
            cycleCount: 295,
            healthPercent: 92,
            condition: "Normal",
            temperatureCelsius: 30.5,
            voltage: 12.72,
            amperage: charging ? 1_840 : -923,
            batteryWatts: charging ? 23.4 : -11.7,
            designCapacitymAh: 6_249,
            maxCapacitymAh: 5_749,
            currentCapacitymAh: Int(5_749 * percent / 100),
            isLowPowerMode: false,
            adapterWatts: charging ? 96 : nil,
            adapterName: charging ? "96W USB-C Power Adapter" : nil,
            systemWatts: nil,
            isOptimizedChargingPaused: false
        )
        power.accessories = [
            AccessoryBattery(id: "airpods", name: "AirPods Pro", category: "Headphones",
                             percent: 64, isCharging: false, parts: [
                                .init(name: "Left", percent: 64, isCharging: false),
                                .init(name: "Right", percent: 71, isCharging: false),
                                .init(name: "Case", percent: 90, isCharging: false),
                             ]),
            AccessoryBattery(id: "mouse", name: "Magic Mouse", category: "Mouse",
                             percent: 23, isCharging: charging),
        ]
        return power
    }


    public static func desktopPower() -> PowerSnapshot {
        PowerSnapshot(hasBattery: false, isPluggedIn: true, adapterWatts: 143,
                      adapterName: "143W USB-C Power Adapter")
    }

    public static func thermal(cpuTemp: Double, fanRPM: Double) -> ThermalSnapshot {
        ThermalSnapshot(
            pressure: cpuTemp > 95 ? .serious : (cpuTemp > 80 ? .fair : .nominal),
            sensors: [
                TemperatureSensor(id: "Tp0C", name: "CPU Performance Cluster", category: .cpu, celsius: cpuTemp),
                TemperatureSensor(id: "Tp1C", name: "CPU Efficiency Cluster", category: .cpu, celsius: cpuTemp - 6),
                TemperatureSensor(id: "Tg0f", name: "GPU", category: .gpu, celsius: cpuTemp - 9),
                TemperatureSensor(id: "Ts0S", name: "Enclosure Bottom", category: .ambient, celsius: cpuTemp - 22),
                TemperatureSensor(id: "TB0T", name: "Battery", category: .battery, celsius: 30.5),
                TemperatureSensor(id: "TN0S", name: "SSD", category: .storage, celsius: cpuTemp - 14),
            ],
            fans: [
                FanInfo(id: 0, name: "Left Fan", currentRPM: fanRPM, minRPM: 1_200, maxRPM: 6_800),
                FanInfo(id: 1, name: "Right Fan", currentRPM: fanRPM * 0.97, minRPM: 1_200, maxRPM: 6_800),
            ],
            cpuCelsius: cpuTemp,
            gpuCelsius: cpuTemp - 9
        )
    }

    public static func processes(topCPU: Double = 46.2) -> ProcessSnapshot {
        let names: [(String, Double, UInt64, Int)] = [
            ("Xcode", topCPU, 4_284_432_384, 41),
            ("kernel_task", topCPU * 0.42, 1_842_216_960, 612),
            ("WindowServer", topCPU * 0.31, 968_884_224, 28),
            ("Google Chrome Helper (Renderer)", topCPU * 0.24, 742_391_808, 22),
            ("swift-frontend", topCPU * 0.19, 1_284_046_848, 9),
            ("Music", topCPU * 0.08, 412_663_808, 17),
            ("mds_stores", topCPU * 0.05, 186_646_528, 11),
        ]
        return ProcessSnapshot(
            processes: names.enumerated().map { index, entry in
                ProcessRow(pid: Int32(420 + index * 137), parentPID: 1, name: entry.0,
                           executablePath: "/Applications/\(entry.0).app",
                           cpuPercent: entry.1, memoryBytes: entry.2,
                           threadCount: entry.3, userName: "byren",
                           startTime: referenceDate.addingTimeInterval(-3_600))
            },
            totalProcessCount: 648,
            totalThreadCount: 2_314
        )
    }

    public static func system() -> SystemInfoSnapshot {
        // Built by assignment rather than through the 17-argument initialiser: with
        // that many defaulted parameters the type checker exhausts its budget.
        var info = SystemInfoSnapshot()
        info.hostName = "Byrens-Macbook-Pro.local"
        info.computerName = "Byren's MacBook Pro"
        info.modelIdentifier = "Mac15,6"
        info.modelName = "MacBook Pro (14-inch, Nov 2023)"
        info.chipName = "Apple M3 Pro"
        info.osName = "macOS"
        info.osVersion = "26.5.2"
        info.osBuild = "25F84"
        let uptimeSeconds: TimeInterval = 372_060   // 4d 7h 21m
        info.uptime = uptimeSeconds
        info.bootTime = referenceDate.addingTimeInterval(-uptimeSeconds)
        info.physicalCores = 11
        info.logicalCores = 11
        info.performanceCores = 5
        info.efficiencyCores = 6
        info.totalMemoryBytes = 19_327_352_832
        info.isAppleSilicon = true
        info.gpuCoreCount = 14
        return info
    }

    /// History pre-filled with a plausible waveform, so charts render with real shape
    /// instead of a single point.
    public static func history(capacity: Int = 150, interval: TimeInterval = 2) -> MetricHistory {
        var history = MetricHistory(capacity: capacity, sampleInterval: interval)
        for index in 0..<capacity {
            let t = Double(index) / Double(capacity)
            // Two out-of-phase sines plus a decaying spike: enough structure to expose
            // bad curve smoothing, clipping at the top of the plot, and baseline gaps.
            let slow: Double = 0.22 * sin(t * Double.pi * 6)
            let fast: Double = 0.14 * sin(t * Double.pi * 17 + 1.2)
            let base: Double = 0.32 + slow + fast
            var spike: Double = 0
            if t > 0.62 && t < 0.72 {
                spike = 0.44 * (1 - abs(t - 0.67) / 0.05)
            }
            let cpu: Double = min(0.99, max(0.02, base + spike))
            history.record(.cpuTotal, cpu)
            history.record(.cpuUser, cpu * 0.62)
            history.record(.cpuSystem, cpu * 0.38)
            history.record(.cpuPerformance, min(0.99, cpu * 1.15))
            history.record(.cpuEfficiency, cpu * 0.7)
            history.record(.memoryUsed, 0.5 + 0.09 * sin(t * Double.pi * 3))
            history.record(.memoryPressure, 0.28 + 0.07 * sin(t * Double.pi * 2.2))
            history.record(.gpuUtilization, max(0, 0.2 + 0.3 * sin(t * Double.pi * 9 + 0.6)))
            history.record(.networkDownload, max(0, 1_800_000 + 2_600_000 * sin(t * Double.pi * 11)))
            history.record(.networkUpload, max(0, 240_000 + 380_000 * sin(t * Double.pi * 7 + 2)))
            history.record(.diskRead, max(0, 6_000_000 + 9_000_000 * sin(t * Double.pi * 13 + 0.3)))
            history.record(.diskWrite, max(0, 900_000 + 1_400_000 * sin(t * Double.pi * 5)))
            history.record(.batteryPercent, 92 - 16 * t)
            history.record(.cpuTemperature, 44 + 14 * cpu)
            history.record(.fanRPM, 1_400 + 2_600 * cpu)
        }
        history.markSampleDate(referenceDate)
        return history
    }

    /// A day of minute buckets ending at the reference date, with the shape a real
    /// day has: quiet overnight, a working-hours plateau, one spike, and two hours
    /// with no samples at all where the machine slept. Two samples a minute, spread
    /// around the curve, so every bucket has a band and not just a line.
    ///
    /// `collectedMinutes` keeps only the newest that many minutes, which is what a
    /// day looks like on a machine that launched the app that long ago.
    public static func dayHistory(capacity: Int = MinuteHistory.defaultCapacity,
                                  collectedMinutes: Int? = nil) -> MinuteHistory {
        var day = MinuteHistory(capacity: capacity)
        let end = referenceDate
        let firstCollected = collectedMinutes.map { max(0, capacity - $0) } ?? 0
        for index in 0..<capacity {
            let t = Double(index) / Double(capacity)
            let date = end.addingTimeInterval(-Double(capacity - index) * MinuteHistory.bucketDuration)
            day.advance(to: date)
            if index < firstCollected { continue }
            // Asleep from roughly 3 to 5 in the morning of a 24 hour window that ends
            // mid afternoon.
            if t > 0.50 && t < 0.585 { continue }
            let working = t > 0.62 ? 0.24 : (t < 0.30 ? 0.16 : 0.05)
            let wobble = 0.05 * sin(t * Double.pi * 40) + 0.03 * sin(t * Double.pi * 9 + 0.4)
            var spike: Double = 0
            if t > 0.80 && t < 0.83 { spike = 0.55 * (1 - abs(t - 0.815) / 0.015) }
            let cpu = min(0.99, max(0.02, 0.06 + working + wobble + spike))
            for jitter in [0.82, 1.18] {
                let sample = min(0.99, cpu * jitter)
                day.record(.cpuTotal, sample)
                day.record(.cpuUser, sample * 0.62)
                day.record(.cpuSystem, sample * 0.38)
                day.record(.cpuPerformance, min(0.99, sample * 1.15))
                day.record(.cpuEfficiency, sample * 0.7)
                day.record(.memoryUsed, min(0.95, (0.42 + 0.22 * t + 0.04 * sin(t * Double.pi * 7)) * (0.98 + 0.02 * jitter)))
                day.record(.memoryPressure, 0.2 + 0.12 * sin(t * Double.pi * 3) * jitter)
                day.record(.gpuUtilization, max(0, 0.05 + 0.5 * spike + 0.08 * sin(t * Double.pi * 25) * jitter))
                day.record(.networkDownload, max(0, (600_000 + 2_400_000 * working * 4 * abs(sin(t * Double.pi * 31))) * jitter))
                day.record(.networkUpload, max(0, (90_000 + 300_000 * working * abs(sin(t * Double.pi * 17))) * jitter))
                day.record(.diskRead, max(0, (1_500_000 + 12_000_000 * spike + 3_000_000 * working * abs(sin(t * Double.pi * 23))) * jitter))
                day.record(.diskWrite, max(0, (400_000 + 2_000_000 * working * abs(sin(t * Double.pi * 13))) * jitter))
                day.record(.batteryPercent, max(8, min(100, t < 0.3 ? 100 - 20 * t / 0.3 : (t < 0.6 ? 80 + 50 * (t - 0.3) : 100 - 60 * (t - 0.6)))))
                // On the charger for the middle stretch, which is the part of the
                // curve that climbs.
                day.record(.batteryPlugged, t >= 0.3 && t < 0.6 ? 1 : 0)
                day.record(.cpuTemperature, 41 + 22 * sample)
                day.record(.fanRPM, sample > 0.45 ? 1_400 + 3_200 * sample : 0)
            }
            // The minutes a real day would have looked at: the spike, and the
            // working-hours stretch where CPU clears the witness threshold.
            if spike > 0 {
                day.note(.cpu, name: "swift-frontend", value: cpu)
            } else if cpu >= 0.10 {
                day.note(.cpu, name: index % 7 == 0 ? "Google Chrome Helper (Renderer)" : "Xcode", value: cpu)
            }
            if t > 0.9 { day.note(.memory, name: "Xcode", value: 0.42 + 0.22 * t) }
        }
        return day
    }

}
