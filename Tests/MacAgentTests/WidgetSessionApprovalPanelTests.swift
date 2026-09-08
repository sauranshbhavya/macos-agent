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

        // The branch, and one control on each side of it. `if let` rather than a `!= nil` test, so
        // the Stop's accessibility label reads the bound session rather than re-optional-chaining
        // into a fallback that can only ever be reached by a race with itself (PR #132 cycle 2's nit).
        #expect(MacAgentSource.count(of: "if let sessionProgress = viewModel.visionSessionProgress {", inText: panel) == 2)
        #expect(MacAgentSource.count(of: "?? \"\"", inText: panel) == 0)
        #expect(MacAgentSource.count(of: "Button(ScreenControlSessionPresentation.stopLabel)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.emergencyStopVisionSession()", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "Button(\"Deny\")", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "viewModel.cancelCurrentRun()", inText: panel) == 1)
        // Allow is one control in both cases and is outside the branch entirely.
        #expect(MacAgentSource.count(of: "Button(\"Allow\")", inText: panel) == 1)

        // System A's own destructive treatment, not the widget's red — the two surfaces have
        // separate token sets and `.claude/rules/macagent-ui-conventions.md` forbids mixing them.
        // The literal is the shared button system's danger tone at its small size (2026-09-08's
        // modernization retired `CommandCenterRowActionStyle` onto it); what is pinned is that the
        // Stop is the one danger-toned control on this panel.
        #expect(MacAgentSource.count(of: "SonnyButtonStyle(tone: .danger, size: .small)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "WidgetTheme", inText: panel) == 0)
        #expect(MacAgentSource.count(of: "WidgetType", inText: panel) == 0)

        // And the session's context row, so the question is anchored to the session on this surface
        // too rather than arriving with a Stop and no statement of what it stops. It is its own view
        // as of PR #132's cycle 2 (N1), so the row's own content is asserted where it now lives.
        #expect(MacAgentSource.count(of: "CommandCenterSessionContextRow(progress: sessionProgress)", inText: panel) == 1)

        let contextRow = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct CommandCenterSessionContextRow: View {"
        )
        #expect(
            MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.controllingPrefix)", inText: contextRow) == 1
        )
        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stepLine(", inText: contextRow) == 1)
        // System A here too — the row exists as its own view *because* the widget's cannot be reused.
        #expect(MacAgentSource.count(of: "WidgetTheme", inText: contextRow) == 0)
        #expect(MacAgentSource.count(of: "WidgetType", inText: contextRow) == 0)
    }

    /// **All three of a session's control labels are VoiceOver names and nothing held any of them**
    /// (PR #132 cycle 2, N3 — reviewer mutant R5 survived).
    ///
    /// Each of these buttons carries a word or a glyph that does not say *what* it acts on: "Stop"
    /// and "Pause" alone name no app, and during a screen-control session the app being controlled is
    /// the single most important fact about the control. Blanking or rewiring any of the three was
    /// invisible to the whole suite. Held in `ResumeOfferPresentationTests`' pattern — the exact call
    /// at the exact site — because that is the shape this repository already uses for a label a
    /// runtime assertion cannot reach, and because a looser check passes on a label wired to the
    /// wrong session's name.
    ///
    /// The strings themselves are asserted in
    /// `bothSurfacesReadTheSessionsWordsFromOneOwnerAndNeitherHandWritesThem`; these three say the
    /// controls actually wear them.
    @Test
    func everySessionControlWearsItsOwnAccessibilityLabel() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")

        // The Stop, shared by both widget panels — one component, so one site.
        let stop = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "private struct WidgetSessionStopButton: View {"
        )
        #expect(
            MacAgentSource.count(
                of: ".accessibilityLabel(ScreenControlSessionPresentation.stopAccessibilityLabel(appDisplayName: appDisplayName))",
                inText: stop
            ) == 1
        )

        // The HUD's Pause, which lives only on the controlling panel.
        let hud = try MacAgentSource.region(
            of: widget,
            from: "private struct WidgetControllingPanel: View {",
            to: "private struct WidgetClarificationPanel: View {"
        )
        #expect(
            MacAgentSource.count(
                of: """
                .accessibilityLabel(ScreenControlSessionPresentation.pauseAccessibilityLabel(
                                    appDisplayName: progress.appDisplayName
                                ))
                """,
                inText: hud
            ) == 1
        )

        // And Command Center's Stop, whose label is the one the nit above rebound.
        let commandCenter = try MacAgentSource.region(
            of: MacAgentSource.read("CommandCenterView.swift"),
            from: "private func permissionContent(_ request: RiskApprovalRequest) -> some View {",
            to: "private func clarificationContent(_ question: String) -> some View {"
        )
        #expect(MacAgentSource.count(of: ".accessibilityLabel(ScreenControlSessionPresentation.stopAccessibilityLabel(", inText: commandCenter) == 1)
        #expect(MacAgentSource.count(of: "appDisplayName: sessionProgress.appDisplayName", inText: commandCenter) == 1)

        // And no fourth site anywhere hand-writing one of these two sentences, so a new session
        // control cannot arrive with a label of its own that drifts from the owner's. Matched on
        // "Stop Sonny"/"Pause Sonny" rather than on "Stop"/"Pause": Command Center carries an
        // unrelated `.accessibilityLabel("Paused — needs your attention")` on a routine's badge,
        // which is not this sentence and must not be swept up by a check for this one.
        for file in ["FloatingWidgetView.swift", "CommandCenterView.swift"] {
            let source = try MacAgentSource.read(file)
            #expect(MacAgentSource.count(of: ".accessibilityLabel(\"Stop Sonny", inText: source) == 0, "\(file)")
            #expect(MacAgentSource.count(of: ".accessibilityLabel(\"Pause Sonny", inText: source) == 0, "\(file)")
        }
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

        // **No hand-written step line anywhere on either surface, and this used to say "exactly
        // one".** The one was `WidgetCaptureReviewPanel`'s, which interpolated the app's *name*
        // where the iteration cap belongs and so read "Step 2 of Safari" in Safe mode's pre-send
        // review. It was pinned at one rather than exempted precisely so that the count would drop
        // to zero when the type change landed rather than sitting here as a permanent allowance;
        // it landed, `VisionCapturePreview` carries `maximumIterations`, and the panel reads the
        // owner's sentence like its three neighbours. The population is the whole of both files, so
        // a fourth panel inventing its own step line fails this rather than shipping.
        for file in ["FloatingWidgetView.swift", "CommandCenterView.swift"] {
            let source = try MacAgentSource.read(file)
            #expect(MacAgentSource.count(of: "\"Step \\(", inText: source) == 0, "\(file)")
        }

        // And the owner really is read at every site that shows one, so "no hand-written copy" is
        // not satisfied by a panel that dropped the line altogether: the HUD, the widget's approval
        // panel and the capture review in one file, Command Center's session context row in the
        // other.
        #expect(
            MacAgentSource.count(
                of: "ScreenControlSessionPresentation.stepLine(",
                inText: try MacAgentSource.read("FloatingWidgetView.swift")
            ) == 3
        )
        #expect(
            MacAgentSource.count(
                of: "ScreenControlSessionPresentation.stepLine(",
                inText: try MacAgentSource.read("CommandCenterView.swift")
            ) == 1
        )

        // **And the capture review's two arguments, at the site, in order.** A count of calls cannot
        // see a swap: `stepLine(iteration: preview.maximumIterations, maximumIterations:
        // preview.iteration)` would satisfy every expectation above and render "Step 8 of 2".
        // Nothing in this repository can ask a SwiftUI view what it drew, so the exact call at the
        // exact site is the pin — the shape `everySessionControlWearsItsOwnAccessibilityLabel` uses
        // for the same reason.
        //
        // **All four sites are pinned this way now, and the swap is also caught as a property of
        // the population** (SONNY-310, which is the ticket this comment used to file). This said
        // that only two were — this one and the approval panel's, in
        // `theApprovalPanelCarriesTheSessionsIdentityLineAndItsStopWhileASessionIsLive` — and that a
        // swap at the HUD or at Command Center's session context row was invisible to the suite.
        // Both now have a per-site pin of their own, and
        // `everyStepLineCallPairsItsArgumentsWithTheirOwnFields` sweeps both files whole, so a fifth
        // panel inherits the guard rather than needing a fifth assert nobody remembers to write.
        let captureReview = try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "private struct WidgetCaptureReviewPanel: View {",
            to: "private struct WidgetDelegationReviewPanel: View {"
        )
        #expect(MacAgentSource.count(of: "iteration: preview.iteration", inText: captureReview) == 1)
        #expect(
            MacAgentSource.count(of: "maximumIterations: preview.maximumIterations", inText: captureReview) == 1
        )
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

    /// **The two sites nothing pinned, pinned — and the general rule that makes a fifth site
    /// inherit the guard** (SONNY-310).
    ///
    /// Four sites render a session's step line, all four through
    /// `ScreenControlSessionPresentation.stepLine(iteration:maximumIterations:)`. Two had their
    /// arguments asserted at the site and two did not, so
    /// `stepLine(iteration: progress.maximumIterations, maximumIterations: progress.iteration)`
    /// compiled, rendered **"Step 12 of 2"** to a user watching Sonny move their cursor, and was
    /// invisible to the whole suite. The existing scans count the *calls*, which is what "the words
    /// have one owner" needs and which cannot see an argument order at all.
    ///
    /// **Two asserts would have closed the two sites and left the shape open**, which is the
    /// decision the ticket carried rather than the fix it asked for. The blind spot is not those two
    /// panels; it is that a call-site count reads as coverage for every argument handed to a shared
    /// presentation helper. So the primary guard here is a property of the *population*: every
    /// `stepLine` call in the whole `MacAgent` target pairs `iteration:` with an expression ending
    /// in `.iteration` and `maximumIterations:` with one ending in `.maximumIterations`. A fifth
    /// panel gets it without anyone remembering to add a pin, which per-site asserts cannot offer.
    ///
    /// **The sweep reads `appSourceFiles()`, and it first read two hard-coded filenames — which is
    /// the same defect one level up** (PR #151 review, F3). A scan whose population is a literal
    /// list is a scan that answers about that list while its doc comment claims the tree; the
    /// reviewer added a third file carrying the exact swap and all twelve tests passed. The
    /// neighbouring guard on hand-written copies,
    /// `bothSurfacesReadTheSessionsWordsFromOneOwnerAndNeitherHandWritesThem`, still reads those two
    /// filenames for its `"Step \("` absence check; that is stated here rather than left to be
    /// discovered, and it is a narrower hole — a third file would have to hand-write the sentence
    /// rather than mis-order a call to the owner.
    ///
    /// **The guard is shown to flag the defect before the live sweep is believed**, the discipline
    /// `UntrustedContentBoundaryScalarMatchingTests` states after a scan that flagged 0 of 13
    /// historical instances while its own doc promised otherwise. The swapped call is run through
    /// the same predicate first, verbatim.
    ///
    /// What this does *not* hold is the receiver: `iteration: someOtherProgress.iteration` passes.
    /// That is what the per-site pins are for, and all four now have one — this test's two, the
    /// approval panel's in
    /// `theApprovalPanelCarriesTheSessionsIdentityLineAndItsStopWhileASessionIsLive`, and the
    /// capture review's in `theStepLineHasOneOwnerAndNoPanelHandWritesIt`.
    @Test
    func everyStepLineCallPairsItsArgumentsWithTheirOwnFields() throws {
        // The guard first, against the defect itself. A predicate that cannot see a swap would pass
        // the sweep below and say nothing, which is the failure mode this shape has already had.
        #expect(Self.pairsItsArgumentsWithTheirOwnFields("\n    iteration: progress.iteration,\n    maximumIterations: progress.maximumIterations\n"))
        #expect(!Self.pairsItsArgumentsWithTheirOwnFields("\n    iteration: progress.maximumIterations,\n    maximumIterations: progress.iteration\n"), "the swap the ticket names")
        #expect(!Self.pairsItsArgumentsWithTheirOwnFields("\n    iteration: progress.iteration,\n    maximumIterations: 12\n"), "a literal is not the session's cap")
        #expect(!Self.pairsItsArgumentsWithTheirOwnFields("\n    iteration: progress.iteration\n"), "a call that lost an argument")

        // Then the live population, which is the **whole app target** rather than a list of
        // filenames. `appSourceFiles()` enumerates `Sources/MacAgent/` recursively, so a fifth site
        // in a file that does not exist yet is swept by the same rule — which is the property this
        // test claims, and which a two-filename loop did not have (PR #151 review, F3: the reviewer
        // added `StepLineThirdFileProbe.swift` carrying the exact swap and this test passed).
        // `RoutineDetailView.swift` is the standing precedent that a view here really does get split
        // into a file of its own, so the third file is not hypothetical.
        var calls: [(file: String, call: String)] = []
        for url in try MacAgentSource.appSourceFiles() {
            for call in Self.stepLineCalls(in: try MacAgentSource.read(url)) {
                calls.append((file: MacAgentSource.relativePath(of: url), call: call))
            }
        }
        #expect(calls.count == 4, "the whole-tree population, not a per-file count: \(calls.map(\.file))")
        for (file, call) in calls {
            #expect(
                Self.pairsItsArgumentsWithTheirOwnFields(call),
                "a step line whose arguments do not pair with their own fields, in \(file): \(call.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    /// **The HUD's own site, at the site** (SONNY-310) — the receiver as well as the pairing, which
    /// the population rule above deliberately does not reach.
    ///
    /// Anchored on the type name rather than a line number, which is what the ticket's own rebase
    /// note asks for: it was filed citing `FloatingWidgetView.swift:1716`, restated at `:1719` after
    /// one rebase, and the line has moved again since. A region opened by a declaration cannot drift
    /// that way, and a rename fails it loudly, which is the moment to re-check the property.
    @Test
    func theHUDsStepLineReadsTheSessionsOwnIterationAndCap() throws {
        let hud = try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "private struct WidgetControllingPanel: View {",
            to: "private struct WidgetClarificationPanel: View {"
        )

        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stepLine(", inText: hud) == 1)
        #expect(MacAgentSource.count(of: "iteration: progress.iteration", inText: hud) == 1)
        #expect(MacAgentSource.count(of: "maximumIterations: progress.maximumIterations", inText: hud) == 1)
    }

    /// **Command Center's session context row, at the site** (SONNY-310). The row that carries the
    /// session's identity above the approval panel, and the one of the four that lives in the other
    /// file — so a sweep confined to `FloatingWidgetView.swift` would have missed it, which is why
    /// the population rule above reads both.
    ///
    /// A brace block rather than a region between two declarations, because this row's neighbour
    /// below it is a doc comment rather than a type and an `to:` anchor there would be pinned to
    /// prose.
    @Test
    func commandCenterSessionContextRowsStepLineReadsTheSessionsOwnIterationAndCap() throws {
        let row = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("CommandCenterView.swift"),
            openedBy: "private struct CommandCenterSessionContextRow: View {"
        )

        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stepLine(", inText: row) == 1)
        #expect(MacAgentSource.count(of: "iteration: progress.iteration", inText: row) == 1)
        #expect(MacAgentSource.count(of: "maximumIterations: progress.maximumIterations", inText: row) == 1)
    }

    /// Every `ScreenControlSessionPresentation.stepLine(` call's argument text, read to its own
    /// closing parenthesis by depth rather than to the end of the line it opens on — the calls in
    /// both files are written across three lines, so a single-line reader would see a bare
    /// `stepLine(` and conclude nothing (SONNY-310).
    ///
    /// Comments are already gone: `MacAgentSource.read` strips both syntaxes before this sees the
    /// text, which is what stops a sentence *about* a step line from being counted as one.
    private static func stepLineCalls(in source: String) -> [String] {
        let anchor = "ScreenControlSessionPresentation.stepLine("
        var calls: [String] = []
        var searchStart = source.startIndex
        while let found = source.range(of: anchor, range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            var depth = 1
            var index = found.upperBound
            var call = ""
            while index < source.endIndex {
                let character = source[index]
                if character == "(" {
                    depth += 1
                }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }
                call.append(character)
                index = source.index(after: index)
            }
            calls.append(call)
        }
        return calls
    }

    /// The labelled arguments of one such call, split at commas that are not inside a nested call or
    /// subscript.
    private static func arguments(in call: String) -> [(label: String, expression: String)] {
        var depth = 0
        var current = ""
        var pieces: [String] = []
        for character in call {
            switch character {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth -= 1
            case "," where depth == 0:
                pieces.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = trimmed.firstIndex(of: ":") else {
                return nil
            }
            return (
                label: String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                expression: String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// Whether one call hands each label the field it is named for. The two suffixes are what
    /// separates the swap from the correct call — `.maximumIterations` does not end in
    /// `.iteration`, which is the whole discrimination — and a literal or a missing argument fails
    /// both.
    private static func pairsItsArgumentsWithTheirOwnFields(_ call: String) -> Bool {
        let arguments = arguments(in: call)
        guard arguments.count == 2 else {
            return false
        }
        guard arguments[0].label == "iteration", arguments[1].label == "maximumIterations" else {
            return false
        }
        return arguments[0].expression.hasSuffix(".iteration")
            && arguments[1].expression.hasSuffix(".maximumIterations")
    }
}
