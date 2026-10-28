import Foundation

/// Coalesces concurrent discovery requests. Invalidation never waits for the
/// loader, and a result invalidated in flight is not retained for later reads.
public final class InvalidatingCache<Value> {
    private let condition = NSCondition()
    private let lifetime: TimeInterval
    private let clock: () -> TimeInterval
    private var generation: UInt64 = 0
    private var loading = false
    private var value: Value?
    private var loadedAt: TimeInterval?

    public init(lifetime: TimeInterval, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = lifetime
        self.clock = clock
    }

    public func invalidate() {
        self.condition.lock()
        self.generation &+= 1
        self.value = nil
        self.loadedAt = nil
        self.condition.unlock()
    }

    public func get(_ load: () -> Value?) -> Value? {
        self.condition.lock()
        while self.loading { self.condition.wait() }
        let now = self.clock()
        let age = self.value == nil ? min(1, self.lifetime) : self.lifetime
        if let loadedAt = self.loadedAt, now >= loadedAt, now - loadedAt < age {
            let value = self.value
            self.condition.unlock()
            return value
        }
        let generation = self.generation
        self.loading = true
        self.condition.unlock()
        let value = load()
        let completed = self.clock()
        self.condition.lock()
        if self.generation == generation && completed.isFinite {
            self.value = value
            self.loadedAt = completed
        }
        self.loading = false
        self.condition.broadcast()
        self.condition.unlock()
        return value
    }
}
