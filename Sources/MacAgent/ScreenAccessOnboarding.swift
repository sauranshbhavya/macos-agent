import AppKit
import MacAgentCore
import SwiftUI

// MARK: - Relaunch seam

protocol AppRelaunching {
    @MainActor
    func relaunch()
}

struct DefaultAppRelauncher: AppRelaunching {
    /// Screen Recording grants only take effect in a fresh process, so this launches a new
    /// instance and terminates this one. Only meaningful for the packaged `.app` — a bare
    /// `swift run` binary has no bundle to reopen (and no TCC identity to relaunch for), so
    /// there it just terminates.
    @MainActor
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            try? process.run()
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Model

/// Drives the request → relaunch guidance → confirm cycle for the two System-Settings-only
/// grants (Screen Recording, Accessibility). The asymmetry this model exists to own: an
/// Accessibility grant takes effect immediately, but a Screen Recording grant is invisible to
/// the running process — `CGPreflightScreenCaptureAccess` keeps answering `false` until the app
/// relaunches, so "requested but not granted" must show relaunch guidance rather than polling
/// for a flip that can never come.
@MainActor
final class ScreenAccessOnboardingModel: ObservableObject {
    @Published private(set) var screenRecordingGranted: Bool
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var screenRecordingRequestedThisLaunch = false

    private let permissionChecker: any ScreenCapturePermissionChecking
    private let relauncher: any AppRelaunching
    private let settingsOpener: (URL) -> Void

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker(),
        relauncher: any AppRelaunching = DefaultAppRelauncher(),
        settingsOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.permissionChecker = permissionChecker
        self.relauncher = relauncher
        self.settingsOpener = settingsOpener
        self.screenRecordingGranted = permissionChecker.hasScreenRecordingPermission()
        self.accessibilityTrusted = permissionChecker.isAccessibilityTrusted()
    }

    var needsRelaunchGuidance: Bool {
        screenRecordingRequestedThisLaunch && !screenRecordingGranted
    }

    var allGranted: Bool {
        screenRecordingGranted && accessibilityTrusted
    }

    func refresh() {
        screenRecordingGranted = permissionChecker.hasScreenRecordingPermission()
        accessibilityTrusted = permissionChecker.isAccessibilityTrusted()
    }

    /// Registers Sonny in the Screen Recording list (and shows macOS's one-time dialog if it has
    /// never appeared). The grant itself happens in System Settings and takes effect only after
    /// relaunch, which is why this flips the flag that reveals the guidance step.
    func requestScreenRecording() {
        guard !screenRecordingGranted else { return }
        permissionChecker.requestScreenRecordingPermission()
        screenRecordingRequestedThisLaunch = true
        refresh()
    }

    func requestAccessibility() {
        guard !accessibilityTrusted else { return }
        permissionChecker.requestAccessibilityTrust()
        refresh()
    }

    func openScreenRecordingSettings() {
        settingsOpener(Self.screenRecordingSettingsURL)
    }

    func openAccessibilitySettings() {
        settingsOpener(Self.accessibilitySettingsURL)
    }

    func relaunchNow() {
        relauncher.relaunch()
    }
}

// MARK: - Modal

/// System A dialog on `SettingsDialogView`'s chrome pattern; opened from Settings › Security &
/// Access. Visual verification is manual, in the packaged app — TCC ignores a bare `swift run`.
struct ScreenAccessOnboardingView: View {
    @ObservedObject var model: ScreenAccessOnboardingModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(SonnyType.icon(11, weight: .semibold))
                        .foregroundStyle(SonnyTheme.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .sonnyPointerCursor()
                .sonnyHoverHighlight(cornerRadius: 12)
                .accessibilityLabel("Close Screen Access setup")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Screen access")
                            .font(SonnyType.settingsContentTitle)
                            .foregroundStyle(SonnyTheme.text)
                        Text(model.allGranted
                            ? "Sonny is set up to see your screen."
                            : "Sonny's screen-aware tools need two macOS grants. Both live in System Settings — Sonny can only take you there.")
                            .font(SonnyType.body)
                            .foregroundStyle(SonnyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 20)

                    SettingsDivider()

                    permissionBlock(
                        title: "Screen Recording",
                        granted: model.screenRecordingGranted,
                        grantedDetail: "Granted. Sonny can capture the window of an app you target.",
                        neededDetail: "Lets Sonny capture the window of an app you target, so screen-aware tools can see it. Takes effect after Sonny relaunches."
                    ) {
                        HStack(spacing: 8) {
                            Button("Request access") {
                                model.requestScreenRecording()
                            }
                            .buttonStyle(SonnyButtonStyle(tone: .primary))
                            .accessibilityLabel("Request Screen Recording access")

                            Button("Open System Settings") {
                                model.openScreenRecordingSettings()
                            }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                            .accessibilityLabel("Open Screen Recording settings")
                        }
                    }

                    if model.needsRelaunchGuidance {
                        relaunchGuidance
                    }

                    SettingsDivider()

                    permissionBlock(
                        title: "Accessibility",
                        granted: model.accessibilityTrusted,
                        grantedDetail: "Granted. Sonny can act inside apps you specifically allow.",
                        neededDetail: "Lets Sonny act inside apps you specifically allow, once screen-acting tools arrive. Takes effect immediately — no relaunch."
                    ) {
                        HStack(spacing: 8) {
                            Button("Request access") {
                                model.requestAccessibility()
                            }
                            .buttonStyle(SonnyButtonStyle(tone: .primary))
                            .accessibilityLabel("Request Accessibility access")

                            Button("Open System Settings") {
                                model.openAccessibilitySettings()
                            }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                            .accessibilityLabel("Open Accessibility settings")

                            Button {
                                model.refresh()
                            } label: {
                                Label("Check again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(SonnyButtonStyle(tone: .secondary))
                            .accessibilityLabel("Check Accessibility grant again")
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
                .padding(.bottom, 36)
            }
        }
        .frame(width: 620, height: 480)
        .background(SonnyTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.container)
                .stroke(SonnyTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: SonnyRadius.container))
        .onAppear {
            model.refresh()
        }
    }

    private var relaunchGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Two steps left")
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.warning)
            }
            Text("1. In System Settings › Privacy & Security › Screen Recording, switch Sonny on.\n2. Relaunch Sonny — macOS only applies the grant to a fresh launch, so this page can't show it as granted until then.")
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.relaunchNow()
            } label: {
                Label("Relaunch Sonny", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary))
            .accessibilityLabel("Relaunch Sonny")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .fill(SonnyTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SonnyRadius.panelCard)
                .stroke(SonnyTheme.cardBorder, lineWidth: 1)
        )
        .padding(.bottom, 20)
    }

    private func permissionBlock<Actions: View>(
        title: String,
        granted: Bool,
        grantedDetail: String,
        neededDetail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(SonnyType.caption)
                    .foregroundStyle(granted ? SonnyTheme.accent : SonnyTheme.warning)
                Text(title)
                    .font(SonnyType.bodyEmphasis)
                    .foregroundStyle(SonnyTheme.text)
                Text(granted ? "Granted" : "Not granted")
                    .font(SonnyType.micro)
                    .foregroundStyle(granted ? SonnyTheme.accent : SonnyTheme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill((granted ? SonnyTheme.accent : SonnyTheme.warning).opacity(0.14))
                    )
            }

            Text(granted ? grantedDetail : neededDetail)
                .font(SonnyType.body)
                .foregroundStyle(SonnyTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if !granted {
                actions()
            }
        }
        .padding(.vertical, 20)
    }
}
