import Foundation
import XCTest

private final class EnergyFixture {
    var time: TimeInterval = 0
    var calls = 0
    var counters: [EnergyCounter]? = []
    var collectionDelay: TimeInterval = 0

    func cache() -> EnergySnapshotCache {
        EnergySnapshotCache(clock: { self.time }, load: {
            self.calls += 1
            self.time += self.collectionDelay
            return self.counters
        })
    }
}

final class EnergyTests: XCTestCase {
    private func counter(_ joules: Double, id: String? = nil) -> EnergyCounter {
        counter("CPU Energy", joules, id: id)
    }

    private func counter(_ name: String, _ joules: Double, id: String? = nil) -> EnergyCounter {
        EnergyCounter(id: id ?? name, name: name, joules: joules)
    }

    func testEnergyUnitsAreConvertedWithoutGuessingUnknownUnits() {
        for (unit, raw) in [("J", 1.0), ("mJ", 1e3), ("uJ", 1e6), ("µJ", 1e6), ("μJ", 1e6), (" nJ ", 1e9), ("pJ", 1e12)] {
            XCTAssertEqual(EnergyCounter.joules(raw, unit: unit), 1)
        }
        XCTAssertNil(EnergyCounter.joules(1000, unit: "unknown"))
        XCTAssertNil(EnergyCounter.joules(-1, unit: "nJ"))
        XCTAssertNil(EnergyCounter.joules(.nan, unit: "nJ"))
        XCTAssertNil(EnergyCounter.joules(.infinity, unit: "nJ"))
    }

    func testConcurrentConsumersShareOneCollection() {
        let source = EnergyFixture()
        source.counters = [counter(10)]
        let cache = source.cache()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(cache.snapshot()?.counters, source.counters)
        }
        XCTAssertEqual(source.calls, 1)
    }

    func testCacheExpiresAndUsesCollectionCompletionTime() {
        let source = EnergyFixture()
        source.counters = [counter(10)]
        source.collectionDelay = 0.08
        let cache = source.cache()
        XCTAssertEqual(cache.snapshot()?.timestamp, 0.08)
        source.time = 0.12
        XCTAssertEqual(cache.snapshot()?.timestamp, 0.08)
        XCTAssertEqual(source.calls, 1)
        source.time = 0.2
        XCTAssertEqual(cache.snapshot()?.timestamp ?? 0, 0.28, accuracy: 1e-9)
        XCTAssertEqual(source.calls, 2)
    }

    func testConsumersKeepIndependentAveragingWindows() {
        let source = EnergyFixture()
        source.counters = [counter(0)]
        let cache = source.cache()
        let fast = EnergyRateReader(load: cache.snapshot)
        let slow = EnergyRateReader(load: cache.snapshot)
        XCTAssertEqual(fast.read()?.cpu, 0)
        XCTAssertEqual(slow.read()?.cpu, 0)
        source.time = 1; source.counters = [counter(10)]
        XCTAssertEqual(fast.read()?.cpu, 10)
        source.time = 2; source.counters = [counter(50)]
        XCTAssertEqual(fast.read()?.cpu, 40)
        source.time = 3; source.counters = [counter(90)]
        XCTAssertEqual(fast.read()?.cpu, 40)
        XCTAssertEqual(slow.read()?.cpu, 30)
        XCTAssertEqual(source.calls, 4)
    }

    func testRepeatedCachedSnapshotDoesNotEraseLastPower() {
        let source = EnergyFixture()
        source.counters = [counter(0)]
        let cache = source.cache()
        let reader = EnergyRateReader(load: cache.snapshot)
        _ = reader.read()
        source.time = 1; source.counters = [counter(20)]
        XCTAssertEqual(reader.read()?.cpu, 20)
        source.time = 1.05
        XCTAssertEqual(reader.read()?.cpu, 20)
        source.time = 2; source.counters = [counter(40)]
        XCTAssertEqual(reader.read()?.cpu, 20)
        XCTAssertEqual(source.calls, 3)
    }

    func testWakeInvalidationStartsANewBaselineForEveryReader() {
        let source = EnergyFixture()
        source.counters = [counter(0)]
        let cache = source.cache()
        let first = EnergyRateReader(load: cache.snapshot)
        let second = EnergyRateReader(load: cache.snapshot)
        _ = first.read(); _ = second.read()
        source.time = 1; source.counters = [counter(10)]
        XCTAssertEqual(first.read()?.cpu, 10)
        cache.invalidate()
        source.time = 100; source.counters = [counter(90000)]
        XCTAssertEqual(first.read()?.cpu, 0)
        XCTAssertEqual(second.read()?.cpu, 0)
        source.time = 101; source.counters = [counter(90005)]
        XCTAssertEqual(first.read()?.cpu, 5)
        XCTAssertEqual(second.read()?.cpu, 5)
    }

    func testCounterResetDoesNotProduceNegativePower() {
        let source = EnergyFixture()
        source.counters = [counter(100), counter("GPU Energy", 100)]
        let reader = EnergyRateReader(load: source.cache().snapshot)
        _ = reader.read()
        source.time = 1
        source.counters = [counter(5), counter("GPU Energy", 110)]
        let sample = reader.read()
        XCTAssertEqual(sample?.cpu, 0)
        XCTAssertEqual(sample?.gpu, 10)
        source.time = 2; source.counters = [counter(8)]
        XCTAssertEqual(reader.read()?.cpu, 3)
    }

    func testMissingAndNewChannelsDoNotReuseAnotherCounter() {
        let source = EnergyFixture()
        source.counters = [counter(10, id: "old")]
        let reader = EnergyRateReader(load: source.cache().snapshot)
        _ = reader.read()
        source.time = 1; source.counters = [counter(900, id: "new")]
        XCTAssertEqual(reader.read()?.cpu, 0)
        source.time = 2; source.counters = [counter("GPU Energy", 100)]
        XCTAssertEqual(reader.read()?.cpu, 0)
        source.time = 3; source.counters = [counter(1000, id: "new")]
        XCTAssertEqual(reader.read()?.cpu, 0)
    }

    func testFailureRecoveryDoesNotBridgeAnUnknownInterval() {
        let source = EnergyFixture()
        source.counters = [counter(0)]
        let reader = EnergyRateReader(load: source.cache().snapshot)
        _ = reader.read()
        source.time = 1; source.counters = nil
        XCTAssertNil(reader.read())
        source.time = 2; source.counters = [counter(1000)]
        XCTAssertEqual(reader.read()?.cpu, 0)
        source.time = 3; source.counters = [counter(1004)]
        XCTAssertEqual(reader.read()?.cpu, 4)
    }

    func testClockRollbackAndInvalidClockResetTheBaseline() {
        let source = EnergyFixture()
        source.time = 10; source.counters = [counter(10)]
        let reader = EnergyRateReader(load: source.cache().snapshot)
        _ = reader.read()
        source.time = 5; source.counters = [counter(30)]
        XCTAssertEqual(reader.read()?.cpu, 0)
        source.time = .nan
        XCTAssertNil(reader.read())
        source.time = 6; source.counters = [counter(40)]
        XCTAssertEqual(reader.read()?.cpu, 0)
    }

    func testExistingChannelSelectionAndANEAggregationArePreserved() {
        let source = EnergyFixture()
        let names = ["ECPU Energy", "PCPU Energy", "GPU Energy", "ANE0 Energy", "ANE1 Energy", "DRAM Energy", "PCI Energy", "ANE CPU Energy"]
        source.counters = names.map { counter($0, 0) }
        let reader = EnergyRateReader(load: source.cache().snapshot)
        _ = reader.read()
        source.time = 1
        source.counters = zip(names, [2.0, 3, 6, 4, 5, 7, 8, 9]).map { counter($0.0, $0.1) }
        let result = reader.read()
        XCTAssertEqual(result?.cpu, 9)
        XCTAssertEqual(result?.gpu, 6)
        XCTAssertEqual(result?.ane, 5)
        XCTAssertEqual(result?.aneTotal, 18)
        XCTAssertEqual(result?.ram, 7)
        XCTAssertEqual(result?.pci, 8)
    }

    func testResettingOneConsumerDoesNotResetAnother() {
        let source = EnergyFixture()
        source.counters = [counter(0)]
        let cache = source.cache()
        let first = EnergyRateReader(load: cache.snapshot)
        let second = EnergyRateReader(load: cache.snapshot)
        _ = first.read(); _ = second.read()
        first.reset()
        source.time = 1; source.counters = [counter(20)]
        XCTAssertEqual(first.read()?.cpu, 0)
        XCTAssertEqual(second.read()?.cpu, 20)
    }
}
