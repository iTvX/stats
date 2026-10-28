import AppKit
import Kit
import XCTest

final class SensorDeferredTests: XCTestCase {
    func testAlarmRunsBeforeNotificationSettingsExist() {
        let key = "sensor_fixture-temperature_notification"
        Store.shared.set(key: key, value: "50")
        defer { Store.shared.remove(key) }
        let sensor = Sensor(key: "fixture-temperature", name: "Fixture sensor", value: 80, group: .sensor, type: .temperature, platforms: [])
        let notifications = Notifications(.sensors)
        notifications.setup([sensor])
        notifications.usageCallback([sensor])
        notifications.usageCallback([sensor])
        XCTAssertEqual(notifications.evaluations.count, 2)
        XCTAssertEqual(notifications.registeredIDs, [sensor.key])
        XCTAssertTrue(notifications.subviews.isEmpty)
        notifications.prepareContent()
        XCTAssertFalse(notifications.subviews.isEmpty)
        notifications.prepareContent()
        XCTAssertEqual(notifications.evaluations.count, 2)
    }

    func testSettingsRetainListBeforeFirstOpenAndRemoveOldRows() {
        let settings = Settings(.sensors)
        let first = Sensor(key: "first", name: "First sensor", value: 1, group: .sensor, type: .temperature, platforms: [])
        let second = Sensor(key: "second", name: "Second sensor", value: 2, group: .sensor, type: .power, platforms: [])
        settings.setList([first])
        settings.setList([second])
        XCTAssertTrue(settings.subviews.isEmpty)
        settings.load(widgets: [.mini])
        XCTAssertEqual(settings.subviews.filter { $0.identifier?.rawValue == "sensor" }.count, 1)
        settings.setList([first, second])
        XCTAssertEqual(settings.subviews.filter { $0.identifier?.rawValue == "sensor" }.count, 2)
        settings.setList([second])
        XCTAssertEqual(settings.subviews.filter { $0.identifier?.rawValue == "sensor" }.count, 1)
    }
}
