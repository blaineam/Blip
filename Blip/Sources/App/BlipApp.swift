import SwiftUI
import AppKit
import Combine

@main
struct BlipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(helperClient: nil)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    private var dismissWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    /// When true, the detail panel stops refreshing — used while the pointer is over
    /// the process list so rows don't reshuffle and the two-click kill state survives.
    private var processListFrozen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        setupDetailPanel()
        setupEventMonitor()
        setupLiveRefresh()
        monitor.start()
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

    private func hideDetailPanel() {
        detailPanel?.orderOut(nil)
        currentSection = nil
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
                onProcessHover: { [weak self] hovering in self?.processListFrozen = hovering }
            )
        case .memory:
            MemoryDetailPanel(
                stats: monitor.snapshot.memory,
                history: monitor.memoryHistory.values,
                topProcesses: monitor.snapshot.topProcessesByMemory,
                onKill: { pid, force in await self.monitor.killProcess(pid: pid, force: force) },
                onProcessHover: { [weak self] hovering in self?.processListFrozen = hovering }
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
                tracePoll: { await self.monitor.tracerouteHops() }
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

        let settingsView = SettingsView(helperClient: monitor.helperClient)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Blip Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.setFrameAutosaveName("BlipSettings")
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
