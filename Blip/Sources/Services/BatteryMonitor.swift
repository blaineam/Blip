import Foundation
import IOKit.ps

final class BatteryMonitor: Sendable {
    func read() async -> BatteryStats {
        var stats = BatteryStats()

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
              !sources.isEmpty else {
            return stats
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            stats.isPresent = true

            if let capacity = info[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = info[kIOPSMaxCapacityKey] as? Int,
               maxCapacity > 0 {
                stats.level = Double(capacity) / Double(maxCapacity) * 100
            }

            if let charging = info[kIOPSIsChargingKey] as? Bool {
                stats.isCharging = charging
            }

            if let source = info[kIOPSPowerSourceStateKey] as? String {
                stats.powerSource = source == kIOPSACPowerValue ? "AC Power" : "Battery"
            }

            if let timeRemaining = info[kIOPSTimeToEmptyKey] as? Int {
                stats.timeRemaining = timeRemaining
            }
        }

        // Read battery health and cycle count from IOKit registry
        await readBatteryHealth(&stats)

        return stats
    }

    private func readBatteryHealth(_ stats: inout BatteryStats) async {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return
        }

        if let cycleCount = dict["CycleCount"] as? Int {
            stats.cycleCount = cycleCount
        }

        // Use NominalChargeCapacity for health — matches macOS Settings app
        // NominalChargeCapacity accounts for calibration, AppleRawMaxCapacity does not
        if let nominalCapacity = dict["NominalChargeCapacity"] as? Int,
           let designCapacity = dict["DesignCapacity"] as? Int,
           designCapacity > 0 {
            stats.health = Double(nominalCapacity) / Double(designCapacity) * 100
        } else if let rawMax = dict["AppleRawMaxCapacity"] as? Int,
                  let designCapacity = dict["DesignCapacity"] as? Int,
                  designCapacity > 0 {
            stats.health = Double(rawMax) / Double(designCapacity) * 100
        }

        // Battery condition (Normal, Service, etc.)
        if let condition = dict["BatteryHealthCondition"] as? String {
            stats.condition = condition
        } else {
            stats.condition = "Normal"
        }

        if let temp = dict["Temperature"] as? Int {
            stats.temperature = Double(temp) / 100.0 // centi-degrees to degrees
        }
    }
}
