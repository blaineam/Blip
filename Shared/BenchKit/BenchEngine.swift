import Foundation
import Combine

// The orchestrator: burst legs (single-core mix → multicore mix → memory → GPU), then the
// sustained phase (full profile only) that repeats the multicore mix while sampling thermals —
// sustained÷burst is the throttle factor, the number Geekbench doesn't give you and iStats
// can't. Platform split is injected through ThermalSource; everything else is shared.
//
// Mirrors DiskSpeedTester's shape (phases / progress / cancel / history) so the UI and the
// intents wire up the same way the existing speed tests do.

public protocol ThermalSource: Sendable {
    /// Best-effort CPU temperature in °C, nil where the platform can't say (iOS, no SMC).
    func temperatureC() -> Double?
    /// Best-effort fan RPM (first fan), nil on fanless hardware and iOS.
    func fanRPM() -> Double?
}

public struct NullThermalSource: ThermalSource {
    public init() {}
    public func temperatureC() -> Double? { nil }
    public func fanRPM() -> Double? { nil }
}

@MainActor
public final class BenchEngine: ObservableObject {
    public enum Phase: String, Sendable {
        case idle, singleCore, multiCore, memory, gpu, sustained, done
        public var label: String {
            switch self {
            case .idle: return "Idle"
            case .singleCore: return "CPU · single-core"
            case .multiCore: return "CPU · all cores"
            case .memory: return "Memory"
            case .gpu: return "GPU"
            case .sustained: return "Sustained + thermals"
            case .done: return "Done"
            }
        }
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var lastResult: BenchResult?
    @Published public private(set) var history: [BenchResult] = []
    @Published public private(set) var liveThermal: BenchThermalSample?
    /// Category scores as each leg finishes mid-run — what lets the UI animate results in
    /// as they land instead of sitting blank until the end. id "sustained" updates in place
    /// each bucket with the CURRENT bucket's score relative to the first (percent).
    @Published public private(set) var liveLegs: [BenchLiveLeg] = []
    @Published public private(set) var lastError: String?

    private let thermal: ThermalSource
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private let cancelledFlag = CancelFlag()

    public init(thermal: ThermalSource = NullThermalSource(), defaults: UserDefaults = .standard) {
        self.thermal = thermal
        self.defaults = defaults
        self.history = BenchHistory.load(defaults: defaults)
    }

    public func toggle(profile: BenchProfile = .full) {
        isRunning ? cancel() : start(profile: profile)
    }

    public func cancel() {
        cancelledFlag.set()
        task?.cancel()
    }

    public func start(profile: BenchProfile = .full) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        phase = .singleCore
        progress = 0
        liveLegs = []
        cancelledFlag.reset()
        let flag = cancelledFlag
        let thermal = self.thermal
        task = Task { [weak self] in
            let result = await Self.run(profile: profile, thermal: thermal, flag: flag) { [weak self] phase, progress, sample, leg in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase = phase
                    self.progress = progress
                    if let sample { self.liveThermal = sample }
                    if let leg {
                        if let i = self.liveLegs.firstIndex(where: { $0.id == leg.id }) { self.liveLegs[i] = leg }
                        else { self.liveLegs.append(leg) }
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.phase = result == nil ? .idle : .done
                self.progress = result == nil ? 0 : 1
                if let result {
                    self.lastResult = result
                    BenchHistory.append(result, defaults: self.defaults)
                    self.history = BenchHistory.load(defaults: self.defaults)
                }
            }
        }
    }

    /// Run through the SHARED engine (published state + history) and return the result —
    /// what the Run Benchmark intent uses so Shortcuts runs land in the panel like any other.
    public func runAwaiting(profile: BenchProfile) async -> BenchResult? {
        guard !isRunning else { return nil }   // one benchmark at a time
        start(profile: profile)
        _ = await task?.value
        return phase == .done ? lastResult : nil
    }

    /// One-shot run for intents/QA — no published state needed, returns the result directly.
    public static func runOnce(profile: BenchProfile, thermal: ThermalSource = NullThermalSource()) async -> BenchResult? {
        await run(profile: profile, thermal: thermal, flag: CancelFlag()) { _, _, _, _ in }
    }

    // MARK: - The measurement itself (off the main actor)

    private static func run(
        profile: BenchProfile,
        thermal: ThermalSource,
        flag: CancelFlag,
        report: @escaping @Sendable (Phase, Double, BenchThermalSample?, BenchLiveLeg?) -> Void
    ) async -> BenchResult? {
        let cancelled: @Sendable () -> Bool = { flag.isSet || Task.isCancelled }
        let t = profile.perWorkloadSeconds

        // Weights for the progress bar: legs aren't equal-length.
        let sustainedWeight = profile.sustainedSeconds > 0 ? 0.45 : 0
        let legWeight = (1 - sustainedWeight) / 4

        return await Task.detached(priority: .userInitiated) { () -> BenchResult? in
            var progressSoFar = 0.0
            func step(_ phase: Phase, _ weight: Double, _ leg: BenchLiveLeg? = nil) {
                progressSoFar += weight
                report(phase, min(progressSoFar, 1), nil, leg)
            }

            // 1. Single-core mix.
            report(.singleCore, 0, nil, nil)
            let single = BenchWorkloads.cpuMix(seconds: t * 4, cancelled: cancelled)
            if cancelled() { return nil }
            let singleCat = BenchScore.category("Single-core", single)
            step(.multiCore, legWeight, BenchLiveLeg(id: "single", name: "Single-core", score: singleCat.score))

            // 2. Multicore: every core runs the mix concurrently; throughputs sum.
            let cores = max(2, Foundation.ProcessInfo.processInfo.activeProcessorCount)
            let multi = await withTaskGroup(of: [WorkloadResult].self) { group in
                for _ in 0..<cores {
                    group.addTask { BenchWorkloads.cpuMix(seconds: t * 4, cancelled: cancelled) }
                }
                var sums: [String: Double] = [:]
                var units: [String: BenchUnit] = [:]
                for await results in group {
                    for r in results { sums[r.id, default: 0] += r.value; units[r.id] = r.unit }
                }
                return sums.map { WorkloadResult(id: "multi." + $0.key.dropFirst(4), value: $0.value, unit: units[$0.key] ?? .mbPerSec) }
                    .sorted { $0.id < $1.id }
            }
            if cancelled() { return nil }
            let multiCat = BenchScore.category("All cores", multi.map {
                WorkloadResult(id: "cpu." + $0.id.dropFirst(6), value: $0.value / Double(cores), unit: $0.unit)
            })
            // Multicore normalizes per-core against the same references, scaled back up: the
            // category score then reflects total throughput relative to reference-per-core.
            let multiScaled = BenchCategoryScore(name: multiCat.name, score: multiCat.score * Double(cores), results: multi)
            step(.memory, legWeight, BenchLiveLeg(id: "multi", name: "All cores", score: multiScaled.score))

            // 3. Memory.
            let mem = [
                BenchWorkloads.memoryBandwidth(seconds: t, cancelled: cancelled),
                BenchWorkloads.memoryLatency(seconds: t, cancelled: cancelled),
            ]
            if cancelled() { return nil }
            let memCat = BenchScore.category("Memory", mem)
            step(.gpu, legWeight, BenchLiveLeg(id: "memory", name: "Memory", score: memCat.score))

            // 4. GPU (may be unavailable — category drops out, never zeroes).
            let gpu = BenchGPU.matmul(seconds: t * 2, cancelled: cancelled)
            if cancelled() { return nil }
            let gpuCat = gpu.map { BenchScore.category("GPU", [$0]) }
            step(.sustained, legWeight, gpuCat.map { BenchLiveLeg(id: "gpu", name: "GPU", score: $0.score) })

            // 5. Sustained (full profile): repeat the multicore mix in buckets, sampling thermals.
            var throttle: Double?
            var samples: [BenchThermalSample] = []
            if profile.sustainedSeconds > 0 {
                let bucket = 5.0
                let buckets = Int(profile.sustainedSeconds / bucket)
                var bucketScores: [Double] = []
                let sustainedStart = CFAbsoluteTimeGetCurrent()
                for i in 0..<buckets {
                    if cancelled() { break }
                    let results = await withTaskGroup(of: [WorkloadResult].self) { group in
                        for _ in 0..<cores {
                            group.addTask { BenchWorkloads.cpuMix(seconds: bucket, cancelled: cancelled) }
                        }
                        var all: [WorkloadResult] = []
                        for await r in group { all.append(contentsOf: r) }
                        return all
                    }
                    var sums: [String: Double] = [:]
                    for r in results { sums[r.id, default: 0] += r.value }
                    let summed = sums.map { WorkloadResult(id: $0.key, value: $0.value, unit: .mbPerSec) }
                    bucketScores.append(BenchScore.composite(summed))
                    let sample = BenchThermalSample(
                        atSeconds: CFAbsoluteTimeGetCurrent() - sustainedStart,
                        temperatureC: thermal.temperatureC(),
                        fanRPM: thermal.fanRPM(),
                        thermalState: Foundation.ProcessInfo.processInfo.thermalState.rawValue)
                    samples.append(sample)
                    let relative = bucketScores.first.map { $0 > 0 ? bucketScores[bucketScores.count - 1] / $0 * 100 : 100 }
                    report(.sustained, min(progressSoFar + sustainedWeight * Double(i + 1) / Double(buckets), 1), sample,
                           relative.map { BenchLiveLeg(id: "sustained", name: "Sustained", score: $0) })
                }
                if let first = bucketScores.first, first > 0, let last = bucketScores.last {
                    // Mean of the back half ÷ the first bucket: robust to a noisy single bucket.
                    let back = bucketScores.suffix(max(1, bucketScores.count / 2))
                    throttle = (back.reduce(0, +) / Double(back.count)) / first
                    _ = last
                }
            }

            let composite = BenchScore.overall([singleCat, multiScaled, memCat, gpuCat])
            var sysinfo = utsname(); uname(&sysinfo)
            let model = withUnsafeBytes(of: &sysinfo.machine) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return BenchResult(
                date: Date(), profile: profile,
                singleCore: singleCat, multiCore: multiScaled, memory: memCat, gpu: gpuCat,
                throttleFactor: throttle, thermalSamples: samples,
                composite: composite,
                deviceModel: model,
                osVersion: Foundation.ProcessInfo.processInfo.operatingSystemVersionString)
        }.value
    }
}

/// Cross-actor cancellation flag (the workloads poll it from whatever thread they run on).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// Thread-safe latest-thermal reading, refreshed by whoever already polls the sensors (the
/// app's 2 s snapshot tick on macOS) and read by the bench's sustained phase off-thread.
public final class LatestThermalBox: ThermalSource, @unchecked Sendable {
    private let lock = NSLock()
    private var temp: Double?
    private var rpm: Double?
    public init() {}
    public func update(temperatureC: Double?, fanRPM: Double?) {
        lock.lock(); temp = temperatureC; rpm = fanRPM; lock.unlock()
    }
    public func temperatureC() -> Double? { lock.lock(); defer { lock.unlock() }; return temp }
    public func fanRPM() -> Double? { lock.lock(); defer { lock.unlock() }; return rpm }
}

/// A category score surfaced mid-run, as its leg completes.
public struct BenchLiveLeg: Sendable, Equatable, Identifiable {
    public let id: String        // "single" / "multi" / "memory" / "gpu" / "sustained"
    public let name: String
    public let score: Double     // category units; for "sustained", percent of first bucket
    public init(id: String, name: String, score: Double) {
        self.id = id; self.name = name; self.score = score
    }
}
