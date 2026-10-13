import XCTest
import Combine
@testable import BlipMobile

// MobileDiskBench paths the feature tests don't reach: the internal-storage entry point,
// the one-run-at-a-time guard, and the result's volume naming.

@MainActor
final class MobileDiskBenchRunTests: XCTestCase {
    private func waitForEnd(_ bench: MobileDiskBench) async {
        let reached = expectation(description: "finished")
        reached.assertForOverFulfill = false
        let sub = bench.$phase.sink { phase in
            if case .failed = phase { reached.fulfill() }
            if phase == .done { reached.fulfill() }
        }
        await fulfillment(of: [reached], timeout: 120)
        sub.cancel()
    }

    func testInternalStorageRunMeasuresAndIgnoresAConcurrentStart() async throws {
        let bench = MobileDiskBench()
        XCTAssertFalse(bench.isRunning)
        bench.runInternal()
        XCTAssertTrue(bench.isRunning)
        XCTAssertEqual(bench.phase, .writing)

        // A second request while one is in flight must not reset or restart the first.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        bench.runExternal(at: dir)
        await waitForEnd(bench)

        XCTAssertEqual(bench.phase, .done, "ended in \(bench.phase)")
        let result = try XCTUnwrap(bench.result)
        XCTAssertEqual(result.volumeName, "Internal storage")
        XCTAssertGreaterThan(result.writeMBps, 0)
        XCTAssertGreaterThan(result.readMBps, 0)
        XCTAssertEqual(bench.liveMBps, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [],
                       "the guarded second run never touched its folder")
    }
}
