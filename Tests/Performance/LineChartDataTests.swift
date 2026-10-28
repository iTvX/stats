import Foundation
import XCTest

final class LineChartDataTests: XCTestCase {
    private func sample(_ value: Double, at seconds: TimeInterval) -> DoubleValue {
        var point = DoubleValue(value)
        point.ts = Date(timeIntervalSince1970: seconds)
        return point
    }

    func testHistoryRemainsBoundedWithoutAView() {
        let data = LineChartData(num: 120)
        for index in 0..<1000 { data.append(sample(Double(index), at: Double(index))) }
        XCTAssertEqual(data.capacity, 120)
        XCTAssertEqual(data.snapshot().compactMap { $0?.value }, (880..<1000).map { Double($0) })
        XCTAssertEqual(data.snapshot().last??.ts, Date(timeIntervalSince1970: 999))
    }

    func testNonfiniteValuesKeepTheirTimestampWhenSanitized() {
        let data = LineChartData(num: 6)
        for (index, value) in [Double.nan, .infinity, -.infinity, 0.5].enumerated() {
            data.append(sample(value, at: Double(index)))
        }
        XCTAssertEqual(data.snapshot().compactMap { $0?.value }, [0, 0, 0, 0.5])
        XCTAssertEqual(data.snapshot().compactMap { $0?.ts }, (0..<4).map { Date(timeIntervalSince1970: Double($0)) })
    }

    func testSnapshotsAreIndependentAndResizeKeepsRecentHistory() {
        let data = LineChartData(num: 6)
        data.replace(with: (0..<6).map { sample(Double($0), at: Double($0)) })
        var snapshot = data.snapshot()
        snapshot[0] = nil
        data.resize(3)
        XCTAssertEqual(data.snapshot().compactMap { $0?.value }, [3, 4, 5])
        data.resize(8)
        XCTAssertEqual(data.snapshot().count, 8)
        XCTAssertEqual(data.snapshot().compactMap { $0?.value }, [3, 4, 5])
        XCTAssertEqual(snapshot.compactMap { $0?.value }, [1, 2, 3, 4, 5])
    }

    func testConcurrentSamplingAndSnapshotsRemainConsistent() {
        let data = LineChartData(num: 120)
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            data.append(self.sample(Double(index), at: Double(index)))
            let snapshot = data.snapshot()
            XCTAssertEqual(snapshot.count, 120)
            XCTAssertTrue(snapshot.compactMap { $0?.value }.allSatisfy { $0.isFinite })
            XCTAssertEqual(data.capacity, 120)
        }
        data.append(sample(2000, at: 2000))
        XCTAssertEqual(data.snapshot().last??.value, 2000)
    }

    func testConnectivityHistoryKeepsExactSamplesAndTimestamps() {
        let data = StatusChartData(num: 3)
        for time in [0.0, 1, 60, 61] { data.append(time != 60, at: Date(timeIntervalSince1970: time)) }
        XCTAssertEqual(data.snapshot().compactMap { $0?.value }, [1, 0, 1])
        XCTAssertEqual(data.snapshot().compactMap { $0?.ts }, [1, 60, 61].map { Date(timeIntervalSince1970: $0) })
        XCTAssertEqual(data.snapshot(count: 5).count, 5)
        XCTAssertEqual(data.snapshot(count: 2).compactMap { $0?.value }, [0, 1])
    }

    func testConnectivityConcurrentAccessAndZeroCapacity() {
        let data = StatusChartData(num: 0)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            data.append(index.isMultiple(of: 2))
            XCTAssertEqual(data.snapshot().count, 1)
        }
        data.append(false)
        XCTAssertEqual(data.snapshot().last??.value, 0)
    }
}
