import Foundation

// Only persistence, logging and remote delivery are replaced. Reader and timer
// implementations are compiled unchanged by run-performance-tests.py.
public enum ModuleType {
    case CPU, disk, sensors
    public var stringValue: String {
        switch self {
        case .CPU: return "CPU"
        case .disk: return "Disk"
        case .sensors: return "Sensors"
        }
    }
}

public final class NextLog {
    static let shared = NextLog()
    func copy(category: String) -> NextLog { self }
}
func debug(_ message: String, log: NextLog) {}

final class Store {
    static let shared = Store()
    var integers: [String: Int] = [:]
    func int(key: String, defaultValue: Int) -> Int { self.integers[key] ?? defaultValue }
}

final class DB {
    static let shared = DB()
    func setup<T: Codable>(_ type: T.Type, _ key: String) {}
    func findOne<T: Decodable>(_ type: T.Type, key: String) -> T? { nil }
    func insert(key: String, value: Codable, force: Bool = false) {}
    func recordHistory<T: Encodable>(key: String, value: T, at: Date, duration: TimeInterval) {}
}

final class SystemStats {
    static let shared = SystemStats()
    func send(key: String, value: Any) {}
}
