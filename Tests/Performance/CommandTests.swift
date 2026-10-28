import Foundation
import XCTest
import Darwin

private final class FixtureCommandReader: CommandReader<Int> {
    var arguments = ["ignore-term"]
    var finished: () -> Void = {}

    override func setup() { self.popup = true }

    override func read() {
        defer { self.finished() }
        guard let executable = ProcessInfo.processInfo.environment["STATS_COMMAND_FIXTURE"],
              let output = self.runCommand(executable, arguments: self.arguments), self.commandRunner.accepts(output) else { return }
        self.callback(1)
    }
}

final class CommandTests: XCTestCase {
    private var executable: String { ProcessInfo.processInfo.environment["STATS_COMMAND_FIXTURE"]! }

    private func waitUntilRunning(_ runner: CommandRunner) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !runner.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertTrue(runner.isRunning)
    }

    private func expectFailure(_ expected: CommandFailure, _ work: () throws -> CommandOutput, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { error in
            XCTAssertEqual(error as? CommandFailure, expected, file: file, line: line)
        }
    }

    func testArgumentsArePassedWithoutShellExpansion() throws {
        let value = "literal $HOME $(uname) `date` \"quotes\" 中文"
        let output = try CommandRunner().run(executable, arguments: ["echo", value])
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), value)
        XCTAssertEqual(output.exitCode, 0)
    }

    func testBothPipesAreDrainedEvenWhenStderrFillsFirst() throws {
        let output = try CommandRunner().run(executable, arguments: ["flood"])
        XCTAssertEqual(output.stdout.count, 64 * 4096)
        XCTAssertEqual(output.stderr.count, 64 * 4096)
        XCTAssertEqual(output.exitCode, 0)
    }

    func testExitCodeAndStderrArePreserved() throws {
        let output = try CommandRunner().run(executable, arguments: ["exit"])
        XCTAssertEqual(output.exitCode, 42)
        XCTAssertEqual(output.stdout, Data("out".utf8))
        XCTAssertEqual(output.stderr, Data("err".utf8))
    }

    func testChildCannotWaitForInteractiveInput() throws {
        let output = try CommandRunner().run(executable, arguments: ["stdin"])
        XCTAssertEqual(output.stdout, Data("closed".utf8))
    }

    func testTimeoutKillsACommandThatIgnoresTermination() {
        let runner = CommandRunner()
        let start = ProcessInfo.processInfo.systemUptime
        expectFailure(.timedOut) { try runner.run(executable, arguments: ["ignore-term"], timeout: 0.1) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertFalse(runner.isRunning)
    }

    func testClosedOutputDoesNotBypassTheTimeout() {
        let runner = CommandRunner()
        expectFailure(.timedOut) { try runner.run(executable, arguments: ["closed-output"], timeout: 0.1) }
        XCTAssertFalse(runner.isRunning)
    }

    func testDescendantHoldingPipesCannotHangTheReader() {
        let runner = CommandRunner()
        let start = ProcessInfo.processInfo.systemUptime
        expectFailure(.timedOut) { try runner.run(executable, arguments: ["descendant"], timeout: 0.1) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertFalse(runner.isRunning)
    }

    func testOutputLimitStopsTheCommandAndAllowsTheNextOne() throws {
        let runner = CommandRunner()
        expectFailure(.outputLimit) { try runner.run(executable, arguments: ["flood"], maxBytes: 8192) }
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(try runner.run(executable, arguments: ["echo", "next"]).stdout, Data("next".utf8))
    }

    func testSpawnFailureDoesNotLeaveRunnerBusy() throws {
        let runner = CommandRunner()
        expectFailure(.system(ENOENT)) { try runner.run("/nonexistent/stats-test-command") }
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(try runner.run(executable, arguments: ["echo", "next"]).exitCode, 0)
    }

    func testSuspendBeforeLaunchAndResume() throws {
        let runner = CommandRunner()
        runner.cancel(suspend: true)
        expectFailure(.cancelled) { try runner.run(executable, arguments: ["echo", "no"]) }
        runner.resume()
        XCTAssertEqual(try runner.run(executable, arguments: ["echo", "yes"]).stdout, Data("yes".utf8))
    }

    func testCancelReturnsPromptlyAndDoesNotPermitOverlap() throws {
        let runner = CommandRunner()
        let done = expectation(description: "cancelled command reaped")
        DispatchQueue.global().async {
            self.expectFailure(.cancelled) { try runner.run(self.executable, arguments: ["ignore-term"]) }
            done.fulfill()
        }
        waitUntilRunning(runner)
        expectFailure(.busy) { try runner.run(executable, arguments: ["echo", "overlap"]) }
        let start = ProcessInfo.processInfo.systemUptime
        runner.cancel(suspend: true)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.2)
        wait(for: [done], timeout: 2)
        runner.resume()
        XCTAssertEqual(try runner.run(executable, arguments: ["echo", "resumed"]).stdout, Data("resumed".utf8))
    }

    func testCancelledGenerationRejectsAnAlreadyCollectedResult() throws {
        let runner = CommandRunner()
        let output = try runner.run(executable, arguments: ["echo", "old"])
        XCTAssertTrue(runner.accepts(output))
        runner.cancel()
        XCTAssertFalse(runner.accepts(output))
        let next = try runner.run(executable, arguments: ["echo", "new"])
        XCTAssertTrue(runner.accepts(next))
    }

    func testRepeatedQueriesDoNotLeakFileDescriptors() throws {
        func count() -> Int { (0..<512).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        let runner = CommandRunner()
        let before = count()
        for _ in 0..<40 { _ = try runner.run(executable, arguments: ["echo", "sample"]) }
        XCTAssertEqual(count(), before)
    }

    func testUnrelatedParentDescriptorIsNotInherited() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(try CommandRunner().run(executable, arguments: ["descriptor", String(descriptor)]).exitCode, 0)
    }

    func testReaderPauseCancelsAndStartAllowsFreshData() {
        let reader = FixtureCommandReader(.CPU)
        let stopped = expectation(description: "paused read finished")
        reader.finished = { stopped.fulfill() }
        reader.callbackHandler = { _ in XCTFail("Cancelled query delivered a result") }
        reader.start()
        waitUntilRunning(reader.commandRunner)
        reader.pause()
        wait(for: [stopped], timeout: 2)
        let fresh = expectation(description: "fresh result after restart")
        reader.finished = {}
        reader.arguments = ["echo", "fresh"]
        reader.callbackHandler = { _ in fresh.fulfill() }
        reader.start()
        wait(for: [fresh], timeout: 2)
        reader.stop()
    }

    func testSettingsRefreshDoesNotEnableAPausedReader() {
        let reader = FixtureCommandReader(.CPU)
        reader.pause()
        let completed = expectation(description: "paused manual request returns")
        reader.finished = { completed.fulfill() }
        reader.callbackHandler = { _ in XCTFail("Paused reader delivered a result") }
        reader.refreshCommand()
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(reader.commandRunner.isRunning)
    }
}
