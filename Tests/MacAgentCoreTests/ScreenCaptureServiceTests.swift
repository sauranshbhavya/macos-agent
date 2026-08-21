import CoreGraphics
import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgentCore

private final class FakeScreenCaptureBackend: ScreenCaptureBackend, @unchecked Sendable {
    var windows: [ScreenCaptureWindowInfo]
    var frontToBackIDs: [UInt32]
    var imageByWindowID: [UInt32: ScreenCaptureBackendImage]
    private(set) var enumerationCount = 0
    private(set) var capturedWindowIDs: [UInt32] = []

    init(
        windows: [ScreenCaptureWindowInfo],
        frontToBackIDs: [UInt32],
        imageByWindowID: [UInt32: ScreenCaptureBackendImage] = [:]
    ) {
        self.windows = windows
        self.frontToBackIDs = frontToBackIDs
        self.imageByWindowID = imageByWindowID
    }

    func shareableLayerZeroWindows() async throws -> [ScreenCaptureWindowInfo] {
        enumerationCount += 1
        return windows
    }

    func frontToBackLayerZeroWindowIDs() async -> [UInt32] {
        frontToBackIDs
    }

    func captureImage(of window: ScreenCaptureWindowInfo) async throws -> ScreenCaptureBackendImage {
        capturedWindowIDs.append(window.windowID)
        guard let image = imageByWindowID[window.windowID] else {
            throw ScreenCaptureServiceError.captureFailed("no fixture image for window \(window.windowID)")
        }
        return image
    }
}

private func window(
    id: UInt32,
    bundleID: String?,
    width: CGFloat = 800,
    height: CGFloat = 600,
    title: String? = nil
) -> ScreenCaptureWindowInfo {
    ScreenCaptureWindowInfo(
        windowID: id,
        bundleIdentifier: bundleID,
        frame: CGRect(x: 0, y: 0, width: width, height: height),
        title: title
    )
}

private func image(_ marker: UInt8, width: Int = 800, height: Int = 600) -> ScreenCaptureBackendImage {
    ScreenCaptureBackendImage(pngData: Data([marker]), pixelWidth: width, pixelHeight: height)
}

struct ScreenCaptureServiceTests {
    @Test
    func captureReturnsImageDataForAResolvableTarget() async throws {
        let backend = FakeScreenCaptureBackend(
            windows: [window(id: 10, bundleID: "com.example.notes", title: "Meeting notes")],
            frontToBackIDs: [10],
            imageByWindowID: [10: image(7, width: 800, height: 600)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(captured.pngData == Data([7]))
        #expect(captured.pixelWidth == 800)
        #expect(captured.pixelHeight == 600)
        #expect(captured.bundleIdentifier == "com.example.notes")
        #expect(captured.windowTitle == "Meeting notes")
    }

    @Test
    func missingScreenRecordingGrantThrowsBeforeTouchingTheBackend() async throws {
        let backend = FakeScreenCaptureBackend(
            windows: [window(id: 10, bundleID: "com.example.notes")],
            frontToBackIDs: [10],
            imageByWindowID: [10: image(1)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: false),
            backend: backend
        )

        await #expect(throws: ScreenCaptureServiceError.screenRecordingNotGranted) {
            try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")
        }
        #expect(backend.enumerationCount == 0)
        #expect(backend.capturedWindowIDs.isEmpty)
    }

    @Test
    func targetWithNoOnScreenWindowFailsCleanlyNamingTheTarget() async throws {
        let backend = FakeScreenCaptureBackend(
            windows: [window(id: 10, bundleID: "com.other.app")],
            frontToBackIDs: [10]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        await #expect(throws: ScreenCaptureServiceError.targetWindowNotFound(bundleIdentifier: "com.example.notes")) {
            try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")
        }
        #expect(backend.capturedWindowIDs.isEmpty)
    }

    @Test
    func aDialogOverTheMainWindowIsWhatGetsCaptured() async throws {
        // The z-order discipline this service exists for: ScreenCaptureKit's enumeration order
        // is undocumented and lists the big main window first here, but the CG front-to-back
        // list says the small save dialog is what the user is actually looking at.
        let mainWindow = window(id: 10, bundleID: "com.example.notes", width: 1400, height: 900, title: "Main")
        let dialog = window(id: 11, bundleID: "com.example.notes", width: 420, height: 260, title: "Save As")
        let backend = FakeScreenCaptureBackend(
            windows: [mainWindow, dialog],
            frontToBackIDs: [11, 10],
            imageByWindowID: [10: image(1), 11: image(2, width: 420, height: 260)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(backend.capturedWindowIDs == [11])
        #expect(captured.pngData == Data([2]))
        #expect(captured.windowTitle == "Save As")
    }

    @Test
    func anotherAppsWindowInFrontDoesNotHijackTheCapture() async throws {
        // A different app's window being globally frontmost must not matter — the z-order is
        // only consulted to order the *target's own* candidates.
        let otherApp = window(id: 20, bundleID: "com.other.app", title: "Other")
        let target = window(id: 10, bundleID: "com.example.notes", title: "Main")
        let backend = FakeScreenCaptureBackend(
            windows: [otherApp, target],
            frontToBackIDs: [20, 10],
            imageByWindowID: [10: image(1), 20: image(9)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(backend.capturedWindowIDs == [10])
        #expect(captured.pngData == Data([1]))
    }

    @Test
    func helperChromeBelowTheSizeFloorIsNeverACandidate() async throws {
        // A tooltip-sized window can sit frontmost in z-order; the capture must skip it and
        // take the real window behind it.
        let tooltip = window(id: 12, bundleID: "com.example.notes", width: 60, height: 24, title: "Tooltip")
        let mainWindow = window(id: 10, bundleID: "com.example.notes", width: 1200, height: 800, title: "Main")
        let backend = FakeScreenCaptureBackend(
            windows: [tooltip, mainWindow],
            frontToBackIDs: [12, 10],
            imageByWindowID: [10: image(1), 12: image(9)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(backend.capturedWindowIDs == [10])
        #expect(captured.pngData == Data([1]))
    }

    @Test
    func onlyHelperChromeOnScreenFailsAsTargetNotFound() async throws {
        let tooltip = window(id: 12, bundleID: "com.example.notes", width: 60, height: 24)
        let backend = FakeScreenCaptureBackend(windows: [tooltip], frontToBackIDs: [12])
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        await #expect(throws: ScreenCaptureServiceError.targetWindowNotFound(bundleIdentifier: "com.example.notes")) {
            try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")
        }
    }

    @Test
    func unavailableZOrderFallsBackToTheLargestCandidate() async throws {
        let small = window(id: 11, bundleID: "com.example.notes", width: 400, height: 300)
        let large = window(id: 10, bundleID: "com.example.notes", width: 1400, height: 900)
        let backend = FakeScreenCaptureBackend(
            windows: [small, large],
            frontToBackIDs: [],
            imageByWindowID: [10: image(1), 11: image(2)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(backend.capturedWindowIDs == [10])
        #expect(captured.pngData == Data([1]))
    }

    @Test
    func zOrderListingOnlyForeignWindowsAlsoFallsBackToTheLargestCandidate() async throws {
        // The CG list can exist but name none of the target's windows (stale IDs, races);
        // that is the same "no ordering signal" situation as an empty list.
        let small = window(id: 11, bundleID: "com.example.notes", width: 400, height: 300)
        let large = window(id: 10, bundleID: "com.example.notes", width: 1400, height: 900)
        let backend = FakeScreenCaptureBackend(
            windows: [small, large],
            frontToBackIDs: [99, 98],
            imageByWindowID: [10: image(1), 11: image(2)]
        )
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: backend
        )

        let captured = try await service.captureFrontmostWindow(ofBundleIdentifier: "com.example.notes")

        #expect(backend.capturedWindowIDs == [10])
        #expect(captured.pngData == Data([1]))
    }

    @Test
    func preflightHelpersThrowTheInstructiveErrorsWhenUngranted() throws {
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: false, screenRecordingGranted: false),
            backend: FakeScreenCaptureBackend(windows: [], frontToBackIDs: [])
        )

        #expect(throws: ScreenCaptureServiceError.screenRecordingNotGranted) {
            try service.preflightScreenRecording()
        }
        #expect(throws: ScreenCaptureServiceError.accessibilityNotGranted) {
            try service.preflightAccessibilityControl()
        }
    }

    @Test
    func preflightHelpersPassWhenGranted() throws {
        let service = ScreenCaptureService(
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: true, screenRecordingGranted: true),
            backend: FakeScreenCaptureBackend(windows: [], frontToBackIDs: [])
        )

        try service.preflightScreenRecording()
        try service.preflightAccessibilityControl()
    }

    @Test
    func permissionErrorsCarryInstructiveSystemSettingsCopy() {
        let screenRecording = ScreenCaptureServiceError.screenRecordingNotGranted.errorDescription ?? ""
        #expect(screenRecording.contains("System Settings"))
        #expect(screenRecording.contains("Screen Recording"))
        #expect(screenRecording.contains("relaunch"))

        let accessibility = ScreenCaptureServiceError.accessibilityNotGranted.errorDescription ?? ""
        #expect(accessibility.contains("System Settings"))
        #expect(accessibility.contains("Accessibility"))

        let notFound = ScreenCaptureServiceError.targetWindowNotFound(bundleIdentifier: "com.example.notes").errorDescription ?? ""
        #expect(notFound.contains("com.example.notes"))
    }
}

struct PermissionReadinessScreenRowsTests {
    private func rows(screenRecording: Bool, accessibility: Bool) -> [PermissionReadinessItem] {
        // `.deterministic` rather than a bare init: it also states the microphone status, which
        // `currentStatus` reads and this file has no opinion about (SONNY-123).
        let service = PermissionReadinessService.deterministic(
            accessibilityTrusted: accessibility,
            screenRecordingGranted: screenRecording
        )
        return service.currentStatus(hasAPIKey: true, hotKeyReady: true)
    }

    private func row(_ items: [PermissionReadinessItem], id: String) throws -> PermissionReadinessItem {
        try #require(items.first { $0.id == id })
    }

    @Test
    func grantedScreenRecordingRowReadsReady() throws {
        let item = try row(rows(screenRecording: true, accessibility: false), id: "screen-recording")
        #expect(item.state == .ready)
        #expect(item.detail == "Screen Recording is granted.")
    }

    @Test
    func ungrantedScreenRecordingRowNeedsActionWithGrantAndRelaunchInstructions() throws {
        let item = try row(rows(screenRecording: false, accessibility: true), id: "screen-recording")
        #expect(item.state == .needsAction)
        #expect(item.detail.contains("System Settings"))
        #expect(item.detail.contains("relaunch"))
        #expect(!item.detail.contains("Not required yet"))
    }

    @Test
    func trustedAccessibilityRowReadsReady() throws {
        let item = try row(rows(screenRecording: false, accessibility: true), id: "accessibility")
        #expect(item.state == .ready)
        #expect(item.detail == "Accessibility is trusted for the current process.")
    }

    @Test
    func untrustedAccessibilityRowNeedsActionWithGrantInstructions() throws {
        let item = try row(rows(screenRecording: true, accessibility: false), id: "accessibility")
        #expect(item.state == .needsAction)
        #expect(item.detail.contains("System Settings"))
        #expect(!item.detail.contains("Not required yet"))
    }

    @Test
    func bothUngrantedShowsBothRowsNeedingActionAndBothGrantedShowsBothReady()  throws {
        let allNeeded = rows(screenRecording: false, accessibility: false)
        #expect(try row(allNeeded, id: "screen-recording").state == .needsAction)
        #expect(try row(allNeeded, id: "accessibility").state == .needsAction)

        let allGranted = rows(screenRecording: true, accessibility: true)
        #expect(try row(allGranted, id: "screen-recording").state == .ready)
        #expect(try row(allGranted, id: "accessibility").state == .ready)
    }
}
