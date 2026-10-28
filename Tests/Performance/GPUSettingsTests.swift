import AppKit
import Kit
import XCTest

final class GPUSettingsTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? self.buttons(in: $0) }
    }

    func testSameCountReplacementUpdatesSelectionMenu() throws {
        let settings = Settings(.GPU)
        let list = GPUs()
        list.list = [GPU_Info(id: "first", type: "e", IOClass: "fixture", model: "First GPU", cores: 8, utilization: 0.1)]
        settings.setList(list)
        settings.load(widgets: [.mini])
        let menu = try XCTUnwrap(buttons(in: settings).first { $0.itemTitles.contains("First GPU") })
        list.list = [GPU_Info(id: "second", type: "e", IOClass: "fixture", model: "Second GPU", cores: 8, utilization: 0.2)]
        settings.setList(list)
        settings.prepareContent()
        XCTAssertFalse(menu.itemTitles.contains("First GPU"))
        XCTAssertEqual(menu.itemTitles.filter { $0 == "Second GPU" }.count, 1)
    }
}
