import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Permission seam

/// Live TCC state for the two System-Settings-only grants vision features need. Both are
/// preflight-style booleans rather than authorization-status enums because macOS exposes no
/// "not determined vs. denied" distinction for either — `CGPreflightScreenCaptureAccess` and
/// `AXIsProcessTrusted` answer only "granted right now, for this process".
public protocol ScreenCapturePermissionChecking: Sendable {
    func hasScreenRecordingPermission() -> Bool

    /// Registers the app in System Settings › Privacy & Security › Screen Recording and shows the
    /// one-time system dialog if it has never been shown. Returns the *current* grant, which stays
    /// `false` for this process even after the user toggles the switch — Screen Recording grants
    /// only take effect after relaunch.
    @discardableResult
    func requestScreenRecordingPermission() -> Bool

    func isAccessibilityTrusted() -> Bool

    /// Shows the system's Accessibility prompt (which routes to System Settings) if untrusted.
    /// Unlike Screen Recording, an Accessibility grant takes effect without a relaunch.
    @discardableResult
    func requestAccessibilityTrust() -> Bool
}

public struct SystemScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    public init() {}

    public func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityTrust() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt — the SDK global is a mutable `var` and
        // Swift 6 strict concurrency refuses to read it from a nonisolated context.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

// MARK: - Capture value types

/// A value-type snapshot of one shareable window. The backend hands these out instead of live
/// `SCWindow` references because `SCWindow` is not `Sendable`; the capture call re-resolves the
/// live window by `windowID`.
public struct ScreenCaptureWindowInfo: Equatable, Sendable {
    public var windowID: UInt32
    public var bundleIdentifier: String?
    public var frame: CGRect
    public var title: String?

    public init(windowID: UInt32, bundleIdentifier: String?, frame: CGRect, title: String?) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
        self.title = title
    }
}

/// Raw pixels from the backend, before the service attaches target identity.
public struct ScreenCaptureBackendImage: Equatable, Sendable {
    public var pngData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One captured window image, PNG-encoded, tagged with the target it was captured from.
public struct CapturedWindowImage: Equatable, Sendable {
    public var pngData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var bundleIdentifier: String
    public var windowTitle: String?
    /// The captured window's identifier, and its frame in global (top-left origin) points **at the
    /// moment of capture**.
    ///
    /// Added by row I, and only row I reads them: an acting loop has to translate a point the model
    /// picked *in the image* back to a point on the screen, and it cannot do that from pixel
    /// dimensions alone. `windowID` is what lets the loop re-read the frame immediately before it
    /// synthesizes anything — the frame here is already stale by the time a model has answered, and
    /// clicking through a stale frame is how a click lands somewhere nobody chose.
    ///
    /// Non-defaulted in the initializer on purpose. Both are only meaningful for a real capture of a
    /// real window, and a defaulted `.zero` frame would be a plausible-looking value that silently
    /// maps every image point onto the top-left corner of the screen.
    public var windowID: UInt32
    public var windowFrame: CGRect

    public init(
        pngData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        bundleIdentifier: String,
        windowTitle: String?,
        windowID: UInt32,
        windowFrame: CGRect
    ) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.windowFrame = windowFrame
    }
}

// MARK: - Backend seam

/// The OS-facing half of screen capture. Split from the service so window *selection* — the part
/// that has a correctness discipline attached — is pure logic under test, while this protocol's
/// conformers only enumerate and rasterize.
public protocol ScreenCaptureBackend: Sendable {
    /// All on-screen, layer-0 shareable windows. Order is NOT meaningful — ScreenCaptureKit
    /// documents no ordering for `SCShareableContent.windows`, which is exactly why
    /// `frontToBackLayerZeroWindowIDs()` exists as a separate input.
    func shareableLayerZeroWindows() async throws -> [ScreenCaptureWindowInfo]

    /// Window IDs front-to-back (the CoreGraphics window-list discipline). The z-order truth the
    /// selection must follow. Empty when the OS list is unavailable.
    func frontToBackLayerZeroWindowIDs() async -> [UInt32]

    func captureImage(of window: ScreenCaptureWindowInfo) async throws -> ScreenCaptureBackendImage
}

// MARK: - Errors

public enum ScreenCaptureServiceError: Error, Equatable, LocalizedError {
    case screenRecordingNotGranted
    case accessibilityNotGranted
    case targetWindowNotFound(bundleIdentifier: String)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingNotGranted:
            return "Screen Recording is not granted. Enable Sonny in System Settings › Privacy & Security › Screen Recording, then relaunch Sonny — the grant only takes effect after a relaunch."
        case .accessibilityNotGranted:
            return "Accessibility is not granted. Enable Sonny in System Settings › Privacy & Security › Accessibility so Sonny can control apps you allow."
        case .targetWindowNotFound(let bundleIdentifier):
            return "No on-screen window was found for \(bundleIdentifier). Make sure the app is open with a visible window, then try again."
        case .captureFailed(let reason):
            return "Sonny could not capture the window: \(reason)"
        }
    }
}

// MARK: - Service

/// Captures the true-frontmost layer-0 window of a target app, identified by bundle id.
///
/// The selection discipline this type exists to enforce: candidates come from ScreenCaptureKit
/// (filtered to the target's layer-0, on-screen, non-trivially-sized windows), but the *choice*
/// among them follows the CoreGraphics front-to-back window list — the first candidate in that
/// z-order is the window the user is actually looking at. A dialog sitting over the app's main
/// window IS the frontmost layer-0 window and is what gets captured; picking
/// `SCShareableContent.windows.first` instead silently captures the occluded main window, the
/// class of bug the SONNY-69 spike hit live.
public struct ScreenCaptureService: Sendable {
    /// Windows below this edge length are tooltips, status items, and other helper chrome —
    /// never the window a user means by "the app". Same floor the spike validated live.
    public static let minimumWindowEdge: CGFloat = 80

    private let permissionChecker: any ScreenCapturePermissionChecking
    private let backend: any ScreenCaptureBackend

    public init(
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker(),
        backend: any ScreenCaptureBackend = ScreenCaptureKitBackend()
    ) {
        self.permissionChecker = permissionChecker
        self.backend = backend
    }

    /// Throws the instructive Screen Recording error when the grant is missing.
    public func preflightScreenRecording() throws {
        guard permissionChecker.hasScreenRecordingPermission() else {
            throw ScreenCaptureServiceError.screenRecordingNotGranted
        }
    }

    /// Throws the instructive Accessibility error when the process is untrusted. Capture itself
    /// never needs this — it exists for callers (row I's acting loop) that will drive UI.
    public func preflightAccessibilityControl() throws {
        guard permissionChecker.isAccessibilityTrusted() else {
            throw ScreenCaptureServiceError.accessibilityNotGranted
        }
    }

    public func captureFrontmostWindow(ofBundleIdentifier bundleIdentifier: String) async throws -> CapturedWindowImage {
        try preflightScreenRecording()

        let candidates = try await backend.shareableLayerZeroWindows().filter { window in
            window.bundleIdentifier == bundleIdentifier
                && window.frame.width >= Self.minimumWindowEdge
                && window.frame.height >= Self.minimumWindowEdge
        }
        guard !candidates.isEmpty else {
            throw ScreenCaptureServiceError.targetWindowNotFound(bundleIdentifier: bundleIdentifier)
        }

        let frontToBack = await backend.frontToBackLayerZeroWindowIDs()
        let chosen = frontToBack.lazy
            .compactMap { id in candidates.first { $0.windowID == id } }
            .first
            // Z-order unavailable (or lists none of the candidates): largest area is the best
            // remaining guess at "the window the user means".
            ?? candidates.max { first, second in
                first.frame.width * first.frame.height < second.frame.width * second.frame.height
            }!

        let image = try await backend.captureImage(of: chosen)
        return CapturedWindowImage(
            pngData: image.pngData,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            bundleIdentifier: bundleIdentifier,
            windowTitle: chosen.title,
            windowID: chosen.windowID,
            windowFrame: chosen.frame
        )
    }
}

// MARK: - Live backend

public struct ScreenCaptureKitBackend: ScreenCaptureBackend {
    public init() {}

    public func shareableLayerZeroWindows() async throws -> [ScreenCaptureWindowInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureServiceError.captureFailed(error.localizedDescription)
        }
        return content.windows
            .filter { $0.windowLayer == 0 && $0.isOnScreen }
            .map { window in
                ScreenCaptureWindowInfo(
                    windowID: window.windowID,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    frame: window.frame,
                    title: window.title
                )
            }
    }

    public func frontToBackLayerZeroWindowIDs() async -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = info[kCGWindowNumber as String] as? Int else {
                return nil
            }
            return UInt32(number)
        }
    }

    public func captureImage(of window: ScreenCaptureWindowInfo) async throws -> ScreenCaptureBackendImage {
        // Re-resolve the live SCWindow by ID at capture time — the enumeration hands out value
        // types (SCWindow is not Sendable), and a window that closed in between fails cleanly
        // here rather than capturing something stale.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureServiceError.captureFailed(error.localizedDescription)
        }
        guard let scWindow = content.windows.first(where: { $0.windowID == window.windowID }) else {
            throw ScreenCaptureServiceError.captureFailed("the target window is no longer on screen")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(scWindow.frame.width)
        configuration.height = Int(scWindow.frame.height)
        configuration.showsCursor = false
        // Point resolution, not Retina 2x — half the pixel count per axis for a payload that
        // ultimately leaves the device, with no loss the consumers care about.
        configuration.captureResolution = .nominal

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ScreenCaptureServiceError.captureFailed(error.localizedDescription)
        }
        guard let pngData = Self.pngData(from: image) else {
            throw ScreenCaptureServiceError.captureFailed("the captured window could not be encoded as PNG")
        }
        return ScreenCaptureBackendImage(pngData: pngData, pixelWidth: image.width, pixelHeight: image.height)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
