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
