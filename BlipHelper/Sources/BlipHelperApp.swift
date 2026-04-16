import AppKit
import ServiceManagement

@main
@MainActor
final class BlipHelperAppDelegate: NSObject, NSApplicationDelegate {
    private let server = HelperServer()
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BlipHelperAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register as login item so it starts automatically
        registerLoginItem()

        // Start the TCP server
        guard let port = server.start() else {
            NSLog("BlipHelper: Failed to start server")
            NSApp.terminate(nil)
            return
        }
        NSLog("BlipHelper: Listening on 127.0.0.1:\(port)")

        // Show a minimal menu bar icon
        setupMenuBar()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        SMC.close()
    }

    // MARK: - Login Item

    private func registerLoginItem() {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
                NSLog("BlipHelper: Registered as login item")
            } catch {
                NSLog("BlipHelper: Failed to register login item: \(error)")
            }
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Blip Helper")
            button.image?.size = NSSize(width: 14, height: 14)
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Blip Helper is running", action: nil, keyEquivalent: "")
        menu.items.first?.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Blip Helper", action: #selector(quit(_:)), keyEquivalent: "q")
        statusItem?.menu = menu

        updateLoginItemMenu()
    }

    private func updateLoginItemMenu() {
        guard let menu = statusItem?.menu,
              let loginItem = menu.items.first(where: { $0.action == #selector(toggleLoginItem(_:)) }) else { return }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("BlipHelper: Failed to toggle login item: \(error)")
        }
        updateLoginItemMenu()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
