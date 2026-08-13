import Foundation

// SONNY-80 experiment. Owns the two cua-driver child processes of embedded mode and the MCP
// JSON-RPC conversation with them:
//
//   cua-driver serve --embedded --socket <path>   (the daemon: owns the runtime + input/capture)
//   cua-driver mcp   --embedded --socket <path>   (thin stdio proxy; our JSON-RPC peer)
//
// Both are spawned as DIRECT children (never open/NSWorkspace — that breaks macOS TCC
// responsibility inheritance; cua-driver's embedding docs are explicit), so their Accessibility /
// Screen Recording checks resolve against Sonny's own grants. Fail-closed posture throughout: a
// timeout or unexpected exit kills both children and fails every pending request — the loop then
// surfaces the error; nothing retries silently.

actor CUADriverProcess {
    static let requestTimeoutSeconds: Double = 30
    private static let requiredTools: Set<String> = [
        "list_windows", "get_window_state", "click", "double_click", "type_text", "press_key", "scroll"
    ]

    private let environment: [String: String]
    private var daemonProcess: Process?
    private var proxyProcess: Process?
    private var proxyStdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var socketPath: String?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<CUAJSONRPCMessage, Error>] = [:]
    private var stopped = false
    private(set) var serverVersion = "unknown"

    init(environment: [String: String]) {
        self.environment = environment
    }

    // MARK: - Lifecycle

    var isStarted: Bool { proxyProcess != nil }

    func start() async throws {
        guard !isStarted else { return }
        stopped = false
        let binary = try Self.resolveBinary(environment: environment)
        let socket = "/tmp/sonny-cua-\(getpid())-\(UInt32.random(in: 0x1000...0xFFFF_FFFF)).sock"
        socketPath = socket

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: binary)
        daemon.arguments = ["serve", "--embedded", "--socket", socket]
        // Daemon logs go to Sonny's own console so a founder-attended run sees them live.
        do {
            try daemon.run()
        } catch {
            throw VisionActionLoopError.driverFailure("could not launch cua-driver daemon at \(binary): \(error.localizedDescription)")
        }
        daemonProcess = daemon

        // The daemon signals readiness by creating its socket; poll like the reference harness
        // (50ms, 10s deadline) rather than sleeping a fixed amount.
        var waited: UInt64 = 0
        while !FileManager.default.fileExists(atPath: socket) {
            guard daemon.isRunning else {
                await stop()
                throw VisionActionLoopError.driverFailure("cua-driver daemon exited during startup (exit code \(daemon.terminationStatus))")
            }
            guard waited < 10_000_000_000 else {
                await stop()
                throw VisionActionLoopError.driverFailure("cua-driver daemon did not create its socket within 10s")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 50_000_000
        }

        let proxy = Process()
        proxy.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["mcp", "--embedded", "--socket", socket]
        if let bundleID = Bundle.main.bundleIdentifier {
            arguments += ["--host-bundle-id", bundleID]
        }
        proxy.arguments = arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proxy.standardInput = stdinPipe
        proxy.standardOutput = stdoutPipe
        do {
            try proxy.run()
        } catch {
            await stop()
            throw VisionActionLoopError.driverFailure("could not launch cua-driver mcp proxy: \(error.localizedDescription)")
        }
        proxyProcess = proxy
        proxyStdin = stdinPipe.fileHandleForWriting

        let stdout = stdoutPipe.fileHandleForReading
        readerTask = Task { [weak self] in
            do {
                for try await line in stdout.bytes.lines {
                    guard !line.isEmpty else { continue }
                    await self?.route(line: line)
                }
            } catch {
                // Fall through to the EOF handling below — a broken pipe and EOF end the same way.
            }
            await self?.handleProxyEOF()
        }

        // MCP handshake, then verify this binary actually serves the tools the seam depends on —
        // the versioned-contract check recommended for embedded hosts, done at the tools level.
        let initResult = try await send(method: "initialize", params: .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Sonny"), "version": .string("SONNY-80-experiment")])
        ]))
        if let version = initResult["serverInfo"]?["version"]?.stringValue {
            serverVersion = version
        }
        try sendNotification(method: "notifications/initialized")

        let toolsResult = try await send(method: "tools/list", params: nil)
        let advertised = Set((toolsResult["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
        let missing = Self.requiredTools.subtracting(advertised)
        guard missing.isEmpty else {
            await stop()
            throw VisionActionLoopError.driverFailure("cua-driver \(serverVersion) does not advertise required tools: \(missing.sorted().joined(separator: ", "))")
        }
        print("[CUADriver] started cua-driver \(serverVersion) (daemon pid \(daemon.processIdentifier), proxy pid \(proxy.processIdentifier), \(advertised.count) tools)")
    }

    func stop() async {
        stopped = true
        readerTask?.cancel()
        readerTask = nil
        failAllPending(reason: "cua-driver connection closed")
        try? proxyStdin?.close()
        proxyStdin = nil
        for process in [proxyProcess, daemonProcess].compactMap({ $0 }) where process.isRunning {
            process.terminate()
        }
        // Grace period, then SIGKILL — the embedding docs' stop contract (graceful, bounded).
        let survivors = [proxyProcess, daemonProcess].compactMap { $0 }
        proxyProcess = nil
        daemonProcess = nil
        if !survivors.isEmpty {
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                for process in survivors where process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        socketPath = nil
    }

    // MARK: - RPC

    func callTool(_ name: String, arguments: CUAJSONValue) async throws -> (structured: CUAJSONValue, imagePNG: Data?) {
        let result = try await send(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments
        ]))
        return try CUAJSONRPCCodec.unwrapToolResult(result, toolName: name)
    }

    private func send(method: String, params: CUAJSONValue?) async throws -> CUAJSONValue {
        guard let proxyStdin, !stopped else {
            throw VisionActionLoopError.driverFailure("cua-driver is not running")
        }
        let id = nextRequestID
        nextRequestID += 1
        let frame = try CUAJSONRPCCodec.encode(id: id, method: method, params: params)

        let message: CUAJSONRPCMessage = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try proxyStdin.write(contentsOf: frame)
            } catch {
                resumePending(id: id, with: .failure(VisionActionLoopError.driverFailure("could not write to cua-driver: \(error.localizedDescription)")))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeoutSeconds * 1_000_000_000))
                await self?.timeOutRequest(id: id, method: method)
            }
        }
        if let error = message.error {
            let text = error["message"]?.stringValue ?? "unknown JSON-RPC error"
            throw VisionActionLoopError.driverFailure("cua-driver \(method) error: \(text)")
        }
        return message.result ?? .object([:])
    }

    private func sendNotification(method: String) throws {
        guard let proxyStdin else {
            throw VisionActionLoopError.driverFailure("cua-driver is not running")
        }
        let frame = try CUAJSONRPCCodec.encode(id: nil, method: method, params: nil)
        try proxyStdin.write(contentsOf: frame)
    }

    private func route(line: String) {
        guard let message = try? CUAJSONRPCCodec.decode(Data(line.utf8)) else {
            print("[CUADriver] ignoring unparseable frame from proxy: \(line.prefix(200))")
            return
        }
        guard let id = message.id else {
            // Server-initiated notifications (progress/log events) are outside this experiment's
            // needs; they are logged, never silently swallowed, so an attended run can see them.
            if let method = message.method {
                print("[CUADriver] notification: \(method)")
            }
            return
        }
        resumePending(id: id, with: .success(message))
    }

    private func handleProxyEOF() {
        guard !stopped else { return }
        print("[CUADriver] mcp proxy exited unexpectedly — failing pending requests")
        failAllPending(reason: "cua-driver mcp proxy exited unexpectedly")
    }

    private func timeOutRequest(id: Int, method: String) async {
        guard pending[id] != nil else { return }
        // A wedged request means a wedged pipe: fail closed, exactly like a daemon death, rather
        // than leaving later requests to queue behind a dead one.
        print("[CUADriver] \(method) timed out after \(Int(Self.requestTimeoutSeconds))s — stopping cua-driver")
        resumePending(id: id, with: .failure(VisionActionLoopError.driverFailure("cua-driver \(method) timed out after \(Int(Self.requestTimeoutSeconds))s")))
        await stop()
    }

    /// Removal from `pending` is the ownership handoff — whoever removes the continuation is the
    /// only resumer, which is what makes reader/timeout/EOF races resume-exactly-once.
    private func resumePending(id: Int, with result: Result<CUAJSONRPCMessage, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAllPending(reason: String) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: VisionActionLoopError.driverFailure(reason))
        }
    }

    // MARK: - Binary resolution

    static func resolveBinary(environment: [String: String]) throws -> String {
        var candidates: [String] = []
        if let override = environment["SONNY_CUA_DRIVER_PATH"], !override.isEmpty {
            candidates.append(override)
        }
        candidates.append(FileManager.default.currentDirectoryPath + "/vendor/cua-driver/cua-driver")
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("cua-driver").path {
            candidates.append(bundled)
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw VisionActionLoopError.driverFailure(
            "cua-driver binary not found (tried: \(candidates.joined(separator: ", "))). Run scripts/fetch-cua-driver.sh, or set SONNY_CUA_DRIVER_PATH, or set SONNY_VISION_SUBSTRATE=handwritten."
        )
    }
}
