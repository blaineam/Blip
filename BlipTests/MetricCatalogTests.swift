import XCTest
@testable import Blip

final class MetricCatalogTests: XCTestCase {

    // MARK: Catalog integrity

    func testCatalogCoversEveryMetricID() {
        let catalogIDs = Set(MetricCatalog.all.map(\.id))
        for id in MetricID.allCases {
            XCTAssertTrue(catalogIDs.contains(id), "catalog is missing \(id)")
        }
        XCTAssertEqual(MetricCatalog.all.count, MetricID.allCases.count, "catalog has duplicates or extras")
    }

    func testCatalogIDsAreUniqueAndStable() {
        let raws = MetricCatalog.all.map(\.id.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count)
        // Spot-check stability — saved Shortcuts reference these raw ids.
        XCTAssertEqual(MetricID.cpuUsage.rawValue, "cpu.usage")
        XCTAssertEqual(MetricID.smartHealthy.rawValue, "disk.smartok")
        XCTAssertEqual(MetricID.batteryMinutesRemaining.rawValue, "battery.minutesleft")
    }

    func testDescriptorLookup() {
        XCTAssertEqual(MetricCatalog.descriptor(forRawID: "cpu.usage")?.id, .cpuUsage)
        XCTAssertNil(MetricCatalog.descriptor(forRawID: "nope.nothing"))
    }

    func testHistoryFlagsMatchSystemMonitorRings() {
        // Exactly the seven charted metrics carry history.
        let withHistory = Set(MetricCatalog.all.filter(\.hasHistory).map(\.id))
        XCTAssertEqual(withHistory, [.cpuUsage, .memoryUsage, .gpuUsage, .diskRead, .diskWrite, .netDown, .netUp])
    }

    // MARK: Mapping

    func testEveryMetricMapsFromFullSnapshot() {
        let s = Fixtures.snapshot()
        for id in MetricID.allCases {
            XCTAssertNotNil(MetricMapper.value(of: id, in: s), "\(id) returned nil from a full snapshot")
        }
    }

    func testMappingValues() {
        let s = Fixtures.snapshot()
        XCTAssertEqual(MetricMapper.value(of: .cpuUsage, in: s), 42.5)
        XCTAssertEqual(MetricMapper.value(of: .cpuLoad15, in: s), 3.5)
        XCTAssertEqual(MetricMapper.value(of: .memoryUsage, in: s), 50.0)
        XCTAssertEqual(MetricMapper.value(of: .memoryUsed, in: s), 16_000_000_000)
        XCTAssertEqual(MetricMapper.value(of: .diskUsage, in: s), 75.0)
        XCTAssertEqual(MetricMapper.value(of: .diskFree, in: s), 250_000_000_000)
        XCTAssertEqual(MetricMapper.value(of: .diskRead, in: s), 120_000_000)
        XCTAssertEqual(MetricMapper.value(of: .smartHealthy, in: s), 1)
        XCTAssertEqual(MetricMapper.value(of: .ssdLife, in: s), 92)        // 100 - 8
        XCTAssertEqual(MetricMapper.value(of: .driveTemperature, in: s), 41)
        XCTAssertEqual(MetricMapper.value(of: .gpuUsage, in: s), 17.5)
        XCTAssertEqual(MetricMapper.value(of: .netDown, in: s), 12_500_000)
        XCTAssertEqual(MetricMapper.value(of: .netPing, in: s), 12.5)
        XCTAssertEqual(MetricMapper.value(of: .batteryLevel, in: s), 84)
        XCTAssertEqual(MetricMapper.value(of: .batteryMinutesRemaining, in: s), 245)
        XCTAssertEqual(MetricMapper.value(of: .cpuTemperature, in: s), 55.5)
        XCTAssertEqual(MetricMapper.value(of: .fanRPM, in: s), 2_100)     // fastest fan
        XCTAssertEqual(MetricMapper.value(of: .uptime, in: s), 93_784)
        XCTAssertEqual(MetricMapper.value(of: .thermalLevel, in: s), 1)   // .fair
    }

    func testDiskUsageUsesRootVolume() {
        var s = Fixtures.snapshot()
        // Reorder so root isn't first — mapping must still pick "/".
        s.disk.volumes = [s.disk.volumes[1], s.disk.volumes[0]]
        XCTAssertEqual(MetricMapper.value(of: .diskUsage, in: s), 75.0)
    }

    func testUnavailableMetricsReturnNil() {
        var s = Fixtures.snapshot()
        s.battery.isPresent = false
        s.fans = FanStats()              // no SMC data (sandboxed, no helper)
        s.network.pingMs = nil
        s.disk.drives = []
        s.disk.smartStatus = ""
        s.disk.volumes = []

        for id: MetricID in [.batteryLevel, .batteryHealth, .batteryCycles, .batteryTemperature,
                             .batteryMinutesRemaining, .cpuTemperature, .gpuTemperature, .fanRPM,
                             .netPing, .smartHealthy, .ssdLife, .driveTemperature, .diskUsage, .diskFree] {
            XCTAssertNil(MetricMapper.value(of: id, in: s), "\(id) should be nil when unavailable")
        }
    }

    func testBatteryTimeRemainingUnknownIsNil() {
        var s = Fixtures.snapshot()
        s.battery.timeRemaining = -1     // calculating / unknown
        XCTAssertNil(MetricMapper.value(of: .batteryMinutesRemaining, in: s))
    }

    func testSmartHealthyFallsBackToDiskutilStatus() {
        var s = Fixtures.snapshot()
        s.disk.drives = []
        s.disk.smartStatus = "Verified"
        XCTAssertEqual(MetricMapper.value(of: .smartHealthy, in: s), 1)
        s.disk.smartStatus = "Failing"
        XCTAssertEqual(MetricMapper.value(of: .smartHealthy, in: s), 0)
    }

    func testSmartHealthyFlagsFailingDrive() {
        var s = Fixtures.snapshot()
        s.disk.drives = [Fixtures.drive(name: "Bad SSD", percentageUsed: 97, tempC: 60, healthy: false)]
        XCTAssertEqual(MetricMapper.value(of: .smartHealthy, in: s), 0)
        XCTAssertEqual(MetricMapper.value(of: .ssdLife, in: s), 3)
    }

    // MARK: Statistics

    func testReduceStatistics() {
        let samples: [Double] = [10, 20, 30, 40]
        XCTAssertEqual(MetricMapper.reduce(samples, statistic: .current), 40)
        XCTAssertEqual(MetricMapper.reduce(samples, statistic: .average), 25)
        XCTAssertEqual(MetricMapper.reduce(samples, statistic: .minimum), 10)
        XCTAssertEqual(MetricMapper.reduce(samples, statistic: .maximum), 40)
        XCTAssertNil(MetricMapper.reduce([], statistic: .average))
    }

    // MARK: Formatting

    func testFormatter() {
        XCTAssertEqual(MetricFormatter.format(42.55, unit: .percent), "42.5%")
        XCTAssertEqual(MetricFormatter.format(950, unit: .bytes), "950 B")
        XCTAssertEqual(MetricFormatter.format(1_500, unit: .bytes), "1.5 KB")
        XCTAssertEqual(MetricFormatter.format(120_000_000, unit: .bytesPerSecond), "120.0 MB/s")
        XCTAssertEqual(MetricFormatter.format(250_000_000_000, unit: .bytes), "250.00 GB")
        XCTAssertEqual(MetricFormatter.format(9_000_000_000_000, unit: .bytes), "9.00 TB")
        XCTAssertEqual(MetricFormatter.format(12.55, unit: .milliseconds), "12.6 ms")
        XCTAssertEqual(MetricFormatter.format(41, unit: .celsius), "41°C")
        XCTAssertEqual(MetricFormatter.format(2_100, unit: .rpm), "2100 RPM")
        XCTAssertEqual(MetricFormatter.format(3, unit: .count), "3")
        XCTAssertEqual(MetricFormatter.format(1.5, unit: .count), "1.50")
        XCTAssertEqual(MetricFormatter.format(93_784, unit: .seconds), "1d 2h 3m")
        XCTAssertEqual(MetricFormatter.format(245, unit: .minutes), "4h 5m")
        XCTAssertEqual(MetricFormatter.format(2, unit: .level), "2")
    }
}
