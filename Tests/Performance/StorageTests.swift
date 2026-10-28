import Foundation
import XCTest

private final class EncodingCounter {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }
    func increment() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.value += 1
    }
}

private struct CountedSnapshot: Codable {
    let value: Int
    var counter = EncodingCounter()
    var failEncoding = false
    enum CodingKeys: String, CodingKey { case value }
    enum Failure: Error { case encoding }

    func encode(to encoder: Encoder) throws {
        self.counter.increment()
        if self.failEncoding { throw Failure.encoding }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.value, forKey: .value)
    }
}

final class StorageTests: XCTestCase {
    func testThrottledSamplesUpdateCacheWithoutEncoding() {
        let storage = LLDB()
        let counter = EncodingCounter()
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        for value in 0..<1000 { db.insert(key: "CPU", value: CountedSnapshot(value: value, counter: counter)) }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(storage.writes.count, 1)
        XCTAssertEqual(db.findOne(CountedSnapshot.self, key: "CPU")?.value, 999)
        XCTAssertEqual(storage.findOne("CPU"), "{\"value\":0}")
    }

    func testThirtySecondBoundaryAndIndependentKeys() {
        let storage = LLDB()
        var seconds: TimeInterval = 100
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: seconds) })
        db.insert(key: "CPU", value: 1)
        seconds = 129.999
        db.insert(key: "CPU", value: 2)
        db.insert(key: "GPU", value: 3)
        XCTAssertEqual(storage.writes.count, 2)
        seconds = 130
        db.insert(key: "CPU", value: 4)
        XCTAssertEqual(storage.writes.count, 3)
        XCTAssertEqual(storage.findOne("CPU"), "4")
    }

    func testForceSavePersistsLatestValueInsideThrottleWindow() {
        let storage = LLDB()
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        db.insert(key: "CPU", value: 1)
        db.insert(key: "CPU", value: 2)
        db.insert(key: "CPU", value: 3, force: true)
        XCTAssertEqual(storage.writes.count, 2)
        XCTAssertEqual(storage.findOne("CPU"), "3")
        XCTAssertEqual(db.findOne(Int.self, key: "CPU"), 3)
    }

    func testEncodingFailureDoesNotConsumeWriteWindow() {
        let storage = LLDB()
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        db.insert(key: "CPU", value: CountedSnapshot(value: 1, failEncoding: true))
        XCTAssertNil(db.writeTS["CPU"])
        XCTAssertEqual(db.findOne(CountedSnapshot.self, key: "CPU")?.value, 1)
        db.insert(key: "CPU", value: 2)
        XCTAssertEqual(storage.findOne("CPU"), "2")
        XCTAssertNotNil(db.writeTS["CPU"])
    }

    func testStorageFailureCanRetryImmediately() {
        let storage = LLDB()
        storage.onInsert = { _, _ in false }
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        db.insert(key: "CPU", value: 1)
        XCTAssertNil(db.writeTS["CPU"])
        XCTAssertEqual(db.findOne(Int.self, key: "CPU"), 1)
        storage.onInsert = nil
        db.insert(key: "CPU", value: 2)
        XCTAssertEqual(storage.findOne("CPU"), "2")
    }

    func testConcurrentRequestsEncodeOncePerKey() {
        let storage = LLDB()
        let counter = EncodingCounter()
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        DispatchQueue.concurrentPerform(iterations: 100) { value in
            db.insert(key: "CPU", value: CountedSnapshot(value: value, counter: counter))
        }
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(storage.writes.count, 1)
        XCTAssertNotNil(db.findOne(CountedSnapshot.self, key: "CPU"))
    }

    func testForcedSaveCannotBeOverwrittenByAnOlderSlowWrite() {
        let storage = LLDB()
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: 100) })
        let entered = expectation(description: "first write entered")
        let firstFinished = expectation(description: "first write finished")
        let forcedFinished = expectation(description: "forced write finished")
        let cacheRead = expectation(description: "cache remains available")
        let release = DispatchSemaphore(value: 0)
        storage.onInsert = { _, value in
            if value == "1" {
                entered.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            }
            return true
        }
        DispatchQueue.global().async {
            db.insert(key: "CPU", value: 1)
            firstFinished.fulfill()
        }
        wait(for: [entered], timeout: 2)
        DispatchQueue.global().async {
            XCTAssertEqual(db.findOne(Int.self, key: "CPU"), 1)
            cacheRead.fulfill()
        }
        wait(for: [cacheRead], timeout: 2)
        DispatchQueue.global().async {
            db.insert(key: "CPU", value: 2, force: true)
            forcedFinished.fulfill()
        }
        release.signal()
        wait(for: [firstFinished, forcedFinished], timeout: 2)
        XCTAssertEqual(storage.writes.map { $0.1 }, ["1", "2"])
        XCTAssertEqual(storage.findOne("CPU"), "2")
    }

    func testClockMovingBackwardDoesNotSuppressWrites() {
        let storage = LLDB()
        var seconds: TimeInterval = 100
        let db = DB(storage: storage, now: { Date(timeIntervalSince1970: seconds) })
        db.insert(key: "CPU", value: 1)
        seconds = 50
        db.insert(key: "CPU", value: 2)
        XCTAssertEqual(storage.writes.count, 2)
        XCTAssertEqual(storage.findOne("CPU"), "2")
    }

    func testHistoryFlushStillPersistsPendingSamples() {
        let storage = LLDB()
        let db = DB(storage: storage)
        db.insert(key: "CPU", value: 1)
        db.recordHistory(key: "CPU", value: ["usage": 0.5], at: Date(), duration: 1)
        db.flush()
        let buckets = storage.writes.filter { $0.0.hasPrefix("history@v2@") }
        XCTAssertFalse(buckets.isEmpty)
        for (_, value) in buckets {
            let bucket = try? JSONDecoder().decode(HistoryBucket.self, from: Data(value.utf8))
            XCTAssertEqual(bucket?.values["/field:usage"]?.average, 0.5)
        }
    }
}
