import Foundation
import Network
import SystemConfiguration
import Darwin
import SwiftUI

// MARK: - Network Speed Test

/// Result of a single throughput test run.
struct NetSpeedResult: Identifiable, Sendable {
    let id = UUID()
    let downMbps: Double
    let upMbps: Double
    let timestamp: Date
}

/// Phase of the current speed test, used to drive UI labels.
enum SpeedTestPhase: Sendable, Equatable {
    case idle
    case download
    case upload
    case done
    case failed(String)
}

/// Drives a multi-gigabit throughput test against Cloudflare's free speed
/// endpoints using several concurrent `URLSession` transfers. Fully async and
/// cancelable; publishes live Mbps and a short history of results.
///
/// Works under the App Store sandbox: only outbound `URLSession` is used.
@MainActor
final class SpeedTester: ObservableObject {
    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var liveMbps: Double = 0       // current direction throughput while running
    @Published private(set) var lastResult: NetSpeedResult?
    @Published private(set) var history: [NetSpeedResult] = []

    /// Number of concurrent transfers used to saturate fast links.
    private let parallelism = 6
    /// Duration of each measured phase (seconds).
    private let phaseDuration: TimeInterval = 9
    /// Short warm-up window discarded from the measurement (seconds).
    private let warmup: TimeInterval = 1.5
    /// Bytes requested per download chunk (100 MB) — large enough to keep a
    /// fast link busy without finishing too quickly.
    private let downloadChunkBytes = 100_000_000
    /// Bytes posted per upload chunk (25 MB in-memory body).
    private let uploadChunkBytes = 25_000_000
    private let maxHistory = 10

    private var runTask: Task<Void, Never>?

    var isRunning: Bool {
        if case .idle = phase { return false }
        if case .done = phase { return false }
        if case .failed = phase { return false }
        return true
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 12
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func start() {
        guard runTask == nil else { return }
        liveMbps = 0
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if isRunning { phase = .idle }
        liveMbps = 0
    }

    private func run() async {
        do {
            phase = .download
            liveMbps = 0
            let down = try await measure(direction: .download)
            try Task.checkCancellation()

            phase = .upload
            liveMbps = 0
            let up = try await measure(direction: .upload)
            try Task.checkCancellation()

            let result = NetSpeedResult(downMbps: down, upMbps: up, timestamp: Date())
            lastResult = result
            history.append(result)
            if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
            phase = .done
            liveMbps = 0
        } catch is CancellationError {
            phase = .idle
            liveMbps = 0
        } catch {
            phase = .failed(Self.message(for: error))
            liveMbps = 0
        }
    }

    private enum Direction { case download, upload }

    /// Runs `parallelism` concurrent transfers for `phaseDuration` seconds and
    /// returns the measured throughput in Mbps (warm-up window excluded).
    private func measure(direction: Direction) async throws -> Double {
        let counter = ByteCounter()
        let start = Date()
        let warmupEnd = start.addingTimeInterval(warmup)
        let deadline = start.addingTimeInterval(phaseDuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Concurrent transfer workers.
            for _ in 0..<parallelism {
                group.addTask { [weak self] in
                    guard let self else { return }
                    while Date() < deadline {
                        try Task.checkCancellation()
                        switch direction {
                        case .download:
                            try await self.streamDownload(into: counter, until: deadline, warmupEnd: warmupEnd)
                        case .upload:
                            try await self.streamUpload(into: counter, until: deadline, warmupEnd: warmupEnd)
                        }
                    }
                }
            }

            // Live progress reporter.
            group.addTask { [weak self] in
                guard let self else { return }
                while Date() < deadline {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 250_000_000)
                    let elapsed = Date().timeIntervalSince(warmupEnd)
                    if elapsed > 0 {
                        let mbps = await counter.mbps(over: elapsed)
                        await MainActor.run { self.liveMbps = mbps }
                    }
                }
            }

            try await group.waitForAll()
        }

        let measuredSeconds = deadline.timeIntervalSince(warmupEnd)
        guard measuredSeconds > 0 else { return 0 }
        let total = await counter.total
        guard total > 0 else {
            throw URLError(.cannotConnectToHost)
        }
        return Double(total) * 8 / measuredSeconds / 1_000_000
    }

    private func streamDownload(into counter: ByteCounter, until deadline: Date, warmupEnd: Date) async throws {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(downloadChunkBytes)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        var batch = 0
        for try await _ in bytes {
            batch += 1
            // Accrue in batches to limit actor hops on multi-gig links.
            if batch >= 16384 {
                if Date() >= warmupEnd { await counter.add(batch) }
                batch = 0
                if Date() >= deadline { break }
                try Task.checkCancellation()
            }
        }
        if Date() >= warmupEnd { await counter.add(batch) }
    }

    private func streamUpload(into counter: ByteCounter, until deadline: Date, warmupEnd: Date) async throws {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let body = Data(count: uploadChunkBytes)
        let (_, response) = try await session.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        // The whole body is uploaded by the time this returns.
        if Date() >= warmupEnd { await counter.add(uploadChunkBytes) }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost:
                return "Network unavailable"
            case .timedOut:
                return "Timed out"
            default:
                return "Test failed"
            }
        }
        return "Test failed"
    }
}

/// Thread-safe byte accumulator for the concurrent transfer workers.
private actor ByteCounter {
    private(set) var total: Int = 0
    func add(_ n: Int) { total += n }
    func mbps(over seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(total) * 8 / seconds / 1_000_000
    }
}

final class NetworkMonitor: @unchecked Sendable {
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.blainemiller.Blip.network", qos: .utility)
    private var _isConnected = false
    // Per-interface last-seen 32-bit byte counters (kernel exposes only u_int32_t
    // counters that wrap every 4 GiB), plus 64-bit running totals we accumulate from
    // wrap-aware deltas. This is robust across macOS versions, unlike parsing the
    // routing-socket if_data64 struct whose layout shifts between releases.
    private var perIfLastIn: [String: UInt64] = [:]
    private var perIfLastOut: [String: UInt64] = [:]
    private var accumulatedIn: UInt64 = 0
    private var accumulatedOut: UInt64 = 0
    private var previousTimestamp: Date?
    private var lastPing: Double?
    private var lastRouterPing: Double?
    private var pingCount = 0
    private var cachedGateway: String?
    private var gatewayPollCount = 0
    var pingTarget: String = "1.1.1.1"

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?._isConnected = path.status == .satisfied
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func read() -> NetworkStats {
        var stats = NetworkStats()
        stats.isConnected = _isConnected

        // Get interface addresses
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return stats }
        defer { freeifaddrs(ifaddr) }

        var activeMacInterfaces = Set<String>()
        // Collect per-interface data for multi-interface display
        var ifIPv4: [String: String] = [:]
        var ifIPv6: [String: String] = [:]
        var ifMAC: [String: String] = [:]
        var ifHasIP: Set<String> = []
        // Current 32-bit byte counters per physical interface (en*), used to derive
        // wrap-aware deltas below. Loopback and VPN tunnels are intentionally excluded.
        var curIn: [String: UInt64] = [:]
        var curOut: [String: UInt64] = [:]

        var current = firstAddr
        while true {
            let interface = current.pointee
            let nameLen = Int(strlen(interface.ifa_name))
            let name = String(decoding: UnsafeBufferPointer(start: interface.ifa_name, count: nameLen).map { UInt8(bitPattern: $0) }, as: UTF8.self)

            // Get IP addresses
            if let addr = interface.ifa_addr {
                let family = addr.pointee.sa_family

                if family == UInt8(AF_INET) { // IPv4
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(decoding: hostname.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        .trimmingCharacters(in: .controlCharacters)

                    if name.hasPrefix("en") {
                        ifIPv4[name] = ip
                        ifHasIP.insert(name)
                        if stats.lanAddress == "—" {
                            stats.lanAddress = ip
                            stats.ipv4Address = ip
                            stats.interfaceName = name
                        }
                        activeMacInterfaces.insert(name)
                    } else if name.hasPrefix("utun") || name.hasPrefix("tailscale") || name.hasPrefix("wg") {
                        stats.vpnAddress = ip
                        stats.vpnInterface = name
                        stats.isVPNActive = true
                    }
                } else if family == UInt8(AF_INET6) { // IPv6
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(decoding: hostname.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        .trimmingCharacters(in: .controlCharacters)
                    if name.hasPrefix("en") && !ip.hasPrefix("fe80") {
                        if ifIPv6[name] == nil {
                            ifIPv6[name] = ip
                        }
                        if stats.ipv6Address == "—" {
                            stats.ipv6Address = ip
                        }
                    }
                }

                // MAC address from AF_LINK for active interfaces
                if family == UInt8(AF_LINK) && name.hasPrefix("en") {
                    if let sockaddrData = interface.ifa_addr {
                        let sdl = sockaddrData.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                        if sdl.sdl_alen == 6 {
                            var macBytes = [UInt8](repeating: 0, count: 6)
                            withUnsafePointer(to: sdl) { ptr in
                                let base = UnsafeRawPointer(ptr).advanced(by: 8 + Int(sdl.sdl_nlen))
                                macBytes = [UInt8](UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: 6))
                            }
                            let macStr = macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
                            if macStr != "00:00:00:00:00:00" {
                                ifMAC[name] = macStr
                                if stats.macAddress == "—" {
                                    stats.macAddress = macStr
                                }
                            }
                        }
                    }

                    // Capture this interface's 32-bit byte counters for delta tracking.
                    if let networkData = interface.ifa_data {
                        let ifData = networkData.assumingMemoryBound(to: if_data.self).pointee
                        curIn[name] = UInt64(ifData.ifi_ibytes)
                        curOut[name] = UInt64(ifData.ifi_obytes)
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            current = next
        }

        // Accumulate wrap-aware deltas into 64-bit running totals. The kernel only
        // exposes 32-bit byte counters (via getifaddrs or the routing socket) that
        // wrap every 4 GiB, so reporting them raw made totals a tiny fraction of
        // reality once an interface had moved >4 GiB since boot. By summing positive
        // per-interface deltas each poll we get accurate totals for all traffic seen
        // while Blip is running, independent of macOS struct-layout changes.
        let wrap: UInt64 = 1 << 32
        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (ifName, cur) in curIn {
            if let last = perIfLastIn[ifName] {
                deltaIn += cur >= last ? (cur - last) : (wrap - last + cur)
            }
            perIfLastIn[ifName] = cur
        }
        for (ifName, cur) in curOut {
            if let last = perIfLastOut[ifName] {
                deltaOut += cur >= last ? (cur - last) : (wrap - last + cur)
            }
            perIfLastOut[ifName] = cur
        }
        accumulatedIn &+= deltaIn
        accumulatedOut &+= deltaOut

        // Expose cumulative totals for traffic seen since Blip started.
        stats.totalBytesDownloaded = accumulatedIn
        stats.totalBytesUploaded = accumulatedOut

        // Build interface list for all active en* interfaces with IPs
        stats.interfaces = ifHasIP.sorted().map { ifName in
            let displayName = Self.interfaceDisplayName(ifName)
            return InterfaceInfo(
                id: ifName,
                name: displayName,
                ipv4: ifIPv4[ifName] ?? "—",
                ipv6: ifIPv6[ifName] ?? "—",
                macAddress: ifMAC[ifName] ?? "—",
                isActive: true
            )
        }

        // Get router (default gateway) IP — cache and refresh every 15th cycle (~30s)
        gatewayPollCount += 1
        if cachedGateway == nil || gatewayPollCount % 15 == 1 {
            cachedGateway = Self.readDefaultGateway()
        }
        stats.routerIP = cachedGateway ?? "—"

        // Calculate speed from this poll's delta. Skip the first poll (no baseline yet)
        // so a freshly seeded interface doesn't register a spurious spike.
        let now = Date()
        if let prev = previousTimestamp {
            let interval = now.timeIntervalSince(prev)
            if interval > 0 {
                stats.downloadSpeed = UInt64(Double(deltaIn) / interval)
                stats.uploadSpeed = UInt64(Double(deltaOut) / interval)
            }
        }
        previousTimestamp = now

        // Measure pings every 5th poll (~10 seconds) to avoid spamming
        pingCount += 1
        if pingCount % 5 == 1 && stats.isConnected {
            lastPing = measurePing(host: pingTarget)
            if stats.routerIP != "—" {
                lastRouterPing = measurePing(host: stats.routerIP)
            }
        }
        stats.pingMs = lastPing
        stats.routerPingMs = lastRouterPing

        return stats
    }

    /// Reads the default gateway IP via sysctl routing table (no subprocess needed).
    /// Falls back to netstat if the sysctl approach fails.
    private static func readDefaultGateway() -> String {
        // Try sysctl route lookup first — no subprocess, sandbox-friendly
        if let gw = readGatewayViaSysctl() { return gw }
        #if !APPSTORE
        // Fallback to netstat (subprocess, not permitted on App Store)
        return readGatewayViaNetstat()
        #else
        return "—"
        #endif
    }

    /// Parse the routing table via sysctl NET_RT_FLAGS to find the default gateway.
    private static func readGatewayViaSysctl() -> String? {
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var bufferSize = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) == 0, bufferSize > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &bufferSize, nil, 0) == 0 else {
            return nil
        }

        var offset = 0
        while offset < bufferSize {
            let rtm = buffer.withUnsafeBufferPointer { ptr -> rt_msghdr in
                ptr.baseAddress!.advanced(by: offset)
                    .withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
            }
            let msgLen = Int(rtm.rtm_msglen)
            guard msgLen > 0 else { break }

            // Look for default route (destination 0.0.0.0)
            if rtm.rtm_flags & RTF_GATEWAY != 0 {
                let saStart = offset + MemoryLayout<rt_msghdr>.size
                // First sockaddr is destination, second is gateway
                if rtm.rtm_addrs & RTA_DST != 0 && rtm.rtm_addrs & RTA_GATEWAY != 0 {
                    let dst = buffer.withUnsafeBufferPointer { ptr -> sockaddr_in in
                        ptr.baseAddress!.advanced(by: saStart)
                            .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    }
                    // Default route has destination 0.0.0.0
                    if dst.sin_addr.s_addr == 0 {
                        let gwOffset = saStart + Int(max(dst.sin_len, UInt8(MemoryLayout<sockaddr_in>.size)))
                        // Align to 4-byte boundary
                        let alignedGwOffset = (gwOffset + 3) & ~3
                        if alignedGwOffset + MemoryLayout<sockaddr_in>.size <= bufferSize {
                            let gw = buffer.withUnsafeBufferPointer { ptr -> sockaddr_in in
                                ptr.baseAddress!.advanced(by: alignedGwOffset)
                                    .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                            }
                            if gw.sin_family == UInt8(AF_INET) {
                                let addr = gw.sin_addr
                                if let cStr = inet_ntoa(addr) {
                                    return String(cString: cStr)
                                }
                            }
                        }
                    }
                }
            }
            offset += msgLen
        }
        return nil
    }

    #if !APPSTORE
    /// Fallback: reads the default gateway via netstat subprocess.
    private static func readGatewayViaNetstat() -> String {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn", "-f", "inet"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 && parts[0] == "default" {
                    return String(parts[1])
                }
            }
        } catch {}
        return "—"
    }
    #endif

    /// Maps interface names to user-friendly display names
    private static func interfaceDisplayName(_ name: String) -> String {
        // Common macOS interface mappings
        switch name {
        case "en0": return "Wi-Fi"
        case "en1": return "Thunderbolt Ethernet"
        case "en2": return "Thunderbolt Ethernet 2"
        case "en3": return "Thunderbolt Ethernet 3"
        case "en4": return "Thunderbolt Ethernet 4"
        case "en5": return "USB Ethernet"
        default:
            if name.hasPrefix("en") { return "Ethernet (\(name))" }
            return name
        }
    }

    /// Measures latency by timing a TCP connection to a host
    private func measurePing(host: String, port: UInt16 = 53) -> Double? {

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { Darwin.close(sock) }

        // Set non-blocking with 2s timeout
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        let start = CFAbsoluteTimeGetCurrent()
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        guard result == 0 else { return nil }
        return elapsed
    }
}
