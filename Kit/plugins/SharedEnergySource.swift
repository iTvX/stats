import Cocoa

private final class SharedEnergySource {
    static let shared = SharedEnergySource()
    private let cache: EnergySnapshotCache
    private var wakeObserver: NSObjectProtocol?

    private init() {
        self.cache = EnergySnapshotCache(clock: { ProcessInfo.processInfo.systemUptime }, load: {
            guard let sample = StatsCopyEnergySample(), let raw = sample as? [[String: Any]] else { return nil }
            return raw.compactMap { value in
                guard let id = value["id"] as? String, let name = value["name"] as? String,
                      let unit = value["unit"] as? String, let raw = value["value"] as? NSNumber,
                      let joules = EnergyCounter.joules(raw.doubleValue, unit: unit) else { return nil }
                return EnergyCounter(id: id, name: name, joules: joules)
            }
        })
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak cache] _ in
            cache?.invalidate()
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func snapshot() -> EnergySnapshot? { self.cache.snapshot() }
}

extension EnergyRateReader {
    public convenience init() {
        self.init(load: { SharedEnergySource.shared.snapshot() })
    }
}
