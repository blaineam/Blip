import XCTest
@testable import Blip

// MTR-style traceroute statistics, shared by the direct build's in-process runner and Blip
// Helper. Lines are real `traceroute -n -q 1` output shapes.

final class TraceParsingTests: XCTestCase {

    func testParsesHopLineShapes() {
        XCTAssertEqual(TraceHopLine.parse(" 1  192.168.1.1  1.234 ms"),
                       TraceHopLine(hop: 1, host: "192.168.1.1", rttMs: 1.234))
        XCTAssertEqual(TraceHopLine.parse("12  *"), TraceHopLine(hop: 12, host: nil, rttMs: nil))
        XCTAssertEqual(TraceHopLine.parse("\t3\t10.0.0.1\t0.5 ms"), TraceHopLine(hop: 3, host: "10.0.0.1", rttMs: 0.5))
        // Several probes per line: the last RTT wins, the first responder is kept.
        XCTAssertEqual(TraceHopLine.parse(" 4  198.51.100.1  9.1 ms  8.2 ms  7.3 ms"),
                       TraceHopLine(hop: 4, host: "198.51.100.1", rttMs: 7.3))
        // Unreachable annotations don't replace the host.
        XCTAssertEqual(TraceHopLine.parse(" 6  203.0.113.9  12.0 ms !H"),
                       TraceHopLine(hop: 6, host: "203.0.113.9", rttMs: 12.0))
        XCTAssertEqual(TraceHopLine.parse(" 2  2001:db8::1  3.5 ms")?.host, "2001:db8::1")
    }

    func testIgnoresNonHopLines() {
        XCTAssertNil(TraceHopLine.parse("traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 52 byte packets"))
        XCTAssertNil(TraceHopLine.parse(""))
        XCTAssertNil(TraceHopLine.parse("    "))
        XCTAssertNil(TraceHopLine.parse("garbage line"))
    }

    func testAccumulatesLossAndLatencyAcrossPasses() throws {
        var acc = TraceHopAccumulator()
        acc.ingest(output: """
        traceroute to 1.1.1.1 (1.1.1.1), 30 hops max, 52 byte packets
         1  192.168.1.1  2.0 ms
         2  *
         3  1.1.1.1  10.0 ms
        """)
        acc.ingest(output: """
         1  192.168.1.1  4.0 ms
         2  10.0.0.1  20.0 ms
         3  1.1.1.1  14.0 ms
        """)
        acc.ingest(output: """
         1  192.168.1.1  3.0 ms
         2  *
         3  *
        """)
        let hops = acc.snapshot()
        XCTAssertEqual(hops.map(\.hop), [1, 2, 3], "sorted by hop")

        let h1 = hops[0]
        XCTAssertEqual(h1.sent, 3)
        XCTAssertEqual(h1.recv, 3)
        XCTAssertEqual(h1.lossPct, 0)
        XCTAssertEqual(try XCTUnwrap(h1.avgMs), 3.0, accuracy: 1e-9)
        XCTAssertEqual(h1.bestMs, 2.0)
        XCTAssertEqual(h1.worstMs, 4.0)
        XCTAssertEqual(h1.lastMs, 3.0)

        let h2 = hops[1]
        XCTAssertEqual(h2.host, "10.0.0.1", "a later answer names a hop that timed out first")
        XCTAssertEqual(h2.sent, 3)
        XCTAssertEqual(h2.recv, 1)
        XCTAssertEqual(h2.lossPct, 200.0 / 3, accuracy: 1e-9)

        let h3 = hops[2]
        XCTAssertEqual(h3.lastMs, 14.0, "a timeout doesn't erase the last good RTT")
        XCTAssertEqual(h3.lossPct, 100.0 / 3, accuracy: 1e-9)
    }

    func testAllTimeoutsHopHasNoLatency() {
        var acc = TraceHopAccumulator()
        acc.ingest(line: " 7  *")
        acc.ingest(line: " 7  *")
        let hop = acc.snapshot()[0]
        XCTAssertEqual(hop.host, "*")
        XCTAssertEqual(hop.lossPct, 100)
        XCTAssertNil(hop.avgMs)
        XCTAssertNil(hop.bestMs)
    }

    func testRemoveAllClearsState() {
        var acc = TraceHopAccumulator()
        acc.ingest(line: " 1  192.168.1.1  2.0 ms")
        XCTAssertFalse(acc.isEmpty)
        acc.removeAll()
        XCTAssertTrue(acc.isEmpty)
        XCTAssertEqual(acc.snapshot().count, 0)
    }

    func testHostValidationRejectsInjectionShapes() {
        for good in ["1.1.1.1", "example.com", "a-b.example", "2001:db8::1", "::1", "localhost"] {
            XCTAssertTrue(HostValidation.isValid(good), good)
        }
        for bad in ["", "a b", "1.1.1.1;id", "$(id)", "`id`", "host|x", "host&", "host\n", "x/y",
                    String(repeating: "a", count: 254)] {
            XCTAssertFalse(HostValidation.isValid(bad), bad)
        }
    }

    func testHostValidationRejectsOptionLookingHosts() {
        // Passed as the last argv element to /usr/sbin/traceroute: a leading "-" would be
        // parsed as an option (e.g. "-ien0", "-g1.2.3.4") instead of a destination.
        for bad in ["-n", "-ien0", "-g192.0.2.1", "--help", "-"] {
            XCTAssertFalse(HostValidation.isValid(bad), bad)
        }
    }

    #if !APPSTORE
    func testLocalRunnerRefusesInvalidHosts() {
        let runner = LocalTraceRunner()
        runner.start(host: "1.1.1.1; rm -rf ~")
        XCTAssertFalse(runner.snapshot().running, "an invalid host never spawns traceroute")
        XCTAssertTrue(runner.snapshot().hops.isEmpty)
    }
    #endif
}
