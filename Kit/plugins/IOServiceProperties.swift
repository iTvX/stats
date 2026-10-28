import Foundation
import IOKit

public func fetchIOService(_ name: String, properties keys: [String]? = nil) -> [NSDictionary]? {
    var iterator: io_iterator_t = 0
    let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator)
    guard result == kIOReturnSuccess else {
        print("Error IOServiceGetMatchingServices(): " + String(cString: mach_error_string(result)))
        return nil
    }
    defer { IOObjectRelease(iterator) }

    var list: [NSDictionary] = []
    while true {
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { break }
        defer { IOObjectRelease(entry) }
        if let properties = getIOProperties(entry, keys: keys) {
            list.append(properties)
        }
    }
    return list.isEmpty ? nil : list
}

public func getIOProperties(_ entry: io_registry_entry_t, keys: [String]? = nil) -> NSDictionary? {
    guard entry != 0 else { return nil }
    if let keys {
        return selectedIOProperties(keys) { key in
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
    }

    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess else { return nil }
    return properties?.takeRetainedValue()
}

internal func selectedIOProperties(_ keys: [String], read: (String) -> Any?) -> NSDictionary? {
    var properties: [String: Any] = [:]
    for key in keys {
        if let value = read(key) { properties[key] = value }
    }
    return properties.isEmpty ? nil : properties as NSDictionary
}
