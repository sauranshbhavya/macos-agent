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
    /// The process in front now, if any.
    func frontmostPID() async -> pid_t?
}

extension ScreenApps {
    public func frontmostPID() async -> pid_t? { nil }
}

public struct WorkspaceScreenApps: ScreenApps {
    /// What bringing an app forward asks of the system, as a seam so the fallback can be tested
    /// without moving real windows.
    public struct Foreground: Sendable {
        public var frontmost: @Sendable () async -> pid_t?
        /// `NSRunningApplication.activate()`.
        public var activate: @Sendable (pid_t) async -> Bool
        /// Opening the app through Launch Services, as `open_app` does.
        public var open: @Sendable (pid_t) async -> Bool
        public var settle: @Sendable () async -> Void

        public init(
            frontmost: @escaping @Sendable () async -> pid_t?,
            activate: @escaping @Sendable (pid_t) async -> Bool,
            open: @escaping @Sendable (pid_t) async -> Bool,
            settle: @escaping @Sendable () async -> Void
        ) {
            self.frontmost = frontmost
            self.activate = activate
            self.open = open
            self.settle = settle
        }

        public static let live = Foreground(
            frontmost: { await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } },
            activate: { pid in await MainActor.run { NSRunningApplication(processIdentifier: pid)?.activate() ?? false } },
            open: { pid in
                let bundleID = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
                guard let bundleID else { return false }
                do {
                    try await WorkspaceAppOpener().open(bundleIdentifier: bundleID)
                    return true
                } catch {
                    return false
                }
            },
            settle: { try? await Task.sleep(nanoseconds: 50_000_000) }
        )
    }

    private let resolver: any InstalledAppResolving
    private let foreground: Foreground

    public init(resolver: any InstalledAppResolving = InstalledAppResolver.shared, foreground: Foreground = .live) {
        self.resolver = resolver
        self.foreground = foreground
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

    public func frontmostPID() async -> pid_t? {
        await foreground.frontmost()
    }

    /// Asks directly first. Since macOS 14 the system may ignore that from an app that isn't in front
    /// itself, which Sonny usually isn't once a task has put another app forward: in the founders'
    /// manual pass, Safari couldn't be brought forward right after a page opened in Chrome. So when
    /// asking doesn't bring the app forward, it is opened the way `open_app` opens apps, which did.
    public func activate(pid: pid_t) async -> Bool {
        if await foreground.frontmost() == pid { return true }
        if await foreground.activate(pid), await isFront(pid, checks: 10) { return true }
        guard await foreground.open(pid) else { return false }
        return await isFront(pid, checks: 20)
    }

    private func isFront(_ pid: pid_t, checks: Int) async -> Bool {
        for _ in 0..<checks {
            if await foreground.frontmost() == pid { return true }
            await foreground.settle()
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

/// Why a picture of a window was not taken.
public enum ScreenshotRefusal: Error, Equatable {
    /// The window shows a shell. Sonny doesn't work in shells, so none of it is sent.
    case shellOnScreen
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
        if payload.shellSurface.showsShell { throw ScreenshotRefusal.shellOnScreen }
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
