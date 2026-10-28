import AppKit
import Kit
import RAM
import XCTest

final class SamplingIntegrationTests: XCTestCase {
    func testTopWithoutFrameworkTotalsStillProducesValidMemoryRows() throws {
        let output = try CommandRunner().run("/usr/bin/top", arguments: ["-l", "1", "-F", "-o", "mem", "-stats", "pid,command,mem", "-n", "8"])
        XCTAssertEqual(output.exitCode, 0)
        let text = try XCTUnwrap(String(data: output.stdout, encoding: .utf8))
        var rows: [TopProcess] = []
        text.enumerateLines { line, _ in
            if line.matches("^\\d+\\** +.* +\\d+[A-Z]*\\+?\\-? *$") {
                rows.append(ProcessReader.parseProcess(line))
            }
        }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThanOrEqual(rows.count, 8)
        XCTAssertTrue(rows.allSatisfy { $0.pid > 0 && $0.usage.isFinite && $0.usage >= 0 })
        XCTAssertEqual(Set(rows.map { $0.pid }).count, rows.count)
    }

    func testCPUQueryRunsThroughTheBoundedCollector() throws {
        let output = try CommandRunner().run("/bin/ps", arguments: ["-Aceo pid,pcpu,comm", "-r"])
        XCTAssertEqual(output.exitCode, 0)
        let text = try XCTUnwrap(String(data: output.stdout, encoding: .utf8))
        XCTAssertTrue(text.contains("PID"))
        XCTAssertGreaterThan(text.split(separator: "\n").count, 1)
    }

    func testLiveSharedEnergySourceAndWakeBaseline() throws {
        #if arch(arm64)
        let first = EnergyRateReader()
        let second = EnergyRateReader()
        guard let initial = first.read(), let shared = second.read() else {
            throw XCTSkip("Energy Model channels are unavailable on this host")
        }
        XCTAssertGreaterThanOrEqual(shared.timestamp, initial.timestamp)
        XCTAssertEqual(initial.cpu, 0)
        XCTAssertEqual(shared.cpu, 0)
        Thread.sleep(forTimeInterval: 0.15)
        let next = try XCTUnwrap(first.read())
        XCTAssertGreaterThan(next.timestamp, initial.timestamp)
        XCTAssertTrue([next.cpu, next.gpu, next.ane, next.ram, next.pci].allSatisfy { $0.isFinite && $0 >= 0 })
        // This posts only to this test process's notification center.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let resumed = try XCTUnwrap(first.read())
        XCTAssertEqual(resumed.cpu, 0)
        XCTAssertEqual(resumed.gpu, 0)
        XCTAssertEqual(try XCTUnwrap(second.read()).cpu, 0)
        #else
        throw XCTSkip("Energy Model sharing is specific to Apple silicon")
        #endif
    }
}
