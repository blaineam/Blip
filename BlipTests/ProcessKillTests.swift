import XCTest
@testable import Blip

// "Kill" from the process list, against a real child process: the direct build signals it
// itself; the App Store build routes the same ProcessSignaller through Blip Helper.

final class ProcessKillTests: XCTestCase {

    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testSIGTERMEndsAChildProcess() throws {
        let child = try spawnSleeper()
        let result = ProcessSignaller.terminate(child.processIdentifier, force: false)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "Terminated")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    func testForceKillSendsSIGKILL() throws {
        let child = try spawnSleeper()
        let result = ProcessSignaller.terminate(child.processIdentifier, force: true)
        XCTAssertEqual(result.message, "Force killed")
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, SIGKILL)
    }

    func testKillingAReapedProcessReportsItIsGone() throws {
        let child = try spawnSleeper()
        let pid = child.processIdentifier
        child.terminate()
        child.waitUntilExit()   // reaped: the PID no longer exists
        let result = ProcessSignaller.terminate(pid, force: false)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Process no longer running")
    }

    func testKillingLaunchdIsRefusedWithoutSignalling() {
        let result = ProcessSignaller.terminate(1, force: true)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Invalid PID")
    }

    #if !APPSTORE
    /// The direct build's SystemMonitor signals processes itself.
    @MainActor
    func testSystemMonitorKillsDirectlyInTheDirectBuild() async throws {
        let child = try spawnSleeper()
        let monitor = SystemMonitor(defaults: Fixtures.scratchDefaults("kill"))
        let result = await monitor.killProcess(pid: child.processIdentifier, force: false)
        XCTAssertTrue(result.ok)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }

    /// pid 0 is in `ps` output (kernel_task); kill(0, …) would signal Blip's own process
    /// group, so it must be refused rather than "succeed".
    @MainActor
    func testSystemMonitorRefusesProcessGroupPIDs() async {
        let monitor = SystemMonitor(defaults: Fixtures.scratchDefaults("kill"))
        let zero = await monitor.killProcess(pid: 0, force: false)
        XCTAssertFalse(zero.ok)
        XCTAssertEqual(zero.message, "Invalid PID")
    }
    #endif
}
