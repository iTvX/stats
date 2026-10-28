//
//  main.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 07/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct stats: Codable {
    var read: Int64 = 0
    var write: Int64 = 0

    var readBytes: Int64 = 0
    var writeBytes: Int64 = 0
}

public struct smart_t: Codable {
    var temperature: Int = 0
    var life: Int = 0
    var totalRead: Int64 = 0
    var totalWritten: Int64 = 0
    var powerCycles: Int = 0
    var powerOnHours: Int = 0
    var criticalWarning: Int? = nil
    var availableSpare: Int? = nil
    var spareThreshold: Int? = nil
    var unsafeShutdowns: Int? = nil
    var mediaErrors: Int64? = nil
}

internal func smartCriticalWarnings(_ value: Int) -> [String] {
    var list: [String] = []
    if value & 0x01 != 0 { list.append(localizedString("Spare below threshold")) }
    if value & 0x02 != 0 { list.append(localizedString("Temperature out of range")) }
    if value & 0x04 != 0 { list.append(localizedString("Reliability degraded")) }
    if value & 0x08 != 0 { list.append(localizedString("Read-only mode")) }
    if value & 0x10 != 0 { list.append(localizedString("Backup failed")) }
    return list
}

public struct drive: Codable {
    var uuid: String = ""
    var mediaName: String = ""
    var BSDName: String = ""
    var registryID: UInt64? = nil

    var root: Bool = false
    var removable: Bool = false

    var model: String = ""
    var path: URL?
    var connectionType: String = ""
    var fileSystem: String = ""
    var writable: Bool = true
    var encrypted: Bool = false

    var size: Int64 = 1
    var free: Int64 = 0

    var activity: stats = stats()
    var smart: smart_t? = nil

    public var percentage: Double {
        let total = self.size
        let free = self.free
        var usedSpace = total - free
        if usedSpace < 0 {
            usedSpace = 0
        }
        if total == 0 {
            return 0
        }
        return Double(usedSpace) / Double(total)
    }

    public var popupState: Bool {
        Store.shared.bool(key: "Disk_\(self.uuid)_popup", defaultValue: true)
    }

    public func remote() -> String {
        return "\(self.uuid),\(self.size),\(self.size-self.free),\(self.free),\(self.activity.read),\(self.activity.write)"
    }
}

public class Disks: Codable, RemoteType {
    private var queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Disk.SynchronizedArray")
    private var _array: [drive] = []
    public var array: [drive] {
        get { self.queue.sync { self._array } }
        set { self.queue.sync { self._array = newValue } }
    }

    enum CodingKeys: String, CodingKey {
        case array
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.array = try container.decode(Array<drive>.self, forKey: CodingKeys.array)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(array, forKey: .array)
    }

    init() {}

    public var count: Int {
        self.queue.sync { self._array.count }
    }

    public func first(where predicate: (drive) -> Bool) -> drive? {
        return self.array.first(where: predicate)
    }

    public func index(where predicate: (drive) -> Bool) -> Int? {
        return self.array.firstIndex(where: predicate)
    }

    public func map<ElementOfResult>(_ transform: (drive) -> ElementOfResult?) -> [ElementOfResult] {
        return self.array.compactMap(transform)
    }

    public func filter(where isIncluded: (drive) -> Bool) -> [drive] {
        return self.array.filter(isIncluded)
    }

    public func reversed() -> [drive] {
        return self.array.reversed()
    }

    func forEach(_ body: (drive) -> Void) {
        self.array.forEach(body)
    }

    public func append( _ element: drive) {
        if !self.array.contains(where: {$0.BSDName == element.BSDName}) {
            self.array.append(element)
        }
    }

    public func remove(at index: Int) {
        self.array.remove(at: index)
    }

    public func sort() {
        self.array.sort{ $1.removable }
    }

    func updateFreeSize(_ idx: Int, newValue: Int64) {
        self.array[idx].free = newValue
    }

    func updateSMARTData(_ idx: Int, smart: smart_t?) {
        self.array[idx].smart = smart
    }

    public func remote() -> Data? {
        let arr = self.array.filter({ !$0.removable })
        var string = "\(arr.count),"
        for (i, v) in arr.enumerated() {
            string += v.remote()
            if i != self.array.count {
                string += ","
            }
        }
        string += "$"
        return string.data(using: .utf8)
    }
}

public struct Disk_process: Process_p, Codable {
    public var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(ModuleType.disk.stringValue)_base", defaultValue: "byte")) ?? .byte
    }
    public var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(ModuleType.disk.stringValue)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }

    public var pid: Int
    public var name: String
    public var icon: NSImage {
        ProcessIconCache.shared.icon(for: self.pid)
    }

    var read: Int
    var write: Int

    init(pid: Int, name: String, read: Int, write: Int) {
        self.pid = pid
        self.name = name
        self.read = read
        self.write = write

        if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            if let name = app.localizedName {
                self.name = name
            }
        }
    }
}
