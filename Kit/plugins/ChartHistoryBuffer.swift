import Foundation

/// A bounded history with a median of adjacent, positive sampling intervals.
/// Append only removes the expired edge and inserts the new edge; it never
/// scans or sorts the full history. The owning chart supplies synchronization.
struct ChartHistoryBuffer<Value> {
    private var points: [Value?]
    private var head = 0
    private var intervals: [TimeInterval] = []
    private let timestamp: (Value) -> Date

    var capacity: Int { self.points.count }

    var intervalStatistics: (lastTs: Date, typical: TimeInterval)? {
        guard self.intervals.count >= 2, let last = self.points[(self.head + self.capacity - 1) % self.capacity] else { return nil }
        return (self.timestamp(last), self.intervals[self.intervals.count / 2])
    }

    init(capacity: Int, timestamp: @escaping (Value) -> Date) {
        self.points = Array(repeating: nil, count: max(capacity, 2))
        self.timestamp = timestamp
    }

    func orderedValues() -> [Value?] {
        (0..<self.capacity).map { self.points[(self.head + $0) % self.capacity] }
    }

    mutating func append(_ value: Value) {
        guard self.capacity > 0 else { return }
        if let stats = self.intervalStatistics {
            let gap = self.timestamp(value).timeIntervalSince(stats.lastTs)
            if gap >= 2, gap > stats.typical * 1.5 {
                // Clamp before converting to Int, including very large clock jumps.
                let missing = Int(min((gap / stats.typical).rounded() - 1, Double(self.capacity - 1)))
                if missing == self.capacity - 1 {
                    self.points = Array(repeating: nil, count: self.capacity)
                    self.intervals.removeAll(keepingCapacity: true)
                    self.head = 0
                } else {
                    for _ in 0..<max(0, missing) { self.appendPoint(nil) }
                }
            }
        }
        self.appendPoint(value)
    }

    mutating func resize(_ capacity: Int) {
        let capacity = max(capacity, 2)
        guard capacity != self.capacity else { return }
        let values = self.orderedValues()
        self.points = Array(repeating: nil, count: max(0, capacity - values.count)) + Array(values.suffix(capacity))
        self.head = 0
        self.rebuildIntervals()
    }

    mutating func replace(with values: [Value]) {
        self.points = values.map { Optional($0) }
        self.head = 0
        self.rebuildIntervals()
    }

    private func interval(from first: Value?, to second: Value?) -> TimeInterval? {
        guard let first, let second else { return nil }
        let delta = self.timestamp(second).timeIntervalSince(self.timestamp(first))
        return delta > 0 && delta.isFinite ? delta : nil
    }

    private func insertionIndex(_ value: TimeInterval) -> Int {
        var lower = 0
        var upper = self.intervals.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if self.intervals[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private mutating func appendPoint(_ value: Value?) {
        let count = self.capacity
        if count > 1 {
            if let expired = self.interval(from: self.points[self.head], to: self.points[(self.head + 1) % count]) {
                let index = self.insertionIndex(expired)
                assert(index < self.intervals.count && self.intervals[index] == expired)
                self.intervals.remove(at: index)
            }
            if let added = self.interval(from: self.points[(self.head + count - 1) % count], to: value) {
                self.intervals.insert(added, at: self.insertionIndex(added))
            }
        }
        self.points[self.head] = value
        self.head = (self.head + 1) % count
    }

    private mutating func rebuildIntervals() {
        self.intervals.removeAll(keepingCapacity: true)
        guard self.capacity > 1 else { return }
        for index in 1..<self.capacity {
            if let delta = self.interval(from: self.points[index - 1], to: self.points[index]) {
                self.intervals.append(delta)
            }
        }
        self.intervals.sort()
    }
}
