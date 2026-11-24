import Darwin
import Foundation
import SandboxPTY

@MainActor
public final class SandboxTerminal {
    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var connection: Connection?

    public init() {}

    public func start(_ launch: SandboxLaunch, columns: UInt16, rows: UInt16) throws {
        guard connection == nil else { throw SandboxFailure("终端仍在关闭，请稍后重试。") }
        var arguments = ([launch.executable] + launch.arguments).map { strdup($0) }
        var environment = launch.environment.map { strdup($0) }
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        guard !arguments.contains(where: { $0 == nil }), !environment.contains(where: { $0 == nil }) else {
            throw SandboxFailure("无法分配终端启动参数。")
        }
        arguments.append(nil)
        environment.append(nil)
        var descriptor: Int32 = -1
        let pid = sandbox_pty_spawn(launch.executable, &arguments, &environment, launch.workingDirectory,
                                    max(1, columns), max(1, rows), &descriptor)
        guard pid > 0 else {
            throw SandboxFailure("无法创建伪终端（\(String(cString: strerror(errno)))）。")
        }
        let session = Connection(pid: pid, descriptor: descriptor)
        connection = session
        session.start(
            output: { [weak self] data in
                DispatchQueue.main.async { [weak self] in
                    guard self?.connection === session else { return }
                    self?.onOutput?(data)
                }
            },
            finished: { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard self?.connection === session else { return }
                    self?.connection = nil
                    self?.onExit?(status)
                }
            }
        )
    }

    public func write(_ bytes: Data) { connection?.write(bytes) }

    public func resize(columns: UInt16, rows: UInt16) {
        connection?.resize(columns: max(1, columns), rows: max(1, rows))
    }

    public func stop() { connection?.stop() }
}

private final class Connection: @unchecked Sendable {
    private let pid: pid_t
    private let descriptor: Int32
    private let input = DispatchQueue(label: "CCBox.terminal.input", qos: .userInteractive)
    private let lock = NSLock()
    private var active = true

    init(pid: pid_t, descriptor: Int32) {
        self.pid = pid
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    }

    func start(output: @escaping (Data) -> Void, finished: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                if poll(&poller, 1, -1) < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    output(Data(buffer.prefix(count)))
                } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                    break
                }
            }
            // Close only after pending writes and window-size changes leave the descriptor.
            lock.lock()
            active = false
            close(descriptor)
            lock.unlock()
            finished(sandbox_pty_wait(pid))
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if active { sandbox_pty_resize(descriptor, columns, rows) }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        input.async { [self] in
            data.withUnsafeBytes { buffer in
                guard let start = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    lock.lock()
                    guard active else {
                        lock.unlock()
                        return
                    }
                    let written = Darwin.write(descriptor, start + offset, buffer.count - offset)
                    let operationError = errno
                    lock.unlock()
                    if written > 0 {
                        offset += written
                    } else if operationError == EAGAIN {
                        Thread.sleep(forTimeInterval: 0.01)
                    } else if operationError != EINTR {
                        return
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        if kill(-pid, SIGHUP) != 0 { kill(pid, SIGHUP) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            if active {
                if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
            }
        }
    }
}
