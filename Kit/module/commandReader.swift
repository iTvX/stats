import Foundation

/// Reader lifecycle for bounded system commands. Closing the last consuming
/// view cancels in-flight work as well as the queued refreshes in Reader.
open class CommandReader<T: Codable>: Reader<T> {
    public let commandRunner = CommandRunner()

    public override func start() {
        self.commandRunner.resume()
        super.start()
    }

    public override func pause() {
        self.commandRunner.cancel(suspend: true)
        super.pause()
    }

    public override func stop() {
        self.commandRunner.cancel(suspend: true)
        super.stop()
    }

    public override func terminate() {
        self.commandRunner.cancel(suspend: true)
        super.terminate()
    }

    public func refreshCommand() {
        self.commandRunner.cancel()
        self.requestRead()
    }

    public func runCommand(_ executable: String, arguments: [String] = [], timeout: TimeInterval = 5) -> CommandOutput? {
        do {
            let output = try self.commandRunner.run(executable, arguments: arguments, timeout: timeout)
            guard output.exitCode == 0, self.commandRunner.accepts(output) else { return nil }
            return output
        } catch CommandFailure.cancelled {
            return nil
        } catch let failure {
            error("\(URL(fileURLWithPath: executable).lastPathComponent): \(failure)", log: self.log)
            return nil
        }
    }
}
