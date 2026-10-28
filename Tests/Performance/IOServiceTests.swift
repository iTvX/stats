import Foundation
import IOKit
import XCTest

final class IOServiceTests: XCTestCase {
    private let keys = ["IOClass", "IOPCIMatch", "IOPCIPrimaryMatch", "PerformanceStatistics", "AGCInfo"]

    func testOnlyRequestedPropertiesAreReadForEachVendor() {
        for ioClass in ["AGXAccelerator", "IntelAccelerator", "AMDRadeonX6000", "NVAccelerator"] {
            let fixture: [String: Any] = [
                "IOClass": ioClass, "IOPCIMatch": "0x12341002", "IOPCIPrimaryMatch": "0x12348086",
                "PerformanceStatistics": ["Device Utilization %": 37, "Temperature(C)": 55],
                "AGCInfo": ["poweredOffByAGC": 1], "UnrelatedLargeProperty": Data(count: 25000)
            ]
            var requested: [String] = []
            let selected = selectedIOProperties(self.keys) { key in
                requested.append(key)
                return fixture[key]
            }
            XCTAssertEqual(requested, self.keys)
            XCTAssertEqual(selected?.count, self.keys.count)
            XCTAssertEqual(selected?["IOClass"] as? String, ioClass)
            XCTAssertEqual(selected?["IOPCIMatch"] as? String, "0x12341002")
            XCTAssertEqual(selected?["IOPCIPrimaryMatch"] as? String, "0x12348086")
            XCTAssertEqual(selected?["PerformanceStatistics"] as? [String: Int], ["Device Utilization %": 37, "Temperature(C)": 55])
            XCTAssertEqual(selected?["AGCInfo"] as? [String: Int], ["poweredOffByAGC": 1])
            XCTAssertNil(selected?["UnrelatedLargeProperty"])
        }
    }

    func testMissingOptionalPropertiesAndChangingPowerState() {
        var poweredOff = 0
        for state in [0, 1, 0] {
            poweredOff = state
            let selected = selectedIOProperties(self.keys) { key -> Any? in
                switch key {
                case "IOClass": return "IntelAccelerator"
                case "PerformanceStatistics": return ["GPU Activity(%)": 25]
                case "AGCInfo": return ["poweredOffByAGC": poweredOff]
                default: return nil
                }
            }
            XCTAssertNil(selected?["IOPCIMatch"])
            XCTAssertNil(selected?["IOPCIPrimaryMatch"])
            XCTAssertEqual((selected?["AGCInfo"] as? [String: Int])?["poweredOffByAGC"], state)
        }
    }

    func testMissingServiceAndInvalidEntryReturnNil() {
        XCTAssertNil(fetchIOService("StatsPerformanceTestsNonexistentService", properties: self.keys))
        XCTAssertNil(getIOProperties(0))
        XCTAssertNil(getIOProperties(0, keys: self.keys))
        XCTAssertNil(selectedIOProperties(self.keys, read: { _ in nil }))
    }

    func testLiveGPUSelectionPreservesRequiredPropertyTypes() throws {
        guard let full = fetchIOService("IOAccelerator"), let selected = fetchIOService("IOAccelerator", properties: self.keys) else {
            throw XCTSkip("No IOAccelerator services on this host")
        }
        XCTAssertEqual(selected.compactMap { $0["IOClass"] as? String }.sorted(), full.compactMap { $0["IOClass"] as? String }.sorted())
        for properties in selected {
            XCTAssertTrue(Set(properties.allKeys.compactMap { $0 as? String }).isSubset(of: Set(self.keys)))
            XCTAssertNotNil(properties["IOClass"] as? String)
            XCTAssertNotNil(properties["PerformanceStatistics"] as? [String: Any])
        }
    }
}
