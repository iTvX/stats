import Cocoa
import Kit
import DiskArbitration
import IOKit.storage

// Returns a retained driver only when all ancestor branches resolve to one driver.
internal func getDeviceIOParent(_ media: io_registry_entry_t) -> io_registry_entry_t? {
    IOObjectRetain(media)

    var entries = [media]
    defer { entries.forEach { IOObjectRelease($0) } }
    var visited: Set<UInt64> = []
    var driver: io_registry_entry_t?
    var index = 0

    while index < entries.count {
        let entry = entries[index]
        index += 1
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS else { return nil }
        guard visited.insert(id).inserted else { continue }
        guard visited.count <= 256 else { return nil }

        if IOObjectConformsTo(entry, kIOBlockStorageDriverClass) != 0 {
            guard driver == nil else { return nil }
            driver = entry
            continue
        }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetParentIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var parent = IOIteratorNext(iterator)
        while parent != 0 {
            entries.append(parent)
            parent = IOIteratorNext(iterator)
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
    }

    guard let driver else { return nil }
    IOObjectRetain(driver)
    return driver
}

internal func driveDetails(_ disk: DADisk, removableState: Bool) -> drive? {
    var d: drive = drive()

    if let bsdName = DADiskGetBSDName(disk) {
        d.BSDName = String(cString: bsdName)
    }

    if let diskDescription = DADiskCopyDescription(disk) {
        if let dict = diskDescription as? [String: AnyObject] {
            if let removable = dict[kDADiskDescriptionMediaRemovableKey as String] as? Bool {
                if removable {
                    if !removableState {
                        return nil
                    }
                    d.removable = true
                }
            }

            if let mediaUUID = dict[kDADiskDescriptionMediaUUIDKey as String], CFGetTypeID(mediaUUID) == CFUUIDGetTypeID() {
                d.uuid = CFUUIDCreateString(kCFAllocatorDefault, (mediaUUID as! CFUUID)) as String
            }
            if let mediaName = dict[kDADiskDescriptionVolumeNameKey as String] as? String {
                d.mediaName = mediaName
                if d.mediaName == "Recovery" {
                    return nil
                }
            }
            if d.mediaName == "" {
                if let mediaName = dict[kDADiskDescriptionMediaNameKey as String] as? String {
                    d.mediaName = mediaName
                    if d.mediaName == "Recovery" {
                        return nil
                    }
                }
            }
            if let deviceModel = dict[kDADiskDescriptionDeviceModelKey as String] as? String {
                d.model = deviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let deviceProtocol = dict[kDADiskDescriptionDeviceProtocolKey as String] as? String {
                d.connectionType = deviceProtocol
            }
            if let volumePath = dict[kDADiskDescriptionVolumePathKey as String] {
                if let url = volumePath as? NSURL {
                    d.path = url as URL

                    if let components = url.pathComponents {
                        d.root = components.count == 1

                        if components.count > 1 && components[1] == "Volumes" {
                            if let name: String = url.lastPathComponent, name != "" {
                                d.mediaName = name
                            }
                        }
                    }
                }
            }
            if let volumeKind = dict[kDADiskDescriptionVolumeKindKey as String] as? String {
                d.fileSystem = volumeKind
            }
            if let writable = dict[kDADiskDescriptionMediaWritableKey as String] as? Bool {
                d.writable = writable
            }
            if let encrypted = dict[kDADiskDescriptionMediaEncryptedKey as String] as? Bool {
                d.encrypted = encrypted
            }
        }
    }

    if d.path == nil {
        return nil
    }
    if d.uuid == "" || d.uuid == "00000000-0000-0000-0000-000000000000" {
        d.uuid = d.BSDName
    }

    return d
}
