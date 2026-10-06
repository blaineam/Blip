import XCTest

// Launch + query helpers for the macOS UI tests. The app under test is BlipUITestHost
// ("Blip UITest", bundle id com.blainemiller.Blip.uitesthost): the direct app's sources
// under their own bundle id, so -UITestMode's per-launch defaults wipe can never touch the
// real Blip's preferences. In -UITestMode the app shows the real PopoverView in a titled
// window ("blip-uitest-popover") with inline (click-to-expand) details, loaded with the
// screenshot rig's fictional snapshot. No sleeps: everything waits on existence/predicates.

extension XCTestCase {
    static let timeout: TimeInterval = 10

    @discardableResult
    func launchBlip(_ extra: [String] = [], seeded: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestScenario", seeded ? "seeded" : "empty",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        XCTAssertTrue(app.popoverWindow.waitForExistence(timeout: 20), "UI-test window never appeared")
        return app
    }

    @discardableResult
    func wait(_ element: XCUIElement, _ timeout: TimeInterval = XCTestCase.timeout,
              file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Timed out waiting for \(element)",
                      file: file, line: line)
        return element
    }

    /// Waits until the element's displayed text (label, or value for static texts) matches.
    func waitText(_ element: XCUIElement, equals text: String, _ timeout: TimeInterval = XCTestCase.timeout,
                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@ OR value == %@", text, text)
        // Fast path: already true (XCTest's predicate expectation only polls once a second).
        if element.waitForExistence(timeout: timeout), predicate.evaluate(with: element) { return }
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected '\(text)', got '\(element.displayText)'", file: file, line: line)
    }

    func waitText(_ element: XCUIElement, contains text: String, _ timeout: TimeInterval = XCTestCase.timeout,
                  file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        if element.waitForExistence(timeout: timeout), predicate.evaluate(with: element) { return }
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected text containing '\(text)', got '\(element.displayText)'",
                       file: file, line: line)
    }

    func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = XCTestCase.timeout,
                  file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed, "\(element) still exists",
                       file: file, line: line)
    }
}

extension XCUIElement {
    /// What a static text shows: macOS exposes SwiftUI Text through `value`, iOS-style `label` as fallback.
    var displayText: String {
        guard exists else { return "<missing>" }
        if let v = value as? String, !v.isEmpty { return v }
        return label
    }

    func el(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// An element inside this one showing exactly `text` (static text value, or the label of
    /// a copy-to-clipboard address button).
    func text(_ text: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).firstMatch
    }
}

extension XCUIApplication {
    var popoverWindow: XCUIElement { windows["blip-uitest-popover"] }
    var settingsWindow: XCUIElement { windows["blip-settings"] }
    var tracerouteWindow: XCUIElement { windows["blip-traceroute"] }

    /// Clicks a popover row (inline details expand under it) and returns its detail panel.
    @discardableResult
    func expand(_ section: String) -> XCUIElement {
        let row = el("popover.row.\(section)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row \(section)")
        row.click()
        let panel = el("detail.\(section)")
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "detail.\(section) did not expand")
        return panel
    }

    /// Opens Settings from the popover's gear and returns its window.
    @discardableResult
    func openSettings() -> XCUIElement {
        el("popover.settings").click()
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings window never opened")
        return settingsWindow
    }

    /// Settings tab switching (SwiftUI TabView → toolbar/segmented tab buttons on macOS).
    func settingsTab(_ title: String) {
        let match = settingsWindow.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.radioButton.rawValue, XCUIElement.ElementType.tab.rawValue,
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.toolbarButton.rawValue)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10), "no Settings tab \(title)")
        match.click()
    }
}
