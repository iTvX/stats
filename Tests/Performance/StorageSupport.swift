import Foundation

// The production DB is compiled unchanged, with only its LevelDB boundary
// replaced. No default DB initializer or user directory may be accessed.
final class LLDB {
    private let lock = NSLock()
    private var data: [String: String] = [:]
    private var insertions: [(String, String)] = []
    var onInsert: ((String, String) -> Bool)?

    init() {}
    init?(_ path: String) { fatalError("Tests must inject isolated storage") }

    var writes: [(String, String)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.insertions
    }

    func insert(_ key: String, value: String) -> Bool {
        guard self.onInsert?(key, value) ?? true else { return false }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.data[key] = value
        self.insertions.append((key, value))
        return true
    }

    func insertMany(_ values: [String: String]) -> Bool {
        for (key, value) in values where !self.insert(key, value: value) { return false }
        return true
    }

    func findOne(_ key: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.data[key]
    }

    func findRange(_ prefix: String, from start: String, to end: String) -> [String: String]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.data.filter { $0.key.hasPrefix(prefix) && $0.key >= start && $0.key < end }
    }

    func keys(_ key: String) -> NSArray? { [] }
    func deleteMany(_ keys: [String]) {}
    func delete(before prefix: String, timestamp: String) -> Bool { true }
    func close() {}
}

extension Date {
    func currentTimeSeconds() -> Int { Int(self.timeIntervalSince1970) }
}
