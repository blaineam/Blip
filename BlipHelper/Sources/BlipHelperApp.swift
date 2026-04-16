import AppKit
import ServiceManagement

@main
@MainActor
final class BlipHelperAppDelegate: NSObject, NSApplicationDelegate {
    private let server = HelperServer()

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
}
