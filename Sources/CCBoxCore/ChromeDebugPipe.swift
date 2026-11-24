import Darwin
import Foundation

final class ChromeDebugPipe: @unchecked Sendable {
    let input = Pipe()
    let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var stopped = false

    var environment: [String: String] {
        [
            "CCBOX_CDP_READ_FD": String(input.fileHandleForWriting.fileDescriptor),
            "CCBOX_CDP_WRITE_FD": String(output.fileHandleForReading.fileDescriptor)
        ]
    }

    func start() {
        for descriptor in [
            input.fileHandleForReading.fileDescriptor,
            input.fileHandleForWriting.fileDescriptor,
            output.fileHandleForReading.fileDescriptor,
            output.fileHandleForWriting.fileDescriptor
        ] {
            _ = fcntl(descriptor, F_SETFD, 0)
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
    }

    func open(_ url: URL) async throws {
        let id = try reserve()
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            timeouts[id] = Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.finish(id, with: .failure(SandboxFailure("打开隔离 Chrome 页面超时。")))
            }
            do {
                let message: [String: Any] = [
                    "id": id,
                    "method": "Target.createTarget",
                    "params": ["url": url.absoluteString]
                ]
                var data = try JSONSerialization.data(withJSONObject: message)
                data.append(0)
                input.fileHandleForWriting.write(data)
            } catch {
                finish(id, with: .failure(error))
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let continuations = pending
        pending.removeAll()
        timeouts.removeAll()
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        for (_, continuation) in continuations {
            continuation.resume(throwing: SandboxFailure("Chrome 控制通道已关闭。"))
        }
    }

    private func reserve() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw SandboxFailure("Chrome 控制通道已关闭。") }
        defer { nextID += 1 }
        return nextID
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var messages: [Data] = []
        while let separator = buffer.firstIndex(of: 0) {
            messages.append(buffer.prefix(separator))
            buffer.removeSubrange(...separator)
        }
        lock.unlock()

        for message in messages {
            guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            if object["error"] != nil {
                finish(id, with: .failure(SandboxFailure("隔离 Chrome 拒绝了页面打开请求。")))
            } else {
                finish(id, with: .success(()))
            }
        }
    }

    private func finish(_ id: Int, with result: Result<Void, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        let timeout = timeouts.removeValue(forKey: id)
        lock.unlock()
        timeout?.cancel()
        switch result {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
