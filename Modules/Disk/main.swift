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

public class Disk: Module {
    private let popupView: Popup = Popup(.disk)
    private let settingsView: Settings = Settings(.disk)
    private let portalView: Portal = Portal(.disk, height: 120)
    private let notificationsView: Notifications = Notifications(.disk)
    private let previewView: Preview = Preview(.disk)
    
    private var capacityReader: CapacityReader?
    private var activityReader: ActivityReader?
    private var processReader: ProcessReader?
    private var smartReader: SMARTReader?
    
    private var selectedDisk: String = ""
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$capacity.free/$capacity.total")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    private var mainColor: NSColor {
        SColor.fromString(Store.shared.string(key: "\(self.name)_mainColor", defaultValue: SColor.secondBlue.key)).additional as! NSColor
    }
    
    public init() {
        super.init(
            moduleType: .disk,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.capacityReader = CapacityReader(.disk, defaultInterval: ReaderDefaults.diskCapacity) { [weak self] value in
            if let value {
                self?.capacityCallback(value)
            }
        }
        self.activityReader = ActivityReader(.disk) { [weak self] value in
            if let value {
                self?.activityCallback(value)
            }
        }
        self.processReader = ProcessReader(.disk) { [weak self] value in
            if let list = value {
                self?.popupView.processCallback(list)
                self?.previewView.processCallback(list)
            }
        }
        self.smartReader = SMARTReader(.disk) { [weak self] value in
            if let value {
                self?.SMARTCallback(value)
            }
        }
        
        self.selectedDisk = Store.shared.string(key: "\(ModuleType.disk.stringValue)_disk", defaultValue: self.selectedDisk)
        
        self.settingsView.selectedDiskHandler = { [weak self] value in
            self?.selectedDisk = value
            self?.capacityReader?.requestRead()
        }
        self.settingsView.callback = { [weak self] in
            self?.capacityReader?.requestRead()
            self?.smartReader?.requestRead()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.capacityReader?.setInterval(value)
        }
        self.settingsView.setSMARTInterval = { [weak self] value in
            self?.smartReader?.setInterval(value)
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView.numberOfProcessesUpdated()
            self?.previewView.numberOfProcessesUpdated()
            self?.processReader?.requestRead()
        }
        
        self.setReaders([self.capacityReader, self.activityReader, self.processReader, self.smartReader])
    }
    
    private func capacityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.capacityCallback(value)
            self.previewView.capacityCallback(value)
        })
        self.settingsView.setList(value)
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.utilizationCallback(d)
        self.notificationsView.utilizationCallback(d.percentage)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini: widget.setValue(d.percentage)
            case let widget as BarChart: widget.setValue([[ColorValue(d.percentage)]])
            case let widget as MemoryWidget:
                widget.setValue((DiskSize(d.free).getReadableMemory(), DiskSize(d.size - d.free).getReadableMemory()), usedPercentage: d.percentage)
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(d.percentage, color: self.mainColor)
                ])
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$capacity":
                        switch pair.value {
                        case "total": replacement = DiskSize(d.size).getReadableMemory()
                        case "used": replacement = DiskSize(d.size - d.free).getReadableMemory()
                        case "free": replacement = DiskSize(d.free).getReadableMemory()
                        default: return
                        }
                    case "$percentage":
                        var percentage: Int
                        if d.size == 0 {
                            percentage = 0
                        } else {
                            switch pair.value {
                            case "used": percentage = Int((Double(d.size - d.free) / Double(d.size)) * 100)
                            case "free": percentage = Int((Double(d.free) / Double(d.size)) * 100)
                            default: return
                            }
                        }
                        replacement = "\(percentage < 0 ? 0 : percentage)%"
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            SystemWidgetUpdates.shared.update(d, key: "Disk@CapacityReader", kinds: [Disk_entry.kind, "UnitedWidget"], defaults: self.userDefaults)
        }
    }
    
    private func activityCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.activityCallback(value)
            self.previewView.activityCallback(value)
        })
        
        guard let d = value.first(where: { $0.mediaName == self.selectedDisk }) ?? value.first(where: { $0.root }) else {
            return
        }
        
        self.portalView.activityCallback(d)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as SpeedWidget: 
                widget.setValue(input: d.activity.read, output: d.activity.write)
            case let widget as NetworkChart:
                widget.setValue(upload: Double(d.activity.write), download: Double(d.activity.read))
                if self.capacityReader?.interval != 1 {
                    self.settingsView.setUpdateInterval(value: 1)
                }
            default: break
            }
        }
    }
    
    private func SMARTCallback(_ value: Disks) {
        guard self.enabled else { return }
        
        DispatchQueue.main.async(execute: {
            self.popupView.smartCallback(value)
        })
        self.previewView.smartCallback(value)
    }
}
