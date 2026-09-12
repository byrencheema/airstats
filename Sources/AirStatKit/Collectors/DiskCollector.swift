import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

/// Volume capacity and block-device read/write throughput.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
public final class DiskCollector: MetricSource {
    public typealias Output = DiskSnapshot

    public let identifier: CollectorID = .disk
    public let preferredInterval: TimeInterval = 2.0

    /// Cumulative counters for one `IOBlockStorageDriver`.
    ///
    /// Deliberately per-drive rather than one set of deltas over the summed total:
    /// when a drive is attached its counters start at whatever the driver has already
    /// accumulated, and differencing the sum would report that entire history as a
    /// single-interval spike. Per-drive `CounterDelta`s make a new drive contribute
    /// nothing until it has been seen twice, and a vanished drive simply stop
    /// contributing.
    private struct DriveCounters {
        var bytesRead = CounterDelta()
        var bytesWritten = CounterDelta()
        var reads = CounterDelta()
        var writes = CounterDelta()
    }

    private struct Drive {
        let service: io_registry_entry_t
        let entryID: UInt64
        var counters: DriveCounters
    }

    private var drives: [Drive] = []
    private var needsDriveRefresh = false

    private var volumes: [VolumeInfo] = []
    private var lastVolumeScan: ContinuousClock.Instant?

    /// Purgeable bytes per volume path. Kept separately from `volumes` because it is
    /// refreshed on a much slower cadence and outlives `stop()` — see `refreshPurgeable`.
    private var purgeable: [String: UInt64] = [:]
    private var lastPurgeableScan: ContinuousClock.Instant?
    private var purgeableCursor = 0
    private lazy var arbitration = DASessionCreate(kCFAllocatorDefault)

    /// Capacity moves slowly and enumerating volumes is not free (a resource-value
    /// fetch and a `statfs` per mount, and a stalled network mount can block for
    /// longer), so it runs on its own cadence while the I/O counters below are read
    /// on every sample.
    private let volumeScanInterval: TimeInterval = 15
    private let purgeableScanInterval: TimeInterval = 60

    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsRootFileSystemKey, .volumeUUIDStringKey,
        .volumeLocalizedFormatDescriptionKey,
    ]
    private static let volumeKeySet = Set(volumeKeys)

    /// Bridged once at startup; `CFDictionaryGetValue` needs the CFString identities and
    /// re-bridging these literals per lookup would reintroduce the per-sample allocation
    /// that `statistics(of:)` exists to avoid.
    private static let statisticsKey = kIOBlockStorageDriverStatisticsKey as CFString
    private static let bytesReadKey = kIOBlockStorageDriverStatisticsBytesReadKey as CFString
    private static let bytesWrittenKey = kIOBlockStorageDriverStatisticsBytesWrittenKey as CFString
    private static let readsKey = kIOBlockStorageDriverStatisticsReadsKey as CFString
    private static let writesKey = kIOBlockStorageDriverStatisticsWritesKey as CFString

    public init() {}

    public func start() {
        refreshDrives()
    }

    /// `purgeable` survives so a resume does not start from plain free space.
    public func stop() {
        releaseDrives()
        volumes = []
        lastVolumeScan = nil
        needsDriveRefresh = false
    }

    deinit { releaseDrives() }

    public func collect(context: SampleContext) -> MetricState<DiskSnapshot> {
        if drives.isEmpty || needsDriveRefresh { refreshDrives() }

        let scanDue = lastVolumeScan.map { Monotonic.seconds(since: $0) >= volumeScanInterval } ?? true
        if scanDue {
            scanVolumes()
            // A drive appearing or disappearing shows up as a mount change far more
            // often than not, so the two rescans share one cadence.
            refreshDrives()
        }

        guard !drives.isEmpty else {
            return .failure(.failed("no IOBlockStorageDriver services matched"))
        }

        var readBytes: UInt64 = 0, writeBytes: UInt64 = 0
        var readOps: UInt64 = 0, writeOps: UInt64 = 0
        var totalRead: UInt64 = 0, totalWrite: UInt64 = 0
        var readable = 0

        for index in drives.indices {
            guard let stats = statistics(of: drives[index].service) else {
                // Almost always a drive that was unplugged since the last rescan.
                needsDriveRefresh = true
                continue
            }
            readable += 1
            totalRead += stats.bytesRead
            totalWrite += stats.bytesWritten
            readBytes += drives[index].counters.bytesRead.delta(current: stats.bytesRead)
            writeBytes += drives[index].counters.bytesWritten.delta(current: stats.bytesWritten)
            readOps += drives[index].counters.reads.delta(current: stats.reads)
            writeOps += drives[index].counters.writes.delta(current: stats.writes)
        }

        guard readable > 0 else {
            return .failure(.failed("IOBlockStorageDriver Statistics unreadable"))
        }

        // The counters above have only been baselined, not differenced, so there is
        // no honest rate to report yet. Same on wake: the counters survive sleep but
        // averaging hours of idle time into a "current" rate would be a fiction.
        guard !context.isFirstSample, !context.didWakeFromSleep, context.elapsed > 0.001 else {
            return .failure(.pending)
        }

        return .value(DiskSnapshot(volumes: volumes,
                                   readBytesPerSecond: Double(readBytes) / context.elapsed,
                                   writeBytesPerSecond: Double(writeBytes) / context.elapsed,
                                   readOpsPerSecond: Double(readOps) / context.elapsed,
                                   writeOpsPerSecond: Double(writeOps) / context.elapsed,
                                   totalReadBytes: totalRead,
                                   totalWriteBytes: totalWrite))
    }
}

// MARK: - Volumes

extension DiskCollector {

    private func scanVolumes() {
        lastVolumeScan = Monotonic.now
        // The startup disk is reported as its *container*, reached through the sealed
        // system volume at "/". Every volume in an APFS volume group shares one storage
        // pool, so "/" already reports container-wide total and free space rather than
        // the 12 GB sealed snapshot's own footprint — one entry really is the whole
        // startup disk. `.skipHiddenVolumes` is what keeps it to one entry: it drops the
        // nobrowse volumes (Data, Preboot, VM, Update, xART), so /System/Volumes/Data
        // cannot appear next to "Macintosh HD" and show the same disk twice. Checked on
        // this machine: enumeration returns exactly one URL, "/". The Data volume shows
        // up only with an empty option set.
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.volumeKeys,
            options: [.skipHiddenVolumes]) else {
            volumes = []
            return
        }

        // Mounted disk images are installers and app payloads, not storage.
        let mounts = urls.compactMap { url -> (url: URL, device: (bsdName: String?, fileSystem: String?))? in
            let device = deviceInfo(for: url.path)
            if let bsdName = device.bsdName, isDiskImage(bsdName) { return nil }
            return (url, device)
        }
        refreshPurgeable(mounts.map(\.url))

        var found: [VolumeInfo] = []
        found.reserveCapacity(mounts.count)
        for (url, device) in mounts {
            // Throws for volumes that vanished between enumeration and this call, and
            // for network mounts the user cannot stat. Both mean "not a volume we can
            // report", never "report zeroes".
            guard let values = try? url.resourceValues(forKeys: Self.volumeKeySet),
                  let total = values.volumeTotalCapacity, total > 0,
                  let available = values.volumeAvailableCapacity else { continue }

            // These four fields always satisfy
            //     freeBytes <= availableBytes <= totalBytes
            //     availableBytes - freeBytes == purgeableBytes
            // because APFS gives two different honest answers for "free" and the pair
            // only makes sense together. `volumeAvailableCapacity` is byte-identical to
            // statfs `f_bavail` (the number `df` prints) and excludes purgeable caches;
            // `volumeAvailableCapacityForImportantUsage` (see `refreshPurgeable`) adds
            // back what the OS would evict on demand. Read against Finder's Get Info for
            // Macintosh HD at one instant: Capacity 494.38 GB, "Available: 181.03 GB
            // (38.99 GB purgeable)" — `totalBytes`, `availableBytes` and `purgeableBytes`
            // reproduce all three exactly, so `availableBytes` is the figure to show a
            // user and `freeBytes` the one to trust for "will this write succeed now".
            //
            // That makes `usedBytes` (totalBytes - freeBytes, defined in Snapshots.swift)
            // mean container space not immediately allocatable. No single definition can
            // satisfy both Apple UIs: Finder reports used 338.58 GB — the volume group's
            // own usage, system 12.57 + data 326.01 — which does not even sum with its own
            // available figure, while System Settings > Storage reports "313.21 GB of
            // 494.38 GB used", i.e. totalBytes - availableBytes. A summary that pairs
            // "used" with `availableBytes` has to derive used from `availableBytes` to
            // agree with System Settings; `usedBytes` is deliberately the stricter view.
            let free = UInt64(max(0, available))
            let slack = purgeable[url.path] ?? 0

            let removable = values.volumeIsRemovable ?? false
            let ejectable = values.volumeIsEjectable ?? false
            found.append(VolumeInfo(id: values.volumeUUIDString ?? url.path,
                                    name: values.volumeName ?? url.lastPathComponent,
                                    path: url.path,
                                    totalBytes: UInt64(total),
                                    freeBytes: free,
                                    availableBytes: free + slack,
                                    purgeableBytes: slack,
                                    isInternal: values.volumeIsInternal ?? !(removable || ejectable),
                                    isRemovable: removable,
                                    isRoot: values.volumeIsRootFileSystem ?? false,
                                    isEjectable: ejectable,
                                    fileSystem: values.volumeLocalizedFormatDescription ?? device.fileSystem,
                                    bsdName: device.bsdName))
        }
        volumes = found
    }

    /// Updates the purgeable figure for a single volume, round-robin.
    ///
    /// `volumeAvailableCapacityForImportantUsage` measures 13–38 ms per volume on an
    /// M3 Pro — two orders of magnitude more than every other key here — because APFS
    /// has to walk its purgeable accounting to answer. Two things follow: it cannot
    /// run on the sampling cadence, and it cannot run for every mount at once or the
    /// cost would scale with the number of attached drives. So one volume is refreshed
    /// per minute and the result is cached as *purgeable bytes* rather than as an
    /// available total — purgeable space is the slow-moving half of that sum (caches
    /// and snapshots), while free space moves every second, so `free + purgeable`
    /// tracks reality between refreshes and is exact at each one.
    ///
    /// A volume with no figure yet is measured on the next scan, startup disk first,
    /// so a restart never leaves the menu bar on plain free space.
    private func refreshPurgeable(_ urls: [URL]) {
        guard !urls.isEmpty else {
            purgeable.removeAll()
            return
        }
        // Unmounted volumes must not keep a stale figure alive for a path that gets
        // reused by the next thing mounted there.
        purgeable = purgeable.filter { entry in urls.contains { $0.path == entry.key } }

        let url: URL
        let unmeasured = urls.filter { purgeable[$0.path] == nil }
        if let fresh = unmeasured.first(where: { $0.path == "/" }) ?? unmeasured.first {
            url = fresh
        } else {
            let due = lastPurgeableScan.map { Monotonic.seconds(since: $0) >= purgeableScanInterval } ?? true
            guard due else { return }
            lastPurgeableScan = Monotonic.now
            url = urls[purgeableCursor % urls.count]
            purgeableCursor = (purgeableCursor + 1) % urls.count
        }
        // Both figures come from one call so the subtraction cannot straddle a change
        // in free space. 0 is what volumes that do not implement the key report
        // (non-APFS, network mounts, disk images): nothing purgeable to add back.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey]),
           let important = values.volumeAvailableCapacityForImportantUsage,
           let available = values.volumeAvailableCapacity.map(Int64.init) {
            purgeable[url.path] = important > available ? UInt64(important - available) : 0
        } else {
            purgeable[url.path] = 0
        }
    }

    private func isDiskImage(_ bsdName: String) -> Bool {
        guard let session = arbitration,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        return description[kDADiskDescriptionDeviceModelKey as String] as? String == "Disk Image"
    }

    /// BSD device name and filesystem type, which the URL resource keys do not expose.
    private func deviceInfo(for path: String) -> (bsdName: String?, fileSystem: String?) {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return (nil, nil) }

        let mountedFrom = withUnsafeBytes(of: &info.f_mntfromname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let type = withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        let bsdName = mountedFrom.hasPrefix("/dev/")
            ? String(mountedFrom.dropFirst(5))
            : nil
        return (bsdName, type.isEmpty ? nil : type)
    }
}

// MARK: - Block device statistics

extension DiskCollector {

    private struct DriveStatistics {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var reads: UInt64 = 0
        var writes: UInt64 = 0
    }

    /// Rebuilds the cached service list, carrying each surviving drive's counter
    /// baselines across so a rescan does not itself look like a burst of I/O.
    private func refreshDrives() {
        needsDriveRefresh = false

        var iterator: io_iterator_t = IO_OBJECT_NULL
        // IOServiceGetMatchingServices consumes the matching dictionary
        // (CF_RELEASES_ARGUMENT), so there is nothing to release on this line.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault,
                                                  IOServiceMatching(kIOBlockStorageDriverClass),
                                                  &iterator)
        guard result == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var carried: [UInt64: DriveCounters] = [:]
        carried.reserveCapacity(drives.count)
        for drive in drives { carried[drive.entryID] = drive.counters }

        var found: [Drive] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
                IOObjectRelease(service)
                continue
            }
            found.append(Drive(service: service,
                               entryID: entryID,
                               counters: carried[entryID] ?? DriveCounters()))
        }

        releaseDrives()
        drives = found
    }

    private func releaseDrives() {
        for drive in drives { IOObjectRelease(drive.service) }
        drives = []
    }

    /// Reads one driver's `Statistics` dictionary. Returns nil when the service has
    /// been detached, which is how an ejected drive surfaces here.
    ///
    /// The dictionary is read through the CF API rather than bridged to
    /// `[String: NSNumber]`. Bridging would allocate a fresh native dictionary plus a
    /// boxed number per key, per drive, on every single sample — eight drives at 20 Hz
    /// is tens of thousands of short-lived allocations a minute, which does not leak
    /// but does keep the malloc arena growing its free-list pages. `CFDictionaryGetValue`
    /// is a Get, not a Create: the value comes back at +0 and must not be released.
    private func statistics(of service: io_registry_entry_t) -> DriveStatistics? {
        guard let property = IORegistryEntryCreateCFProperty(service,
                                                             Self.statisticsKey,
                                                             kCFAllocatorDefault,
                                                             0)?.takeRetainedValue(),
              CFGetTypeID(property) == CFDictionaryGetTypeID() else { return nil }
        let stats = unsafeDowncast(property, to: CFDictionary.self)

        return DriveStatistics(bytesRead: counter(stats, Self.bytesReadKey),
                               bytesWritten: counter(stats, Self.bytesWrittenKey),
                               reads: counter(stats, Self.readsKey),
                               writes: counter(stats, Self.writesKey))
    }

    /// A missing or non-numeric key means the driver does not track that counter, not
    /// an error; it reads as zero and its delta stays zero.
    private func counter(_ stats: CFDictionary, _ key: CFString) -> UInt64 {
        guard let raw = CFDictionaryGetValue(stats, Unmanaged.passUnretained(key).toOpaque())
        else { return 0 }
        let value = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return 0 }
        var out: Int64 = 0
        guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt64Type, &out),
              out >= 0 else { return 0 }
        return UInt64(out)
    }
}
