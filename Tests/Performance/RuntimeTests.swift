import Cocoa
import XCTest

private final class FixtureReader: Reader<Int> {
    var onRead: (Int) -> Void = { _ in }
    private let countLock = NSLock()
    private var reads = 0
    private var running = 0
    private var peak = 0

    var counts: (reads: Int, peak: Int) {
        self.countLock.lock()
        defer { self.countLock.unlock() }
        return (self.reads, self.peak)
    }

    override func read() {
        self.countLock.lock()
        self.reads += 1
        self.running += 1
        self.peak = max(self.peak, self.running)
        let count = self.reads
        self.countLock.unlock()
        self.onRead(count)
        self.countLock.lock()
        self.running -= 1
        self.countLock.unlock()
    }
}

final class PerformanceTests: XCTestCase {
    override func setUp() {
        Store.shared.integers = [:]
    }

    func testDefaultCadencesAndSavedOverride() {
        let sensor = FixtureReader(.sensors, defaultInterval: ReaderDefaults.sensors)
        sensor.initStoreValues(title: "Sensors")
        XCTAssertEqual(sensor.interval, 3)
        let disk = FixtureReader(.disk, defaultInterval: ReaderDefaults.diskCapacity)
        disk.initStoreValues(title: "Disk")
        XCTAssertEqual(disk.interval, 10)
        Store.shared.integers["Sensors_updateInterval"] = 5
        let custom = FixtureReader(.sensors, defaultInterval: ReaderDefaults.sensors)
        custom.initStoreValues(title: "Sensors")
        XCTAssertEqual(custom.interval, 5)
        let activity = FixtureReader(.disk)
        activity.setInterval(1)
        activity.initStoreValues(title: "Disk")
        XCTAssertEqual(activity.interval, 1)
    }

    func testManualRefreshReturnsBeforeSlowReadFinishes() {
        XCTAssertTrue(Thread.isMainThread)
        let reader = FixtureReader(.CPU)
        let entered = expectation(description: "worker entered")
        let completed = expectation(description: "worker completed")
        let release = DispatchSemaphore(value: 0)
        reader.onRead = { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            completed.fulfill()
        }
        reader.requestRead()
        wait(for: [entered], timeout: 2)
        release.signal()
        wait(for: [completed], timeout: 2)
    }

    func testBurstKeepsOneTrailingRefresh() {
        let reader = FixtureReader(.CPU)
        let entered = expectation(description: "first read")
        let trailing = expectation(description: "trailing read")
        let release = DispatchSemaphore(value: 0)
        reader.onRead = { count in
            XCTAssertFalse(Thread.isMainThread)
            if count == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            } else {
                XCTAssertEqual(count, 2)
                trailing.fulfill()
            }
        }
        reader.requestRead()
        wait(for: [entered], timeout: 2)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in reader.requestRead() }
        release.signal()
        wait(for: [trailing], timeout: 2)
        XCTAssertEqual(reader.counts.reads, 2)
        XCTAssertEqual(reader.counts.peak, 1)
    }

    func testCancelDiscardsQueuedWorkAndAllowsFutureWork() {
        let queue = ReaderWorkQueue()
        let entered = expectation(description: "first work")
        let completed = expectation(description: "first completes")
        let later = expectation(description: "later work")
        let release = DispatchSemaphore(value: 0)
        queue.request {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            completed.fulfill()
        }
        wait(for: [entered], timeout: 2)
        queue.request { XCTFail("cancelled refresh ran") }
        queue.cancelPending()
        release.signal()
        wait(for: [completed], timeout: 2)
        queue.request { later.fulfill() }
        wait(for: [later], timeout: 2)
    }

    func testTimerAndManualRefreshNeverOverlap() {
        let reader = FixtureReader(.CPU)
        reader.initStoreValues(title: "CPU")
        let entered = expectation(description: "first read")
        let trailing = expectation(description: "timer and manual coalesced")
        let release = DispatchSemaphore(value: 0)
        reader.onRead = { count in
            XCTAssertFalse(Thread.isMainThread)
            if count == 1 {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 4), .success)
            } else {
                reader.pause()
                trailing.fulfill()
            }
        }
        reader.start()
        wait(for: [entered], timeout: 2)
        // Keep the first read running across a real timer tick.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.4) {
            reader.requestRead()
            release.signal()
        }
        wait(for: [trailing], timeout: 3)
        reader.stop()
        XCTAssertEqual(reader.counts.reads, 2)
        XCTAssertEqual(reader.counts.peak, 1)
    }

    func testIntervalChangeDoesNotReadOnCallingThread() {
        let reader = FixtureReader(.CPU)
        reader.initStoreValues(title: "CPU")
        let first = expectation(description: "initial read")
        let second = expectation(description: "reset read")
        reader.onRead = { count in
            XCTAssertFalse(Thread.isMainThread)
            if count == 1 { first.fulfill() } else { second.fulfill() }
        }
        reader.start()
        wait(for: [first], timeout: 2)
        reader.setInterval(5)
        wait(for: [second], timeout: 2)
        reader.stop()
        XCTAssertEqual(reader.interval, 5)
    }

    func testPauseDropsTrailingRefreshWithoutBlockingInFlightRead() {
        let reader = FixtureReader(.CPU)
        reader.initStoreValues(title: "CPU")
        let entered = expectation(description: "in flight")
        let completed = expectation(description: "read exits")
        let release = DispatchSemaphore(value: 0)
        reader.onRead = { count in
            XCTAssertEqual(count, 1)
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            completed.fulfill()
        }
        reader.start()
        wait(for: [entered], timeout: 2)
        reader.requestRead()
        reader.pause()
        XCTAssertFalse(reader.active)
        release.signal()
        wait(for: [completed], timeout: 2)
        reader.stop()
        XCTAssertEqual(reader.counts.reads, 1)
    }

    func testLockedPopupRemainsInactiveAfterInitialRefresh() {
        let reader = FixtureReader(.CPU, popup: true)
        reader.initStoreValues(title: "CPU")
        let first = expectation(description: "one initial refresh")
        reader.onRead = { count in
            XCTAssertEqual(count, 1)
            first.fulfill()
        }
        reader.start()
        wait(for: [first], timeout: 2)
        XCTAssertFalse(reader.active)
        reader.stop()
    }

    func testSameDisplayedNumberDoesNotChangePresentation() {
        let first = MiniValuePresentation(value: 0.401, utilizationColor: false, orange: 0.6, red: 0.8)
        XCTAssertEqual(first.text, "40")
        for index in 1...1000 {
            let next = MiniValuePresentation(value: 0.401 + Double(index) / 1_000_000,
                                             utilizationColor: false, orange: 0.6, red: 0.8)
            XCTAssertEqual(next, first)
        }
        XCTAssertNotEqual(first, MiniValuePresentation(value: 0.42, utilizationColor: false, orange: 0.6, red: 0.8))
    }

    func testColorBoundaryInvalidatesEvenWithSameNumber() {
        let first = MiniValuePresentation(value: 0.6, utilizationColor: true, orange: 0.6, red: 0.8)
        let second = MiniValuePresentation(value: 0.6001, utilizationColor: true, orange: 0.6, red: 0.8)
        XCTAssertEqual(first.number, second.number)
        XCTAssertNotEqual(first, second)
    }

    func testStaticColorIgnoresUnseenUtilizationZones() {
        let first = MiniValuePresentation(value: 0.6, utilizationColor: false, orange: 0.6, red: 0.8)
        let second = MiniValuePresentation(value: 0.6001, utilizationColor: false, orange: 0.6, red: 0.8)
        XCTAssertEqual(first, second)
    }

    func testInvalidPresentationValuesDoNotTrap() {
        for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(MiniValuePresentation(value: value, utilizationColor: false, orange: 0.6, red: 0.8).text, "–")
        }
    }
}
