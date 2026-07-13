import Foundation

public protocol UsageProvider: Sendable {
    func fetch() async throws -> UsageSnapshot
}

public final class CodexAppServerClient: UsageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var initialized = false
    private var startupTask: Task<Void, Error>?
    private var snapshotHandler: (@Sendable (UsageSnapshot) -> Void)?

    public init() {}

    public func setSnapshotHandler(_ handler: (@Sendable (UsageSnapshot) -> Void)?) {
        lock.withLock { snapshotHandler = handler }
    }

    deinit { stop() }

    public func fetch() async throws -> UsageSnapshot {
        try await ensureStarted()
        let result = try await request(method: "account/rateLimits/read", params: [:])
        return try AppServerUsageParser.parseResult(result)
    }

    public func stop() {
        let state: (Process?, FileHandle?, [CheckedContinuation<Data, Error>]) = lock.withLock {
            let state = (process, output, Array(pending.values))
            process = nil
            input = nil
            output = nil
            outputBuffer.removeAll(keepingCapacity: false)
            pending.removeAll()
            initialized = false
            startupTask = nil
            return state
        }
        state.1?.readabilityHandler = nil
        state.0?.terminationHandler = nil
        if state.0?.isRunning == true { state.0?.terminate() }
        state.2.forEach { $0.resume(throwing: ClientError.disconnected) }
    }

    private func ensureStarted() async throws {
        if lock.withLock({ initialized }) { return }

        let task: Task<Void, Error> = lock.withLock {
            if let startupTask { return startupTask }
            let task = Task { [weak self] in
                guard let self else { throw ClientError.disconnected }
                try await self.startProcess()
            }
            startupTask = task
            return task
        }

        do {
            try await task.value
        } catch {
            stop()
            throw error
        }
    }

    private func startProcess() async throws {
        let executable = try Self.findCodexExecutable()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] _ in self?.processDidTerminate() }
        try process.run()

        lock.withLock {
            self.process = process
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "codex-usage-menu", "version": "3.1.0"],
                "capabilities": ["experimentalApi": true],
            ]
        )
        try sendNotification(method: "initialized", params: [:])
        lock.withLock {
            initialized = true
            startupTask = nil
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            } catch {
                let saved = lock.withLock { pending.removeValue(forKey: id) }
                saved?.resume(throwing: error)
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.timeoutRequest(id)
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try lock.withLock {
            guard let input else { throw ClientError.disconnected }
            try input.write(contentsOf: data)
        }
    }

    private func consume(_ data: Data) {
        let lines: [Data] = lock.withLock {
            outputBuffer.append(data)
            var result: [Data] = []
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                result.append(outputBuffer[..<newline])
                outputBuffer.removeSubrange(...newline)
            }
            return result
        }

        for line in lines {
            guard let parsed = try? RPCEnvelope.parse(line) else { continue }
            if let response = parsed.response {
                let continuation = lock.withLock { pending.removeValue(forKey: response.id) }
                if let errorMessage = response.errorMessage {
                    continuation?.resume(throwing: ClientError.server(errorMessage))
                } else if let result = response.result {
                    continuation?.resume(returning: result)
                } else {
                    continuation?.resume(throwing: ClientError.invalidResponse)
                }
            } else if parsed.method == "account/rateLimits/updated",
                      let params = parsed.params,
                      let snapshot = try? AppServerUsageParser.parseResult(params) {
                lock.withLock { snapshotHandler }?(snapshot)
            }
        }
    }

    private func timeoutRequest(_ id: Int) {
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(throwing: ClientError.timedOut)
    }

    private func processDidTerminate() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Data, Error>] in
            process = nil
            input = nil
            output = nil
            initialized = false
            startupTask = nil
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        continuations.forEach { $0.resume(throwing: ClientError.disconnected) }
    }

    static var codexExecutableCandidates: [String] {
        [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }

    private static func findCodexExecutable() throws -> URL {
        let candidates = codexExecutableCandidates
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        throw ClientError.codexNotFound
    }

    public enum ClientError: LocalizedError {
        case codexNotFound
        case disconnected
        case invalidResponse
        case server(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .codexNotFound: "未找到 Codex 命令行组件"
            case .disconnected: "Codex 用量服务连接已断开"
            case .invalidResponse: "Codex 用量服务返回了无效响应"
            case .server(let message): "Codex 用量服务错误：\(message)"
            case .timedOut: "Codex 用量服务请求超时"
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
