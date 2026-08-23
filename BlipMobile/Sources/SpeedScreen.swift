import SwiftUI

struct SpeedScreen: View {
    @ObservedObject var tester: MobileSpeedTester
    @ObservedObject var stats: DeviceStats
    @State private var liveCurve: [Double] = []
    @FocusState private var serverFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pathBanner
                    gauge
                    if tester.isRunning || !liveCurve.isEmpty {
                        Sparkline(values: liveCurve, tint: .teal, height: 60)
                            .onChange(of: tester.phase) { _, phase in
                                if phase == .download { liveCurve = [] }
                            }
                    }
                    serverField
                    runButton
                    if let r = tester.lastResult { resultCard(r) }
                }
                .padding()
            }
            .navigationTitle("Speed")
        }
    }

    private var pathBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: stats.snapshot.interfaceType == "Cellular"
                  ? "antenna.radiowaves.left.and.right" : "wifi")
            Text("Testing over \(stats.snapshot.interfaceType)")
            if stats.snapshot.isExpensivePath {
                Text("· metered").foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var gauge: some View {
        VStack(spacing: 4) {
            Text(tester.isRunning ? String(format: "%.0f", tester.liveMbps)
                                  : tester.lastResult.map { String(format: "%.0f", $0.downMbps) } ?? "—")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(phaseLabel)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onChange(of: tester.liveMbps) { _, mbps in
            guard tester.isRunning, mbps > 0 else { return }
            liveCurve.append(mbps)
            if liveCurve.count > 120 { liveCurve.removeFirst() }
        }
    }

    private var phaseLabel: String {
        switch tester.phase {
        case .idle: return "Mbps"
        case .download: return "Mbps · downloading"
        case .upload: return "Mbps · uploading"
        case .done: return "Mbps · down"
        case .failed(let why): return why
        }
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OpenSpeedTest server").font(.caption).foregroundStyle(.secondary)
            TextField("192.168.1.50:3000", text: $tester.serverBase)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($serverFocused)
            Text("Self-hosted OpenSpeedTest (Docker) or any compatible server — same rule as Blip for Mac: open-source endpoints only, nothing reverse-engineered.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var runButton: some View {
        Button {
            serverFocused = false
            tester.toggle(interface: stats.snapshot.interfaceType)
        } label: {
            Text(tester.isRunning ? "Cancel" : "Run Speed Test")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tester.isRunning ? .red : .teal)
    }

    private func resultCard(_ r: MobileSpeedResult) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Label(String(format: "%.0f Mbps", r.downMbps), systemImage: "arrow.down")
                if let up = r.upMbps {
                    Label(String(format: "%.0f Mbps", up), systemImage: "arrow.up")
                }
            }
            .font(.system(.body, design: .rounded).weight(.semibold))
            Spacer()
            Text(r.date.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
