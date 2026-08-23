import SwiftUI

// "What can this connection actually do, reliably?" — per-category grades computed from
// measured down/up throughput and unloaded/loaded latency. Thresholds are the published
// service requirements (with headroom), not vibes: a grade says "this activity works with
// margin", "works", "struggles", or "won't". Latency-under-load (bufferbloat) is what
// separates a connection that benchmarks well from one that video-calls well — it's
// weighted wherever interactivity matters.

struct CategoryGrade: Identifiable {
    enum Grade: String, Comparable {
        case a = "A", b = "B", c = "C", f = "F"
        static func < (l: Grade, r: Grade) -> Bool { l.rank < r.rank }
        var rank: Int { ["F": 0, "C": 1, "B": 2, "A": 3][rawValue]! }
        var tint: Color {
            switch self { case .a: return .green; case .b: return .mint; case .c: return .orange; case .f: return .red }
        }
        var word: String {
            switch self { case .a: return "great"; case .b: return "good"; case .c: return "struggles"; case .f: return "won't work" }
        }
    }
    let id: String
    let name: String
    let icon: String
    let grade: Grade
}

enum ConnectionGrades {
    /// down/up in Mbps; pings in ms (nil = unmeasured → latency-sensitive grades cap at B).
    static func evaluate(down: Double, up: Double?, unloadedMs: Double?, loadedMs: Double?) -> [CategoryGrade] {
        let upv = up ?? 0
        let bloat = (loadedMs ?? 0) - (unloadedMs ?? 0)

        func throughputGrade(_ value: Double, a: Double, b: Double, c: Double) -> CategoryGrade.Grade {
            value >= a ? .a : value >= b ? .b : value >= c ? .c : .f
        }
        /// Cap an interactivity grade by latency-under-load.
        func latencyCap(_ g: CategoryGrade.Grade) -> CategoryGrade.Grade {
            guard let loaded = loadedMs else { return min(g, .b) }   // unmeasured: no A for interactive
            if loaded > 300 || bloat > 250 { return min(g, .f) }
            if loaded > 150 || bloat > 100 { return min(g, .c) }
            return g
        }

        var out: [CategoryGrade] = []
        out.append(.init(id: "browse", name: "Browsing", icon: "safari",
                         grade: throughputGrade(down, a: 25, b: 10, c: 3)))
        out.append(.init(id: "hd", name: "HD streaming", icon: "play.rectangle",
                         grade: throughputGrade(down, a: 15, b: 8, c: 5)))
        out.append(.init(id: "4k", name: "4K streaming", icon: "4k.tv",
                         grade: throughputGrade(down, a: 50, b: 25, c: 15)))
        // Calls need BOTH directions + stable latency.
        let callThroughput = min(throughputGrade(down, a: 10, b: 4, c: 1.5),
                                 throughputGrade(upv, a: 5, b: 2.5, c: 1))
        out.append(.init(id: "calls", name: "Video calls", icon: "video",
                         grade: latencyCap(callThroughput)))
        // Cloud gaming: heavy down + latency is everything.
        out.append(.init(id: "gaming", name: "Cloud gaming", icon: "gamecontroller",
                         grade: latencyCap(throughputGrade(down, a: 45, b: 25, c: 10))))
        out.append(.init(id: "uploads", name: "Big uploads", icon: "icloud.and.arrow.up",
                         grade: throughputGrade(upv, a: 100, b: 30, c: 10)))
        return out
    }

    static func shareLines(_ grades: [CategoryGrade]) -> String {
        grades.map { "\($0.grade.rawValue) \($0.name)" }.joined(separator: " · ")
    }
}
