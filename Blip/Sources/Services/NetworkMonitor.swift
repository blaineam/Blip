import Foundation
import Network
import SystemConfiguration

final class NetworkMonitor: @unchecked Sendable {
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.blainemiller.Blip.network", qos: .utility)
    private var _isConnected = false
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
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

        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0
        var activeMacInterfaces = Set<String>()
        // Collect per-interface data for multi-interface display
        var ifIPv4: [String: String] = [:]
        var ifIPv6: [String: String] = [:]
        var ifMAC: [String: String] = [:]
        var ifHasIP: Set<String> = []

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

                    // Also collect byte counters
                    if let networkData = interface.ifa_data {
                        let ifData = networkData.assumingMemoryBound(to: if_data.self).pointee
                        totalBytesIn += UInt64(ifData.ifi_ibytes)
                        totalBytesOut += UInt64(ifData.ifi_obytes)
                    }
                }

                // Loopback counters
                if family == UInt8(AF_LINK) && name.hasPrefix("lo") {
                    if let networkData = interface.ifa_data {
                        let ifData = networkData.assumingMemoryBound(to: if_data.self).pointee
                        totalBytesIn += UInt64(ifData.ifi_ibytes)
                        totalBytesOut += UInt64(ifData.ifi_obytes)
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            current = next
        }

        // Expose cumulative totals since boot
        stats.totalBytesDownloaded = totalBytesIn
        stats.totalBytesUploaded = totalBytesOut

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

        // Calculate speed from delta
        let now = Date()
        if let prev = previousTimestamp {
            let interval = now.timeIntervalSince(prev)
            if interval > 0 {
                stats.downloadSpeed = totalBytesIn > previousBytesIn
                    ? UInt64(Double(totalBytesIn - previousBytesIn) / interval)
                    : 0
                stats.uploadSpeed = totalBytesOut > previousBytesOut
                    ? UInt64(Double(totalBytesOut - previousBytesOut) / interval)
                    : 0
            }
        }
        previousBytesIn = totalBytesIn
        previousBytesOut = totalBytesOut
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

    /// Reads the default gateway (router) IP from the routing table
    private static func readDefaultGateway() -> String {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn", "-f", "inet"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Find the default route line
            for line in output.components(separatedBy: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 && parts[0] == "default" {
                    return String(parts[1])
                }
            }
        } catch {}
        return "—"
    }

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
