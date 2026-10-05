import XCTest
#if os(iOS)
@testable import BlipMobile
#else
@testable import Blip
#endif

// The offline GeoIP reader parses a binary file downloaded from the internet, so besides
// resolving addresses correctly it must survive anything: truncated downloads, random
// bytes, corrupt pointers. Fixtures come from MMDBFixtureBuilder (an independent encoder).
// Compiled into both the macOS and iOS test bundles — the reader ships in both apps.

final class MMDBReaderTests: XCTestCase {

    func testLookupResolvesCityCountryAndLocation() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        let hit = try XCTUnwrap(reader.lookup("192.0.2.77"))
        XCTAssertEqual(hit.city, "Testville")
        XCTAssertEqual(hit.country, "United States", "English names are chosen")
        XCTAssertEqual(hit.countryCode, "US")
        XCTAssertEqual(hit.latitude, 37.5)
        XCTAssertEqual(hit.longitude, -122.25)
        XCTAssertEqual(reader.lookup("192.0.2.0"), hit, "network boundaries are inclusive")
        XCTAssertEqual(reader.lookup("192.0.2.255"), hit)
    }

    func testMetadataIsExposed() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        XCTAssertEqual(reader.databaseType, "Blip-Test-City")
        XCTAssertEqual(reader.buildEpoch, 1_759_276_800)
    }

    func testPointerToASharedRecordIsFollowed() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        let berlin = try XCTUnwrap(reader.lookup("198.51.100.5"))
        XCTAssertEqual(berlin.city, "Berlin")
        XCTAssertEqual(berlin.country, "Germany")
        XCTAssertEqual(berlin.countryCode, "DE")
        XCTAssertNil(reader.lookup("198.51.100.200"), "outside the /25")
    }

    func testRecordWithoutCityStillLocates() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        let hit = try XCTUnwrap(reader.lookup("203.0.113.100"))
        XCTAssertNil(hit.city)
        XCTAssertEqual(hit.countryCode, "JP")
    }

    func testIPv6Lookup() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        XCTAssertEqual(reader.lookup("2001:db8:1234:5::1")?.city, "Sixville")
        XCTAssertNil(reader.lookup("2001:db8:9999::1"))
    }

    func testMissesPrivateAndInvalidAddressesReturnNil() throws {
        let reader = try MMDBReader(data: MMDBFixtureBuilder.sample())
        for ip in ["10.0.0.1", "192.168.1.1", "127.0.0.1", "192.0.3.1", "::1",
                   "", "not-an-ip", "256.1.1.1", "1.2.3", "192.0.2.1; rm -rf /"] {
            XCTAssertNil(reader.lookup(ip), ip)
        }
    }

    func testEveryRecordSizeDecodesTheSameTree() throws {
        for size in [24, 28, 32] {
            let reader = try MMDBReader(data: MMDBFixtureBuilder.sample(recordSize: size))
            XCTAssertEqual(reader.lookup("192.0.2.9")?.city, "Testville", "record size \(size)")
            XCTAssertEqual(reader.lookup("2001:db8:1234::9")?.city, "Sixville", "record size \(size)")
            XCTAssertNil(reader.lookup("10.1.1.1"), "record size \(size)")
        }
    }

    func testIPv4OnlyDatabaseRejectsIPv6Lookups() throws {
        var b = MMDBFixtureBuilder()
        b.ipVersion = 4
        let rec = b.store(MMDBFixtureBuilder.cityRecord(city: "Fourville", country: "Canada", iso: "CA", lat: 45, lon: -75))
        b.insert("192.0.2.0/24", dataOffset: rec)
        let reader = try MMDBReader(data: b.build())
        XCTAssertEqual(reader.lookup("192.0.2.1")?.city, "Fourville")
        XCTAssertNil(reader.lookup("2001:db8::1"))
    }

    func testUnsupportedRecordSizeIsRejected() {
        var b = MMDBFixtureBuilder()
        b.recordSize = 16
        let rec = b.store(.string("x"))
        b.insert("192.0.2.0/24", dataOffset: rec)
        XCTAssertThrowsError(try MMDBReader(data: b.build())) { error in
            guard case MMDBReader.Error.unsupportedRecordSize = error else { return XCTFail("\(error)") }
        }
    }

    func testFilesWithoutMetadataAreUnreadable() {
        for data in [Data(), Data([0x00]), Data(repeating: 0xAB, count: 4096)] {
            XCTAssertThrowsError(try MMDBReader(data: data)) { error in
                guard case MMDBReader.Error.unreadable = error else { return XCTFail("\(error)") }
            }
        }
    }

    func testEveryTruncationThrowsOrDegradesWithoutCrashing() throws {
        let full = MMDBFixtureBuilder.sample()
        for length in 0..<full.count {
            let cut = full.prefix(length)
            if let reader = try? MMDBReader(data: cut) {
                // A cut inside the metadata can still parse; lookups must stay in bounds.
                _ = reader.lookup("192.0.2.1")
                _ = reader.lookup("2001:db8:1234::1")
            }
        }
    }

    func testCorruptBytesNeverCrashALookup() throws {
        let full = [UInt8](MMDBFixtureBuilder.sample())
        var rng = SplitMix64(seed: 0xB11B)
        for _ in 0..<400 {
            var bytes = full
            for _ in 0..<8 { bytes[Int(rng.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            if let reader = try? MMDBReader(data: Data(bytes)) {
                for ip in ["192.0.2.1", "198.51.100.1", "203.0.113.70", "2001:db8:1234::1", "8.8.8.8"] {
                    _ = reader.lookup(ip)
                }
            }
        }
    }

    func testRandomBytesWithAMetadataMarkerDoNotCrash() {
        var rng = SplitMix64(seed: 7)
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        for _ in 0..<200 {
            let junk = (0..<Int(rng.next() % 300)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let tail = (0..<Int(rng.next() % 64)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            if let reader = try? MMDBReader(data: Data(junk + marker + tail)) {
                _ = reader.lookup("1.1.1.1")
            }
        }
    }

    func testSelfReferencingPointerTerminates() throws {
        // A data record that is a pointer to itself: a naive decoder recurses forever.
        var b = MMDBFixtureBuilder()
        let selfRef = b.store(.pointer(0))
        b.insert("192.0.2.0/24", dataOffset: selfRef)
        let reader = try MMDBReader(data: b.build())
        XCTAssertNil(reader.lookup("192.0.2.1"))
    }

    func testNodeCountLargerThanTheFileIsRejected() {
        for claimed in [10_000, Int(UInt32.max)] {
            var b = MMDBFixtureBuilder()
            b.nodeCountOverride = claimed
            let rec = b.store(.string("x"))
            b.insert("192.0.2.0/24", dataOffset: rec)
            XCTAssertThrowsError(try MMDBReader(data: b.build()), "node_count \(claimed)") { error in
                guard case MMDBReader.Error.badMetadata = error else { return XCTFail("\(error)") }
            }
        }
    }
}

/// Deterministic PRNG for the fuzz loops (reproducible failures).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
