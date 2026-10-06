import XCTest

// macOS XCUITests for Blip's menu-bar UI, driven through -UITestMode (DEBUG-only): the real
// PopoverView in a titled window, the screenshot rig's fictional snapshot (CPU 31 %, 12
// cores 8P/4E, load 2.40; 36 GB RAM, 19 used; Macintosh HD 1 TB, 612 GB free; Wi-Fi
// 192.168.1.42, ping 11 ms; battery 84 % / 6h 12m; thermal nominal) plus a GPU reading,
// a seeded bench history ending 1342, and stub runners (bench 1388, disk 3120/5480 MB/s,
// network 930/840 Mbps, a canned RFC 5737 MTR route). Never clicked: Quit, Share, Launch at
// Login, GeoIP Download, support links, "Change…" (NSOpenPanel), lid/jiggle extras.

// MARK: - Popover overview

final class PopoverOverviewTests: XCTestCase {
    func testRowsShowDemoValues() {
        let app = launchBlip()
        waitText(app.el("popover.row.cpu.value"), equals: "31%")
        waitText(app.el("popover.row.memory.value"), equals: "53%")
        waitText(app.el("popover.row.disk.value"), equals: "39%")
        waitText(app.el("popover.row.network.down"), equals: "4.2M")
        waitText(app.el("popover.row.network.up"), equals: "680K")
        waitText(app.el("popover.row.gpu.value"), equals: "18%")
        waitText(app.el("popover.row.thermal.value"), equals: "Nominal")
        waitText(app.el("popover.row.bench.value"), equals: "1342")
        waitText(app.el("popover.row.battery.value"), equals: "84%")
        waitText(app.el("popover.row.awake.value"), equals: "Off")
    }

    func testFooterShowsModelOSUptimeVersion() {
        let app = launchBlip()
        waitText(app.el("popover.footer.model"), equals: "MacBook Pro")
        waitText(app.el("popover.footer.os"), equals: "macOS 15.0")
        waitText(app.el("popover.footer.uptime"), equals: "3d 5h")
        waitText(app.el("popover.footer.version"), contains: "41.6 MB")
        XCTAssertTrue(app.el("popover.share").exists)
        XCTAssertTrue(app.el("popover.quit").exists)
    }

    func testEmptyBenchHistoryOffersRun() {
        let app = launchBlip(seeded: false)
        waitText(app.el("popover.row.bench.value"), equals: "run")
    }

    func testNoRecommendationForHealthyDemo() {
        let app = launchBlip()
        wait(app.el("popover.row.cpu"))
        XCTAssertFalse(app.el("popover.recommendation.title").exists)
    }

    func testRecommendationBannerDismissAndResetFromSettings() {
        let app = launchBlip(["-UITestRecommendation"])
        waitText(app.el("popover.recommendation.title"), contains: "swap in use")
        app.el("popover.recommendation.dismiss").click()
        waitGone(app.el("popover.recommendation.title"))
        // Settings → Recommendations → Reset brings dismissed suggestions back.
        let settings = app.openSettings()
        let reset = wait(settings.el("settings.recommendations.reset"))
        reset.click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        waitGone(app.settingsWindow)
        wait(app.el("popover.recommendation.title"))
    }

    func testRecommendationsToggleHidesBanner() {
        let app = launchBlip(["-UITestRecommendation"])
        wait(app.el("popover.recommendation.title"))
        let settings = app.openSettings()
        let toggle = wait(settings.el("settings.recommendations.toggle"))
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        waitGone(app.el("popover.recommendation.title"))
    }

    func testGearOpensSettingsOnGeneralTab() {
        let app = launchBlip()
        let settings = app.openSettings()
        XCTAssertEqual(settings.title, "Blip Settings")
        wait(settings.el("settings.launchAtLogin"))
        wait(settings.el("settings.pingTarget"))
    }

    func testSupportRowOpensSettings() {
        let app = launchBlip()
        wait(app.el("popover.support")).click()
        wait(app.settingsWindow)
    }

    func testPinTogglesState() {
        let app = launchBlip()
        wait(app.el("popover.pin.off")).click()
        wait(app.el("popover.pin.on")).click()
        wait(app.el("popover.pin.off"))
    }
}

// MARK: - Inline detail panels

final class InlineDetailTests: XCTestCase {
    func testCPUDetail() {
        let app = launchBlip()
        let panel = app.expand("cpu")
        wait(panel.text("31%"))
        wait(panel.text("2.40"))      // load 1m
        wait(panel.text("2.10"))      // load 5m
        wait(panel.text("8"))         // P-cores
        wait(panel.text("4"))         // E-cores
        wait(panel.text("12"))        // logical
    }

    func testMemoryDetail() {
        let app = launchBlip()
        let panel = app.expand("memory")
        wait(panel.text("53%"))
        wait(panel.text("36 GB"))
    }

    func testDiskDetail() {
        let app = launchBlip()
        let panel = app.expand("disk")
        wait(panel.text("Macintosh HD"))
        wait(panel.text("612 GB free"))
        wait(panel.text("388 GB used"))
    }

    func testNetworkDetail() {
        let app = launchBlip()
        let panel = app.expand("network")
        wait(panel.text("11 ms"))      // WAN ping
        wait(panel.text("2 ms"))       // router ping
        wait(panel.text("192.168.1.42"))
    }

    func testGPUDetail() {
        let app = launchBlip()
        let panel = app.expand("gpu")
        wait(panel.text("Apple M4 Pro GPU"))
        wait(panel.text("18%"))
    }

    func testThermalDetail() {
        let app = launchBlip()
        let panel = app.expand("thermal")
        wait(panel.text("Nominal"))
        // No helper → no SMC fans/temps: those sections stay out instead of showing zeros.
        XCTAssertFalse(panel.text("Fans").exists)
    }

    func testBatteryDetail() {
        let app = launchBlip()
        let panel = app.expand("battery")
        wait(panel.text("84%"))
        wait(panel.text("On Battery"))
        wait(panel.text("6h 12m"))
    }

    func testBenchDetailShowsScoreAndHistory() {
        let app = launchBlip()
        let panel = app.expand("bench")
        waitText(panel.el("detail.bench.score"), equals: "1,342")
        waitText(panel.el("detail.bench.history.0"), equals: "1,342")
        waitText(panel.el("detail.bench.history.2"), equals: "1,246")
        XCTAssertFalse(panel.el("detail.bench.history.3").exists)
    }

    func testKeepAwakeDetailShowsOff() {
        let app = launchBlip()
        let panel = app.expand("awake")
        waitText(panel.el("detail.awake.status"), equals: "Off")
        wait(panel.el("detail.awake.duration.oneHour"))
    }

    func testClickingExpandedRowCollapses() {
        let app = launchBlip()
        app.expand("cpu")
        app.el("popover.row.cpu").click()
        waitGone(app.el("detail.cpu"))
        // Expanding another row replaces it.
        app.expand("memory")
        app.expand("battery")
        waitGone(app.el("detail.memory"))
    }
}

// MARK: - Flows

final class FlowTests: XCTestCase {
    func testBenchRunShowsScoreAndAppendsHistory() {
        let app = launchBlip()
        let panel = app.expand("bench")
        waitText(panel.el("detail.bench.score"), equals: "1,342")
        panel.el("detail.bench.run").click()
        waitText(app.el("popover.row.bench.value"), equals: "running…")
        waitText(panel.el("detail.bench.score"), equals: "1,388", 20)
        waitText(app.el("popover.row.bench.value"), equals: "1388")
        waitText(panel.el("detail.bench.history.0"), equals: "1,388")
        waitText(panel.el("detail.bench.history.3"), equals: "1,246")
    }

    func testBenchCancelKeepsPreviousScore() {
        let app = launchBlip(["-UITestBenchOutcome", "cancel"])
        let panel = app.expand("bench")
        panel.el("detail.bench.run").click()
        waitText(app.el("popover.row.bench.value"), equals: "running…")
        waitText(panel.el("detail.bench.run"), equals: "Cancel")
        panel.el("detail.bench.run").click()
        waitText(app.el("popover.row.bench.value"), equals: "1342")
        XCTAssertFalse(panel.el("detail.bench.history.3").exists, "a cancelled run must not land in history")
    }

    func testDiskSpeedTestRunShowsResultThenCancelMidRun() {
        let app = launchBlip()
        let panel = app.expand("disk")
        wait(panel.el("detail.disk.speed.toggle")).click()
        wait(panel.el("detail.disk.speed.run")).click()
        wait(panel.el("detail.disk.speed.cancel"))
        waitText(panel.el("detail.disk.speed.iops"), equals: "41K IOPS", 15)
        wait(panel.text("5480 MB/s"))
        wait(panel.text("3120 MB/s"))
        // A second run cancelled mid-way returns to idle with the first result intact.
        wait(panel.el("detail.disk.speed.run")).click()
        wait(panel.el("detail.disk.speed.cancel")).click()
        wait(panel.el("detail.disk.speed.run"))
        waitText(panel.el("detail.disk.speed.iops"), equals: "41K IOPS")
    }

    func testNetworkSpeedTestRunShowsResult() {
        let app = launchBlip()
        let panel = app.expand("network")
        wait(panel.el("detail.network.speed.toggle")).click()
        wait(panel.el("detail.network.speed.run")).click()
        wait(panel.text("930 Mbps"), 15)
        wait(panel.text("840 Mbps"))
    }

    func testInlineTracerouteListsHopsThenStops() {
        let app = launchBlip()
        let panel = app.expand("network")
        wait(panel.el("detail.network.trace.toggle")).click()
        wait(panel.el("detail.network.trace.start")).click()
        waitText(panel.el("detail.network.trace.hop.8"), equals: "203.0.113.60", 15)
        waitText(panel.el("detail.network.trace.hop.2"), equals: "192.0.2.1")
        waitText(panel.el("detail.network.trace.hop.5"), equals: "*")
        panel.el("detail.network.trace.stop").click()
        wait(panel.el("detail.network.trace.start"))
        XCTAssertTrue(panel.el("detail.network.trace.hop.8").exists, "stopping keeps the session's hops")
    }

    func testTracerouteWindowRunsTypedHost() {
        let app = launchBlip()
        let panel = app.expand("network")
        // The "open in a window" icon is the trailing glyph of the Traceroute header row.
        let header = wait(panel.el("detail.network.trace.toggle"))
        header.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -6, dy: 0)).click()
        let window = wait(app.tracerouteWindow)
        let host = wait(window.el("traceroute.host"))
        XCTAssertEqual(host.value as? String, "1.1.1.1", "defaults to 1.1.1.1 with no target set")
        host.doubleClick()
        host.typeKey("a", modifierFlags: .command)
        host.typeText("example.test")
        window.el("traceroute.start").click()
        waitText(window.el("traceroute.hop.8"), equals: "203.0.113.60", 15)
        waitText(window.el("traceroute.hop.1"), equals: "192.168.1.1")
        window.el("traceroute.stop").click()
        wait(window.el("traceroute.start"))
    }

    func testKeepAwakeToggleFromOverviewRow() {
        let app = launchBlip()
        let toggle = wait(app.el("popover.row.awake.switch"))
        toggle.click()
        waitText(app.el("popover.row.awake.value"), equals: "∞")
        // In inline mode the click on the row's switch also expands the row's details.
        var panel = app.el("detail.awake")
        if !panel.waitForExistence(timeout: 3) { panel = app.expand("awake") }
        waitText(panel.el("detail.awake.status"), equals: "On")
        panel.el("detail.awake.stop").click()
        waitText(app.el("popover.row.awake.value"), equals: "Off")
        waitText(panel.el("detail.awake.status"), equals: "Off")
    }
}

// MARK: - Settings

final class SettingsTests: XCTestCase {
    func testTabsSwitch() {
        let app = launchBlip()
        let settings = app.openSettings()
        wait(settings.el("settings.launchAtLogin"))
        app.settingsTab("Appearance")
        wait(settings.el("settings.colorMode"))
        app.settingsTab("Menu Bar")
        wait(settings.el("settings.menubar.showCPU"))
        wait(settings.el("settings.menubar.detailStyle"))
        app.settingsTab("General")
        wait(settings.el("settings.pingTarget"))
    }

    func testPingTargetPersistsAcrossReopen() {
        let app = launchBlip()
        var settings = app.openSettings()
        let field = wait(settings.el("settings.pingTarget"))
        XCTAssertEqual(field.value as? String, "1.1.1.1")
        field.doubleClick()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("192.0.2.9\r")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        waitGone(app.settingsWindow)
        settings = app.openSettings()
        XCTAssertEqual(wait(settings.el("settings.pingTarget")).value as? String, "192.0.2.9")
    }

    func testColorModeCustomRevealsColorPicker() {
        let app = launchBlip()
        let settings = app.openSettings()
        app.settingsTab("Appearance")
        XCTAssertFalse(settings.el("settings.colorPicker").exists)
        wait(settings.radioButtons["Custom Color"]).click()
        wait(settings.el("settings.colorPicker"))
        settings.radioButtons["Monochrome"].click()
        waitGone(settings.el("settings.colorPicker"))
    }

    func testMenuBarDetailsPickerSwitchesPopoverToHoverPanels() {
        let app = launchBlip()
        let settings = app.openSettings()
        app.settingsTab("Menu Bar")
        let inline = wait(settings.radioButtons["Inside the menu, on click"])
        XCTAssertEqual(inline.value as? Int, 1, "UI-test mode starts with inline details")
        settings.radioButtons["Beside the menu, on hover"].click()
        XCTAssertEqual(settings.radioButtons["Beside the menu, on hover"].value as? Int, 1)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        waitGone(app.settingsWindow)
        // Beside mode: clicking a row no longer expands it inline.
        wait(app.el("popover.row.cpu")).click()
        XCTAssertFalse(app.el("detail.cpu").waitForExistence(timeout: 2))
    }

    func testMenuBarItemToggles() {
        let app = launchBlip()
        let settings = app.openSettings()
        app.settingsTab("Menu Bar")
        let cpu = wait(settings.el("settings.menubar.showCPU"))
        XCTAssertEqual(cpu.value as? Int, 1)
        cpu.click()
        XCTAssertEqual(cpu.value as? Int, 0)
        let gpu = settings.el("settings.menubar.showGPU")
        XCTAssertEqual(gpu.value as? Int, 0)
        gpu.click()
        XCTAssertEqual(gpu.value as? Int, 1)
    }

    func testGeoIPShowsNotInstalled() {
        let app = launchBlip()
        let settings = app.openSettings()
        waitText(settings.el("settings.geoip.status"), equals: "Not installed")
        XCTAssertTrue(settings.el("settings.geoip.download").exists)
    }

    func testVersionRowShowsAppVersion() {
        let app = launchBlip()
        let settings = app.openSettings()
        let version = wait(settings.el("settings.version"))
        XCTAssertTrue(version.displayText.range(of: #"^\d+\.\d+(\.\d+)?"#, options: .regularExpression) != nil,
                      "version: \(version.displayText)")
    }
}
