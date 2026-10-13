import XCTest
import SwiftUI
@testable import Blip

@MainActor
final class KeepAwakeViewRenderTests: XCTestCase {
    private func make() -> KeepAwake {
        let k = KeepAwake()
        k.defaults = Fixtures.scratchDefaults("kav-\(UUID().uuidString)")
        k.assertions = MockPowerAssertions()
        k.extrasBackend = MockExtras()
        return k
    }

    func testOverviewRowOffAndOnWithTimer() {
        let k = make()
        ViewHost.smoke(KeepAwakeOverviewRow(keepAwake: k))
        k.start(.indefinitely)
        ViewHost.smoke(KeepAwakeOverviewRow(keepAwake: k))
        k.stop()
        k.start(.oneHour)
        ViewHost.smoke(KeepAwakeOverviewRow(keepAwake: k))
        k.stop()
    }

    func testDetailPanelAndSettingsSectionVariants() {
        let k = make()
        for avail in [true, false] {
            for outdated in [true, false] {
                ViewHost.smoke(KeepAwakeDetailPanel(keepAwake: k, extrasAvailable: avail, helperNeedsUpdate: outdated))
                ViewHost.smoke(KeepAwakeSettingsSection(keepAwake: k, extrasAvailable: avail, helperNeedsUpdate: outdated))
            }
        }
        k.start(.thirtyMinutes)
        let active = ViewHost.smoke(KeepAwakeDetailPanel(keepAwake: k, extrasAvailable: true))
        k.stop()
        let idle = ViewHost.smoke(KeepAwakeDetailPanel(keepAwake: k, extrasAvailable: true))
        XCTAssertGreaterThan(idle.height, 0); XCTAssertGreaterThan(active.height, 0)
        ViewHost.smoke(KeepAwakeDetailPanel(keepAwake: k, extrasAvailable: true),
                       prefs: [KeepAwake.Keys.lidClosed: true, KeepAwake.Keys.jiggle: true,
                               KeepAwake.Keys.keepDisplayOn: false])
        ViewHost.smoke(KeepAwakeHelperUpdateNote())
        ViewHost.smoke(PillSwitch(isOn: .constant(true), label: "On"))
        ViewHost.smoke(PillSwitch(isOn: .constant(false), label: "Off"))
    }

    func testExtrasStatusAndNoticeRender() async {
        let k = make()
        let extras = MockExtras()
        extras.reply = KeepAwakeExtrasStatus()
        k.extrasBackend = extras
        k.start(.indefinitely)
        ViewHost.smoke(KeepAwakeDetailPanel(keepAwake: k, extrasAvailable: true),
                       prefs: [KeepAwake.Keys.lidClosed: true])
        k.stop()
    }
}
