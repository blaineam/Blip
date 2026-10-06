import XCTest

// Shared launch + query helpers for the iOS/iPadOS UI tests. Every test launches a fresh
// app in -UITestMode (DEBUG-only: isolated defaults, demo fixtures, canned runners, no
// network, animations off) with a pinned language/locale. No sleeps: everything waits on
// element existence or an expectation with a timeout.

enum Scenario: String {
    case seeded, empty
}

extension XCTestCase {
    static let timeout: TimeInterval = 10

    @discardableResult
    func launchBlip(_ scenario: Scenario = .seeded, _ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-UITestScenario", scenario.rawValue,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Waits for `element` to exist, failing the test with a useful message otherwise.
    @discardableResult
    func wait(_ element: XCUIElement, _ timeout: TimeInterval = XCTestCase.timeout,
              file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Timed out waiting for \(element)", file: file, line: line)
        return element
    }

    /// Waits until `element`'s label equals `text`.
    func waitLabel(_ element: XCUIElement, equals text: String, _ timeout: TimeInterval = XCTestCase.timeout,
                   file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label == %@", text)
        // Fast path: already true (XCTest's predicate expectation only polls once a second).
        if element.waitForExistence(timeout: timeout), predicate.evaluate(with: element) { return }
        let exp = expectation(for: predicate, evaluatedWith: element)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "Expected label '\(text)', got '\(element.exists ? element.label : "<missing>")'",
                       file: file, line: line)
    }

    /// Waits until `element`'s label contains `text`.
    func waitLabel(_ element: XCUIElement, contains text: String, _ timeout: TimeInterval = XCTestCase.timeout,
                   file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        if element.waitForExistence(timeout: timeout), predicate.evaluate(with: element) { return }
        let exp = expectation(for: predicate, evaluatedWith: element)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed,
                       "Expected label containing '\(text)', got '\(element.exists ? element.label : "<missing>")'",
                       file: file, line: line)
    }

    /// Taps `element` and waits for `target`. A tap that lands while the previous navigation
    /// is still settling can be dropped by UIKit, so it is re-issued (at most twice more) only
    /// if the destination never appeared — the assertion is still that it does appear.
    func tap(_ element: XCUIElement, expecting target: XCUIElement,
             file: StaticString = #filePath, line: UInt = #line) {
        wait(element, file: file, line: line)
        for _ in 0..<3 {
            if element.isHittable { element.tap() }
            if target.waitForExistence(timeout: 4) { return }
        }
        XCTFail("Tapping \(element) never led to \(target)", file: file, line: line)
    }

    /// Back from the screen titled `title` to the one titled `to`.
    func goBack(from title: String, to destination: String, in app: XCUIApplication,
                file: StaticString = #filePath, line: UInt = #line) {
        tap(app.navigationBars[title].buttons.element(boundBy: 0), expecting: app.navigationBars[destination],
            file: file, line: line)
    }

    /// Waits until `element` no longer exists.
    func waitGone(_ element: XCUIElement, _ timeout: TimeInterval = XCTestCase.timeout,
                  file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
                       "\(element) still exists", file: file, line: line)
    }
}

extension XCUIApplication {
    /// Any element by accessibility identifier.
    func el(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Tab switching that works for the bottom bar (iPhone) and the top tab bar (iPad).
    func tapTab(_ title: String) {
        let barButton = tabBars.buttons[title]
        if barButton.waitForExistence(timeout: 5) {
            barButton.tap()
        } else {
            buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch.tap()
        }
    }

    var navTitle: XCUIElement { navigationBars.firstMatch }

    /// Scrolls the frontmost scroll view / list until `element` is hittable (bounded).
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while (!element.exists || !element.isHittable) && swipes < maxSwipes {
            swipeUp()
            swipes += 1
        }
    }
}
