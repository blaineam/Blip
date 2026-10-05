import XCTest
@testable import Blip

// The real disk speed test engine (uncached POSIX write → read → random 4K reads), run
// against a per-test scratch directory at the smallest size (128 MB). Verifies it measures
// something, reports its phases, and never leaves its temp file behind — on success, on
// cancellation, or on error.

final class DiskBenchmarkEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-diskbench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
    }

    /// Thread-safe recorder for the engine's @Sendable callbacks.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _phases: [DiskBenchmark.Phase] = []
        private var _maxWrite = 0.0
        private var _maxRead = 0.0
        var cancelOnPhase: DiskBenchmark.Phase?
        private var _cancelled = false

        var phases: [DiskBenchmark.Phase] { lock.withLock { _phases } }
        var maxWriteFraction: Double { lock.withLock { _maxWrite } }
        var maxReadFraction: Double { lock.withLock { _maxRead } }
        var cancelled: Bool { lock.withLock { _cancelled } }

        func record(_ phase: DiskBenchmark.Phase, _ fraction: Double) {
            lock.withLock {
                if _phases.last != phase { _phases.append(phase) }
                if phase == .writing { _maxWrite = max(_maxWrite, fraction) }
                if phase == .reading { _maxRead = max(_maxRead, fraction) }
                if phase == cancelOnPhase { _cancelled = true }
            }
        }
    }

    func testRunMeasuresWriteReadAndIOPSAndCleansUp() throws {
        let rec = Recorder()
        let result = try DiskBenchmark.run(size: .small, directory: dir,
                                           progress: { rec.record($0, $1) },
                                           isCancelled: { false })
        XCTAssertGreaterThan(result.writeMBps, 0)
        XCTAssertGreaterThan(result.readMBps, 0)
        XCTAssertGreaterThan(try XCTUnwrap(result.randomReadIOPS), 0)
        XCTAssertEqual(rec.phases, [.writing, .reading, .randomRead], "phases run in order")
        XCTAssertEqual(rec.maxWriteFraction, 1, accuracy: 1e-9, "the full 128 MB is written")
        XCTAssertEqual(rec.maxReadFraction, 1, accuracy: 1e-9, "and read back")
        XCTAssertEqual(try leftovers(), [], "temp file removed after a successful run")
    }

    func testCancellationDuringWriteThrowsAndCleansUp() throws {
        let rec = Recorder()
        rec.cancelOnPhase = .writing
        XCTAssertThrowsError(try DiskBenchmark.run(size: .small, directory: dir,
                                                   progress: { rec.record($0, $1) },
                                                   isCancelled: { rec.cancelled })) { error in
            XCTAssertTrue(error is DiskBenchmark.CancelledError)
        }
        XCTAssertFalse(rec.phases.contains(.reading), "nothing runs after a cancel")
        XCTAssertLessThan(rec.maxWriteFraction, 1, "stopped before writing everything")
        XCTAssertEqual(try leftovers(), [], "temp file removed after cancellation")
    }

    func testCancellationDuringReadThrowsAndCleansUp() throws {
        let rec = Recorder()
        rec.cancelOnPhase = .reading
        XCTAssertThrowsError(try DiskBenchmark.run(size: .small, directory: dir,
                                                   progress: { rec.record($0, $1) },
                                                   isCancelled: { rec.cancelled })) { error in
            XCTAssertTrue(error is DiskBenchmark.CancelledError)
        }
        XCTAssertEqual(try leftovers(), [])
    }

    func testMissingDirectoryIsAPOSIXError() {
        let missing = dir.appendingPathComponent("no/such/dir")
        XCTAssertThrowsError(try DiskBenchmark.run(size: .small, directory: missing,
                                                   progress: { _, _ in }, isCancelled: { false })) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testReadOnlyDirectoryIsAPermissionErrorAndLeavesNothing() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try DiskBenchmark.run(size: .small, directory: dir,
                                                   progress: { _, _ in }, isCancelled: { false })) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(EACCES))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try leftovers(), [])
    }

    func testSizeMetadata() {
        XCTAssertEqual(DiskBenchmark.Size.small.bytes, 128_000_000)
        XCTAssertEqual(DiskBenchmark.Size.large.label, "1024 MB")
        XCTAssertEqual(DiskBenchmark.Size.allCases.map(\.rawValue), [128, 512, 1024])
    }

    // MARK: DiskSpeedTester bookkeeping

    @MainActor
    func testAutoRunHealthGuardSkipsWornDrivesOnly() {
        let tester = DiskSpeedTester()
        XCTAssertTrue(tester.autoRunAllowedNow, "unknown health never blocks")
        tester.targetHealthRemaining = 30
        XCTAssertTrue(tester.autoRunAllowedNow)
        tester.targetHealthRemaining = 29
        XCTAssertFalse(tester.autoRunAllowedNow, "below 30% life, interval runs are skipped")
    }
}
