import Foundation
import Darwin

final class MemoryMonitor: Sendable {
    func read() -> MemoryStats {
        var stats = MemoryStats()

        // Total physical memory
        stats.total = Foundation.ProcessInfo.processInfo.physicalMemory

        // VM statistics
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return stats }

        let pageSize: UInt64 = 16384 // ARM64 page size (Apple Silicon)

        stats.wired = UInt64(vmStats.wire_count) * pageSize
        stats.compressed = UInt64(vmStats.compressor_page_count) * pageSize

        let active = UInt64(vmStats.active_count) * pageSize
        let inactive = UInt64(vmStats.inactive_count) * pageSize
        let speculative = UInt64(vmStats.speculative_count) * pageSize
        let free = UInt64(vmStats.free_count) * pageSize

        stats.appMemory = active + inactive - UInt64(vmStats.purgeable_count) * pageSize
        stats.used = active + inactive + speculative + stats.wired + stats.compressed
        stats.free = stats.total > stats.used ? stats.total - stats.used : free

        return stats
    }
}
