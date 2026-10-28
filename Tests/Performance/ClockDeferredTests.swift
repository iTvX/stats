import AppKit
import Kit
import XCTest

final class ClockDeferredTests: XCTestCase {
    func testColdClockRetainsLatestValueWithoutBuildingCalendar() {
        let popup = Popup(.clock)
        let first = Clock_t(id: "fixture-clock", name: "First", format: "HH:mm:ss", tz: "UTC", value: Date(timeIntervalSince1970: 0))
        let last = Clock_t(id: "fixture-clock", name: "Latest", format: "HH:mm:ss", tz: "UTC", value: Date(timeIntervalSince1970: 10))
        popup.callback([first])
        popup.callback([last])
        XCTAssertTrue(popup.subviews.isEmpty)
        popup.appear()
        XCTAssertEqual(popup.subviews.compactMap { $0 as? ClockView }.count, 1)
        XCTAssertEqual(popup.subviews.compactMap { $0 as? ClockView }.first?.clock.name, "Latest")
        popup.disappear()
        popup.callback([first])
        popup.appear()
        XCTAssertEqual(popup.subviews.compactMap { $0 as? ClockView }.first?.clock.name, "First")
    }

    func testSettingsTableBuildsOnlyOnFirstOpen() {
        let settings = Settings(.clock)
        XCTAssertTrue(settings.subviews.isEmpty)
        settings.load(widgets: [])
        let count = settings.subviews.count
        XCTAssertGreaterThan(count, 0)
        settings.load(widgets: [])
        XCTAssertEqual(settings.subviews.count, count)
    }

    func testColdClockReleasesWithPendingUpdate() {
        weak var released: Popup?
        autoreleasepool {
            let popup = Popup(.clock)
            popup.callback([Clock.local])
            released = popup
        }
        XCTAssertNil(released)
    }
}
