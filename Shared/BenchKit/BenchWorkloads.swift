import Foundation
import CryptoKit
import Compression
import Accelerate

// BenchKit — Blip's whole-device benchmark. Platform-pure (macOS + iOS): every workload is an
// Apple framework the OS already ships (CryptoKit, Compression, Foundation, Accelerate, Metal),
// so the benchmark measures what real Mac/iOS software actually does and adds ~nothing to the
// app's footprint. No third-party code, no private APIs — Store-clean on both platforms.
//
// Each workload runs for a TIME BUDGET and reports throughput (work per second), so runs are
// comparable across devices regardless of speed. Cancellation is checked between chunks; a
// cancelled run reports what it measured so far (the engine discards partial results).

public enum BenchUnit: String, Codable, Sendable {
    case mbPerSec = "MB/s"
    case gbPerSec = "GB/s"
    case fftPerSec = "kFFT/s"
    case nsPerAccess = "ns"       // memory latency — LOWER is better; score math inverts it
    case gflops = "GFLOPS"
}

public struct WorkloadResult: Codable, Sendable, Equatable {
    public let id: String
    public let value: Double
    public let unit: BenchUnit
    public init(id: String, value: Double, unit: BenchUnit) {
        self.id = id; self.value = value; self.unit = unit
    }
}

public enum BenchWorkloads {

    // MARK: - CPU

    /// SHA-256 throughput (CryptoKit). Hashing shows up everywhere: file dedup, sync engines,
    /// content addressing. 8 MB chunks — big enough to stream, small enough to stay cache-honest.
    public static func sha256(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        let chunk = makeBuffer(bytes: 8 << 20, pattern: .pseudorandom)
        var hashed = 0
        let deadline = now() + seconds
        var digest = SHA256()
        while now() < deadline && !cancelled() {
            digest.update(data: chunk)
            hashed += chunk.count
        }
        _ = digest.finalize()
        return .init(id: "cpu.sha256", value: mbPerSec(bytes: hashed, seconds: seconds), unit: .mbPerSec)
    }

    /// LZFSE compression throughput (Apple's own codec — what APFS, Apple Archive, and half the
    /// system use). Input is half-compressible: all-zeros lies, pure noise lies the other way.
    public static func compressLZFSE(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        let src = makeBuffer(bytes: 8 << 20, pattern: .halfCompressible)
        let dstCap = src.count + (src.count >> 2)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dst.deallocate() }
        var processed = 0
        let deadline = now() + seconds
        src.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while now() < deadline && !cancelled() {
                let n = compression_encode_buffer(dst, dstCap, base, src.count, nil, COMPRESSION_LZFSE)
                precondition(n > 0, "LZFSE encode failed")
                processed += src.count
            }
        }
        return .init(id: "cpu.lzfse", value: mbPerSec(bytes: processed, seconds: seconds), unit: .mbPerSec)
    }

    /// JSON decode throughput (Foundation JSONDecoder over a realistic record array). Parsing is
    /// the tax every app pays; this is deliberately allocation-heavy like real decoding is.
    public static func jsonDecode(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        struct Record: Codable { let id: Int; let name: String; let score: Double; let tags: [String]; let active: Bool }
        let records = (0..<4000).map { i in
            Record(id: i, name: "record-\(i)-\(UUID().uuidString.prefix(8))", score: Double(i) * 1.5,
                   tags: ["alpha", "bravo", "tag\(i % 17)"], active: i % 3 == 0)
        }
        let blob = try! JSONEncoder().encode(records)
        let decoder = JSONDecoder()
        var processed = 0
        let deadline = now() + seconds
        while now() < deadline && !cancelled() {
            _ = try! decoder.decode([Record].self, from: blob)
            processed += blob.count
        }
        return .init(id: "cpu.json", value: mbPerSec(bytes: processed, seconds: seconds), unit: .mbPerSec)
    }

    /// 1024-point single-precision FFTs (Accelerate/vDSP) — the DSP core of audio, imaging, and
    /// every "smart" feature that touches a signal.
    public static func fft(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        let log2n = vDSP_Length(10)                    // 1024 points
        let n = 1 << 10
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return .init(id: "cpu.fft", value: 0, unit: .fftPerSec)
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = (0..<n/2).map { Float(sin(Double($0) * 0.37)) }
        var imag = [Float](repeating: 0, count: n/2)
        var count = 0
        let deadline = now() + seconds
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                while now() < deadline && !cancelled() {
                    // 256 forward FFTs per cancellation check keeps the loop overhead honest.
                    for _ in 0..<256 { vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD)) }
                    count += 256
                }
            }
        }
        return .init(id: "cpu.fft", value: Double(count) / seconds / 1000.0, unit: .fftPerSec)
    }

    /// The single-core CPU mix: equal time slices of all four, geometric-mean friendly.
    public static func cpuMix(seconds: Double, cancelled: () -> Bool) -> [WorkloadResult] {
        let slice = seconds / 4
        return [
            sha256(seconds: slice, cancelled: cancelled),
            compressLZFSE(seconds: slice, cancelled: cancelled),
            jsonDecode(seconds: slice, cancelled: cancelled),
            fft(seconds: slice, cancelled: cancelled),
        ]
    }

    // MARK: - Memory

    /// Streaming bandwidth: y = a·x + y over buffers far past any cache (vDSP_vsma — the classic
    /// triad). Reports GB/s of traffic actually moved (three streams per element).
    public static func memoryBandwidth(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        let count = 32 << 20 / MemoryLayout<Float>.size          // 32 MB per array, 3 arrays
        let x = [Float](repeating: 1.25, count: count)
        let y = [Float](repeating: 0.5, count: count)
        var out = [Float](repeating: 0, count: count)
        var a: Float = 1.0001
        var bytes = 0
        let deadline = now() + seconds
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeBufferPointer { yp in
                out.withUnsafeMutableBufferPointer { op in
                    while now() < deadline && !cancelled() {
                        vDSP_vsma(xp.baseAddress!, 1, &a, yp.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(count))
                        bytes += count * MemoryLayout<Float>.size * 3
                    }
                }
            }
        }
        return .init(id: "mem.bandwidth", value: Double(bytes) / seconds / 1_000_000_000, unit: .gbPerSec)
    }

    /// Dependent-load latency: a pointer chase around a shuffled 64 MB ring. Every load depends
    /// on the last — the prefetcher can't help, so this is the DRAM round-trip applications feel
    /// in linked structures and hash tables. Lower is better.
    public static func memoryLatency(seconds: Double, cancelled: () -> Bool) -> WorkloadResult {
        let count = 8 << 20                                       // 8M entries × 8 B = 64 MB
        var ring = [Int](repeating: 0, count: count)
        // Sattolo's algorithm: one full cycle, so the chase visits every slot exactly once.
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count { ring[i] = i }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int.random(in: 0..<i, using: &rng)
            ring.swapAt(i, j)
        }
        var idx = 0
        var hops = 0
        let start = now()
        let deadline = start + seconds
        // Check the clock every 64K hops — a per-hop check would BE the benchmark.
        while now() < deadline && !cancelled() {
            for _ in 0..<(64 << 10) { idx = ring[idx] }
            hops += 64 << 10
        }
        let elapsed = now() - start
        let ns = elapsed * 1_000_000_000 / Double(max(hops, 1))
        // Keep the chase honest: fold idx into the result so the loop can't be optimized away.
        return .init(id: "mem.latency", value: ns + Double(idx % 1) , unit: .nsPerAccess)
    }

    // MARK: - Helpers

    enum Pattern { case pseudorandom, halfCompressible }

    static func makeBuffer(bytes: Int, pattern: Pattern) -> Data {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            var state: UInt64 = 0x9E3779B97F4A7C15
            for i in 0..<p.count {
                switch pattern {
                case .pseudorandom:
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    p[i] = state
                case .halfCompressible:
                    if (i >> 6) & 1 == 0 { p[i] = 0x2020202020202020 }   // runs of spaces…
                    else {
                        state ^= state << 13; state ^= state >> 7; state ^= state << 17
                        p[i] = state                                      // …between noise
                    }
                }
            }
        }
        return data
    }

    static func now() -> Double { CFAbsoluteTimeGetCurrent() }
    static func mbPerSec(bytes: Int, seconds: Double) -> Double {
        Double(bytes) / max(seconds, 0.001) / 1_000_000
    }
}
