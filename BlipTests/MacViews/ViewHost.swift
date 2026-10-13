import SwiftUI
import AppKit
import XCTest
@testable import Blip

/// Hosts a SwiftUI view in an AppKit hosting view inside an off-screen, never-shown window,
/// then forces layout and a real draw so every `body`, ViewBuilder branch and modifier closure
/// executes. Nothing is ordered front, so `onAppear`/`task` side effects (network lookups,
/// helper probes, login-item queries) never fire and tests stay hermetic.
@MainActor
enum ViewHost {
    @MainActor struct Rendered {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        var fitting: CGSize { host.fittingSize }
        func close() { window.contentView = nil; window.close() }
    }

    /// A throwaway defaults suite pre-loaded with `prefs`. Hosted views read `@AppStorage`
    /// through it (via `.defaultAppStorage`), so tests never read or write the real Blip prefs.
    static func prefsSuite(_ prefs: [String: Any] = [:]) -> UserDefaults {
        let name = "com.blainemiller.BlipTests.viewhost.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        for (k, v) in prefs { d.set(v, forKey: k) }
        return d
    }

    static func render<V: View>(_ view: V, width: CGFloat = 340, height: CGFloat = 640,
                                prefs: [String: Any] = [:]) -> Rendered {
        let host = NSHostingView(rootView: AnyView(view.defaultAppStorage(prefsSuite(prefs))))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // A real draw pass evaluates canvases and shape/gradient closures too.
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        host.layoutSubtreeIfNeeded()
        return Rendered(host: host, window: window)
    }

    /// Render, assert the view produced a non-empty layout, and tear down.
    @discardableResult
    static func smoke<V: View>(_ view: V, width: CGFloat = 340, prefs: [String: Any] = [:],
                               file: StaticString = #filePath, line: UInt = #line) -> CGSize {
        let r = render(view, width: width, prefs: prefs)
        defer { r.close() }
        XCTAssertGreaterThan(r.fitting.height, 0, "view laid out to zero height", file: file, line: line)
        return r.fitting
    }
}
