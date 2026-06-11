import XCTest
@testable import Blip

@MainActor
final class SpeedTestIntentTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = Fixtures.scratchDefaults("speedtest")
        AppIntentsEnvironment.defaults = defaults
        AppIntentsEnvironment.volumesProvider = {
            [
                VolumeInfo(name: "Macintosh HD", mountPoint: "/", totalBytes: 1_000_000_000_000, freeBytes: 250_000_000_000),
                VolumeInfo(name: "External", mountPoint: "/Volumes/External", totalBytes: 4_000_000_000_000, freeBytes: 1_000_000_000_000),
            ]
        }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "com.blainemiller.BlipTests.speedtest")
        AppIntentsEnvironment.defaults = .standard
        AppIntentsEnvironment.volumesProvider = { DiskMonitor.readVolumes() }
        AppIntentsEnvironment.networkSpeedRunner = nil
        AppIntentsEnvironment.diskSpeedRunner = { size, mountPoint in
            try await IntentDiskSpeedRunner.run(size: size, mountPoint: mountPoint)
        }
    }

    // MARK: Volume entity query

    func testVolumeQueryListsMountedVolumes() async throws {
        let entities = try await VolumeEntityQuery().suggestedEntities()
        XCTAssertEqual(entities.map(\.id), ["/", "/Volumes/External"])
        XCTAssertEqual(entities.first?.name, "Macintosh HD")
    }

    func testVolumeQueryResolvesAndDropsUnmounted() async throws {
        let entities = try await VolumeEntityQuery().entities(for: ["/Volumes/External", "/Volumes/Gone"])
        XCTAssertEqual(entities.map(\.id), ["/Volumes/External"])
    }

    func testVolumeQueryMatchesByName() async throws {
        let entities = try await VolumeEntityQuery().entities(matching: "extern")
        XCTAssertEqual(entities.map(\.id), ["/Volumes/External"])
    }

    func testVolumeQueryDefaultsToRoot() async {
        let entity = await VolumeEntityQuery().defaultResult()
        XCTAssertEqual(entity?.id, "/")
    }

    // MARK: Size mapping

    func testBenchmarkSizeMapping() {
        XCTAssertEqual(DiskBenchmarkSizeOption.small.benchmarkSize, .small)
        XCTAssertEqual(DiskBenchmarkSizeOption.medium.benchmarkSize, .medium)
        XCTAssertEqual(DiskBenchmarkSizeOption.large.benchmarkSize, .large)
        XCTAssertEqual(DiskBenchmark.Size.large.bytes, 1_024_000_000)
    }

    // MARK: Drive speed test intent

    private func makeDriveIntent(mountPoint: String, name: String) -> RunDriveSpeedTestIntent {
        let intent = RunDriveSpeedTestIntent()
        var volume = VolumeInfo(name: name, mountPoint: mountPoint, totalBytes: 1, freeBytes: 1)
        if let live = AppIntentsEnvironment.volumesProvider().first(where: { $0.mountPoint == mountPoint }) {
            volume = live
        }
        intent.volume = VolumeEntity(volume: volume)
        intent.size = .small
        return intent
    }

    func testDriveSpeedTestRunsMockedBenchmark() async throws {
        var requested: (size: DiskBenchmark.Size, mountPoint: String)?
        AppIntentsEnvironment.diskSpeedRunner = { size, mountPoint in
            requested = (size, mountPoint)
            return DiskSpeedResult(writeMBps: 2_842, readMBps: 3_105, randomReadIOPS: 24_000, timestamp: Date())
        }

        let result = try await makeDriveIntent(mountPoint: "/Volumes/External", name: "External").perform()
        XCTAssertEqual(requested?.size, .small)
        XCTAssertEqual(requested?.mountPoint, "/Volumes/External")
        XCTAssertTrue(result.value!.contains("write 2842 MB/s"))
        XCTAssertTrue(result.value!.contains("External"))
    }

    func testDriveSpeedTestRejectsUnmountedVolume() async {
        AppIntentsEnvironment.diskSpeedRunner = { _, _ in
            XCTFail("runner must not be called for an unmounted volume")
            return DiskSpeedResult(writeMBps: 0, readMBps: 0, randomReadIOPS: nil, timestamp: Date())
        }
        do {
            _ = try await makeDriveIntent(mountPoint: "/Volumes/Gone", name: "Gone").perform()
            XCTFail("expected volumeNotMounted")
        } catch let error as BlipIntentError {
            guard case .volumeNotMounted = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testDriveSpeedTestSurfacesBusyError() async {
        AppIntentsEnvironment.diskSpeedRunner = { _, _ in
            throw SpeedTestRunFailure(message: "A disk speed test is already running.")
        }
        do {
            _ = try await makeDriveIntent(mountPoint: "/", name: "Macintosh HD").perform()
            XCTFail("expected busy")
        } catch let error as BlipIntentError {
            guard case .busy = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: Network provider resolution (pure)

    func testProviderResolution() {
        typealias R = NetworkSpeedProviderResolver

        XCTAssertEqual(R.resolve(choice: .publicOpenSpeedTest, storedKind: "selfhosted", storedURL: "http://x"),
                       .server(.openSpeedTestPublic))

        XCTAssertEqual(R.resolve(choice: .selfHosted, storedKind: nil, storedURL: "192.168.1.50:3000"),
                       .server(.openSpeedTest(baseURL: "192.168.1.50:3000")))

        XCTAssertEqual(R.resolve(choice: .selfHosted, storedKind: nil, storedURL: "   "),
                       .missingURL)
        XCTAssertEqual(R.resolve(choice: .selfHosted, storedKind: nil, storedURL: nil),
                       .missingURL)

        XCTAssertEqual(R.resolve(choice: .appSetting, storedKind: "selfhosted", storedURL: "http://lan:3000"),
                       .server(.openSpeedTest(baseURL: "http://lan:3000")))
        XCTAssertEqual(R.resolve(choice: .appSetting, storedKind: "selfhosted", storedURL: ""),
                       .missingURL)
        XCTAssertEqual(R.resolve(choice: .appSetting, storedKind: "public", storedURL: nil),
                       .server(.openSpeedTestPublic))
        XCTAssertEqual(R.resolve(choice: .appSetting, storedKind: nil, storedURL: nil),
                       .server(.openSpeedTestPublic))
    }

    func testServerURLNormalization() {
        XCTAssertEqual(SpeedTestServer.openSpeedTest(baseURL: "192.168.1.50:3000").openSpeedTestBase,
                       "http://192.168.1.50:3000")
        XCTAssertEqual(SpeedTestServer.openSpeedTest(baseURL: " https://speed.lan/ ").openSpeedTestBase,
                       "https://speed.lan")
        XCTAssertEqual(SpeedTestServer.openSpeedTest(baseURL: "http://lan:3000///").openSpeedTestBase,
                       "http://lan:3000")
        XCTAssertNil(SpeedTestServer.openSpeedTest(baseURL: "").openSpeedTestBase)
        XCTAssertNil(SpeedTestServer.openSpeedTestPublic.openSpeedTestBase)
    }

    // MARK: Network speed test intent

    private func makeNetworkIntent(_ provider: NetworkSpeedProvider) -> RunNetworkSpeedTestIntent {
        let intent = RunNetworkSpeedTestIntent()
        intent.provider = provider
        return intent
    }

    func testNetworkSpeedTestUsesResolvedServer() async throws {
        defaults.set("selfhosted", forKey: "speedTestServerKind")
        defaults.set("http://192.168.1.50:3000", forKey: "speedTestOpenSpeedTestURL")

        var requested: SpeedTestServer?
        AppIntentsEnvironment.networkSpeedRunner = { server in
            requested = server
            return NetSpeedResult(downMbps: 940.5, upMbps: 880.25, timestamp: Date())
        }

        let result = try await makeNetworkIntent(.appSetting).perform()
        XCTAssertEqual(requested, .openSpeedTest(baseURL: "http://192.168.1.50:3000"))
        XCTAssertTrue(result.value!.contains("down 940.5 Mbps"))
        XCTAssertTrue(result.value!.contains("up 880.2 Mbps"))
    }

    func testNetworkSpeedTestMissingSelfHostedURLThrows() async {
        AppIntentsEnvironment.networkSpeedRunner = { _ in
            XCTFail("runner must not be called without a configured URL")
            return NetSpeedResult(downMbps: 0, upMbps: nil, timestamp: Date())
        }
        do {
            _ = try await makeNetworkIntent(.selfHosted).perform()
            XCTFail("expected failure")
        } catch let error as BlipIntentError {
            guard case .failed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testNetworkSpeedTestPropagatesRunFailure() async {
        AppIntentsEnvironment.networkSpeedRunner = { _ in
            throw SpeedTestRunFailure(message: "The speed test timed out.")
        }
        do {
            _ = try await makeNetworkIntent(.publicOpenSpeedTest).perform()
            XCTFail("expected failure")
        } catch let error as BlipIntentError {
            guard case .failed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: Summaries (pure)

    func testSummaries() {
        let disk = DiskSpeedResult(writeMBps: 2_842.4, readMBps: 3_104.6, randomReadIOPS: 23_950.7, timestamp: Date())
        XCTAssertEqual(SpeedTestSummary.disk(disk, volumeName: "Macintosh HD", sizeLabel: "512 MB"),
                       "Macintosh HD (512 MB): write 2842 MB/s, read 3105 MB/s, 23951 random-read IOPS")

        let diskNoIOPS = DiskSpeedResult(writeMBps: 100, readMBps: 200, randomReadIOPS: nil, timestamp: Date())
        XCTAssertEqual(SpeedTestSummary.disk(diskNoIOPS, volumeName: "External", sizeLabel: "128 MB"),
                       "External (128 MB): write 100 MB/s, read 200 MB/s")

        let net = NetSpeedResult(downMbps: 940.55, upMbps: 880.21, timestamp: Date())
        XCTAssertEqual(SpeedTestSummary.network(net, serverName: "Self-hosted"),
                       "Self-hosted: down 940.5 Mbps, up 880.2 Mbps")

        let downOnly = NetSpeedResult(downMbps: 250, upMbps: nil, timestamp: Date())
        XCTAssertEqual(SpeedTestSummary.network(downOnly, serverName: "OpenSpeedTest (public)"),
                       "OpenSpeedTest (public): down 250.0 Mbps")
    }

    // MARK: DiskSpeedTester recording

    func testDiskSpeedTesterRecordKeepsBoundedHistory() {
        let tester = DiskSpeedTester()
        for i in 0..<12 {
            tester.record(DiskSpeedResult(writeMBps: Double(i), readMBps: 0, randomReadIOPS: nil, timestamp: Date()))
        }
        XCTAssertEqual(tester.history.count, 10)
        XCTAssertEqual(tester.lastResult?.writeMBps, 11)
        XCTAssertEqual(tester.history.first?.writeMBps, 2)
    }
}
