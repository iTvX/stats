import AppKit
import Kit
import XCTest

final class SensorViewTests: XCTestCase {
    private func sensor(_ key: String, value: Double = 42, type: SensorType = .power) -> Sensor {
        Sensor(key: key, name: key, value: value, group: .sensor, type: type, platforms: [])
    }

    private func fan() -> Fan {
        Fan(id: 0, key: "test-fan", name: "Test fan", minSpeed: 2000, maxSpeed: 6000, value: 2500, mode: .automatic)
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? self.views(type, in: child)
        }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "view callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testColdPopupCreatesNoChartsWhileKeepingHistory() {
        let popup = Popup()
        let sensors = (0..<100).map { self.sensor("cold-\($0)") }
        popup.setup(sensors)
        popup.usageCallback(sensors)
        drainMainQueue()
        let rows = views(SensorView.self, in: popup)
        XCTAssertEqual(rows.count, 100)
        XCTAssertTrue(rows.allSatisfy { $0.chartView == nil })
        XCTAssertTrue(rows.allSatisfy { $0.history.snapshot().compactMap { $0 }.count == 1 })
        XCTAssertTrue(views(LineChartView.self, in: popup).isEmpty)
    }

    func testFirstExpansionAndReopenKeepOriginalHistoryAndGaps() {
        let row = SensorView(sensor("history"), width: 300) {}
        for second in [0.0, 1, 2, 6, 7] {
            row.addHistoryPoint(sensor("history", value: second), at: Date(timeIntervalSince1970: second))
        }
        let before = row.history.snapshot()
        XCTAssertEqual(before.suffix(8).map { $0?.value }, [0, 0.01, 0.02, nil, nil, nil, 0.06, 0.07])
        weak var released: ChartSensorView?
        autoreleasepool {
            row.toggleChart()
            XCTAssertNotNil(row.chartView)
            released = row.chartView
            row.toggleChart()
        }
        drainMainQueue()
        XCTAssertNil(released)
        XCTAssertNil(row.chartView)
        row.addHistoryPoint(sensor("history", value: 8), at: Date(timeIntervalSince1970: 8))
        row.toggleChart()
        XCTAssertNotNil(row.chartView)
        XCTAssertEqual(row.history.snapshot().compactMap { $0?.ts }, [0, 1, 2, 6, 7, 8].map { Date(timeIntervalSince1970: Double($0)) })
        XCTAssertEqual(row.history.snapshot().count, 120)
    }

    func testRepeatedCollapseReleasesViewWithoutDroppingSamples() {
        let row = SensorView(sensor("repeat"), width: 300) {}
        for index in 0..<40 {
            weak var released: ChartSensorView?
            autoreleasepool {
                row.addHistoryPoint(sensor("repeat", value: Double(index)), at: Date(timeIntervalSince1970: Double(index)))
                row.toggleChart()
                released = row.chartView
                row.toggleChart()
            }
            XCTAssertNil(released)
            XCTAssertEqual(row.arrangedSubviews.count, 1)
        }
        XCTAssertEqual(row.history.snapshot().compactMap { $0 }.count, 40)
    }

    func testUnitAndNameChangesBeforeFirstExpansionAndWhileOpen() {
        let row = SensorView(sensor("units"), width: 300) {}
        var changed = sensor("units", type: .current)
        changed.name = "Current sensor"
        row.addHistoryPoint(changed)
        row.update(changed)
        row.toggleChart()
        XCTAssertEqual(row.chartView?.currentSuffix, "A")
        XCTAssertTrue(views(NSTextField.self, in: row).contains { $0.stringValue == "Current sensor" })
        row.addHistoryPoint(sensor("units", type: .voltage))
        XCTAssertEqual(row.chartView?.currentSuffix, "V")
        XCTAssertEqual(row.history.snapshot().compactMap { $0 }.count, 2)
    }

    func testSettingsReloadReusesExpandedSensorRowAndHistory() {
        let popup = Popup()
        popup.setup([sensor("stable"), sensor("other")])
        let row = views(SensorView.self, in: popup)[0]
        row.addHistoryPoint(sensor("stable"))
        row.toggleChart()
        let chart = row.chartView
        popup.setup(reload: true)
        XCTAssertTrue(views(SensorView.self, in: popup)[0] === row)
        XCTAssertTrue(row.chartView === chart)
        XCTAssertEqual(row.history.snapshot().compactMap { $0 }.count, 1)
    }

    func testRemovedRowIsReleasedAndStopsReceivingHistory() {
        let popup = Popup()
        weak var removed: SensorView?
        var history: LineChartData?
        autoreleasepool {
            popup.setup([sensor("removed"), sensor("kept")])
            let row = views(SensorView.self, in: popup)[0]
            removed = row
            history = row.history
            popup.setup([sensor("kept")])
        }
        drainMainQueue()
        XCTAssertNil(removed)
        popup.usageCallback([sensor("removed"), sensor("kept")])
        drainMainQueue()
        XCTAssertEqual(history?.snapshot().compactMap { $0 }.count, 0)
        XCTAssertEqual(views(SensorView.self, in: popup).count, 1)
    }

    func testDisablingOneRowPreservesTheOtherRow() {
        let key = "sensor_disabled-test_popup"
        defer { Store.shared.remove(key) }
        let popup = Popup()
        popup.setup([sensor("disabled-test"), sensor("retained-test")])
        let retained = views(SensorView.self, in: popup)[1]
        Store.shared.set(key: key, value: false)
        popup.setup(reload: true)
        XCTAssertEqual(views(SensorView.self, in: popup).count, 1)
        XCTAssertTrue(views(SensorView.self, in: popup)[0] === retained)
        Store.shared.set(key: key, value: true)
        popup.setup(reload: true)
        XCTAssertEqual(views(SensorView.self, in: popup).count, 2)
        XCTAssertTrue(views(SensorView.self, in: popup)[1] === retained)
    }

    func testChangedSensorKindReplacesTheOldRow() {
        let popup = Popup()
        weak var old: SensorView?
        autoreleasepool {
            popup.setup([sensor("changed-kind")])
            old = views(SensorView.self, in: popup).first
            popup.setup([sensor("changed-kind", type: .current)])
        }
        drainMainQueue()
        XCTAssertNil(old)
        XCTAssertEqual(views(SensorView.self, in: popup).first?.sensorType, .current)
    }

    func testFanRowReuseDropsOldContainerAndDoesNotRepeatHelperOperations() {
        let popup = Popup()
        var row: FanView!
        weak var oldContainer: NSView?
        autoreleasepool {
            popup.setup([fan()])
            row = views(FanView.self, in: popup)[0]
            oldContainer = row.superview
        }
        drainMainQueue()
        let operations = SMCHelper.shared.operations
        autoreleasepool { popup.setup(reload: true) }
        drainMainQueue()
        XCTAssertTrue(views(FanView.self, in: popup)[0] === row)
        XCTAssertNil(oldContainer)
        XCTAssertEqual(SMCHelper.shared.operations, operations)
    }

    func testPopupAndFanRowReleaseWithTheirOwner() {
        weak var releasedPopup: Popup?
        weak var releasedFan: FanView?
        autoreleasepool {
            let popup = Popup()
            popup.setup([fan()])
            releasedPopup = popup
            releasedFan = views(FanView.self, in: popup).first
        }
        drainMainQueue()
        XCTAssertNil(releasedPopup)
        XCTAssertNil(releasedFan)
    }

    func testChangedFanModeRebuildsTheControlRow() {
        let popup = Popup()
        weak var old: FanView?
        autoreleasepool {
            popup.setup([fan()])
            old = views(FanView.self, in: popup).first
            var changed = fan()
            changed.mode = .forced
            popup.setup([changed])
        }
        drainMainQueue()
        XCTAssertNil(old)
        XCTAssertEqual(views(FanView.self, in: popup).first?.fan.mode, .forced)
    }

    func testAppearReplaysLatestHiddenValueWithoutCreatingChart() {
        let popup = Popup()
        popup.setup([sensor("hidden", value: 10)])
        popup.usageCallback([sensor("hidden", value: 10)])
        drainMainQueue()
        popup.usageCallback([sensor("hidden", value: 20)])
        drainMainQueue()
        let row = views(SensorView.self, in: popup)[0]
        XCTAssertEqual(row.history.snapshot().compactMap { $0?.value }, [0.1, 0.2])
        popup.appear()
        XCTAssertTrue(views(NSTextField.self, in: row).contains { $0.stringValue == sensor("hidden", value: 20).formattedPopupValue })
        XCTAssertNil(row.chartView)
        XCTAssertEqual(row.history.snapshot().compactMap { $0 }.count, 2)
    }
}
