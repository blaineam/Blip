import SwiftUI
import UniformTypeIdentifiers

// Disk speed test for iOS (#feedback: "port disk speed tests too — internal or external").
// Internal = the app's own container (the system SSD; sandbox paths hit the same NAND).
// External = any folder the user picks in Files — USB-C drives, SMB shares mounted by
// Files, whatever. Security-scoped access, test file cleaned up in ALL exits.
//
// Method mirrors the Mac's DiskSpeedTester philosophy: sequential write then read of one
// large file with F_NOCACHE so we measure the medium, not the unified buffer cache.

struct DiskBenchResult: Equatable {
    let writeMBps: Double
    let readMBps: Double
    let volumeName: String
    let date: Date
}

@MainActor
final class MobileDiskBench: ObservableObject {
    enum Phase: Equatable { case idle, writing, reading, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveMBps: Double = 0
    @Published private(set) var result: DiskBenchResult?

    var isRunning: Bool { phase == .writing || phase == .reading }

    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); phase = .idle; liveMBps = 0 }

    func runInternal() {
        let dir = FileManager.default.temporaryDirectory
        run(in: dir, name: "Internal storage", scoped: false)
    }

    func runExternal(at url: URL) {
        let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
        run(in: url, name: name, scoped: true)
    }

    private func run(in dir: URL, name: String, scoped: Bool) {
        guard !isRunning else { return }
        phase = .writing
        liveMBps = 0
        result = nil
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let scopeGranted = scoped ? dir.startAccessingSecurityScopedResource() : false
            defer { if scopeGranted { dir.stopAccessingSecurityScopedResource() } }
            let file = dir.appendingPathComponent(".blip-diskbench-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let write = try Self.sequentialWrite(to: file) { mbps in
                    Task { @MainActor in self?.liveMBps = mbps }
                }
                if Task.isCancelled { return }
                await MainActor.run { self?.phase = .reading; self?.liveMBps = 0 }
                let read = try Self.sequentialRead(from: file) { mbps in
                    Task { @MainActor in self?.liveMBps = mbps }
                }
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    self.result = DiskBenchResult(writeMBps: write, readMBps: read, volumeName: name, date: Date())
                    self.phase = .done
                    self.liveMBps = 0
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { self?.phase = .failed((error as NSError).localizedDescription) }
            }
        }
    }

    // 512 MB in 8 MB chunks — enough to escape burst caches on real media without
    // chewing minutes on a slow thumb drive; budget-capped at ~20 s per direction.
    nonisolated private static let chunk = 8 << 20
    nonisolated private static let maxBytes = 512 << 20
    nonisolated private static let budget = 20.0

    nonisolated private static func sequentialWrite(to url: URL, live: @escaping @Sendable (Double) -> Void) throws -> Double {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        let data = Data(repeating: 0xB1, count: chunk)   // incompressible enough for NAND; fixed pattern is fine for throughput
        let start = CFAbsoluteTimeGetCurrent()
        var written = 0
        while written < maxBytes {
            if Task.isCancelled { break }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > budget { break }
            try handle.write(contentsOf: data)
            written += chunk
            live(Double(written) / max(elapsed, 0.05) / 1_048_576)
        }
        try handle.synchronize()   // include the flush — honesty over flattery
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard written > 0, elapsed > 0.2 else { throw CocoaError(.fileWriteUnknown) }
        return Double(written) / elapsed / 1_048_576
    }

    nonisolated private static func sequentialRead(from url: URL, live: @escaping @Sendable (Double) -> Void) throws -> Double {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        let start = CFAbsoluteTimeGetCurrent()
        var read = 0
        while true {
            if Task.isCancelled { break }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if elapsed > budget { break }
            guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { break }
            read += data.count
            live(Double(read) / max(elapsed, 0.05) / 1_048_576)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard read > 0, elapsed > 0.05 else { throw CocoaError(.fileReadUnknown) }
        return Double(read) / elapsed / 1_048_576
    }
}

/// The Storage detail's disk-test section, including the external-folder picker.
struct MobileDiskBenchSection: View {
    @ObservedObject var bench: MobileDiskBench
    @State private var showPicker = false

    var body: some View {
        Section {
            if bench.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(bench.phase == .writing ? "Writing…" : "Reading…")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(String(format: "%.0f MB/s", bench.liveMBps))
                            .font(.system(.callout, design: .rounded).weight(.bold))
                            .contentTransition(.numericText())
                    }
                    ProgressView().frame(maxWidth: .infinity)
                    Button("Cancel", role: .destructive) { bench.cancel() }
                        .buttonStyle(.borderless)
                }
            } else {
                if let r = bench.result {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.volumeName).font(.callout.weight(.semibold))
                        HStack(spacing: 16) {
                            Label(String(format: "%.0f MB/s write", r.writeMBps), systemImage: "arrow.down.doc")
                            Label(String(format: "%.0f MB/s read", r.readMBps), systemImage: "arrow.up.doc")
                        }
                        .font(.callout)
                    }
                }
                if case .failed(let why) = bench.phase {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button { bench.runInternal() } label: {
                    Label("Test Internal Storage", systemImage: "internaldrive")
                }
                Button { showPicker = true } label: {
                    Label("Test External Volume…", systemImage: "externaldrive")
                }
            }
        } header: {
            Text("Disk Speed")
        } footer: {
            Text("Sequential write-then-read of a large temporary file with caching disabled, flush included. External volumes: pick any folder in Files — a USB-C drive, an SMB share — and the test runs there. The test file is removed afterward.")
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { bench.runExternal(at: url) }
        }
    }
}
