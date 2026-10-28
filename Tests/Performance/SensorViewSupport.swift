import Kit

// Shadow only the privileged helper boundary while compiling the actual
// Sensors popup and value types. Tests never control the machine's fans.
final class SMCHelper {
    static let shared = SMCHelper()
    private(set) var operations = 0
    var isInstalled: Bool { false }
    func isActive() -> Bool { false }
    func resetFanControl() { self.operations += 1 }
    func setFanMode(_ id: Int, mode: Int) { self.operations += 1 }
    func setFanSpeed(_ id: Int, speed: Int) { self.operations += 1 }
    func openLoginItems() { self.operations += 1 }
    func install(completion: @escaping (SMCHelperInstallState) -> Void) {
        self.operations += 1
        completion(.failed)
    }
}
