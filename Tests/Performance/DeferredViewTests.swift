import AppKit
import Kit
import XCTest

final class DeferredViewTests: XCTestCase {
    func testColdViewBuildsOnceAndReplaysLatestValuesInDependencyOrder() {
        let view = DeferredStackView()
        var builds = 0
        var rendered: [String] = []
        view.deferContent { builds += 1 }
        for value in 0..<100 {
            XCTAssertTrue(view.deferUpdate(key: "activity", priority: 2) { rendered.append("activity:\(value)") })
            XCTAssertTrue(view.deferUpdate(key: "capacity", priority: 0) { rendered.append("capacity:\(value)") })
        }
        XCTAssertEqual(builds, 0)
        XCTAssertTrue(rendered.isEmpty)
        view.prepareContent()
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(rendered, ["capacity:99", "activity:99"])
        view.prepareContent()
        XCTAssertEqual(builds, 1)
        XCTAssertEqual(rendered.suffix(2), ["capacity:99", "activity:99"])
    }

    func testReplayCanUpdateItsCacheWithoutRecursion() {
        final class View: DeferredStackView {
            var rendered: [Int] = []
            func update(_ value: Int) {
                if self.deferUpdate(key: "value", action: { [weak self] in self?.update(value) }) { return }
                self.rendered.append(value)
                self.prepareContent()
            }
        }
        let view = View()
        view.deferContent {}
        view.update(1)
        view.update(2)
        view.prepareContent()
        XCTAssertEqual(view.rendered, [2])
        view.update(3)
        XCTAssertEqual(view.rendered, [2])
        view.prepareContent()
        XCTAssertEqual(view.rendered, [2, 3])
    }

    func testColdHistoryIsBoundedAndDiscardedWithRemovedDevice() {
        let view = DeferredStackView()
        view.deferContent {}
        let history = view.history("removed", num: 30)
        for i in 0..<100 {
            var value = DoubleValue(Double(i))
            value.ts = Date(timeIntervalSince1970: Double(i))
            history.append(value)
        }
        XCTAssertEqual(history.snapshot().compactMap { $0?.value }, (70..<100).map(Double.init))
        XCTAssertTrue(view.subviews.isEmpty)
        XCTAssertTrue(view.history("removed", num: 30) === history)
        view.retainHistories([])
        XCTAssertFalse(view.history("removed", num: 30) === history)
    }

    func testColdClosuresDoNotRetainOwner() {
        weak var released: DeferredStackView?
        autoreleasepool {
            let view = DeferredStackView()
            released = view
            view.deferContent { [weak view] in view?.addArrangedSubview(NSView()) }
            view.deferUpdate(key: "value") { [weak view] in view?.prepareContent() }
        }
        XCTAssertNil(released)
    }

    func testNetworkAndGridRefreshDoNotAppendSamples() {
        let download = LineChartData(num: 30)
        let upload = LineChartData(num: 30)
        download.append(DoubleValue(1024))
        upload.append(DoubleValue(512))
        let network = NetworkChartView(num: 30, inHistory: download, outHistory: upload)
        let status = StatusChartData(num: 10)
        status.append(false)
        let grid = GridChartView(grid: (rows: 2, columns: 5), history: status)
        for _ in 0..<10 { network.refresh(); grid.refresh() }
        XCTAssertEqual(download.snapshot().compactMap { $0?.value }, [1024])
        XCTAssertEqual(upload.snapshot().compactMap { $0?.value }, [512])
        XCTAssertEqual(status.snapshot().compactMap { $0?.value }, [0])
    }

    func testWindowAttachmentBuildsContentWithoutShowingAWindow() {
        let view = DeferredStackView()
        var count = 0
        view.deferContent { count += 1 }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        XCTAssertEqual(count, 1)
        XCTAssertFalse(window.isVisible)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(count, 1)
        window.contentView = nil
    }
}
