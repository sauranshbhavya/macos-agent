import AppKit
import Foundation

/// An app the screen capability can act in: installed, and running as `pid` when it is running.
public struct ScreenApp: Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var pid: pid_t?

    public init(bundleID: String, name: String, pid: pid_t?) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// Finds apps and brings them forward. The app's version lives on `NSWorkspace`; tests use a fake.
public protocol ScreenApps: Sendable {
    /// The installed app a name or bundle id names, and its process if it is running.
    func resolve(_ nameOrBundleID: String) async -> ScreenApp?
    /// Brings the app's process to the front. True once it is frontmost.
    func activate(pid: pid_t) async -> Bool
}

public struct WorkspaceScreenApps: ScreenApps {
    private let resolver: any InstalledAppResolving

    public init(resolver: any InstalledAppResolving = InstalledAppResolver.shared) {
        self.resolver = resolver
    }

    public func resolve(_ nameOrBundleID: String) async -> ScreenApp? {
        guard let app = resolver.resolve(nameOrBundleID) else { return nil }
        let pid = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
                .first { !$0.isTerminated }?
                .processIdentifier
        }
        return ScreenApp(bundleID: app.bundleIdentifier, name: app.displayName, pid: pid)
    }

    public func activate(pid: pid_t) async -> Bool {
        let started = await MainActor.run { () -> Bool in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return app.activate()
        }
        guard started else { return false }
        for _ in 0..<20 {
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if front == pid { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

/// One app in front at a time, for any action that needs it there (V2 plan section 6).
///
/// cua refuses background input to a window on another Space, so every screen action brings its
/// app forward first. The lease makes that one task's hold at a time; with concurrent tasks the
/// others wait their turn here.
public actor ForegroundLease {
    public static let shared = ForegroundLease()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func hold<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// A redacted picture of an app's window, ready to send.
public protocol WindowScreenshotting: Sendable {
    func screenshot(bundleID: String) async throws -> ObservationBody.Screenshot
}

/// The existing capture and redaction pipeline: ScreenCaptureKit, then OCR-driven masking of
/// secrets, then encoding within the 3 MB egress limit. An image that could not be scanned is never
/// returned (V2 plan section 7.4, the security floor).
public struct RedactedWindowScreenshots: WindowScreenshotting {
    private let capture: ScreenCaptureService
    private let redaction: LocalRedactionService

    public init(capture: ScreenCaptureService = ScreenCaptureService(), redaction: LocalRedactionService = LocalRedactionService()) {
        self.capture = capture
        self.redaction = redaction
    }

    public func screenshot(bundleID: String) async throws -> ObservationBody.Screenshot {
        let image = try await capture.captureFrontmostWindow(ofBundleIdentifier: bundleID)
        let payload = try await redaction.redactCapture(image)
        guard let data = payload.redactedImageData,
              let width = payload.imagePixelWidth,
              let height = payload.imagePixelHeight
        else {
            throw ScreenCaptureServiceError.captureFailed("the redacted image was empty")
        }
        return ObservationBody.Screenshot(
            mediaType: payload.imageMediaType == .png ? .png : .jpeg,
            data: data.base64EncodedString(),
            width: width,
            height: height
        )
    }
}

/// cua-driver's environment variables that decide its policy. They can only narrow what Sonny's
/// explicit manifest allows or make the driver refuse to start, never widen it (V2 plan section
/// 12), so clearing them is about a stray shell setting breaking screen control, not safety.
/// Cleared at launch, before any other thread starts, because `unsetenv` races with them.
public enum CuaEnvironment {
    public static let managedVariables = [
        "CUA_DRIVER_PERMISSION_MODE",
        "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS",
        "CUA_DRIVER_DISABLE_UNRESTRICTED",
        "CUA_DRIVER_POLICY_FILE",
        "CUA_DRIVER_MANAGED_POLICY_FILE",
        "CUA_DRIVER_CAPABILITY_MANIFEST_FILE",
        "CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED",
        "CUA_DRIVER_SESSION_POLICY_FILE",
        "CUA_DRIVER_SESSION_POLICY_APPROVED",
    ]

    public static func clearManagedVariables() {
        for name in managedVariables { unsetenv(name) }
    }
}
