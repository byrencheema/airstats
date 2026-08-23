import Foundation

/// CPU load, per-core utilisation, load average, P/E core split.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
public final class CPUCollector: MetricSource {
    public typealias Output = CPUSnapshot

    public let identifier: CollectorID = .cpu
    public let preferredInterval: TimeInterval = 1.0

    private static let stateCount = Int(CPU_STATE_MAX)

    /// How often the thread total is recounted. Counting threads is the single most
    /// expensive thing this collector does, and it is rendered as a plain integer that
    /// drifts by dozens between any two samples anyway — 1 Hz resolution buys nothing.
    /// The tick sampling below still runs on every call.
    private static let threadCountInterval: TimeInterval = 3

    private var host: host_t = 0
    /// Flat `coreCount * CPU_STATE_MAX` tick counters. The two buffers are swapped
    /// rather than reassigned so a 1 Hz collector never allocates on the tick path.
    private var previousTicks: [UInt32] = []
    private var currentTicks: [UInt32] = []
    private var hasBaseline = false
    private var coreKinds: [CoreKind] = []
    /// Reused across samples so enumerating processes does not allocate per sample.
    private var pidBuffer: [pid_t] = []
    private var ownPIDBuffer: [pid_t] = []
    private var cachedThreadCount = 0
    private var threadCountTakenAt: ContinuousClock.Instant?
    /// Cleared for good the first time the kernel refuses the zone query, so a sandbox
    /// that blocks it costs one failed call per session rather than one per sample.
    private var threadZoneReadable = true

    public init() {}

    public func start() {
        if host == 0 { host = mach_host_self() }
        coreKinds = Self.resolveCoreKinds()
        hasBaseline = false
        threadCountTakenAt = nil
        threadZoneReadable = true
    }

    public func stop() {
        if host != 0 {
            mach_port_deallocate(mach_task_self_, host)
            host = 0
        }
        hasBaseline = false
        previousTicks = []
        currentTicks = []
        pidBuffer = []
        ownPIDBuffer = []
        coreKinds = []
        threadCountTakenAt = nil
        cachedThreadCount = 0
    }

    public func collect(context: SampleContext) -> MetricState<CPUSnapshot> {
        if host == 0 { start() }

        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, coreCount > 0 else {
            return .failure(.failed("host_processor_info: \(machMessage(result))"))
        }

        let wanted = Int(coreCount) * Self.stateCount
        if currentTicks.count != wanted { currentTicks = [UInt32](repeating: 0, count: wanted) }
        for index in 0..<min(wanted, Int(infoCount)) {
            currentTicks[index] = UInt32(bitPattern: info[index])
        }
        // The kernel hands back a freshly mapped VM region on every call; leaking it
        // would cost this process a page per second for as long as AirStat runs.
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))

        // Whatever this sample concludes, it becomes the baseline for the next one.
        defer {
            swap(&previousTicks, &currentTicks)
            hasBaseline = true
        }

        // These counters are cumulative since boot, so the first sample after launch,
        // after a wake, or after a core-count change can only establish a baseline —
        // differencing against zero would report "average usage since boot" instead.
        // `.pending`, not `.failed`: nothing has gone wrong, the reading simply does
        // not exist yet and will on the next tick. The UI treats the two differently
        // — a pending module holds its full height open, because it is about to be
        // filled in, and a failed one collapses — so calling this a failure made the
        // desktop widget open a row short and then jump.
        guard hasBaseline, !context.isFirstSample, !context.didWakeFromSleep,
              previousTicks.count == wanted else {
            return .pending
        }

        var perCore: [CPULoad] = []
        perCore.reserveCapacity(Int(coreCount))
        var totalUser = 0.0, totalSystem = 0.0, totalIdle = 0.0, totalNice = 0.0
        var performanceBusy = 0.0, performanceTotal = 0.0
        var efficiencyBusy = 0.0, efficiencyTotal = 0.0
        let kindsUsable = coreKinds.count == Int(coreCount)

        for core in 0..<Int(coreCount) {
            let base = core * Self.stateCount
            // Wrapping subtraction is correct here: the counters are 32-bit and roll
            // over after ~497 days of uptime, and one wrap differences exactly.
            let user = Double(currentTicks[base + Int(CPU_STATE_USER)] &- previousTicks[base + Int(CPU_STATE_USER)])
            let system = Double(currentTicks[base + Int(CPU_STATE_SYSTEM)] &- previousTicks[base + Int(CPU_STATE_SYSTEM)])
            let idle = Double(currentTicks[base + Int(CPU_STATE_IDLE)] &- previousTicks[base + Int(CPU_STATE_IDLE)])
            let nice = Double(currentTicks[base + Int(CPU_STATE_NICE)] &- previousTicks[base + Int(CPU_STATE_NICE)])
            let span = user + system + idle + nice

            totalUser += user; totalSystem += system; totalIdle += idle; totalNice += nice

            // A parked core accrues no ticks at all over a very short window. It did no
            // work, so idle is the only reading the data supports.
            let load = span > 0
                ? CPULoad(user: user / span, system: system / span, idle: idle / span, nice: nice / span)
                : CPULoad.idleLoad
            perCore.append(load)

            guard kindsUsable else { continue }
            switch coreKinds[core] {
            case .performance:
                performanceBusy += user + system + nice
                performanceTotal += span
            case .efficiency:
                efficiencyBusy += user + system + nice
                efficiencyTotal += span
            case .unknown:
                break
            }
        }

        let grandTotal = totalUser + totalSystem + totalIdle + totalNice
        guard grandTotal > 0 else {
            return .failure(.failed("no CPU ticks accrued since last sample"))
        }

        var loadValues = [Double](repeating: 0, count: 3)
        guard getloadavg(&loadValues, 3) == 3 else {
            return .failure(.failed("getloadavg failed"))
        }

        guard let processes = processCount(), let threads = threadCount() else {
            return .failure(.failed("proc_listpids failed: \(errnoMessage())"))
        }

        return .value(CPUSnapshot(
            total: CPULoad(user: totalUser / grandTotal,
                           system: totalSystem / grandTotal,
                           idle: totalIdle / grandTotal,
                           nice: totalNice / grandTotal),
            perCore: perCore,
            coreKinds: kindsUsable ? coreKinds : Array(repeating: .unknown, count: Int(coreCount)),
            loadAverage: LoadAverage(one: loadValues[0], five: loadValues[1], fifteen: loadValues[2]),
            processCount: processes,
            threadCount: threads,
            performanceBusy: performanceTotal > 0 ? performanceBusy / performanceTotal : nil,
            efficiencyBusy: efficiencyTotal > 0 ? efficiencyBusy / efficiencyTotal : nil))
    }

    /// Maps each index of `host_processor_info`'s array onto a core cluster.
    ///
    /// The kernel numbers logical CPUs starting at the *last* performance level and
    /// working back to `perflevel0`, so on a 5P/6E machine indices 0...5 are the
    /// efficiency cluster. That ordering is not documented, so it was verified on this
    /// hardware: six background-QoS spinners drove indices 0-5 to 100% while five
    /// user-interactive spinners drove indices 6-10 instead.
    private static func resolveCoreKinds() -> [CoreKind] {
        let logical = sysctlInt("hw.logicalcpu") ?? sysctlInt("hw.ncpu") ?? 0
        guard logical > 0 else { return [] }

        let unknown = [CoreKind](repeating: .unknown, count: logical)
        // Intel Macs have no perflevel keys at all; a single level means every core is
        // the same and there is no meaningful P/E split to report.
        guard let levels = sysctlInt("hw.nperflevels"), levels > 1 else { return unknown }

        var kinds: [CoreKind] = []
        kinds.reserveCapacity(logical)
        for level in stride(from: levels - 1, through: 0, by: -1) {
            guard let count = sysctlInt("hw.perflevel\(level).logicalcpu"), count > 0 else { return unknown }
            kinds.append(contentsOf: [CoreKind](repeating: level == 0 ? .performance : .efficiency,
                                                count: count))
        }
        // If the clusters do not account for exactly the logical CPUs the kernel
        // reports, the index mapping is a guess — say "unknown" rather than mislabel.
        return kinds.count == logical ? kinds : unknown
    }

    /// Exact, and cheap enough to run every sample: one `proc_listpids` costs ~0.01 ms
    /// because the kernel only copies out a pid per process.
    private func processCount() -> Int? {
        listPIDs(&pidBuffer, filter: UInt32(PROC_ALL_PIDS), argument: 0)
    }

    private func threadCount() -> Int? {
        if let taken = threadCountTakenAt, Monotonic.seconds(since: taken) < Self.threadCountInterval {
            return cachedThreadCount
        }
        var counted = threadZoneReadable ? liveThreadCount() : nil
        if counted == nil {
            threadZoneReadable = false
            counted = ownedThreadCount()
        }
        guard let counted else { return nil }
        cachedThreadCount = counted
        threadCountTakenAt = Monotonic.now
        return counted
    }

    /// The kernel keeps one `threads` zone element per live thread, so its element count
    /// is the whole machine's thread total — the only such figure an unentitled process
    /// can read. Verified against `top`: spawning 200 threads moved this by 248 while
    /// `top` moved by 250, and it tracks `top` with a constant ~34 offset for the kernel's
    /// own unattributed threads.
    ///
    /// `mach_zone_info` is declared in `<mach/mach_host.h>` but is not a documented
    /// interface and the zone name is a kernel implementation detail, so both the call
    /// and the lookup are treated as failable and fall back to `ownedThreadCount`.
    private func liveThreadCount() -> Int? {
        var names: mach_zone_name_array_t?
        var nameCount: mach_msg_type_number_t = 0
        var info: mach_zone_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard mach_zone_info(host, &names, &nameCount, &info, &infoCount) == KERN_SUCCESS,
              let names, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: names)),
                          vm_size_t(Int(nameCount) * MemoryLayout<mach_zone_name_t>.size))
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<mach_zone_info_t>.size))
        }
        for index in 0..<min(Int(nameCount), Int(infoCount)) {
            // Compared as bytes so scanning 292 zone names allocates no Strings.
            let isThreads = withUnsafeBytes(of: names[index].mzn_name) {
                $0.prefix { $0 != 0 }.elementsEqual("threads".utf8)
            }
            if isThreads { return Int(info[index].mzi_count) }
        }
        return nil
    }

    /// Fallback when the zone query is unavailable: sum the threads of every process this
    /// uid may inspect. `proc_pidinfo` returns EPERM for other users' processes, so this
    /// undercounts by roughly 40% on a normal Mac. Reading the rest needs
    /// `com.apple.system-task-ports.read`, an Apple-only entitlement `top` carries.
    private func ownedThreadCount() -> Int? {
        // Asking the kernel for our own uid's pids skips ~230 calls that could only ever
        // return EPERM: PROC_UID_ONLY(geteuid()) matches proc_pidinfo's own permission
        // check exactly. Elevated is the one case where that would hide most of the machine.
        let euid = geteuid()
        let filter = euid == 0 ? UInt32(PROC_ALL_PIDS) : UInt32(PROC_UID_ONLY)
        guard let count = listPIDs(&ownPIDBuffer, filter: filter, argument: euid == 0 ? 0 : euid) else {
            return nil
        }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        var threads = 0
        for index in 0..<count where ownPIDBuffer[index] > 0 {
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(ownPIDBuffer[index], PROC_PIDTASKINFO, 0, $0, size)
            }
            if read == size { threads += Int(info.pti_threadnum) }
        }
        return threads
    }
}

/// Fills `buffer`, growing it as needed, and returns how many entries are valid.
private func listPIDs(_ buffer: inout [pid_t], filter: UInt32, argument: UInt32) -> Int? {
    if buffer.isEmpty { buffer = [pid_t](repeating: 0, count: 1024) }
    let pidSize = MemoryLayout<pid_t>.size
    while true {
        let bytes = buffer.withUnsafeMutableBufferPointer {
            proc_listpids(filter, argument, $0.baseAddress, Int32($0.count * pidSize))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / pidSize
        // proc_listpids truncates silently, so an exactly-full buffer means the tail
        // of the process list was dropped.
        guard count == buffer.count else { return count }
        buffer = [pid_t](repeating: 0, count: buffer.count * 2)
    }
}

/// File-scoped on purpose: every collector lives in the same module, so a shared
/// helper here would collide with the identically-named one another collector needs.
private func sysctlInt(_ name: String) -> Int? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    switch size {
    case MemoryLayout<Int32>.size:
        var value: Int32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    case MemoryLayout<Int64>.size:
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    default:
        return nil
    }
}

private func machMessage(_ code: kern_return_t) -> String {
    guard let text = mach_error_string(code) else { return "kern_return \(code)" }
    return "\(String(cString: text)) (\(code))"
}

private func errnoMessage() -> String {
    String(cString: strerror(errno))
}
