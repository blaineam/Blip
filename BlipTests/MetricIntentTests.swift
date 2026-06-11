import XCTest
@testable import Blip

@MainActor
final class MetricIntentTests: XCTestCase {

    private var source: MockMetricSource!

    override func setUp() async throws {
        source = MockMetricSource()
        source.snapshot = Fixtures.snapshot()
        AppIntentsEnvironment.metricSource = source
    }

    override func tearDown() async throws {
        AppIntentsEnvironment.metricSource = nil
    }

    // MARK: Entity query

    func testQueryResolvesIdentifiers() async throws {
        let entities = try await MetricEntityQuery().entities(for: ["cpu.usage", "battery.level", "bogus"])
        XCTAssertEqual(entities.map(\.id), ["cpu.usage", "battery.level"])
        XCTAssertEqual(entities.first?.title, "CPU Usage")
    }

    func testQuerySuggestsFullCatalog() async throws {
        let entities = try await MetricEntityQuery().suggestedEntities()
        XCTAssertEqual(entities.count, MetricID.allCases.count)
    }

    func testQueryStringMatching() async throws {
        let byTitle = try await MetricEntityQuery().entities(matching: "battery")
        XCTAssertEqual(Set(byTitle.map(\.id)),
                       ["battery.level", "battery.health", "battery.cycles", "battery.temp", "battery.minutesleft"])

        let byID = try await MetricEntityQuery().entities(matching: "smartok")
        XCTAssertEqual(byID.map(\.id), ["disk.smartok"])

        let none = try await MetricEntityQuery().entities(matching: "zzz-not-a-metric")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: GetMetric perform

    private func makeIntent(_ id: MetricID, statistic: MetricStatistic = .current) -> GetMetricIntent {
        let intent = GetMetricIntent()
        intent.metric = MetricEntity(descriptor: MetricCatalog.descriptor(for: id))
        intent.statistic = statistic
        return intent
    }

    func testGetCurrentMetric() async throws {
        let result = try await makeIntent(.cpuUsage).perform()
        XCTAssertEqual(result.value, 42.5)
        XCTAssertEqual(source.ensureFreshSampleCalls, 1, "intent must wait for the first sample")
    }

    func testGetAverageOverHistory() async throws {
        source.histories[.cpuUsage] = [10, 20, 30]
        let result = try await makeIntent(.cpuUsage, statistic: .average).perform()
        XCTAssertEqual(result.value, 20)
    }

    func testGetMaximumOverHistory() async throws {
        source.histories[.netDown] = [1_000, 9_000, 5_000]
        let result = try await makeIntent(.netDown, statistic: .maximum).perform()
        XCTAssertEqual(result.value, 9_000)
    }

    func testHistoryStatisticOnUnchartedMetricThrows() async {
        do {
            _ = try await makeIntent(.netPing, statistic: .average).perform()
            XCTFail("expected historyUnavailable")
        } catch let error as BlipIntentError {
            guard case .historyUnavailable = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testUnavailableMetricThrows() async {
        source.snapshot.battery.isPresent = false
        do {
            _ = try await makeIntent(.batteryLevel).perform()
            XCTFail("expected metricUnavailable")
        } catch let error as BlipIntentError {
            guard case .metricUnavailable = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testGetMinimumOverHistory() async throws {
        source.histories[.memoryUsage] = [55, 41, 62]
        let result = try await makeIntent(.memoryUsage, statistic: .minimum).perform()
        XCTAssertEqual(result.value, 41)
    }

    func testHistoryStatisticWithEmptyHistoryThrows() async {
        source.histories[.gpuUsage] = []
        do {
            _ = try await makeIntent(.gpuUsage, statistic: .average).perform()
            XCTFail("expected metricUnavailable")
        } catch let error as BlipIntentError {
            guard case .metricUnavailable = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testIntentErrorsHaveDescriptions() {
        let errors: [BlipIntentError] = [
            .appNotReady, .unknownMetric, .metricUnavailable("CPU"), .historyUnavailable("Ping"),
            .invalidHost("x y"), .volumeNotMounted("External"), .busy("busy"), .failed("nope"),
        ]
        for error in errors {
            XCTAssertFalse(String(localized: error.localizedStringResource).isEmpty)
        }
    }

    func testMissingSourceThrowsAppNotReady() async {
        AppIntentsEnvironment.metricSource = nil
        do {
            _ = try await makeIntent(.cpuUsage).perform()
            XCTFail("expected appNotReady")
        } catch let error as BlipIntentError {
            guard case .appNotReady = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
