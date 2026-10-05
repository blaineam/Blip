import XCTest
@testable import Blip

// Dismissing a recommendation hides it for 24 h, survives a relaunch (persisted to
// defaults), and "Reset dismissed" brings everything back.

@MainActor
final class RecommendationDismissalTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = Fixtures.scratchDefaults("recs")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: "com.blainemiller.BlipTests.recs")
    }

    private func diskFullSnapshot() -> SystemSnapshot {
        var s = Fixtures.snapshot()
        s.disk.volumes[0] = VolumeInfo(name: "Macintosh HD", mountPoint: "/", totalBytes: 1_000, freeBytes: 50)
        s.memory.pressureLevel = 2
        return s
    }

    private func monitor(at time: Date) -> SystemMonitor {
        let m = SystemMonitor(defaults: defaults)
        m.now = { time }
        m.snapshot = diskFullSnapshot()
        return m
    }

    func testDismissHidesOnlyThatRecommendationAndPersists() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let m = monitor(at: t0)
        m.dismissRecommendation("disk-full")
        let ids = m.recommendations.map(\.id)
        XCTAssertFalse(ids.contains("disk-full"))
        XCTAssertTrue(ids.contains("mem-pressure"), "other recommendations stay")

        // A relaunch (new monitor, same defaults) still hides it.
        let relaunched = monitor(at: t0.addingTimeInterval(3_600))
        relaunched.dismissRecommendation("unrelated")   // forces a recompute
        XCTAssertFalse(relaunched.recommendations.map(\.id).contains("disk-full"))
    }

    func testDismissalExpiresAfter24Hours() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        monitor(at: t0).dismissRecommendation("disk-full")
        let later = monitor(at: t0.addingTimeInterval(86_401))
        later.dismissRecommendation("unrelated")
        XCTAssertTrue(later.recommendations.map(\.id).contains("disk-full"), "re-surfaces after a day")
    }

    func testResetBringsEverythingBackAndClearsStorage() {
        let m = monitor(at: Date(timeIntervalSince1970: 1_800_000_000))
        m.dismissRecommendation("disk-full")
        m.dismissRecommendation("mem-pressure")
        XCTAssertNotNil(defaults.dictionary(forKey: "dismissedRecs"))
        m.resetDismissedRecommendations()
        XCTAssertNil(defaults.dictionary(forKey: "dismissedRecs"))
        XCTAssertTrue(Set(m.recommendations.map(\.id)).isSuperset(of: ["disk-full", "mem-pressure"]))
    }
}
