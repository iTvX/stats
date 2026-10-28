import Foundation
import Darwin

public struct CommandOutput {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    fileprivate let generation: UInt64
}

public enum CommandFailure: Error, Equatable {
    case cancelled, busy, timedOut, outputLimit
    case system(Int32)
}

/// Owns and reaps one child process. Both pipes are drained without blocking;
/// cancellation only signals the process group created for this command.
public final class CommandRunner {
    private let lock = NSLock()
    private var enabled = true
    private var generation: UInt64 = 0
    private var pid: pid_t?

    public init() {}

    public var isRunning: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pid != nil
    }

    public func resume() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.enabled = true
    }

    public func cancel(suspend: Bool = false) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.generation &+= 1
        if suspend { self.enabled = false }
        if let pid = self.pid { kill(-pid, SIGTERM) }
    }

    public func accepts(_ output: CommandOutput) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.enabled && output.generation == self.generation
    }

    public func run(_ executable: String, arguments: [String] = [], timeout: TimeInterval = 5, maxBytes: Int = 8 * 1024 * 1024) throws -> CommandOutput {
        guard timeout.isFinite, timeout > 0, maxBytes > 0 else { throw CommandFailure.system(EINVAL) }
        self.lock.lock()
        let available = self.enabled && self.pid == nil
        let wasEnabled = self.enabled
        self.lock.unlock()
        guard available else { throw wasEnabled ? CommandFailure.busy : CommandFailure.cancelled }

        let stdoutPipe = try self.makePipe()
        defer { close(stdoutPipe.0) }
        let stderrPipe: (Int32, Int32)
        do { stderrPipe = try self.makePipe() } catch {
            close(stdoutPipe.1)
            throw error
        }
        defer { close(stderrPipe.0) }

        let child: (pid: pid_t, generation: UInt64)
        do {
            child = try self.launch(executable, arguments: arguments, stdout: stdoutPipe, stderr: stderrPipe)
        } catch {
            close(stdoutPipe.1)
            close(stderrPipe.1)
            throw error
        }
        close(stdoutPipe.1)
        close(stderrPipe.1)
        return try self.collect(child, stdout: stdoutPipe.0, stderr: stderrPipe.0, timeout: timeout, maxBytes: maxBytes)
    }

    private func makePipe() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw CommandFailure.system(errno) }
        do {
            for index in descriptors.indices {
                if descriptors[index] < 3 {
                    let copied = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                    guard copied >= 0 else { throw CommandFailure.system(errno) }
                    close(descriptors[index])
                    descriptors[index] = copied
                }
                guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) == 0 else { throw CommandFailure.system(errno) }
            }
            guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { throw CommandFailure.system(errno) }
            return (descriptors[0], descriptors[1])
        } catch {
            descriptors.forEach { close($0) }
            throw error
        }
    }

    private func launch(_ executable: String, arguments: [String], stdout: (Int32, Int32), stderr: (Int32, Int32)) throws -> (pid: pid_t, generation: UInt64) {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try self.check(posix_spawn_file_actions_adddup2(&actions, stdout.1, STDOUT_FILENO))
        try self.check(posix_spawn_file_actions_adddup2(&actions, stderr.1, STDERR_FILENO))
        for fd in [stdout.0, stdout.1, stderr.0, stderr.1] {
            try self.check(posix_spawn_file_actions_addclose(&actions, fd))
        }
        var mask = sigset_t()
        sigemptyset(&mask)
        try self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        try self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try self.check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try self.check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        let strings = ([executable] + arguments).map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            strings.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard strings.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw CommandFailure.system(ENOMEM) }
        var argv = strings + [nil]
        var envp = environment + [nil]
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.enabled else { throw CommandFailure.cancelled }
        guard self.pid == nil else { throw CommandFailure.busy }
        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try self.check(status)
        self.pid = pid
        return (pid, self.generation)
    }

    private func collect(_ child: (pid: pid_t, generation: UInt64), stdout: Int32, stderr: Int32, timeout: TimeInterval, maxBytes: Int) throws -> CommandOutput {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = [Data(), Data()]
        var pipes = [pollfd(fd: stdout, events: Int16(POLLIN), revents: 0), pollfd(fd: stderr, events: Int16(POLLIN), revents: 0)]
        var ended = [false, false]
        var failure: CommandFailure?
        var terminationTime: TimeInterval?
        var killed = false
        var buffer = [UInt8](repeating: 0, count: 8192)

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            if self.generation != child.generation { failure = failure ?? .cancelled }
            if now >= deadline { failure = failure ?? .timedOut }
            if failure != nil && terminationTime == nil {
                kill(-child.pid, SIGTERM)
                terminationTime = now
            }
            if let terminationTime, now - terminationTime >= 0.2, !killed {
                kill(-child.pid, SIGKILL)
                killed = true
            }
            // Do not reap while a descendant might still hold a pipe. Keeping
            // the child unreaped also prevents its PID being reused by a kill.
            if ended.allSatisfy({ $0 }) || (killed && now - (terminationTime ?? now) >= 0.4) {
                var status: Int32 = 0
                let result = waitpid(child.pid, &status, WNOHANG)
                if result == child.pid || (result < 0 && errno == ECHILD) {
                    self.pid = nil
                    self.lock.unlock()
                    if let failure { throw failure }
                    guard result == child.pid else { throw CommandFailure.system(ECHILD) }
                    let exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    return CommandOutput(stdout: output[0], stderr: output[1], exitCode: exitCode, generation: child.generation)
                }
            }
            self.lock.unlock()

            let status = pipes.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 25) }
            if status < 0 && errno != EINTR { failure = failure ?? .system(errno) }
            for index in pipes.indices where !ended[index] && pipes[index].revents != 0 {
                // Bound each drain pass so a continuously writing command
                // cannot starve timeout and cancellation checks.
                for _ in 0..<8 {
                    let count = Darwin.read(pipes[index].fd, &buffer, buffer.count)
                    if count > 0 {
                        let remaining = max(0, maxBytes - output[0].count - output[1].count)
                        output[index].append(contentsOf: buffer.prefix(min(count, remaining)))
                        if count > remaining { failure = failure ?? .outputLimit }
                    } else if count == 0 {
                        ended[index] = true
                        pipes[index].fd = -1
                        break
                    } else {
                        if errno != EAGAIN && errno != EINTR { failure = failure ?? .system(errno) }
                        break
                    }
                }
            }
        }
    }

    private func check(_ status: Int32) throws {
        guard status == 0 else { throw CommandFailure.system(status) }
    }
}
