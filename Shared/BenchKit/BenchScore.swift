import Foundation

// Score model. Every workload throughput is normalized against a FIXED reference constant and
// the composite is a geometric mean × 1000. The references are arbitrary round numbers chosen
// once (Blip 2.0) and FROZEN — they are not claims about any real chip, they are the unit
// system. That keeps scores comparable across devices and across years without ever
// fabricating "an M1 scores X" tables; "how does my Mac compare to itself last month" comes
// from the on-device history, which is the comparison that actually diagnoses something.
//
// Latency-type workloads (lower = better) contribute as reference/value; throughput types as
// value/reference. A missing workload (GPU unavailable, cancelled leg) simply drops out of the
// mean rather than zeroing the composite.

public enum BenchReference {
    /// FROZEN Blip 2.0 reference constants — the unit system, never "a real device".
    public static let unit: [String: Double] = [
        "cpu.sha256": 1500,        // MB/s
        "cpu.lzfse": 500,          // MB/s
        "cpu.json": 300,           // MB/s
        "cpu.fft": 2000,           // kFFT/s
        "mem.bandwidth": 60,       // GB/s
        "mem.latency": 100,        // ns — lower is better
        "gpu.matmul": 2000,        // GFLOPS
        "npu.featureprint": 50,    // inferences/s (Vision feature print — ANE where present)
    ]
    public static let lowerIsBetter: Set<String> = ["mem.latency"]
}

public struct BenchCategoryScore: Codable, Sendable, Equatable {
    public let name: String
    public let score: Double
    public let results: [WorkloadResult]
}

public struct BenchThermalSample: Codable, Sendable, Equatable {
    public let atSeconds: Double
    /// Best temperature the platform offers (SMC CPU die on macOS; nil where unavailable).
    public let temperatureC: Double?
    /// Fan RPM (macOS with fans; nil on fanless/iOS).
    public let fanRPM: Double?
    /// ProcessInfo.ThermalState rawValue (0 nominal … 3 critical) — available everywhere.
    public let thermalState: Int
    public init(atSeconds: Double, temperatureC: Double?, fanRPM: Double?, thermalState: Int) {
        self.atSeconds = atSeconds; self.temperatureC = temperatureC
        self.fanRPM = fanRPM; self.thermalState = thermalState
    }
}

public struct BenchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public let date: Date
    public let profile: BenchProfile
    public let singleCore: BenchCategoryScore
    public let multiCore: BenchCategoryScore
    public let memory: BenchCategoryScore
    public let gpu: BenchCategoryScore?
    /// Core ML/Vision inference throughput — routed to the Neural Engine on hardware that
    /// has one (Vision decides; there is no public "force ANE" switch, so this honestly
    /// measures *ML inference* rather than claiming raw NPU FLOPS). nil on old results.
    public let neural: BenchCategoryScore?
    /// Sustained multicore composite ÷ burst multicore composite. 1.0 = no throttle;
    /// 0.75 = the machine loses a quarter of itself under sustained load.
    public let throttleFactor: Double?
    public let thermalSamples: [BenchThermalSample]
    public let composite: Double
    public let deviceModel: String
    public let osVersion: String

    public var throttlePercentLost: Int? {
        throttleFactor.map { max(0, Int(((1 - $0) * 100).rounded())) }
    }
}

public enum BenchProfile: String, Codable, Sendable, CaseIterable {
    /// ~90 s: 10 s/leg burst + 45 s sustained with thermal sampling.
    case full
    /// ~6 s: 0.5 s/leg, no sustained phase. The QA/Soren profile — proves every code path
    /// (including GPU dispatch) without turning the test farm into a space heater.
    case quick

    public var perWorkloadSeconds: Double { self == .full ? 2.5 : 0.5 }
    public var sustainedSeconds: Double { self == .full ? 45 : 0 }
}

public enum BenchScore {
    /// score for one workload in reference units (1.0 == reference).
    public static func normalized(_ r: WorkloadResult) -> Double? {
        guard let ref = BenchReference.unit[r.id], r.value > 0 else { return nil }
        return BenchReference.lowerIsBetter.contains(r.id) ? ref / r.value : r.value / ref
    }

    /// Geometric mean of the normalized workloads × 1000, ignoring missing legs.
    public static func composite(_ results: [WorkloadResult]) -> Double {
        let norms = results.compactMap(normalized)
        guard !norms.isEmpty else { return 0 }
        let logSum = norms.reduce(0) { $0 + log($1) }
        return exp(logSum / Double(norms.count)) * 1000
    }

    public static func category(_ name: String, _ results: [WorkloadResult]) -> BenchCategoryScore {
        .init(name: name, score: composite(results), results: results)
    }

    /// The headline number: geometric mean across category scores that exist.
    public static func overall(_ categories: [BenchCategoryScore?]) -> Double {
        let scores = categories.compactMap { $0?.score }.filter { $0 > 0 }
        guard !scores.isEmpty else { return 0 }
        let logSum = scores.reduce(0) { $0 + log($1) }
        return exp(logSum / Double(scores.count))
    }
}

// MARK: - History

/// On-device score history — the comparison that means something ("my Mac vs my Mac").
public struct BenchHistory {
    public static let maxEntries = 30
    private static let key = "benchHistory.v1"

    public static func load(defaults: UserDefaults = .standard) -> [BenchResult] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([BenchResult].self, from: data)) ?? []
    }

    public static func append(_ result: BenchResult, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all.append(result)
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    /// Personal best composite (full-profile runs only — quick runs are QA, not measurements).
    public static func personalBest(defaults: UserDefaults = .standard) -> Double? {
        load(defaults: defaults).filter { $0.profile == .full }.map(\.composite).max()
    }
}
