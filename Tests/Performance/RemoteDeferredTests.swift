import AppKit
import Kit
import XCTest

final class RemoteDeferredTests: XCTestCase {
    func testSignedOutPopupBuildsPromptOnlyWhenOpened() {
        let popup = Popup(.remote)
        popup.authorizationStatus(false)
        XCTAssertTrue(popup.subviews.isEmpty)
        popup.appear()
        XCTAssertFalse(popup.subviews.isEmpty)
        let count = popup.subviews.count
        popup.disappear()
        popup.authorizationStatus(false)
        popup.appear()
        XCTAssertEqual(popup.subviews.count, count)
        popup.disappear()
    }

    func testColdRemoteSettingsDoNotCreateAccountControls() {
        weak var released: Settings?
        autoreleasepool {
            let settings = Settings(.remote)
            released = settings
            XCTAssertTrue(settings.subviews.isEmpty)
            XCTAssertFalse(settings.isContentPrepared)
        }
        XCTAssertNil(released)
    }
}
