import XCTest
@testable import Blip

// Behaviour that differs between the direct download and the sandboxed App Store build.
// The `unit` Soren suite runs this file as the direct build; `appstore-unit` compiles the
// same bundle with APPSTORE so the other branch executes too.

@MainActor
final class BuildVariantTests: XCTestCase {
    private let missingVolume = "/Volumes/BlipTestNoSuchVolume-\(UUID().uuidString)"

    #if APPSTORE
    func testSandboxedDriveTestNeedsAUserGrantedBookmark() async {
        do {
            _ = try await IntentDiskSpeedRunner.run(size: .small, mountPoint: missingVolume)
            XCTFail("the sandbox can't reach an arbitrary volume")
        } catch let error as IntentDiskSpeedRunner.AccessError {
            XCTAssertTrue(error.message.contains(missingVolume), error.message)
            XCTAssertTrue(error.message.contains("Disk panel"), "tells the user how to grant access")
        } catch {
            XCTFail("expected an AccessError, got \(error)")
        }
    }

    func testAppStoreBuildRoutesKeepAwakeExtrasThroughTheHelper() {
        XCTAssertEqual(keepAwakeHelperState(nil), .absent, "no helper, no lid/jiggle switches")
        XCTAssertFalse(keepAwakeExtrasAvailable(nil))
    }
    #else
    func testDirectDriveTestWritesStraightToTheVolumePath() async {
        do {
            _ = try await IntentDiskSpeedRunner.run(size: .small, mountPoint: missingVolume)
            XCTFail("a missing volume can't be benchmarked")
        } catch {
            XCTAssertFalse(error is IntentDiskSpeedRunner.AccessError, "no bookmark dance outside the sandbox")
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
    }

    func testDirectBuildRunsTheExtrasInProcess() {
        XCTAssertEqual(keepAwakeHelperState(nil), .ready)
    }
    #endif
}
