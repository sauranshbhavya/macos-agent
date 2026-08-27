import Foundation
import Testing
@testable import MacAgent

/// The approval panel while a screen-control session is live (SONNY-255).
///
/// `VisionSessionRunTests` holds the half a runtime assertion can reach — that the widget resolves
/// to `.permission` rather than `.controlling` while a mid-loop question is parked, that the HUD
/// comes back when it is answered, and that the panel's Stop really ends the session. What it cannot
/// reach is what the panel *draws*: this repository has no SwiftUI inspection harness and no way to
/// drive the live app, so the panel's shape is pinned the way every other panel's is, by scanning
/// the source with comments stripped (`MacAgentSource.read`).
///
/// **The property these exist for is that there is exactly one way to refuse.** Reordering the
/// precedence took the HUD off screen while the question is up, and the HUD is where Stop lived —
/// the emergency control for a program moving the user's cursor. Putting Stop in this panel is the
/// half that keeps that reachable; taking the cross out is the half that stops the panel offering
/// two controls with one effect, on the one surface in the app where an ambiguous refusal is most
/// expensive. Either half alone is wrong, so both are held here.
@MainActor
struct WidgetSessionApprovalPanelTests {
    /// The panel's own region, from its declaration to the type that follows it.
    private func permissionPanel() throws -> String {
        try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "private struct WidgetPermissionPanel: View {",
            to: "private struct WidgetCaptureReviewPanel: View {"
        )
    }

    /// **The session's own two elements reach this panel, and they are the shared ones.**
    ///
    /// Not a second hand-written "Sonny is controlling …" and not a second Stop button: both are the
    /// components the HUD uses, so the sentence, the colour and the VoiceOver name cannot come to
    /// differ between the two panels that describe one session. The `sessionProgress` binding is
    /// what makes them conditional, and it is declared here so the panel cannot render them for an
    /// ordinary approval.
    @Test
    func theApprovalPanelCarriesTheSessionsIdentityLineAndItsStopWhileASessionIsLive() throws {
        let panel = try permissionPanel()

        #expect(MacAgentSource.count(of: "let sessionProgress: VisionSessionProgress?", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "let onStop: () -> Void", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "if let sessionProgress {", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "WidgetSessionIdentityLine(appDisplayName:", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "WidgetSessionStopButton(", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "action: onStop", inText: panel) == 1)

        // The step count comes off the session, through the owner both surfaces read rather than a
        // sentence of this panel's own (PR #132 review, F1 moved the words there).
        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stepLine(", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "iteration: sessionProgress.iteration", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "maximumIterations: sessionProgress.maximumIterations", inText: panel) == 1)

        // The action line deliberately does not come across at all — at the moment an approval is
        // raised it still holds what the iteration reported when it began, so it would be stale
        // beside an accurate sentence about the same moment.
        #expect(MacAgentSource.count(of: "currentAction", inText: panel) == 0)
    }

    /// **The ordinary approval keeps its step rows, and the session row replaces them rather than
    /// joining them** (PR #132 review, F3).
    ///
    /// The `else` arm had no assertion in either direction, so a mutant deleting it survived: the
    /// panel for an ordinary tier-2 approval would have lost its plan rows and every test still
    /// passed. Both directions are held here because the pair is the decision — one row about the
    /// session *instead of* rows about a plan whose single step is "control this app", not two rows
    /// saying the same thing on a 472pt panel.
    @Test
    func theOrdinaryApprovalKeepsItsStepRowsAndTheSessionRowReplacesThem() throws {
        let panel = try permissionPanel()

        // The `else` arm exists and renders the rows, with the plan and statuses it was handed.
        #expect(
            MacAgentSource.count(
                of: "WidgetExistingStepRows(plan: plan, stepStatuses: stepStatuses)",
                inText: panel
            ) == 1
        )

        // And it is only in the `else` arm: the session branch must not render them too.
        let sessionArm = try MacAgentSource.braceBlock(of: panel, openedBy: "if let sessionProgress {")
        #expect(MacAgentSource.count(of: "WidgetExistingStepRows", inText: sessionArm) == 0)
        #expect(MacAgentSource.count(of: "WidgetSessionIdentityLine(", inText: sessionArm) == 1)
    }

    /// **One refusal, and it is the one that says what it does.**
    ///
    /// Counted on both sides rather than checked for presence, for the reason `MacAgentSource`'s own
    /// doc gives: a trailing comment can add a token but cannot subtract one, so a rewiring that
    /// moves the cross's action shows up as a count that went *up* on the side that gained. The
    /// cross is still declared and still wired to `onDeny` — outside a session it is the panel's
    /// only way to say no — and it is gated so it cannot appear beside the Stop.
    @Test
    func theCrossIsTheRefusalOutsideASessionAndTheStopIsTheRefusalInsideOne() throws {
        let panel = try permissionPanel()

        #expect(MacAgentSource.count(of: "let onDeny: () -> Void", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(action: onDeny)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(action: onAllow)", inText: panel) == 1)
        // The gate, and its shape: the cross renders only when there is no session under the
        // question. `sessionProgress == nil` appearing once is what stops the two refusals coexisting.
        #expect(MacAgentSource.count(of: "if sessionProgress == nil {", inText: panel) == 1)
    }

    /// **The call sites, which the panel's own region cannot see.**
    ///
    /// A panel declaring `sessionProgress` and an `onStop` proves nothing if the view hands it `nil`
    /// and an empty closure. The routing switch is where the session actually reaches it, and where
    /// the Stop is wired to the same entry point the HUD's own Stop uses — `emergencyStopVisionSession`,
    /// which logs the press and routes into `cancelCurrentRun`, rather than a second stop path.
    @Test
    func theWidgetHandsTheApprovalPanelTheLiveSessionAndTheSameStopTheHudUses() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let routing = try MacAgentSource.region(
            of: widget,
            from: "case .permission(let request):",
            to: "case .captureReview(let preview):"
        )

        #expect(MacAgentSource.count(of: "sessionProgress: viewModel.visionSessionProgress", inText: routing) == 1)
        #expect(MacAgentSource.count(of: "onStop: { viewModel.emergencyStopVisionSession() }", inText: routing) == 1)
        #expect(MacAgentSource.count(of: "onDeny: { viewModel.cancelCurrentRun() }", inText: routing) == 1)

        // And the HUD's Stop is the same component with the same call, so "one stop control" is a
        // property of the file rather than a claim about it. Two call sites, one per panel — the
        // declarations carry no open paren, so they are not in these counts.
        #expect(MacAgentSource.count(of: "WidgetSessionStopButton(", inText: widget) == 2, "one call site per panel")
        #expect(MacAgentSource.count(of: "WidgetSessionIdentityLine(", inText: widget) == 2, "one call site per panel")
        #expect(MacAgentSource.count(of: "private struct WidgetSessionStopButton: View {", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "private struct WidgetSessionIdentityLine: View {", inText: widget) == 1)
    }

    /// **Nothing this panel gained explains how Sonny works**, per the founder's standing rule of
    /// 2026-08-14. The identity line states what is happening and the Stop is a control; neither
    /// teaches the feature, and the HUD's one teaching sentence — the hotkey reminder — deliberately
    /// did not come across.
    ///
    /// The hotkey line earns its place in the HUD because during a live session the pointer is not
    /// the user's to aim, so the keyboard is the input path that reliably is. While an approval is
    /// parked that premise is false: the loop is frozen on a continuation, nothing is moving the
    /// cursor, and the Stop is a click away.
    @Test
    func theApprovalPanelTeachesNothingAndDoesNotRepeatTheHotkeyLine() throws {
        let panel = try permissionPanel()

        #expect(MacAgentSource.count(of: "EmergencyStopHotKey.displayName", inText: panel) == 0)
        #expect(MacAgentSource.count(of: "stops it from anywhere", inText: panel) == 0)
        // The HUD still says it, so this is an absence here rather than a deletion there.
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(MacAgentSource.count(of: "stops it from anywhere", inText: widget) == 1)
    }

    // MARK: - The same argument on Command Center's surface (PR #132 review, F1)

    /// **Command Center's approval panel got the identical treatment, one round later.**
    ///
    /// SONNY-255 hid the widget's icon-only cross while a session is live, because `cancelCurrentRun`
    /// ends the whole session rather than declining a step. `CommandCenterAttentionPanel` kept a
    /// button *labelled* "Deny" wired to the same call — the same claim in words, and worse for being
    /// legible. The behaviour is unchanged on both surfaces; what changed is that the label stops
    /// disagreeing with it.
    ///
    /// Counted on both sides, which is what a scan can honestly hold here: the "Deny" button still
    /// exists for an ordinary approval and the Stop exists only for a session, so a mutant collapsing
    /// the branch moves a count rather than merely adding a token a comment could have supplied.
    @Test
    func commandCentersApprovalPanelOffersStopRatherThanDenyWhileASessionIsLive() throws {
        let panel = try MacAgentSource.region(
            of: MacAgentSource.read("CommandCenterView.swift"),
            from: "private func permissionContent(_ request: RiskApprovalRequest) -> some View {",
            to: "private func clarificationContent(_ question: String) -> some View {"
        )

        // The branch, and one control on each side of it.
        #expect(MacAgentSource.count(of: "if viewModel.visionSessionProgress != nil {", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(ScreenControlSessionPresentation.stopLabel)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.emergencyStopVisionSession()", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(\"Deny\")", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.cancelCurrentRun()", inText: panel) == 1)
        // Allow is one control in both cases and is outside the branch entirely.
        #expect(MacAgentSource.count(of: "Button(\"Allow\")", inText: panel) == 1)

        // System A's own destructive treatment, not the widget's red — the two surfaces have
        // separate token sets and `.claude/rules/macagent-ui-conventions.md` forbids mixing them.
        #expect(MacAgentSource.count(of: "CommandCenterRowActionStyle(tone: .danger)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "WidgetTheme", inText: panel) == 0)
        #expect(MacAgentSource.count(of: "WidgetType", inText: panel) == 0)

        // And the session's context row, so the question is anchored to the session on this surface
        // too rather than arriving with a Stop and no statement of what it stops.
        #expect(MacAgentSource.count(of: "if let sessionProgress = viewModel.visionSessionProgress {", inText: panel) == 1)
        #expect(
            MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.controllingPrefix)", inText: panel) == 1
        )
        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stepLine(", inText: panel) == 1)
    }

    /// **The words are shared between the surfaces; the views are not, and that is the whole design
    /// of `ScreenControlSessionPresentation`.**
    ///
    /// A user who reads "Sonny is controlling Safari" in the widget and something else in Command
    /// Center is looking at one session described two ways, and nothing in either file would catch
    /// the divergence — the two are 4,000 lines apart in different token systems. So the strings have
    /// one owner and each surface renders them with its own tokens. Asserted as the population:
    /// neither file may carry a hand-written copy of any of the three.
    @Test
    func bothSurfacesReadTheSessionsWordsFromOneOwnerAndNeitherHandWritesThem() throws {
        #expect(ScreenControlSessionPresentation.controllingMessage(appDisplayName: "Safari")
            == "Sonny is controlling Safari")
        #expect(ScreenControlSessionPresentation.stepLine(iteration: 2, maximumIterations: 4) == "Step 2 of 4")
        #expect(ScreenControlSessionPresentation.stopLabel == "Stop")
        #expect(ScreenControlSessionPresentation.stopAccessibilityLabel(appDisplayName: "Safari")
            == "Stop Sonny controlling Safari")
        #expect(ScreenControlSessionPresentation.pauseAccessibilityLabel(appDisplayName: "Safari")
            == "Pause Sonny controlling Safari")

        for file in ["FloatingWidgetView.swift", "CommandCenterView.swift"] {
            let source = try MacAgentSource.read(file)
            #expect(MacAgentSource.count(of: "\"Sonny is controlling ", inText: source) == 0, "\(file)")
            #expect(MacAgentSource.count(of: "\"Stop Sonny controlling ", inText: source) == 0, "\(file)")
            #expect(MacAgentSource.count(of: "\"Pause Sonny controlling ", inText: source) == 0, "\(file)")
        }

        // **One hand-written step line survives, and it is a filed defect rather than an exemption**
        // (SONNY-303, found by this scan). `WidgetCaptureReviewPanel` renders
        // `"Step \(preview.iteration) of \(preview.appDisplayName)"` — the app's *name* where the
        // iteration cap belongs, so Safe mode's pre-send review reads "Step 2 of Safari".
        // `VisionCapturePreview` carries no `maximumIterations`, which is why it is a type change and
        // a product decision rather than a typo, and why it is not fixed here. Pinned at exactly one
        // so a second hand-written step line fails this, and so the count drops to zero the moment
        // SONNY-303 lands rather than sitting here as a permanent allowance.
        #expect(
            MacAgentSource.count(of: "\"Step \\(", inText: try MacAgentSource.read("FloatingWidgetView.swift")) == 1,
            "the one known hand-written step line is SONNY-303's; a second one is new"
        )
        #expect(MacAgentSource.count(of: "\"Step \\(", inText: try MacAgentSource.read("CommandCenterView.swift")) == 0)
    }

    /// **Pause does not travel with the Stop, and that is a decision rather than an omission.**
    ///
    /// `pauseVisionSession` sets the attention monitor's flag, which the loop reads at the top of its
    /// *next* iteration — so pressed while an approval is parked it freezes nothing, because the loop
    /// is already frozen on the continuation, and it would take effect only after the user answered
    /// the question. A control that appears inert and then acts later is worse than one that is not
    /// there. It stays in the HUD, where the loop is running and it does what it says.
    @Test
    func pauseStaysInTheHudAndIsNotOfferedBesideAParkedQuestion() throws {
        let panel = try permissionPanel()
        #expect(MacAgentSource.count(of: "onPause", inText: panel) == 0)
        #expect(MacAgentSource.count(of: "Pause", inText: panel) == 0)

        let hud = try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "private struct WidgetControllingPanel: View {",
            to: "private struct WidgetClarificationPanel: View {"
        )
        #expect(MacAgentSource.count(of: "Button(action: onPause)", inText: hud) == 1)
        #expect(MacAgentSource.count(of: "WidgetSessionStopButton(", inText: hud) == 1)
    }
}
