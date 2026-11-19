import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Throughput, per-interface counters, Wi-Fi link quality, addresses.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
public final class NetworkCollector: MetricSource {
    public typealias Output = NetworkSnapshot

    public let identifier: CollectorID = .network
    public let preferredInterval: TimeInterval = 1.0

    /// CoreWLAN is an XPC round trip to `wifid` per property: a full link-quality read
    /// measures ~7 ms idle on an M3 Pro and up to 20 ms when the machine is busy, which
    /// dwarfs the ~0.5 ms the rest of this collector costs and is the one call here whose
    /// latency this process does not control. RSSI and channel move far slower than
    /// throughput does, so they get their own cadence and are cached in between; the
    /// counters keep updating every sample regardless.
    private static let wifiRefreshInterval: TimeInterval = 10

    /// `SCNetworkInterfaceCopyAll` costs ~3 ms because it walks IOKit. Its answer only
    /// changes when hardware is plugged in or removed, so it is rebuilt on demand
    /// (throttled) rather than every sample.
    private static let hardwarePortRescanInterval: TimeInterval = 5

    /// A macOS hardware port, as Network Settings would list it.
    private struct HardwarePort {
        var displayName: String
        var type: ConnectionType
        /// Bridges, bonds and VLANs re-report the bytes of the ports they are built on.
        var aggregatesMembers: Bool
    }

    /// One interface exactly as the kernel currently reports it.
    private struct Link {
        var name: String
        var flags: Int32
        var inBytes: UInt64
        var outBytes: UInt64
        var ipv4: String?
        var ipv6: String?
        /// True once a non-link-local address is configured, i.e. the interface can
        /// actually reach something rather than merely existing.
        var hasRoutableAddress = false

        var isUp: Bool { flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 }
    }

    /// Rate and absolute-delta need separate baselines: each `CounterDelta` call
    /// consumes the stored previous value, so one instance cannot answer both
    /// questions in the same cycle.
    private struct Baselines {
        var inRate = CounterDelta()
        var outRate = CounterDelta()
        var inBytes = CounterDelta()
        var outBytes = CounterDelta()

        mutating func reset() {
            inRate.reset(); outRate.reset(); inBytes.reset(); outBytes.reset()
        }
    }

    /// Carries the errno text out of the counter read and into the `.failure` the
    /// collector has to return, so the reason reaches the UI instead of a bare nil.
    private struct ReadFailure: Error {
        var message: String
    }

    private var baselines: [String: Baselines] = [:]
    private var hardwarePorts: [String: HardwarePort] = [:]
    /// Names a completed scan proved are not hardware ports, so a tunnel coming up
    /// never triggers a repeat scan.
    private var nonHardwarePorts: Set<String> = []
    private var lastPortScan: ContinuousClock.Instant?

    /// Formatted MAC plus the raw bytes it was built from, so the string is only
    /// rebuilt when the link address actually changes (Wi-Fi rotates its private
    /// address per network) instead of once per interface per sample.
    private var macCache: [String: (packed: UInt64, text: String)] = [:]

    private var store: SCDynamicStore?
    private var primaryIPv4Key: CFString?
    private var primaryIPv6Key: CFString?

    /// Reused across samples: the routing-table dump is a few KB and reallocating it
    /// every second for the life of the app would be pure churn.
    private var linkBuffer: UnsafeMutableRawPointer?
    private var linkBufferSize = 0

    private var addressText = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

    private var sessionIn: UInt64 = 0
    private var sessionOut: UInt64 = 0

    /// Set by `start()`. The engine is not required to flag the first sample after a
    /// restart, and differencing across the stopped interval would invent a rate, so the
    /// collector decides for itself when it still owes a baseline.
    private var needsBaseline = true

    private var wifi: WiFiInfo?
    private var lastWiFiRead: ContinuousClock.Instant?
    private var wifiInterfaceName: String?

    /// Owns the one outbound request this app makes. Idle until the user turns
    /// `general.fetchesPublicIP` on; see `PublicIPFetcher` for the endpoint and the
    /// throttle, both of which are its business rather than this collector's.
    private let publicIPLookup = PublicIPFetcher()

    public init() {}

    /// Pushed in from `SamplingCore` when the setting changes, because a collector has
    /// no way to read the settings store and no business acquiring one.
    func setPublicIPLookupEnabled(_ enabled: Bool) {
        publicIPLookup.setEnabled(enabled)
    }

    public func start() {
        autoreleasepool { acquire() }
    }

    /// Same autorelease discipline as `collect`: a disable/enable cycle runs this again,
    /// and `SCNetworkInterfaceCopyAll` plus the CoreWLAN warm-up are the two most
    /// allocation-heavy calls in the collector.
    private func acquire() {
        store = SCDynamicStoreCreate(nil, "com.airstat.network" as CFString, nil, nil)
        primaryIPv4Key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        primaryIPv6Key = SCDynamicStoreKeyCreateNetworkGlobalEntity(
            nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)

        if linkBuffer == nil {
            linkBufferSize = 16 * 1024
            linkBuffer = malloc(linkBufferSize)
        }

        wifiInterfaceName = CWWiFiClient.shared().interface()?.interfaceName
        rescanHardwarePorts()

        // Sampling may have been stopped for hours. Differencing across that gap would
        // invent a rate and pollute the session totals, so every counter re-baselines.
        for name in baselines.keys { baselines[name]?.reset() }
        needsBaseline = true

        // The first CoreWLAN call of the process pays for the XPC connection to wifid on
        // top of the query — ~20 ms against ~7 ms warm. Spending it here keeps it off the
        // sampling path entirely.
        wifi = nil
        lastWiFiRead = nil
        refreshWiFi(force: true, linkIsUp: true)
    }

    public func stop() {
        store = nil
        primaryIPv4Key = nil
        primaryIPv6Key = nil
        free(linkBuffer)
        linkBuffer = nil
        linkBufferSize = 0
        hardwarePorts.removeAll()
        nonHardwarePorts.removeAll()
        lastPortScan = nil
        wifi = nil
        wifiInterfaceName = nil
    }

    /// Every sample runs inside its own autorelease pool.
    ///
    /// CoreWLAN and SystemConfiguration return autoreleased Objective-C objects —
    /// `CWInterface.security()` alone accrues 20 KB per call, the other properties
    /// ~0.2 KB each. Nothing drains a pool on `SamplingCore`'s serial queue, so those
    /// objects would sit there until the thread happened to go idle. Measured without
    /// this pool: +22.5 KB per Wi-Fi refresh, roughly 250 MB a day at probe cadence.
    public func collect(context: SampleContext) -> MetricState<NetworkSnapshot> {
        autoreleasepool { sample(context: context) }
    }

    private func sample(context: SampleContext) -> MetricState<NetworkSnapshot> {
        var links: [Link]
        switch readLinks() {
        case .success(let value): links = value
        case .failure(let error): return .failure(.failed(error.message))
        }
        guard !links.isEmpty else {
            return .failure(.failed("the kernel reported no network interfaces"))
        }

        var indexByName: [String: Int] = [:]
        indexByName.reserveCapacity(links.count)
        for (index, link) in links.enumerated() { indexByName[link.name] = index }
        applyAddresses(to: &links, indexByName: indexByName)
        classifyNewNames(links)

        // A wake re-baselines rather than differencing: the counters survive sleep but
        // `elapsed` spans it, which would smear hours of traffic into one reading.
        let rebaseline = context.isFirstSample || context.didWakeFromSleep || needsBaseline
        needsBaseline = false

        var stats: [NetworkInterfaceStats] = []
        stats.reserveCapacity(links.count)
        var downloadRate = 0.0
        var uploadRate = 0.0
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        var countedInterfaces = 0
        var ratedInterfaces = 0
        var vpnActive = false

        for link in links {
            var baseline = baselines[link.name] ?? Baselines()
            if rebaseline { baseline.reset() }
            let inRate = baseline.inRate.rate(current: link.inBytes, elapsed: context.elapsed)
            let outRate = baseline.outRate.rate(current: link.outBytes, elapsed: context.elapsed)
            let inDelta = baseline.inBytes.delta(current: link.inBytes)
            let outDelta = baseline.outBytes.delta(current: link.outBytes)
            baselines[link.name] = baseline

            if countsTowardTotal(link.name) {
                countedInterfaces += 1
                totalIn += link.inBytes
                totalOut += link.outBytes
                deltaIn += inDelta
                deltaOut += outDelta
                if let inRate { downloadRate += inRate; ratedInterfaces += 1 }
                if let outRate { uploadRate += outRate; ratedInterfaces += 1 }
            }

            let port = classify(link)
            if port.type == .vpn, link.isUp, link.hasRoutableAddress { vpnActive = true }

            stats.append(NetworkInterfaceStats(
                name: link.name,
                displayName: port.displayName,
                type: port.type,
                isActive: link.isUp && (link.hasRoutableAddress || inDelta > 0 || outDelta > 0),
                // An interface seen for the first time has no baseline yet. 0 here means
                // "not measured", the same state the snapshot as a whole reports as
                // `.pending` on its first cycle; it is never a failed reading.
                uploadBytesPerSecond: outRate ?? 0,
                downloadBytesPerSecond: inRate ?? 0,
                totalUploadBytes: link.outBytes,
                totalDownloadBytes: link.inBytes,
                ipv4: link.ipv4,
                ipv6: link.ipv6,
                macAddress: macCache[link.name]?.text))
        }

        // Before any early return: pruning is bookkeeping about which interfaces still
        // exist, and the sample where one disappears is exactly the sample most likely to
        // fail. Leaving it on the success path would let entries survive precisely when
        // they should be dropped.
        pruneVanishedInterfaces(links)

        // With no countable interface at all there is genuinely nothing flowing, and 0 is
        // the measurement. Otherwise a missing rate means no usable baseline, not zero.
        guard countedInterfaces == 0 || ratedInterfaces > 0 else {
            guard !rebaseline else { return .failure(.pending) }
            return .failure(.failed(String(
                format: "no usable sampling interval (elapsed %.4fs)", context.elapsed)))
        }

        sessionIn += deltaIn
        sessionOut += deltaOut

        // The radio can be powered on while the interface carries no link at all (a Mac
        // on Ethernet). Reading CoreWLAN then costs 7 ms to learn nothing.
        let wifiLinkIsUp = links.first { $0.name == wifiInterfaceName }?.isUp ?? false
        // `lastWiFiRead` is a ContinuousClock instant, so a sleep counts against the
        // interval and the link quality is re-read on the first sample after a wake.
        refreshWiFi(force: false, linkIsUp: wifiLinkIsUp)

        // Returns immediately whether or not it starts anything: the round trip belongs
        // to URLSession's queues, so nothing behind us on the sampling queue waits for
        // a server on the far side of the internet.
        publicIPLookup.refreshIfDue()

        let primaryName = primaryInterfaceName()
        let primary = primaryName.flatMap { name in stats.first { $0.name == name } }
        sort(&stats, primaryName: primaryName)

        return .value(NetworkSnapshot(
            uploadBytesPerSecond: uploadRate,
            downloadBytesPerSecond: downloadRate,
            totalUploadBytes: totalOut,
            totalDownloadBytes: totalIn,
            sessionUploadBytes: sessionOut,
            sessionDownloadBytes: sessionIn,
            interfaces: stats,
            primaryInterfaceName: primaryName,
            connectionType: primary?.type ?? .none,
            wifi: wifi,
            localIPv4: primary?.ipv4,
            // Never fetched inline: `collect()` runs on the shared sampling queue, so an
            // HTTP round trip would block every other collector behind it, and silently
            // contacting a third party is not something a sampling tick should do. This
            // is the cached answer of the opt-in fetcher above, read under its lock.
            publicIP: publicIPLookup.currentState(),
            isVPNActive: vpnActive))
    }

    // MARK: Kernel counters

    /// Reads every interface's counters in a single `net.link.generic.ifalldata` sysctl.
    ///
    /// This is the same MIB `netstat -ib` reads, and on this OS it is the only source
    /// that is both 64-bit and exact. The two obvious alternatives each lose data:
    /// `getifaddrs` hands back a `struct if_data` whose `ifi_ibytes`/`ifi_obytes` are
    /// `u_int32_t` and therefore wrap every 4 GiB, which a Wi-Fi interface can pass in a
    /// day; `NET_RT_IFLIST2` is 64-bit but its exported counters are floored to a 1 KiB
    /// boundary (measured on macOS 26.5: it reported en0 at 1920479232 while this MIB and
    /// netstat both said 1920479553). `ifmibdata.ifmd_data` is an `if_data64` carrying
    /// the unrounded value, alongside the name and flags, in fixed-size records.
    private func readLinks() -> Result<[Link], ReadFailure> {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]

        for attempt in 0..<2 {
            guard let buffer = linkBuffer else {
                return .failure(ReadFailure(message: "collector was not started"))
            }
            var size = linkBufferSize
            if sysctl(&mib, 6, buffer, &size, nil, 0) == 0 {
                return parseLinks(buffer, size)
            }
            let code = errno
            guard code == ENOMEM, attempt == 0 else {
                return .failure(ReadFailure(
                    message: "sysctl(net.link.generic.ifalldata) failed: "
                             + String(cString: strerror(code))))
            }
            var needed = 0
            guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0 else {
                return .failure(ReadFailure(
                    message: "sysctl(net.link.generic.ifalldata) sizing failed: "
                             + String(cString: strerror(errno))))
            }
            // Headroom: an interface can appear between the sizing call and the fetch.
            let target = needed + needed / 4 + 1024
            guard let grown = realloc(buffer, target) else {
                return .failure(ReadFailure(
                    message: "could not allocate \(target) bytes for the interface list"))
            }
            linkBuffer = grown
            linkBufferSize = target
        }
        return .failure(ReadFailure(
            message: "sysctl(net.link.generic.ifalldata) kept reporting ENOMEM"))
    }

    private func parseLinks(_ buffer: UnsafeMutableRawPointer,
                            _ size: Int) -> Result<[Link], ReadFailure> {
        // `ifmibdata` is pack(4), so the kernel's record stride is its plain size. If the
        // reply is not a whole number of records the layout assumption is wrong and the
        // counters would be nonsense; refusing to parse beats reporting garbage.
        let recordSize = MemoryLayout<ifmibdata>.size
        guard recordSize > 0, size % recordSize == 0 else {
            return .failure(ReadFailure(
                message: "ifalldata returned \(size) bytes, not a multiple of \(recordSize)"))
        }

        var links: [Link] = []
        links.reserveCapacity(size / recordSize)
        var offset = 0
        while offset + recordSize <= size {
            defer { offset += recordSize }
            let record = buffer.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
            let name = withUnsafeBytes(of: record.ifmd_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            // An index can be vacant after an interface is detached.
            guard !name.isEmpty else { continue }
            links.append(Link(name: name,
                              flags: Int32(bitPattern: record.ifmd_flags),
                              inBytes: record.ifmd_data.ifi_ibytes,
                              outBytes: record.ifmd_data.ifi_obytes))
        }
        return .success(links)
    }

    /// Field offsets inside `sockaddr_dl`. The BSD name and the link address share the
    /// variable-length `sdl_data`, which Swift cannot address as a fixed-size tuple.
    private static let sdlLengthOffset = 0
    private static let sdlNameLengthOffset = 5
    private static let sdlAddressLengthOffset = 6
    private static let sdlDataOffset = 8

    private func cacheMAC(name: String, address: UnsafeRawPointer) {
        let length = Int(address.load(fromByteOffset: Self.sdlLengthOffset, as: UInt8.self))
        let nameLength = Int(address.load(fromByteOffset: Self.sdlNameLengthOffset,
                                          as: UInt8.self))
        let addressLength = Int(address.load(fromByteOffset: Self.sdlAddressLengthOffset,
                                             as: UInt8.self))
        let start = Self.sdlDataOffset + nameLength
        guard addressLength == 6, start + addressLength <= length else { return }

        var packed: UInt64 = 0
        for index in 0..<6 {
            let byte = address.load(fromByteOffset: start + index, as: UInt8.self)
            packed = packed << 8 | UInt64(byte)
        }
        guard macCache[name]?.packed != packed else { return }
        var text = ""
        text.reserveCapacity(17)
        for index in 0..<6 {
            if index > 0 { text += ":" }
            text += String(format: "%02x",
                           address.load(fromByteOffset: start + index, as: UInt8.self))
        }
        macCache[name] = (packed, text)
    }

    /// Addresses and link-layer addresses, which the counter MIB does not carry.
    private func applyAddresses(to links: inout [Link], indexByName: [String: Int]) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }
        defer { freeifaddrs(head) }

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard let index = indexByName[name] else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                cacheMAC(name: name, address: UnsafeRawPointer(address))
            case AF_INET:
                var raw = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in.self).sin_addr
                guard raw.s_addr != 0 else { continue }
                if links[index].ipv4 == nil {
                    links[index].ipv4 = withUnsafeBytes(of: &raw) {
                        presentation(AF_INET, $0.baseAddress)
                    }
                }
                // 169.254/16 is a self-assigned address: the interface is up but the
                // network never answered, so it is not evidence of connectivity.
                if UInt32(bigEndian: raw.s_addr) >> 16 != 0xA9FE {
                    links[index].hasRoutableAddress = true
                }
            case AF_INET6:
                var raw = UnsafeRawPointer(address).loadUnaligned(as: sockaddr_in6.self).sin6_addr
                let bytes = raw.__u6_addr.__u6_addr8
                let isLinkLocal = bytes.0 == 0xFE && bytes.1 & 0xC0 == 0x80
                if !isLinkLocal { links[index].hasRoutableAddress = true }
                // A routable address always wins over the fe80:: one every interface has.
                guard !isLinkLocal || links[index].ipv6 == nil else { continue }
                links[index].ipv6 = withUnsafeBytes(of: &raw) {
                    presentation(AF_INET6, $0.baseAddress)
                }
            default:
                continue
            }
        }
    }

    private func presentation(_ family: Int32, _ address: UnsafeRawPointer?) -> String? {
        guard let address else { return nil }
        return addressText.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress,
                  inet_ntop(family, address, base, socklen_t(buffer.count)) != nil
            else { return nil }
            return String(cString: base)
        }
    }

    // MARK: Interface classification

    private static let scTypes: [String: ConnectionType] = [
        kSCNetworkInterfaceTypeIEEE80211 as String: .wifi,
        kSCNetworkInterfaceTypeEthernet as String: .ethernet,
        kSCNetworkInterfaceTypeFireWire as String: .ethernet,
        kSCNetworkInterfaceTypeBond as String: .ethernet,
        kSCNetworkInterfaceTypeVLAN as String: .ethernet,
        kSCNetworkInterfaceTypeWWAN as String: .cellular,
        kSCNetworkInterfaceTypeModem as String: .cellular,
        kSCNetworkInterfaceTypePPP as String: .vpn,
        kSCNetworkInterfaceTypeIPSec as String: .vpn,
        kSCNetworkInterfaceTypeL2TP as String: .vpn,
        // SystemConfiguration exports no constant for the bridge type even though
        // `SCNetworkInterfaceGetInterfaceType` returns it for bridge0.
        "Bridge": .ethernet,
    ]

    private static let aggregatingSCTypes: Set<String> = [
        kSCNetworkInterfaceTypeBond as String,
        kSCNetworkInterfaceTypeVLAN as String,
        "Bridge",
    ]

    /// Prefixes macOS reserves for pseudo-interfaces, none of which can ever be a
    /// hardware port. Recognising them avoids a 3 ms rescan every time a tunnel appears.
    private static let virtualPrefixes = [
        "lo", "utun", "ipsec", "ppp", "tun", "tap", "awdl", "llw", "anpi", "ap",
        "gif", "stf", "vmnet", "XHC", "pktap",
    ]

    private func rescanHardwarePorts() {
        lastPortScan = Monotonic.now
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        hardwarePorts.removeAll(keepingCapacity: true)
        nonHardwarePorts.removeAll(keepingCapacity: true)
        for interface in all {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let scType = SCNetworkInterfaceGetInterfaceType(interface) as String? ?? ""
            hardwarePorts[bsdName] = HardwarePort(
                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                    ?? bsdName,
                type: Self.scTypes[scType] ?? .other,
                aggregatesMembers: Self.aggregatingSCTypes.contains(scType))
        }
    }

    /// Rescans hardware ports at most once per interval, and only when a name turns up
    /// that could plausibly be a newly attached port (a dock, a USB adapter).
    private func classifyNewNames(_ links: [Link]) {
        var needsRescan = false
        for link in links where hardwarePorts[link.name] == nil
            && !nonHardwarePorts.contains(link.name) {
            if Self.virtualPrefixes.contains(where: { link.name.hasPrefix($0) }) {
                nonHardwarePorts.insert(link.name)
            } else {
                needsRescan = true
            }
        }
        guard needsRescan else { return }
        if let last = lastPortScan,
           Monotonic.seconds(since: last) < Self.hardwarePortRescanInterval { return }
        rescanHardwarePorts()
        // Anything a fresh scan still does not know about is not a hardware port.
        for link in links where hardwarePorts[link.name] == nil {
            nonHardwarePorts.insert(link.name)
        }
    }

    /// Which interfaces are summed into the machine-wide throughput.
    ///
    /// Only real, non-aggregating hardware ports count, for two reasons. A VPN tunnel
    /// (utun/ppp/ipsec) does not move bytes of its own: its payload is encapsulated and
    /// then sent out over the physical carrier, which counts those same bytes again, so
    /// summing both doubles every byte a VPN user transfers. A bridge, bond or VLAN
    /// re-reports the counters of the member ports it sits on, for the same reason.
    /// Everything else excluded here — loopback, awdl (AirDrop), llw, anpi, ap — is
    /// either local-only or peer-to-peer radio traffic rather than network throughput,
    /// and is still reported per-interface for anyone who wants to see it.
    private func countsTowardTotal(_ name: String) -> Bool {
        guard let port = hardwarePorts[name] else {
            // Degraded path: if SCNetworkInterfaceCopyAll gave us nothing at all, fall
            // back to the BSD convention that macOS reserves en*/eth* for real ports.
            guard hardwarePorts.isEmpty else { return false }
            return name.hasPrefix("en") || name.hasPrefix("eth")
        }
        return !port.aggregatesMembers
    }

    private func classify(_ link: Link) -> (type: ConnectionType, displayName: String) {
        if link.flags & IFF_LOOPBACK != 0 { return (.loopback, "Loopback") }
        if let port = hardwarePorts[link.name] { return (port.type, port.displayName) }
        if link.name == wifiInterfaceName { return (.wifi, "Wi-Fi") }

        let name = link.name
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("tun") || name.hasPrefix("tap") {
            return (.vpn, "Tunnel (\(name))")
        }
        if name.hasPrefix("awdl") { return (.other, "AirDrop") }
        if name.hasPrefix("llw") { return (.other, "Low Latency WLAN") }
        if name.hasPrefix("anpi") { return (.other, "Apple Network Processor") }
        if name.hasPrefix("ap") { return (.other, "Personal Hotspot") }
        if name.hasPrefix("bridge") { return (.ethernet, "Bridge (\(name))") }
        if name.hasPrefix("gif") || name.hasPrefix("stf") { return (.other, "Transition Tunnel") }
        if name.hasPrefix("en") || name.hasPrefix("eth") { return (.ethernet, name) }
        return (.other, name)
    }

    /// Interfaces come and go — Wi-Fi toggled, a dock unplugged, a VPN torn down. Their
    /// baselines have to go with them or the dictionaries grow for the life of the app,
    /// and a reattached interface must start from a fresh baseline rather than being
    /// differenced against a counter from an hour ago.
    private func pruneVanishedInterfaces(_ links: [Link]) {
        guard baselines.count > links.count || macCache.count > links.count else { return }
        var live = Set<String>()
        live.reserveCapacity(links.count)
        for link in links { live.insert(link.name) }
        baselines = baselines.filter { live.contains($0.key) }
        macCache = macCache.filter { live.contains($0.key) }
        nonHardwarePorts.formIntersection(live)
    }

    private func sort(_ stats: inout [NetworkInterfaceStats], primaryName: String?) {
        stats.sort { a, b in
            if (a.name == primaryName) != (b.name == primaryName) { return a.name == primaryName }
            if a.isActive != b.isActive { return a.isActive }
            let aCounts = countsTowardTotal(a.name)
            let bCounts = countsTowardTotal(b.name)
            if aCounts != bCounts { return aCounts }
            return a.name < b.name
        }
    }

    // MARK: Primary interface

    /// The interface backing the default route, straight from configd's own state.
    /// IPv6 is consulted as well so an IPv6-only network still reports a primary.
    private func primaryInterfaceName() -> String? {
        guard let store else { return nil }
        for key in [primaryIPv4Key, primaryIPv6Key] {
            guard let key,
                  let entity = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  let name = entity[kSCDynamicStorePropNetPrimaryInterface as String] as? String
            else { continue }
            return name
        }
        return nil
    }

    // MARK: Wi-Fi

    private func refreshWiFi(force: Bool, linkIsUp: Bool) {
        guard linkIsUp else {
            // Left un-timestamped on purpose: the read should happen on the first sample
            // after the link comes back, not up to an interval later.
            wifi = nil
            return
        }
        if !force, let last = lastWiFiRead,
           Monotonic.seconds(since: last) < Self.wifiRefreshInterval { return }
        lastWiFiRead = Monotonic.now
        wifi = readWiFi()
    }

    /// Every CWInterface getter is a synchronous round trip to the Wi-Fi daemon, so this
    /// asks only for what something shows. Security, noise and BSSID were read here once
    /// and displayed nowhere, and security alone cost 2.7 ms of a 9 ms read.
    private func readWiFi() -> WiFiInfo? {
        // `wlanChannel()` is nil unless the radio is associated with a network, which
        // also covers a radio that is powered off. Without an association
        // rssiValue()/transmitRate() return 0, and reporting that would be inventing a
        // -0 dBm signal rather than measuring one.
        guard let interface = CWWiFiClient.shared().interface(),
              let channel = interface.wlanChannel() else { return nil }

        let rssi = interface.rssiValue()
        let rate = interface.transmitRate()
        return WiFiInfo(
            // ssid comes back nil unless the app holds Location Services authorisation,
            // which a menu bar sampler has no business prompting for. Everything else
            // on the link is readable without it.
            ssid: interface.ssid().flatMap { $0.isEmpty ? nil : $0 },
            rssi: rssi == 0 ? nil : rssi,
            channel: channel.channelNumber,
            band: Self.bandLabel(channel.channelBand),
            transmitRateMbps: rate > 0 ? rate : nil)
    }

    private static func bandLabel(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        case .bandUnknown: return nil
        @unknown default: return nil
        }
    }
}
