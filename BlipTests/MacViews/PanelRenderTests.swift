import XCTest
import SwiftUI
@testable import Blip

/// Renders the detail panels and shared components with fixture stats so their view bodies,
/// branches and formatters run under the unit gate (previously only the UI suites reached them).
/// Assertions are structural (layout produced, content-dependent heights), never pixel based.
@MainActor
final class PanelRenderTests: XCTestCase {

    static func icon() -> Data {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        return img.tiffRepresentation ?? Data()
    }

    func procs() -> [Blip.ProcessInfo] {
        [
            Blip.ProcessInfo(id: 101, name: "Xcode", cpu: 88.5, memory: 4_000_000_000, icon: nil),
            Blip.ProcessInfo(id: 102, name: "Safari", cpu: 12.25, memory: 900_000_000, icon: Self.icon()),
            Blip.ProcessInfo(id: 1, name: "launchd", cpu: 0.5, memory: 10_000_000, icon: nil, isUserOwned: false),
        ]
    }
    var history: [Double] { (0..<60).map { Double($0 % 17) * 5 } }

    func testCPUPanelGrowsWithItsProcessList() {
        var s = Fixtures.snapshot().cpu
        s.coreUsages = [10, 50, 90, 20]; s.logicalCores = 4; s.physicalCores = 4
        s.performanceCores = 2; s.efficiencyCores = 2
        let full = ViewHost.smoke(CPUDetailPanel(stats: s, history: history, topProcesses: procs()))
        let bare = ViewHost.smoke(CPUDetailPanel(stats: s, history: history, topProcesses: []))
        XCTAssertGreaterThan(full.height, bare.height, "process rows add height")
        ViewHost.smoke(CPUDetailPanel(stats: CPUStats(), history: [], topProcesses: []))
    }

    func testCPUPanelWithKillHandlerAndArmedProcess() {
        var armed: pid_t? = 101
        let binding = Binding<pid_t?>(get: { armed }, set: { armed = $0 })
        ViewHost.smoke(CPUDetailPanel(stats: Fixtures.snapshot().cpu, history: history, topProcesses: procs(),
                                      onKill: { _, _ in (true, "") }, onProcessHover: { _ in }, armedPID: binding))
        ViewHost.smoke(MemoryDetailPanel(stats: Fixtures.snapshot().memory, history: history, topProcesses: procs(),
                                         onKill: { _, _ in (false, "denied") }, onProcessHover: { _ in }, armedPID: binding))
    }

    func testMemoryPanelRendersAllPressureLevels() {
        for level in [0, 1, 2, 4] {
            var m = Fixtures.snapshot().memory
            m.pressureLevel = level; m.swapTotal = 4_000_000_000; m.wired = 3_000_000_000
            m.compressed = 1_000_000_000; m.appMemory = 10_000_000_000; m.cachedFiles = 2_000_000_000
            ViewHost.smoke(MemoryDetailPanel(stats: m, history: history, topProcesses: procs()))
        }
        ViewHost.smoke(MemoryDetailPanel(stats: MemoryStats(), history: [], topProcesses: []))
    }

    func testGPUBatteryThermalPanelsRender() {
        let snap = Fixtures.snapshot()
        ViewHost.smoke(GPUDetailPanel(stats: snap.gpu, history: history))
        ViewHost.smoke(GPUDetailPanel(stats: GPUStats(), history: []))
        var b = snap.battery
        ViewHost.smoke(BatteryDetailPanel(stats: b))
        b.isCharging = true; b.timeRemaining = -1; b.condition = "Service Recommended"; b.health = 70
        ViewHost.smoke(BatteryDetailPanel(stats: b))
        b.level = 5; b.powerSource = "AC Power"
        ViewHost.smoke(BatteryDetailPanel(stats: b))
        for level in [ThermalLevel.nominal, .fair, .serious, .critical] {
            ViewHost.smoke(ThermalDetailPanel(thermalLevel: level, fanStats: snap.fans))
        }
        var hot = snap.fans
        hot.cpuTemperature = 99; hot.gpuTemperature = 95
        ViewHost.smoke(ThermalDetailPanel(thermalLevel: .critical, fanStats: hot))
        ViewHost.smoke(ThermalDetailPanel(thermalLevel: .nominal, fanStats: FanStats()))
    }

    // MARK: Components

    func testChartsAndBarsRenderEdgeInputs() {
        ViewHost.smoke(MiniChart(data: history, color: .green))
        ViewHost.smoke(MiniChart(data: [], height: 12))
        ViewHost.smoke(MiniChart(data: [5]))
        ViewHost.smoke(MiniChart(data: [Double](repeating: 0, count: 10)))
        ViewHost.smoke(DetailChart(data: history, color: .blue, label: "CPU"))
        ViewHost.smoke(DetailChart(data: [], color: .blue, label: "CPU"))
        for v in [-5.0, 0, 30, 70, 95, 100, 250] {
            ViewHost.smoke(UsageBar(value: v))
            ViewHost.smoke(UsageBar(value: v, color: .red, width: 80))
        }
        ViewHost.smoke(OverviewRow(icon: "cpu", label: "CPU", value: "42%", percent: 42, color: .blue, id: "cpu"))
        ViewHost.smoke(OverviewRow(icon: "cpu", label: "CPU", value: "—", percent: 0, color: .blue))
        ViewHost.smoke(RowChevron())
        ViewHost.smoke(RowChevron().environment(\.rowExpanded, true))
    }

    func testProcessRowModesConfirmAndPlainStates() {
        let p = procs()
        for mode in [ProcessRow.Mode.cpu, .memory] {
            for proc in p { ViewHost.smoke(ProcessRow(process: proc, mode: mode)) }
        }
        var armed: pid_t? = nil
        let binding = Binding<pid_t?>(get: { armed }, set: { armed = $0 })
        ViewHost.smoke(ProcessRow(process: p[0], mode: .cpu, onKill: { _, _ in (true, "") }, armedPID: binding))
        armed = 101
        ViewHost.smoke(ProcessRow(process: p[0], mode: .cpu, onKill: { _, _ in (true, "") }, armedPID: binding))
    }

    func testPanelChromeShowsPinStates() {
        let a = ViewHost.smoke(DetailPanelChrome(pinned: false, section: "cpu", onTogglePin: {}) { Text("body") })
        let b = ViewHost.smoke(DetailPanelChrome(pinned: true, section: "cpu", onTogglePin: {}) { Text("body") })
        XCTAssertGreaterThan(a.height, 0); XCTAssertGreaterThan(b.height, 0)
    }

    func testColorHexRoundTrip() {
        let c = Color(hex: "#3A7BD5")
        XCTAssertEqual(c?.hexString, "3A7BD5")
        XCTAssertNotNil(Color(hex: "FFFFFF"))
        XCTAssertNil(Color(hex: "xyz"))
        XCTAssertNil(Color(hex: "12345"))
        XCTAssertNil(Color(hex: "GGGGGG"))
    }
}
