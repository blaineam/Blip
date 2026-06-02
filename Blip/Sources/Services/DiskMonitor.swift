import Foundation
import SwiftUI
#if !APPSTORE
import IOKit
#endif

final class DiskMonitor: @unchecked Sendable {
    #if !APPSTORE
    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousTimestamp: Date?
    private var cachedSmartStatus: String?
    #endif

    func read() -> DiskStats {
        var stats = DiskStats()
        let fileManager = FileManager.default

        // Get mounted volume URLs
        guard let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey],
            options: [.skipHiddenVolumes]
        ) else {
            return stats
        }

        for url in volumeURLs {
            guard let resources = try? url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ]) else { continue }

            let name = resources.volumeName ?? url.lastPathComponent
            let total = UInt64(resources.volumeTotalCapacity ?? 0)
            let free = UInt64(resources.volumeAvailableCapacityForImportantUsage ?? 0)

            guard total > 0 else { continue }

            let volume = VolumeInfo(
                name: name,
                mountPoint: url.path,
                totalBytes: total,
                freeBytes: free
            )
            stats.volumes.append(volume)
        }

        // Sort: root volume first, then alphabetically
        stats.volumes.sort { a, b in
            if a.mountPoint == "/" { return true }
            if b.mountPoint == "/" { return false }
            return a.name < b.name
        }

        #if !APPSTORE
        // Read disk I/O from IOKit (undocumented IOBlockStorageDriver properties)
        readDiskIO(&stats)

        // SMART status (cached, only read once — uses diskutil subprocess)
        if let cached = cachedSmartStatus {
            stats.smartStatus = cached
        } else {
            let smart = Self.readSmartStatus()
            cachedSmartStatus = smart
            stats.smartStatus = smart
        }
        #endif

        return stats
    }

    #if !APPSTORE
    private static func readSmartStatus() -> String {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "disk0"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                if line.contains("SMART Status") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count >= 2 {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {}
        return ""
    }

    /// IOKit class names for disk I/O — Apple may change on future storage controllers.
    private static let diskIOServiceNames = [
        "IOBlockStorageDriver",
        "IONVMeBlockStorageDriver",
    ]

    private func readDiskIO(_ stats: inout DiskStats) {
        var iterator: io_iterator_t = 0
        var matched = false
        for serviceName in Self.diskIOServiceNames {
            guard let matching = IOServiceMatching(serviceName) else { continue }
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess {
                matched = true
                break
            }
        }
        guard matched else { return }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let ioStats = dict["Statistics"] as? [String: Any] else {
                continue
            }

            if let read = ioStats["Bytes (Read)"] as? UInt64 {
                totalRead += read
            }
            if let write = ioStats["Bytes (Write)"] as? UInt64 {
                totalWrite += write
            }
        }

        // Expose cumulative totals since boot
        stats.totalBytesRead = totalRead
        stats.totalBytesWritten = totalWrite

        let now = Date()
        if let prev = previousTimestamp {
            let interval = now.timeIntervalSince(prev)
            if interval > 0 {
                stats.readBytesPerSec = totalRead > previousReadBytes
                    ? UInt64(Double(totalRead - previousReadBytes) / interval)
                    : 0
                stats.writeBytesPerSec = totalWrite > previousWriteBytes
                    ? UInt64(Double(totalWrite - previousWriteBytes) / interval)
                    : 0
            }
        }
        previousReadBytes = totalRead
        previousWriteBytes = totalWrite
        previousTimestamp = now
    }
    #endif
}

// MARK: - Disk Speed Benchmark

/// Low-level sequential disk benchmark. Writes then reads a temp file using
/// uncached (`F_NOCACHE`) POSIX I/O so the numbers reflect the storage device
/// rather than the unified buffer cache / RAM.
///
/// Sandbox note: this benchmarks the volume hosting the app container's temp
/// directory (the boot / internal volume under the App Store sandbox). Testing
/// arbitrary external volumes is a future improvement — it would require a
/// user-selected, security-scoped bookmark and is out of scope here.
enum DiskBenchmark {
    /// Selectable workload sizes for the benchmark.
    enum Size: Int, CaseIterable, Identifiable, Sendable {
        case small = 128   // MB
        case medium = 512
        case large = 1024

        var id: Int { rawValue }
        var bytes: Int { rawValue * 1_000_000 }
        var label: String { "\(rawValue) MB" }
    }

    /// Which phase of the benchmark is currently running.
    enum Phase: Sendable, Equatable {
        case idle
        case writing
        case reading
        case randomRead
    }

    /// 16 MB transfer buffer.
    private static let blockSize = 16 * 1_000_000
    /// Number of random 4 KB reads for the IOPS measurement.
    private static let randomReadCount = 2_000
    private static let randomBlockSize = 4_096

    struct CancelledError: Error {}

    /// Runs the full benchmark off the caller's thread is the caller's job;
    /// this function performs blocking POSIX I/O and must not run on the main
    /// thread. `progress` is invoked with the running phase and 0...1 fraction.
    /// `isCancelled` is polled between blocks so the run can be aborted.
    static func run(
        size: Size,
        progress: @Sendable (Phase, Double) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws -> DiskSpeedResult {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("blip-speedtest-\(UUID().uuidString).bin")
        let path = fileURL.path

        // Always clean up the temp file, even on error / cancellation.
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let totalBytes = size.bytes

        // One reusable, page-aligned-ish data buffer filled with non-zero bytes
        // (avoid all-zero pages which some filesystems may compress/sparse).
        var buffer = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize { buffer[i] = UInt8(truncatingIfNeeded: i &* 2654435761) }

        // MARK: Write pass
        let writeFD = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard writeFD >= 0 else { throw posixError() }
        fcntl(writeFD, F_NOCACHE, 1)

        var written = 0
        let writeStart = Date()
        while written < totalBytes {
            if isCancelled() { close(writeFD); throw CancelledError() }
            let chunk = min(blockSize, totalBytes - written)
            let n = buffer.withUnsafeBytes { ptr -> Int in
                write(writeFD, ptr.baseAddress, chunk)
            }
            guard n == chunk else { close(writeFD); throw posixError() }
            written += chunk
            progress(.writing, Double(written) / Double(totalBytes))
        }
        fsync(writeFD)
        close(writeFD)
        let writeElapsed = Date().timeIntervalSince(writeStart)
        let writeMBps = writeElapsed > 0 ? Double(totalBytes) / 1_000_000 / writeElapsed : 0

        if isCancelled() { throw CancelledError() }

        // MARK: Read pass (re-open uncached)
        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { throw posixError() }
        fcntl(readFD, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: blockSize)
        var readTotal = 0
        let readStart = Date()
        while readTotal < totalBytes {
            if isCancelled() { close(readFD); throw CancelledError() }
            let chunk = min(blockSize, totalBytes - readTotal)
            let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                read(readFD, ptr.baseAddress, chunk)
            }
            guard n > 0 else { break }
            readTotal += n
            progress(.reading, Double(readTotal) / Double(totalBytes))
        }
        let readElapsed = Date().timeIntervalSince(readStart)
        let readMBps = readElapsed > 0 ? Double(readTotal) / 1_000_000 / readElapsed : 0

        // MARK: Random read IOPS (optional, reuses the read descriptor)
        var randomReadIOPS: Double? = nil
        if !isCancelled(), totalBytes > randomBlockSize {
            progress(.randomRead, 0)
            var smallBuffer = [UInt8](repeating: 0, count: randomBlockSize)
            let maxOffset = off_t(totalBytes - randomBlockSize)
            var completed = 0
            let randomStart = Date()
            var seed = UInt64(0x9E3779B97F4A7C15)
            for i in 0..<randomReadCount {
                if isCancelled() { break }
                // xorshift for cheap pseudo-random offsets
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let offset = off_t(seed % UInt64(maxOffset))
                lseek(readFD, offset, SEEK_SET)
                let n = smallBuffer.withUnsafeMutableBytes { ptr -> Int in
                    read(readFD, ptr.baseAddress, randomBlockSize)
                }
                if n <= 0 { break }
                completed += 1
                if i % 128 == 0 {
                    progress(.randomRead, Double(i) / Double(randomReadCount))
                }
            }
            let randomElapsed = Date().timeIntervalSince(randomStart)
            if randomElapsed > 0 && completed > 0 {
                randomReadIOPS = Double(completed) / randomElapsed
            }
        }
        close(readFD)

        return DiskSpeedResult(
            writeMBps: writeMBps,
            readMBps: readMBps,
            randomReadIOPS: randomReadIOPS,
            timestamp: Date()
        )
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}

/// Observable driver for the Speed Test UI. Owns the running task, progress,
/// the latest result, a short history, and the optional auto-run timer.
@MainActor
final class DiskSpeedTester: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase: DiskBenchmark.Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastResult: DiskSpeedResult?
    @Published private(set) var history: [DiskSpeedResult] = []
    @Published var size: DiskBenchmark.Size = .medium

    @Published var autoRun = false {
        didSet { autoRun ? startTimer() : stopTimer() }
    }
    /// Auto-run interval in minutes.
    @Published var intervalMinutes = 5 {
        didSet { if autoRun { startTimer() } }
    }

    /// Location label shown in the UI (the volume hosting the container temp dir).
    let locationLabel = "Boot volume"

    private static let maxHistory = 10
    private var task: Task<Void, Never>?
    private var timer: Timer?

    func toggle() {
        isRunning ? cancel() : start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        phase = .writing
        progress = 0
        let size = self.size

        task = Task.detached(priority: .utility) {
            let cancelledFlag: @Sendable () -> Bool = { Task.isCancelled }
            let progressHandler: @Sendable (DiskBenchmark.Phase, Double) -> Void = { phase, frac in
                Task { @MainActor [weak self] in
                    self?.phase = phase
                    self?.progress = frac
                }
            }
            let result = try? DiskBenchmark.run(size: size, progress: progressHandler, isCancelled: cancelledFlag)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let result {
                    self.lastResult = result
                    self.history.append(result)
                    if self.history.count > Self.maxHistory {
                        self.history.removeFirst(self.history.count - Self.maxHistory)
                    }
                }
                self.isRunning = false
                self.phase = .idle
                self.progress = 0
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        phase = .idle
        progress = 0
    }

    private func startTimer() {
        stopTimer()
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            // `Timer` isn't Sendable; invalidate on this (run-loop) thread when
            // the tester is gone, otherwise hop to the main actor to run.
            guard self != nil else { t.invalidate(); return }
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                self.start()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
