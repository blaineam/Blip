import Foundation
import Metal
import MetalPerformanceShaders

// GPU throughput via MPS matrix multiply — the one kernel every GPU vendor optimizes to death,
// which is exactly why it's the honest ceiling measurement. 1024³ single-precision GEMM in a
// loop for the time budget; GFLOPS = 2·N³ per multiply. Works identically on macOS and iOS
// (Apple silicon + Intel Macs with any Metal GPU); returns nil where Metal/MPS is unavailable
// so the score simply omits the GPU category instead of zeroing it.

public enum BenchGPU {
    public static func matmul(seconds: Double, cancelled: () -> Bool) -> WorkloadResult? {
        guard let device = MTLCreateSystemDefaultDevice(),
              MPSSupportsMTLDevice(device),
              let queue = device.makeCommandQueue() else { return nil }

        let n = 1024
        let rowBytes = n * MemoryLayout<Float>.size
        let desc = MPSMatrixDescriptor(rows: n, columns: n, rowBytes: rowBytes, dataType: .float32)
        let length = n * rowBytes
        guard let bufA = device.makeBuffer(length: length, options: .storageModeShared),
              let bufB = device.makeBuffer(length: length, options: .storageModeShared),
              let bufC = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }

        // Fill A and B with small non-trivial values (all-zeros lets clever drivers cheat).
        let pa = bufA.contents().bindMemory(to: Float.self, capacity: n * n)
        let pb = bufB.contents().bindMemory(to: Float.self, capacity: n * n)
        for i in 0..<(n * n) {
            pa[i] = Float((i % 97)) * 0.013
            pb[i] = Float((i % 89)) * 0.011
        }

        let a = MPSMatrix(buffer: bufA, descriptor: desc)
        let b = MPSMatrix(buffer: bufB, descriptor: desc)
        let c = MPSMatrix(buffer: bufC, descriptor: desc)
        let mul = MPSMatrixMultiplication(device: device, transposeLeft: false, transposeRight: false,
                                          resultRows: n, resultColumns: n, interiorColumns: n,
                                          alpha: 1.0, beta: 0.0)

        // Warm-up: first dispatch pays pipeline compilation; measuring it would punish cold GPUs.
        if let cb = queue.makeCommandBuffer() {
            mul.encode(commandBuffer: cb, leftMatrix: a, rightMatrix: b, resultMatrix: c)
            cb.commit(); cb.waitUntilCompleted()
        }

        var multiplies = 0
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + seconds
        while CFAbsoluteTimeGetCurrent() < deadline && !cancelled() {
            guard let cb = queue.makeCommandBuffer() else { break }
            // 4 GEMMs per command buffer amortizes submission overhead without letting one
            // buffer overshoot the budget by much.
            for _ in 0..<4 { mul.encode(commandBuffer: cb, leftMatrix: a, rightMatrix: b, resultMatrix: c) }
            cb.commit(); cb.waitUntilCompleted()
            multiplies += 4
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        guard multiplies > 0, elapsed > 0 else { return nil }
        let flops = 2.0 * Double(n) * Double(n) * Double(n) * Double(multiplies)
        return .init(id: "gpu.matmul", value: flops / elapsed / 1_000_000_000, unit: .gflops)
    }
}
