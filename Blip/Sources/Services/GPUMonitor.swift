import Foundation
import IOKit
import Metal

final class GPUMonitor: Sendable {
    private let device: (any MTLDevice)?

    init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    func read() -> GPUStats {
        var stats = GPUStats()
        stats.name = device?.name ?? "Apple GPU"

        // GPU core count from Metal
        if let device = device {
            // Apple Silicon GPUs don't expose core count directly via Metal,
            // but we can read it from IOKit or sysctl
            var gpuCores: Int32 = 0
            var size = MemoryLayout<Int32>.size
            if sysctlbyname("machdep.gpu.core_count", &gpuCores, &size, nil, 0) == 0 {
                stats.coreCount = Int(gpuCores)
            } else {
                // Fallback: estimate from device name or use Metal's max threads
                stats.coreCount = device.maxThreadsPerThreadgroup.width > 0 ? 0 : 0
            }
        }

        // Read GPU utilization from IOKit accelerator stats
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return stats
        }
        defer { IOObjectRelease(iterator) }

        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                // Apple Silicon reports "Device Utilization %" directly
                if let utilization = perfStats["Device Utilization %"] as? NSNumber {
                    stats.utilization = utilization.doubleValue
                } else if let gpuActivity = perfStats["GPU Activity(%)"] as? NSNumber {
                    stats.utilization = gpuActivity.doubleValue
                }

                // Try to get core count from IOKit if sysctl failed
                if stats.coreCount == 0 {
                    if let cores = dict["gpu-core-count"] as? NSNumber {
                        stats.coreCount = cores.intValue
                    }
                }
            }
        }

        return stats
    }
}
