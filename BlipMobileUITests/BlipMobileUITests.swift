import XCTest

// iOS/iPadOS XCUITests — every tab and detail screen, driven by -UITestMode fixtures:
// the DeviceStats demo overlay (+ pinned CPU 23 %, thermal nominal, uptime 3d 5h, load 1.82),
// DemoSeed bench history (7 runs ending 1342 full) and speed history (942/851 Mbps latest),
// canned ping samples (24, #17 a timeout) and trace hops (8, RFC 5737, hop 5 silent), and
// stub runners (bench → 1388, speed → 905/812 Mbps). The same bundle runs on iPhone and iPad.

private enum Fixture {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static let gib = 1024.0 * 1024 * 1024
    static var memoryTotal: String { mem(isPad ? 16 : 12) }
    static var memoryAvailable: String { mem(isPad ? 9.2 : 6.8) }
    static var storageTotal: Int64 { Int64((isPad ? 1024 : 512) * 1_000_000_000) }
    static var storageFree: String {
        ByteCountFormatter.string(fromByteCount: Int64(Double(storageTotal) * 0.38), countStyle: .file)
    }
    static var storageTotalText: String { ByteCountFormatter.string(fromByteCount: storageTotal, countStyle: .file) }
    static func mem(_ g: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(UInt64(g * gib)), countStyle: .memory)
    }
}

// MARK: - Tabs + deep links

final class TabNavigationTests: XCTestCase {
    func testRouteLaunchArgLandsOnTab() {
        let app = launchBlip(.seeded, ["-blip.route", "bench"])
        wait(app.navigationBars["Bench"])
        waitLabel(app.el("bench.score"), equals: "1,342")
    }

    func testDeepLinkLaunchRouting() {
        let app = launchBlip(.seeded, ["-UITestOpenURL", "blip://speed"])
        wait(app.navigationBars["Speed"])
    }

    /// All four tabs by tapping, then blip:// URLs opened while running — one launch.
    func testTabsAndOpenURLRouting() {
        let app = launchBlip()
        wait(app.navigationBars["Blip"])
        app.tapTab("Bench")
        wait(app.navigationBars["Bench"])
        app.tapTab("Speed")
        wait(app.navigationBars["Speed"])
        app.tapTab("Network")
        wait(app.navigationBars["Network Tools"])
        app.tapTab("Overview")
        wait(app.navigationBars["Blip"])
        app.open(URL(string: "blip://network")!)
        wait(app.navigationBars["Network Tools"])
        app.open(URL(string: "blip://bench")!)
        wait(app.navigationBars["Bench"])
        app.open(URL(string: "blip://somewhere-unknown")!)
        wait(app.navigationBars["Blip"])
    }
}

// MARK: - Overview + detail screens

final class OverviewTests: XCTestCase {
    /// Every card's headline + caption, the (absent) suggestions banner, the toolbar, and the
    /// grid layout for this idiom — one launch.
    func testCardsShowDemoValuesAndLayout() {
        let app = launchBlip()
        waitLabel(app.el("overview.card.cpu"), contains: "23%")
        waitLabel(app.el("overview.card.memory"), contains: Fixture.memoryTotal)
        waitLabel(app.el("overview.card.memory"), contains: "\(Fixture.memoryAvailable) available to apps")
        waitLabel(app.el("overview.card.storage"), contains: "\(Fixture.storageFree) free of \(Fixture.storageTotalText)")
        waitLabel(app.el("overview.card.network"), contains: "Wi-Fi")
        waitLabel(app.el("overview.card.battery"), contains: "87%")
        waitLabel(app.el("overview.card.battery"), contains: "On battery")
        waitLabel(app.el("overview.card.thermal"), contains: "Nominal")
        waitLabel(app.el("overview.card.device"), contains: "Up 3d 5h")
        // 62 % storage, nominal thermals, 6.8+ GB app headroom, no Low Data/Low Power: nothing applies.
        XCTAssertFalse(app.el("overview.suggestions").exists)
        XCTAssertTrue(app.el("overview.share").exists)
        XCTAssertTrue(app.el("overview.settings").exists)

        let cpu = app.el("overview.card.cpu"), memory = app.el("overview.card.memory")
        let storage = app.el("overview.card.storage"), network = app.el("overview.card.network")
        if Fixture.isPad {
            // Adaptive grid: 3+ cards share the first row on a 13" iPad.
            let row = [cpu, memory, storage, network].filter { abs($0.frame.minY - cpu.frame.minY) < 2 }
            XCTAssertGreaterThanOrEqual(row.count, 3, "adaptive grid should put 3+ cards in the first row on iPad")
        } else {
            // Compact width: the classic two-up.
            XCTAssertEqual(cpu.frame.minY, memory.frame.minY, accuracy: 2)
            XCTAssertGreaterThan(storage.frame.minY, cpu.frame.maxY - 1)
        }
    }

    func testCPUMemoryStorageNetworkDetails() {
        let app = launchBlip()
        tap(app.el("overview.card.cpu"), expecting: app.navigationBars["CPU"])
        waitLabel(app.el("detail.cpu.total"), equals: "23%")
        waitLabel(app.el("detail.cpu.load1"), equals: "1.82")
        waitLabel(app.el("detail.cpu.cores"), equals: "6")
        waitLabel(app.el("detail.cpu.pcores"), equals: "2")
        waitLabel(app.el("detail.cpu.ecores"), equals: "4")
        goBack(from: "CPU", to: "Blip", in: app)

        tap(app.el("overview.card.memory"), expecting: app.navigationBars["Memory"])
        waitLabel(app.el("detail.memory.total"), equals: Fixture.memoryTotal)
        waitLabel(app.el("detail.memory.available"), equals: Fixture.memoryAvailable)
        waitLabel(app.el("detail.memory.wired"), equals: Fixture.mem(Fixture.isPad ? 2.4 : 1.9))
        goBack(from: "Memory", to: "Blip", in: app)

        tap(app.el("overview.card.storage"), expecting: app.navigationBars["Storage"])
        waitLabel(app.el("detail.storage.free"), equals: Fixture.storageFree)
        waitLabel(app.el("detail.storage.purgeable"),
                  equals: ByteCountFormatter.string(fromByteCount: Int64(Double(Fixture.storageTotal) * 0.44), countStyle: .file))
        goBack(from: "Storage", to: "Blip", in: app)

        tap(app.el("overview.card.network"), expecting: app.navigationBars["Network"])
        waitLabel(app.el("detail.network.interface"), equals: "Wi-Fi")
        waitLabel(app.el("detail.network.ip.en0"), equals: "192.0.2.24")
        waitLabel(app.el("detail.network.vpn"), equals: "Not detected")
        // The button flips to its "copied" state (checkmark) for a moment, then back.
        tap(app.el("detail.network.ip.en0.copy"), expecting: app.el("detail.network.ip.en0.copied"))
        wait(app.el("detail.network.ip.en0.copy"), 10)
    }

    func testBatteryThermalDeviceDetails() {
        let app = launchBlip()
        tap(app.el("overview.card.battery"), expecting: app.navigationBars["Battery"])
        waitLabel(app.el("detail.battery.level"), equals: "87%")
        waitLabel(app.el("detail.battery.state"), equals: "On battery")
        waitLabel(app.el("detail.battery.lowPower"), equals: "Off")
        goBack(from: "Battery", to: "Blip", in: app)

        tap(app.el("overview.card.thermal"), expecting: app.navigationBars["Thermal"])
        waitLabel(app.el("detail.thermal.state"), equals: "Nominal")
        XCTAssertTrue(app.staticTexts["Full performance"].exists)
        goBack(from: "Thermal", to: "Blip", in: app)

        tap(app.el("overview.card.device"), expecting: app.navigationBars["Device"])
        let model = wait(app.el("detail.device.model"))
        XCTAssertTrue(model.label.hasPrefix(Fixture.isPad ? "iPad" : "iPhone"), "model: \(model.label)")
        XCTAssertFalse(wait(app.el("detail.device.os")).label.isEmpty)
        waitLabel(app.el("detail.device.uptime"), equals: "3d 5h")
    }
}

// MARK: - Bench

final class BenchTests: XCTestCase {
    func testEmptyShowsIntroRunButtonAndBatteryGuardrail() {
        let app = launchBlip(.empty, ["-blip.route", "bench"])
        wait(app.el("bench.intro"))
        waitLabel(app.el("bench.run"), equals: "Run Full Benchmark")
        XCTAssertFalse(app.el("bench.score").exists)
        XCTAssertFalse(app.el("bench.history.row.0").exists)
        // The demo device is on battery → the fair-run warning shows above the button.
        waitLabel(app.el("bench.guardrail.battery"), contains: "On battery")
    }

    func testSeededShowsScoreAndHistory() {
        let app = launchBlip(.seeded, ["-blip.route", "bench"])
        waitLabel(app.el("bench.score"), equals: "1,342")
        wait(app.el("bench.share"))
        app.scrollTo(app.el("bench.history.row.6"))
        waitLabel(app.el("bench.history.row.0"), equals: "1,342")
        waitLabel(app.el("bench.history.profile.0"), equals: "full")
        waitLabel(app.el("bench.history.row.1"), equals: "1,301")
        waitLabel(app.el("bench.history.profile.1"), equals: "quick")
        waitLabel(app.el("bench.history.row.6"), equals: "1,210")
        XCTAssertFalse(app.el("bench.history.row.7").exists)
    }

    func testRunStubShowsLegsThenScoreAndGrowsHistory() {
        let app = launchBlip(.seeded, ["-blip.route", "bench"])
        waitLabel(app.el("bench.score"), equals: "1,342")
        app.el("bench.run").tap()
        wait(app.el("bench.running"))
        wait(app.el("bench.leg.single"))
        waitLabel(app.el("bench.score"), equals: "1,388", 15)
        waitLabel(app.el("bench.run"), equals: "Run Full Benchmark")
        XCTAssertFalse(app.el("bench.running").exists)
        app.scrollTo(app.el("bench.history.row.7"))
        waitLabel(app.el("bench.history.row.0"), equals: "1,388")
        waitLabel(app.el("bench.history.row.7"), equals: "1,210")
    }

    func testCancelDuringRunKeepsPreviousResult() {
        let app = launchBlip(.seeded, ["-blip.route", "bench", "-UITestBenchOutcome", "cancel"])
        waitLabel(app.el("bench.score"), equals: "1,342")
        app.el("bench.run").tap()
        wait(app.el("bench.leg.neural"), 15)          // every leg landed; the stub now holds
        waitLabel(app.el("bench.run"), equals: "Cancel")
        app.el("bench.run").tap()
        waitLabel(app.el("bench.score"), equals: "1,342")
        waitLabel(app.el("bench.run"), equals: "Run Full Benchmark")
        app.scrollTo(app.el("bench.history.row.6"))
        XCTAssertFalse(app.el("bench.history.row.7").exists, "a cancelled run must not land in history")
    }
}

// MARK: - Speed

final class SpeedTests: XCTestCase {
    func testPathBannerAndSeededResult() {
        let app = launchBlip(.seeded, ["-blip.route", "speed"])
        waitLabel(app.el("speed.pathBanner"), contains: "Testing over Wi-Fi")
        waitLabel(app.el("speed.gauge"), equals: "942")
        waitLabel(app.el("speed.phase"), equals: "Mbps")
        waitLabel(app.el("speed.result.down"), contains: "942 Mbps")
        waitLabel(app.el("speed.result.up"), contains: "851 Mbps")
        waitLabel(app.el("speed.result.ping"), contains: "12 ms idle")
        waitLabel(app.el("speed.result.loadedPing"), contains: "29 ms under load")
        wait(app.el("speed.result.share"))
        tap(app.el("speed.settings"), expecting: app.navigationBars["Settings"])
    }

    func testSeededHistoryNewestFirst() {
        let app = launchBlip(.seeded, ["-blip.route", "speed"])
        app.scrollTo(app.el("speed.history.2.down"))
        waitLabel(app.el("speed.history.0.down"), contains: "897 Mbps")
        waitLabel(app.el("speed.history.1.down"), contains: "68 Mbps")
        waitLabel(app.el("speed.history.2.down"), contains: "915 Mbps")
        XCTAssertFalse(app.el("speed.history.3.down").exists)
    }

    func testRunStubDrivesPhasesToDone() {
        let app = launchBlip(.seeded, ["-blip.route", "speed"])
        waitLabel(app.el("speed.gauge"), equals: "942")
        app.el("speed.run").tap()
        waitLabel(app.el("speed.phase"), equals: "Mbps · down", 15)
        waitLabel(app.el("speed.gauge"), equals: "905")
        waitLabel(app.el("speed.result.down"), contains: "905 Mbps")
        waitLabel(app.el("speed.result.up"), contains: "812 Mbps")
        waitLabel(app.el("speed.result.ping"), contains: "14 ms idle")
        waitLabel(app.el("speed.run"), equals: "Run Speed Test")
        // The previous latest (942) is now the newest history entry.
        app.scrollTo(app.el("speed.history.0.down"))
        waitLabel(app.el("speed.history.0.down"), contains: "942 Mbps")
    }

    func testRunFailureShowsReason() {
        let app = launchBlip(.seeded, ["-blip.route", "speed", "-UITestSpeedOutcome", "fail"])
        wait(app.el("speed.run")).tap()
        waitLabel(app.el("speed.phase"), equals: "Server unreachable", 15)
        waitLabel(app.el("speed.run"), equals: "Run Speed Test")
    }

    func testMyServerWithoutAddressAsksForOne() {
        let app = launchBlip(.seeded, ["-blip.route", "speed"])
        waitLabel(app.el("speed.configure"), contains: "Configure")
        wait(app.el("speed.sourceMenu")).tap()
        wait(app.buttons["My server"]).tap()
        waitLabel(app.el("speed.sourceMenu"), contains: "My server (not set)")
        waitLabel(app.el("speed.configure"), contains: "Set server…")
        app.el("speed.run").tap()
        waitLabel(app.el("speed.phase"), equals: "Set your server address in Settings first.")
    }

}

// MARK: - Network tools

final class NetworkToolsTests: XCTestCase {
    func testPingStartShowsStatsAndTimeoutThenStops() {
        let app = launchBlip(.empty, ["-blip.route", "network"])
        waitLabel(app.el("net.target"), contains: "1.1.1.1")
        XCTAssertFalse(app.el("net.ping.stat.sent").exists)
        wait(app.el("net.ping.start")).tap()
        waitLabel(app.el("net.ping.start"), equals: "Stop")
        waitLabel(app.el("net.ping.stat.sent"), equals: "24", 15)
        waitLabel(app.el("net.ping.stat.loss"), equals: "4%")
        wait(app.el("net.ping.stat.avg"))
        wait(app.el("net.ping.stat.minmax"))
        waitLabel(app.el("net.ping.sample.17"), equals: "timeout")
        XCTAssertTrue(app.el("net.ping.sample.24").label.hasSuffix(" ms"))
        app.el("net.ping.start").tap()
        waitLabel(app.el("net.ping.start"), equals: "Start Ping")
        XCTAssertEqual(app.el("net.ping.stat.sent").label, "24", "stopping keeps the session's samples")
    }


    func testTraceShowsHopsDestinationAndGeoHint() {
        let app = launchBlip(.empty, ["-blip.route", "network"])
        wait(app.el("net.mode"))
        app.el("net.mode").buttons["Traceroute"].tap()
        wait(app.el("net.trace.start")).tap()
        app.scrollTo(app.el("net.trace.hop.8"))
        waitLabel(app.el("net.trace.hop.8"), equals: "203.0.113.60", 15)
        waitLabel(app.el("net.trace.hop.1"), equals: "192.168.1.1")
        waitLabel(app.el("net.trace.hop.5"), equals: "*")
        waitLabel(app.el("net.trace.start"), equals: "Run Traceroute")
        // No GeoIP database in the isolated store and no demo geo table → the hint, no map.
        wait(app.el("net.trace.geoHint"))
        XCTAssertFalse(app.el("net.trace.map").exists)
    }

    func testGeoHintOpensSettingsWithDownloadOffer() {
        let app = launchBlip(.empty, ["-blip.route", "network"])
        wait(app.el("net.mode")).buttons["Traceroute"].tap()
        wait(app.el("net.trace.start")).tap()
        waitLabel(app.el("net.trace.start"), equals: "Run Traceroute", 15)
        tap(app.el("net.trace.geoHint"), expecting: app.navigationBars["Settings"])
        app.scrollTo(app.el("settings.geoip.download"))
        waitLabel(app.el("settings.geoip.download"), contains: "Download GeoIP Database")
    }

    func testSeededTraceModeShowsMapAndNoHint() {
        let app = launchBlip(.seeded, ["-blip.route", "network", "-blip.demoNetworkMode", "trace"])
        waitLabel(app.el("net.trace.start"), equals: "Run Traceroute")
        waitLabel(app.el("net.trace.hop.2"), equals: "192.0.2.1")
        XCTAssertFalse(app.el("net.trace.geoHint").exists)
    }

    func testSeededSessionAndModePickerSwitches() {
        let app = launchBlip(.seeded, ["-blip.route", "network"])
        let picker = wait(app.el("net.mode"))
        // The demo fixtures show a finished canned ping session without touching the network.
        waitLabel(app.el("net.ping.stat.sent"), equals: "24")
        waitLabel(app.el("net.ping.start"), equals: "Start Ping")
        picker.buttons["Traceroute"].tap()
        wait(app.el("net.trace.start"))
        XCTAssertFalse(app.el("net.ping.start").exists)
        picker.buttons["Ping"].tap()
        wait(app.el("net.ping.start"))
    }

    func testPingTargetFromSettingsShowsInHeader() {
        let app = launchBlip(.empty, ["-blip.route", "network"])
        waitLabel(app.el("net.target"), contains: "1.1.1.1")
        tap(app.el("net.settings"), expecting: app.navigationBars["Settings"])
        let field = wait(app.el("settings.pingTarget"))
        field.tap()
        field.typeText("192.0.2.9")
        goBack(from: "Settings", to: "Network Tools", in: app)
        waitLabel(app.el("net.target"), contains: "192.0.2.9")
    }
}

// MARK: - Settings

final class SettingsTests: XCTestCase {
    func testFieldsStartEmptyAndGeoIPNotInstalled() {
        let app = launchBlip()
        tap(app.el("overview.settings"), expecting: app.navigationBars["Settings"])
        let server = wait(app.el("settings.speedServer"))
        XCTAssertEqual(server.placeholderValue, "192.168.1.50:3000")
        XCTAssertTrue((server.value as? String ?? "").isEmpty || server.value as? String == server.placeholderValue,
                      "the isolated store starts with no server")
        wait(app.el("settings.traceTarget"))
        app.scrollTo(app.el("settings.geoip.download"))
        waitLabel(app.el("settings.geoip.download"), contains: "Download GeoIP Database")
    }

    func testTraceTargetPersistsAcrossVisits() {
        let app = launchBlip()
        tap(app.el("overview.settings"), expecting: app.navigationBars["Settings"])
        let field = wait(app.el("settings.traceTarget"))
        field.tap()
        field.typeText("example.test")
        goBack(from: "Settings", to: "Blip", in: app)
        tap(app.el("overview.settings"), expecting: app.navigationBars["Settings"])
        XCTAssertEqual(wait(app.el("settings.traceTarget")).value as? String, "example.test")
    }
}

// MARK: - Suggestions banner, Storage → Disk Speed, GeoIP states, About

final class CoverageGapTests: XCTestCase {
    /// `-UITestFixture strained` (96 % storage used, serious thermals) → exactly the storage
    /// and thermal suggestions, with the real numbers in the text.
    func testSuggestionsBannerListsApplicableItems() {
        let app = launchBlip(.seeded, ["-UITestFixture", "strained"])
        wait(app.el("overview.suggestions"))
        let free = ByteCountFormatter.string(fromByteCount: Int64(Double(Fixture.storageTotal) * 0.04), countStyle: .file)
        waitLabel(app.el("overview.suggestions.item.storage"), contains: "Storage is nearly full (\(free) left)")
        waitLabel(app.el("overview.suggestions.item.thermal"), contains: "running serious")
        waitLabel(app.el("overview.card.thermal"), contains: "Serious")
        XCTAssertFalse(app.el("overview.suggestions.item.lpm").exists)
        XCTAssertFalse(app.el("overview.suggestions.item.lowdata").exists)
        XCTAssertFalse(app.el("overview.suggestions.item.mem").exists)
    }

    private func openDiskSpeed(_ extra: [String] = []) -> XCUIApplication {
        let app = launchBlip(.seeded, extra)
        tap(app.el("overview.card.storage"), expecting: app.navigationBars["Storage"])
        let run = app.el("storage.disk.runInternal")
        app.scrollTo(run)
        waitLabel(run, contains: "Test Internal Storage")
        waitLabel(app.el("storage.disk.pickFolder"), contains: "Test External Volume")
        XCTAssertFalse(app.el("storage.disk.result.volume").exists, "no result before the first run")
        return app
    }

    func testStorageDiskSpeedRunShowsResult() {
        let app = openDiskSpeed()
        app.el("storage.disk.runInternal").tap()
        waitLabel(app.el("storage.disk.result.volume"), equals: "Internal storage")
        waitLabel(app.staticTexts["storage.disk.result.write"], contains: "2,950 MB/s write")
        waitLabel(app.staticTexts["storage.disk.result.read"], contains: "3,400 MB/s read")
        // Back to idle: the run buttons return, the live readout is gone.
        wait(app.el("storage.disk.runInternal"))
        XCTAssertFalse(app.el("storage.disk.cancel").exists)
    }

    func testStorageDiskSpeedCancelLeavesNoResult() {
        let app = openDiskSpeed(["-UITestDiskOutcome", "cancel"])
        app.el("storage.disk.runInternal").tap()
        // The stub walks writing → reading and holds there with the last live figure.
        waitLabel(app.el("storage.disk.phase"), equals: "Reading…")
        waitLabel(app.el("storage.disk.live"), equals: "3400 MB/s")
        app.el("storage.disk.cancel").tap()
        wait(app.el("storage.disk.runInternal"))
        XCTAssertFalse(app.el("storage.disk.phase").exists)
        XCTAssertFalse(app.el("storage.disk.result.volume").exists, "a cancelled run records nothing")
    }

    private func openGeoIPSettings(_ state: String) -> XCUIApplication {
        let app = launchBlip(.seeded, ["-UITestGeoIP", state])
        tap(app.el("overview.settings"), expecting: app.navigationBars["Settings"])
        app.scrollTo(app.el("settings.geoip.status"))
        return app
    }

    func testGeoIPReadyShowsRemove() {
        let app = openGeoIPSettings("ready")
        waitLabel(app.el("settings.geoip.status"), contains: "Installed — DBIP-City-Lite")
        waitLabel(app.el("settings.geoip.updated"), contains: "Updated Sep 15, 2026")
        waitLabel(app.el("settings.geoip.updated"), contains: "IP geolocation by DB-IP")
        app.el("settings.geoip.remove").tap()
        waitLabel(app.el("settings.geoip.download"), contains: "Download GeoIP Database")
        XCTAssertFalse(app.el("settings.geoip.remove").exists)
    }

    func testGeoIPFailedShowsRetry() {
        let app = openGeoIPSettings("failed")
        waitLabel(app.el("settings.geoip.status"), contains: "No internet connection.")
        // Try Again starts a (stubbed, offline) download; cancelling it lands on not-installed.
        tap(app.el("settings.geoip.retry"), expecting: app.el("settings.geoip.cancel"))
        XCTAssertFalse(app.el("settings.geoip.retry").exists)
        app.el("settings.geoip.cancel").tap()
        waitLabel(app.el("settings.geoip.download"), contains: "Download GeoIP Database")
    }

    func testAboutShowsAppVersion() {
        let app = launchBlip()
        tap(app.el("overview.settings"), expecting: app.navigationBars["Settings"])
        let label = app.staticTexts["Version"]
        app.scrollTo(label, maxSwipes: 12)
        wait(label)
        let version = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", #"^\d+\.\d+(\.\d+)?( \(\d+\))?$"#)).firstMatch
        wait(version)
        XCTAssertEqual(version.frame.midY, label.frame.midY, accuracy: 12, "the version sits on the Version row")
    }
}
