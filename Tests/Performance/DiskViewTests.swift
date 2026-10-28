import AppKit
import Kit
import XCTest

final class DiskViewTests: XCTestCase {
    private func disks(_ disk: drive) -> Disks {
        let list = Disks()
        list.append(disk)
        return list
    }

    private func buttons(in view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? self.buttons(in: $0) }
    }

    private func rows(in view: NSView) -> [DiskView] {
        view.subviews.flatMap { ($0 as? DiskView).map { [$0] } ?? self.rows(in: $0) }
    }

    func testRenamedDeviceRefreshesMetadataAndKeepsSameMediaHistory() throws {
        let popup = Popup(.disk)
        var disk = drive(uuid: "fixture-volume", mediaName: "Original", BSDName: "fixture0", registryID: 1, size: 10000, free: 8000)
        disk.activity.read = 1024
        popup.capacityCallback(disks(disk))
        popup.activityCallback(disks(disk))
        popup.appear()
        let first = try XCTUnwrap(rows(in: popup).first)
        let history = popup.history("read:fixture-volume:1", num: 30)
        disk.mediaName = "Renamed"
        disk.path = URL(fileURLWithPath: "/Volumes/Renamed")
        popup.capacityCallback(disks(disk))
        popup.appear()
        let current = try XCTUnwrap(rows(in: popup).first)
        XCTAssertFalse(current === first)
        XCTAssertTrue(current.matches(disk))
        XCTAssertTrue(popup.history("read:fixture-volume:1", num: 30) === history)
        XCTAssertEqual(history.snapshot().compactMap { $0?.value }, [1024])
    }

    func testReplacementMediaDoesNotInheritPreviousHistory() throws {
        let popup = Popup(.disk)
        var disk = drive(uuid: "fixture-volume", mediaName: "Same UUID", BSDName: "fixture0", registryID: 1, size: 10000)
        disk.activity.read = 1024
        popup.capacityCallback(disks(disk))
        popup.activityCallback(disks(disk))
        popup.appear()
        let previous = popup.history("read:fixture-volume:1", num: 30)
        let oldDisk = disk
        disk.registryID = 2
        disk.activity.read = 2048
        popup.capacityCallback(disks(disk))
        popup.activityCallback(disks(disk))
        popup.appear()
        let current = try XCTUnwrap(rows(in: popup).first)
        XCTAssertTrue(current.represents(disk))
        XCTAssertFalse(current.represents(oldDisk))
        XCTAssertEqual(popup.history("read:fixture-volume:2", num: 30).snapshot().compactMap { $0?.value }, [2048])
        XCTAssertEqual(previous.snapshot().compactMap { $0?.value }, [1024])
        popup.capacityCallback(Disks())
        popup.activityCallback(Disks())
        popup.appear()
        XCTAssertTrue(rows(in: popup).isEmpty)
        XCTAssertTrue(popup.history("read:fixture-volume:2", num: 30).snapshot().compactMap { $0 }.isEmpty)
    }

    func testSettingsRenameReplacesMenuItemsInsteadOfAppending() throws {
        let settings = Settings(.disk)
        var disk = drive(uuid: "fixture-volume", mediaName: "Original", BSDName: "fixture0")
        settings.setList(disks(disk))
        settings.load(widgets: [.mini])
        let menu = try XCTUnwrap(buttons(in: settings).first { $0.itemTitles.contains("Original") })
        disk.mediaName = "Renamed"
        settings.setList(disks(disk))
        settings.prepareContent()
        XCTAssertEqual(menu.itemTitles, ["Renamed"])
    }
}
