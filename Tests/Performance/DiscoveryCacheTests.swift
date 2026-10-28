import Foundation
import XCTest

final class DiscoveryCacheTests: XCTestCase {
    func testHitExpiryAndClockRollback() {
        var time = 0.0
        var loads = 0
        let cache = InvalidatingCache<Int>(lifetime: 30, clock: { time })
        func read() -> Int? { cache.get { loads += 1; return loads } }
        XCTAssertEqual(read(), 1)
        time = 29
        XCTAssertEqual(read(), 1)
        time = 30
        XCTAssertEqual(read(), 2)
        time = 0
        XCTAssertEqual(read(), 3)
    }

    func testDeviceEventInvalidatesBeforeExpiry() {
        let cache = InvalidatingCache<Int>(lifetime: 30)
        XCTAssertEqual(cache.get { 1 }, 1)
        cache.invalidate()
        XCTAssertEqual(cache.get { 2 }, 2)
        XCTAssertEqual(cache.get { 3 }, 2)
    }

    func testFailureIsRetriedSoonWithoutSpinning() {
        var time = 0.0
        let cache = InvalidatingCache<Int>(lifetime: 30, clock: { time })
        XCTAssertNil(cache.get { nil })
        XCTAssertNil(cache.get { XCTFail("failure should briefly coalesce"); return 1 })
        time = 1
        XCTAssertEqual(cache.get { 2 }, 2)
    }

    func testConcurrentReadersShareOneDiscovery() {
        let cache = InvalidatingCache<Int>(lifetime: 30)
        let lock = NSLock()
        var loads = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(cache.get {
                lock.lock()
                loads += 1
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
                return 42
            }, 42)
        }
        XCTAssertEqual(loads, 1)
    }

    func testInvalidationDuringDiscoveryDoesNotRetainStaleSnapshot() {
        let cache = InvalidatingCache<Int>(lifetime: 30)
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = expectation(description: "in-flight discovery")
        DispatchQueue.global().async {
            XCTAssertEqual(cache.get {
                entered.signal()
                XCTAssertEqual(finish.wait(timeout: .now() + 2), .success)
                return 1
            }, 1)
            done.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        cache.invalidate()
        finish.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(cache.get { 2 }, 2)
    }

    func testNonfiniteClockDoesNotCacheForever() {
        let cache = InvalidatingCache<Int>(lifetime: 30, clock: { .nan })
        XCTAssertEqual(cache.get { 1 }, 1)
        XCTAssertEqual(cache.get { 2 }, 2)
    }
}
