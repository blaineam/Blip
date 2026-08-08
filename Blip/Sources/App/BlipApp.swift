import SwiftUI
import AppKit
import Combine
import MillerKit

@main
struct BlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(helperClient: nil)
        }

        // The support surface gets a dedicated, real window. Blip is a
        // menu-bar app: a sheet would attach to the transient popover and be
        // torn down with it, so the rule stands — menu-bar apps host support
        // UI in a real window, never a sheet. Opened via
        // openWindow(id: "support") from the popover footer row and from
        // Settings.
        Window("Support Blip", id: "support") {
            SupportWindowContent(app: .blip)
                .onAppear {
                    // Match the app's "windows show a Dock icon" behavior
                    // (see AppDelegate.showDockIconForWindows) and take focus:
                    // an accessory app's window otherwise opens behind.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    // Drop the Dock icon again if no titled Blip window
                    // remains (async: this window still counts as visible
                    // while it is closing).
                    DispatchQueue.main.async {
                        let anyVisible = NSApp.windows.contains {
                            $0.isVisible && $0.styleMask.contains(.titled)
                        }
                        if !anyVisible { NSApp.setActivationPolicy(.accessory) }
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let monitor = SystemMonitor()
    // Persistent test engines so results/history survive a detail panel being
    // dismissed and reopened, and so interval runs continue while panels are closed.
    private let netSpeedTester = SpeedTester()
    private let diskSpeedTester = DiskSpeedTester()
    private var hostingView: NSHostingView<StatusItemView>?
    private var eventMonitor: Any?
    private var detailPanel: NSPanel?
    private var detailHostingView: NSHostingView<AnyView>?
    private var currentSection: PopoverSection?
    private var settingsWindow: NSWindow?
    private var tracerouteWindow: NSWindow?
    private var screenshotWindow: NSWindow?
    private var dismissWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// When true, the detail panel stops refreshing — used while the pointer is over
    /// the process list so rows don't reshuffle and the two-click kill state survives.
    private var processListFrozen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host this app: skip the menu-bar UI, monitors, and timers
        // entirely so tests stay deterministic and fast. Tests install their
        // own mocked seams via AppIntentsEnvironment.
        if Foundation.ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Foundation.ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil {
            return
        }

        // Make the live services available to App Intents (Shortcuts) in every
        // mode — installed first so an intent arriving right after a cold
        // Shortcut-triggered launch finds them.
        installAppIntentServices()

        // Screenshot automation: inject fictional demo data, then run the REAL
        // menu-bar UI (status item + popover) and pin the popover open so a
        // full-screen capture shows the authentic menu-bar app. No real
        // monitoring, no helper.
        if BlipScreenshotMode.isActive {
            monitor.loadDemoData()
            setupStatusItem()
            setupPopover()
            setupDetailPanel()
            popover.behavior = .applicationDefined   // don't auto-dismiss
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                if let button = statusItem.button {
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
                // Section scenes also reveal that detail panel beside the popover.
                if let section = BlipScreenshotMode.section {
                    showDetailPanel(for: section)
                }
            }
            return
        }
        setupStatusItem()
        setupPopover()
        setupDetailPanel()
        setupEventMonitor()
        setupLiveRefresh()
        monitor.start()

        // Once per cold launch (§4.6: "Launch: once per cold launch"). This
        // used to hang off the Settings scene's .task, which only ran when
        // Settings was opened — so the launch gate for the review ask barely
        // advanced. RatingManager keeps its state in UserDefaults, so this
        // instance and the one on the disk detail panel read the same counters.
        RatingManager(gates: .utility).recordLaunch()

        // Resume persisted interval speed/disk tests so they keep running across restarts
        // without needing to open a detail panel first. (Starts the timers only — no
        // immediate run on launch.)
        let defaults = UserDefaults.standard
        // Interval auto-run only applies to a self-hosted server (never the public widget).
        if defaults.string(forKey: "speedTestServerKind") == "selfhosted" {
            netSpeedTester.server = .openSpeedTest(baseURL: defaults.string(forKey: "speedTestOpenSpeedTestURL") ?? "")
            if defaults.bool(forKey: "netSpeedAutoRun") {
                netSpeedTester.resumeAutoRun(every: defaults.object(forKey: "netSpeedInterval") as? Int ?? 15)
            }
        }
        if defaults.bool(forKey: "diskSpeedAutoRun") {
            diskSpeedTester.resumeAutoRun(every: defaults.object(forKey: "diskSpeedInterval") as? Int ?? 5)
        }

        // If the optional traceroute-map database is installed and auto-update is on,
        // quietly check (throttled to once a day) for a newer monthly DB-IP release.
        GeoIPDatabase.shared.runAutoUpdateCheck()
    }

    /// Installs the real monitor/testers behind the App Intents seams so
    /// Shortcuts actions read live data and share results with the panels.
    private func installAppIntentServices() {
        AppIntentsEnvironment.metricSource = monitor
        AppIntentsEnvironment.tracerouteControl = TracerouteControl(
            start: { [monitor] host in await monitor.startTraceroute(host: host) },
            stop: { [monitor] in await monitor.stopTraceroute() },
            poll: { [monitor] in await monitor.tracerouteHops() }
        )
        AppIntentsEnvironment.openTracerouteWindow = { [weak self] host in
            if let host { UserDefaults.standard.set(host, forKey: "tracerouteTarget") }
            self?.openTracerouteWindow()
        }
        AppIntentsEnvironment.networkSpeedRunner = { [netSpeedTester] server in
            try await netSpeedTester.runOnce(server: server)
        }
        AppIntentsEnvironment.diskSpeedRunner = { [diskSpeedTester] size, mountPoint in
            guard !diskSpeedTester.isRunning else {
                throw SpeedTestRunFailure(message: "A disk speed test is already running.")
            }
            let result = try await IntentDiskSpeedRunner.run(size: size, mountPoint: mountPoint)
            diskSpeedTester.record(result)
            return result
        }
    }

    /// Renders the requested scene (overview popover or a section detail panel)
    /// as a borderless card on a transparent window, sized to fit, for screenshots.
    private func setupScreenshotWindow() {
        let cornerRadius: CGFloat = 20
        let inner: AnyView
        if let section = BlipScreenshotMode.section {
            inner = AnyView(detailContent(for: section).frame(width: 260))
        } else {
            inner = AnyView(PopoverView(monitor: monitor, onHoverSection: nil, onOpenSettings: nil).frame(width: 260))
        }
        let card = inner
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .padding(2)
            .preferredColorScheme(.dark)

        let hosting = NSHostingView(rootView: card)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .normal
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        screenshotWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        SMC.close()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let view = NSHostingView(rootView: StatusItemView(monitor: monitor))
        view.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        hostingView = view

        if let button = statusItem.button {
            button.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                view.topAnchor.constraint(equalTo: button.topAnchor),
                view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 320)
        popover.behavior = .transient
        popover.animates = true

        let popoverView = PopoverView(
            monitor: monitor,
            onHoverSection: { [weak self] section in
                self?.handleSectionHover(section)
            },
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            // The row itself opens the SwiftUI Window scene via
            // openWindow(id: "support"); the delegate only closes the
            // popover so the new window isn't fighting a transient panel
            // for focus.
            onOpenSupport: { [weak self] in
                self?.closeAll()
            }
        )

        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closeAll()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Detail Panel (separate window)

    private func setupDetailPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        detailPanel = panel
    }

    private func handleSectionHover(_ section: PopoverSection?) {
        // Cancel any pending dismiss
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let section = section {
            currentSection = section
            showDetailPanel(for: section)
        } else {
            // Delay dismiss to allow moving mouse to the detail panel
            let work = DispatchWorkItem { [weak self] in
                self?.hideDetailPanel()
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func showDetailPanel(for section: PopoverSection) {
        guard let panel = detailPanel,
              let popoverWindow = popover.contentViewController?.view.window else {
            return
        }

        let cornerRadius: CGFloat = 20
        let wrappedView = makeWrappedView(for: section)

        // Reuse existing hosting view to prevent memory growth
        if let existing = detailHostingView {
            existing.rootView = wrappedView
        } else {
            let hostingView = NSHostingView(rootView: wrappedView)
            hostingView.frame = NSRect(x: 0, y: 0, width: 230, height: 400)
            detailHostingView = hostingView
            panel.contentView = hostingView
        }

        guard let hostingView = detailHostingView else { return }

        // Ensure no opaque background leaks through rounded corners
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.cornerRadius = cornerRadius
        hostingView.layer?.masksToBounds = true
        if #available(macOS 13.0, *) {
            hostingView.layer?.cornerCurve = .continuous
        }

        // Position snug to the left of the popover (1px gap)
        let popoverFrame = popoverWindow.frame

        // Size to fit content exactly. Width is pinned to the content width (260) so a
        // scroll bar can never widen the panel or shift the content; height comes from
        // the fitting size, which the ScrollIfNeeded modifier caps at the screen height.
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let panelWidth: CGFloat = 260
        let panelHeight = min(fittingSize.height, panelMaxHeight)
        let panelX = popoverFrame.minX - panelWidth - 1
        let panelY = popoverFrame.maxY - panelHeight

        panel.setFrame(NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
                       display: true)

        panel.orderFront(nil)
    }

    /// Freeze the panel while the pointer is over the process list (so rows don't
    /// reshuffle and the kill-confirm survives); clear any armed kill when leaving.
    private func setProcessHover(_ hovering: Bool) {
        processListFrozen = hovering
        if !hovering { monitor.pendingKillPID = nil }
    }

    private func hideDetailPanel() {
        detailPanel?.orderOut(nil)
        currentSection = nil
        monitor.pendingKillPID = nil
        // Collapse the Traceroute/MTR disclosure on dismiss (the session keeps running
        // underneath and its values are restored when the user re-expands it).
        UserDefaults.standard.set(false, forKey: "traceExpanded")
    }

    @ViewBuilder
    private func detailContent(for section: PopoverSection) -> some View {
        switch section {
        case .cpu:
            CPUDetailPanel(
                stats: monitor.snapshot.cpu,
                history: monitor.cpuHistory.values,
                topProcesses: monitor.snapshot.topProcessesByCPU,
                onKill: { pid, force in await self.monitor.killProcess(pid: pid, force: force) },
                onProcessHover: { [weak self] hovering in self?.setProcessHover(hovering) },
                armedPID: Binding(get: { self.monitor.pendingKillPID },
                                  set: { self.monitor.pendingKillPID = $0 })
            )
        case .memory:
            MemoryDetailPanel(
                stats: monitor.snapshot.memory,
                history: monitor.memoryHistory.values,
                topProcesses: monitor.snapshot.topProcessesByMemory,
                onKill: { pid, force in await self.monitor.killProcess(pid: pid, force: force) },
                onProcessHover: { [weak self] hovering in self?.setProcessHover(hovering) },
                armedPID: Binding(get: { self.monitor.pendingKillPID },
                                  set: { self.monitor.pendingKillPID = $0 })
            )
        case .disk:
            #if APPSTORE
            DiskDetailPanel(
                stats: monitor.snapshot.disk,
                readHistory: monitor.diskReadHistory.values,
                writeHistory: monitor.diskWriteHistory.values,
                hasIOData: monitor.helperClient.isConnected,
                speedTester: diskSpeedTester
            )
            #else
            DiskDetailPanel(
                stats: monitor.snapshot.disk,
                readHistory: monitor.diskReadHistory.values,
                writeHistory: monitor.diskWriteHistory.values,
                speedTester: diskSpeedTester
            )
            #endif
        case .network:
            NetworkDetailPanel(
                stats: monitor.snapshot.network,
                downloadHistory: monitor.netDownHistory.values,
                uploadHistory: monitor.netUpHistory.values,
                speedTester: netSpeedTester,
                traceStart: { host in await self.monitor.startTraceroute(host: host) },
                traceStop: { await self.monitor.stopTraceroute() },
                tracePoll: { await self.monitor.tracerouteHops() },
                onOpenTracerouteWindow: { [weak self] in self?.openTracerouteWindow() }
            )
        case .gpu:
            GPUDetailPanel(
                stats: monitor.snapshot.gpu,
                history: monitor.gpuHistory.values
            )
        case .thermal:
            ThermalDetailPanel(
                thermalLevel: monitor.snapshot.system.thermalLevel,
                fanStats: monitor.snapshot.fans
            )
        case .battery:
            BatteryDetailPanel(
                stats: monitor.snapshot.battery
            )
        }
    }

    private func closeAll() {
        popover.performClose(nil)
        hideDetailPanel()
    }

    // MARK: - Settings

    private func openSettings() {
        closeAll()

        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(helperClient: monitor.helperClient, monitor: monitor)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Blip Settings", comment: "Title of the settings window")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.center()
        window.setFrameAutosaveName("BlipSettings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        showDockIconForWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Traceroute Window

    func openTracerouteWindow() {
        closeAll()
        if let existing = tracerouteWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = TracerouteWindowView(
            start: { host in await self.monitor.startTraceroute(host: host) },
            stop: { await self.monitor.stopTraceroute() },
            poll: { await self.monitor.tracerouteHops() }
        )
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Traceroute Map", comment: "Title of the traceroute map window")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 620))
        window.center()
        window.setFrameAutosaveName("BlipTraceroute")
        window.isReleasedWhenClosed = false
        window.delegate = self
        tracerouteWindow = window

        window.makeKeyAndOrderFront(nil)
        showDockIconForWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dock icon (only while a real window is open)

    /// Shows the app in the Dock when any Blip window is visible — the menu-bar
    /// popover/panels don't count, matching the "windows show a Dock icon" behavior.
    private func showDockIconForWindows() {
        NSApp.setActivationPolicy(.regular)
    }

    private func updateActivationPolicyForOpenWindows() {
        let anyVisible = [settingsWindow, tracerouteWindow].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
    }

    func windowWillClose(_ notification: Notification) {
        // After this window closes, drop the Dock icon if no Blip windows remain.
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicyForOpenWindows()
        }
    }

    // MARK: - Live Refresh

    private func setupLiveRefresh() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let section = self.currentSection,
                      let panel = self.detailPanel, panel.isVisible,
                      !self.processListFrozen else { return }
                self.refreshDetailContent(for: section)
            }
            .store(in: &cancellables)
    }

    private func refreshDetailContent(for section: PopoverSection) {
        guard detailPanel != nil else { return }
        if let existing = detailHostingView {
            existing.rootView = makeWrappedView(for: section)
        }
    }

    /// The most a detail panel may grow — capped to the visible height of the screen
    /// it appears on (minus a margin) so it always fits regardless of display size /
    /// scaling. Content taller than this scrolls.
    private var panelMaxHeight: CGFloat {
        let screen = popover.contentViewController?.view.window?.screen
            ?? detailPanel?.screen ?? NSScreen.main
        let h = screen?.visibleFrame.height ?? 800
        return max(220, h - 24)
    }

    /// Builds the styled, scroll-when-needed, hover-tracking wrapper around a panel.
    private func makeWrappedView(for section: PopoverSection) -> AnyView {
        let cornerRadius: CGFloat = 20
        return AnyView(
            detailContent(for: section)
                .frame(width: 260)
                .modifier(ScrollIfNeeded(maxHeight: panelMaxHeight))
                .frame(width: 260)
                .background(
                    VisualEffectView(material: .popover, blendingMode: .behindWindow, cornerRadius: cornerRadius)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .onHover { [weak self] hovering in
                    if hovering {
                        self?.dismissWorkItem?.cancel()
                        self?.dismissWorkItem = nil
                    } else {
                        self?.handleSectionHover(nil)
                    }
                }
        )
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closeAll()
        }
    }
}

// MARK: - Scroll-if-needed

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Wraps content in a vertical ScrollView **only when** its natural height exceeds
/// `maxHeight`; otherwise renders it at its natural height. This keeps short panels
/// un-scrolled (and correctly sized) while letting tall ones scroll, without the
/// content ever being clipped or shifted by an always-on scroll view.
struct ScrollIfNeeded: ViewModifier {
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        let measured = content.background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
        Group {
            if contentHeight > maxHeight + 0.5 {
                ScrollView(.vertical) { measured }
                    .frame(height: maxHeight)
                    .scrollIndicators(.visible)
            } else {
                measured
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        if cornerRadius > 0 {
            view.maskImage = Self.roundedMask(cornerRadius: cornerRadius)
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        if cornerRadius > 0 {
            nsView.maskImage = Self.roundedMask(cornerRadius: cornerRadius)
        } else {
            nsView.maskImage = nil
        }
    }

    private static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
