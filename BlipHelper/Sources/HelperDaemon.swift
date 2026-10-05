import Foundation
import IOKit
import IOKit.ps
import Darwin
import AppKit

/// Polls privileged system APIs and produces HelperSnapshots.
/// Runs in the helper process (unsandboxed) to collect data
/// that the sandboxed MAS app cannot access directly.
final class HelperDaemon: HelperDaemonActions, @unchecked Sendable {
    private var previousDiskRead: UInt64 = 0
    private var previousDiskWrite: UInt64 = 0
    private var previousDiskTimestamp: Date?

    private var previousCPUTimes: [pid_t: (user: UInt64, system: UInt64, wallNs: UInt64)] = [:]
    private let machToNs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private var cachedSmartStatus: String?

    // Drive health (S.M.A.R.T.) changes slowly; refresh on an interval instead of every poll.
    private var cachedDrives: [HelperDriveHealth] = []
    private var drivePollCount = 0

    // Network totals come from a netstat subprocess; cache and refresh every ~5 polls.
    private var cachedNetTotals: (down: UInt64, up: UInt64)?
    private var netPollCount = 0

    private let iconCache = NSCache<NSNumber, NSData>()

    private var cachedModelName: String?

    // Traceroute / MTR session state (Feature B)
    private let traceLock = NSLock()
    private var traceSession: TraceSession?

    init() {
        iconCache.countLimit = 15
        iconCache.totalCostLimit = 2 * 1024 * 1024
    }

    /// Collect all privileged data into a HelperSnapshot.
    func poll() -> HelperSnapshot {
        let fans = readFans()
        let temps = readTemperatures()
        let gpu = readGPUUtilization()
        let diskIO = readDiskIO()
        let battery = readBatteryHealth()
        let procs = readProcesses()

        // S.M.A.R.T. drive health — refresh every ~30 polls (~60s); seed on first poll.
        if cachedDrives.isEmpty || drivePollCount % 30 == 0 {
            cachedDrives = readDriveHealth()
        }
        drivePollCount += 1

        netPollCount += 1
        if cachedNetTotals == nil || netPollCount % 5 == 1 {
            cachedNetTotals = readNetworkTotals()
        }
        let netTotals = cachedNetTotals

        return HelperSnapshot(
            fans: fans,
            cpuTemperature: temps.cpu,
            gpuTemperature: temps.gpu,
            gpuUtilization: gpu,
            diskReadBytesPerSec: diskIO.readPerSec,
            diskWriteBytesPerSec: diskIO.writePerSec,
            diskTotalBytesRead: diskIO.totalRead,
            diskTotalBytesWritten: diskIO.totalWrite,
            smartStatus: readSmartStatus(),
            drives: cachedDrives,
            networkTotalDownloaded: netTotals?.down,
            networkTotalUploaded: netTotals?.up,
            batteryHealth: battery.health,
            batteryCycleCount: battery.cycleCount,
            batteryCondition: battery.condition,
            batteryTemperature: battery.temperature,
            topProcessesByCPU: procs.byCPU,
            topProcessesByMemory: procs.byMemory,
            macModelName: fetchModelName(),
            helperVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            timestamp: Date()
        )
    }

    // MARK: - Mac Model Name (via system_profiler)

    private func fetchModelName() -> String? {
        if let cached = cachedModelName { return cached }
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["SPHardwareDataType"] as? [[String: Any]],
               let first = items.first {
                let name = first["machine_name"] as? String ?? ""
                let chip = first["chip_type"] as? String ?? ""
                if !name.isEmpty && !chip.isEmpty {
                    cachedModelName = "\(name) (\(chip))"
                } else if !name.isEmpty {
                    cachedModelName = name
                }
            }
        } catch {}
        return cachedModelName
    }

    // MARK: - Fan & Thermal (via SMC)

    private func readFans() -> [HelperFan] {
        guard SMC.open() else { return [] }
        let count = SMC.readFanCount()
        guard count > 0, count <= 10 else { return [] }

        var fans: [HelperFan] = []
        for i in 0..<count {
            let rpm = SMC.readFanRPM(fan: i)
            fans.append(HelperFan(
                id: i,
                name: "Fan \(i + 1)",
                currentRPM: (rpm >= 0 && rpm <= 10_000) ? rpm : 0,
                minRPM: max(0, SMC.readFanMin(fan: i)),
                maxRPM: max(0, SMC.readFanMax(fan: i))
            ))
        }
        return fans
    }

    private func readTemperatures() -> (cpu: Double?, gpu: Double?) {
        guard SMC.open() else { return (nil, nil) }
        return (SMC.readCPUTemperature(), SMC.readGPUTemperature())
    }

    // MARK: - GPU Utilization (via IOKit)

    private static let gpuUtilKeys = [
        "Device Utilization %",
        "GPU Activity(%)",
        "GPU Core Utilization %",
    ]

    private func readGPUUtilization() -> Double {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let perfStats = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            for key in Self.gpuUtilKeys {
                if let value = perfStats[key] as? NSNumber {
                    return value.doubleValue
                }
            }
        }
        return 0
    }

    // MARK: - Disk I/O (via IOKit)

    private static let diskServiceNames = ["IOBlockStorageDriver", "IONVMeBlockStorageDriver"]

    private func readDiskIO() -> (readPerSec: UInt64, writePerSec: UInt64, totalRead: UInt64, totalWrite: UInt64) {
        var iterator: io_iterator_t = 0
        var matched = false
        for name in Self.diskServiceNames {
            guard let matching = IOServiceMatching(name) else { continue }
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess {
                matched = true
                break
            }
        }
        guard matched else { return (0, 0, 0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            if let r = stats["Bytes (Read)"] as? UInt64 { totalRead += r }
            if let w = stats["Bytes (Write)"] as? UInt64 { totalWrite += w }
        }

        let now = Date()
        var readPerSec: UInt64 = 0
        var writePerSec: UInt64 = 0
        if let prev = previousDiskTimestamp {
            let interval = now.timeIntervalSince(prev)
            if interval > 0 {
                readPerSec = totalRead > previousDiskRead
                    ? UInt64(Double(totalRead - previousDiskRead) / interval) : 0
                writePerSec = totalWrite > previousDiskWrite
                    ? UInt64(Double(totalWrite - previousDiskWrite) / interval) : 0
            }
        }
        previousDiskRead = totalRead
        previousDiskWrite = totalWrite
        previousDiskTimestamp = now

        return (readPerSec, writePerSec, totalRead, totalWrite)
    }

    // MARK: - SMART Status

    private func readSmartStatus() -> String {
        if let cached = cachedSmartStatus { return cached }
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "disk0"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                if line.contains("SMART Status") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count >= 2 {
                        let status = parts[1].trimmingCharacters(in: .whitespaces)
                        cachedSmartStatus = status
                        return status
                    }
                }
            }
        } catch {}
        return ""
    }

    // MARK: - Network Totals (since-boot, via netstat)

    /// Sums since-boot RX/TX bytes for physical `en*` interfaces from `netstat -ib`.
    /// These are the kernel's true 64-bit counters (what Activity Monitor shows); the
    /// sandboxed app can't spawn netstat, so the helper provides them.
    private func readNetworkTotals() -> (down: UInt64, up: UInt64)? {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-ib"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            var down: UInt64 = 0
            var up: UInt64 = 0
            for line in output.components(separatedBy: "\n") {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard cols.count >= 10,
                      cols[0].hasPrefix("en"),
                      cols[2].hasPrefix("<Link"),
                      let ib = UInt64(cols[6]),
                      let ob = UInt64(cols[9]) else { continue }
                down += ib
                up += ob
            }
            return (down, up)
        } catch {
            return nil
        }
    }

    // MARK: - Drive Health (S.M.A.R.T. via IOKit user clients)

    // CFUUIDs identifying the IOKit plug-in and NVMe SMART interface. Computed (not
    // stored) so they stay concurrency-safe; CFUUIDGetConstantUUIDWithBytes returns a
    // cached singleton, so this is cheap.
    // kIOCFPlugInInterfaceID — not exposed to Swift as a macro.
    private static var plugInInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    // kIONVMeSMARTUserClientTypeID
    private static var nvmeSMARTTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    }
    // kIONVMeSMARTInterfaceID
    private static var nvmeSMARTInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    }
    // kIOATASMARTUserClientTypeID
    private static var ataSMARTTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0x24, 0x51, 0x4B, 0x7A, 0x28, 0x04, 0x11, 0xD6, 0x8A, 0x02, 0x00, 0x30, 0x65, 0x70, 0x48, 0x66)
    }
    // kIOATASMARTInterfaceID
    private static var ataSMARTInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0x08, 0xAB, 0xE2, 0x1C, 0x20, 0xD4, 0x11, 0xD6, 0x8D, 0xF6, 0x00, 0x03, 0x93, 0x5A, 0x76, 0xB2)
    }

    /// Enumerates physical block-storage devices and reads S.M.A.R.T. health for any
    /// that expose the NVMe SMART user client (internal Apple SSD and most NVMe
    /// enclosures). Works unprivileged — Apple publishes the user client in the
    /// IORegistry, so no root/admin is required.
    private func readDriveHealth() -> [HelperDriveHealth] {
        var drives: [HelperDriveHealth] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return drives }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }

            let deviceChars = dict["Device Characteristics"] as? [String: Any]
            let protocolChars = dict["Protocol Characteristics"] as? [String: Any]

            let name = (deviceChars?["Product Name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? "Drive"
            let medium = deviceChars?["Medium Type"] as? String ?? ""
            let location = protocolChars?["Physical Interconnect Location"] as? String ?? ""
            let interconnect = protocolChars?["Physical Interconnect"] as? String ?? ""
            let bsdName = dict["BSD Name"] as? String ?? ""
            let isInternal = location.localizedCaseInsensitiveContains("internal")

            // Skip synthesized/virtual disk images.
            if interconnect.localizedCaseInsensitiveContains("Virtual") { continue }
            let displayName = name.isEmpty ? "Drive" : name

            if (dict["NVMe SMART Capable"] as? Bool) ?? false {
                var health = HelperDriveHealth(
                    name: displayName,
                    bsdName: bsdName,
                    isInternal: isInternal,
                    medium: interconnect.isEmpty ? (medium.isEmpty ? "NVMe" : medium) : interconnect,
                    smartStatus: ""
                )
                if let log = readNVMeSMARTLog(service: entry) {
                    health.percentageUsed = Int(log.percentUsed)
                    health.availableSpare = Int(log.availableSpare)
                    health.availableSpareThreshold = Int(log.spareThreshold)
                    health.temperatureCelsius = Int(log.temperatureKelvin) - 273
                    health.dataUnitsWritten = log.dataUnitsWritten
                    health.dataUnitsRead = log.dataUnitsRead
                    health.powerOnHours = log.powerOnHours
                    health.powerCycles = log.powerCycles
                    health.unsafeShutdowns = log.unsafeShutdowns
                    health.mediaErrors = log.mediaErrors
                    health.criticalWarning = Int(log.criticalWarning)
                    health.smartStatus = log.criticalWarning == 0 ? "Verified" : "Failing"
                }
                drives.append(health)
            } else if (dict["SMART Capable"] as? Bool) ?? false {
                // External SATA/USB drives — ATA/SAT path.
                guard let ata = readATASMART(service: entry) else { continue }
                var health = HelperDriveHealth(
                    name: displayName,
                    bsdName: bsdName,
                    isInternal: isInternal,
                    medium: interconnect.isEmpty ? (medium.isEmpty ? "SATA" : medium) : interconnect,
                    smartStatus: ata.status
                )
                health.percentageUsed = ata.life.map { max(0, 100 - $0) }
                health.temperatureCelsius = ata.tempC
                health.powerOnHours = ata.powerOnHours
                health.criticalWarning = ata.status == "Failing" ? 1 : 0
                drives.append(health)
            }
        }
        return drives
    }

    /// Reads the 512-byte NVMe SMART/Health log via the IONVMeSMARTUserClient plug-in.
    /// The interface vtable is `IUNKNOWN_C_GUTS` + `UInt16 version`/`revision` +
    /// `SMARTReadData(self, buffer)`, so SMARTReadData sits at vtable byte offset 40.
    private func readNVMeSMARTLog(service: io_service_t) -> NVMeSMARTLog? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, Self.nvmeSMARTTypeID,
                                                Self.plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let pluginVtbl = plugin.pointee?.pointee else { return nil }
        defer { _ = IODestroyPlugInInterface(plugin) }

        var ifaceRaw: LPVOID?
        let hr = pluginVtbl.QueryInterface(plugin, CFUUIDGetUUIDBytes(Self.nvmeSMARTInterfaceID), &ifaceRaw)
        guard hr == S_OK, let ifaceRaw else { return nil }

        // ifaceRaw -> pointer to (pointer to vtable). Pull function pointers by raw offset
        // since the IONVMeSMARTInterface struct isn't bridged into Swift.
        let ifacePtr = ifaceRaw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let vtable = ifacePtr.pointee else { return nil }

        typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        let ptrSize = MemoryLayout<UnsafeRawPointer>.size
        let readData = vtable.load(fromByteOffset: 5 * ptrSize, as: ReadFn.self)   // SMARTReadData
        let release = vtable.load(fromByteOffset: 3 * ptrSize, as: ReleaseFn.self) // IUnknown::Release
        defer { _ = release(ifaceRaw) }

        var buffer = [UInt8](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBytes { readData(ifaceRaw, $0.baseAddress) }
        guard result == kIOReturnSuccess else { return nil }

        return NVMeSMARTLog(bytes: buffer)
    }

    /// Reads ATA/SAT S.M.A.R.T. for external SATA/USB drives. Overall pass/fail is
    /// reliable; life%/temperature/power-on hours are best-effort (USB bridges vary).
    private func readATASMART(service: io_service_t)
        -> (status: String, life: Int?, tempC: Int?, powerOnHours: UInt64?)? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, Self.ataSMARTTypeID,
                                                Self.plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let pluginVtbl = plugin.pointee?.pointee else { return nil }
        defer { _ = IODestroyPlugInInterface(plugin) }

        var ifaceRaw: LPVOID?
        let hr = pluginVtbl.QueryInterface(plugin, CFUUIDGetUUIDBytes(Self.ataSMARTInterfaceID), &ifaceRaw)
        guard hr == S_OK, let ifaceRaw else { return nil }
        let ifacePtr = ifaceRaw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let vtable = ifacePtr.pointee else { return nil }
        let ptr = MemoryLayout<UnsafeRawPointer>.size

        typealias EnableFn = @convention(c) (UnsafeMutableRawPointer?, DarwinBoolean) -> IOReturn
        typealias StatusFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<DarwinBoolean>?) -> IOReturn
        typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        let enableFn = vtable.load(fromByteOffset: 5 * ptr, as: EnableFn.self)
        let statusFn = vtable.load(fromByteOffset: 7 * ptr, as: StatusFn.self)
        let readFn = vtable.load(fromByteOffset: 9 * ptr, as: ReadFn.self)
        let release = vtable.load(fromByteOffset: 3 * ptr, as: ReleaseFn.self)
        defer { _ = release(ifaceRaw) }

        _ = enableFn(ifaceRaw, DarwinBoolean(true))

        var exceeded = DarwinBoolean(false)
        guard statusFn(ifaceRaw, &exceeded) == kIOReturnSuccess else { return nil }
        let smartStatus = exceeded.boolValue ? "Failing" : "Verified"

        var buffer = [UInt8](repeating: 0, count: 512)
        guard buffer.withUnsafeMutableBytes({ readFn(ifaceRaw, $0.baseAddress) }) == kIOReturnSuccess else {
            return (smartStatus, nil, nil, nil)
        }
        let attrs = ATASMARTAttributes.parse(buffer)
        return (smartStatus, attrs.life, attrs.tempC, attrs.powerOnHours)
    }

    // MARK: - Battery Health (via IOKit registry)

    private static let batteryServiceNames = ["AppleSmartBattery", "AppleSmartBatteryCase"]
    private static let capacityKeys = ["NominalChargeCapacity", "AppleRawMaxCapacity", "MaxCapacity"]
    private static let designCapacityKeys = ["DesignCapacity", "DesignCycleCount9C"]

    private func readBatteryHealth() -> (health: Double?, cycleCount: Int?, condition: String?, temperature: Double?) {
        var service: io_service_t = 0
        for name in Self.batteryServiceNames {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
            if service != 0 { break }
        }
        guard service != 0 else { return (nil, nil, nil, nil) }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return (nil, nil, nil, nil)
        }

        let cycleCount = dict["CycleCount"] as? Int
        let currentCap = Self.capacityKeys.lazy.compactMap { dict[$0] as? Int }.first
        let designCap = Self.designCapacityKeys.lazy.compactMap { dict[$0] as? Int }.first
        var health: Double?
        if let c = currentCap, let d = designCap, d > 0 {
            let h = Double(c) / Double(d) * 100
            if h > 0 && h < 200 { health = h }
        }

        let condition = dict["BatteryHealthCondition"] as? String ?? "Normal"

        var temperature: Double?
        if let temp = dict["Temperature"] as? Int {
            let c = Double(temp) / 100.0
            if c > -20 && c < 80 { temperature = c }
        }

        return (health, cycleCount, condition, temperature)
    }

    // MARK: - Process List (via proc_*)

    private func readProcesses() -> (byCPU: [HelperProcess], byMemory: [HelperProcess]) {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return ([], []) }

        let pidCount = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: pidCount)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return ([], []) }

        let actualCount = Int(actualSize) / MemoryLayout<pid_t>.size
        let myPid = getpid()
        let nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC)

        var results: [HelperProcess] = []

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0, pid != myPid else { continue }

            var taskInfo = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size) == size else { continue }

            let memory = physFootprint(for: pid)
            guard memory > 0 else { continue }

            // Delta-based CPU
            let currentUser = taskInfo.pti_total_user
            let currentSystem = taskInfo.pti_total_system
            var cpuPercent: Double = 0
            if let prev = previousCPUTimes[pid] {
                let userDelta = currentUser > prev.user ? currentUser - prev.user : 0
                let systemDelta = currentSystem > prev.system ? currentSystem - prev.system : 0
                let wallDelta = nowNs > prev.wallNs ? nowNs - prev.wallNs : 1
                if wallDelta > 0 {
                    let cpuNs = Double(userDelta + systemDelta) * machToNs
                    cpuPercent = (cpuNs / Double(wallDelta)) * 100
                }
            }
            previousCPUTimes[pid] = (currentUser, currentSystem, nowNs)

            var nameBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            proc_pidpath(pid, &nameBuffer, UInt32(nameBuffer.count))
            let path = String(decoding: nameBuffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            let name = (path as NSString).lastPathComponent

            guard !name.isEmpty, (cpuPercent > 0.1 || memory > 1_048_576) else { continue }
            results.append(HelperProcess(pid: pid, name: name, cpu: cpuPercent, memory: memory, icon: nil))
        }

        // Prune stale PIDs
        let activePIDs = Set(results.map { $0.pid })
        previousCPUTimes = previousCPUTimes.filter { activePIDs.contains($0.key) }

        var byCPU = Array(results.sorted { $0.cpu > $1.cpu }.prefix(5))
        var byMemory = Array(results.sorted { $0.memory > $1.memory }.prefix(5))

        // Fetch icons and display names for the visible processes only
        var seenPIDs = Set<pid_t>()
        for p in byCPU + byMemory { seenPIDs.insert(p.pid) }

        var iconMap: [pid_t: Data?] = [:]
        var nameMap: [pid_t: String] = [:]
        for pid in seenPIDs {
            iconMap[pid] = appIcon(for: pid)
            if let app = NSRunningApplication(processIdentifier: pid),
               let displayName = app.localizedName, !displayName.isEmpty {
                nameMap[pid] = displayName
            }
        }

        byCPU = byCPU.map { p in
            HelperProcess(pid: p.pid, name: nameMap[p.pid] ?? p.name,
                          cpu: p.cpu, memory: p.memory, icon: iconMap[p.pid] ?? nil)
        }
        byMemory = byMemory.map { p in
            HelperProcess(pid: p.pid, name: nameMap[p.pid] ?? p.name,
                          cpu: p.cpu, memory: p.memory, icon: iconMap[p.pid] ?? nil)
        }

        return (byCPU, byMemory)
    }

    // MARK: - App Icons

    private func appIcon(for pid: pid_t) -> Data? {
        let key = NSNumber(value: pid)
        if let cached = iconCache.object(forKey: key) {
            return cached as Data
        }

        guard let app = NSRunningApplication(processIdentifier: pid),
              let icon = app.icon else { return nil }

        // Render at 16x16 to keep TCP payload small
        let smallIcon = NSImage(size: NSSize(width: 16, height: 16))
        smallIcon.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
                  from: NSRect(origin: .zero, size: icon.size),
                  operation: .copy, fraction: 1.0)
        smallIcon.unlockFocus()

        guard let tiff = smallIcon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        iconCache.setObject(pngData as NSData, forKey: key, cost: pngData.count)
        return pngData
    }

    private func physFootprint(for pid: pid_t) -> UInt64 {
        var rusage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &rusage) { ptr in
            ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rusagePtr)
            }
        }
        guard result == 0 else { return 0 }
        return rusage.ri_phys_footprint
    }

    // MARK: - Kill Process (Feature A)

    /// Send a termination signal to a process. The helper runs as the logged-in
    /// user, so it can only kill user-owned processes — system processes fail
    /// with EPERM, which we surface gracefully rather than escalating.
    func killProcess(_ pid: pid_t, force: Bool) -> (ok: Bool, message: String) {
        ProcessSignaller.terminate(pid, force: force)
    }

    // MARK: - Traceroute / MTR (Feature B)

    /// Start (or restart) a continuous traceroute session targeting `host`.
    func startTraceroute(host: String) {
        traceLock.lock()
        defer { traceLock.unlock() }
        // Restart if the target changed; otherwise leave the running session intact.
        if let existing = traceSession, existing.host == host, existing.isRunning {
            return
        }
        traceSession?.stop()
        let session = TraceSession(host: host)
        traceSession = session
        session.start()
    }

    /// Stop any active traceroute session.
    func stopTraceroute() {
        traceLock.lock()
        defer { traceLock.unlock() }
        traceSession?.stop()
        traceSession = nil
    }

    /// Snapshot the current hops + running state of the traceroute session.
    func tracerouteSnapshot() -> (hops: [HelperTraceHop], running: Bool) {
        traceLock.lock()
        let session = traceSession
        traceLock.unlock()
        guard let session else { return ([], false) }
        return (session.snapshot(), session.isRunning)
    }
}

// MARK: - TraceSession

/// Runs `/usr/sbin/traceroute` repeatedly against a host, accumulating
/// MTR-style per-hop statistics (sent/received/loss/last/avg/best/worst).
private final class TraceSession: @unchecked Sendable {
    let host: String

    private let lock = NSLock()
    private var hops = TraceHopAccumulator()
    private var thread: Thread?
    private var stopFlag = false

    /// We never shell-interpolate the host (Process takes an argument array), but we
    /// still reject anything with whitespace or shell metacharacters as defense-in-depth.
    static func isValidHost(_ host: String) -> Bool {
        HostValidation.isValid(host)
    }

    init(host: String) {
        self.host = host
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopFlag && thread != nil
    }

    func start() {
        guard Self.isValidHost(host) else { return }
        let t = Thread { [weak self] in self?.runLoop() }
        t.stackSize = 512 * 1024
        lock.lock(); thread = t; stopFlag = false; lock.unlock()
        t.start()
    }

    func stop() {
        lock.lock(); stopFlag = true; thread = nil; lock.unlock()
    }

    func snapshot() -> [HelperTraceHop] {
        lock.lock(); defer { lock.unlock() }
        return hops.snapshot()
    }

    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopFlag
    }

    private func runLoop() {
        while !shouldStop() {
            runOnePass()
            // Brief pause between full traceroute passes.
            for _ in 0..<10 {
                if shouldStop() { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Runs one full traceroute and folds the results into the accumulators.
    private func runOnePass() {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        // -n no DNS, -w 1 1s wait, -q 1 one probe/hop, -m 30 max hops.
        process.arguments = ["-n", "-w", "1", "-q", "1", "-m", "30", host]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !shouldStop() else { return }

        let output = String(data: data, encoding: .utf8) ?? ""
        lock.lock(); hops.ingest(output: output); lock.unlock()
    }
}
