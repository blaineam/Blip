import XCTest
@testable import Blip

// SystemMonitor is the coordinator: it polls every monitor, folds in the helper's data when
// the in-process readers came back empty (sandboxed build), and publishes snapshot + history.

@MainActor
final class SystemMonitorTests: XCTestCase {

    private var scratch: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "blip-sysmon-\(UUID().uuidString)"
        scratch = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        scratch.removePersistentDomain(forName: suiteName)
    }

    // MARK: A real poll

    func testStartPublishesAFullSnapshotAndHistory() async {
        // pingTarget is an @AppStorage on the standard defaults; keep the poll on loopback and put it back.
        let key = "pingTarget"
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("127.0.0.1", forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let monitor = SystemMonitor(defaults: scratch)
        XCTAssertFalse(monitor.hasSampled)
        var thermalSamples = 0
        monitor.onThermalSample = { _, _ in thermalSamples += 1 }
        monitor.start()
        monitor.start()                              // a second start is a no-op
        for _ in 0..<40 where !monitor.hasSampled { await monitor.ensureFreshSample() }
        monitor.stop()

        XCTAssertTrue(monitor.hasSampled)
        let s = monitor.snapshot
        XCTAssertGreaterThan(s.cpu.logicalCores, 0)
        XCTAssertGreaterThan(s.memory.total, 0)
        XCTAssertFalse(s.disk.volumes.isEmpty, "the first poll also reads the disk")
        XCTAssertTrue(s.system.macOSVersion.hasPrefix("macOS "), s.system.macOSVersion)
        XCTAssertFalse(s.system.macModel.isEmpty)
        XCTAssertGreaterThan(s.system.uptime, 0)
        XCTAssertGreaterThan(s.system.blipMemoryMB, 0)
        XCTAssertGreaterThanOrEqual(thermalSamples, 1)
        XCTAssertGreaterThanOrEqual(monitor.cpuHistory.values.count, 1)
        XCTAssertEqual(monitor.memoryHistory.values.last ?? -1, s.memory.usagePercent, accuracy: 0.0001)
        // Already sampled: ensureFreshSample returns immediately.
        await monitor.ensureFreshSample()
    }

    func testKillRefusesPidsThatWouldSignalTheWholeSession() async {
        let monitor = SystemMonitor(defaults: scratch)
        for pid: pid_t in [0, 1, -1] {
            let r = await monitor.killProcess(pid: pid, force: true)
            XCTAssertFalse(r.ok, "pid \(pid)")
        }
    }

    #if !APPSTORE
    func testLocalTracerouteSessionStartsAndStopsAndRefusesBadHosts() async {
        let monitor = SystemMonitor(defaults: scratch)
        await monitor.startTraceroute(host: "-oProxyCommand=evil")
        var state = await monitor.tracerouteHops()
        XCTAssertFalse(state.running, "an option-looking host is never run")
        XCTAssertTrue(state.hops.isEmpty)

        await monitor.startTraceroute(host: "127.0.0.1")
        state = await monitor.tracerouteHops()
        XCTAssertTrue(state.running)
        await monitor.startTraceroute(host: "127.0.0.1")   // same host while running: untouched
        await monitor.stopTraceroute()
        state = await monitor.tracerouteHops()
        XCTAssertFalse(state.running)
    }

    func testLocalTraceRunnerHostRules() {
        XCTAssertTrue(LocalTraceRunner.isValidHost("example.com"))
        XCTAssertTrue(LocalTraceRunner.isValidHost("2001:db8::1"))
        XCTAssertFalse(LocalTraceRunner.isValidHost("a b"))
        XCTAssertFalse(LocalTraceRunner.isValidHost(""))
        XCTAssertFalse(LocalTraceRunner.isValidHost("-n"))
        XCTAssertFalse(LocalTraceRunner.isValidHost("a;rm"))
    }
    #endif

    // MARK: Helper merge (the sandboxed build's data path)

    private func helperSnapshot() -> HelperSnapshot {
        HelperSnapshot(
            fans: [HelperFan(id: 0, name: "Left", currentRPM: 1800, minRPM: 1200, maxRPM: 5800)],
            cpuTemperature: 61, gpuTemperature: 55, gpuUtilization: 42,
            diskReadBytesPerSec: 111, diskWriteBytesPerSec: 222,
            diskTotalBytesRead: 1_000, diskTotalBytesWritten: 2_000, smartStatus: "Verified",
            drives: [HelperDriveHealth(name: "APPLE SSD", bsdName: "disk0", isInternal: true, medium: "NVMe",
                                       smartStatus: "Verified", percentageUsed: 3, availableSpare: 100,
                                       availableSpareThreshold: 10, temperatureCelsius: 35,
                                       dataUnitsWritten: 10, dataUnitsRead: 20, powerOnHours: 99,
                                       powerCycles: 7, unsafeShutdowns: 1, mediaErrors: 0, criticalWarning: 0)],
            networkTotalDownloaded: 9_000, networkTotalUploaded: 8_000,
            batteryHealth: 91, batteryCycleCount: 212, batteryCondition: "Normal", batteryTemperature: 29.5,
            topProcessesByCPU: [HelperProcess(pid: 10, name: "Xcode", cpu: 80, memory: 5_000, icon: nil)],
            topProcessesByMemory: [HelperProcess(pid: 11, name: "Safari", cpu: 5, memory: 9_000, icon: nil)],
            macModelName: "MacBook Pro", helperVersion: "2.0.7", timestamp: Date())
    }

    private struct Parts {
        var fans = FanStats()
        var gpu = GPUStats()
        var disk = DiskStats()
        var network = NetworkStats()
        var battery = BatteryStats()
        var cpuProcs: [Blip.ProcessInfo] = []
        var memProcs: [Blip.ProcessInfo] = []
    }

    private func merge(_ h: HelperSnapshot, into p: inout Parts) {
        SystemMonitor.mergeHelper(h, fans: &p.fans, gpu: &p.gpu, disk: &p.disk, network: &p.network,
                                  battery: &p.battery, topByCPU: &p.cpuProcs, topByMemory: &p.memProcs)
    }

    func testMergeFillsEveryGapTheSandboxLeft() {
        var p = Parts()
        p.battery.health = 0; p.battery.condition = ""      // what a sandboxed BatteryMonitor leaves
        merge(helperSnapshot(), into: &p)

        XCTAssertEqual(p.fans.fans.map(\.currentRPM), [1800])
        XCTAssertEqual(p.fans.fans.first?.name, "Left")
        XCTAssertEqual(p.fans.cpuTemperature, 61)
        XCTAssertEqual(p.fans.gpuTemperature, 55)
        XCTAssertEqual(p.gpu.utilization, 42)
        XCTAssertEqual(p.disk.readBytesPerSec, 111)
        XCTAssertEqual(p.disk.writeBytesPerSec, 222)
        XCTAssertEqual(p.disk.totalBytesRead, 1_000)
        XCTAssertEqual(p.disk.totalBytesWritten, 2_000)
        XCTAssertEqual(p.disk.smartStatus, "Verified")
        XCTAssertEqual(p.network.totalBytesDownloaded, 9_000)
        XCTAssertEqual(p.network.totalBytesUploaded, 8_000)
        XCTAssertEqual(p.disk.drives.count, 1)
        XCTAssertEqual(p.disk.drives.first?.bsdName, "disk0")
        XCTAssertEqual(p.disk.drives.first?.bytesWritten, 5_120_000, "10 NVMe units x 512,000 bytes")
        XCTAssertEqual(p.disk.drives.first?.lifeRemaining, 97)
        XCTAssertEqual(p.battery.health, 91)
        XCTAssertEqual(p.battery.cycleCount, 212)
        XCTAssertEqual(p.battery.condition, "Normal")
        XCTAssertEqual(p.battery.temperature, 29.5)
        XCTAssertEqual(p.cpuProcs.map(\.name), ["Xcode"])
        XCTAssertEqual(p.memProcs.map(\.id), [11])
    }

    func testMergeNeverOverwritesWhatTheAppAlreadyRead() {
        var p = Parts()
        p.fans.fans = [FanInfo(id: 0, name: "Fan 1", currentRPM: 999, minRPM: 1, maxRPM: 2)]
        p.fans.cpuTemperature = 40; p.fans.gpuTemperature = 41
        p.gpu.utilization = 7
        p.disk.readBytesPerSec = 5
        p.disk.smartStatus = "Local"
        p.network.totalBytesDownloaded = 1
        p.disk.drives = [DriveHealth(name: "Own", bsdName: "diskX", isInternal: true, medium: "NVMe", smartStatus: "Verified",
                                     percentageUsed: nil, availableSpare: nil, availableSpareThreshold: nil,
                                     temperatureCelsius: nil, bytesWritten: nil, bytesRead: nil, powerOnHours: nil,
                                     powerCycles: nil, unsafeShutdowns: nil, mediaErrors: nil, criticalWarning: nil)]
        p.battery.health = 80; p.battery.cycleCount = 5; p.battery.condition = "Service"; p.battery.temperature = 20
        p.cpuProcs = [Blip.ProcessInfo(id: 1, name: "own", cpu: 1, memory: 1, icon: nil)]
        p.memProcs = [Blip.ProcessInfo(id: 2, name: "own2", cpu: 1, memory: 1, icon: nil)]

        var h = helperSnapshot()
        h.networkTotalDownloaded = 0          // zero totals are ignored too
        merge(h, into: &p)

        XCTAssertEqual(p.fans.fans.first?.currentRPM, 999)
        XCTAssertEqual(p.fans.cpuTemperature, 40)
        XCTAssertEqual(p.fans.gpuTemperature, 41)
        XCTAssertEqual(p.gpu.utilization, 7)
        XCTAssertEqual(p.disk.readBytesPerSec, 5)
        XCTAssertEqual(p.disk.writeBytesPerSec, 0, "disk I/O is taken as a unit or not at all")
        XCTAssertEqual(p.disk.smartStatus, "Local")
        XCTAssertEqual(p.network.totalBytesDownloaded, 1)
        XCTAssertEqual(p.network.totalBytesUploaded, 8_000)
        XCTAssertEqual(p.disk.drives.map(\.bsdName), ["diskX"])
        XCTAssertEqual(p.battery.health, 80)
        XCTAssertEqual(p.battery.cycleCount, 5)
        XCTAssertEqual(p.battery.condition, "Service")
        XCTAssertEqual(p.battery.temperature, 20)
        XCTAssertEqual(p.cpuProcs.map(\.name), ["own"])
        XCTAssertEqual(p.memProcs.map(\.name), ["own2"])
    }

    func testMergeWithAnEmptyHelperSnapshotChangesNothing() {
        var h = helperSnapshot()
        h.fans = []; h.drives = nil; h.gpuUtilization = 0; h.smartStatus = ""
        h.topProcessesByCPU = []; h.topProcessesByMemory = []
        h.networkTotalDownloaded = nil; h.networkTotalUploaded = nil
        h.batteryHealth = nil; h.batteryCycleCount = nil; h.batteryCondition = nil; h.batteryTemperature = nil
        var p = Parts()
        p.battery.health = 0; p.battery.condition = ""
        merge(h, into: &p)
        XCTAssertTrue(p.fans.fans.isEmpty)
        XCTAssertEqual(p.gpu.utilization, 0)
        XCTAssertTrue(p.disk.drives.isEmpty)
        XCTAssertEqual(p.disk.smartStatus, "")
        XCTAssertEqual(p.network.totalBytesDownloaded, 0)
        XCTAssertEqual(p.battery.health, 0)
        XCTAssertEqual(p.battery.condition, "")
        XCTAssertTrue(p.cpuProcs.isEmpty && p.memProcs.isEmpty)
    }
}
