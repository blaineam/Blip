import WidgetKit
import SwiftUI

// Blip's widgets — designed around what WidgetKit actually is: a SNAPSHOT gallery, not a live
// monitor. Design rules applied here, deliberately:
//
//   1. One durable fact per widget. A bench score, a storage level, a speed-test result are
//      true until replaced; CPU% or network throughput in a widget is a stale number wearing
//      a live costume, so those don't exist here.
//   2. Never duplicate the OS. iOS already renders battery beautifully — no battery widget.
//   3. Say WHEN. Every tile carries its fact's age; an undated snapshot is a lie of omission.
//   4. Tap lands you on the screen that refreshes the fact (blip://bench, blip://speed, …).
//   5. The app pushes reloads on every new fact (MobileSharedStore); timelines refresh
//      lazily (30 min) otherwise, which respects the widget budget.

// MARK: - Shared look

/// The widgets' shared visual identity: a quiet dark-tinted gradient wash of the widget's
/// accent over the system container — branded at a glance, never loud, correct in both
/// appearances (the wash sits on the adaptive background rather than replacing it).
struct BlipWidgetBackground: View {
    let tint: Color
    var body: some View {
        LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.05), .clear],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Bench score

struct BenchEntry: TimelineEntry {
    let date: Date
    let result: BenchResult?
    let best: Double?
}

struct BenchProvider: TimelineProvider {
    func placeholder(in context: Context) -> BenchEntry {
        // Sample data for the gallery — real entries replace it the moment the timeline loads.
        .init(date: .now, result: BenchProvider.sample, best: BenchProvider.sample.composite)
    }
    static let sample = BenchResult(
        date: .now, profile: .full,
        singleCore: .init(name: "Single-core", score: 690, results: []),
        multiCore: .init(name: "All cores", score: 6300, results: []),
        memory: .init(name: "Memory", score: 1000, results: []),
        gpu: .init(name: "GPU", score: 650, results: []),
        neural: .init(name: "Neural", score: 800, results: []),
        throttleFactor: 0.95, thermalSamples: [], composite: 1300,
        deviceModel: "iPhone", osVersion: "iOS")
    func getSnapshot(in context: Context, completion: @escaping (BenchEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BenchEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(1800))))
    }
    private func load() -> BenchEntry {
        let history = BenchHistory.load(defaults: MobileSharedStore.defaults)
        return .init(date: .now,
                     result: history.last,
                     best: history.filter { $0.profile == .full }.map(\.composite).max())
    }
}

struct BenchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BenchEntry

    var body: some View {
        Group {
            if let r = entry.result { filled(r) } else { empty }
        }
        .containerBackground(for: .widget) { BlipWidgetBackground(tint: .purple) }
        .widgetURL(URL(string: "blip://bench"))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.needle").font(.title2).foregroundStyle(.purple)
            Text("Run your first benchmark").font(.caption2).multilineTextAlignment(.center)
        }
    }

    private func filled(_ r: BenchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Bench", systemImage: "gauge.with.needle")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.purple)
                Spacer()
                if let best = entry.best, best > 0, r.profile == .full {
                    let pct = Int(((r.composite - best) / best * 100).rounded())
                    if pct < 0 {
                        Text("\(pct)%").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                    }
                }
            }
            Text("\(Int(r.composite.rounded()))")
                .font(.system(size: family == .systemSmall ? 34 : 40, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.purple, .blue],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .minimumScaleFactor(0.6)
            if family != .systemSmall {
                HStack(spacing: 10) {
                    stat("1-core", r.singleCore.score)
                    stat("all", r.multiCore.score)
                    stat("mem", r.memory.score)
                    if let gpu = r.gpu { stat("gpu", gpu.score) }
                    if let neural = r.neural { stat("neural", neural.score) }
                }
                if let lost = r.throttlePercentLost, lost > 0 {
                    Label("sustained −\(lost)%", systemImage: "flame")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Text(r.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(Int(value.rounded()))").font(.caption.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct BlipBenchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BlipBench", provider: BenchProvider()) { entry in
            BenchWidgetView(entry: entry)
        }
        .configurationDisplayName("Bench Score")
        .description("Your latest Blip Bench composite — and how it compares with this device's best.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Storage

struct StorageEntry: TimelineEntry {
    let date: Date
    let record: MobileSharedStore.DeviceRecord?
}

struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry {
        .init(date: .now, record: .init(storageTotal: 512_000_000_000, storageFree: 128_000_000_000,
                                        thermalState: 0, batteryLevel: 0.8, date: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(.init(date: .now, record: MobileSharedStore.readDevice()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, record: MobileSharedStore.readDevice())],
                            policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct StorageWidgetView: View {
    let entry: StorageEntry

    var body: some View {
        Group {
            if let d = entry.record, d.storageTotal > 0 {
                let used = Double(d.storageTotal - d.storageFree) / Double(d.storageTotal)
                VStack(alignment: .leading, spacing: 4) {
                    Label("Storage", systemImage: "internaldrive")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    Spacer(minLength: 2)
                    HStack {
                        Spacer(minLength: 0)
                        Gauge(value: used) { EmptyView() } currentValueLabel: {
                            Text("\(Int(used * 100))%")
                                .font(.system(.body, design: .rounded).weight(.bold))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(used > 0.9 ? .red : .orange)
                        .scaleEffect(1.15)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 2)
                    Text("\(ByteCountFormatter.string(fromByteCount: d.storageFree, countStyle: .file)) free")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Label("Open Blip once", systemImage: "internaldrive").font(.caption2)
            }
        }
        .containerBackground(for: .widget) { BlipWidgetBackground(tint: .orange) }
        .widgetURL(URL(string: "blip://overview"))
    }
}

struct BlipStorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BlipStorage", provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry)
        }
        .configurationDisplayName("Storage")
        .description("How full this device is, and what's actually free.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Last speed test

struct SpeedEntry: TimelineEntry {
    let date: Date
    let record: MobileSharedStore.SpeedRecord?
}

struct SpeedProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpeedEntry {
        .init(date: .now, record: .init(downMbps: 940, upMbps: 850, date: .now, interface: "Wi-Fi",
                                        pingMs: 12, loadedPingMs: 31))
    }
    func getSnapshot(in context: Context, completion: @escaping (SpeedEntry) -> Void) {
        completion(.init(date: .now, record: MobileSharedStore.readSpeed()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SpeedEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, record: MobileSharedStore.readSpeed())],
                            policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct SpeedWidgetView: View {
    let entry: SpeedEntry

    var body: some View {
        Group {
            if let r = entry.record {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Speed", systemImage: "speedometer")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.teal)
                        Spacer()
                        Text(r.interface).font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(r.downMbps))")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(.teal)
                            Label("Mbps down", systemImage: "arrow.down")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let up = r.upMbps {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(up))")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(.orange)
                                Label("Mbps up", systemImage: "arrow.up")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let ping = r.pingMs {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(Int(ping))")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                Label(r.loadedPingMs != nil ? "ms idle · \(Int(r.loadedPingMs!)) loaded" : "ms ping",
                                      systemImage: "clock")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    Spacer(minLength: 0)
                    // The honest frame: this is a RESULT, aging in front of you. Tap = retest.
                    Text("tested \(r.date, style: .relative) ago · tap to retest")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Label("Run a speed test in Blip", systemImage: "speedometer").font(.caption2)
            }
        }
        .containerBackground(for: .widget) { BlipWidgetBackground(tint: .teal) }
        .widgetURL(URL(string: "blip://speed"))
    }
}

struct BlipSpeedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BlipSpeed", provider: SpeedProvider()) { entry in
            SpeedWidgetView(entry: entry)
        }
        .configurationDisplayName("Last Speed Test")
        .description("Your most recent result, its network, and its age — tap to run a fresh one.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Bundle

@main
struct BlipWidgetBundle: WidgetBundle {
    var body: some Widget {
        BlipBenchWidget()
        BlipStorageWidget()
        BlipSpeedWidget()
    }
}
