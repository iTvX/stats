import Cocoa
import Kit
import DiskArbitration
import IOKit.storage

internal struct DiskIdentity: Equatable {
    let bsdName: String
    let uuid: String
    let path: String?
    let fileSystem: String
    let mediaID: UInt64?
}

internal final class DiskDriver {
    let entry: io_registry_entry_t
    let id: UInt64

    init(entry: io_registry_entry_t, id: UInt64) {
        self.entry = entry
        self.id = id
    }

    deinit { IOObjectRelease(self.entry) }
}

internal struct DiscoveredDisk {
    let drive: drive
    let visible: Bool
    let identity: DiskIdentity
    let driver: DiskDriver?
}

private let diskInventoryChanged: DADiskAppearedCallback = { _, context in
    guard let context else { return }
    Unmanaged<DiskDiscovery>.fromOpaque(context).takeUnretainedValue().invalidate()
}

private let diskDescriptionChanged: DADiskDescriptionChangedCallback = { _, _, context in
    guard let context else { return }
    Unmanaged<DiskDiscovery>.fromOpaque(context).takeUnretainedValue().invalidate()
}

/// One session and topology snapshot for capacity, activity and SMART readers.
/// Only metadata and retained registry references are cached, never counters
/// or free-space values. Thirty seconds is a fallback for missed notifications.
internal final class DiskDiscovery {
    static let shared = DiskDiscovery()
    private let cache = InvalidatingCache<[DiscoveredDisk]>(lifetime: 30)
    private let queue = DispatchQueue(label: "eu.exelban.Stats.Disk.discovery", qos: .utility)
    private var session: DASession?
    private var observers: [NSObjectProtocol] = []
    private var sessionCount = 0

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            })
        }
    }

    deinit {
        self.observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        self.resetSession()
    }

    var createdSessions: Int { self.queue.sync { self.sessionCount } }

    func invalidate() { self.cache.invalidate() }

    func snapshot() -> [DiscoveredDisk]? {
        self.cache.get { self.queue.sync { self.discover() } }
    }

    private func getSession() -> DASession? {
        if let session { return session }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskInventoryChanged, context)
        DARegisterDiskDisappearedCallback(session, nil, diskInventoryChanged, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, diskDescriptionChanged, context)
        DASessionSetDispatchQueue(session, self.queue)
        self.session = session
        self.sessionCount += 1
        return session
    }

    private func resetSession() {
        guard let session else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        DAUnregisterCallback(session, unsafeBitCast(diskInventoryChanged, to: UnsafeMutableRawPointer.self), context)
        DAUnregisterCallback(session, unsafeBitCast(diskDescriptionChanged, to: UnsafeMutableRawPointer.self), context)
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    private func discover() -> [DiscoveredDisk]? {
        let keys: [URLResourceKey] = [.volumeNameKey]
        guard let session = self.getSession(),
              let all = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys),
              let visible = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return nil }
        let visiblePaths = Set(visible.map { $0.path })
        var result: [DiscoveredDisk] = []
        var drivers: [UInt64: DiskDriver] = [:]
        var matched = 0
        let paths = all.filter { $0.pathComponents.count == 1 || ($0.pathComponents.count > 1 && $0.pathComponents[1] == "Volumes") }
        for path in paths {
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, path as CFURL) else { continue }
            matched += 1
            guard var value = driveDetails(disk, removableState: true), !value.BSDName.isEmpty else { continue }
            let media = DADiskCopyIOMedia(disk)
            var mediaID: UInt64?
            var driver: DiskDriver?
            if media != 0 {
                defer { IOObjectRelease(media) }
                var id: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS { mediaID = id }
                if let entry = getDeviceIOParent(media) {
                    if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS {
                        if let existing = drivers[id] {
                            IOObjectRelease(entry)
                            driver = existing
                        } else {
                            driver = DiskDriver(entry: entry, id: id)
                            drivers[id] = driver
                        }
                    } else {
                        IOObjectRelease(entry)
                    }
                }
            }
            value.registryID = mediaID
            let identity = DiskIdentity(bsdName: value.BSDName, uuid: value.uuid, path: value.path?.path, fileSystem: value.fileSystem, mediaID: mediaID)
            result.append(DiscoveredDisk(drive: value, visible: visiblePaths.contains(path.path), identity: identity, driver: driver))
        }
        if !paths.isEmpty && matched == 0 {
            self.resetSession()
            return nil
        }
        return result
    }
}
