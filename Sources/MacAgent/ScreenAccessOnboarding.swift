import AppKit
import MacAgentCore
import SwiftUI

// MARK: - Relaunch seam

/// Why a relaunch did not happen.
///
/// Read as a failure to report and never rendered: the user is told the restart did not happen,
/// not why (SONNY-348, founder decision 2026-08-30).
enum AppRelaunchFailure: Error, Equatable {
    /// `/usr/bin/open` ran and refused to reopen the bundle — it moved, is quarantined, is
    /// unreadable, or the launch was refused.
    case reopenRefused(status: Int32)
}

protocol AppRelaunching {
    /// Reopens the bundle and terminates this process, in that order.
    ///
    /// **Throwing means the app is still running**, which is the whole contract: a reopen that
    /// worked ends in `NSApp.terminate`, so the only thing a caller can be told here is that the
    /// new instance never started — and that it must act on rather than discard.
    @MainActor
    func relaunch() async throws
}

struct DefaultAppRelauncher: AppRelaunching {
    /// The bundle to reopen, and what reopening and terminating actually do.
    ///
    /// **Injected rather than reached for** (SONNY-379). `Bundle.main`, `/usr/bin/open` and
    /// `NSApp.terminate` are all process-wide, so a `relaunch()` naming them inline could not be
    /// driven in a test process at all: reaching it ended the test run rather than failing it, and
    /// every decision this type makes was therefore held by a source scan reading this file's text.
    /// With the three collaborators handed in, those decisions are behaviour again.
    private let bundleURL: URL
    private let reopen: @MainActor (URL) async throws -> Int32
    private let terminate: @MainActor () -> Void

    /// **No parameter has a default, deliberately** — SONNY-240's family, whose rule is that
    /// anything a fixture could accidentally point at the real machine is a required parameter.
    /// A defaulted `terminate` is the sharpest case this repository has: a test that omitted it
    /// would end its own process rather than fail, which is the failure this seam exists to remove.
    /// `forTheRunningApp()` is where the real collaborators are named, in words a reader and a
    /// source scan can both see.
    init(
        bundleURL: URL,
        reopen: @escaping @MainActor (URL) async throws -> Int32,
        terminate: @escaping @MainActor () -> Void
    ) {
        self.bundleURL = bundleURL
        self.reopen = reopen
        self.terminate = terminate
    }

    /// The wiring the shipping app runs, and the only place in the product that names it.
    ///
    /// **Scan-held rather than behavioural, and it cannot be anything else**: a test that ran this
    /// reopen would start a second Sonny, and one that ran this terminate would end the test
    /// process. `-n` forces a *new* instance, which is the entire point of the flag on a TCC
    /// relaunch — reusing the running one would hand the user back the same process with the same
    /// grant still denied.
    static func forTheRunningApp() -> DefaultAppRelauncher {
        DefaultAppRelauncher(
            bundleURL: Bundle.main.bundleURL,
            reopen: { bundleURL in
                try await AsyncProcessRunner.run(
                    executablePath: "/usr/bin/open",
                    arguments: ["-n", bundleURL.path]
                ).terminationStatus
            },
            terminate: { NSApp.terminate(nil) }
        )
    }

    /// Screen Recording grants only take effect in a fresh process, so this reopens the bundle and
    /// terminates this one. Only meaningful for the packaged `.app` — a bare `swift run` binary has
    /// no bundle to reopen (and no TCC identity to relaunch for), so there it just terminates.
    ///
    /// **The terminate is downstream of the reopen, and both of the reopen's failures are read**
    /// (SONNY-348). This used to launch with `try? process.run()` and terminate unconditionally, so
    /// an `open` that could not start the new instance left the user with no Sonny at all — on the
    /// first-run path, on a Mac where they had just granted a screen-recording permission to it.
    /// **The discarded `try?` was the smaller half of that**, and reading it alone would have fixed
    /// the least likely case: `Process.run()` fails only when `/usr/bin/open` itself cannot be
    /// spawned, while every failure the ticket was filed about — a bundle that moved, is
    /// quarantined, or is refused — is `open` starting fine and *exiting non-zero*, which the old
    /// code could not have seen at all. So the exit status is what decides, and `AsyncProcessRunner`
    /// is what waits for it: `open` can sit on a Gatekeeper dialog for as long as the user leaves it
    /// there, and this runs on the main actor.
    @MainActor
    func relaunch() async throws {
        if bundleURL.pathExtension == "app" {
            let status = try await reopen(bundleURL)
            guard status == 0 else {
                throw AppRelaunchFailure.reopenRefused(status: status)
            }
        }
        terminate()
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
    /// Set when the last relaunch could not start a new instance, so this app is still the only
    /// Sonny there is and the guidance has to say so. Cleared when another attempt begins.
    @Published private(set) var relaunchFailed = false
    /// True while a reopen is in flight, which is a window this branch created and the app did not
    /// have before (SONNY-348, PR #180's review, F7). The old relaunch reached `NSApp.terminate`
    /// synchronously, so there was no second press to make; now the button stays live for as long
    /// as `/usr/bin/open` takes, and `-n` forces a *new* instance by design — so two presses are two
    /// Sonnys sharing one Keychain, one set of encrypted stores and one menu bar, which
    /// `WORKFLOW.md` names as a state to avoid. It also gives the button a pending state for the
    /// case the async seam exists for, where `open` can sit on a Gatekeeper dialog indefinitely.
    @Published private(set) var isRelaunching = false

    private let permissionChecker: any ScreenCapturePermissionChecking
    private let relauncher: any AppRelaunching
    private let settingsOpener: (URL) -> Void

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    init(
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker(),
        relauncher: any AppRelaunching = DefaultAppRelauncher.forTheRunningApp(),
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

    /// **Nothing here decides that the relaunch worked** — it decides only that it did not.
    /// A reopen that succeeded ends in `NSApp.terminate`, which need not return before the process
    /// goes, so the flag is left where it was cleared and the guidance stays silent. A throw is the
    /// one thing that means the user is still looking at this app.
    func relaunchNow() async {
        guard !isRelaunching else { return }
        isRelaunching = true
        defer { isRelaunching = false }
        relaunchFailed = false
        do {
            try await relauncher.relaunch()
        } catch {
            relaunchFailed = true
        }
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
                Task { await model.relaunchNow() }
            } label: {
                Label("Relaunch Sonny", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(SonnyButtonStyle(tone: .secondary))
            .disabled(model.isRelaunching)
            .accessibilityLabel("Relaunch Sonny")

            if model.relaunchFailed {
                Text("Couldn't restart Sonny.")
                    .font(SonnyType.caption)
                    .foregroundStyle(SonnyTheme.warning)
            }
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
