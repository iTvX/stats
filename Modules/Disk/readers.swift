//
//  readers.swift
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
import IOKit.storage
import CoreServices

let kIONVMeSMARTUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                  0xAA, 0x0F, 0xA6, 0xF9,
                                                                  0xC2, 0xD6, 0x45, 0x7F,
                                                                  0xB1, 0x0B, 0x59, 0xA1,
                                                                  0x32, 0x53, 0x29, 0x2F
)
let kIONVMeSMARTInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                             0xCC, 0xD1, 0xDB, 0x19,
                                                             0xFD, 0x9A, 0x4D, 0xAF,
                                                             0xBF, 0x95, 0x12, 0x45,
                                                             0x4B, 0x23, 0x0A, 0xB6
)
let kIOCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                            0xC2, 0x44, 0xE8, 0x58,
                                                            0x10, 0x9C, 0x11, 0xD4,
                                                            0x91, 0xD4, 0x00, 0x50,
                                                            0xE4, 0xC6, 0x42, 0x6F
)
let kIOATASMARTUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                                 0x24, 0x51, 0x4B, 0x7A,
                                                                 0x28, 0x04, 0x11, 0xD6,
                                                                 0x8A, 0x02, 0x00, 0x30,
                                                                 0x65, 0x70, 0x48, 0x66
)
let kIOATASMARTInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
                                                            0x08, 0xAB, 0xE2, 0x1C,
                                                            0x20, 0xD4, 0x11, 0xD6,
                                                            0x8D, 0xF6, 0x00, 0x03,
                                                            0x93, 0x5A, 0x76, 0xB2
)

internal class CapacityReader: Reader<Disks> {
    internal var list: Disks = Disks()
    
    private var purgableSpace: [URL: (Date, Int64)] = [:]
    private var identities: [String: DiskIdentity] = [:]
    
    public override func read() {
        guard let snapshot = DiskDiscovery.shared.snapshot() else { return }
        let removable = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        let records = snapshot.filter { $0.visible && (!$0.drive.removable || removable) }
        let previous = self.list
        let next = Disks()
        var identities: [String: DiskIdentity] = [:]
        var paths: Set<URL> = []
        for record in records {
            var disk = record.drive
            guard let path = disk.path else { continue }
            paths.insert(path)
            let same = self.identities[disk.BSDName] == record.identity
            if !same { self.purgableSpace.removeValue(forKey: path) }
            let space = self.diskSpaceInBytes(path, fileSystem: disk.fileSystem)
            disk.size = space.total
            if disk.size == 0, same, let old = previous.first(where: { $0.BSDName == disk.BSDName }) { disk.size = old.size }
            disk.free = space.free
            identities[disk.BSDName] = record.identity
            if disk.size > 0 { next.append(disk) }
        }
        self.purgableSpace = self.purgableSpace.filter { paths.contains($0.key) }
        self.identities = identities
        next.sort()
        self.list = next
        self.callback(next)
    }

    private func diskSpaceInBytes(_ path: URL, fileSystem: String) -> (total: Int64, free: Int64) {
        var path = path
        path.removeAllCachedResourceValues()
        
        var stat = statfs()
        if statfs(path.path, &stat) == 0 {
            let total = Int64(stat.f_blocks) * Int64(stat.f_bsize)
            let available = Int64(stat.f_bavail) * Int64(stat.f_bsize)
            let used = total - available
            
            var purgeable: Int64 = 0
            if fileSystem == "apfs" {
                if let pair = self.purgableSpace[path], Date().timeIntervalSince(pair.0) <= 60 {
                    purgeable = pair.1
                } else {
                    let value = CSDiskSpaceGetRecoveryEstimate(path as NSURL)
                    if used > 0 && value <= UInt64(used) {
                        purgeable = Int64(value)
                    }
                    self.purgableSpace[path] = (Date(), purgeable)
                }
            }
            
            return (total, available + purgeable)
        }
        
        var total: Int64 = 0
        var free: Int64 = 0
        
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path.path)
            total = (systemAttributes[FileAttributeKey.systemSize] as? NSNumber)?.int64Value ?? 0
            free = (systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        } catch let err {
            error("error retrieving disk space: \(err.localizedDescription)", log: self.log)
        }
        
        do {
            let values = try path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity != 0 {
                free = capacity
            }
        } catch let err {
            error("error retrieving free space: \(err.localizedDescription)", log: self.log)
        }
        
        return (total, free)
    }
}

internal class ActivityReader: Reader<Disks> {
    private var list: Disks = Disks()
    private let readLock = NSLock()
    private var samples: [UInt64: (read: UInt64?, write: UInt64?, time: UInt64)] = [:]
    
    override func setup() {
        self.setInterval(1)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.reset), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    public override func pause() {
        super.pause()
        self.reset()
    }
    
    public override func stop() {
        super.stop()
        self.reset()
    }
    
    @objc private func reset() {
        self.readLock.lock()
        defer { self.readLock.unlock() }
        self.samples.removeAll()
    }
    
    public override func read() {
        self.readLock.lock()
        defer { self.readLock.unlock() }
        let removable = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        guard let records = DiskDiscovery.shared.snapshot() else {
            self.samples.removeAll()
            let list = Disks()
            for var disk in self.list.array {
                disk.activity = stats()
                list.append(disk)
            }
            self.list = list
            self.callback(list)
            return
        }
        let list = Disks()
        var values: [UInt64: stats] = [:]
        for record in records where !record.drive.removable || removable {
            var disk = record.drive
            defer { list.append(disk) }
            guard let driver = record.driver else { continue }
            if let value = values[driver.id] { disk.activity = value; continue }
            let property = IORegistryEntryCreateCFProperty(driver.entry, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0)
            let counters = property?.takeRetainedValue() as? NSDictionary
            if counters == nil { DiskDiscovery.shared.invalidate() }
            let time = DispatchTime.now().uptimeNanoseconds
            let previous = self.samples[driver.id]
            let elapsed = previous.map { time > $0.time ? Double(time - $0.time) / 1_000_000_000 : 0 } ?? 0
            let read = Self.activity(counters?.object(forKey: kIOBlockStorageDriverStatisticsBytesReadKey), previous: previous?.read, elapsed: elapsed)
            let write = Self.activity(counters?.object(forKey: kIOBlockStorageDriverStatisticsBytesWrittenKey), previous: previous?.write, elapsed: elapsed)
            disk.activity = stats(read: read.rate, write: write.rate, readBytes: Int64(clamping: read.bytes ?? 0), writeBytes: Int64(clamping: write.bytes ?? 0))
            self.samples[driver.id] = (read.bytes, write.bytes, time)
            values[driver.id] = disk.activity
        }
        list.sort()
        self.samples = self.samples.filter { values[$0.key] != nil }
        self.list = list
        self.callback(list)
    }

    internal static func activity(_ value: Any?, previous: UInt64?, elapsed: Double) -> (bytes: UInt64?, rate: Int64) {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let bytes = UInt64(number.stringValue) else {
            return (nil, 0)
        }
        guard let previous, bytes >= previous, elapsed > 0, elapsed.isFinite else {
            return (bytes, 0)
        }
        
        let rate = Double(bytes - previous) / elapsed
        return (bytes, rate >= Double(Int64.max) ? Int64.max : Int64(rate))
    }
}

struct io {
    var read: Int
    var write: Int
}

public class ProcessReader: Reader<[Disk_process]> {
    private let queue = DispatchQueue(label: "eu.exelban.Disk.processReader")
    
    private var _list: [Int32: io] = [:]
    private var list: [Int32: io] {
        get { self.queue.sync { self._list } }
        set { self.queue.sync { self._list = newValue } }
    }
    
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(ModuleType.disk.stringValue)_processes", defaultValue: 5)
    }
    
    public override func setup() {
        self.popup = true
        self.preview = true
        self.setInterval(1)
    }
    
    public override func read() {
        guard self.numberOfProcesses != 0, let output = runProcess(path: "/bin/ps", args: ["-Aceo pid,args", "-r"]) else { return }
        
        var snapshot = self.list
        var processes: [Disk_process] = []
        output.enumerateLines { (line, _) in
            let str = line.trimmingCharacters(in: .whitespaces)
            let pidFind = str.findAndCrop(pattern: "^\\d+")
            guard let pid = Int32(pidFind.cropped) else { return }
            let name = pidFind.remain.findAndCrop(pattern: "^[^ ]+").cropped
            
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result != -1 else { return }
            
            let bytesRead = Int(clamping: usage.ri_diskio_bytesread)
            let bytesWritten = Int(clamping: usage.ri_diskio_byteswritten)
            
            if snapshot[pid] == nil {
                snapshot[pid] = io(read: bytesRead, write: bytesWritten)
            }
            
            if let v = snapshot[pid] {
                let read = bytesRead - v.read
                let write = bytesWritten - v.write
                if read != 0 || write != 0 {
                    processes.append(Disk_process(pid: Int(pid), name: name, read: read, write: write))
                }
            }
            
            snapshot[pid]?.read = bytesRead
            snapshot[pid]?.write = bytesWritten
        }
        self.list = snapshot
        
        processes.sort {
            let firstMax = max($0.read, $0.write)
            let secondMax = max($1.read, $1.write)
            let firstMin = min($0.read, $0.write)
            let secondMin = min($1.read, $1.write)
            
            if firstMax == secondMax && firstMin != secondMin { // max values are the same, min not. Sort by min values
                return firstMin < secondMin
            }
            return firstMax < secondMax // max values are not the same, sort by max value
        }
        
        self.callback(processes.suffix(self.numberOfProcesses).reversed())
    }
}

private func runProcess(path: String, args: [String] = []) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    
    let outputPipe = Pipe()
    defer {
        outputPipe.fileHandleForReading.closeFile()
    }
    task.standardOutput = outputPipe
    
    do {
        try task.run()
    } catch {
        return nil
    }
    
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: outputData, encoding: .utf8)
}

internal class SMARTReader: Reader<Disks> {
    internal var list: Disks = Disks()
    
    private var SMART: Bool {
        Store.shared.bool(key: "\(ModuleType.disk.stringValue)_SMART", defaultValue: true)
    }
    private var ATASMART: Bool {
        Store.shared.bool(key: "\(ModuleType.disk.stringValue)_ATASMART", defaultValue: false)
    }
    
    private var smartTotals: [String: (read: Int64, written: Int64)] = [:]
    private var smartEnableAttempted: Set<String> = []
    private var identities: [String: DiskIdentity] = [:]
    
    override func setup() {
        self.setInterval(Store.shared.int(key: "\(ModuleType.disk.stringValue)_updateSMARTInterval", defaultValue: 30))
    }
    
    public override func read() {
        guard self.SMART, let snapshot = DiskDiscovery.shared.snapshot() else { return }
        let removable = Store.shared.bool(key: "Disk_removable", defaultValue: false)
        let records = snapshot.filter { $0.visible && (!$0.drive.removable || removable) }
        let next = Disks()
        var identities: [String: DiskIdentity] = [:]
        for record in records {
            var disk = record.drive
            if self.identities[disk.BSDName] != record.identity {
                self.smartTotals.removeValue(forKey: disk.BSDName)
                self.smartEnableAttempted.remove(disk.BSDName)
            }
            disk.smart = self.getSMARTDetails(for: disk.BSDName, expectedMediaID: record.identity.mediaID)
            identities[disk.BSDName] = record.identity
            next.append(disk)
        }
        self.identities = identities
        self.smartTotals = self.smartTotals.filter { identities[$0.key] != nil }
        self.smartEnableAttempted = self.smartEnableAttempted.filter { identities[$0] != nil }
        next.sort()
        self.list = next
        self.callback(next)
    }

    private func getSMARTDetails(for BSDName: String, expectedMediaID: UInt64?) -> smart_t? {
        guard self.SMART else { return nil }
        
        var disk = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, BSDName.cString(using: .utf8)))
        guard disk != kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(disk) }
        if let expectedMediaID {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(disk, &id) == KERN_SUCCESS, id == expectedMediaID else {
                DiskDiscovery.shared.invalidate()
                return nil
            }
        }

        while IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) == 0 {
            var parent: io_registry_entry_t = 0
            let error = IORegistryEntryGetParentEntry(disk, kIOServicePlane, &parent)
            if error != kIOReturnSuccess || parent == kIOReturnSuccess { return nil }
            IOObjectRelease(disk)
            disk = parent
        }
        
        guard IOObjectConformsTo(disk, kIOBlockStorageDeviceClass) > 0 else { return nil }
        
        if let smart = self.getNVMeSMART(for: disk) { return smart }
        if self.ATASMART, let smart = self.getATASMART(for: disk, BSDName: BSDName) { return smart }
        return nil
    }
    
    private func getNVMeSMART(for disk: io_object_t) -> smart_t? {
        guard let raw = IORegistryEntryCreateCFProperty(disk, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0),
              let val = raw.takeRetainedValue() as? Bool, val else {
            return nil
        }
        
        var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smartInterface: UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        var score: Int32  = 0
        
        var result = IOCreatePlugInInterfaceForService(disk, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score)
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if pluginInterface != nil {
                IODestroyPlugInInterface(pluginInterface)
            }
        }
        
        result = withUnsafeMutablePointer(to: &smartInterface) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                pluginInterface?.pointee?.pointee.QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), $0) ?? KERN_NOT_FOUND
            }
        }
        
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if smartInterface != nil {
                _ = pluginInterface?.pointee?.pointee.Release(smartInterface)
            }
        }
        
        guard let smart = smartInterface?.pointee else { return nil }
        var smartData: nvme_smart_log = nvme_smart_log()
        guard smart.pointee.SMARTReadData(smartInterface, &smartData) == kIOReturnSuccess else { return nil }
        
        let temperatures: [UInt8] = [UInt8(smartData.temperature.1), UInt8(smartData.temperature.0)]
        var temperature: UInt16 = 0
        let data = NSData(bytes: temperatures, length: 2)
        data.getBytes(&temperature, length: 2)
        
        let bytesPerDataUnit: Int64 = 512 * 1000
        let (totalRead, readOverflow) = self.extractUInt128(smartData.data_units_read).multipliedReportingOverflow(by: bytesPerDataUnit)
        let (totalWritten, writtenOverflow) = self.extractUInt128(smartData.data_units_written).multipliedReportingOverflow(by: bytesPerDataUnit)

        let powerCycles = withUnsafeBytes(of: smartData.power_cycles) { $0.load(as: UInt32.self) }
        let powerOnHours = withUnsafeBytes(of: smartData.power_on_hours) { $0.load(as: UInt32.self) }
        let unsafeShutdowns = withUnsafeBytes(of: smartData.unsafe_shutdowns) { $0.load(as: UInt32.self) }
        let mediaErrors = withUnsafeBytes(of: smartData.media_errors) { $0.load(as: UInt32.self) }
        
        return smart_t(
            temperature: max(0, Int(UInt16(bigEndian: temperature)) - 273),
            life: max(0, 100 - Int(smartData.percent_used)),
            totalRead: readOverflow ? Int64.max : totalRead,
            totalWritten: writtenOverflow ? Int64.max : totalWritten,
            powerCycles: Int(powerCycles),
            powerOnHours: Int(powerOnHours),
            criticalWarning: Int(smartData.critical_warning),
            availableSpare: Int(smartData.avail_spare),
            spareThreshold: Int(smartData.spare_thresh),
            unsafeShutdowns: Int(unsafeShutdowns),
            mediaErrors: Int64(mediaErrors)
        )
    }
    
    private func getATASMART(for disk: io_object_t, BSDName: String) -> smart_t? {
        guard let raw = IORegistryEntryCreateCFProperty(disk, "SMART Capable" as CFString, kCFAllocatorDefault, 0),
              let val = raw.takeRetainedValue() as? Bool, val else {
            return nil
        }
        
        var pluginInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var smartInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOATASMARTInterface>?>?
        var score: Int32 = 0
        
        var result = IOCreatePlugInInterfaceForService(disk, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pluginInterface, &score)
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if pluginInterface != nil {
                IODestroyPlugInInterface(pluginInterface)
            }
        }
        
        result = withUnsafeMutablePointer(to: &smartInterface) {
            $0.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) {
                pluginInterface?.pointee?.pointee.QueryInterface(pluginInterface, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), $0) ?? KERN_NOT_FOUND
            }
        }
        
        guard result == kIOReturnSuccess else { return nil }
        defer {
            if smartInterface != nil {
                _ = pluginInterface?.pointee?.pointee.Release(smartInterface)
            }
        }
        
        guard let smart = smartInterface?.pointee else { return nil }
        
        var smartData = ATASMARTData()
        var readResult = smart.pointee.SMARTReadData(smartInterface, &smartData)
        if readResult != kIOReturnSuccess && !self.smartEnableAttempted.contains(BSDName) {
            self.smartEnableAttempted.insert(BSDName)
            _ = smart.pointee.SMARTEnableDisableOperations(smartInterface, true)
            readResult = smart.pointee.SMARTReadData(smartInterface, &smartData)
        }
        guard readResult == kIOReturnSuccess else { return nil }
        
        var attributes: [Int: (current: Int, raw: [UInt8])] = [:]
        withUnsafeBytes(of: &smartData) { buffer in
            for i in 0..<30 {
                let offset = 2 + i * 12
                let id = Int(buffer[offset])
                if id == 0 { continue }
                let current = Int(buffer[offset + 3])
                var rawBytes: [UInt8] = []
                for j in 0..<6 {
                    rawBytes.append(buffer[offset + 5 + j])
                }
                attributes[id] = (current, rawBytes)
            }
        }
        
        func rawValue(_ id: Int, bytes count: Int = 6) -> UInt64? {
            guard let attribute = attributes[id] else { return nil }
            var value: UInt64 = 0
            for i in 0..<min(count, attribute.raw.count) {
                value |= UInt64(attribute.raw[i]) << (8 * i)
            }
            return value
        }
        
        var temperature = 0
        if let temp = rawValue(194, bytes: 1) ?? rawValue(190, bytes: 1) {
            temperature = Int(temp)
        }
        
        var life = 100
        for id in [231, 202, 177, 173, 169, 233] {
            if let attribute = attributes[id] {
                life = min(max(attribute.current, 0), 100)
                break
            }
        }
        
        let bytesPerLBA: Int64 = 512
        
        var deviceRead: Int64?
        var deviceWritten: Int64?
        
        let pageCount = 8
        let logSize = 512 * pageCount
        var logBuffer = [UInt8](repeating: 0, count: logSize)
        let logResult = logBuffer.withUnsafeMutableBytes {
            smart.pointee.SMARTReadLogAtAddress(smartInterface, 0x04, $0.baseAddress, UInt32(logSize))
        }
        if logResult == kIOReturnSuccess {
            func deviceStatistic(page: Int, offset: Int) -> UInt64? {
                let base = page * 512 + offset
                guard base + 8 <= logBuffer.count else { return nil }
                var value: UInt64 = 0
                for i in 0..<8 {
                    value |= UInt64(logBuffer[base + i]) << (8 * i)
                }
                guard (value & (UInt64(1) << 63)) != 0, (value & (UInt64(1) << 62)) != 0 else { return nil }
                return value & 0x0000_FFFF_FFFF_FFFF
            }
            
            if let written = deviceStatistic(page: 1, offset: 0x18) {
                let (bytes, overflow) = Int64(written).multipliedReportingOverflow(by: bytesPerLBA)
                if !overflow {
                    deviceWritten = bytes
                }
            }
            if let read = deviceStatistic(page: 1, offset: 0x28) {
                let (bytes, overflow) = Int64(read).multipliedReportingOverflow(by: bytesPerLBA)
                if !overflow {
                    deviceRead = bytes
                }
            }
            if let used = deviceStatistic(page: 7, offset: 0x08) {
                life = max(0, 100 - Int(used & 0xFF))
            }
        }
        
        if deviceRead != nil || deviceWritten != nil {
            let cached = self.smartTotals[BSDName]
            self.smartTotals[BSDName] = (
                read: deviceRead ?? cached?.read ?? 0,
                written: deviceWritten ?? cached?.written ?? 0
            )
        }
        
        let totalRead = deviceRead ?? self.smartTotals[BSDName]?.read ?? Int64(rawValue(242) ?? 0) * bytesPerLBA
        let totalWritten = deviceWritten ?? self.smartTotals[BSDName]?.written ?? Int64(rawValue(241) ?? 0) * bytesPerLBA
        
        let errorCounts = [rawValue(5), rawValue(197), rawValue(198)].compactMap({ $0 })
        
        return smart_t(
            temperature: temperature,
            life: life,
            totalRead: totalRead,
            totalWritten: totalWritten,
            powerCycles: Int(rawValue(12, bytes: 4) ?? 0),
            powerOnHours: Int(rawValue(9, bytes: 4) ?? 0),
            unsafeShutdowns: rawValue(174, bytes: 4).map({ Int($0) }),
            mediaErrors: errorCounts.isEmpty ? nil : Int64(errorCounts.reduce(0, +))
        )
    }
    
    private func extractUInt128(_ tuple: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> Int64 {
        let byteArray: [UInt8] = [
            tuple.0, tuple.1, tuple.2, tuple.3, tuple.4, tuple.5, tuple.6, tuple.7,
            tuple.8, tuple.9, tuple.10, tuple.11, tuple.12, tuple.13, tuple.14, tuple.15
        ]
        
        let uint64Value = byteArray.prefix(8).withUnsafeBytes { $0.load(as: UInt64.self) }
        let hasHigherBytes = byteArray.suffix(8).contains(where: { $0 != 0 })
        
        if hasHigherBytes || uint64Value > UInt64(Int64.max) {
            return Int64.max
        }
        
        return Int64(uint64Value)
    }
}
