import XCTest
import Combine
@testable import Blip

// The offline GeoIP database lifecycle: load an installed file, report a corrupt one, remove
// it, and download + gunzip + validate + install the monthly file — here against a loopback
// server (no DB-IP traffic) with the database location and defaults pointed at scratch space,
// so the owner's real Application Support database and preferences are never touched.

@MainActor
final class GeoIPDatabaseTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL!
    private var suite: String!
    private var scratch: UserDefaults!
    private var servers: [StaticFileServer] = []
    private var bag = Set<AnyCancellable>()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-geoipdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("dbip-city.mmdb")
        suite = "blip-geoipdb-\(UUID().uuidString)"
        scratch = UserDefaults(suiteName: suite)
        GeoIPDatabase.fileURLOverride = dbURL
        GeoIPDatabase.defaults = scratch
        GeoIPDatabase.candidatesOverride = nil
    }

    override func tearDown() async throws {
        GeoIPDatabase.fileURLOverride = nil
        GeoIPDatabase.defaults = .standard
        GeoIPDatabase.candidatesOverride = nil
        servers.forEach { $0.stop() }
        servers = []
        bag.removeAll()
        scratch.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    private func gzip(_ data: Data) throws -> Data {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString).mmdb")
        try data.write(to: src)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", "-n", src.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return out
    }

    private func serve(_ files: [String: Data]) throws -> StaticFileServer {
        let s = try StaticFileServer(files: files)
        servers.append(s)
        return s
    }

    private func installFixture() throws {
        try MMDBFixtureBuilder.sample().write(to: dbURL)
    }

    /// Fulfils when `condition` holds for a status published by `db`.
    private func waitForStatus(_ db: GeoIPDatabase, timeout: TimeInterval = 30,
                               _ condition: @escaping (GeoIPDatabase.Status) -> Bool) async {
        let done = expectation(description: "status")
        done.assertForOverFulfill = false
        db.$status.sink { if condition($0) { done.fulfill() } }.store(in: &bag)
        await fulfillment(of: [done], timeout: timeout)
    }

    private func month(ofEpoch e: UInt64) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(e)))
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: loading

    func testNoFileMeansAbsentAndNothingToLookUp() {
        let db = GeoIPDatabase()
        XCTAssertEqual(db.status, .absent)
        XCTAssertFalse(db.isReady)
        XCTAssertNil(db.lookup("192.0.2.4"))
        XCTAssertNil(db.installedMonth)
        XCTAssertEqual(GeoIPDatabase.attribution, "IP geolocation by DB-IP")
    }

    func testInstalledFileLoadsAndBackfillsTheInstalledMonthTag() throws {
        try installFixture()
        let db = GeoIPDatabase()
        guard case let .ready(date, type) = db.status else { return XCTFail("\(db.status)") }
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_759_276_800))
        XCTAssertFalse(type.isEmpty)
        XCTAssertTrue(db.isReady)
        XCTAssertEqual(db.lookup("192.0.2.4")?.city, "Testville")
        XCTAssertEqual(db.installedMonth, month(ofEpoch: 1_759_276_800))

        // An existing tag is never overwritten by a reload.
        scratch.set("2031-04", forKey: "geoipInstalledMonth")
        db.loadIfPresent()
        XCTAssertEqual(db.installedMonth, "2031-04")
    }

    func testCorruptFileIsReportedAsUnreadable() throws {
        try Data("definitely not an mmdb".utf8).write(to: dbURL)
        let db = GeoIPDatabase()
        guard case let .failed(message) = db.status else { return XCTFail("\(db.status)") }
        XCTAssertTrue(message.contains("unreadable"), message)
        XCTAssertFalse(db.isReady)
        XCTAssertNil(db.lookup("192.0.2.4"))
    }

    func testRemoveDeletesTheFileAndForgetsTheInstall() throws {
        try installFixture()
        let db = GeoIPDatabase()
        XCTAssertTrue(db.isReady)
        db.remove()
        XCTAssertEqual(db.status, .absent)
        XCTAssertFalse(db.isReady)
        XCTAssertNil(db.installedMonth)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertNil(db.lookup("192.0.2.4"))
    }

    // MARK: download

    func testDownloadFallsBackPastAnUnpublishedMonthThenInstalls() async throws {
        let gz = try gzip(MMDBFixtureBuilder.sample())
        let server = try serve(["/free/dbip-city-lite-2099-01.mmdb.gz": gz])
        GeoIPDatabase.candidatesOverride = [
            (tag: "2099-02", url: server.baseURL("/free/dbip-city-lite-2099-02.mmdb.gz")),   // 404: not published yet
            (tag: "2099-01", url: server.baseURL("/free/dbip-city-lite-2099-01.mmdb.gz")),
        ]
        let db = GeoIPDatabase()
        XCTAssertEqual(db.status, .absent)

        var sawDownloading = false
        db.$status.sink { if case .downloading = $0 { sawDownloading = true } }.store(in: &bag)
        db.download()
        db.download()                                       // a second request while one runs is ignored
        await waitForStatus(db) { if case .ready = $0 { return true } else { return false } }

        XCTAssertTrue(sawDownloading)
        XCTAssertEqual(db.installedMonth, "2099-01", "the newest PUBLISHED month is recorded")
        XCTAssertNotNil(scratch.object(forKey: "geoipLastUpdateCheck"))
        XCTAssertEqual(db.lookup("198.51.100.1")?.city, "Berlin")
        XCTAssertEqual(try Data(contentsOf: dbURL), MMDBFixtureBuilder.sample())
        XCTAssertEqual(server.requests, ["GET /free/dbip-city-lite-2099-02.mmdb.gz",
                                         "GET /free/dbip-city-lite-2099-01.mmdb.gz"])
    }

    func testEveryMonthMissingFailsWithAMessageAndLeavesTheOldDatabase() async throws {
        try installFixture()
        let before = try Data(contentsOf: dbURL)
        let server = try serve([:])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: server.baseURL("/none.gz"))]
        let db = GeoIPDatabase()
        db.download()
        await waitForStatus(db) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(db.status, .failed("Download failed."))
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }

    func testAGarbageDownloadIsRejectedBeforeItReplacesAnything() async throws {
        try installFixture()
        let before = try Data(contentsOf: dbURL)
        let server = try serve(["/bad.gz": Data("<html>captive portal</html>".utf8)])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: server.baseURL("/bad.gz"))]
        let db = GeoIPDatabase()
        db.download()
        await waitForStatus(db) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(db.status, .failed("Download failed."))
        XCTAssertEqual(try Data(contentsOf: dbURL), before, "the working database survives a bad download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.appendingPathExtension("tmp").path))
    }

    func testAGzipThatIsNotAnMMDBIsRejectedByValidation() async throws {
        let server = try serve(["/junk.gz": try gzip(Data("gzip of junk, not a database".utf8))])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: server.baseURL("/junk.gz"))]
        let db = GeoIPDatabase()
        db.download()
        await waitForStatus(db) { if case .failed = $0 { return true } else { return false } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertFalse(db.isReady)
    }

    func testAnUnreachableServerReadsAsNoInternet() async throws {
        let dead = try StaticFileServer(files: [:])
        let url = dead.baseURL("/x.gz")
        dead.stop()                                         // the port now refuses connections
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: url)]
        let db = GeoIPDatabase()
        db.download()
        await waitForStatus(db) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(db.status, .failed("No internet connection."))
    }

    // MARK: auto-update

    func testAutoUpdateIsOffByDefaultAndNeedsAnInstalledDatabase() throws {
        let server = try serve([:])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: server.baseURL("/x.gz"))]
        let absent = GeoIPDatabase()
        scratch.set(true, forKey: "geoipAutoUpdate")
        absent.runAutoUpdateCheck(force: true)              // nothing installed: nothing to refresh
        XCTAssertEqual(absent.status, .absent)

        try installFixture()
        scratch.set(false, forKey: "geoipAutoUpdate")
        let ready = GeoIPDatabase()
        ready.runAutoUpdateCheck()                          // toggle off, no force
        XCTAssertNil(scratch.object(forKey: "geoipLastUpdateCheck"))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAutoUpdateIsThrottledToOncePerDay() throws {
        try installFixture()
        let server = try serve([:])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-01", url: server.baseURL("/x.gz"))]
        scratch.set(true, forKey: "geoipAutoUpdate")
        let recent = Date().addingTimeInterval(-3600)
        scratch.set(recent, forKey: "geoipLastUpdateCheck")
        let db = GeoIPDatabase()
        db.runAutoUpdateCheck()
        XCTAssertEqual(scratch.object(forKey: "geoipLastUpdateCheck") as? Date, recent, "checked an hour ago: skipped")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAutoUpdateDownloadsWhenANewerMonthIsPublished() async throws {
        try installFixture()
        scratch.set("2020-01", forKey: "geoipInstalledMonth")
        scratch.set(true, forKey: "geoipAutoUpdate")
        let gz = try gzip(MMDBFixtureBuilder.sample())
        let server = try serve(["/dbip-2099-02.gz": gz])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-02", url: server.baseURL("/dbip-2099-02.gz"))]
        let db = GeoIPDatabase()
        db.runAutoUpdateCheck()
        await waitForStatus(db) { [scratch] _ in scratch?.string(forKey: "geoipInstalledMonth") == "2099-02" }
        XCTAssertEqual(server.requests.first, "HEAD /dbip-2099-02.gz", "probes with HEAD before downloading")
        XCTAssertTrue(server.requests.contains("GET /dbip-2099-02.gz"))
    }

    func testAutoUpdateStaysPutWhenAlreadyCurrent() async throws {
        try installFixture()
        scratch.set("2099-02", forKey: "geoipInstalledMonth")
        let server = try serve(["/dbip-2099-02.gz": Data("x".utf8)])
        GeoIPDatabase.candidatesOverride = [(tag: "2099-02", url: server.baseURL("/dbip-2099-02.gz"))]
        let db = GeoIPDatabase()
        db.runAutoUpdateCheck(force: true)
        let probed = NSPredicate { _, _ in server.requests.contains("HEAD /dbip-2099-02.gz") }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: probed, object: nil)], timeout: 30)
        XCTAssertFalse(server.requests.contains("GET /dbip-2099-02.gz"))
        XCTAssertEqual(scratch.string(forKey: "geoipInstalledMonth"), "2099-02")
    }

    func testCancelDownloadIsSafeWhenIdle() {
        let db = GeoIPDatabase()
        db.cancelDownload()
        XCTAssertEqual(db.status, .absent)
    }
}
