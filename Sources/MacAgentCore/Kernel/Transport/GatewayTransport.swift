import Foundation

public enum GatewayChannelEvent: Sendable, Equatable {
    case text(String)
    case closed(code: Int, reason: String)
}

public enum GatewayTransportError: Error, Sendable, Equatable {
    /// The upgrade was answered with an ordinary HTTP status: 401 for a token, 410 for a client too
    /// old, 503 for a gateway that is restarting.
    case refused(status: Int)
    case unreachable(String)
}

/// One open socket. Frames arrive on `events`, which ends after `.closed`.
public protocol GatewayChannel: Sendable {
    var events: AsyncStream<GatewayChannelEvent> { get }
    func send(_ text: String) async throws
    func close(code: Int) async
}

/// Opens sockets to the gateway. Tests use an in-memory transport; the app uses URLSession.
public protocol GatewayTransport: Sendable {
    func open(url: URL, headers: [String: String]) async throws -> any GatewayChannel
}

public struct URLSessionGatewayTransport: GatewayTransport {
    public init() {}

    public func open(url: URL, headers: [String: String]) async throws -> any GatewayChannel {
        let channel = URLSessionGatewayChannel(url: url, headers: headers)
        try await channel.open()
        return channel
    }
}

final class URLSessionGatewayChannel: NSObject, GatewayChannel, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// A little above the gateway's 6 MiB frame limit.
    static let maximumMessageSize = 8 * 1024 * 1024

    let events: AsyncStream<GatewayChannelEvent>
    private let continuation: AsyncStream<GatewayChannelEvent>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, any Error>?
    private var finished = false
    private let request: URLRequest

    init(url: URL, headers: [String: String]) {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 15
        self.request = request
        (events, continuation) = AsyncStream.makeStream(of: GatewayChannelEvent.self)
        super.init()
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (opening: CheckedContinuation<Void, any Error>) in
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = Self.maximumMessageSize
            lock.withLock {
                self.session = session
                self.task = task
                self.opening = opening
            }
            task.resume()
        }
    }

    func send(_ text: String) async throws {
        guard let task = lock.withLock({ task }) else { throw GatewayTransportError.unreachable("not open") }
        try await task.send(.string(text))
    }

    func close(code: Int) async {
        let task = lock.withLock { self.task }
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        finish(code: code, reason: "closed by the Mac")
    }

    private func finish(code: Int, reason: String) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        continuation.yield(.closed(code: code, reason: reason))
        continuation.finish()
        lock.withLock { session }?.invalidateAndCancel()
    }

    private func receiveNext() {
        guard let task = lock.withLock({ task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                continuation.yield(.text(text))
                receiveNext()
            case .success:
                // The protocol has no binary frames.
                task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: 4400) ?? .protocolError, reason: nil)
                finish(code: 4400, reason: "binary frame")
            case .failure:
                // The delegate reports the close with its code.
                break
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let opening = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.opening = nil }
            return self.opening
        }
        opening?.resume()
        receiveNext()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let opening = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.opening = nil }
            return self.opening
        }
        if let opening {
            if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                opening.resume(throwing: GatewayTransportError.refused(status: status))
            } else {
                opening.resume(throwing: GatewayTransportError.unreachable(error?.localizedDescription ?? "closed"))
            }
        }
        finish(code: 1006, reason: error?.localizedDescription ?? "connection lost")
    }
}
