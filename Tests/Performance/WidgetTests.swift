import Cocoa
import XCTest
import Kit
import ObjectiveC

private var invalidationKey: UInt8 = 0

private extension NSView {
    @objc func stats_recordNeedsDisplay(_ flag: Bool) {
        if flag, let count = objc_getAssociatedObject(self, &invalidationKey) as? NSNumber {
            objc_setAssociatedObject(self, &invalidationKey, NSNumber(value: count.intValue + 1), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        self.stats_recordNeedsDisplay(flag)
    }
}

final class WidgetPerformanceTests: XCTestCase {
    private func exchangeInvalidationRecorder() {
        let original = class_getInstanceMethod(NSView.self, NSSelectorFromString("setNeedsDisplay:"))!
        let recorder = class_getInstanceMethod(NSView.self, #selector(NSView.stats_recordNeedsDisplay(_:)))!
        method_exchangeImplementations(original, recorder)
    }

    override func setUp() {
        self.exchangeInvalidationRecorder()
    }

    override func tearDown() {
        self.exchangeInvalidationRecorder()
    }

    private func beginRecording(_ view: NSView) {
        objc_setAssociatedObject(view, &invalidationKey, NSNumber(value: 0), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func invalidations(_ view: NSView) -> Int {
        (objc_getAssociatedObject(view, &invalidationKey) as? NSNumber)?.intValue ?? 0
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testMiniSkipsInvisibleValueChanges() {
        let view = Mini(title: "CPU", config: ["Color": SColor.monochrome.key], preview: true)
        view.setValue(0.401)
        drainMainQueue()
        beginRecording(view)
        for index in 1...1000 { view.setValue(0.401 + Double(index) / 1_000_000) }
        drainMainQueue()
        XCTAssertEqual(invalidations(view), 0)
        view.setValue(0.42)
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
    }

    func testMiniPreservesColorThresholdUpdates() {
        let view = Mini(title: "CPU", config: ["Color": SColor.utilization.key], preview: true)
        view.setValue(0.6)
        drainMainQueue()
        beginRecording(view)
        view.setValue(0.6001)
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
    }

    func testMiniUnitsAndLabelsStillInvalidate() {
        let view = Mini(title: "CPU", config: nil, preview: true)
        beginRecording(view)
        view.setSuffix("W")
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
        beginRecording(view)
        view.setTitle("Power")
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
        beginRecording(view)
        view.setSuffix("W")
        view.setTitle("Power")
        drainMainQueue()
        XCTAssertEqual(invalidations(view), 0)
    }

    func testStackSkipsIdenticalTextButUpdatesChangedLabelsAndMembership() {
        let view = StackWidget(title: "Sensors", config: nil, preview: true)
        let values = [Stack_t(key: "power", value: "20W", label: "Power")]
        view.setValues(values)
        drainMainQueue()
        beginRecording(view)
        view.setValues(values)
        drainMainQueue()
        XCTAssertEqual(invalidations(view), 0)
        view.setValues([Stack_t(key: "power", value: "20W", label: "CPU")])
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
        beginRecording(view)
        view.setValues([])
        drainMainQueue()
        XCTAssertGreaterThan(invalidations(view), 0)
    }
}
