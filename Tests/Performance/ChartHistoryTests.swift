import Foundation
import XCTest

private struct Sample: Equatable {
    let ts: Date
    let value: Int

    init(_ seconds: TimeInterval, value: Int = 0) {
        self.ts = Date(timeIntervalSince1970: seconds)
        self.value = value
    }
}

// A simple specification using ordered arrays and a full median calculation.
// It preserves the previous chart's gap and upper-median semantics.
private struct ReferenceHistory {
    var points: [Sample?]

    var statistics: (lastTs: Date, typical: TimeInterval)? {
        var deltas: [TimeInterval] = []
        var previous: Date?
        var last: Date?
        for point in self.points {
            if let point {
                if let previous {
                    let delta = point.ts.timeIntervalSince(previous)
                    if delta > 0 { deltas.append(delta) }
                }
                previous = point.ts
                last = point.ts
            } else {
                previous = nil
            }
        }
        guard let last, deltas.count >= 2 else { return nil }
        return (last, deltas.sorted()[deltas.count / 2])
    }

    mutating func append(_ value: Sample) {
        guard !self.points.isEmpty else { return }
        if let stats = self.statistics {
            let gap = value.ts.timeIntervalSince(stats.lastTs)
            if gap >= 2, gap > stats.typical * 1.5 {
                let missing = min(Int((gap / stats.typical).rounded()) - 1, self.points.count - 1)
                for _ in 0..<max(0, missing) {
                    self.points.removeFirst()
                    self.points.append(nil)
                }
            }
        }
        self.points.removeFirst()
        self.points.append(value)
    }

    mutating func resize(_ requested: Int) {
        let capacity = max(requested, 2)
        self.points = Array(repeating: nil, count: max(0, capacity - self.points.count)) + Array(self.points.suffix(capacity))
    }
}

final class ChartHistoryTests: XCTestCase {
    private func assertEquivalent(_ history: ChartHistoryBuffer<Sample>, _ reference: ReferenceHistory, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(history.orderedValues(), reference.points, file: file, line: line)
        XCTAssertEqual(history.intervalStatistics?.lastTs, reference.statistics?.lastTs, file: file, line: line)
        XCTAssertEqual(history.intervalStatistics?.typical, reference.statistics?.typical, file: file, line: line)
    }

    func testRegularCadenceAndRepeatedRollover() {
        for capacity in [2, 3, 4, 60, 120, 180, 600] {
            var history = ChartHistoryBuffer<Sample>(capacity: capacity, timestamp: { $0.ts })
            var reference = ReferenceHistory(points: Array(repeating: nil, count: capacity))
            for index in 0..<1500 {
                let value = Sample(Double(index), value: index)
                history.append(value)
                reference.append(value)
                assertEquivalent(history, reference)
            }
        }
    }

    func testSleepGapPreservesEmptySlotsAndAdaptsToNewCadence() {
        var history = ChartHistoryBuffer<Sample>(capacity: 12, timestamp: { $0.ts })
        var reference = ReferenceHistory(points: Array(repeating: nil, count: 12))
        for second in [0, 1, 2, 3, 7, 8, 9, 120, 123, 126, 129, 132, 135, 138] {
            let value = Sample(Double(second))
            history.append(value)
            reference.append(value)
            assertEquivalent(history, reference)
        }
        XCTAssertEqual(history.intervalStatistics?.typical, 3)
    }

    func testDuplicateAndBackwardTimestampsDoNotCreateIntervals() {
        var history = ChartHistoryBuffer<Sample>(capacity: 8, timestamp: { $0.ts })
        var reference = ReferenceHistory(points: Array(repeating: nil, count: 8))
        for second in [5, 5, 4, 3, 4, 5, 6, 6, 6, 5, 6, 7, 8] {
            let value = Sample(Double(second))
            history.append(value)
            reference.append(value)
            assertEquivalent(history, reference)
        }
    }

    func testResizeAndReplacementRebuildIntervals() {
        var history = ChartHistoryBuffer<Sample>(capacity: 8, timestamp: { $0.ts })
        var reference = ReferenceHistory(points: Array(repeating: nil, count: 8))
        for second in [0, 1, 2, 6, 7, 8] {
            let value = Sample(Double(second))
            history.append(value)
            reference.append(value)
        }
        for capacity in [4, 20, 2, 0, 600] {
            history.resize(capacity)
            reference.resize(capacity)
            assertEquivalent(history, reference)
        }
        for count in [6, 0, 1, 2, 60] {
            let values = (0..<count).map { Sample(Double($0 * 3), value: $0) }
            history.replace(with: values)
            reference.points = values.map { Optional($0) }
            assertEquivalent(history, reference)
            history.append(Sample(Double(count * 3)))
            reference.append(Sample(Double(count * 3)))
            assertEquivalent(history, reference)
        }
    }

    func testVeryLargeGapIsBoundedBeforeIntegerConversion() {
        var history = ChartHistoryBuffer<Sample>(capacity: 8, timestamp: { $0.ts })
        for second in [0.0, 1, 2, 1e20] { history.append(Sample(second)) }
        XCTAssertEqual(history.orderedValues().compactMap { $0 }.count, 1)
        XCTAssertEqual(history.orderedValues().last??.ts, Sample(1e20).ts)
        XCTAssertNil(history.intervalStatistics)
    }

    func testRandomizedCadenceResizeAndReplaceMatchSpecification() {
        var history = ChartHistoryBuffer<Sample>(capacity: 60, timestamp: { $0.ts })
        var reference = ReferenceHistory(points: Array(repeating: nil, count: 60))
        var state: UInt64 = 42
        var seconds: TimeInterval = 0
        let increments: [TimeInterval] = [-1, 0, 0.25, 0.5, 1, 2, 3, 10, 60]
        for index in 0..<5000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            seconds += increments[Int(state % UInt64(increments.count))]
            if index % 137 == 0 {
                let values = (0..<Int(state % 20)).map { Sample(seconds + Double($0), value: $0) }
                history.replace(with: values)
                reference.points = values.map { Optional($0) }
            } else if index % 73 == 0 {
                let capacity = Int(state % 180)
                history.resize(capacity)
                reference.resize(capacity)
            }
            let value = Sample(seconds, value: index)
            history.append(value)
            reference.append(value)
            assertEquivalent(history, reference)
        }
    }

    func testAppendReadsOnlyBoundaryTimestamps() {
        var reads = 0
        var history = ChartHistoryBuffer<Sample>(capacity: 600, timestamp: { value in
            reads += 1
            return value.ts
        })
        for index in 0..<600 { history.append(Sample(Double(index))) }
        reads = 0
        history.append(Sample(600))
        XCTAssertLessThanOrEqual(reads, 8, "Appending must not scan all 600 points")
        XCTAssertEqual(history.intervalStatistics?.typical, 1)
    }
}
