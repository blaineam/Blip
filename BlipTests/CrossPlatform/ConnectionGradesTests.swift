import XCTest
#if os(iOS)
@testable import BlipMobile
#else
@testable import Blip
#endif

// "What can this connection do?" grades, shown after every speed test and in share text on
// both platforms. Thresholds are the published service requirements; these pin each
// boundary and the latency-under-load caps that separate interactive from bulk use.

final class ConnectionGradesTests: XCTestCase {
    private func grades(down: Double, up: Double? = 1_000, idle: Double? = 10, loaded: Double? = 20) -> [String: CategoryGrade.Grade] {
        Dictionary(uniqueKeysWithValues: ConnectionGrades.evaluate(down: down, up: up, unloadedMs: idle, loadedMs: loaded)
            .map { ($0.id, $0.grade) })
    }

    func testCategoriesAreStableAndOrdered() {
        let ids = ConnectionGrades.evaluate(down: 100, up: 100, unloadedMs: 5, loadedMs: 10).map(\.id)
        XCTAssertEqual(ids, ["browse", "hd", "4k", "calls", "gaming", "uploads"])
    }

    func testDownloadThresholdBoundaries() {
        // (category, A, B, C) thresholds in Mbps — exactly at a threshold earns that grade.
        let table: [(String, Double, Double, Double)] = [
            ("browse", 25, 10, 3), ("hd", 15, 8, 5), ("4k", 50, 25, 15), ("gaming", 45, 25, 10),
        ]
        for (id, a, b, c) in table {
            XCTAssertEqual(grades(down: a)[id], .a, "\(id) at A")
            XCTAssertEqual(grades(down: a - 0.01)[id], .b, "\(id) just under A")
            XCTAssertEqual(grades(down: b)[id], .b, "\(id) at B")
            XCTAssertEqual(grades(down: b - 0.01)[id], .c, "\(id) just under B")
            XCTAssertEqual(grades(down: c)[id], .c, "\(id) at C")
            XCTAssertEqual(grades(down: c - 0.01)[id], .f, "\(id) just under C")
        }
    }

    func testUploadThresholds() {
        XCTAssertEqual(grades(down: 1_000, up: 100)["uploads"], .a)
        XCTAssertEqual(grades(down: 1_000, up: 99)["uploads"], .b)
        XCTAssertEqual(grades(down: 1_000, up: 30)["uploads"], .b)
        XCTAssertEqual(grades(down: 1_000, up: 10)["uploads"], .c)
        XCTAssertEqual(grades(down: 1_000, up: 9.9)["uploads"], .f)
    }

    func testMissingUploadFailsUploadsAndCalls() {
        let g = grades(down: 1_000, up: nil)
        XCTAssertEqual(g["uploads"], .f, "a download-only result can't vouch for uploads")
        XCTAssertEqual(g["calls"], .f, "calls need both directions")
        XCTAssertEqual(g["browse"], .a)
    }

    func testCallsTakeTheWorseDirection() {
        XCTAssertEqual(grades(down: 1_000, up: 5)["calls"], .a)
        XCTAssertEqual(grades(down: 1_000, up: 2.5)["calls"], .b)
        XCTAssertEqual(grades(down: 1.5, up: 1_000)["calls"], .c)
        XCTAssertEqual(grades(down: 1_000, up: 0.9)["calls"], .f)
    }

    func testUnmeasuredLatencyCapsInteractiveGradesAtB() {
        let g = grades(down: 1_000, up: 1_000, idle: nil, loaded: nil)
        XCTAssertEqual(g["calls"], .b)
        XCTAssertEqual(g["gaming"], .b)
        XCTAssertEqual(g["4k"], .a, "bulk categories don't care about latency")
    }

    func testBufferbloatCaps() {
        XCTAssertEqual(grades(down: 1_000, idle: 60, loaded: 150)["gaming"], .a, "150 ms loaded (bloat 90) is still fine")
        XCTAssertEqual(grades(down: 1_000, idle: 60, loaded: 151)["gaming"], .c)
        XCTAssertEqual(grades(down: 1_000, idle: 100, loaded: 300)["calls"], .c)
        XCTAssertEqual(grades(down: 1_000, idle: 100, loaded: 301)["calls"], .f)
        XCTAssertEqual(grades(down: 1_000, idle: 10, loaded: 150)["gaming"], .c, "bloat 140 caps even under 150 ms")
        // Bloat (loaded − idle) caps even when the loaded figure alone looks fine.
        XCTAssertEqual(grades(down: 1_000, idle: 5, loaded: 110)["gaming"], .c, "bloat 105 > 100")
        XCTAssertEqual(grades(down: 1_000, idle: 5, loaded: 105)["gaming"], .a, "bloat exactly 100")
        XCTAssertEqual(grades(down: 1_000, idle: nil, loaded: 260)["gaming"], .f, "unknown idle → bloat = loaded")
        // A cap never raises a grade.
        XCTAssertEqual(grades(down: 12, idle: 10, loaded: 151)["gaming"], .c)
        XCTAssertEqual(grades(down: 5, idle: 10, loaded: 151)["gaming"], .f)
    }

    func testGradeOrdering() {
        XCTAssertLessThan(CategoryGrade.Grade.f, .c)
        XCTAssertLessThan(CategoryGrade.Grade.c, .b)
        XCTAssertLessThan(CategoryGrade.Grade.b, .a)
        XCTAssertEqual(min(CategoryGrade.Grade.a, .c), .c)
    }

    func testShareLinesFormat() {
        let all = ConnectionGrades.evaluate(down: 1_000, up: 1_000, unloadedMs: 5, loadedMs: 10)
        let line = ConnectionGrades.shareLines(all)
        let parts = line.components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 6)
        XCTAssertTrue(parts.allSatisfy { $0.hasPrefix("A ") }, line)
        XCTAssertEqual(parts.first, "A \(all[0].name)")
    }
}
