import Foundation

/// Per-process CPU, memory, threads and I/O.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
public final class ProcessCollector: MetricSource {
    public typealias Output = ProcessSnapshot

    public let identifier: CollectorID = .processes
    public let preferredInterval: TimeInterval = 2.0

    /// How many rows reach the UI. The panel shows a dozen at a time and sorts within
    /// what it is given, so shipping every process would be work nobody looks at.
    private static let rowLimit = 50
    /// Ranked by CPU, the top 50 miss anything idle, and the biggest memory users
    /// usually are idle: an editor left open holds gigabytes at 0%. These extra rows
    /// are the largest resident sets outside the CPU cut, so a memory-ranked list has
    /// the right processes to rank.
    private static let memoryRowLimit = 10
    /// The first pass ranks on resident size, but the row shows phys_footprint, and a
    /// process whose footprint is mostly compressed pages can rank low on one and top
    /// on the other. Reading rusage for every process would double the collector's
    /// cost, so instead twice the tail is fetched and trimmed on the displayed figure.
    private static let memoryCandidateLimit = 20

    /// Cumulative per-process counters carried between samples, keyed by pid.
    private struct Baseline {
        var cpuTime: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var hasIO: Bool
        var seenAt: UInt64
    }

    /// Just enough to rank a process without building a String for one we will drop.
    private struct Candidate {
        var pid: pid_t
        var cpuPercent: Double
        /// Resident size, not phys_footprint: it comes free with the task info every
        /// process is already read for, and it only has to pick which rows get the
        /// real figure from rusage in the second pass.
        var residentBytes: UInt64
    }

    private var baselines: [pid_t: Baseline] = [:]
    private var generation: UInt64 = 0
    private var userNames: [uid_t: String] = [:]
    /// Mach absolute time ticks to seconds; fixed for the life of the process.
    private var tickSeconds: Double = 0
    private var pidBuffer: [pid_t] = []
    private var ownPIDBuffer: [pid_t] = []
    private var candidates: [Candidate] = []
    private var host: host_t = 0
    /// Cleared for good the first time the kernel refuses the zone query.
    private var threadZoneReadable = true
    private var pathBuffer = [CChar]()

    public init() {}

    public func start() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 {
            tickSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        }
        if host == 0 { host = mach_host_self() }
        pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        candidates.reserveCapacity(1024)
        baselines.removeAll(keepingCapacity: true)
        generation = 0
        threadZoneReadable = true
    }

    public func stop() {
        if host != 0 {
            mach_port_deallocate(mach_task_self_, host)
            host = 0
        }
        baselines = [:]
        userNames = [:]
        pidBuffer = []
        ownPIDBuffer = []
        candidates = []
        pathBuffer = []
    }

    public func collect(context: SampleContext) -> MetricState<ProcessSnapshot> {
        if tickSeconds == 0 { start() }

        guard let pidCount = listPIDs(&pidBuffer, filter: UInt32(PROC_ALL_PIDS), argument: 0) else {
            return .failure(.failed("proc_listpids failed: \(String(cString: strerror(errno)))"))
        }

        // Only same-uid processes are inspectable, and PROC_UID_ONLY reproduces
        // proc_pidinfo's permission check exactly, so filtering here drops ~230 calls
        // per sample that could only return EPERM. Elevated, everything is ours.
        let euid = geteuid()
        var ownCount = pidCount
        if euid != 0 {
            guard let own = listPIDs(&ownPIDBuffer, filter: UInt32(PROC_UID_ONLY), argument: euid) else {
                return .failure(.failed("proc_listpids failed: \(String(cString: strerror(errno)))"))
            }
            ownCount = own
        }

        // Cumulative CPU time is meaningless without a previous reading: dividing a
        // process's whole lifetime of CPU by one interval would rank long-running
        // daemons at thousands of percent.
        let rebaselining = context.isFirstSample || context.didWakeFromSleep || context.elapsed <= 0.001
        if context.didWakeFromSleep { baselines.removeAll(keepingCapacity: true) }

        generation &+= 1
        candidates.removeAll(keepingCapacity: true)

        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var totalThreads = 0
        var inspected = 0

        for index in 0..<ownCount {
            let pid = euid == 0 ? pidBuffer[index] : ownPIDBuffer[index]
            guard pid > 0 else { continue }
            let read = withUnsafeMutablePointer(to: &taskInfo) {
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, taskInfoSize)
            }
            // Still possible to fail: the process may have exited since the pid list was
            // taken. Skip it rather than fail a sample over one dead pid.
            guard read == taskInfoSize else { continue }
            inspected += 1
            totalThreads += Int(taskInfo.pti_threadnum)

            // Mach absolute time units, despite the "time" naming — measured against a
            // process pinned to one core, treating them as nanoseconds understates CPU
            // by the timebase ratio (24x on Apple Silicon).
            let cpuTime = taskInfo.pti_total_user &+ taskInfo.pti_total_system
            let previous = baselines[pid]
            // A pid first seen this cycle has no delta to report. Zero is what Activity
            // Monitor shows for the same reason, and it corrects on the next sample.
            var percent = 0.0
            if let previous, !rebaselining, cpuTime >= previous.cpuTime {
                percent = Double(cpuTime - previous.cpuTime) * tickSeconds / context.elapsed * 100
            }
            baselines[pid] = Baseline(cpuTime: cpuTime,
                                      diskRead: previous?.diskRead ?? 0,
                                      diskWrite: previous?.diskWrite ?? 0,
                                      hasIO: previous?.hasIO ?? false,
                                      seenAt: generation)
            candidates.append(Candidate(pid: pid, cpuPercent: percent,
                                        residentBytes: taskInfo.pti_resident_size))
        }

        // Without this the dictionary would accumulate an entry for every process the
        // machine has ever run, which over days of uptime is tens of thousands.
        if baselines.count > inspected {
            let current = generation
            baselines = baselines.filter { $0.value.seenAt == current }
        }

        // See `CPUCollector`: a first sample with nothing to difference against is
        // pending, not failed.
        guard !rebaselining else {
            return .pending
        }

        candidates.sort { $0.cpuPercent > $1.cpuPercent }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(Self.rowLimit + Self.memoryRowLimit)
        for candidate in candidates.prefix(Self.rowLimit) {
            if let row = buildRow(candidate, elapsed: context.elapsed) { rows.append(row) }
        }

        // Rows stay in CPU order end to end: the memory picks all sit below the CPU
        // cut by construction, and are re-sorted among themselves so the tail of the
        // list is ordered the same way as its head.
        if candidates.count > Self.rowLimit {
            candidates[Self.rowLimit...].sort { $0.residentBytes > $1.residentBytes }
            let tailEnd = min(candidates.count, Self.rowLimit + Self.memoryCandidateLimit)
            var tail = candidates[Self.rowLimit..<tailEnd]
                .compactMap { buildRow($0, elapsed: context.elapsed) }
            tail.sort { $0.memoryBytes > $1.memoryBytes }
            tail.removeLast(max(0, tail.count - Self.memoryRowLimit))
            tail.sort { $0.cpuPercent > $1.cpuPercent }
            rows.append(contentsOf: tail)
        }

        // `totalThreads` only covers processes this uid may inspect, which is ~60% of
        // them. The kernel's `threads` zone counts every live thread on the machine and
        // is what CPUSnapshot.threadCount reports — the two are shown side by side in
        // the UI, so they must not disagree by 40%. See CPUCollector for the caveats
        // on mach_zone_info; the summed figure is the fallback.
        return .value(ProcessSnapshot(processes: rows,
                                      totalProcessCount: pidCount,
                                      totalThreadCount: liveThreadCount() ?? totalThreads))
    }

    private func liveThreadCount() -> Int? {
        guard threadZoneReadable else { return nil }
        var names: mach_zone_name_array_t?
        var nameCount: mach_msg_type_number_t = 0
        var info: mach_zone_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard mach_zone_info(host, &names, &nameCount, &info, &infoCount) == KERN_SUCCESS,
              let names, let info else {
            threadZoneReadable = false
            return nil
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: names)),
                          vm_size_t(Int(nameCount) * MemoryLayout<mach_zone_name_t>.size))
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<mach_zone_info_t>.size))
        }
        for index in 0..<min(Int(nameCount), Int(infoCount)) {
            let isThreads = withUnsafeBytes(of: names[index].mzn_name) {
                $0.prefix { $0 != 0 }.elementsEqual("threads".utf8)
            }
            if isThreads { return Int(info[index].mzi_count) }
        }
        threadZoneReadable = false
        return nil
    }

    /// Second pass, run only for the rows that will actually be displayed: names,
    /// paths and rusage cost roughly as much again as ranking every process did.
    private func buildRow(_ candidate: Candidate, elapsed: TimeInterval) -> ProcessRow? {
        var all = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let read = withUnsafeMutablePointer(to: &all) {
            proc_pidinfo(candidate.pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        // The process exited between the two passes; drop it rather than invent a row.
        guard read == size else { return nil }

        let name = cString(all.pbsd.pbi_name).isEmpty
            ? cString(all.pbsd.pbi_comm)
            : cString(all.pbsd.pbi_name)

        let pathLength = pathBuffer.withUnsafeMutableBufferPointer {
            proc_pidpath(candidate.pid, $0.baseAddress, UInt32($0.count))
        }
        let path: String? = pathLength > 0
            ? pathBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            : nil

        var memoryBytes = all.ptinfo.pti_resident_size
        var readRate: Double?
        var writeRate: Double?

        var usage = rusage_info_v4()
        let usageOK = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(candidate.pid, RUSAGE_INFO_V4, $0)
            }
        } == 0

        if usageOK {
            // Activity Monitor's "Memory" column is phys_footprint, not RSS: it counts
            // compressed and IOKit-mapped pages and excludes shared clean ones, so the
            // two disagree by hundreds of megabytes on browsers.
            memoryBytes = usage.ri_phys_footprint
            if var previous = baselines[candidate.pid] {
                if previous.hasIO, elapsed > 0.001 {
                    if usage.ri_diskio_bytesread >= previous.diskRead {
                        readRate = Double(usage.ri_diskio_bytesread - previous.diskRead) / elapsed
                    }
                    if usage.ri_diskio_byteswritten >= previous.diskWrite {
                        writeRate = Double(usage.ri_diskio_byteswritten - previous.diskWrite) / elapsed
                    }
                }
                previous.diskRead = usage.ri_diskio_bytesread
                previous.diskWrite = usage.ri_diskio_byteswritten
                previous.hasIO = true
                baselines[candidate.pid] = previous
            }
        }

        let start = all.pbsd.pbi_start_tvsec > 0
            ? Date(timeIntervalSince1970: Double(all.pbsd.pbi_start_tvsec)
                   + Double(all.pbsd.pbi_start_tvusec) / 1_000_000)
            : nil

        return ProcessRow(pid: candidate.pid,
                          parentPID: pid_t(bitPattern: all.pbsd.pbi_ppid),
                          name: name,
                          executablePath: path,
                          cpuPercent: candidate.cpuPercent,
                          memoryBytes: memoryBytes,
                          threadCount: Int(all.ptinfo.pti_threadnum),
                          userName: userName(for: all.pbsd.pbi_uid),
                          startTime: start,
                          diskReadBytesPerSecond: readRate,
                          diskWriteBytesPerSecond: writeRate,
                          isAppleSignedSystem: path.map(Self.isSystemPath) ?? false)
    }

    /// Approximated from the executable's location rather than its signature: verifying
    /// a real code signature costs milliseconds per process, which is far beyond the
    /// budget for something sampled every two seconds. SIP owns these prefixes, so a
    /// binary living under one is Apple's.
    private static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") || path.hasPrefix("/usr/lib") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/")
            || path.hasPrefix("/Library/Apple/")
    }

    private func userName(for uid: uid_t) -> String? {
        if let cached = userNames[uid] { return cached }
        // getpwuid hits Open Directory, so it is cached: a cold lookup can take
        // milliseconds and the uid of a running process never changes.
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        let resolved = String(cString: name)
        userNames[uid] = resolved
        return resolved
    }

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
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
