import SwiftUI

// Settings/About, reached from the gear in the Overview corner — the nav-stack pattern the
// rest of the portfolio uses instead of burning a tab on it.

struct AboutScreen: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Blip").font(.headline)
                        Text("Version \(version)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("What this app shows") {
                Text("Everything iOS honestly exposes to a well-behaved app — no private APIs, no permission grabs. The Mac app's deeper powers (fans, SMART, other apps' processes) have no sandbox-legal iOS equivalent, so they aren't faked here.")
                    .font(.footnote)
            }
            Section("Bench scores") {
                Text("Blip Bench scores are geometric means against fixed reference units frozen at Blip 2.0 — one scale for every Mac and iPhone running Blip, forever. The comparison that matters most is this device against its own history.")
                    .font(.footnote)
            }
            Section("Widgets") {
                Text("Widgets show durable facts — your last bench score, storage, your last speed test — each stamped with its age. iOS widgets can't watch live numbers, and Blip won't pretend otherwise.")
                    .font(.footnote)
            }
            Section {
                Link(destination: URL(string: "https://github.com/blaineam/blip")!) {
                    Label("Source on GitHub (MIT)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/blaineam/blip/issues")!) {
                    Label("Report an issue", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
