import CCuaDriver
import Foundation

/// Calls one cua-driver tool by name with JSON arguments and returns the tool's JSON result
/// (https://github.com/trycua/cua). The live implementation is `CuaDriverLibrary`; tests answer
/// the same calls from a scripted app, so everything above this seam runs unchanged in both.
public protocol CuaToolInvoking: Sendable {
    func invoke(_ tool: String, arguments: Data) async throws -> Data
}

public enum CuaDriverError: Error, Equatable, Sendable {
    /// The library would not start: the fetch script has not been run, or it refused its options.
    case unavailable(String)
    /// A call failed at the library, before the tool answered. Carries cua's status and message.
    case call(status: Int32, message: String)
}

/// cua-driver's in-process library, loaded into Sonny's own process (founders, 2026-09-24). That
/// is what makes Sonny's own Accessibility permission the only one a person grants: cua's CLI and
/// MCP routes run through a daemon of its own that macOS asks about separately.
///
/// Created per run, in cua's `bounded` mode, under `CuaCapabilityManifest`: a ceiling of its own
/// that refuses any tool outside Sonny's list and any app but the ones named there, whatever
/// Sonny's own rules would allow. It carries no telemetry; `scripts/fetch-cua-driver.sh` refuses
/// a release whose library does.
public final class CuaDriverLibrary: CuaToolInvoking, @unchecked Sendable {
    // The handle is created once and only destroyed in deinit; cua's calls are thread-safe.
    private let handle: OpaquePointer
    private let manifestURL: URL

    public init(manifest: CuaCapabilityManifest = .milestoneA) throws {
        guard cua_driver_abi_is_compatible_v1(1, 1) else {
            throw CuaDriverError.unavailable("cua-driver's library speaks an incompatible ABI")
        }
        // cua reads its ceiling from a file. A private directory each launch, so nothing on disk
        // outlives the process it governs.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-cua-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        manifestURL = directory.appendingPathComponent("capabilities.yaml")
        try Data(manifest.yaml.utf8).write(to: manifestURL, options: .atomic)

        let options = try JSONSerialization.data(withJSONObject: [
            "authorization": [
                "allowed_modes": ["bounded"],
                "compatibility_mode": "bounded",
                "compatibility_capability_manifest_path": manifestURL.path,
                "unrestricted_acknowledged": false,
                "max_session_ttl_seconds": 3600,
                "max_idle_ttl_seconds": 1800,
            ] as [String: Any],
        ])
        var created: OpaquePointer?
        var error = CuaDriverBuffer(data: nil, len: 0, capacity: 0)
        let status = options.withUnsafeBytes { bytes in
            cua_driver_create_v1(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &created, &error)
        }
        let message = Self.string(error)
        cua_driver_buffer_free_v1(&error)
        guard status == 0, let created else {
            try? FileManager.default.removeItem(at: directory)
            throw CuaDriverError.unavailable(message.isEmpty ? "cua-driver would not start (status \(status))" : message)
        }
        handle = created
    }

    deinit {
        var handle: OpaquePointer? = handle
        cua_driver_destroy_v1(&handle)
        try? FileManager.default.removeItem(at: manifestURL.deletingLastPathComponent())
    }

    public func invoke(_ tool: String, arguments: Data) async throws -> Data {
        let operation = PendingOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                operation.start(continuation)
                let context = Unmanaged.passRetained(operation).toOpaque()
                var token: OpaquePointer?
                var error = CuaDriverBuffer(data: nil, len: 0, capacity: 0)
                let status = Array(tool.utf8).withUnsafeBufferPointer { name in
                    arguments.withUnsafeBytes { bytes in
                        cua_driver_invoke_v1(
                            handle, name.baseAddress, name.count,
                            bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                            { context, status, result, error in
                                let operation = Unmanaged<PendingOperation>.fromOpaque(context!).takeRetainedValue()
                                var result = result
                                var error = error
                                operation.complete(status: status, result: CuaDriverLibrary.data(result), message: CuaDriverLibrary.string(error))
                                cua_driver_buffer_free_v1(&result)
                                cua_driver_buffer_free_v1(&error)
                            },
                            context, &token, &error
                        )
                    }
                }
                if status != 0 {
                    // Not admitted, so the callback never runs: release what it would have.
                    Unmanaged<PendingOperation>.fromOpaque(context).release()
                    let message = Self.string(error)
                    cua_driver_buffer_free_v1(&error)
                    operation.complete(status: status, result: Data(), message: message)
                } else {
                    operation.admitted(token)
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    static func string(_ buffer: CuaDriverBuffer) -> String {
        String(decoding: data(buffer), as: UTF8.self)
    }

    static func data(_ buffer: CuaDriverBuffer) -> Data {
        guard let bytes = buffer.data, buffer.len > 0 else { return Data() }
        return Data(bytes: bytes, count: buffer.len)
    }
}

/// One call in flight: resumes its continuation exactly once, and owns the cancellation token.
///
/// The token is released exactly once, by whichever of two things happens last: the call being
/// admitted (the library hands the token back) or the call finishing (its callback runs), and
/// never while a cancel is using it. cua may finish a call before `invoke` returns, and a cancel
/// may land at any moment, so every step takes the lock; it is recursive because cancelling may
/// run the completion on the cancelling thread.
private final class PendingOperation: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var token: OpaquePointer?
    private var finished = false
    private var cancelRequested = false
    private var cancelling = false

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func admitted(_ token: OpaquePointer?) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
        if finished {
            releaseToken()
        } else if cancelRequested {
            cancelNow()
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested = true
        if !finished { cancelNow() }
    }

    func complete(status: Int32, result: Data, message: String) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if !cancelling { releaseToken() }
        let continuation = self.continuation
        self.continuation = nil
        let cancelled = cancelRequested
        lock.unlock()
        if status == 0 {
            continuation?.resume(returning: result)
        } else if status == 5 || cancelled {
            // 5 is CUA_DRIVER_STATUS_CANCELLED.
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: CuaDriverError.call(status: status, message: message))
        }
    }

    /// With the lock held.
    private func cancelNow() {
        guard let token, !cancelling else { return }
        cancelling = true
        cua_driver_operation_cancel_v1(token)
        cancelling = false
        if finished { releaseToken() }
    }

    /// With the lock held.
    private func releaseToken() {
        guard token != nil else { return }
        cua_driver_operation_release_v1(&token)
        token = nil
    }
}
