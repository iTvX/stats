import Foundation

public struct DoubleValue {
    public var ts: Date = Date()
    public let value: Double

    public init(_ value: Double = 0) {
        self.value = value
    }
}

/// Bounded sampling history that can outlive a chart view. It owns no AppKit
/// objects or queues, so collapsed charts can keep history without rendering.
public final class LineChartData {
    private let lock = NSLock()
    private var history: ChartHistoryBuffer<DoubleValue>

    public init(num: Int) {
        self.history = ChartHistoryBuffer(capacity: num, timestamp: { $0.ts })
    }

    public var capacity: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.history.capacity
    }

    public func append(_ sample: DoubleValue) {
        var sample = sample
        if !sample.value.isFinite {
            let timestamp = sample.ts
            sample = DoubleValue(0)
            sample.ts = timestamp
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.history.append(sample)
    }

    public func snapshot() -> [DoubleValue?] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.history.orderedValues()
    }

    public func resize(_ num: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.history.resize(num)
    }

    public func replace(with values: [DoubleValue]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.history.replace(with: values)
    }
}

/// Connectivity samples have one slot per observation rather than inferred
/// time gaps. Keep their timestamps independently of the grid view as well.
public final class StatusChartData {
    private let lock = NSLock()
    private var points: [DoubleValue?]
    private var head = 0

    public init(num: Int) { self.points = Array(repeating: nil, count: max(num, 1)) }

    public func append(_ value: Bool, at timestamp: Date = Date()) {
        var point = DoubleValue(value ? 1 : 0)
        point.ts = timestamp
        self.lock.lock()
        defer { self.lock.unlock() }
        self.points[self.head] = point
        self.head = (self.head + 1) % self.points.count
    }

    public func snapshot(count: Int? = nil) -> [DoubleValue?] {
        self.lock.lock()
        defer { self.lock.unlock() }
        let ordered = self.points.indices.map { self.points[(self.head + $0) % self.points.count] }
        let count = max(count ?? self.points.count, 1)
        return Array(repeating: nil, count: max(0, count - ordered.count)) + Array(ordered.suffix(count))
    }
}
