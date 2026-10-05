import XCTest
@testable import Blip

// The GeoIP database arrives as DB-IP's monthly `.mmdb.gz`. Gzip.inflate streams it to
// disk; the downloader probes month-tagged URLs newest first. Fixtures are produced with
// the system gzip so the inflater is checked against a real encoder.

final class GeoIPDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blip-geoip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// gzips `data` with /usr/bin/gzip. `keepName` stores the original file name (FNAME flag).
    private func gzip(_ data: Data, keepName: Bool) throws -> URL {
        let src = dir.appendingPathComponent("dbip-city-lite.mmdb")
        try data.write(to: src)
        let out = dir.appendingPathComponent("fixture-\(UUID().uuidString).gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = keepName ? ["-c", "-9", src.path] : ["-c", "-n", src.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let gz = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try gz.write(to: out)
        return out
    }

    func testInflateRoundTripsAnMMDBThatThenLoads() throws {
        let mmdb = MMDBFixtureBuilder.sample()
        for keepName in [true, false] {
            let gz = try gzip(mmdb, keepName: keepName)
            let dest = dir.appendingPathComponent("out-\(keepName).mmdb")
            try Gzip.inflate(gzFile: gz, to: dest)
            XCTAssertEqual(try Data(contentsOf: dest), mmdb, "FNAME=\(keepName)")
            XCTAssertEqual(try MMDBReader(url: dest).lookup("192.0.2.4")?.city, "Testville")
        }
    }

    func testInflateStreamsLargerThanOneBuffer() throws {
        // > 1 MiB output exercises the multi-chunk loop.
        var payload = Data(count: 3 << 20)
        payload.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: (i &* 2654435761) >> 7) }
        }
        let dest = dir.appendingPathComponent("big.bin")
        try Gzip.inflate(gzFile: try gzip(payload, keepName: true), to: dest)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testNonGzipInputIsRejected() throws {
        for bytes in [Data(), Data("PK\u{3}\u{4} definitely a zip".utf8), MMDBFixtureBuilder.sample()] {
            let file = dir.appendingPathComponent("plain-\(UUID().uuidString)")
            try bytes.write(to: file)
            XCTAssertThrowsError(try Gzip.inflate(gzFile: file, to: dir.appendingPathComponent("x"))) { error in
                XCTAssertEqual(error as? Gzip.Error, .notGzip)
            }
        }
    }

    func testMalformedHeaderIsRejectedNotOverread() throws {
        // FNAME set but never NUL-terminated: the header walk must stop at the data's end.
        var header: [UInt8] = [0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0x03]
        header += [UInt8](repeating: 0x41, count: 40)
        let file = dir.appendingPathComponent("bad-header.gz")
        try Data(header).write(to: file)
        XCTAssertThrowsError(try Gzip.inflate(gzFile: file, to: dir.appendingPathComponent("y"))) { error in
            XCTAssertEqual(error as? Gzip.Error, .notGzip)
        }

        // FEXTRA whose length runs past the end.
        let extra: [UInt8] = [0x1f, 0x8b, 0x08, 0x04, 0, 0, 0, 0, 0, 0x03, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 20)
        try Data(extra).write(to: file)
        XCTAssertThrowsError(try Gzip.inflate(gzFile: file, to: dir.appendingPathComponent("y")))
    }

    func testTruncatedDownloadFailsInsteadOfHanging() throws {
        let gz = try Data(contentsOf: try gzip(MMDBFixtureBuilder.sample(), keepName: false))
        let cut = dir.appendingPathComponent("cut.gz")
        try gz.prefix(gz.count / 2).write(to: cut)
        let dest = dir.appendingPathComponent("cut.mmdb")
        // Either the inflater notices, or the half file fails MMDB validation — never a
        // silently "installed" partial database.
        do {
            try Gzip.inflate(gzFile: cut, to: dest)
            XCTAssertThrowsError(try MMDBReader(url: dest))
        } catch {
            XCTAssertEqual(error as? Gzip.Error, .inflateFailed)
        }
    }

    @MainActor
    func testCandidateMonthsAreNewestFirstAndCrossYearBoundaries() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let feb = cal.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 12))!
        let months = GeoIPDatabase.candidateMonths(now: feb)
        XCTAssertEqual(months.map(\.tag), ["2026-02", "2026-01", "2025-12", "2025-11"])
        XCTAssertEqual(months.first?.url.absoluteString,
                       "https://download.db-ip.com/free/dbip-city-lite-2026-02.mmdb.gz")
        XCTAssertTrue(months.allSatisfy { $0.url.scheme == "https" }, "the database is only fetched over TLS")
    }
}
