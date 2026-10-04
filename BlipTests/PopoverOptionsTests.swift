import XCTest
@testable import Blip

/// Pin + inline-details settings as Shortcuts sees them.
final class PopoverOptionsTests: XCTestCase {
    func testDetailPanelStyleIsAValidatedChoice() throws {
        let d = try XCTUnwrap(BlipSettingDescriptor.descriptor(for: DetailPanelStyle.key))
        XCTAssertEqual(d.defaultValue, "beside")
        XCTAssertEqual(SettingsStore.normalize(" INLINE ", for: d), .value("inline"))
        if case .value = SettingsStore.normalize("sideways", for: d) { XCTFail("unknown style accepted") }
    }

    func testPinIsABooleanSetting() throws {
        let d = try XCTUnwrap(BlipSettingDescriptor.descriptor(for: "popoverPinned"))
        XCTAssertEqual(d.defaultValue, "false")
        XCTAssertEqual(SettingsStore.normalize("on", for: d), .value("true"))
    }

    func testEveryStyleRoundTripsThroughItsRawValue() {
        for style in DetailPanelStyle.allCases {
            XCTAssertEqual(DetailPanelStyle(rawValue: style.rawValue), style)
        }
    }
}
