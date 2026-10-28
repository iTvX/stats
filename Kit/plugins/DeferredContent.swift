import Cocoa

public func performOnMain(execute work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

/// Keeps only the latest update for each data source while its UI is cold.
/// Builders and replay closures must capture their owner weakly.
/// Content and update methods run on the main thread; histories are thread-safe.
open class DeferredStackView: NSStackView {
    public private(set) var isContentPrepared = true
    public private(set) var isReplayingUpdates = false
    private var builder: (() -> Void)?
    private var updates: [String: (priority: Int, action: () -> Void)] = [:]
    private let historyLock = NSLock()
    private var histories: [String: LineChartData] = [:]
    private var windowObserver: NSObjectProtocol?

    public func deferContent(_ builder: @escaping () -> Void) {
        self.isContentPrepared = false
        self.builder = builder
    }

    public func prepareContent() {
        guard !self.isReplayingUpdates else { return }
        self.isReplayingUpdates = true
        defer { self.isReplayingUpdates = false }
        if !self.isContentPrepared {
            self.isContentPrepared = true
            let builder = self.builder
            self.builder = nil
            builder?()
        }
        let updates = self.updates.sorted {
            $0.value.priority == $1.value.priority ? $0.key < $1.key : $0.value.priority < $1.value.priority
        }
        updates.forEach { $0.value.action() }
    }

    @discardableResult
    public func deferUpdate(key: String, priority: Int = 0, action: @escaping () -> Void) -> Bool {
        self.updates[key] = (priority, action)
        return !self.isContentPrepared || (!self.isReplayingUpdates && !(self.window?.isVisible ?? false))
    }

    public func history(_ key: String, num: Int) -> LineChartData {
        self.historyLock.lock()
        defer { self.historyLock.unlock() }
        if let history = self.histories[key] {
            if history.capacity != max(num, 2) { history.resize(num) }
            return history
        }
        let history = LineChartData(num: num)
        self.histories[key] = history
        return history
    }

    public func retainHistories(_ keys: Set<String>) {
        self.historyLock.lock()
        defer { self.historyLock.unlock() }
        self.histories = self.histories.filter { keys.contains($0.key) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        self.windowObserver = nil
        if let window = self.window {
            self.prepareContent()
            self.windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.prepareContent()
            }
        }
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
