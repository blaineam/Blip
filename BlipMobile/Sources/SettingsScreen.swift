import SwiftUI
import MillerKit

// Settings, reached from the gear in the Overview corner — the nav-stack pattern the rest of
// the portfolio uses instead of burning a tab on it. Support/about/rating rows come from
// MillerKit, same as every other app in the suite; only the Blip-specific knobs live here.

struct SettingsScreen: View {
    @AppStorage("mobile.speed.server") private var speedServer = ""
    @AppStorage("mobile.ping.target") private var pingTarget = ""
    @AppStorage("mobile.trace.target") private var traceTarget = ""
    @StateObject private var geo = GeoIPDatabase.shared

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.50:3000", text: $speedServer)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Speed Test Server")
            } footer: {
                Text("A self-hosted OpenSpeedTest server (Docker) or compatible endpoint. The Speed tab's source menu switches between this and the public OpenSpeedTest service — same rule as Blip for Mac: open-source endpoints only, nothing reverse-engineered.")
            }

            Section {
                TextField("Ping target — 1.1.1.1", text: $pingTarget)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Traceroute target — 1.1.1.1", text: $traceTarget)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Network Tools")
            } footer: {
                Text("Defaults to 1.1.1.1 when empty. Hostnames or IPv4 addresses.")
            }

            Section {
                geoRow
            } header: {
                Text("Hop Locations")
            } footer: {
                Text("A free offline IP-location database (DB-IP Lite) that annotates traceroute hops with city and country. Around 100 MB; downloaded once, updated monthly if you leave it installed. Lookups never leave the device.")
            }

            SupportSection(app: .blip, extraContext: ["platform": "iOS"])
            LoveThisAppSection(app: .blip)
            AboutSection(app: .blip)

            Section {
                Text("Everything Blip shows on iOS is what the system honestly exposes to a well-behaved app — no private APIs, no permission grabs. The Mac app's deeper powers (fans, SMART, other apps' processes) have no sandbox-legal iOS equivalent, so they aren't faked here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { geo.loadIfPresent() }
    }

    @ViewBuilder
    private var geoRow: some View {
        switch geo.status {
        case .absent:
            Button { geo.download() } label: {
                Label("Download GeoIP Database", systemImage: "arrow.down.circle")
            }
        case .downloading(let p):
            HStack {
                if p >= 0 { ProgressView(value: p) } else { ProgressView() }
                Button("Cancel") { geo.cancelDownload() }
                    .buttonStyle(.borderless)
            }
        case .ready(let date, let type):
            VStack(alignment: .leading, spacing: 2) {
                Label("Installed — \(type)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Updated \(date.formatted(date: .abbreviated, time: .omitted)) · \(GeoIPDatabase.attribution)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { geo.remove() } label: {
                Label("Remove Database", systemImage: "trash")
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                Button { geo.download() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
            }
        }
    }
}

enum NetworkTargets {
    static var ping: String {
        let v = UserDefaults.standard.string(forKey: "mobile.ping.target")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? "1.1.1.1" : v
    }
    static var trace: String {
        let v = UserDefaults.standard.string(forKey: "mobile.trace.target")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? "1.1.1.1" : v
    }
}
