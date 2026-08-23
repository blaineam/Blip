import Foundation
import Combine

// The mobile speed tester, second edition.
//
// The first edition read URLSession.AsyncBytes ONE BYTE AT A TIME to count throughput — the
// iterator overhead CPU-capped the whole test at ~25 Mbps on a 10-gig LAN (reported from the
// field within the hour). Counting now happens where the Mac's does: in a URLSession delegate's
// didReceive-data callback, which sees whole buffers.
//
// Two sources, mirroring the Mac:
//   .publicWidget — OpenSpeedTest's hosted test via the ported invisible-WKWebView runner.
//   .custom       — a self-hosted OpenSpeedTest server (address lives in Settings).
// History is capped and stored in the App Group so the widget can show the latest.

struct MobileSpeedResult: Identifiable, Sendable, Codable, Equatable {
    var id = UUID()
    let downMbps: Double
    let upMbps: Double?
    let pingMs: Double?
    let date: Date
    let interface: String
    let source: String            // "OpenSpeedTest" / server host
}

enum SpeedSource: String, CaseIterable, Identifiable {
    case publicWidget, custom
    var id: String { rawValue }
    var label: String { self == .publicWidget ? "OpenSpeedTest (public)" : "My server" }
}

@MainActor
final class MobileSpeedTester: ObservableObject {
    enum Phase: Equatable { case idle, connecting, download, upload, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var lastResult: MobileSpeedResult?
    @Published private(set) var history: [MobileSpeedResult] = []
    @Published var source: SpeedSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "mobile.speed.source") }
    }

    static let maxHistory = 10
    private var task: Task<Void, Never>?
    private var publicRunner: OpenSpeedTestWidgetRunner?

    init() {
        source = SpeedSource(rawValue: UserDefaults.standard.string(forKey: "mobile.speed.source") ?? "") ?? .publicWidget
        history = Self.loadHistory()
        lastResult = history.last
    }

    var isRunning: Bool {
        switch phase { case .connecting, .download, .upload: return true; default: return false }
    }

    /// The configured self-hosted server (Settings owns the value).
    static var customServer: String {
        UserDefaults.standard.string(forKey: "mobile.speed.server") ?? ""
    }

    func toggle(interface: String) { isRunning ? cancel() : start(interface: interface) }

    func cancel() {
        task?.cancel()
        publicRunner?.cancel(); publicRunner = nil
        phase = .idle
        liveMbps = 0
    }

    func start(interface: String) {
        guard !isRunning else { return }
        liveMbps = 0
        switch source {
        case .publicWidget: startPublic(interface: interface)
        case .custom: startCustom(interface: interface)
        }
    }

    // MARK: - Public widget (ported runner)

    private func startPublic(interface: String) {
        phase = .connecting
        let runner = OpenSpeedTestWidgetRunner()
        publicRunner = runner
        task = Task { [weak self] in
            do {
                let r = try await runner.run { isUpload, mbps in
                    guard let self else { return }
                    self.phase = isUpload ? .upload : .download
                    if let mbps { self.liveMbps = mbps }
                }
                await MainActor.run {
                    self?.record(down: r.down, up: r.up, ping: r.ping,
                                 interface: interface, source: "OpenSpeedTest")
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.phase = .failed(Self.describe(error)) }
            }
            await MainActor.run { self?.publicRunner = nil }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? OpenSpeedTestWidgetRunner.RunError {
            switch e {
            case .loadFailed: return "Couldn't load the OpenSpeedTest widget."
            case .timedOut: return "The public test timed out."
            case .noResult: return "The test finished without a result."
            case .cancelled: return "Cancelled."
            }
        }
        return (error as NSError).localizedDescription
    }

    // MARK: - Self-hosted server (delegate-counted HTTP)

    private func startCustom(interface: String) {
        var base = Self.customServer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            phase = .failed("Set your server address in Settings first."); return
        }
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let baseURL = URL(string: base) else { phase = .failed("That server address isn't a URL."); return }

        phase = .download
        task = Task { [weak self] in
            do {
                let down = try await ThroughputRun.download(baseURL: baseURL, seconds: 8, streams: 4) { mbps in
                    Task { @MainActor in self?.liveMbps = mbps }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.phase = .upload; self?.liveMbps = 0 }
                let up = try await ThroughputRun.upload(baseURL: baseURL, seconds: 8, streams: 3) { mbps in
                    Task { @MainActor in self?.liveMbps = mbps }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.record(down: down, up: up, ping: nil,
                                 interface: interface, source: baseURL.host ?? "custom")
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.phase = .failed((error as NSError).localizedDescription) }
            }
        }
    }

    // MARK: - Result plumbing

    private func record(down: Double, up: Double?, ping: Double?, interface: String, source: String) {
        let result = MobileSpeedResult(downMbps: down, upMbps: up, pingMs: ping,
                                       date: Date(), interface: interface, source: source)
        lastResult = result
        phase = .done
        liveMbps = 0
        history.append(result)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        Self.saveHistory(history)
        MobileSharedStore.write(speed: .init(downMbps: down, upMbps: up, date: result.date, interface: interface))
    }

    private static func loadHistory() -> [MobileSpeedResult] {
        guard let data = MobileSharedStore.defaults.data(forKey: "speed.history") else { return [] }
        return (try? JSONDecoder().decode([MobileSpeedResult].self, from: data)) ?? []
    }
    private static func saveHistory(_ h: [MobileSpeedResult]) {
        if let data = try? JSONEncoder().encode(h) {
            MobileSharedStore.defaults.set(data, forKey: "speed.history")
        }
    }
}

// MARK: - Delegate-counted transfer engine

/// Byte counting in `urlSession(_:dataTask:didReceive:)` — whole buffers, zero per-byte cost.
enum ThroughputRun {
    static func download(baseURL: URL, seconds: Double, streams: Int,
                         live: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let counter = LiveCounter(live: live)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    let delegate = CountingDelegate(counter: counter)
                    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                    defer { session.invalidateAndCancel() }
                    while counter.elapsed < seconds && !Task.isCancelled {
                        var comps = URLComponents(url: baseURL.appendingPathComponent("downloading"), resolvingAgainstBaseURL: false)!
                        comps.queryItems = [.init(name: "n", value: "\(Int.random(in: 1...9_999_999))"),
                                            .init(name: "ckSize", value: "50")]
                        var req = URLRequest(url: comps.url!)
                        req.timeoutInterval = 15
                        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                        // One streamed request; the delegate counts every buffer as it lands.
                        do { try await delegate.run(req, in: session, budgetEnd: counter.start + seconds) }
                        catch { if Task.isCancelled { break } else { throw error } }
                    }
                }
            }
            try await group.waitForAll()
        }
        return counter.finalMbps()
    }

    static func upload(baseURL: URL, seconds: Double, streams: Int,
                       live: @escaping @Sendable (Double) -> Void) async throws -> Double? {
        let counter = LiveCounter(live: live)
        let payload = Data(repeating: 0x42, count: 8 << 20)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    while counter.elapsed < seconds && !Task.isCancelled {
                        var req = URLRequest(url: baseURL.appendingPathComponent("upload"))
                        req.httpMethod = "POST"
                        req.timeoutInterval = 15
                        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        _ = try? await URLSession.shared.upload(for: req, from: payload)
                        counter.add(payload.count)
                    }
                }
            }
            try await group.waitForAll()
        }
        let mbps = counter.finalMbps()
        return mbps > 0 ? mbps : nil
    }
}

final class LiveCounter: @unchecked Sendable {
    let start = CFAbsoluteTimeGetCurrent()
    private let lock = NSLock()
    private var bytes = 0
    private var lastReport = 0.0
    private let live: @Sendable (Double) -> Void
    init(live: @escaping @Sendable (Double) -> Void) { self.live = live }

    var elapsed: Double { CFAbsoluteTimeGetCurrent() - start }

    func add(_ n: Int) {
        lock.lock()
        bytes += n
        let now = CFAbsoluteTimeGetCurrent()
        let doReport = now - lastReport > 0.25
        if doReport { lastReport = now }
        let mbps = Double(bytes) * 8 / max(now - start, 0.2) / 1_000_000
        lock.unlock()
        if doReport { live(mbps) }
    }

    func finalMbps() -> Double {
        lock.lock(); defer { lock.unlock() }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard elapsed > 0.5 else { return 0 }
        return Double(bytes) * 8 / elapsed / 1_000_000
    }
}

final class CountingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let counter: LiveCounter
    private var continuation: CheckedContinuation<Void, Error>?
    private var budgetEnd: Double = .infinity
    private var task: URLSessionDataTask?

    init(counter: LiveCounter) { self.counter = counter }

    func run(_ request: URLRequest, in session: URLSession, budgetEnd: Double) async throws {
        self.budgetEnd = budgetEnd
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let t = session.dataTask(with: request)
            task = t
            t.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        counter.add(data.count)
        if CFAbsoluteTimeGetCurrent() > budgetEnd { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation; continuation = nil
        if let error, (error as NSError).code != NSURLErrorCancelled {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()   // budget-cancel is a normal end
        }
    }
}
