import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// SONNY-80 experiment (stacks on the SONNY-69 spike lineage — never merges without the founder's
// explicit approval). The seam between the vision action loop and the substrate that executes its
// computer-use primitives. Window-scoped by design: the loop reasons about one target window and
// image-pixel coordinates inside its screenshot; each substrate owns the mapping from image pixels
// to real input events — the handwritten one via the spike's original CGWindowList + CGEvent math,
// the CUA one by delegating to cua-driver, which performs the same pixel→point conversion
// internally. Keeping that mapping substrate-side is what lets an A/B run differ ONLY in substrate
// while the loop's semantics, prompts, and logging stay identical above this seam.

/// One captured frame of the target app's front window, in whatever pixel density the substrate
/// natively produces (the handwritten substrate captures at 1x; cua-driver returns Retina-native
/// 2x). The loop never assumes a scale — it derives it from `windowFrame` vs the image dimensions.
public struct DriverWindowCapture: @unchecked Sendable {
    // @unchecked: CGImage is an immutable CoreGraphics object and safe to share across
    // concurrency domains; the SDK just doesn't annotate it as Sendable on all toolchains.
    public let image: CGImage
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    /// Global top-left-origin display coordinates in logical points, as of capture time.
    public let windowFrame: CGRect
    public let windowTitle: String

    public init(image: CGImage, windowID: CGWindowID, ownerPID: pid_t, windowFrame: CGRect, windowTitle: String) {
        self.image = image
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.windowFrame = windowFrame
        self.windowTitle = windowTitle
    }
}

/// What became of one requested click. The non-`posted` cases are the loop's cue to skip, tell the
/// model why in its history, and recapture — they are expected outcomes, not errors.
public enum DriverClickOutcome: Equatable, Sendable {
    /// The event was dispatched (not verified — the loop verifies visually on the next capture).
    /// `globalPoint` is where the substrate resolved the click in global display points.
    case posted(globalPoint: CGPoint)
    /// The window vanished between capture and click.
    case windowDisappeared
    /// The window resized between capture and click, so the model's point would be a lie.
    case windowResized(from: CGSize, to: CGSize)
    /// The resolved point sits inside one of the caller's forbidden rects (Sonny's own windows).
    case suppressed(globalPoint: CGPoint, blockedBy: CGRect)
    /// The substrate itself refused (cua-driver's fail-closed paths, e.g. incoherent pixel frame).
    case refusedByDriver(reason: String)
}

/// The non-text keys the substrates can synthesize. Raw values are cua-driver's key names; the
/// handwritten substrate maps them to macOS virtual keycodes.
public enum ComputerUseKey: String, Sendable {
    case returnKey = "return"
    case tab = "tab"
    case space = "space"
    case delete = "delete"
    case escape = "escape"
    case upArrow = "up"
    case downArrow = "down"
    case leftArrow = "left"
    case rightArrow = "right"

    var macKeyCode: CGKeyCode {
        switch self {
        case .returnKey: return 36
        case .tab: return 48
        case .space: return 49
        case .delete: return 51
        case .escape: return 53
        case .leftArrow: return 123
        case .rightArrow: return 124
        case .downArrow: return 125
        case .upArrow: return 126
        }
    }
}

public enum ComputerUseScrollDirection: String, Sendable {
    case up, down, left, right
}

/// Exactly the primitives the vision action loop needs, plus the double-click/key/scroll surface
/// the eventual production build will want from whichever substrate wins. Every implementation
/// must keep the same observable semantics: clicks resolve against the window's FRESH frame (a
/// pure move translates, a resize refuses), `typeText` delivers newlines as real Return key
/// presses (never inserted "\n" characters — a live-observed spike failure mode), and nothing is
/// verified optimistically — the loop confirms visually.
public protocol ComputerUseDriver: Sendable {
    /// Short name for transcripts, so an A/B run records which substrate produced it.
    var substrateDescription: String { get }

    /// Throws a user-actionable error when Screen Recording / Accessibility are missing.
    func preflightPermissions() throws

    /// One-time substrate startup, called after the permission preflight and before the loop's
    /// first transcript line (the CUA substrate launches its child processes here, so its real
    /// version is known to the transcript). Must be idempotent.
    func prepare() async throws

    /// Brings the target app forward and returns its pid, or nil when it isn't running.
    func activateApp(named appName: String) async -> pid_t?
    func visibleAppNames() async -> [String]

    func captureFrontWindow(ofProcess pid: pid_t, appName: String) async throws -> DriverWindowCapture

    /// `point` is in `capture.image` pixels. `forbiddenGlobalRects` are global-point regions the
    /// click must never land in (Sonny's own windows); the substrate checks them against the
    /// freshly resolved global point, not the stale capture-time frame.
    func clickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome
    func doubleClickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome

    /// Sends real keystrokes to whatever currently has keyboard focus.
    func typeText(_ text: String) async throws
    func pressKey(_ key: ComputerUseKey) async throws

    /// `point` (image pixels) targets a scrollable region; nil scrolls wherever focus/cursor is.
    func scrollInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint?, direction: ComputerUseScrollDirection, amount: Int) async throws

    /// Tears down any substrate-owned resources (the CUA substrate's child processes). Called at
    /// the end of every loop run, including error exits. Must be safe to call more than once.
    func shutdown() async
}

extension ComputerUseDriver {
    // Both real substrates run inside Sonny's own process (cua-driver as a direct child inherits
    // Sonny's TCC responsibility), so the permission preflight is identical for them and lives
    // here once. Moved verbatim from the spike's VisionActionLoop.
    public func preflightPermissions() throws {
        if !CGPreflightScreenCaptureAccess() {
            // Triggers the system prompt / creates the System Settings entry, but the grant only
            // takes effect after relaunch — so this attempt still fails loudly.
            CGRequestScreenCaptureAccess()
            throw VisionActionLoopError.screenRecordingNotGranted
        }
        // Literal value of kAXTrustedCheckOptionPrompt — the SDK global is a mutable `var` and
        // Swift 6 strict concurrency refuses to read it from a nonisolated context.
        let promptKey = "AXTrustedCheckOptionPrompt"
        if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
            throw VisionActionLoopError.accessibilityNotGranted
        }
    }

    // App activation is deliberately shared: it is Sonny-side orchestration (NSWorkspace), not
    // input synthesis, and both substrates need the exact same behavior for a fair A/B. It lives
    // on the protocol (rather than in the loop) so tests can run the loop against a mock driver
    // without touching the real NSWorkspace. (AppKit values never leave the MainActor closures.)
    public func activateApp(named appName: String) async -> pid_t? {
        await MainActor.run {
            let apps = NSWorkspace.shared.runningApplications
            let match = apps.first { $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame }
                ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(appName) ?? false }
            guard let match else { return nil }
            match.activate()
            return match.processIdentifier
        }
    }

    public func visibleAppNames() async -> [String] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.localizedName }
                .sorted()
        }
    }

    public func prepare() async throws {}

    public func shutdown() async {}
}

public enum ComputerUseSubstrate: String, Equatable, Sendable {
    case cua
    case handwritten
}

public enum ComputerUseDriverFactory {
    /// SONNY_VISION_SUBSTRATE=handwritten selects the spike's original substrate; anything else
    /// (including unset) selects the CUA driver — it is the experiment's default per SONNY-80.
    /// An unrecognized value falls back to the default rather than failing the run.
    public static func substrate(fromEnvironment environment: [String: String]) -> ComputerUseSubstrate {
        environment["SONNY_VISION_SUBSTRATE"]?.lowercased() == "handwritten" ? .handwritten : .cua
    }

    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> any ComputerUseDriver {
        switch substrate(fromEnvironment: environment) {
        case .handwritten:
            return HandwrittenComputerUseDriver()
        case .cua:
            return CUAComputerUseDriver(environment: environment)
        }
    }
}
