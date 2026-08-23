import SwiftUI

// Blip for iOS / iPadOS — the honest subset (see DeviceStats) plus the two things a phone
// does BETTER than a Mac here: Blip Bench on Apple's phone silicon, and speed tests from
// wherever you're standing. Widgets deep-link straight to their screen (blip://bench etc.).

@main
struct BlipMobileApp: App {
    @StateObject private var stats = DeviceStats()
    @StateObject private var bench = BenchEngine(thermal: NullThermalSource(),
                                                 defaults: MobileSharedStore.defaults)
    @StateObject private var speed = MobileSpeedTester()
    @State private var tab: Tab = .overview

    enum Tab: String { case overview, bench, speed }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                OverviewScreen(stats: stats)
                    .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.50percent") }
                    .tag(Tab.overview)
                BenchScreen(engine: bench, stats: stats)
                    .tabItem { Label("Bench", systemImage: "gauge.with.needle") }
                    .tag(Tab.bench)
                SpeedScreen(tester: speed, stats: stats)
                    .tabItem { Label("Speed", systemImage: "speedometer") }
                    .tag(Tab.speed)
            }
            .onOpenURL { url in
                // Widget deep links: blip://bench, blip://speed, blip://overview.
                switch url.host ?? url.path.trimmingCharacters(in: .init(charactersIn: "/")) {
                case "bench": tab = .bench
                case "speed": tab = .speed
                default: tab = .overview
                }
            }
        }
    }
}
