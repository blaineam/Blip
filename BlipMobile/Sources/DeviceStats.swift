import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

// What iOS actually lets a well-behaved app know about the device — no private APIs, no
// entitlement gymnastics. This is deliberately the honest subset: battery, storage, memory
// pressure-adjacent numbers, thermal state, uptime, and the network path. The Mac app's
// SMC/SMART/process powers have no sandbox-legal iOS equivalent, and pretending otherwise
// with jittery guesses would betray what Blip is.

/// Fixed-capacity ring of samples for lightweight session charts.
struct SampleRing: Equatable {
    private(set) var values: [Double] = []
    let capacity: Int
    init(capacity: Int = 60) { self.capacity = capacity }
    mutating func append(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

struct DeviceSnapshot: Sendable, Equatable {
    var cpuUsagePercent: Double = 0
    var batteryLevel: Double?          // 0…1, nil = unknown (simulator without battery)
    var batteryState: String = "Unknown"
    var lowPowerMode = false
    var storageTotal: Int64 = 0
    var storageFree: Int64 = 0         // "important usage" free — what the user can really use
    var memoryPhysical: UInt64 = 0
    var memoryAppAvailable: UInt64 = 0 // os_proc_available_memory — headroom for THIS app
    var thermalState: Int = 0          // ProcessInfo.ThermalState rawValue
    var uptime: TimeInterval = 0
    var model = ""
    var osVersion = ""
    var interfaceType: String = "—"    // Wi-Fi / Cellular / Wired / Offline
    var isExpensivePath = false
    var isConstrainedPath = false
    // "As many stats as iOS honestly allows" — every one of these is a public API.
    var memFree: UInt64 = 0            // host_statistics64 pages → bytes
    var memActive: UInt64 = 0
    var memInactive: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var appFootprint: UInt64 = 0       // task_vm_info.phys_footprint — what THIS app costs
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var coresTotal: Int = 0
    var coresPerformance: Int = 0      // hw.perflevel0.logicalcpu (0 where the split is absent)
    var coresEfficiency: Int = 0
    var bootDate: Date?
    var storageOpportunistic: Int64 = 0 // free if the system purges caches — the optimistic tier
    var localIPs: [String] = []        // per-interface IPv4, "en0 192.168.1.7" style
    var radioTech: String?             // 5G / LTE / … on cellular devices

    var storageUsed: Int64 { max(0, storageTotal - storageFree) }
    var storagePercentUsed: Double {
        storageTotal > 0 ? Double(storageUsed) / Double(storageTotal) * 100 : 0
    }
    var thermalLabel: String {
        switch thermalState {
        case 0: return "Nominal"
        case 1: return "Fair"
        case 2: return "Serious"
        default: return "Critical"
        }
    }
}

@MainActor
final class DeviceStats: ObservableObject {
    @Published private(set) var snapshot = DeviceSnapshot()
    // Session charts — see MobileCharts.swift for why these are session-scope by design.
    @Published private(set) var cpuHistory = SampleRing(capacity: 90)
    @Published private(set) var memoryHistory = SampleRing(capacity: 90)
    @Published private(set) var thermalHistory = SampleRing(capacity: 90)
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var lastPath: NWPath?

    init() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.lastPath = path; self?.sample() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "blip.mobile.path"))
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    deinit { pathMonitor.cancel() }

    /// Whole-device CPU %, from host_processor_info deltas — public API, works on iOS for the
    /// device's own cores (this is the same source the Mac app's CPUMonitor reads).
    private func sampleCPU() -> Double? {
        var count = mach_msg_type_number_t(0)
        var info: processor_info_array_t?
        var cpuCount = natural_t(0)
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            user += UInt64(info[base + Int(CPU_STATE_USER)])
            system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nice += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        defer { lastCPUTicks = (user, system, idle, nice) }
        guard let last = lastCPUTicks else { return nil }
        let busy = Double((user - last.user) + (system - last.system) + (nice - last.nice))
        let total = busy + Double(idle - last.idle)
        guard total > 0 else { return nil }
        return busy / total * 100
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value = 0; var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private func collectExtended(into s: inout DeviceSnapshot) {
        // VM breakdown (public host_statistics64) — the real "where did my RAM go".
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(sysctlInt("hw.pagesize") ?? 16384)
            s.memFree = UInt64(vm.free_count) * page
            s.memActive = UInt64(vm.active_count) * page
            s.memInactive = UInt64(vm.inactive_count) * page
            s.memWired = UInt64(vm.wire_count) * page
            s.memCompressed = UInt64(vm.compressor_page_count) * page
        }

        // This app's own physical footprint.
        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        if kr2 == KERN_SUCCESS { s.appFootprint = UInt64(info.phys_footprint) }

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { s.load1 = loads[0]; s.load5 = loads[1]; s.load15 = loads[2] }

        s.coresTotal = Foundation.ProcessInfo.processInfo.activeProcessorCount
        s.coresPerformance = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        s.coresEfficiency = sysctlInt("hw.perflevel1.logicalcpu") ?? 0

        var boot = timeval(); var bootSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &bootSize, nil, 0) == 0, boot.tv_sec > 0 {
            s.bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        }

        if let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]) {
            s.storageOpportunistic = Int64(v.volumeAvailableCapacity ?? 0)
        }

        // Local IPv4 per up-interface (getifaddrs).
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0, let first = addrs {
            defer { freeifaddrs(addrs) }
            var seen: [String] = []
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let c = cursor {
                defer { cursor = c.pointee.ifa_next }
                guard let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                      (c.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                      (c.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let nameBytes = UnsafeBufferPointer(start: c.pointee.ifa_name, count: 32)
                        .prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    let hostBytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    seen.append(String(decoding: nameBytes, as: UTF8.self) + " " + String(decoding: hostBytes, as: UTF8.self))
                }
            }
            s.localIPs = seen
        }
    }

    func sample() {
        var s = DeviceSnapshot()

        #if canImport(UIKit)
        let device = UIDevice.current
        let level = device.batteryLevel
        s.batteryLevel = level >= 0 ? Double(level) : nil
        switch device.batteryState {
        case .charging: s.batteryState = "Charging"
        case .full: s.batteryState = "Full"
        case .unplugged: s.batteryState = "On battery"
        default: s.batteryState = "Unknown"
        }
        #endif
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            s.storageTotal = Int64(values.volumeTotalCapacity ?? 0)
            s.storageFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        }

        s.memoryPhysical = ProcessInfo.processInfo.physicalMemory
        #if canImport(UIKit)
        s.memoryAppAvailable = UInt64(max(0, os_proc_available_memory()))
        #endif

        s.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var sysinfo = utsname(); uname(&sysinfo)
        s.model = withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }

        if let path = lastPath {
            if path.status != .satisfied { s.interfaceType = "Offline" }
            else if path.usesInterfaceType(.wifi) { s.interfaceType = "Wi-Fi" }
            else if path.usesInterfaceType(.cellular) { s.interfaceType = "Cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { s.interfaceType = "Wired" }
            else { s.interfaceType = "Other" }
            s.isExpensivePath = path.isExpensive
            s.isConstrainedPath = path.isConstrained
        }

        collectExtended(into: &s)
        s.cpuUsagePercent = sampleCPU() ?? snapshot.cpuUsagePercent
        snapshot = s
        cpuHistory.append(s.cpuUsagePercent)
        if s.memoryAppAvailable > 0 { memoryHistory.append(Double(s.memoryAppAvailable) / 1_073_741_824) }
        thermalHistory.append(Double(s.thermalState))
        MobileSharedStore.write(device: s)   // widgets read the latest snapshot
    }
}
