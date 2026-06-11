import Foundation
import SwiftUI
import AppKit
#if !APPSTORE
import IOKit
#endif

final class DiskMonitor: @unchecked Sendable {
    #if !APPSTORE
    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousTimestamp: Date?
    private var cachedSmartStatus: String?
    private var cachedDrives: [DriveHealth] = []
    private var driveReadCount = 0
    private var lastVolumeCount = -1
    #endif

    func read() -> DiskStats {
        var stats = DiskStats()
        stats.volumes = Self.readVolumes()

        #if !APPSTORE
        // Read disk I/O from IOKit (undocumented IOBlockStorageDriver properties)
        readDiskIO(&stats)

        // SMART status (cached, only read once — uses diskutil subprocess)
        if let cached = cachedSmartStatus {
            stats.smartStatus = cached
        } else {
            let smart = Self.readSmartStatus()
            cachedSmartStatus = smart
            stats.smartStatus = smart
        }

        // Per-drive S.M.A.R.T. health (NVMe + ATA/SAT). Read in-process here because
        // the direct build is unsandboxed and has no helper. Refreshed ~once a minute,
        // but also immediately whenever a drive is attached/detached (volume set
        // changes) so a freshly plugged-in USB SSD shows its health right away.
        let volumeCount = stats.volumes.count
        if cachedDrives.isEmpty || driveReadCount % 6 == 0 || volumeCount != lastVolumeCount {
            cachedDrives = Self.readDriveHealth()
        }
        lastVolumeCount = volumeCount
        driveReadCount += 1
        stats.drives = cachedDrives
        #endif

        return stats
    }

    /// Enumerates mounted, visible volumes with name / capacity / free space.
    /// Static so the App Intents layer (VolumeEntity query) can reuse it without
    /// spinning up a full DiskMonitor. Root volume first, then alphabetical.
    static func readVolumes() -> [VolumeInfo] {
        var volumes: [VolumeInfo] = []
        let fileManager = FileManager.default

        guard let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                             .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey],
            options: [.skipHiddenVolumes]
        ) else {
            return volumes
        }

        for url in volumeURLs {
            guard let resources = try? url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ]) else { continue }

            let name = resources.volumeName ?? url.lastPathComponent
            let total = UInt64(resources.volumeTotalCapacity ?? 0)
            // `…ForImportantUsage` is accurate for the APFS boot volume (it accounts for
            // purgeable space) but returns 0 on external / non-APFS volumes (exFAT, etc.),
            // which made every external drive read as 100% full. Fall back to the plain
            // available capacity, then to statfs, so external drives report correctly.
            let important = resources.volumeAvailableCapacityForImportantUsage ?? 0
            let plain = Int64(resources.volumeAvailableCapacity ?? 0)
            var free = UInt64(max(0, important > 0 ? important : plain))
            if free == 0 { free = Self.statfsFreeBytes(url.path) }

            guard total > 0 else { continue }

            volumes.append(VolumeInfo(
                name: name,
                mountPoint: url.path,
                totalBytes: total,
                freeBytes: free
            ))
        }

        // Sort: root volume first, then alphabetically
        volumes.sort { a, b in
            if a.mountPoint == "/" { return true }
            if b.mountPoint == "/" { return false }
            return a.name < b.name
        }
        return volumes
    }

    /// Free bytes via `statfs` — a reliable cross-filesystem fallback for volumes where
    /// the URL capacity keys return 0 (e.g. external exFAT/FAT drives).
    private static func statfsFreeBytes(_ path: String) -> UInt64 {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return 0 }
        return UInt64(s.f_bavail) * UInt64(s.f_bsize)
    }

    #if !APPSTORE
    private static func readSmartStatus() -> String {
        let task = Foundation.Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["info", "disk0"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.components(separatedBy: "\n") {
                if line.contains("SMART Status") {
                    let parts = line.components(separatedBy: ":")
                    if parts.count >= 2 {
                        return parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {}
        return ""
    }

    /// IOKit class names for disk I/O — Apple may change on future storage controllers.
    private static let diskIOServiceNames = [
        "IOBlockStorageDriver",
        "IONVMeBlockStorageDriver",
    ]

    private func readDiskIO(_ stats: inout DiskStats) {
        var iterator: io_iterator_t = 0
        var matched = false
        for serviceName in Self.diskIOServiceNames {
            guard let matching = IOServiceMatching(serviceName) else { continue }
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess {
                matched = true
                break
            }
        }
        guard matched else { return }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        var entry: io_object_t = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let ioStats = dict["Statistics"] as? [String: Any] else {
                continue
            }

            if let read = ioStats["Bytes (Read)"] as? UInt64 {
                totalRead += read
            }
            if let write = ioStats["Bytes (Write)"] as? UInt64 {
                totalWrite += write
            }
        }

        // Expose cumulative totals since boot
        stats.totalBytesRead = totalRead
        stats.totalBytesWritten = totalWrite

        let now = Date()
        if let prev = previousTimestamp {
            let interval = now.timeIntervalSince(prev)
            if interval > 0 {
                stats.readBytesPerSec = totalRead > previousReadBytes
                    ? UInt64(Double(totalRead - previousReadBytes) / interval)
                    : 0
                stats.writeBytesPerSec = totalWrite > previousWriteBytes
                    ? UInt64(Double(totalWrite - previousWriteBytes) / interval)
                    : 0
            }
        }
        previousReadBytes = totalRead
        previousWriteBytes = totalWrite
        previousTimestamp = now
    }

    // MARK: - Drive Health (S.M.A.R.T. via IONVMeSMARTUserClient)

    // CFUUIDs (computed for concurrency-safety; CFUUIDGetConstantUUIDWithBytes is cached).
    private static var plugInInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
    private static var nvmeSMARTTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    }
    private static var nvmeSMARTInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    }
    // kIOATASMARTUserClientTypeID (also surfaced as SATSMARTLib.plugin for USB bridges)
    private static var ataSMARTTypeID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0x24, 0x51, 0x4B, 0x7A, 0x28, 0x04, 0x11, 0xD6, 0x8A, 0x02, 0x00, 0x30, 0x65, 0x70, 0x48, 0x66)
    }
    // kIOATASMARTInterfaceID
    private static var ataSMARTInterfaceID: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil,
            0x08, 0xAB, 0xE2, 0x1C, 0x20, 0xD4, 0x11, 0xD6, 0x8D, 0xF6, 0x00, 0x03, 0x93, 0x5A, 0x76, 0xB2)
    }

    /// Reads NVMe S.M.A.R.T. health for all NVMe-SMART-capable block storage devices
    /// (internal Apple SSD + NVMe enclosures). Unprivileged — Apple publishes the user
    /// client in the IORegistry, so no root is required.
    static func readDriveHealth() -> [DriveHealth] {
        var drives: [DriveHealth] = []
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

            let name = (deviceChars?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Drive"
            let medium = deviceChars?["Medium Type"] as? String ?? ""
            let location = protocolChars?["Physical Interconnect Location"] as? String ?? ""
            let interconnect = protocolChars?["Physical Interconnect"] as? String ?? ""
            let bsdName = dict["BSD Name"] as? String ?? ""
            let isInternal = location.localizedCaseInsensitiveContains("internal")

            if interconnect.localizedCaseInsensitiveContains("Virtual") { continue }
            let displayName = name.isEmpty ? "Drive" : name

            if (dict["NVMe SMART Capable"] as? Bool) ?? false {
                // NVMe path — full health log (internal SSD + NVMe enclosures).
                guard let log = readNVMeSMARTLog(service: entry) else { continue }
                drives.append(DriveHealth(
                    name: displayName,
                    bsdName: bsdName,
                    isInternal: isInternal,
                    medium: interconnect.isEmpty ? (medium.isEmpty ? "NVMe" : medium) : interconnect,
                    smartStatus: log.criticalWarning == 0 ? "Verified" : "Failing",
                    percentageUsed: Int(log.percentUsed),
                    availableSpare: Int(log.availableSpare),
                    availableSpareThreshold: Int(log.spareThreshold),
                    temperatureCelsius: Int(log.temperatureKelvin) - 273,
                    bytesWritten: log.dataUnitsWritten &* 512_000,
                    bytesRead: log.dataUnitsRead &* 512_000,
                    powerOnHours: log.powerOnHours,
                    powerCycles: log.powerCycles,
                    unsafeShutdowns: log.unsafeShutdowns,
                    mediaErrors: log.mediaErrors,
                    criticalWarning: Int(log.criticalWarning)
                ))
            } else if (dict["SMART Capable"] as? Bool) ?? false {
                // ATA/SAT path — external SATA/USB SSDs. Overall pass/fail is reliable;
                // life%/temp/hours are best-effort (USB bridges vary in what they expose).
                guard let ata = readATASMART(service: entry) else { continue }
                drives.append(DriveHealth(
                    name: displayName,
                    bsdName: bsdName,
                    isInternal: isInternal,
                    medium: interconnect.isEmpty ? (medium.isEmpty ? "SATA" : medium) : interconnect,
                    smartStatus: ata.status,
                    percentageUsed: ata.life.map { max(0, 100 - $0) },
                    availableSpare: nil,
                    availableSpareThreshold: nil,
                    temperatureCelsius: ata.tempC,
                    bytesWritten: nil,
                    bytesRead: nil,
                    powerOnHours: ata.powerOnHours,
                    powerCycles: nil,
                    unsafeShutdowns: nil,
                    mediaErrors: nil,
                    criticalWarning: ata.status == "Failing" ? 1 : 0
                ))
            }
        }
        return drives
    }

    private struct NVMeSMARTLog {
        var criticalWarning: UInt8
        var temperatureKelvin: UInt16
        var availableSpare: UInt8
        var spareThreshold: UInt8
        var percentUsed: UInt8
        var dataUnitsRead: UInt64
        var dataUnitsWritten: UInt64
        var powerCycles: UInt64
        var powerOnHours: UInt64
        var unsafeShutdowns: UInt64
        var mediaErrors: UInt64
    }

    /// Reads the 512-byte NVMe SMART/Health log via the IONVMeSMARTUserClient plug-in.
    /// `SMARTReadData` sits at vtable byte offset 40 (IUNKNOWN_C_GUTS + UInt16
    /// version/revision); `Release` at offset 24.
    private static func readNVMeSMARTLog(service: io_service_t) -> NVMeSMARTLog? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, nvmeSMARTTypeID,
                                                plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let pluginVtbl = plugin.pointee?.pointee else { return nil }
        defer { _ = IODestroyPlugInInterface(plugin) }

        var ifaceRaw: LPVOID?
        let hr = pluginVtbl.QueryInterface(plugin, CFUUIDGetUUIDBytes(nvmeSMARTInterfaceID), &ifaceRaw)
        guard hr == S_OK, let ifaceRaw else { return nil }

        let ifacePtr = ifaceRaw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let vtable = ifacePtr.pointee else { return nil }

        typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
        let ptrSize = MemoryLayout<UnsafeRawPointer>.size
        let readData = vtable.load(fromByteOffset: 5 * ptrSize, as: ReadFn.self)
        let release = vtable.load(fromByteOffset: 3 * ptrSize, as: ReleaseFn.self)
        defer { _ = release(ifaceRaw) }

        var buffer = [UInt8](repeating: 0, count: 512)
        let result = buffer.withUnsafeMutableBytes { readData(ifaceRaw, $0.baseAddress) }
        guard result == kIOReturnSuccess else { return nil }

        return buffer.withUnsafeBytes { raw -> NVMeSMARTLog in
            func u64(_ off: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: off, as: UInt64.self) }
            return NVMeSMARTLog(
                criticalWarning: raw[0],
                temperatureKelvin: raw.loadUnaligned(fromByteOffset: 1, as: UInt16.self),
                availableSpare: raw[3],
                spareThreshold: raw[4],
                percentUsed: raw[5],
                dataUnitsRead: u64(32),
                dataUnitsWritten: u64(48),
                powerCycles: u64(112),
                powerOnHours: u64(128),
                unsafeShutdowns: u64(144),
                mediaErrors: u64(160)
            )
        }
    }

    /// Reads ATA/SAT S.M.A.R.T. for external SATA/USB drives via the ATA SMART user
    /// client. The overall pass/fail status is reliable; life%/temperature/power-on
    /// hours are best-effort (parsed from the attribute table only when it looks valid,
    /// since USB bridges differ in what — and how — they report).
    private static func readATASMART(service: io_service_t)
        -> (status: String, life: Int?, tempC: Int?, powerOnHours: UInt64?)? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, ataSMARTTypeID,
                                                plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let pluginVtbl = plugin.pointee?.pointee else { return nil }
        defer { _ = IODestroyPlugInInterface(plugin) }

        var ifaceRaw: LPVOID?
        let hr = pluginVtbl.QueryInterface(plugin, CFUUIDGetUUIDBytes(ataSMARTInterfaceID), &ifaceRaw)
        guard hr == S_OK, let ifaceRaw else { return nil }
        let ifacePtr = ifaceRaw.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        guard let vtable = ifacePtr.pointee else { return nil }
        let ptr = MemoryLayout<UnsafeRawPointer>.size

        // Vtable: IUNKNOWN(0-3) + version/revision(4) + EnableDisable(5) + EnableAutosave(6)
        //       + ReturnStatus(7) + ExecuteOffline(8) + ReadData(9)
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
        let statusOK = statusFn(ifaceRaw, &exceeded) == kIOReturnSuccess
        guard statusOK else { return nil }
        let smartStatus = exceeded.boolValue ? "Failing" : "Verified"

        var life: Int?
        var tempC: Int?
        var poh: UInt64?
        var buffer = [UInt8](repeating: 0, count: 512)
        if buffer.withUnsafeMutableBytes({ readFn(ifaceRaw, $0.baseAddress) }) == kIOReturnSuccess {
            // Attribute table at offset 2, 12 bytes/entry. Only trust entries with a
            // plausible structure (known ID + sane normalized value) — bridges that
            // return non-standard blobs simply yield nil for these.
            let lifeIDs: Set<UInt8> = [231, 233, 202, 169, 177, 173]
            for i in 0..<30 {
                let off = 2 + i * 12
                guard off + 11 < buffer.count else { break }
                let id = buffer[off]
                guard id != 0, id != 0xFF else { continue }
                let current = Int(buffer[off + 3])
                if lifeIDs.contains(id), current >= 1, current <= 100, life == nil {
                    life = current
                }
                if id == 194 {  // temperature — normalized current value is °C on most SSDs
                    if current > 0, current < 120 { tempC = current }
                }
                if id == 9 {    // power-on hours (raw, 6 bytes LE)
                    var h: UInt64 = 0
                    for b in 0..<6 { h |= UInt64(buffer[off + 5 + b]) << (8 * b) }
                    if h > 0, h < 1_000_000 { poh = h }
                }
            }
        }
        return (smartStatus, life, tempC, poh)
    }
    #endif
}

// MARK: - Disk Speed Benchmark

/// Low-level sequential disk benchmark. Writes then reads a temp file using
/// uncached (`F_NOCACHE`) POSIX I/O so the numbers reflect the storage device
/// rather than the unified buffer cache / RAM.
///
/// Sandbox note: this benchmarks the volume hosting the app container's temp
/// directory (the boot / internal volume under the App Store sandbox). Testing
/// arbitrary external volumes is a future improvement — it would require a
/// user-selected, security-scoped bookmark and is out of scope here.
enum DiskBenchmark {
    /// Selectable workload sizes for the benchmark.
    enum Size: Int, CaseIterable, Identifiable, Sendable {
        case small = 128   // MB
        case medium = 512
        case large = 1024

        var id: Int { rawValue }
        var bytes: Int { rawValue * 1_000_000 }
        var label: String { "\(rawValue) MB" }
    }

    /// Which phase of the benchmark is currently running.
    enum Phase: Sendable, Equatable {
        case idle
        case writing
        case reading
        case randomRead
    }

    /// 16 MB transfer buffer.
    private static let blockSize = 16 * 1_000_000
    /// Number of random 4 KB reads for the IOPS measurement.
    private static let randomReadCount = 2_000
    private static let randomBlockSize = 4_096

    struct CancelledError: Error {}

    /// Runs the full benchmark off the caller's thread is the caller's job;
    /// this function performs blocking POSIX I/O and must not run on the main
    /// thread. `progress` is invoked with the running phase and 0...1 fraction.
    /// `isCancelled` is polled between blocks so the run can be aborted.
    static func run(
        size: Size,
        directory: URL? = nil,
        progress: @Sendable (Phase, Double) -> Void,
        isCancelled: @Sendable () -> Bool
    ) throws -> DiskSpeedResult {
        // Write into the chosen directory (a user-selected volume) or the app's temp
        // dir (the boot volume) by default.
        let tmpDir = directory ?? FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("blip-speedtest-\(UUID().uuidString).bin")
        let path = fileURL.path

        // Always clean up the temp file, even on error / cancellation.
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let totalBytes = size.bytes

        // One reusable, page-aligned-ish data buffer filled with non-zero bytes
        // (avoid all-zero pages which some filesystems may compress/sparse).
        var buffer = [UInt8](repeating: 0, count: blockSize)
        for i in 0..<blockSize { buffer[i] = UInt8(truncatingIfNeeded: i &* 2654435761) }

        // MARK: Write pass
        let writeFD = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard writeFD >= 0 else { throw posixError() }
        _ = fcntl(writeFD, F_NOCACHE, 1)

        var written = 0
        let writeStart = Date()
        while written < totalBytes {
            if isCancelled() { close(writeFD); throw CancelledError() }
            let chunk = min(blockSize, totalBytes - written)
            let n = buffer.withUnsafeBytes { ptr -> Int in
                write(writeFD, ptr.baseAddress, chunk)
            }
            guard n == chunk else { close(writeFD); throw posixError() }
            written += chunk
            progress(.writing, Double(written) / Double(totalBytes))
        }
        fsync(writeFD)
        close(writeFD)
        let writeElapsed = Date().timeIntervalSince(writeStart)
        let writeMBps = writeElapsed > 0 ? Double(totalBytes) / 1_000_000 / writeElapsed : 0

        if isCancelled() { throw CancelledError() }

        // MARK: Read pass (re-open uncached)
        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { throw posixError() }
        _ = fcntl(readFD, F_NOCACHE, 1)

        var readBuffer = [UInt8](repeating: 0, count: blockSize)
        var readTotal = 0
        let readStart = Date()
        while readTotal < totalBytes {
            if isCancelled() { close(readFD); throw CancelledError() }
            let chunk = min(blockSize, totalBytes - readTotal)
            let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                read(readFD, ptr.baseAddress, chunk)
            }
            guard n > 0 else { break }
            readTotal += n
            progress(.reading, Double(readTotal) / Double(totalBytes))
        }
        let readElapsed = Date().timeIntervalSince(readStart)
        let readMBps = readElapsed > 0 ? Double(readTotal) / 1_000_000 / readElapsed : 0

        // MARK: Random read IOPS (optional, reuses the read descriptor)
        var randomReadIOPS: Double? = nil
        if !isCancelled(), totalBytes > randomBlockSize {
            progress(.randomRead, 0)
            var smallBuffer = [UInt8](repeating: 0, count: randomBlockSize)
            let maxOffset = off_t(totalBytes - randomBlockSize)
            var completed = 0
            let randomStart = Date()
            var seed = UInt64(0x9E3779B97F4A7C15)
            for i in 0..<randomReadCount {
                if isCancelled() { break }
                // xorshift for cheap pseudo-random offsets
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let offset = off_t(seed % UInt64(maxOffset))
                lseek(readFD, offset, SEEK_SET)
                let n = smallBuffer.withUnsafeMutableBytes { ptr -> Int in
                    read(readFD, ptr.baseAddress, randomBlockSize)
                }
                if n <= 0 { break }
                completed += 1
                if i % 128 == 0 {
                    progress(.randomRead, Double(i) / Double(randomReadCount))
                }
            }
            let randomElapsed = Date().timeIntervalSince(randomStart)
            if randomElapsed > 0 && completed > 0 {
                randomReadIOPS = Double(completed) / randomElapsed
            }
        }
        close(readFD)

        return DiskSpeedResult(
            writeMBps: writeMBps,
            readMBps: readMBps,
            randomReadIOPS: randomReadIOPS,
            timestamp: Date()
        )
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}

/// Observable driver for the Speed Test UI. Owns the running task, progress,
/// the latest result, a short history, and the optional auto-run timer.
@MainActor
final class DiskSpeedTester: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase: DiskBenchmark.Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastResult: DiskSpeedResult?
    @Published private(set) var history: [DiskSpeedResult] = []
    @Published var size: DiskBenchmark.Size = .medium

    @Published var autoRun = false {
        didSet {
            if autoRun {
                startTimer()
                if !suppressImmediateRun, autoRunAllowedNow, !isRunning { start() }   // instant feedback
            } else {
                stopTimer()
            }
        }
    }
    /// Auto-run interval in minutes.
    @Published var intervalMinutes = 5 {
        didSet { if autoRun { startTimer() } }
    }
    /// Set while resuming a persisted schedule at launch so we don't benchmark the disk
    /// on every app start.
    private var suppressImmediateRun = false

    /// Resume a persisted auto-run schedule at app launch: starts the interval timer
    /// WITHOUT an immediate benchmark.
    func resumeAutoRun(every minutes: Int) {
        intervalMinutes = max(1, minutes)
        guard !autoRun else { return }
        suppressImmediateRun = true
        autoRun = true
        suppressImmediateRun = false
    }

    /// Location label shown in the UI ("Boot volume", or the chosen folder name).
    @Published private(set) var locationLabel = "Boot volume"
    /// Set when the last run couldn't write to the chosen location.
    @Published private(set) var lastError: String?

    private static let maxHistory = 10
    private static let bookmarkKey = "diskSpeedTestBookmark"
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init() { restoreLocationLabel() }

    private var bookmarkData: Data? {
        get { UserDefaults.standard.data(forKey: Self.bookmarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bookmarkKey) }
    }

    func toggle() {
        isRunning ? cancel() : start()
    }

    /// Targets a specific mounted volume and immediately benchmarks it. Used by the
    /// per-volume "speed test" buttons in the disk panel so one click picks the drive
    /// and runs the test.
    func runOn(mountPoint: String, label: String) {
        guard !isRunning else { return }
        if mountPoint == "/" {
            useBootVolume()
            start()
            return
        }
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        #if APPSTORE
        // Sandboxed builds can't write to an external volume without user-granted
        // access, so pre-point the open panel at the volume — one click to confirm.
        chooseLocation(startingAt: url)
        if bookmarkData != nil { start() }
        #else
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarkData = data
            locationLabel = label
            lastError = nil
            start()
        } catch {
            lastError = "Couldn't target \(label)"
        }
        #endif
    }

    /// Prompts the user to pick a folder on the volume to benchmark, persisting a
    /// (security-scoped) bookmark so the choice survives relaunch and works sandboxed.
    func chooseLocation(startingAt: URL? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a writable folder on the drive you want to benchmark."
        if let startingAt { panel.directoryURL = startingAt }
        // This is an accessory (menu-bar) app — bring it forward so the panel takes focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            #if APPSTORE
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            bookmarkData = data
            locationLabel = url.lastPathComponent
            lastError = nil
        } catch {
            lastError = "Couldn't save that location"
        }
    }

    /// Reverts to benchmarking the boot volume (the app's temp dir).
    func useBootVolume() {
        bookmarkData = nil
        locationLabel = "Boot volume"
        lastError = nil
    }

    private func restoreLocationLabel() {
        guard let data = bookmarkData else { return }
        var stale = false
        #if APPSTORE
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        if let url = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) {
            locationLabel = url.lastPathComponent
        }
    }

    /// Resolves the chosen directory and begins security-scoped access (caller must
    /// balance with `stopAccessingSecurityScopedResource`). Returns nil for boot volume.
    private func resolveTargetDirectory() -> (url: URL, scoped: Bool)? {
        guard let data = bookmarkData else { return nil }
        var stale = false
        #if APPSTORE
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        let scoped = url.startAccessingSecurityScopedResource()
        return (url, scoped)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        phase = .writing
        progress = 0
        lastError = nil
        let size = self.size
        let target = resolveTargetDirectory()
        let dirURL = target?.url

        task = Task.detached(priority: .utility) {
            let cancelledFlag: @Sendable () -> Bool = { Task.isCancelled }
            let progressHandler: @Sendable (DiskBenchmark.Phase, Double) -> Void = { phase, frac in
                Task { @MainActor [weak self] in
                    self?.phase = phase
                    self?.progress = frac
                }
            }
            var result: DiskSpeedResult?
            var failure: String?
            do {
                result = try DiskBenchmark.run(size: size, directory: dirURL,
                                               progress: progressHandler, isCancelled: cancelledFlag)
            } catch is DiskBenchmark.CancelledError {
                result = nil
            } catch {
                failure = (error as NSError).localizedDescription
            }
            await MainActor.run { [weak self] in
                if let target, target.scoped { target.url.stopAccessingSecurityScopedResource() }
                guard let self else { return }
                if let result {
                    self.lastResult = result
                    self.history.append(result)
                    if self.history.count > Self.maxHistory {
                        self.history.removeFirst(self.history.count - Self.maxHistory)
                    }
                } else if let failure {
                    // Surface the real reason (e.g. permissions, no space) so external-drive
                    // problems are diagnosable rather than a generic message.
                    self.lastError = failure
                }
                self.isRunning = false
                self.phase = .idle
                self.progress = 0
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        phase = .idle
        progress = 0
    }

    /// Records an externally-run benchmark result (e.g. from the RunDriveSpeedTest
    /// App Intent) into the tester's result/history so the Disk panel reflects it.
    func record(_ result: DiskSpeedResult) {
        lastResult = result
        history.append(result)
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
    }

    /// Health % of the drive being tested (set by the UI). Below 30% the *automated*
    /// interval run is skipped to avoid stressing a worn drive. A manual run is never
    /// blocked. nil = unknown (allow).
    var targetHealthRemaining: Int?

    /// Whether an automated run is currently permitted by the health guard.
    var autoRunAllowedNow: Bool {
        guard let h = targetHealthRemaining else { return true }
        return h >= 30
    }

    private func startTimer() {
        stopTimer()
        let interval = TimeInterval(max(1, intervalMinutes) * 60)
        // Use .common run-loop mode so it also fires while menus/popovers are open.
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in
                guard let self, !self.isRunning, self.autoRunAllowedNow else { return }
                self.start()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
