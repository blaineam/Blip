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
    /// nil when the selected server is download-only (e.g. OVH / Hetzner static files).
    let upMbps: Double?
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

/// Where the throughput test sends its traffic. Blip uses **OpenSpeedTest** servers
/// exclusively — they're open-source and explicitly sanctioned for direct use, unlike
/// reverse-engineered endpoints of public web tools. Point this at your own self-hosted
/// OpenSpeedTest server (Docker), or any OpenSpeedTest-Server-compatible instance that
/// exposes the `/downloading` and `/upload` endpoints.
enum SpeedTestServer: Equatable, Sendable {
    /// OpenSpeedTest's public hosted test, driven headlessly via their embeddable widget.
    case openSpeedTestPublic
    /// A self-hosted OpenSpeedTest server, e.g. "http://192.168.1.50:3000".
    case openSpeedTest(baseURL: String)

    /// Normalized base URL (self-hosted only), or nil for the public test / an empty entry.
    var openSpeedTestBase: String? {
        guard case let .openSpeedTest(raw) = self else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The public widget runs against OpenSpeedTest's donated infrastructure — only ever
    /// used for explicit, manual runs (never automated interval testing).
    var isPublic: Bool { if case .openSpeedTestPublic = self { return true } else { return false } }

    var supportsUpload: Bool { true }
    var displayName: String {
        switch self {
        case .openSpeedTestPublic: return "OpenSpeedTest (public)"
        case .openSpeedTest: return "Self-hosted"
        }
    }
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

    /// Target server. Set this before calling `start()`. Defaults to the public
    /// OpenSpeedTest test so it works out of the box.
    var server: SpeedTestServer = .openSpeedTestPublic

    /// Number of concurrent transfers used to saturate fast links. Tests run against the
    /// user's own OpenSpeedTest server, so we can saturate freely.
    private let parallelism = 6
    /// Duration of each measured phase (seconds).
    private let phaseDuration: TimeInterval = 8
    /// Short warm-up window discarded from the measurement (seconds).
    private let warmup: TimeInterval = 1.5
    /// Bytes requested per download chunk (OpenSpeedTest streams a large response).
    private let downloadChunkBytes = 50_000_000
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
        publicRunner?.cancel()
        publicRunner = nil
        if isRunning { phase = .idle }
        liveMbps = 0
    }

    /// Active headless runner for the OpenSpeedTest public widget (when that server is used).
    private var publicRunner: OpenSpeedTestWidgetRunner?

    // MARK: - Automated interval runs

    /// When true, an interval test runs every `intervalMinutes`. Lives on the tester
    /// (not the view) so it keeps running while the panel is closed.
    @Published var autoRun = false {
        didSet {
            if autoRun {
                startAutoTimer()
                // Never auto-run the public widget (it leans on donated infra) — manual only.
                if !suppressImmediateRun, !autoRunBlocked, !server.isPublic, !isRunning { start() }
            } else {
                stopAutoTimer()
            }
        }
    }
    @Published var intervalMinutes = 15 { didSet { if autoRun { startAutoTimer() } } }
    /// Set by the UI from network conditions. When true the *automated* run is skipped
    /// (metered / expensive / constrained network). A manual `start()` is never blocked.
    var autoRunBlocked = false
    private var autoTimer: Timer?
    /// Set while resuming a persisted schedule at launch so we don't fire a heavy test
    /// on every app start.
    private var suppressImmediateRun = false

    /// Resume a persisted auto-run schedule at app launch: starts the interval timer
    /// WITHOUT an immediate run. Call this once from the app delegate so interval tests
    /// keep running across restarts without needing to open the Network panel.
    func resumeAutoRun(every minutes: Int) {
        intervalMinutes = max(1, minutes)
        guard !autoRun else { return }
        suppressImmediateRun = true
        autoRun = true
        suppressImmediateRun = false
    }

    private func startAutoTimer() {
        stopAutoTimer()
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        // Use .common run-loop mode so the timer also fires while menus/popovers are open.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            Task { @MainActor in
                guard !self.autoRunBlocked, !self.server.isPublic, !self.isRunning else { return }
                self.start()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    private func stopAutoTimer() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    private func run() async {
        do {
            let result: NetSpeedResult
            if server.isPublic {
                result = try await runPublicWidget()
            } else {
                phase = .download
                liveMbps = 0
                let down = try await measure(direction: .download)
                try Task.checkCancellation()

                phase = .upload
                liveMbps = 0
                let up = try await measure(direction: .upload)
                try Task.checkCancellation()

                result = NetSpeedResult(downMbps: down, upMbps: up, timestamp: Date())
            }

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

    /// Drive OpenSpeedTest's public test headlessly and surface live progress + the result
    /// as if it were a native run.
    private func runPublicWidget() async throws -> NetSpeedResult {
        phase = .download
        liveMbps = 0
        let runner = OpenSpeedTestWidgetRunner()
        publicRunner = runner
        defer { publicRunner = nil }
        let r = try await runner.run { [weak self] isUpload, mbps in
            guard let self else { return }
            self.phase = isUpload ? .upload : .download
            if let mbps { self.liveMbps = mbps }
        }
        try Task.checkCancellation()
        return NetSpeedResult(downMbps: r.down, upMbps: r.up, timestamp: Date())
    }

    private enum Direction { case download, upload }

    /// Resolves the endpoints for a direction from the configured server. Built on
    /// the main actor (reads `server`); the returned values are Sendable so the
    /// background transfer runner can mint fresh URLs without actor hops.
    ///
    /// The test only ever contacts the server the user selected — Cloudflare or
    /// their own LAN OpenSpeedTest server. It deliberately does NOT fall back to
    /// any other third-party host: if the chosen server errors (e.g. Cloudflare
    /// rate-limits), the test surfaces a clear message rather than silently
    /// routing the user's traffic to a host they didn't pick.
    private func endpoints(for direction: Direction) -> [SpeedEndpoint] {
        let base = server.openSpeedTestBase ?? ""
        return [direction == .download ? .openSpeedTestDown(base: base) : .openSpeedTestUp(base: base)]
    }

    /// Runs `parallelism` concurrent transfers for `phaseDuration` seconds and
    /// returns the measured throughput in Mbps (warm-up window excluded). Bytes are
    /// counted at the chunk level via a `URLSession` delegate (not per-byte), which
    /// is what makes multi-gigabit links measurable.
    private func measure(direction: Direction) async throws -> Double {
        let runner = ThroughputRunner(
            endpoints: endpoints(for: direction),
            uploadBody: direction == .upload ? Data(count: uploadChunkBytes) : nil
        )
        defer { runner.stop() }

        let start = Date()
        let warmupEnd = start.addingTimeInterval(warmup)
        let deadline = start.addingTimeInterval(phaseDuration)
        runner.start(parallelism: parallelism, deadline: deadline)

        // Sample throughput each tick; capture the byte count at warm-up end so the
        // reported number excludes TCP slow-start. We measure over the window in which
        // data actually flowed ([warmupEnd, lastProgress]) so that hitting the per-phase
        // request cap early (on a very fast link) doesn't dilute the result with idle time.
        var bytesAtWarmup: Int?
        var lastBytes = 0
        var lastProgress = warmupEnd
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000_000)
            let now = Date()
            let b = runner.bytes
            if bytesAtWarmup == nil, now >= warmupEnd { bytesAtWarmup = b; lastBytes = b; lastProgress = now }
            if let baseline = bytesAtWarmup {
                if b > lastBytes { lastBytes = b; lastProgress = now }
                let elapsed = lastProgress.timeIntervalSince(warmupEnd)
                if elapsed > 0 {
                    liveMbps = Double(lastBytes - baseline) * 8 / elapsed / 1_000_000
                }
                // Transfers wound down (e.g. request cap reached) — stop measuring idle time.
                if now.timeIntervalSince(lastProgress) > 0.5, lastBytes - baseline > 0 { break }
            }
        }

        let baseline = bytesAtWarmup ?? 0
        let measuredBytes = max(0, lastBytes - baseline)
        let measuredSeconds = max(0.001, lastProgress.timeIntervalSince(warmupEnd))
        runner.stop()

        if measuredBytes == 0 {
            if runner.httpError != 0 { throw SpeedTestHTTPError(status: runner.httpError) }
            throw runner.lastError ?? URLError(.cannotConnectToHost)
        }
        return Double(measuredBytes) * 8 / measuredSeconds / 1_000_000
    }

    private static func message(for error: Error) -> String {
        if let widget = error as? OpenSpeedTestWidgetRunner.RunError {
            switch widget {
            case .loadFailed: return "Couldn't reach openspeedtest.com. Check your connection, or use a self-hosted server."
            case .timedOut: return "Public test timed out. Try again, or use a self-hosted server."
            case .noResult, .cancelled: return "Public test didn't finish. Try again, or use a self-hosted server."
            }
        }
        if let httpError = error as? SpeedTestHTTPError {
            switch httpError.status {
            case 429:
                return "Server busy (rate-limited). Wait a moment, or pick an OpenSpeedTest LAN server in Settings."
            case 403:
                return "Server rejected the request (403). Try an OpenSpeedTest LAN server in Settings."
            default:
                return "Server error (HTTP \(httpError.status)). Try again, or use an OpenSpeedTest server."
            }
        }
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

/// Raised when the speed-test server returns an HTTP error status (e.g. 429/403),
/// so the UI can show a precise, actionable message instead of a generic failure.
private struct SpeedTestHTTPError: Error { let status: Int }

/// A resolved speed-test endpoint. Sendable so the background runner can mint a
/// fresh URL per request without touching the main actor.
private enum SpeedEndpoint: Sendable {
    case openSpeedTestDown(base: String)
    case openSpeedTestUp(base: String)

    func makeURL() -> URL? {
        switch self {
        case .openSpeedTestDown(let base):
            return URL(string: "\(base)/downloading?r=\(Int.random(in: 0...Int.max))")
        case .openSpeedTestUp(let base):
            return URL(string: "\(base)/upload?r=\(Int.random(in: 0...Int.max))")
        }
    }
}

/// Drives the actual byte transfers for one direction. Counts bytes at the chunk
/// level via `URLSessionDataDelegate` (download) / `didSendBodyData` (upload) and
/// keeps `parallelism` transfers in flight, relaunching each as it finishes, until
/// the deadline. Lock-protected so the main-actor sampler can read `bytes` safely.
private final class ThroughputRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let endpoints: [SpeedEndpoint]
    private let uploadBody: Data?
    private let lock = NSLock()
    private var _bytes = 0
    private var _lastError: Error?
    private var _httpError = 0
    /// Index into `endpoints`; advances when the current endpoint returns an HTTP error.
    private var _endpointIndex = 0
    private var stopped = false
    private var invalidated = false
    private var deadline = Date.distantPast
    /// Hard cap on total requests issued this phase (a good-citizen limit so a single
    /// test can't flood a public server even on a very fast link). 0 = unlimited.
    private let maxRequests: Int
    private var _launchCount = 0

    init(endpoints: [SpeedEndpoint], uploadBody: Data?, maxRequests: Int = 0) {
        self.endpoints = endpoints
        self.uploadBody = uploadBody
        self.maxRequests = maxRequests
        super.init()
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 24
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var bytes: Int { lock.lock(); defer { lock.unlock() }; return _bytes }
    var lastError: Error? { lock.lock(); defer { lock.unlock() }; return _lastError }
    /// Non-zero once the server returned an HTTP error status (e.g. 429 rate-limited,
    /// 403 rejected). Surfaced so `measure()` can report a precise, actionable message.
    var httpError: Int { lock.lock(); defer { lock.unlock() }; return _httpError }

    func start(parallelism: Int, deadline: Date) {
        lock.lock(); self.deadline = deadline; stopped = false; lock.unlock()
        for _ in 0..<parallelism { launch() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let alreadyInvalidated = invalidated
        invalidated = true
        lock.unlock()
        if !alreadyInvalidated { session.invalidateAndCancel() }
    }

    private func launch() {
        lock.lock()
        // Stop relaunching once every endpoint has been exhausted with HTTP errors —
        // hammering a rate-limited server only deepens the throttle. Fail fast instead.
        // Also stop once the per-phase request cap is reached.
        let underCap = maxRequests == 0 || _launchCount < maxRequests
        let go = !stopped && _httpError == 0 && underCap && Date() < deadline
        let index = _endpointIndex
        if go { _launchCount += 1 }
        lock.unlock()
        guard go, index < endpoints.count, let url = endpoints[index].makeURL() else { return }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task: URLSessionTask
        if let body = uploadBody {
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            task = session.uploadTask(with: request, from: body)
        } else {
            task = session.dataTask(with: request)
        }
        // Stamp the endpoint index so an HTTP error only advances the fallback once per
        // endpoint (concurrent failures on the same source don't skip past good ones).
        task.taskDescription = String(index)
        task.resume()
    }

    // Reject error responses up front so their tiny error-page bodies are never counted
    // as throughput (which silently produced a near-zero "successful" result). A status
    // >= 400 (e.g. 429 rate-limited, 403 rejected) cancels the transfer and is recorded.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let taskIndex = Int(dataTask.taskDescription ?? "") ?? 0
            lock.lock()
            // Only the failure on the currently-active endpoint advances the fallback,
            // so concurrent errors on the same source advance the index just once.
            if taskIndex == _endpointIndex {
                if _endpointIndex + 1 < endpoints.count {
                    _endpointIndex += 1                       // fall back to the next CDN
                } else if _httpError == 0 {
                    _httpError = http.statusCode               // all sources exhausted
                }
            }
            lock.unlock()
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    // Download: count each delivered chunk (delegate streams, no full buffering).
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); _bytes += data.count; lock.unlock()
    }

    // Upload: count body bytes as they are sent.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.lock(); _bytes += Int(bytesSent); lock.unlock()
    }

    // When a transfer finishes (or errors), relaunch another until the deadline.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, (error as? URLError)?.code != .cancelled {
            let taskIndex = Int(task.taskDescription ?? "") ?? 0
            lock.lock()
            _lastError = error
            // A connection-level failure (e.g. host unreachable, DNS, timeout) before any
            // bytes have arrived means this endpoint is unusable — fall back like an HTTP
            // error so a dead CDN never traps the whole test on a single source.
            if _bytes == 0, taskIndex == _endpointIndex, _endpointIndex + 1 < endpoints.count {
                _endpointIndex += 1
            }
            lock.unlock()
        }
        launch()
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
    #if !APPSTORE
    private var cachedTotals: (down: UInt64, up: UInt64)?
    private var totalsPollCount = 0
    #endif
    var pingTarget: String = "1.1.1.1"
    private var _isExpensive = false
    private var _isConstrained = false

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?._isConnected = path.status == .satisfied
            self?._isExpensive = path.isExpensive
            self?._isConstrained = path.isConstrained
        }
        pathMonitor.start(queue: monitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }

    func read() -> NetworkStats {
        var stats = NetworkStats()
        stats.isConnected = _isConnected
        stats.isExpensive = _isExpensive
        stats.isConstrained = _isConstrained

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

        // Cumulative totals. Prefer the kernel's true 64-bit since-boot counters
        // (what Activity Monitor shows) via netstat; the wrap-aware session
        // accumulation is the fallback when the subprocess isn't available.
        #if APPSTORE
        // Sandboxed: netstat can't be spawned here — the helper supplies since-boot
        // totals (see SystemMonitor merge). Until then, show the session accumulation.
        stats.totalBytesDownloaded = accumulatedIn
        stats.totalBytesUploaded = accumulatedOut
        #else
        // netstat is a subprocess — refresh totals every ~5th poll (~10s) and cache.
        totalsPollCount += 1
        if cachedTotals == nil || totalsPollCount % 5 == 1 {
            cachedTotals = Self.readSinceBootTotals()
        }
        if let totals = cachedTotals {
            stats.totalBytesDownloaded = totals.down
            stats.totalBytesUploaded = totals.up
        } else {
            stats.totalBytesDownloaded = accumulatedIn
            stats.totalBytesUploaded = accumulatedOut
        }
        #endif

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

    #if !APPSTORE
    /// Sums since-boot RX/TX bytes for physical interfaces by parsing `netstat -ib`.
    /// netstat reports the kernel's true 64-bit counters (the same numbers Activity
    /// Monitor shows); the routing-socket `if_data64` struct is unreliable to parse on
    /// recent macOS, and `getifaddrs` exposes only 32-bit counters that wrap at 4 GiB.
    static func readSinceBootTotals() -> (down: UInt64, up: UInt64)? {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-ib"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return Self.parseNetstatTotals(output)
        } catch {
            return nil
        }
    }

    /// Parses `netstat -ib` output, summing Ibytes/Obytes across the `<Link#…>` rows
    /// of physical `en*` interfaces (one Link row per interface avoids double-counting
    /// the per-address rows).
    static func parseNetstatTotals(_ output: String) -> (down: UInt64, up: UInt64) {
        var down: UInt64 = 0
        var up: UInt64 = 0
        for line in output.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes [Coll]
            guard cols.count >= 10,
                  cols[0].hasPrefix("en"),
                  cols[2].hasPrefix("<Link"),
                  let ib = UInt64(cols[6]),
                  let ob = UInt64(cols[9]) else { continue }
            down += ib
            up += ob
        }
        return (down, up)
    }
    #endif

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
