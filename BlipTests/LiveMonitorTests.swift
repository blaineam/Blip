import XCTest
import Darwin
@testable import Blip

// The hardware readers (mach, sysctl, IOKit, getifaddrs, proc_*) can't be faked without
// re-implementing them, so these run the real readers against the host and assert the
// invariants any Mac must satisfy: sums that must add up, percentages inside 0...100,
// orderings the UI relies on. Values differ per machine; the relationships never do.
// The same file runs in the App Store variant, where the privileged readers are stubbed,
// so those assertions are build-conditional.

final class LiveMonitorTests: XCTestCase {

    // MARK: Memory

    func testMemoryReadAddsUpLikeActivityMonitor() {
        let m = MemoryMonitor().read()
        XCTAssertEqual(m.total, Foundation.ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(m.used, 0)
        XCTAssertLessThanOrEqual(m.used, m.total)
        XCTAssertEqual(m.used, m.appMemory + m.wired + m.compressed, "Used = App + Wired + Compressed")
        XCTAssertEqual(m.free, m.total - m.used)
        XCTAssertGreaterThan(m.wired, 0)
        XCTAssertTrue([0, 1, 2, 4].contains(m.pressureLevel), "kernel pressure level \(m.pressureLevel)")
        XCTAssertLessThanOrEqual(m.swapUsed, m.swapTotal)
        XCTAssertTrue((0...100).contains(m.usagePercent))
    }

    // MARK: CPU

    func testCPUReadReportsCoresAndDeltaUsage() {
        let monitor = CPUMonitor()
        let first = monitor.read()
        XCTAssertGreaterThan(first.logicalCores, 0)
        XCTAssertEqual(first.coreUsages.count, first.logicalCores)
        XCTAssertGreaterThan(first.physicalCores, 0)
        XCTAssertLessThanOrEqual(first.physicalCores, first.logicalCores)
        XCTAssertGreaterThanOrEqual(first.loadAverage1, 0)
        XCTAssertGreaterThanOrEqual(first.loadAverage5, 0)
        XCTAssertGreaterThanOrEqual(first.loadAverage15, 0)

        // Burn a few cycles so the second sample has something to measure.
        var x = 0.0
        for i in 0..<2_000_000 { x += Double(i).squareRoot() }
        XCTAssertGreaterThan(x, 0)

        let second = monitor.read()
        XCTAssertEqual(second.logicalCores, first.logicalCores)
        for usage in second.coreUsages { XCTAssertTrue((0...100).contains(usage), "core usage \(usage)") }
        XCTAssertGreaterThanOrEqual(second.userUsage, 0)
        XCTAssertGreaterThanOrEqual(second.systemUsage, 0)
        XCTAssertEqual(second.totalUsage, second.userUsage + second.systemUsage, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(second.totalUsage, 100.0001)
        // Apple Silicon splits cores into performance + efficiency; Intel reports none.
        XCTAssertLessThanOrEqual(second.performanceCores + second.efficiencyCores, second.physicalCores)
    }

    // MARK: GPU

    func testGPUReadHasANameAndASaneUtilization() {
        let gpu = GPUMonitor().read()
        XCTAssertFalse(gpu.name.isEmpty)
        XCTAssertGreaterThanOrEqual(gpu.coreCount, 0)
        XCTAssertTrue((0...100).contains(gpu.utilization), "utilization \(gpu.utilization)")
    }

    // MARK: Battery

    func testBatteryReadIsInternallyConsistent() async {
        let b = await BatteryMonitor().read()
        guard b.isPresent else {
            // Desktop Mac: defaults stay untouched.
            XCTAssertEqual(b.level, 0)
            XCTAssertFalse(b.isCharging)
            return
        }
        XCTAssertTrue((0...100).contains(b.level))
        XCTAssertTrue(["AC Power", "Battery"].contains(b.powerSource))
        XCTAssertTrue((0...100).contains(b.health))
        XCTAssertFalse(b.condition.isEmpty)
    }

    // MARK: Fans

    func testFanReadReportsOnlyPlausibleValues() async {
        let f = await FanMonitor().read()
        for (index, fan) in f.fans.enumerated() {
            XCTAssertEqual(fan.id, index)
            XCTAssertTrue((0...10_000).contains(fan.currentRPM))
            XCTAssertTrue((0...10_000).contains(fan.minRPM))
            XCTAssertTrue((0...10_000).contains(fan.maxRPM))
            XCTAssertFalse(fan.name.isEmpty)
        }
        if let cpu = f.cpuTemperature { XCTAssertTrue((-20...150).contains(cpu), "cpu \(cpu)") }
        if let gpu = f.gpuTemperature { XCTAssertTrue((-20...150).contains(gpu), "gpu \(gpu)") }
        #if APPSTORE
        XCTAssertTrue(f.fans.isEmpty, "the sandboxed build reads no SMC data")
        XCTAssertNil(f.cpuTemperature)
        #endif
    }

    // MARK: Processes

    func testProcessReadReturnsSortedTopFivesWithoutBlipItself() async {
        let monitor = ProcessMonitor()
        _ = await monitor.read()                     // seed the CPU-delta baseline
        let (byCPU, byMemory) = await monitor.read()
        XCTAssertLessThanOrEqual(byCPU.count, 5)
        XCTAssertLessThanOrEqual(byMemory.count, 5)
        XCTAssertEqual(byCPU.map(\.cpu), byCPU.map(\.cpu).sorted(by: >))
        XCTAssertEqual(byMemory.map(\.memory), byMemory.map(\.memory).sorted(by: >))
        for p in byCPU + byMemory {
            XCTAssertNotEqual(p.id, getpid(), "Blip never lists itself")
            XCTAssertFalse(p.name.isEmpty)
            XCTAssertGreaterThanOrEqual(p.cpu, 0)
        }
        #if APPSTORE
        XCTAssertTrue(byCPU.isEmpty && byMemory.isEmpty, "process enumeration is the helper's job in the store build")
        #else
        XCTAssertFalse(byMemory.isEmpty)
        XCTAssertTrue(byMemory.contains { $0.isUserOwned }, "a user session always owns processes")
        #endif
    }

    // MARK: Disk

    func testVolumesListRootFirstThenAlphabeticalWithConsistentSizes() {
        let volumes = DiskMonitor.readVolumes()
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertEqual(volumes.first?.mountPoint, "/")
        for v in volumes {
            XCTAssertGreaterThan(v.totalBytes, 0)
            XCTAssertLessThanOrEqual(v.freeBytes, v.totalBytes, v.mountPoint)
            XCTAssertFalse(v.name.isEmpty)
            XCTAssertTrue((0...100).contains(v.usagePercent))
        }
        let rest = volumes.dropFirst().map(\.name)
        XCTAssertEqual(rest, rest.sorted(), "non-root volumes sort by name")
    }

    func testDiskReadCachesDriveHealthAndComputesRatesOnTheSecondRead() {
        let monitor = DiskMonitor()
        let first = monitor.read()
        XCTAssertFalse(first.volumes.isEmpty)
        let second = monitor.read()
        XCTAssertEqual(second.volumes.map(\.mountPoint), first.volumes.map(\.mountPoint))
        #if !APPSTORE
        XCTAssertGreaterThanOrEqual(second.totalBytesRead, first.totalBytesRead, "cumulative counters never go back")
        XCTAssertGreaterThanOrEqual(second.totalBytesWritten, first.totalBytesWritten)
        XCTAssertEqual(second.smartStatus, first.smartStatus, "SMART status is read once and cached")
        XCTAssertEqual(second.drives.map(\.id), first.drives.map(\.id))
        for d in second.drives {
            XCTAssertFalse(d.name.isEmpty)
            XCTAssertTrue(["Verified", "Failing"].contains(d.smartStatus), d.smartStatus)
            XCTAssertEqual(d.isHealthy, d.criticalWarning == 0)
        }
        #endif
    }

    #if !APPSTORE
    func testDriveHealthEnumerationIsStable() {
        let a = DiskMonitor.readDriveHealth().map(\.bsdName)
        let b = DiskMonitor.readDriveHealth().map(\.bsdName)
        XCTAssertEqual(a, b)
    }
    #endif

    // MARK: Network

    func testNetworkReadIsCoherentAcrossPolls() {
        let monitor = NetworkMonitor()
        monitor.pingTarget = "127.0.0.1"             // never leave the host
        let first = monitor.read()
        let second = monitor.read()

        func isIPv4(_ s: String) -> Bool { var a = in_addr(); return inet_pton(AF_INET, s, &a) == 1 }
        for s in [first, second] {
            XCTAssertTrue(s.routerIP == "—" || isIPv4(s.routerIP), s.routerIP)
            XCTAssertTrue(s.lanAddress == "—" || isIPv4(s.lanAddress), s.lanAddress)
            for i in s.interfaces {
                XCTAssertTrue(i.id.hasPrefix("en"))
                XCTAssertTrue(i.isActive)
                XCTAssertFalse(i.name.isEmpty)
            }
            if s.lanAddress != "—" {
                let match = s.interfaces.first { $0.id == s.interfaceName }
                XCTAssertEqual(match?.ipv4, s.lanAddress)
            }
            XCTAssertEqual(s.isVPNActive, s.vpnAddress != "—")
        }
        XCTAssertEqual(first.interfaces.map(\.id), second.interfaces.map(\.id))
        XCTAssertEqual(first.interfaces.map(\.id), first.interfaces.map(\.id).sorted())
        // The since-boot totals never go backwards between polls.
        #if !APPSTORE
        XCTAssertGreaterThanOrEqual(second.totalBytesDownloaded, first.totalBytesDownloaded)
        #endif
        XCTAssertGreaterThanOrEqual(second.totalBytesUploaded, 0)
    }
}
