import SwiftUI

// Blip for iOS / iPadOS — the honest subset (see DeviceStats) plus the things a phone
// does BETTER than a Mac here: Blip Bench on Apple's phone silicon, speed tests from
// wherever you're standing, and ping/traceroute from the network you're actually on.
// Widgets deep-link straight to their screen (blip://bench etc.).

@main
struct BlipMobileApp: App {
    @StateObject private var stats = DeviceStats()
    @StateObject private var bench = BenchEngine(thermal: NullThermalSource(),
                                                 defaults: MobileSharedStore.defaults)
    @StateObject private var speed = MobileSpeedTester()
    @StateObject private var router = TabRouter()

    enum Tab: String { case overview, bench, speed, network }

    @MainActor
    final class TabRouter: ObservableObject {
        @Published var tab: Tab = .overview
    }

    init() {
        wireIntents()
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $router.tab) {
                OverviewScreen(stats: stats)
                    .tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.50percent") }
                    .tag(Tab.overview)
                BenchScreen(engine: bench, stats: stats)
                    .tabItem { Label("Bench", systemImage: "gauge.with.needle") }
                    .tag(Tab.bench)
                SpeedScreen(tester: speed, stats: stats)
                    .tabItem { Label("Speed", systemImage: "speedometer") }
                    .tag(Tab.speed)
                NetworkToolsScreen()
                    .tabItem { Label("Network", systemImage: "point.3.connected.trianglepath.dotted") }
                    .tag(Tab.network)
            }
            .onOpenURL { url in
                // Widget deep links: blip://bench, blip://speed, blip://network, blip://overview.
                switch url.host ?? url.path.trimmingCharacters(in: .init(charactersIn: "/")) {
                case "bench": router.tab = .bench
                case "speed": router.tab = .speed
                case "network": router.tab = .network
                default: router.tab = .overview
                }
            }
        }
    }

    /// Point the intent seams at the SHARED live objects, so a Shortcuts-run benchmark lands
    /// in the same history the Bench tab shows, and a speed test animates in the Speed tab.
    private func wireIntents() {
        // @StateObject wrappers aren't installed yet inside App.init — capture the wrapped
        // values directly; they're the same instances SwiftUI will install.
        let bench = self.bench
        let speed = self.speed
        let stats = self.stats
        let router = self.router
        MobileIntentsEnvironment.benchRunner = { profile in
            await bench.runAwaiting(profile: profile)
        }
        MobileIntentsEnvironment.speedStarter = {
            guard !speed.isRunning else { return }
            speed.start(interface: stats.snapshot.interfaceType)
        }
        MobileIntentsEnvironment.snapshotProvider = {
            stats.sample()
            // CPU% needs a second host_processor_info sample to have a delta to report.
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            stats.sample()
            return SnapshotExport.markdown(for: stats.snapshot, speedHistory: speed.history)
        }
        MobileIntentsEnvironment.tabSwitcher = { name in
            if let t = Tab(rawValue: name) { router.tab = t }
        }
    }
}
