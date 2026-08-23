import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// The app ↔ widget contract. Widgets are SNAPSHOTS by platform design — they can't poll, so
// they only ever show durable facts the app recorded: the last bench score (and the best), the
// last speed test, storage, thermal. One suite, tiny keys, reloadTimelines on every write.
//
// NOTE ON THE APP GROUP: BenchHistory already takes a UserDefaults suite, so bench history is
// written straight into the group and the widget reads the same store the panel does.

enum MobileSharedStore {
    static let appGroup = "group.com.blainemiller.Blip"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    struct SpeedRecord: Codable {
        let downMbps: Double
        let upMbps: Double?
        let date: Date
        let interface: String
        // Optional latency pair (second edition — old records decode with nil).
        var pingMs: Double?
        var loadedPingMs: Double?
    }

    struct DeviceRecord: Codable {
        let storageTotal: Int64
        let storageFree: Int64
        let thermalState: Int
        let batteryLevel: Double?
        let date: Date
    }

    static func write(device s: DeviceSnapshot) {
        let record = DeviceRecord(storageTotal: s.storageTotal, storageFree: s.storageFree,
                                  thermalState: s.thermalState, batteryLevel: s.batteryLevel, date: Date())
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: "widget.device")
        }
        reloadWidgets(kind: "BlipStorage")
    }

    static func write(speed: SpeedRecord) {
        if let data = try? JSONEncoder().encode(speed) {
            defaults.set(data, forKey: "widget.speed")
        }
        reloadWidgets(kind: "BlipSpeed")
    }

    static func benchUpdated() {
        reloadWidgets(kind: "BlipBench")
    }

    static func readDevice() -> DeviceRecord? {
        defaults.data(forKey: "widget.device").flatMap { try? JSONDecoder().decode(DeviceRecord.self, from: $0) }
    }

    static func readSpeed() -> SpeedRecord? {
        defaults.data(forKey: "widget.speed").flatMap { try? JSONDecoder().decode(SpeedRecord.self, from: $0) }
    }

    private static func reloadWidgets(kind: String) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        #endif
    }
}
