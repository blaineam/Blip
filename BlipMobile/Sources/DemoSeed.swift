import Foundation

// Screenshot demo mode — `defaults write com.blainemiller.Blip blip.demoSeed -bool true`
// before launch (the capture script does this on a pristine container). Seeds curated,
// PII-free data through the app's REAL types and stores so every screen photographs well:
// no live runs to wait for, no user data anywhere near the frame. The network-tools demo
// uses RFC 5737 documentation addresses (192.0.2.0/24 etc.) — addresses that by
// definition belong to no one.

enum DemoSeed {
    static var active: Bool { UserDefaults.standard.bool(forKey: "blip.demoSeed") }

    @MainActor
    static func applyIfRequested() {
        guard active else { return }
        seedBench()
        seedSpeed()
    }

    // A believable upward-trending bench story ending at a strong full run.
    @MainActor
    private static func seedBench() {
        guard BenchHistory.load(defaults: MobileSharedStore.defaults).isEmpty else { return }
        let composites: [(Double, BenchProfile, Double)] = [   // composite, profile, daysAgo
            (1210, .full, 21), (1188, .quick, 18), (1246, .full, 14),
            (1255, .quick, 9), (1290, .full, 6), (1301, .quick, 3), (1342, .full, 0.2),
        ]
        for (score, profile, daysAgo) in composites {
            let r = BenchResult(
                date: Date().addingTimeInterval(-daysAgo * 86_400),
                profile: profile,
                singleCore: .init(name: "Single-core", score: score * 0.53, results: []),
                multiCore: .init(name: "All cores", score: score * 4.72, results: []),
                memory: .init(name: "Memory", score: score * 0.79, results: []),
                gpu: .init(name: "GPU", score: score * 0.49, results: []),
                neural: .init(name: "Neural", score: score * 0.61, results: []),
                throttleFactor: profile == .full ? 0.95 : nil,
                thermalSamples: profile == .full ? (0..<9).map {
                    BenchThermalSample(atSeconds: Double($0) * 5, temperatureC: nil, fanRPM: nil,
                                       thermalState: $0 > 5 ? 1 : 0)
                } : [],
                composite: score,
                deviceModel: DeviceStats.currentModelIdentifier(),
                osVersion: Foundation.ProcessInfo.processInfo.operatingSystemVersionString)
            BenchHistory.append(r, defaults: MobileSharedStore.defaults)
        }
    }

    private static func seedSpeed() {
        guard UserDefaults.standard.string(forKey: "mobile.speed.source") == nil else { return }
        // Wave-shaped curves like a real cable/fiber run settles into.
        func curve(peak: Double, ramp: Int, n: Int) -> [Double] {
            (0..<n).map { i in
                let settle = min(1, Double(i) / Double(ramp))
                let wobble = 1 + 0.05 * sin(Double(i) * 0.7)
                return peak * settle * wobble
            }
        }
        var latest = MobileSpeedResult(downMbps: 942, upMbps: 851, pingMs: 12,
                                       date: Date().addingTimeInterval(-540),
                                       interface: "Wi-Fi", source: "OpenSpeedTest")
        latest.loadedPingMs = 29
        latest.downCurve = curve(peak: 942, ramp: 10, n: 70)
        latest.upCurve = curve(peak: 851, ramp: 8, n: 55)
        var older: [MobileSpeedResult] = [
            .init(downMbps: 897, upMbps: 830, pingMs: 13, date: Date().addingTimeInterval(-86_400 * 2), interface: "Wi-Fi", source: "OpenSpeedTest"),
            .init(downMbps: 68, upMbps: 21, pingMs: 38, date: Date().addingTimeInterval(-86_400 * 5), interface: "Cellular", source: "OpenSpeedTest"),
            .init(downMbps: 915, upMbps: 842, pingMs: 12, date: Date().addingTimeInterval(-86_400 * 7), interface: "Wi-Fi", source: "OpenSpeedTest"),
        ]
        older[1].loadedPingMs = 96
        older[0].loadedPingMs = 31
        let history = older.reversed() + [latest]
        if let data = try? JSONEncoder().encode(Array(history)) {
            MobileSharedStore.defaults.set(data, forKey: "speed.history")
        }
        MobileSharedStore.write(speed: .init(downMbps: latest.downMbps, upMbps: latest.upMbps,
                                             date: latest.date, interface: latest.interface,
                                             pingMs: latest.pingMs, loadedPingMs: latest.loadedPingMs))
    }

    // MARK: - Canned network tools (RFC 5737 documentation space — nobody's addresses)

    static let pingSamples: [PingSample] = (1...24).map { i in
        PingSample(sequence: i, rttMs: i == 17 ? nil : 11.0 + 4.5 * abs(sin(Double(i) * 0.6)))
    }

    static let traceHops: [TraceHop] = {
        var hops: [TraceHop] = [
            TraceHop(ttl: 1, address: "192.168.1.1", rttMs: 1.4),
            TraceHop(ttl: 2, address: "192.0.2.1", rttMs: 4.1),
            TraceHop(ttl: 3, address: "192.0.2.44", rttMs: 8.9),
            TraceHop(ttl: 4, address: "198.51.100.7", rttMs: 19.6),
            TraceHop(ttl: 5, address: nil, rttMs: nil),
            TraceHop(ttl: 6, address: "198.51.100.90", rttMs: 31.2),
            TraceHop(ttl: 7, address: "203.0.113.12", rttMs: 39.8),
        ]
        var last = TraceHop(ttl: 8, address: "203.0.113.60", rttMs: 44.0)
        last.isDestination = true
        hops.append(last)
        return hops
    }()

    /// City pins for the canned hops — a believable westbound route.
    static let geoTable: [String: (lat: Double, lon: Double, label: String)] = [
        "192.0.2.1": (37.77, -122.42, "San Francisco, US"),
        "192.0.2.44": (39.74, -104.99, "Denver, US"),
        "198.51.100.7": (41.88, -87.63, "Chicago, US"),
        "198.51.100.90": (43.65, -79.38, "Toronto, CA"),
        "203.0.113.12": (40.71, -74.01, "New York, US"),
        "203.0.113.60": (51.51, -0.13, "London, GB"),
    ]
}
