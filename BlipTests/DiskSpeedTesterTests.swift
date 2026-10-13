import XCTest
@testable import Blip

// DiskSpeedTester is the observable driver behind the Disk panel's speed test: result history,
// the chosen drive (a bookmark in the standard defaults), and start/cancel. The benchmark
// engine itself is covered by DiskBenchmarkEngineTests; no test here lets a run finish, so the
// owner's real rating counters and drive choice are left alone (the bookmark is restored).

@MainActor
final class DiskSpeedTesterTests: XCTestCase {
    private let bookmarkKey = "diskSpeedTestBookmark"
    private var savedBookmark: Data?
    private var dir: URL!

    override func setUp() async throws {
        savedBookmark = UserDefaults.standard.data(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-disktester-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let savedBookmark { UserDefaults.standard.set(savedBookmark, forKey: bookmarkKey) }
        else { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func result(_ n: Double) -> DiskSpeedResult {
        DiskSpeedResult(writeMBps: n, readMBps: n * 2, randomReadIOPS: nil, timestamp: Date(timeIntervalSince1970: n))
    }

    func testStartsIdleOnTheBootVolume() {
        let t = DiskSpeedTester()
        XCTAssertFalse(t.isRunning)
        XCTAssertEqual(t.phase, .idle)
        XCTAssertEqual(t.progress, 0)
        XCTAssertNil(t.lastResult)
        XCTAssertEqual(t.locationLabel, "Boot volume")
        XCTAssertEqual(t.size, .medium)
        XCTAssertEqual(t.completedBenchmarks, 0)
        XCTAssertNil(t.lastError)
    }

    func testRecordKeepsTheNewestTenAndCountsNoBenchmark() {
        let t = DiskSpeedTester()
        for n in 1...12 { t.record(result(Double(n))) }
        XCTAssertEqual(t.history.count, 10)
        XCTAssertEqual(t.history.first?.writeMBps, 3, "the two oldest fell off")
        XCTAssertEqual(t.history.last?.writeMBps, 12)
        XCTAssertEqual(t.lastResult?.writeMBps, 12)
        XCTAssertEqual(t.completedBenchmarks, 0, "an externally-run result is not one of this tester's runs")
    }

    func testStartMarksTheRunSynchronouslyAndCancelUnwindsIt() {
        let t = DiskSpeedTester()
        t.size = .small
        t.start()
        XCTAssertTrue(t.isRunning, "callers checking right after start() must see it running")
        XCTAssertEqual(t.phase, .writing)
        t.start()                                       // already running: ignored
        t.cancel()
        XCTAssertFalse(t.isRunning)
        XCTAssertEqual(t.phase, .idle)
        XCTAssertEqual(t.progress, 0)
        XCTAssertNil(t.lastResult, "a cancelled run publishes nothing")
    }

    func testToggleStartsThenCancels() {
        let t = DiskSpeedTester()
        t.size = .small
        t.toggle()
        XCTAssertTrue(t.isRunning)
        t.toggle()
        XCTAssertFalse(t.isRunning)
    }

    #if !APPSTORE
    func testPointingAtAFolderRemembersItAcrossInstances() {
        let t = DiskSpeedTester()
        t.size = .small
        t.runOn(mountPoint: dir.path, label: "Scratch drive")
        XCTAssertEqual(t.locationLabel, "Scratch drive")
        XCTAssertNil(t.lastError)
        XCTAssertTrue(t.isRunning, "choosing a volume starts the test")
        t.cancel()

        let relaunched = DiskSpeedTester()
        XCTAssertEqual(relaunched.locationLabel, dir.lastPathComponent, "the bookmark restores the folder name")

        relaunched.useBootVolume()
        XCTAssertEqual(relaunched.locationLabel, "Boot volume")
        XCTAssertNil(UserDefaults.standard.data(forKey: bookmarkKey))
    }

    func testAMissingFolderReportsWhichDriveCouldNotBeTargeted() {
        let t = DiskSpeedTester()
        t.runOn(mountPoint: dir.appendingPathComponent("gone").path, label: "Ghost")
        XCTAssertEqual(t.lastError, "Couldn't target Ghost")
        XCTAssertFalse(t.isRunning)
        XCTAssertEqual(t.locationLabel, "Boot volume")
    }

    func testRunOnIsIgnoredWhileARunIsInFlight() {
        let t = DiskSpeedTester()
        t.size = .small
        t.start()
        t.runOn(mountPoint: dir.path, label: "Other")
        XCTAssertEqual(t.locationLabel, "Boot volume")
        t.cancel()
    }
    #endif

    func testResumeAutoRunArmsTheScheduleWithoutRunningImmediately() {
        let t = DiskSpeedTester()
        t.resumeAutoRun(every: 0)                       // clamped to a minute
        XCTAssertEqual(t.intervalMinutes, 1)
        XCTAssertTrue(t.autoRun)
        XCTAssertFalse(t.isRunning, "relaunch never benchmarks the disk on its own")
        t.resumeAutoRun(every: 30)                      // already armed: only the interval changes
        XCTAssertEqual(t.intervalMinutes, 30)
        t.autoRun = false
        XCTAssertFalse(t.autoRun)
    }

    func testAutoRunDoesNotStartOnAWornDrive() {
        let t = DiskSpeedTester()
        t.targetHealthRemaining = 20
        t.autoRun = true
        XCTAssertFalse(t.isRunning)
        t.autoRun = false
    }
}
