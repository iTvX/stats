import AppKit
import Kit

// Each build compiles a module's real views and model declarations. Module
// startup, its readers, status items and privileged helpers are not launched.
func makeModuleViewFixture() -> ModuleViewFixture {
    #if TEST_CPU
    Store.shared.set(key: "CPU_notifications_totalLoad_state", value: true)
    let popup = Popup(.CPU), preview = Preview(.CPU), settings = Settings(.CPU), notifications = Notifications(.CPU)
    return ModuleViewFixture(popup: popup, preview: preview, settings: settings, notifications: notifications, sample: { index in
        var value = CPU_Load()
        value.totalUsage = Double(20 + index) / 100
        value.systemLoad = Double(20 + index) / 100
        value.idleLoad = 1 - value.totalUsage
        value.usagePerCore = [value.totalUsage]
        popup.loadCallback(value)
        preview.loadCallback(value)
        notifications.loadCallback(value)
    }, histories: { [popup.history("usage", num: 180), preview.history("usage", num: 600)] }, settingsLabel: nil, latestLabel: { "\(20 + $0)%" })
    #elseif TEST_RAM
    Store.shared.set(key: "RAM_notifications_total_state", value: true)
    let popup = Popup(.RAM), preview = Preview(.RAM), settings = Settings(.RAM), notifications = Notifications(.RAM)
    return ModuleViewFixture(popup: popup, preview: preview, settings: settings, notifications: notifications, sample: { index in
        let value = RAM_Usage(total: 10000, used: Double(20 + index) * 100, free: Double(80 - index) * 100,
                              active: 100, inactive: 100, wired: 100, compressed: 100, app: 100, cache: 100,
                              swap: Swap(total: 100, used: 10, free: 90), pressure: Pressure(level: 1, value: .normal), swapins: 0, swapouts: 0)
        popup.loadCallback(value)
        preview.loadCallback(value)
        notifications.loadCallback(value)
    }, histories: { [popup.history("usage", num: 180)] + ["usage", "pressure", "swap"].map { preview.history($0, num: 600) } },
                             settingsLabel: nil, latestLabel: { Units(bytes: Int64(20 + $0) * 100).getReadableMemory(style: .memory) })
    #elseif TEST_GPU
    Store.shared.set(key: "GPU_notifications_usage_state", value: true)
    let popup = Popup(.GPU), preview = Preview(.GPU), settings = Settings(.GPU), notifications = Notifications(.GPU)
    return ModuleViewFixture(popup: popup, preview: preview, settings: settings, notifications: notifications, sample: { index in
        var value = GPU_Info(id: "fixture-gpu", type: "i", IOClass: "fixture", model: "Fixture GPU", cores: 8, utilization: Double(20 + index) / 100)
        value.renderUtilization = 0.1
        value.tilerUtilization = 0.2
        value.aneUtilization = 0.3
        value.fps = Double(40 + index)
        let gpus = GPUs()
        gpus.list = [value]
        popup.loadCallback(value)
        preview.loadCallback(value)
        settings.setList(gpus)
        notifications.usageCallback(value.utilization!)
    }, histories: { [popup.history("usage", num: 180)] + ["usage", "render", "tiler", "ane", "fps"].map { preview.history($0, num: 600) } },
                             settingsLabel: "Fixture GPU", latestLabel: { "\(40 + $0)" })
    #elseif TEST_NET
    Store.shared.set(key: "Network_notifications_interface_state", value: true)
    let popup = Popup(.network), preview = Preview(.network), settings = Settings(.network), notifications = Notifications(.network)
    return ModuleViewFixture(popup: popup, preview: preview, settings: settings, notifications: notifications, sample: { index in
        var value = Network_Usage()
        value.bandwidth = Bandwidth(upload: 100, download: Int64(index + 1) * 1024)
        value.laddr.v4 = "192.0.2.\(index + 1)"
        value.interface = Network_interface(status: true, displayName: "Fixture", BSDName: "fixture\(index)")
        value.status = true
        popup.usageCallback(value)
        preview.usageCallback(value)
        let connectivity = Network_Connectivity(status: index.isMultiple(of: 2), latency: Double(index), jitter: 1)
        popup.connectivityCallback(connectivity)
        preview.connectivityCallback(connectivity)
        notifications.usageCallback(value)
    }, histories: { ["download", "upload"].flatMap { [popup.history($0, num: 180), preview.history($0, num: 600)] } },
                             settingsLabel: nil, latestLabel: { "192.0.2.\($0 + 1)" })
    #elseif TEST_DISK
    Store.shared.set(key: "Disk_notifications_utilization_state", value: true)
    let popup = Popup(.disk), preview = Preview(.disk), settings = Settings(.disk), notifications = Notifications(.disk)
    let id = SystemKit.shared.device.info.disk?.first?.id ?? "fixture-disk"
    return ModuleViewFixture(popup: popup, preview: preview, settings: settings, notifications: notifications, sample: { index in
        var disk = drive(uuid: id, mediaName: "Fixture Volume", BSDName: "fixture0", registryID: 123,
                         size: 10000, free: Int64(80 - index) * 100)
        disk.activity = stats(read: Int64(index + 1) * 1024, write: 100)
        let disks = Disks()
        disks.append(disk)
        popup.capacityCallback(disks)
        popup.activityCallback(disks)
        preview.capacityCallback(disks)
        preview.activityCallback(disks)
        settings.setList(disks)
        notifications.utilizationCallback(disk.percentage)
    }, histories: {
        var list = [popup.history("read:\(id):123", num: 30), popup.history("write:\(id):123", num: 30)]
        if SystemKit.shared.device.info.disk?.first != nil { list += [preview.history("read", num: 600), preview.history("write", num: 600)] }
        return list
    }, settingsLabel: "Fixture Volume", latestLabel: { "\(80 - $0)%" })
    #elseif TEST_BATTERY
    Store.shared.set(key: "Battery_notifications_low", value: "0.5")
    let popup = Popup(.battery), settings = Settings(.battery), notifications = Notifications(.battery)
    return ModuleViewFixture(popup: popup, preview: nil, settings: settings, notifications: notifications, sample: { index in
        var value = Battery_Usage()
        value.level = Double(20 + index) / 100
        value.isBatteryPowered = true
        value.available = true
        popup.usageCallback(value)
        notifications.usageCallback(value)
    }, histories: { [] }, settingsLabel: nil, latestLabel: { "\(20 + $0)" })
    #elseif TEST_BLUETOOTH
    Store.shared.set(key: "ble_fixture-device_notification", value: "0.5")
    let popup = Popup(), settings = Settings(), notifications = Notifications(.bluetooth)
    return ModuleViewFixture(popup: popup, preview: nil, settings: settings, notifications: notifications, sample: { index in
        let device = BLEDevice(address: "fixture-device", name: "Fixture Bluetooth", uuid: nil, RSSI: nil,
                               batteryLevel: [KeyValue_t(key: "battery", value: "\(20 + index)")], isConnected: true, isPaired: true)
        popup.batteryCallback([device])
        settings.setList([device])
        notifications.callback([device])
    }, histories: { [] }, settingsLabel: "Fixture Bluetooth", latestLabel: { "\(20 + $0)%" })
    #else
    #error("Select a production module for this fixture")
    #endif
}
