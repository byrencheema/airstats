import Foundation

// MARK: - CPU

public enum CoreKind: String, Sendable, Equatable, Hashable, Codable {
    case performance, efficiency, unknown

    public var shortLabel: String {
        switch self {
        case .performance: return "P"
        case .efficiency: return "E"
        case .unknown: return ""
        }
    }
}

/// Fractions of a single core's time, each in 0...1, summing to ~1.
public struct CPULoad: Sendable, Equatable, Hashable {
    public var user: Double
    public var system: Double
    public var idle: Double
    public var nice: Double

    public init(user: Double = 0, system: Double = 0, idle: Double = 1, nice: Double = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Total non-idle fraction, 0...1.
    public var busy: Double { max(0, min(1, user + system + nice)) }

    public static let idleLoad = CPULoad()
}

public struct LoadAverage: Sendable, Equatable, Hashable {
    public var one: Double
    public var five: Double
    public var fifteen: Double
    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

public struct CPUSnapshot: Sendable, Equatable {
    public var total: CPULoad
    public var perCore: [CPULoad]
    public var coreKinds: [CoreKind]
    public var loadAverage: LoadAverage
    public var processCount: Int
    public var threadCount: Int
    /// Aggregate P-core and E-core busy fractions, when core kinds are known.
    public var performanceBusy: Double?
    public var efficiencyBusy: Double?

    public init(total: CPULoad = .idleLoad,
                perCore: [CPULoad] = [],
                coreKinds: [CoreKind] = [],
                loadAverage: LoadAverage = .init(one: 0, five: 0, fifteen: 0),
                processCount: Int = 0,
                threadCount: Int = 0,
                performanceBusy: Double? = nil,
                efficiencyBusy: Double? = nil) {
        self.total = total
        self.perCore = perCore
        self.coreKinds = coreKinds
        self.loadAverage = loadAverage
        self.processCount = processCount
        self.threadCount = threadCount
        self.performanceBusy = performanceBusy
        self.efficiencyBusy = efficiencyBusy
    }
}

// MARK: - Memory

public enum MemoryPressureLevel: Int, Sendable, Equatable, Hashable, Codable, Comparable {
    case normal = 0, warning = 1, critical = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var totalBytes: UInt64
    /// App (anonymous, non-purgeable) memory.
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    /// File-backed / cached pages — reclaimable, matches Activity Monitor's "Cached Files".
    public var cachedBytes: UInt64
    public var freeBytes: UInt64
    /// app + wired + compressed, matching Activity Monitor's "Memory Used".
    public var usedBytes: UInt64
    public var memoryPressure: MemoryPressureLevel
    /// 0...1, the value Activity Monitor graphs as the pressure bar.
    public var pressureFraction: Double
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var pageInsPerSecond: Double
    public var pageOutsPerSecond: Double
    public var swapInsPerSecond: Double
    public var swapOutsPerSecond: Double
    /// Cumulative compressor activity, useful for "is the machine thrashing" readouts.
    public var compressionsPerSecond: Double
    public var decompressionsPerSecond: Double

    public init(totalBytes: UInt64 = 0, appBytes: UInt64 = 0, wiredBytes: UInt64 = 0,
                compressedBytes: UInt64 = 0, cachedBytes: UInt64 = 0, freeBytes: UInt64 = 0,
                usedBytes: UInt64 = 0, memoryPressure: MemoryPressureLevel = .normal,
                pressureFraction: Double = 0, swapUsedBytes: UInt64 = 0, swapTotalBytes: UInt64 = 0,
                pageInsPerSecond: Double = 0, pageOutsPerSecond: Double = 0,
                swapInsPerSecond: Double = 0, swapOutsPerSecond: Double = 0,
                compressionsPerSecond: Double = 0, decompressionsPerSecond: Double = 0) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.memoryPressure = memoryPressure
        self.pressureFraction = pressureFraction
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pageInsPerSecond = pageInsPerSecond
        self.pageOutsPerSecond = pageOutsPerSecond
        self.swapInsPerSecond = swapInsPerSecond
        self.swapOutsPerSecond = swapOutsPerSecond
        self.compressionsPerSecond = compressionsPerSecond
        self.decompressionsPerSecond = decompressionsPerSecond
    }

    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

// MARK: - GPU

public struct GPUDevice: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// 0...1. Nil when the driver exposes no utilisation channel.
    public var utilization: Double?
    public var vramUsedBytes: UInt64?
    public var vramTotalBytes: UInt64?
    public var isBuiltIn: Bool
    public var isRemovable: Bool
    public var coreCount: Int?
    /// Distinct from `utilization`: fraction of time the device scheduler was busy.
    public var rendererUtilization: Double?
    public var tilerUtilization: Double?
    /// True on Apple Silicon, where the GPU shares system RAM. When this is set,
    /// `vramTotalBytes` is a working-set budget carved out of unified memory, not
    /// dedicated video RAM — the UI must say "Memory", never "VRAM", or it implies
    /// the machine has gigabytes of dedicated VRAM that do not exist.
    public var hasUnifiedMemory: Bool

    public init(id: String, name: String, utilization: Double? = nil,
                vramUsedBytes: UInt64? = nil, vramTotalBytes: UInt64? = nil,
                isBuiltIn: Bool = true, isRemovable: Bool = false, coreCount: Int? = nil,
                rendererUtilization: Double? = nil, tilerUtilization: Double? = nil,
                hasUnifiedMemory: Bool = false) {
        self.id = id
        self.name = name
        self.utilization = utilization
        self.vramUsedBytes = vramUsedBytes
        self.vramTotalBytes = vramTotalBytes
        self.isBuiltIn = isBuiltIn
        self.isRemovable = isRemovable
        self.coreCount = coreCount
        self.rendererUtilization = rendererUtilization
        self.tilerUtilization = tilerUtilization
        self.hasUnifiedMemory = hasUnifiedMemory
    }

    /// What to call this device's memory in the UI.
    public var memoryLabel: String { hasUnifiedMemory ? "Memory" : "VRAM" }
}

public struct GPUSnapshot: Sendable, Equatable {
    public var devices: [GPUDevice]
    /// The device the window server is driving, if identifiable.
    public var primaryDeviceID: String?

    public init(devices: [GPUDevice] = [], primaryDeviceID: String? = nil) {
        self.devices = devices
        self.primaryDeviceID = primaryDeviceID
    }

    public var primary: GPUDevice? {
        if let id = primaryDeviceID, let d = devices.first(where: { $0.id == id }) { return d }
        return devices.first
    }
}

// MARK: - Network

public enum ConnectionType: String, Sendable, Equatable, Hashable, Codable {
    case wifi, ethernet, cellular, vpn, loopback, other, none

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .vpn: return "VPN"
        case .loopback: return "Loopback"
        case .other: return "Other"
        case .none: return "Offline"
        }
    }
}

public struct NetworkInterfaceStats: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var type: ConnectionType
    public var isActive: Bool
    public var uploadBytesPerSecond: Double
    public var downloadBytesPerSecond: Double
    public var totalUploadBytes: UInt64
    public var totalDownloadBytes: UInt64
    public var ipv4: String?
    public var ipv6: String?
    public var macAddress: String?

    public init(name: String, displayName: String, type: ConnectionType, isActive: Bool,
                uploadBytesPerSecond: Double = 0, downloadBytesPerSecond: Double = 0,
                totalUploadBytes: UInt64 = 0, totalDownloadBytes: UInt64 = 0,
                ipv4: String? = nil, ipv6: String? = nil, macAddress: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.type = type
        self.isActive = isActive
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.totalUploadBytes = totalUploadBytes
        self.totalDownloadBytes = totalDownloadBytes
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.macAddress = macAddress
    }
}

public struct WiFiInfo: Sendable, Equatable, Hashable {
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int?
    public var noise: Int?
    public var channel: Int?
    public var band: String?
    public var transmitRateMbps: Double?
    public var security: String?

    public init(ssid: String? = nil, bssid: String? = nil, rssi: Int? = nil, noise: Int? = nil,
                channel: Int? = nil, band: String? = nil, transmitRateMbps: Double? = nil,
                security: String? = nil) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.transmitRateMbps = transmitRateMbps
        self.security = security
    }

    /// Signal quality 0...1 derived from RSSI, using the same -100…-50 dBm ramp
    /// macOS uses for its own menu bar Wi-Fi glyph.
    public var signalQuality: Double? {
        guard let rssi else { return nil }
        return max(0, min(1, (Double(rssi) + 100) / 50))
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public var uploadBytesPerSecond: Double
    public var downloadBytesPerSecond: Double
    /// Bytes since the machine booted (sum over physical interfaces).
    public var totalUploadBytes: UInt64
    public var totalDownloadBytes: UInt64
    /// Bytes since AirStat launched.
    public var sessionUploadBytes: UInt64
    public var sessionDownloadBytes: UInt64
    public var interfaces: [NetworkInterfaceStats]
    public var primaryInterfaceName: String?
    public var connectionType: ConnectionType
    public var wifi: WiFiInfo?
    public var localIPv4: String?
    public var publicIP: MetricState<String>
    public var isVPNActive: Bool

    public init(uploadBytesPerSecond: Double = 0, downloadBytesPerSecond: Double = 0,
                totalUploadBytes: UInt64 = 0, totalDownloadBytes: UInt64 = 0,
                sessionUploadBytes: UInt64 = 0, sessionDownloadBytes: UInt64 = 0,
                interfaces: [NetworkInterfaceStats] = [], primaryInterfaceName: String? = nil,
                connectionType: ConnectionType = .none, wifi: WiFiInfo? = nil,
                localIPv4: String? = nil, publicIP: MetricState<String> = .pending,
                isVPNActive: Bool = false) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.totalUploadBytes = totalUploadBytes
        self.totalDownloadBytes = totalDownloadBytes
        self.sessionUploadBytes = sessionUploadBytes
        self.sessionDownloadBytes = sessionDownloadBytes
        self.interfaces = interfaces
        self.primaryInterfaceName = primaryInterfaceName
        self.connectionType = connectionType
        self.wifi = wifi
        self.localIPv4 = localIPv4
        self.publicIP = publicIP
        self.isVPNActive = isVPNActive
    }
}

// MARK: - Disk

public struct VolumeInfo: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    /// Free space the OS will hand out without purging purgeable caches.
    public var availableBytes: UInt64
    public var purgeableBytes: UInt64
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isRoot: Bool
    public var isEjectable: Bool
    public var fileSystem: String?
    public var bsdName: String?

    public init(id: String, name: String, path: String, totalBytes: UInt64, freeBytes: UInt64,
                availableBytes: UInt64, purgeableBytes: UInt64 = 0, isInternal: Bool = true,
                isRemovable: Bool = false, isRoot: Bool = false, isEjectable: Bool = false,
                fileSystem: String? = nil, bsdName: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isRoot = isRoot
        self.isEjectable = isEjectable
        self.fileSystem = fileSystem
        self.bsdName = bsdName
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

public struct DiskSnapshot: Sendable, Equatable {
    public var volumes: [VolumeInfo]
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var readOpsPerSecond: Double
    public var writeOpsPerSecond: Double
    public var totalReadBytes: UInt64
    public var totalWriteBytes: UInt64

    public init(volumes: [VolumeInfo] = [], readBytesPerSecond: Double = 0,
                writeBytesPerSecond: Double = 0, readOpsPerSecond: Double = 0,
                writeOpsPerSecond: Double = 0, totalReadBytes: UInt64 = 0,
                totalWriteBytes: UInt64 = 0) {
        self.volumes = volumes
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOpsPerSecond = readOpsPerSecond
        self.writeOpsPerSecond = writeOpsPerSecond
        self.totalReadBytes = totalReadBytes
        self.totalWriteBytes = totalWriteBytes
    }

    public var rootVolume: VolumeInfo? { volumes.first(where: { $0.isRoot }) }
}

// MARK: - Power

public struct PowerSnapshot: Sendable, Equatable {
    public var hasBattery: Bool
    /// 0...100.
    public var percentage: Double?
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var timeToEmpty: TimeInterval?
    public var timeToFull: TimeInterval?
    public var cycleCount: Int?
    /// maxCapacity / designCapacity as a percentage.
    public var healthPercent: Double?
    public var condition: String?
    public var temperatureCelsius: Double?
    public var voltage: Double?
    /// Negative while discharging, positive while charging.
    public var amperage: Double?
    public var batteryWatts: Double?
    public var designCapacitymAh: Int?
    public var maxCapacitymAh: Int?
    public var currentCapacitymAh: Int?
    public var isLowPowerMode: Bool
    public var adapterWatts: Int?
    public var adapterName: String?
    /// Total system power draw where the platform exposes it.
    public var systemWatts: Double?
    /// True when macOS is holding the charge at ~80% for battery longevity.
    public var isOptimizedChargingPaused: Bool
    /// Batteries in things attached to the Mac: earbuds, a mouse, a keyboard.
    /// Whatever the power source list reports for accessories, read once a minute.
    public var accessories: [AccessoryBattery] = []

    public init(hasBattery: Bool = false, percentage: Double? = nil, isCharging: Bool = false,
                isPluggedIn: Bool = false, isFullyCharged: Bool = false,
                timeToEmpty: TimeInterval? = nil, timeToFull: TimeInterval? = nil,
                cycleCount: Int? = nil, healthPercent: Double? = nil, condition: String? = nil,
                temperatureCelsius: Double? = nil, voltage: Double? = nil, amperage: Double? = nil,
                batteryWatts: Double? = nil, designCapacitymAh: Int? = nil,
                maxCapacitymAh: Int? = nil, currentCapacitymAh: Int? = nil,
                isLowPowerMode: Bool = false, adapterWatts: Int? = nil, adapterName: String? = nil,
                systemWatts: Double? = nil, isOptimizedChargingPaused: Bool = false) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.timeToEmpty = timeToEmpty
        self.timeToFull = timeToFull
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.voltage = voltage
        self.amperage = amperage
        self.batteryWatts = batteryWatts
        self.designCapacitymAh = designCapacitymAh
        self.maxCapacitymAh = maxCapacitymAh
        self.currentCapacitymAh = currentCapacitymAh
        self.isLowPowerMode = isLowPowerMode
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
        self.systemWatts = systemWatts
        self.isOptimizedChargingPaused = isOptimizedChargingPaused
    }
}

/// One accessory's battery, as the power source list reports it.
///
/// Earbuds arrive as several sources that share a group: a part for each bud, one
/// for the case, and sometimes a combined figure. They are folded into one accessory
/// here, with the parts kept, so the panel can show "L 80% R 78% Case 90%" on one
/// row instead of three rows called AirPods.
public struct AccessoryBattery: Sendable, Equatable, Identifiable {
    public struct Part: Sendable, Equatable {
        /// "Left", "Right", "Case", as reported.
        public var name: String
        /// 0...100.
        public var percent: Double
        public var isCharging: Bool

        public init(name: String, percent: Double, isCharging: Bool) {
            self.name = name
            self.percent = percent
            self.isCharging = isCharging
        }
    }

    public var id: String
    public var name: String
    /// The reported category, "Headphones" or "Mouse", when there is one.
    public var category: String?
    /// The headline charge: the combined figure when one is reported, otherwise the
    /// lowest part, since the accessory stops working when its emptiest part does.
    public var percent: Double
    public var isCharging: Bool
    public var parts: [Part]

    public init(id: String, name: String, category: String? = nil, percent: Double,
                isCharging: Bool = false, parts: [Part] = []) {
        self.id = id
        self.name = name
        self.category = category
        self.percent = percent
        self.isCharging = isCharging
        self.parts = parts
    }
}

// MARK: - Thermal

public enum ThermalPressure: Int, Sendable, Equatable, Hashable, Codable, Comparable {

    case nominal = 0, fair = 1, serious = 2, critical = 3
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

public enum SensorCategory: String, Sendable, Equatable, Hashable, Codable {
    case cpu, gpu, memory, storage, battery, ambient, power, other
}

public struct TemperatureSensor: Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: SensorCategory
    public var celsius: Double

    public init(id: String, name: String, category: SensorCategory, celsius: Double) {
        self.id = id
        self.name = name
        self.category = category
        self.celsius = celsius
    }
}

public struct FanInfo: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var currentRPM: Double
    public var minRPM: Double?
    public var maxRPM: Double?

    public init(id: Int, name: String, currentRPM: Double, minRPM: Double? = nil, maxRPM: Double? = nil) {
        self.id = id
        self.name = name
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    /// 0...1 position between min and max, for the fan dial.
    public var loadFraction: Double? {
        guard let minRPM, let maxRPM, maxRPM > minRPM else { return nil }
        return max(0, min(1, (currentRPM - minRPM) / (maxRPM - minRPM)))
    }
}

public struct ThermalSnapshot: Sendable, Equatable {
    public var pressure: ThermalPressure
    public var sensors: [TemperatureSensor]
    public var fans: [FanInfo]
    /// Representative CPU die temperature, averaged across cluster sensors.
    public var cpuCelsius: Double?
    public var gpuCelsius: Double?
    /// True when no temperature sensors are readable on this machine (common on
    /// Apple Silicon without elevated privileges) — the UI degrades to pressure only.
    public var sensorsUnavailableReason: String?

    public init(pressure: ThermalPressure = .nominal, sensors: [TemperatureSensor] = [],
                fans: [FanInfo] = [], cpuCelsius: Double? = nil, gpuCelsius: Double? = nil,
                sensorsUnavailableReason: String? = nil) {
        self.pressure = pressure
        self.sensors = sensors
        self.fans = fans
        self.cpuCelsius = cpuCelsius
        self.gpuCelsius = gpuCelsius
        self.sensorsUnavailableReason = sensorsUnavailableReason
    }
}

// MARK: - Processes

public enum ProcessSortKey: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case cpu, memory, energy, diskIO, networkIO, name, pid

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .energy: return "Energy"
        case .diskIO: return "Disk"
        case .networkIO: return "Network"
        case .name: return "Name"
        case .pid: return "PID"
        }
    }
}

public struct ProcessRow: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var executablePath: String?
    public var bundleIdentifier: String?
    /// Percent of one core, so it can exceed 100 on multicore machines —
    /// same convention Activity Monitor uses.
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var threadCount: Int
    public var userName: String?
    public var startTime: Date?
    public var energyImpact: Double?
    public var diskReadBytesPerSecond: Double?
    public var diskWriteBytesPerSecond: Double?
    public var isAppleSignedSystem: Bool

    public init(pid: Int32, parentPID: Int32 = 0, name: String, executablePath: String? = nil,
                bundleIdentifier: String? = nil, cpuPercent: Double = 0, memoryBytes: UInt64 = 0,
                threadCount: Int = 0, userName: String? = nil, startTime: Date? = nil,
                energyImpact: Double? = nil, diskReadBytesPerSecond: Double? = nil,
                diskWriteBytesPerSecond: Double? = nil, isAppleSignedSystem: Bool = false) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.threadCount = threadCount
        self.userName = userName
        self.startTime = startTime
        self.energyImpact = energyImpact
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.isAppleSignedSystem = isAppleSignedSystem
    }
}

public struct ProcessSnapshot: Sendable, Equatable {
    public var processes: [ProcessRow]
    public var totalProcessCount: Int
    public var totalThreadCount: Int

    public init(processes: [ProcessRow] = [], totalProcessCount: Int = 0, totalThreadCount: Int = 0) {
        self.processes = processes
        self.totalProcessCount = totalProcessCount
        self.totalThreadCount = totalThreadCount
    }
}

// MARK: - System info

public struct SystemInfoSnapshot: Sendable, Equatable {
    public var hostName: String
    public var computerName: String
    public var modelIdentifier: String
    public var modelName: String
    public var chipName: String
    public var osName: String
    public var osVersion: String
    public var osBuild: String
    public var uptime: TimeInterval
    public var bootTime: Date
    public var physicalCores: Int
    public var logicalCores: Int
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var totalMemoryBytes: UInt64
    public var isAppleSilicon: Bool
    public var gpuCoreCount: Int?

    public init(hostName: String = "", computerName: String = "", modelIdentifier: String = "",
                modelName: String = "", chipName: String = "", osName: String = "macOS",
                osVersion: String = "", osBuild: String = "", uptime: TimeInterval = 0,
                bootTime: Date = Date(), physicalCores: Int = 0, logicalCores: Int = 0,
                performanceCores: Int = 0, efficiencyCores: Int = 0, totalMemoryBytes: UInt64 = 0,
                isAppleSilicon: Bool = false, gpuCoreCount: Int? = nil) {
        self.hostName = hostName
        self.computerName = computerName
        self.modelIdentifier = modelIdentifier
        self.modelName = modelName
        self.chipName = chipName
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.uptime = uptime
        self.bootTime = bootTime
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.totalMemoryBytes = totalMemoryBytes
        self.isAppleSilicon = isAppleSilicon
        self.gpuCoreCount = gpuCoreCount
    }
}

// MARK: - Composite

/// One coherent view of the machine. Every field is a `MetricState`, so a module
/// that cannot be sampled on this hardware degrades independently of the others.
public struct SystemSnapshot: Sendable, Equatable {
    public var cpu: MetricState<CPUSnapshot>
    public var memory: MetricState<MemorySnapshot>
    public var gpu: MetricState<GPUSnapshot>
    public var network: MetricState<NetworkSnapshot>
    public var disk: MetricState<DiskSnapshot>
    public var power: MetricState<PowerSnapshot>
    public var thermal: MetricState<ThermalSnapshot>
    public var processes: MetricState<ProcessSnapshot>
    /// Whether `processes` was collected in this very sample. The process slot keeps
    /// its last rows between runs, so a snapshot taken with the panel closed still
    /// carries whatever was on screen when it shut; anything that reads the rows as
    /// "what is running now" has to check this first.
    public var processesSampled: Bool
    public var system: MetricState<SystemInfoSnapshot>
    public var capturedAt: Date
    /// Monotonic capture instant, used for staleness checks across sleep.
    public var capturedInstant: ContinuousClock.Instant

    public init(cpu: MetricState<CPUSnapshot> = .pending,
                memory: MetricState<MemorySnapshot> = .pending,
                gpu: MetricState<GPUSnapshot> = .pending,
                network: MetricState<NetworkSnapshot> = .pending,
                disk: MetricState<DiskSnapshot> = .pending,
                power: MetricState<PowerSnapshot> = .pending,
                thermal: MetricState<ThermalSnapshot> = .pending,
                processes: MetricState<ProcessSnapshot> = .pending,
                processesSampled: Bool = false,
                system: MetricState<SystemInfoSnapshot> = .pending,
                capturedAt: Date = Date(),
                capturedInstant: ContinuousClock.Instant = Monotonic.now) {
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.network = network
        self.disk = disk
        self.power = power
        self.thermal = thermal
        self.processes = processes
        self.processesSampled = processesSampled
        self.system = system
        self.capturedAt = capturedAt
        self.capturedInstant = capturedInstant
    }

    public static let empty = SystemSnapshot()
}
