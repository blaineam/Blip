import XCTest
@testable import Blip

// Formatting helpers behind the panels: the unit thresholds and rounding that were not pinned.

final class FormattingExtraTests: XCTestCase {

    func testByteFormattersUseTheirUnitFamilies() {
        XCTAssertTrue(Fmt.bytes(8 * 1_073_741_824).contains("GB"))
        XCTAssertTrue(Fmt.bytes(512 * 1_048_576).contains("MB"))
        XCTAssertTrue(Fmt.diskBytes(500_000_000_000).contains("GB"))
        XCTAssertTrue(Fmt.diskBytes(2_000_000_000_000).contains("TB"))
    }

    func testRatesStepThroughByteKiloMega() {
        XCTAssertEqual(Fmt.speed(0), "0 B/s")
        XCTAssertEqual(Fmt.speed(1_000), "1000 B/s", "exactly 1 KB is still bytes")
        XCTAssertEqual(Fmt.speed(2_500), String(format: "%.0f KB/s", 2.5))
        XCTAssertEqual(Fmt.speed(3_400_000), "3.4 MB/s")
        XCTAssertEqual(Fmt.shortSpeed(500), "0K")
        XCTAssertEqual(Fmt.shortSpeed(12_000), "12K")
        XCTAssertEqual(Fmt.shortSpeed(1_500_000), "1.5M")
    }

    func testChartSpeedAndThroughputBoundaries() {
        XCTAssertEqual(Fmt.chartSpeed(999), "999 B/s")
        XCTAssertEqual(Fmt.chartSpeed(1_000), "1 KB/s")
        XCTAssertEqual(Fmt.chartSpeed(1_000_000), "1.0 MB/s")
        XCTAssertEqual(Fmt.chartSpeed(2_500_000_000), "2.5 GB/s")
        XCTAssertEqual(Fmt.throughput(999), "999 Mbps")
        XCTAssertEqual(Fmt.throughput(1_000), "1.00 Gbps")
        XCTAssertEqual(Fmt.throughput(2_345), "2.35 Gbps")
    }

    func testTotalBytesStepsThroughEveryMagnitude() {
        XCTAssertEqual(Fmt.totalBytes(999), "999 B")
        XCTAssertEqual(Fmt.totalBytes(1_000), "1 KB")
        XCTAssertEqual(Fmt.totalBytes(1_500_000), "1.5 MB")
        XCTAssertEqual(Fmt.totalBytes(2_000_000_000), "2.0 GB")
        XCTAssertEqual(Fmt.totalBytes(3_000_000_000_000), "3.0 TB")
    }

    func testTimeRemainingAndUptime() {
        XCTAssertEqual(Fmt.timeRemaining(45), "45m")
        XCTAssertEqual(Fmt.timeRemaining(125), "2h 5m")
        XCTAssertFalse(Fmt.timeRemaining(-1).isEmpty, "unknown estimate reads as a placeholder")
        XCTAssertEqual(Fmt.timeRemaining(0), Fmt.timeRemaining(-1))
        XCTAssertEqual(Fmt.uptime(59 * 60), "59m")
        XCTAssertEqual(Fmt.uptime(3 * 3600 + 120), "3h 2m")
        XCTAssertEqual(Fmt.uptime(2 * 86_400 + 5 * 3600), "2d 5h")
    }

    func testPercentAndTemperatureRounding() {
        XCTAssertEqual(Fmt.percent(42.5), String(format: "%.0f%%", 42.5))
        XCTAssertEqual(Fmt.percent(100), "100%")
        XCTAssertEqual(Fmt.temperature(61.25), String(format: "%.1f°C", 61.25))
    }
}
