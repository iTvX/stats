import AppKit
import Kit
import XCTest

struct ModuleViewFixture {
    let popup: PopupWrapper
    let preview: PreviewWrapper?
    let settings: DeferredStackView & Settings_v
    let notifications: NotificationsWrapper
    let sample: (Int) -> Void
    let histories: () -> [LineChartData]
    let settingsLabel: String?
    let latestLabel: (Int) -> String
}

func descendantViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
    root.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendantViews(type, in: child) }
}

final class ModuleViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }

    private func drain() {
        let done = expectation(description: "main callbacks")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 3)
    }

    func testColdSamplesDoNotConstructViewsAndPreserveHistory() {
        let fixture = makeModuleViewFixture()
        for index in 0..<12 { fixture.sample(index) }
        drain()
        for view in [fixture.popup, fixture.preview, fixture.settings, fixture.notifications].compactMap({ $0 }) {
            XCTAssertTrue(view.subviews.isEmpty)
        }
        for history in fixture.histories() { XCTAssertEqual(history.snapshot().compactMap { $0 }.count, 12) }
    }

    func testFirstOpenAndReopenShowLatestDataWithoutDuplicateHistory() {
        let fixture = makeModuleViewFixture()
        fixture.sample(0)
        fixture.sample(1)
        drain()
        fixture.popup.appear()
        fixture.preview?.prepareContent()
        XCTAssertFalse(fixture.popup.subviews.isEmpty)
        if let preview = fixture.preview { XCTAssertFalse(preview.subviews.isEmpty) }
        for history in fixture.histories() { XCTAssertEqual(history.snapshot().compactMap { $0 }.count, 2) }
        let before = fixture.popup.subviews.count
        fixture.popup.disappear()
        fixture.sample(2)
        drain()
        fixture.popup.appear()
        fixture.preview?.prepareContent()
        drain()
        XCTAssertEqual(fixture.popup.subviews.count, before)
        for history in fixture.histories() { XCTAssertEqual(history.snapshot().compactMap { $0 }.count, 3) }
        let fields = descendantViews(NSTextField.self, in: fixture.popup).map { $0.stringValue }
        XCTAssertTrue(fields.contains { $0.contains(fixture.latestLabel(2)) }, "Missing latest value: \(fixture.latestLabel(2))")
    }

    func testSettingsUseLatestDeviceListOnFirstLoadAndReload() {
        let fixture = makeModuleViewFixture()
        fixture.sample(0)
        fixture.sample(1)
        drain()
        XCTAssertTrue(fixture.settings.subviews.isEmpty)
        fixture.settings.load(widgets: [.mini])
        XCTAssertFalse(fixture.settings.subviews.isEmpty)
        if let label = fixture.settingsLabel {
            let fields = descendantViews(NSTextField.self, in: fixture.settings).map { $0.stringValue }
            let items = descendantViews(NSPopUpButton.self, in: fixture.settings).flatMap { $0.itemTitles }
            XCTAssertTrue((fields + items).contains(label), "Missing cached device: \(label)")
        }
        let count = fixture.settings.subviews.count
        fixture.settings.load(widgets: [.mini])
        XCTAssertEqual(fixture.settings.subviews.count, count)
    }

    func testAlarmsRunBeforeSettingsOpenAndAreNotReplayedByUI() {
        let fixture = makeModuleViewFixture()
        for index in 0..<3 { fixture.sample(index) }
        drain()
        let alarms = fixture.notifications.evaluations.count + fixture.notifications.deliveries.count
        XCTAssertGreaterThan(alarms, 0)
        XCTAssertTrue(fixture.notifications.subviews.isEmpty)
        fixture.notifications.prepareContent()
        XCTAssertFalse(fixture.notifications.subviews.isEmpty)
        fixture.notifications.prepareContent()
        XCTAssertEqual(fixture.notifications.evaluations.count + fixture.notifications.deliveries.count, alarms)
    }

    func testColdOwnersReleasePendingDataAndBuilders() {
        weak var popup: PopupWrapper?
        weak var preview: PreviewWrapper?
        weak var settings: DeferredStackView?
        autoreleasepool {
            let fixture = makeModuleViewFixture()
            fixture.sample(0)
            popup = fixture.popup
            preview = fixture.preview
            settings = fixture.settings
        }
        drain()
        XCTAssertNil(popup)
        XCTAssertNil(preview)
        XCTAssertNil(settings)
    }
}
