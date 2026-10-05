import XCTest
@testable import Blip

// Number formatting used across the popover/panels, plus the share text and Markdown
// snapshot export people paste elsewhere.

@MainActor
final class FormattingAndShareTests: XCTestCase {

    func testSpeedBoundaries() {
        XCTAssertEqual(Fmt.speed(0), "0 B/s")
        XCTAssertEqual(Fmt.speed(1_000), "1000 B/s", "strictly greater than 1 KB switches units")
        XCTAssertEqual(Fmt.speed(1_001), "1 KB/s")
        XCTAssertEqual(Fmt.speed(1_000_001), "1.0 MB/s")
        XCTAssertEqual(Fmt.speed(125_500_000), "125.5 MB/s")
        XCTAssertEqual(Fmt.shortSpeed(900), "0K")
        XCTAssertEqual(Fmt.shortSpeed(2_500_000), "2.5M")
    }

    func testChartSpeedAndThroughput() {
        XCTAssertEqual(Fmt.chartSpeed(999), "999 B/s")
        XCTAssertEqual(Fmt.chartSpeed(1_000), "1 KB/s")
        XCTAssertEqual(Fmt.chartSpeed(1_000_000), "1.0 MB/s")
        XCTAssertEqual(Fmt.chartSpeed(2_500_000_000), "2.5 GB/s")
        XCTAssertEqual(Fmt.throughput(999.4), "999 Mbps")
        XCTAssertEqual(Fmt.throughput(1_000), "1.00 Gbps")
        XCTAssertEqual(Fmt.throughput(2_346), "2.35 Gbps")
    }

    func testTotalBytesUsesDecimalUnits() {
        XCTAssertEqual(Fmt.totalBytes(999), "999 B")
        XCTAssertEqual(Fmt.totalBytes(1_500), "2 KB")
        XCTAssertEqual(Fmt.totalBytes(12_300_000_000), "12.3 GB")
        XCTAssertEqual(Fmt.totalBytes(4_200_000_000_000), "4.2 TB")
    }

    func testDurations() {
        XCTAssertEqual(Fmt.uptime(59), "0m")
        XCTAssertEqual(Fmt.uptime(3_660), "1h 1m")
        XCTAssertEqual(Fmt.uptime(93_784), "1d 2h", "days drop the minutes")
        XCTAssertEqual(Fmt.timeRemaining(45), "45m")
        XCTAssertEqual(Fmt.timeRemaining(125), "2h 5m")
        XCTAssertEqual(Fmt.timeRemaining(0), String(localized: "Calculating..."), "0/unknown isn't '0m'")
        XCTAssertEqual(Fmt.timeRemaining(-1), String(localized: "Calculating..."))
    }

    func testPercentAndTemperature() {
        XCTAssertEqual(Fmt.percent(42.6), "43%")
        XCTAssertEqual(Fmt.temperature(41.04), "41.0°C")
    }

    // MARK: Share text

    private func bench(gpu: Bool, neural: Bool, throttle: Double?) -> BenchResult {
        BenchResult(date: Date(timeIntervalSince1970: 1_800_000_000), profile: .full,
                    singleCore: .init(name: "s", score: 690.4, results: []),
                    multiCore: .init(name: "m", score: 6_300.6, results: []),
                    memory: .init(name: "mem", score: 1_000, results: []),
                    gpu: gpu ? .init(name: "g", score: 650, results: []) : nil,
                    neural: neural ? .init(name: "n", score: 800, results: []) : nil,
                    throttleFactor: throttle, thermalSamples: [], composite: 1_299.5,
                    deviceModel: "Mac15,3", osVersion: "macOS")
    }

    func testBenchShareText() {
        let full = MacShareCard.benchText(bench(gpu: true, neural: true, throttle: 0.82), deviceName: "MacBook Pro")
        let lines = full.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Blip Bench — MacBook Pro")
        XCTAssertEqual(lines[1], "Composite 1300 (full run)")
        XCTAssertEqual(lines[2], "Single-core 690 · All cores 6301 · Memory 1000 · GPU 650 · Neural 800")
        XCTAssertEqual(lines[3], "Sustained load loses 18%")
        XCTAssertEqual(lines.last, "Measured with Blip · wemiller.com/apps/blip")

        let cool = MacShareCard.benchText(bench(gpu: false, neural: false, throttle: 1.0), deviceName: "Mac")
        XCTAssertTrue(cool.contains("No throttling under sustained load"))
        XCTAssertFalse(cool.contains("GPU"))
        let quick = MacShareCard.benchText(bench(gpu: false, neural: false, throttle: nil), deviceName: "Mac")
        XCTAssertEqual(quick.components(separatedBy: "\n").count, 4, "no throttle line without a sustained phase")
    }

    func testSpeedShareTextCarriesNumbersAndGrades() {
        var r = NetSpeedResult(downMbps: 940.4, upMbps: 38.6, timestamp: Date())
        r.pingMs = 9.6
        r.loadedPingMs = 180
        let text = MacShareCard.speedText(r)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Network speed — 940 Mbps down · 39 Mbps up · 10 ms idle · 180 ms loaded")
        XCTAssertEqual(lines[1], ConnectionGrades.shareLines(
            ConnectionGrades.evaluate(down: 940.4, up: 38.6, unloadedMs: 9.6, loadedMs: 180)))
        XCTAssertTrue(lines[1].contains("C "), "180 ms under load caps calls/gaming at C")

        let downOnly = MacShareCard.speedText(NetSpeedResult(downMbps: 50, upMbps: nil, timestamp: Date()))
        XCTAssertFalse(downOnly.components(separatedBy: "\n")[0].contains("up"))
    }

    // MARK: Markdown snapshot

    func testMarkdownSnapshotHasEverySection() {
        var s = Fixtures.snapshot()
        s.system.macModel = "MacBook Pro (M3 Max)"
        s.network.isVPNActive = true
        s.network.vpnInterface = "utun4"
        let history = (0..<7).map { NetSpeedResult(downMbps: Double(100 + $0), upMbps: 10, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double($0))) }
        let md = MacSnapshotExport.markdown(s, speedHistory: history)
        for heading in ["# Blip Snapshot — MacBook Pro (M3 Max)", "## System", "## CPU", "## Memory", "## GPU",
                        "## Network", "## Storage", "## Battery", "## Fans & Thermals", "## Recent speed tests"] {
            XCTAssertTrue(md.contains(heading), heading)
        }
        XCTAssertTrue(md.contains("- **Macintosh HD**"))
        XCTAssertTrue(md.contains("- **Scratch**"))
        XCTAssertTrue(md.contains("Active (utun4)"))
        XCTAssertTrue(md.contains("- 1800 rpm (1200–5900)"))
        XCTAssertTrue(md.contains("| Uptime | 1d 2h |"))
        // Only the five newest speed tests, newest first.
        XCTAssertTrue(md.contains("106 Mbps down"))
        XCTAssertFalse(md.contains("101 Mbps down"))
        let newest = md.range(of: "106 Mbps down")!.lowerBound
        let older = md.range(of: "102 Mbps down")!.lowerBound
        XCTAssertLessThan(newest, older)
    }

    func testMarkdownSnapshotOmitsAbsentHardware() {
        var s = SystemSnapshot()
        s.battery.isPresent = false
        let md = MacSnapshotExport.markdown(s, speedHistory: [])
        XCTAssertTrue(md.contains("# Blip Snapshot — Mac"), "falls back to 'Mac' when the model is unknown")
        XCTAssertFalse(md.contains("## Battery"), "desktop Macs have no battery section")
        XCTAssertFalse(md.contains("## Fans & Thermals"))
        XCTAssertFalse(md.contains("## Recent speed tests"))
        XCTAssertTrue(md.contains("| VPN | Not detected |"))
    }
}
