import XCTest
import SwiftUI
@testable import Blip

/// The AppDelegate pieces that are safe to drive without a menu bar: bench wiring, popover
/// delegate hooks and the shared view helpers that live in BlipApp.swift. The status item,
/// popover and windows themselves are only built by `applicationDidFinishLaunching`, which the
/// unit host deliberately skips.
@MainActor
final class AppDelegateWiringTests: XCTestCase {
    private var savedRunner: (@MainActor (BenchProfile) async -> BenchResult?)!

    override func setUp() async throws {
        savedRunner = AppIntentsEnvironment.benchRunner
    }
    override func tearDown() async throws {
        AppIntentsEnvironment.benchRunner = savedRunner
    }

    func testWireBenchRoutesMonitorThermalSamplesIntoTheBenchBox() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.benchThermalBox.temperatureC())
        delegate.wireBench()
        let sink = try? XCTUnwrap(delegate.monitor.onThermalSample)
        sink?(71.5, 3200)
        XCTAssertEqual(delegate.benchThermalBox.temperatureC(), 71.5)
        XCTAssertEqual(delegate.benchThermalBox.fanRPM(), 3200)
        sink?(nil, nil)
        XCTAssertNil(delegate.benchThermalBox.temperatureC())
        XCTAssertNil(delegate.benchThermalBox.fanRPM())
    }

    func testWireBenchRunnerReturnsNilOnceTheDelegateIsGone() async {
        var delegate: AppDelegate? = AppDelegate()
        delegate?.wireBench()
        delegate = nil
        let result = await AppIntentsEnvironment.benchRunner(.quick)
        XCTAssertNil(result, "the runner holds the delegate weakly and bails when it is gone")
    }

    func testPopoverDelegateHooksWithoutAPopover() {
        let delegate = AppDelegate()
        let popover = NSPopover()
        XCTAssertEqual(delegate.popoverShouldDetach(popover), UserDefaults.standard.bool(forKey: "popoverPinned"))
        delegate.popoverDidDetach(popover)       // no content controller: must not crash
        delegate.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    func testScrollIfNeededOnlyWrapsTallContent() {
        let short = ViewHost.smoke(Color.red.frame(width: 100, height: 40).modifier(ScrollIfNeeded(maxHeight: 200)))
        let tall = ViewHost.smoke(Color.red.frame(width: 100, height: 800).modifier(ScrollIfNeeded(maxHeight: 200)))
        XCTAssertLessThanOrEqual(short.height, 200)
        XCTAssertGreaterThan(tall.height, 0)
    }

    func testVisualEffectViewConfiguresMaterialAndRoundedMask() {
        ViewHost.smoke(Color.clear.frame(width: 50, height: 50)
            .background(VisualEffectView(material: .popover, blendingMode: .behindWindow)))
        ViewHost.smoke(Color.clear.frame(width: 50, height: 50)
            .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, cornerRadius: 8)))
    }
}
