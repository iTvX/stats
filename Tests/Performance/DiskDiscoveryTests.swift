import AppKit
import DiskArbitration
import IOKit.storage
import Kit
import XCTest

final class DiskDiscoveryTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(8)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < limit
        return false
    }

    @discardableResult
    private func command(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let output = try CommandRunner().run(executable, arguments: arguments, timeout: 20)
        guard output.exitCode == 0 else {
            throw NSError(domain: "DiskDiscoveryTest", code: Int(output.exitCode), userInfo: [
                NSLocalizedDescriptionKey: String(data: output.stderr, encoding: .utf8) ?? "disk image command failed"
            ])
        }
        return output
    }

    func testRootDiscoveryRetainsReadableDriverAndMatchingMediaIdentity() throws {
        let records = try XCTUnwrap(DiskDiscovery.shared.snapshot())
        let root = try XCTUnwrap(records.first { $0.drive.root })
        XCTAssertEqual(root.drive.path?.path, "/")
        XCTAssertFalse(root.drive.uuid.isEmpty)
        XCTAssertTrue(root.visible)
        let driver = try XCTUnwrap(root.driver)
        XCTAssertNotNil(IORegistryEntryCreateCFProperty(driver.entry, kIOBlockStorageDriverStatisticsKey as CFString, kCFAllocatorDefault, 0))
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, root.drive.BSDName))
        XCTAssertNotEqual(media, 0)
        defer { if media != 0 { IOObjectRelease(media) } }
        var id: UInt64 = 0
        XCTAssertEqual(IORegistryEntryGetRegistryEntryID(media, &id), KERN_SUCCESS)
        XCTAssertEqual(root.identity.mediaID, id, "SMART lookup must refer to the discovered media")
    }

    func testRefreshAndConcurrentSnapshotsReuseOneSession() throws {
        _ = try XCTUnwrap(DiskDiscovery.shared.snapshot())
        let sessions = DiskDiscovery.shared.createdSessions
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            if index.isMultiple(of: 4) { DiskDiscovery.shared.invalidate() }
            XCTAssertNotNil(DiskDiscovery.shared.snapshot())
        }
        XCTAssertEqual(DiskDiscovery.shared.createdSessions, sessions)
        XCTAssertEqual(sessions, 1)
    }

    func testVolumeIdentityDetectsBsdReuseRenameAndFileSystemChange() {
        let initial = DiskIdentity(bsdName: "disk20s1", uuid: "first", path: "/Volumes/First", fileSystem: "apfs", mediaID: 1)
        for changed in [
            DiskIdentity(bsdName: "disk20s1", uuid: "second", path: initial.path, fileSystem: "apfs", mediaID: 1),
            DiskIdentity(bsdName: "disk20s1", uuid: "first", path: "/Volumes/Renamed", fileSystem: "apfs", mediaID: 1),
            DiskIdentity(bsdName: "disk20s1", uuid: "first", path: initial.path, fileSystem: "hfs", mediaID: 1),
            DiskIdentity(bsdName: "disk20s1", uuid: "first", path: initial.path, fileSystem: "apfs", mediaID: 2)
        ] { XCTAssertNotEqual(initial, changed) }
    }

    func testCachedDriveFromEarlierReleaseDecodesWithoutRegistryIdentity() throws {
        let disk = drive(uuid: "old-volume", BSDName: "disk20s1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(disk)) as? [String: Any])
        json.removeValue(forKey: "registryID")
        let decoded = try JSONDecoder().decode(drive.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.uuid, disk.uuid)
        XCTAssertNil(decoded.registryID)
    }

    func testMountRenameAndUnmountInvalidateDiscoveryBeforeFallback() throws {
        let directory = try XCTUnwrap(ProcessInfo.processInfo.environment["STATS_DISK_TEST_DIR"])
        let name = try XCTUnwrap(ProcessInfo.processInfo.environment["STATS_DISK_TEST_NAME"])
        let image = directory + "/hotplug.sparseimage"
        let original = "/Volumes/" + name
        let renamed = original + "-renamed"
        var mounted: String?
        defer { if let mounted { _ = try? command("/usr/bin/hdiutil", ["detach", mounted]) } }
        try command("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-type", "SPARSE", "-volname", name, image])
        // Fill the cache first. Every following change must arrive through an
        // event; the 30-second fallback is longer than each eight-second wait.
        _ = DiskDiscovery.shared.snapshot()
        try command("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen", image])
        mounted = original
        XCTAssertTrue(waitUntil { DiskDiscovery.shared.snapshot()?.contains { $0.drive.path?.path == original } == true })
        let first = try XCTUnwrap(DiskDiscovery.shared.snapshot()?.first { $0.drive.path?.path == original })
        try command("/usr/sbin/diskutil", ["renameVolume", original, name + "-renamed"])
        mounted = renamed
        XCTAssertTrue(waitUntil { DiskDiscovery.shared.snapshot()?.contains { $0.drive.path?.path == renamed } == true })
        let changed = try XCTUnwrap(DiskDiscovery.shared.snapshot()?.first { $0.drive.path?.path == renamed })
        XCTAssertEqual(changed.drive.uuid, first.drive.uuid)
        XCTAssertEqual(changed.identity.mediaID, first.identity.mediaID)
        XCTAssertNotEqual(changed.identity, first.identity)
        try command("/usr/bin/hdiutil", ["detach", renamed])
        mounted = nil
        XCTAssertTrue(waitUntil { DiskDiscovery.shared.snapshot()?.contains { $0.drive.uuid == first.drive.uuid } == false })
        XCTAssertEqual(DiskDiscovery.shared.createdSessions, 1)
    }
}
