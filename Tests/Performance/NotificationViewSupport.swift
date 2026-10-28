import AppKit
import Kit

// Shadow only the delivery boundary. The production module's threshold and
// settings code runs normally, without permissions or desktop notifications.
class NotificationsWrapper: DeferredStackView {
    let module: String
    private(set) var evaluations: [(id: String, value: Double, threshold: Double)] = []
    private(set) var deliveries: [String] = []
    private(set) var registeredIDs: [String] = []

    init(_ module: ModuleType, _ ids: [String] = []) {
        self.module = module.stringValue
        super.init(frame: .zero)
        self.initIDs(ids)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func initIDs(_ ids: [String]) { self.registeredIDs = ids }
    func hideNotification(_ id: String) {}
    func checkDouble(id: String, value: Double, threshold: Double, title: String, subtitle: String, less: Bool = false, consecutive: Int = 2) {
        self.evaluations.append((id, value, threshold))
    }
    func newNotification(id: String, title: String, subtitle: String? = nil) { self.deliveries.append(id) }
}
