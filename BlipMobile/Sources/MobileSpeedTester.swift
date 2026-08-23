import Foundation
import Combine

// A slim, URLSession-only OpenSpeedTest client for iOS — the Mac SpeedTester's public-widget
// path rides a WKWebView-in-NSWindow runner that has no iOS shape, so mobile speaks only to
// SELF-HOSTED OpenSpeedTest servers (`/downloading?...` and `/upload`), same endpoints, same
// design stance ("open-source and explicitly sanctioned; never reverse-engineered web tools").
// TODO(unify): fold this and the Mac SpeedTester's HTTP core into Shared/ next time either
// needs surgery — the loop below is deliberately the same algorithm.

struct MobileSpeedResult: Identifiable, Sendable, Codable {
    var id = UUID()
    let downMbps: Double
    let upMbps: Double?
    let date: Date
}

@MainActor
final class MobileSpeedTester: ObservableObject {
    enum Phase: Equatable { case idle, download, upload, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveMbps: Double = 0
    @Published private(set) var lastResult: MobileSpeedResult?
    @Published var serverBase: String {
        didSet { UserDefaults.standard.set(serverBase, forKey: "mobile.speed.server") }
    }

    private var task: Task<Void, Never>?

    init() {
        serverBase = UserDefaults.standard.string(forKey: "mobile.speed.server") ?? ""
    }

    var isRunning: Bool { phase == .download || phase == .upload }

    func toggle(interface: String) { isRunning ? cancel() : start(interface: interface) }

    func cancel() {
        task?.cancel()
        phase = .idle
        liveMbps = 0
    }

    func start(interface: String) {
        guard !isRunning else { return }
        var base = serverBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { phase = .failed("Set your OpenSpeedTest server address first."); return }
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let baseURL = URL(string: base) else { phase = .failed("That server address isn't a URL."); return }

        phase = .download
        liveMbps = 0
        task = Task { [weak self] in
            do {
                let down = try await Self.measureDownload(baseURL) { mbps in
                    Task { @MainActor in self?.liveMbps = mbps }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.phase = .upload; self?.liveMbps = 0 }
                let up = try await Self.measureUpload(baseURL) { mbps in
                    Task { @MainActor in self?.liveMbps = mbps }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    let result = MobileSpeedResult(downMbps: down, upMbps: up, date: Date())
                    self.lastResult = result
                    self.phase = .done
                    self.liveMbps = 0
                    MobileSharedStore.write(speed: .init(downMbps: down, upMbps: up, date: result.date, interface: interface))
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.phase = .failed((error as NSError).localizedDescription) }
            }
        }
    }

    // MARK: - Transfer loops (8 s per direction, 4 concurrent streams)

    private static func measureDownload(_ base: URL, live: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let duration = 8.0
        let streams = 4
        let counter = ByteCounter()
        let start = CFAbsoluteTimeGetCurrent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<streams {
                group.addTask {
                    while CFAbsoluteTimeGetCurrent() - start < duration && !Task.isCancelled {
                        let url = base.appendingPathComponent("downloading")
                            .appending(queryItems: [.init(name: "n", value: "\(Int.random(in: 1...9_999_999))"),
                                                     .init(name: "ckSize", value: "20")])
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 12
                        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
                        let (bytes, _) = try await URLSession.shared.bytes(for: req)
                        for try await _ in bytes.prefix(0) {}   // headers validated; stream below
                        var chunk = 0
                        for try await _ in bytes {
                            chunk += 1
                            if chunk % (256 << 10) == 0 {
                                counter.add(chunk); chunk = 0
                                live(counter.mbps(since: start))
                                if CFAbsoluteTimeGetCurrent() - start >= duration || Task.isCancelled { break }
                            }
                        }
                        counter.add(chunk)
                    }
                    _ = i
                }
            }
            try await group.waitForAll()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return counter.mbps(elapsed: elapsed)
    }

    private static func measureUpload(_ base: URL, live: @escaping @Sendable (Double) -> Void) async throws -> Double? {
        let duration = 8.0
        let streams = 3
        let payload = Data(repeating: 0x42, count: 4 << 20)   // 4 MB per POST
        let counter = ByteCounter()
        let start = CFAbsoluteTimeGetCurrent()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<streams {
                group.addTask {
                    while CFAbsoluteTimeGetCurrent() - start < duration && !Task.isCancelled {
                        var req = URLRequest(url: base.appendingPathComponent("upload"))
                        req.httpMethod = "POST"
                        req.timeoutInterval = 12
                        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        _ = try await URLSession.shared.upload(for: req, from: payload)
                        counter.add(payload.count)
                        live(counter.mbps(since: start))
                    }
                }
            }
            try await group.waitForAll()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let mbps = counter.mbps(elapsed: elapsed)
        return mbps > 0 ? mbps : nil
    }
}

/// Lock-guarded byte tally shared by the concurrent streams.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func add(_ n: Int) { lock.lock(); bytes += n; lock.unlock() }
    func mbps(since start: Double) -> Double {
        mbps(elapsed: CFAbsoluteTimeGetCurrent() - start)
    }
    func mbps(elapsed: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard elapsed > 0.2 else { return 0 }
        return Double(bytes) * 8 / elapsed / 1_000_000
    }
}
