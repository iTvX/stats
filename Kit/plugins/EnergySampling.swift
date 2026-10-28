import Foundation

internal struct EnergyCounter: Equatable {
    let id: String
    let name: String
    let joules: Double

    static func joules(_ value: Double, unit: String) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "j": return value
        case "mj": return value / 1e3
        case "uj", "µj", "μj": return value / 1e6
        case "nj": return value / 1e9
        case "pj": return value / 1e12
        default: return nil
        }
    }
}

internal struct EnergySnapshot {
    let timestamp: TimeInterval
    let generation: UInt64
    let counters: [EnergyCounter]
}

/// Coalesces nearby requests without adding a polling timer. The timestamp is
/// taken after collection, and invalidation starts a new counter generation.
internal final class EnergySnapshotCache {
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let load: () -> [EnergyCounter]?
    private let maxAge: TimeInterval
    private var generation: UInt64 = 0
    private var lastAttempt: TimeInterval?
    private var cached: EnergySnapshot?

    init(maxAge: TimeInterval = 0.1, clock: @escaping () -> TimeInterval, load: @escaping () -> [EnergyCounter]?) {
        self.maxAge = maxAge
        self.clock = clock
        self.load = load
    }

    func snapshot() -> EnergySnapshot? {
        self.lock.lock()
        defer { self.lock.unlock() }
        let now = self.clock()
        guard now.isFinite else { self.clear(); return nil }
        if let lastAttempt, now >= lastAttempt, now - lastAttempt < self.maxAge { return self.cached }
        if let lastAttempt, now < lastAttempt { self.clear() }
        guard let counters = self.load(), !counters.isEmpty else {
            self.clear()
            self.lastAttempt = now
            return nil
        }
        let sampledAt = self.clock()
        guard sampledAt.isFinite, sampledAt >= now else { self.clear(); return nil }
        let sample = EnergySnapshot(timestamp: sampledAt, generation: self.generation, counters: counters)
        self.cached = sample
        self.lastAttempt = sampledAt
        return sample
    }

    func invalidate() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.clear()
    }

    private func clear() {
        self.generation &+= 1
        self.cached = nil
        self.lastAttempt = nil
    }
}

public struct EnergyPowerSample {
    public let timestamp: TimeInterval
    public var cpu: Double = 0
    public var gpu: Double = 0
    public var ane: Double = 0
    public var ram: Double = 0
    public var pci: Double = 0
    public var aneTotal: Double?
}

/// Each consumer owns its baseline; sharing cumulative samples must not make
/// a slower reader use another reader's averaging interval.
public final class EnergyRateReader {
    private let lock = NSLock()
    private let load: () -> EnergySnapshot?
    private var previous: EnergySnapshot?
    private var lastPower: EnergyPowerSample?

    internal init(load: @escaping () -> EnergySnapshot?) {
        self.load = load
    }

    public func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.previous = nil
        self.lastPower = nil
    }

    public func read() -> EnergyPowerSample? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let next = self.load() else {
            self.previous = nil
            self.lastPower = nil
            return nil
        }
        if let previous, previous.generation == next.generation, previous.timestamp == next.timestamp {
            return self.lastPower
        }
        let elapsed = next.timestamp - (self.previous?.timestamp ?? next.timestamp)
        let validBaseline = self.previous?.generation == next.generation && elapsed.isFinite && elapsed > 0
        let old = Dictionary((self.previous?.counters ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var result = EnergyPowerSample(timestamp: next.timestamp)
        for counter in next.counters {
            var watts: Double = 0
            if validBaseline, let previous = old[counter.id], previous.name == counter.name, counter.joules >= previous.joules {
                watts = (counter.joules - previous.joules) / elapsed
                if !watts.isFinite { watts = 0 }
            }
            // GPU aggregates every ANE channel independently of the Sensors
            // module's legacy, ordered channel selection below.
            if counter.name.hasPrefix("ANE") { result.aneTotal = (result.aneTotal ?? 0) + watts }
            if counter.name.hasSuffix("CPU Energy") {
                result.cpu = watts
            } else if counter.name.hasSuffix("GPU Energy") {
                result.gpu = watts
            } else if counter.name.hasPrefix("ANE") {
                result.ane = watts
            } else if counter.name.hasPrefix("DRAM") {
                result.ram = watts
            } else if counter.name.hasPrefix("PCI") && counter.name.hasSuffix("Energy") {
                result.pci = watts
            }
        }
        self.previous = next
        self.lastPower = result
        return result
    }
}
