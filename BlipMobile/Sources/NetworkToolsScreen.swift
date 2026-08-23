import SwiftUI
import MapKit

// Ping + traceroute, ported from the Mac's network tools to what iOS grants (ICMP datagram
// sockets — see PingTrace.swift). Targets are configurable in Settings; hops get city/country
// annotations when the offline GeoIP database is installed.

struct NetworkToolsScreen: View {
    @StateObject private var ping = PingRunner()
    @StateObject private var trace = TraceRunner()
    @StateObject private var geo = GeoIPDatabase.shared
    @State private var mode: Mode =
        UserDefaults.standard.string(forKey: "blip.demoNetworkMode") == "trace" ? .trace : .ping

    enum Mode: String, CaseIterable, Identifiable {
        case ping, trace
        var id: String { rawValue }
        var label: String { self == .ping ? "Ping" : "Traceroute" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Tool", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .ping: pingView
                    case .trace: traceView
                    }
                }
                .padding()
            }
            .navigationTitle("Network Tools")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsScreen() } label: { Image(systemName: "gearshape") }
                }
            }
            .onAppear {
                geo.loadIfPresent()
                if DemoSeed.active, ping.samples.isEmpty {
                    ping.seedDemo(DemoSeed.pingSamples)
                    trace.seedDemo(DemoSeed.traceHops)
                }
            }
        }
    }

    // MARK: - Ping

    private var pingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetHeader(NetworkTargets.ping)
            Button {
                ping.toggle(host: NetworkTargets.ping)
            } label: {
                Text(ping.isRunning ? "Stop" : "Start Ping").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(ping.isRunning ? .red : .teal)

            if let err = ping.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }

            if !ping.samples.isEmpty {
                let st = ping.stats
                HStack(spacing: 14) {
                    statPill("sent", "\(st.sent)")
                    statPill("loss", "\(st.lossPercent)%", tint: st.lossPercent > 0 ? .orange : .green)
                    if let avg = st.avgMs { statPill("avg", String(format: "%.0f ms", avg)) }
                    if let mn = st.minMs, let mx = st.maxMs {
                        statPill("min–max", String(format: "%.0f–%.0f", mn, mx))
                    }
                }
                Sparkline(values: ping.samples.compactMap(\.rttMs), tint: .teal, height: 60)
                ForEach(ping.samples.suffix(12).reversed()) { s in
                    HStack {
                        Text("#\(s.sequence)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text(s.rttMs.map { String(format: "%.1f ms", $0) } ?? "timeout")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(s.rttMs == nil ? .orange : .primary)
                    }
                }
            }
        }
    }

    // MARK: - Traceroute

    private var traceView: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetHeader(NetworkTargets.trace)
            Button {
                trace.toggle(host: NetworkTargets.trace)
            } label: {
                Text(trace.isRunning ? "Stop" : "Run Traceroute").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(trace.isRunning ? .red : .indigo)

            if let err = trace.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !geo.isReady && !trace.hops.isEmpty && !DemoSeed.active {
                NavigationLink { SettingsScreen() } label: {
                    Label("Download the GeoIP database in Settings to see hop locations & map",
                          systemImage: "globe")
                        .font(.footnote)
                }
            }
            if geo.isReady || DemoSeed.active {
                TraceHopMap(hops: trace.hops, geo: geo)
            }

            ForEach(trace.hops) { hop in
                hopRow(hop)
            }
            if trace.isRunning {
                HStack { MeasuringDots(); Text("probing…").font(.caption).foregroundStyle(.secondary) }
                    .padding(.leading, 34)
            }
        }
    }

    private func hopRow(_ hop: TraceHop) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(hop.ttl)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let addr = hop.address {
                    HStack(spacing: 6) {
                        Text(addr).font(.callout.monospaced())
                        if hop.isDestination {
                            Image(systemName: "flag.checkered").font(.caption)
                        }
                    }
                    if let loc = geo.lookup(addr), let text = Self.locationText(loc) {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("*").font(.callout.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let rtt = hop.rttMs {
                Text(String(format: "%.1f ms", rtt))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private static func locationText(_ loc: GeoLocation) -> String? {
        let parts = [loc.city, loc.country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func targetHeader(_ target: String) -> some View {
        HStack {
            Label(target, systemImage: "scope").font(.callout.monospaced())
            Spacer()
            NavigationLink { SettingsScreen() } label: {
                Text("Change").font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func statPill(_ name: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(tint)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}


// MARK: - The hop map (#feedback: "trace route must use mapkit to show the hops visually")

/// Geolocated hops on a real map: numbered markers joined by the route line. Private-range
/// hops (your router, CGNAT innards) have no location and are honestly skipped — the list
/// below remains the complete record.
struct TraceHopMap: View {
    let hops: [TraceHop]
    @ObservedObject var geo: GeoIPDatabase
    @State private var position: MapCameraPosition = .automatic

    private struct Placed: Identifiable {
        let id: Int          // ttl
        let coordinate: CLLocationCoordinate2D
        let label: String
        let isDestination: Bool
    }

    private var placed: [Placed] {
        hops.compactMap { hop in
            guard let addr = hop.address else { return nil }
            if DemoSeed.active, let demo = DemoSeed.geoTable[addr] {
                return Placed(id: hop.ttl,
                              coordinate: CLLocationCoordinate2D(latitude: demo.lat, longitude: demo.lon),
                              label: demo.label, isDestination: hop.isDestination)
            }
            guard let loc = geo.lookup(addr) else { return nil }
            let place = [loc.city, loc.countryCode].compactMap { $0 }.joined(separator: ", ")
            return Placed(id: hop.ttl,
                          coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude),
                          label: place.isEmpty ? addr : place,
                          isDestination: hop.isDestination)
        }
    }

    var body: some View {
        let points = placed
        if points.isEmpty {
            EmptyView()
        } else {
            Map(position: $position) {
                if points.count > 1 {
                    MapPolyline(coordinates: points.map(\.coordinate))
                        .stroke(.indigo.opacity(0.75),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 5]))
                }
                ForEach(points) { p in
                    Annotation(p.label, coordinate: p.coordinate) {
                        ZStack {
                            Circle()
                                .fill(p.isDestination ? Color.green : Color.indigo)
                                .frame(width: 22, height: 22)
                                .shadow(radius: 2)
                            Text("\(p.id)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onChange(of: hops.count) { _, _ in position = .automatic }
        }
    }
}
