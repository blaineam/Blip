import Foundation
import Darwin

final class CPUMonitor: @unchecked Sendable {
    private var previousTicks: [processor_cpu_load_info] = []

    func read() -> CPUStats {
        var stats = CPUStats()

        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let info = processorInfo else {
            return stats
        }

        let coreCount = Int(processorCount)
        var coreUsages: [Double] = []
        var totalUser: Double = 0
        var totalSystem: Double = 0
        var totalIdle: Double = 0

        // Grow previous ticks array if needed
        if previousTicks.count < coreCount {
            previousTicks = Array(repeating: processor_cpu_load_info(), count: coreCount)
        }

        for i in 0..<coreCount {
            let offset = Int32(i) * CPU_STATE_MAX
            let inUse = info[Int(offset + CPU_STATE_USER)]
            let inSystem = info[Int(offset + CPU_STATE_SYSTEM)]
            let inNice = info[Int(offset + CPU_STATE_NICE)]
            let inIdle = info[Int(offset + CPU_STATE_IDLE)]

            let prevUser = UInt32(previousTicks[i].cpu_ticks.0)
            let prevSystem = UInt32(previousTicks[i].cpu_ticks.1)
            let prevNice = UInt32(previousTicks[i].cpu_ticks.2)
            let prevIdle = UInt32(previousTicks[i].cpu_ticks.3)

            let deltaUser = Double(Int64(UInt32(inUse)) - Int64(prevUser))
            let deltaSystem = Double(Int64(UInt32(inSystem)) - Int64(prevSystem))
            let deltaNice = Double(Int64(UInt32(inNice)) - Int64(prevNice))
            let deltaIdle = Double(Int64(UInt32(inIdle)) - Int64(prevIdle))

            let totalDelta = deltaUser + deltaSystem + deltaNice + deltaIdle
            let coreUsage = totalDelta > 0 ? ((deltaUser + deltaSystem + deltaNice) / totalDelta) * 100 : 0
            coreUsages.append(max(0, min(100, coreUsage)))

            totalUser += deltaUser + deltaNice
            totalSystem += deltaSystem
            totalIdle += deltaIdle

            previousTicks[i].cpu_ticks = (
                UInt32(inUse),
                UInt32(inSystem),
                UInt32(inNice),
                UInt32(inIdle)
            )
        }

        let totalAll = totalUser + totalSystem + totalIdle
        if totalAll > 0 {
            stats.userUsage = (totalUser / totalAll) * 100
            stats.systemUsage = (totalSystem / totalAll) * 100
            stats.totalUsage = stats.userUsage + stats.systemUsage
        }
        stats.coreUsages = coreUsages

        // Load averages
        var loadavg = [Double](repeating: 0, count: 3)
        getloadavg(&loadavg, 3)
        stats.loadAverage1 = loadavg[0]
        stats.loadAverage5 = loadavg[1]
        stats.loadAverage15 = loadavg[2]

        // Core counts
        stats.logicalCores = coreCount
        var physCores: Int32 = 0
        var physSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.physicalcpu", &physCores, &physSize, nil, 0)
        stats.physicalCores = Int(physCores)

        var perfCores: Int32 = 0
        var perfSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &perfCores, &perfSize, nil, 0)
        stats.performanceCores = Int(perfCores)

        var effCores: Int32 = 0
        var effSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel1.physicalcpu", &effCores, &effSize, nil, 0)
        stats.efficiencyCores = Int(effCores)

        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: processorInfo), vm_size_t(Int(processorInfoCount) * MemoryLayout<integer_t>.stride))

        return stats
    }
}
