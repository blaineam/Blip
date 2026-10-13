import SwiftUI
import XCTest
@testable import BlipMobile

// Hosts a SwiftUI screen in a real window on the simulator and forces layout, so the view's
// body, ViewBuilders and closures actually execute (and `ImageRenderer`-free assertions can
// read the accessibility tree SwiftUI publishes for it). Tall by default: Lists and
// LazyVGrids only build the rows that fit the window.

@MainActor
final class Hosted {
    let window: UIWindow
    let controller: UIViewController

    /// SwiftUI only builds its accessibility tree once automation/accessibility is enabled
    /// (XCUITest flips this for UI tests). Do the same for the in-process tests, once, so the
    /// hosted screen's labels and identifiers are readable. Test-bundle only; the app never
    /// does this.
    private static let accessibilityEnabled: Bool = {
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return false }
        typealias SetFn = @convention(c) (Bool) -> Void
        var enabled = false
        for name in ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"] {
            if let sym = dlsym(lib, name) {
                unsafeBitCast(sym, to: SetFn.self)(true)
                enabled = true
            }
        }
        return enabled
    }()

    init<V: View>(_ view: V, width: CGFloat = 390, height: CGFloat = 2600) {
        _ = Self.accessibilityEnabled
        controller = UIHostingController(rootView: view)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle()
    }

    /// Several layout passes with a zero-length run-loop turn between them — enough for
    /// SwiftUI to commit state set before/after hosting. Never waits on wall-clock time.
    func settle() {
        for _ in 0..<5 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date())
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Every accessibility node/view reachable from the hosted view.
    private var reachable: [NSObject] {
        var out: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        Self.collect(controller.view, into: &out, seen: &seen, depth: 0)
        return out
    }

    private static func identifier(of obj: NSObject) -> String? {
        if let id = (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier, !id.isEmpty { return id }
        if obj.responds(to: Selector(("accessibilityIdentifier"))),
           let id = obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String,
           !id.isEmpty { return id }
        return nil
    }

    /// Every accessibility label, value and identifier on screen.
    var accessibilityStrings: Set<String> {
        var out = Set<String>()
        for obj in reachable {
            if let l = obj.accessibilityLabel, !l.isEmpty { out.insert(l) }
            if let v = obj.accessibilityValue, !v.isEmpty { out.insert(v) }
            if let id = Self.identifier(of: obj) { out.insert(id) }
        }
        return out
    }

    private static func collect(_ obj: NSObject, into out: inout [NSObject],
                                seen: inout Set<ObjectIdentifier>, depth: Int) {
        guard depth < 60, seen.insert(ObjectIdentifier(obj)).inserted else { return }
        out.append(obj)
        if let els = obj.accessibilityElements {
            for case let e as NSObject in els { collect(e, into: &out, seen: &seen, depth: depth + 1) }
        }
        let count = obj.accessibilityElementCount()
        if count != NSNotFound, count > 0, count < 2_000 {
            for i in 0..<count {
                if let e = obj.accessibilityElement(at: i) as? NSObject {
                    collect(e, into: &out, seen: &seen, depth: depth + 1)
                }
            }
        }
        if let view = obj as? UIView {
            for sub in view.subviews { collect(sub, into: &out, seen: &seen, depth: depth + 1) }
        }
    }

    /// True when any collected string contains `needle`.
    func shows(_ needle: String) -> Bool {
        accessibilityStrings.contains { $0.contains(needle) }
    }

    /// Activates (taps) the control with this accessibility identifier, then settles layout.
    @discardableResult
    func activate(_ id: String) -> Bool {
        defer { settle() }
        for obj in reachable where Self.identifier(of: obj) == id {
            if obj.accessibilityActivate() { return true }
        }
        return false
    }
}

/// Snapshot + restore of the real defaults keys a screen test touches, so nothing a test
/// seeds survives into the simulator's app state.
@MainActor
struct DefaultsGuard {
    private var std: [String: Any?] = [:]
    private var shared: [String: Any?] = [:]

    init(standard: [String] = [], shared sharedKeys: [String] = []) {
        for k in standard { std[k] = UserDefaults.standard.object(forKey: k) }
        for k in sharedKeys { shared[k] = MobileSharedStore.defaults.object(forKey: k) }
    }

    func restore() {
        for (k, v) in std {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        for (k, v) in shared {
            if let v { MobileSharedStore.defaults.set(v, forKey: k) } else { MobileSharedStore.defaults.removeObject(forKey: k) }
        }
    }
}

extension DeviceSnapshot {
    /// A fully populated, device-plausible snapshot for rendering the detail screens.
    static func fixture(model: String = "iPhone18,1") -> DeviceSnapshot {
        var s = DeviceSnapshot()
        s.cpuUsagePercent = 37
        s.batteryLevel = 0.64
        s.batteryState = "Charging"
        s.lowPowerMode = true
        s.storageTotal = 512_000_000_000
        s.storageFree = 200_000_000_000
        s.storageOpportunistic = 230_000_000_000
        s.memoryPhysical = 12 << 30
        s.memoryAppAvailable = 6 << 30
        s.memFree = 2 << 30; s.memActive = 4 << 30; s.memInactive = 2 << 30
        s.memWired = 1 << 30; s.memCompressed = 1 << 29
        s.appFootprint = 80 << 20
        s.thermalState = 1
        s.uptime = 3 * 86_400 + 3_600
        s.bootDate = Date(timeIntervalSinceNow: -4 * 86_400)
        s.model = model
        s.osVersion = "Version 27.0 (Build 24A1)"
        s.interfaceType = "Cellular"
        s.isExpensivePath = true
        s.isConstrainedPath = true
        s.vpnActive = true
        s.radioTech = "5G"
        s.localIPs = ["en0 192.0.2.24", "utun3 198.51.100.9", "pdp_ip0"]
        s.load1 = 1.5; s.load5 = 1.2; s.load15 = 1.0
        s.coresTotal = 6; s.coresPerformance = 2; s.coresEfficiency = 4
        return s
    }
}
