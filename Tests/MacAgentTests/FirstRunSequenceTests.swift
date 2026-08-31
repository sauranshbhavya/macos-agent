import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// First run as one ordered sequence, and the three properties that make it worth having: it is
/// ordered so the session is in the Keychain before anything can restart the app, it resumes rather
/// than replays, and it never traps the user.
///
/// **What is pinned here and what is owed.** The headline acceptance — sign in against a real
/// project, grant Screen Recording, relaunch, come back signed in — needs a live sign-in, which is
/// deferred as one sitting on **SONNY-280** (its founder-deferral comment of 2026-08-27 and its
/// numbered resume checklist, steps (1)–(5)). Everything that does not need a live backend is
/// pinned below, including the resume itself: the sequence resolves from live state, so a test can
/// stand a second coordinator over the same `UserDefaults` suite and the same grants and ask where
/// the process that came back would land. `SignInSurfaceTests.theSessionIsAlreadyOnDiskWhenTheScreen
/// RecordingGrantRestartsTheApp` (SONNY-128) holds the Keychain half end to end and is the property
/// this ticket must not break.
@Suite
@MainActor
struct FirstRunSequenceTests {
    // MARK: - The order, and why it is the order

    /// **The whole sequence, as an exact list in both directions.**
    ///
    /// Order first: `signIn` before `screenAccess` is the ticket's headline constraint, because the
    /// Screen Recording grant restarts the app and a session not yet in the Keychain is gone when it
    /// does. Exact equality second: it is also how "there is no in-app training-consent step" is
    /// held. Consent is captured in the website signup flow (founder, 2026-08-16), which happens
    /// before the app is ever opened, and a third case appearing here fails this test rather than
    /// shipping.
    @Test
    func theSequenceIsSignInThenScreenAccessAndNothingElse() {
        #expect(FirstRunStep.allCases == [.signIn, .screenAccess])
    }

    /// **The ordering property over every input, not over the two a reader would think of.**
    ///
    /// 64 combinations: signed-in, Screen Recording, Accessibility, each of the four skip sets, and
    /// finished either way. In none of them may `.screenAccess` be the answer while sign-in is still
    /// outstanding — outstanding meaning neither done nor declined. That is "the token reaches the
    /// Keychain before anything that can relaunch", stated as a property of the sequence rather than
    /// as the order two enum cases happen to be written in.
    @Test
    func screenAccessIsNeverReachedWhileSignInIsStillOutstanding() {
        var combinationsChecked = 0
        var timesScreenAccessWasTheAnswer = 0
        for isSignedIn in [false, true] {
            for screenRecordingGranted in [false, true] {
                for accessibilityTrusted in [false, true] {
                    for skipped in Self.everySkipSet {
                        for hasFinished in [false, true] {
                            combinationsChecked += 1
                            let step = FirstRunSequence.step(
                                isSignedIn: isSignedIn,
                                screenRecordingGranted: screenRecordingGranted,
                                accessibilityTrusted: accessibilityTrusted,
                                skipped: skipped,
                                hasFinished: hasFinished
                            )
                            guard step == .screenAccess else { continue }
                            timesScreenAccessWasTheAnswer += 1
                            #expect(
                                isSignedIn || skipped.contains(.signIn),
                                "screen access offered with sign-in outstanding: signedIn=\(isSignedIn) skipped=\(skipped)"
                            )
                        }
                    }
                }
            }
        }
        // Derived rather than spelled, so a third step raises the expectation along with the loop
        // instead of leaving it passing over a third of the space.
        #expect(Self.everySkipSet.count == 4)
        #expect(combinationsChecked == 2 * 2 * 2 * Self.everySkipSet.count * 2)
        #expect(combinationsChecked == 64)
        // A property nothing can satisfy is a property nothing holds: the loop has to reach the case
        // it is about. **Nine of the sixty-four answer `.screenAccess`**, and the figure is counted
        // rather than estimated — the first draft of this line said twelve and this assertion is
        // what caught it. The nine are: unfinished, screen access itself not declined, and the three
        // of four grant pairs that leave it incomplete — six with sign-in declined (either value of
        // `isSignedIn`) and three with sign-in done and nothing declined.
        #expect(timesScreenAccessWasTheAnswer == 9)
    }

    /// A Mac with no Sonny state at all starts at the first step rather than at an empty Command
    /// Center — acceptance criterion 1, at the resolver.
    @Test
    func aCleanMachineStartsAtSignIn() {
        #expect(Self.stepOnAFreshMac(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false) == .signIn)
    }

    // MARK: - The relaunch, which is what the sequence is for

    /// **Acceptance criterion 2's resumption half.** The user signed in, granted Screen Recording,
    /// and macOS restarted the app. The process that came back reads a session from the Keychain and
    /// a granted Screen Recording from TCC, so it must land on the step that is left — and, the part
    /// that would be the worst bug this row can ship, it must not land back on sign-in.
    @Test
    func theRelaunchComesBackAtTheNextStepAndNeverAtTheBeginning() {
        let afterRelaunch = Self.stepOnAFreshMac(
            isSignedIn: true,
            screenRecordingGranted: true,
            accessibilityTrusted: false
        )
        #expect(afterRelaunch == .screenAccess)
        #expect(afterRelaunch != .signIn)
    }

    /// The same thing through the real coordinator and a real store, with a second coordinator over
    /// the same `UserDefaults` suite standing in for the process that came back — the shape
    /// `SignInSurfaceTests` uses for the Keychain, applied to the sequence's own state.
    ///
    /// The relaunch is driven through the product's own `AppRelaunching` seam rather than simulated
    /// beside it, so the test cannot pass by agreeing with itself about what a relaunch is.
    @Test
    func asecondLaunchOverTheSameMacResumesRatherThanRestarting() async {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let relauncher = NoOpRelauncher()
        let screenAccess = makeHermeticScreenAccessModel(
            screenRecordingGranted: false,
            accessibilityTrusted: false,
            relauncher: relauncher
        )

        let firstLaunch = suite.makeCoordinator()
        firstLaunch.begin(isSignedIn: true, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .screenAccess)

        screenAccess.requestScreenRecording()
        #expect(screenAccess.needsRelaunchGuidance)
        await screenAccess.relaunchNow()
        #expect(relauncher.relaunchCount == 1)

        // The process that comes back shares only the two things that survive it: the Keychain, and
        // this suite.
        let secondLaunch = suite.makeCoordinator()
        secondLaunch.begin(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: false)

        #expect(secondLaunch.presentedStep == .screenAccess)
        #expect(secondLaunch.presentedStep != .signIn)
    }

    /// **Nothing is decided before the Keychain has been read.** `restore()` is asynchronous, so a
    /// coordinator that answered on construction would answer `signedIn == false` on every launch —
    /// including the one after the Screen Recording grant, where that answer hands a sign-in step to
    /// a user who is signed in. `refresh` before `begin` must not start the sequence either, or any
    /// view's `onChange` firing during layout would do exactly that.
    @Test
    func nothingIsDecidedBeforeTheKeychainHasBeenRead() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()

        #expect(coordinator.presentedStep == nil)
        #expect(coordinator.hasBegun == false)

        coordinator.refresh(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(coordinator.presentedStep == nil, "refresh must not start the sequence")
        #expect(coordinator.hasBegun == false)

        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(coordinator.hasBegun)
        #expect(coordinator.presentedStep == .signIn)
    }

    /// A second `begin` is ignored. Otherwise anything that re-ran the launch path would re-enter a
    /// sequence the user had already skipped out of during this launch.
    @Test
    func beginningTwiceDoesNotReopenASequenceTheUserLeft() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()
        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        coordinator.skipCurrentStep()
        coordinator.skipCurrentStep()
        #expect(coordinator.presentedStep == nil)

        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(coordinator.presentedStep == nil)
    }

    // MARK: - Skipping, and finishing later

    /// Skipping the first step moves to the second rather than ending the sequence, and the second
    /// step is still the real one.
    @Test
    func skippingSignInMovesToScreenAccessRatherThanEndingTheSequence() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()
        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(coordinator.presentedStep == .signIn)

        coordinator.skipCurrentStep()

        #expect(coordinator.presentedStep == .screenAccess)
    }

    /// **Acceptance criterion 3.** A declined step is not asked again — on this launch or any later
    /// one — and what is left is a usable Sonny rather than a stuck one. The second coordinator is
    /// the next launch of the app on the same Mac.
    @Test
    func aDeclinedStepIsNotAskedAgainOnThisLaunchOrTheNext() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let firstLaunch = suite.makeCoordinator()
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        firstLaunch.skipCurrentStep()
        #expect(firstLaunch.presentedStep == .screenAccess)

        let secondLaunch = suite.makeCoordinator()
        secondLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(secondLaunch.presentedStep == .screenAccess, "the declined step is behind us; the outstanding one is not")
    }

    /// Declining everything ends the sequence and leaves it ended. The user is not asked again, and
    /// what they have is the app — the two places that finish a step later are permanent surfaces,
    /// not something this sequence has to keep offering.
    @Test
    func decliningEveryStepEndsTheSequenceAndLeavesItEnded() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let firstLaunch = suite.makeCoordinator()
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        firstLaunch.skipCurrentStep()
        firstLaunch.skipCurrentStep()
        #expect(firstLaunch.presentedStep == nil)

        let secondLaunch = suite.makeCoordinator()
        secondLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(secondLaunch.presentedStep == nil)
        #expect(suite.store.hasFinished)
    }

    /// Skipping with nothing on screen does nothing at all. The sheet's own dismissal routes here,
    /// and a sheet closing because the sequence *ended* must not record a skip against a step that
    /// is no longer presented.
    @Test
    func skippingWithNothingPresentedRecordsNothing() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()
        coordinator.begin(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)
        #expect(coordinator.presentedStep == nil)

        coordinator.skipCurrentStep()

        #expect(coordinator.presentedStep == nil)
        #expect(suite.store.skippedSteps.isEmpty)
    }

    // MARK: - Completing it, once

    /// **Acceptance criterion 4.** Going through it once means it does not run again — and
    /// *including after signing out*, which is the case that decides whether "finished" is a flag or
    /// a derivation. Signing out is not a new first run.
    @Test
    func completingTheSequenceOnceMeansItNeverRunsAgainEvenAfterSigningOut() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let firstLaunch = suite.makeCoordinator()
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .signIn)

        firstLaunch.refresh(isSignedIn: true, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .screenAccess)
        firstLaunch.refresh(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)
        #expect(firstLaunch.presentedStep == nil)

        let afterSigningOut = suite.makeCoordinator()
        afterSigningOut.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(afterSigningOut.presentedStep == nil)
    }

    /// A Mac that was already signed in and already granted — every user who had the app before this
    /// sequence existed — is never walked through it, and is marked done on that first launch rather
    /// than being asked again the launch after.
    @Test
    func aMacThatIsAlreadySetUpIsNeverWalkedThroughTheSequence() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()

        coordinator.begin(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)

        #expect(coordinator.presentedStep == nil)
        #expect(suite.store.hasFinished)
    }

    // MARK: - The store

    /// A stored step this build does not recognise is dropped rather than guessed at, and the
    /// direction it fails in is the safe one: an unknown step reads as not-skipped, so the worst
    /// case is being asked again.
    @Test
    func anUnrecognisedStoredStepIsDroppedRatherThanGuessedAt() {
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        suite.userDefaults.set(
            ["signIn", "somethingAVersionFromTheFutureWrote"],
            forKey: "com.sonny.state.firstRunSkippedSteps"
        )

        #expect(suite.store.skippedSteps == [.signIn])
    }

    /// The two keys are read the way the Preferences convention requires and written where a wipe
    /// cannot reach them — `UserDefaults`, not a local store. A first run restarted by Delete Local
    /// Data would be a wipe undoing something the user had already done.
    @Test
    func theSequencesStateSurvivesInUserDefaultsAndNotInALocalStore() throws {
        let source = try MacAgentSource.read("FirstRunSequence.swift")

        #expect(MacAgentSource.count(of: "UserDefaults", inText: source) > 0)
        #expect(MacAgentSource.count(of: "LocalStorageEncryption", inText: source) == 0)
        #expect(MacAgentSource.count(of: "LocalStore", inText: source) == 0)
        // `.bool(forKey:)` silently answers false for a missing key of any kind; the convention is
        // the explicit `object(forKey:) as? Bool`.
        #expect(MacAgentSource.count(of: ".bool(forKey:", inText: source) == 0)
        #expect(MacAgentSource.count(of: "object(forKey: Keys.hasFinished) as? Bool ?? false", inText: source) == 1)

        // **The guarantee this test is named for, rather than the mechanism it rests on** (PR #159's
        // review, F6). Everything above says the flag lives in `UserDefaults`; none of it says the
        // flag survives. `LocalDataDeletionService` operates on file URLs through three doors, so a
        // wipe cannot reach a `UserDefaults` domain — but a single
        // `UserDefaults.standard.removeObject(forKey: "com.sonny.state.firstRunFinished")` added to
        // it tomorrow would restart first run for a user who finished it, and every assertion above
        // would still pass. So: no file in either target removes a default, by any route.
        var removalSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() + MacAgentSource.coreSourceFiles() {
            let text = try MacAgentSource.read(url)
            let count = MacAgentSource.count(of: "removeObject(forKey:", inText: text)
                + MacAgentSource.count(of: "removePersistentDomain", inText: text)
            if count > 0 { removalSites[url.lastPathComponent] = count }
        }
        #expect(removalSites.isEmpty, "something in the product now clears a default: \(removalSites)")
        // A zero from a search that cannot find anything is not a measurement: the same scan over a
        // token that is present answers, so the population really is being read.
        var writeSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() + MacAgentSource.coreSourceFiles() {
            let count = MacAgentSource.count(of: "UserDefaults", inText: try MacAgentSource.read(url))
            if count > 0 { writeSites[url.lastPathComponent] = count }
        }
        #expect(writeSites.count >= 5, "the scan found nothing at all: \(writeSites)")
    }

    // MARK: - What the sequence says

    /// **Two labels, and that is the whole of the copy this sequence adds.** Concrete strings,
    /// because the requirement is that a declined step says where it is finished later — a test that
    /// only asserted the labels are non-empty would pass on "Skip".
    @Test
    func theDeferralLabelsSayWhereTheStepIsFinishedLater() {
        #expect(FirstRunCopy.deferralLabel(for: .signIn) == "Sign in later")
        #expect(FirstRunCopy.deferralLabel(for: .screenAccess) == "Set up later in Settings")

        // And the label on screen follows the step, which is what makes the second one reachable at
        // all: it is only ever shown after the first has been declined.
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let coordinator = suite.makeCoordinator()
        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(coordinator.presentedStep.map(FirstRunCopy.deferralLabel(for:)) == "Sign in later")
        coordinator.skipCurrentStep()
        #expect(coordinator.presentedStep.map(FirstRunCopy.deferralLabel(for:)) == "Set up later in Settings")
    }

    /// **No raw error can reach this sequence, and the reason is structural rather than a promise.**
    /// Every `SignInFailure` maps to one of `SignInCopy`'s own sentences, asserted over `allCases`
    /// so a case added later has to be given a sentence rather than inheriting silence, and against
    /// the wire vocabulary a raw error would carry.
    ///
    /// **Both surfaces can fail now, and the screen-access one is held differently** (SONNY-348).
    /// This used to read "only one of them can fail: `ScreenAccessOnboardingModel` throws nothing
    /// and holds no error state at all", and the second half of that sentence was the assertion
    /// underneath it — a `throws` count of zero over the whole file. That stopped being available
    /// the moment a relaunch that cannot reopen the bundle had to be reported rather than discarded,
    /// and it was never the property this test is about: what matters is that no error's *words*
    /// reach the user, not that no error exists. So the file's own error channel is pinned instead —
    /// the catch stores a Bool and reads nothing off the error, and the sentence that reaches the
    /// screen is a literal.
    @Test
    func noStepCanSurfaceARawError() throws {
        var sentences: Set<String> = []
        for failure in SignInFailure.allCases {
            let message = SignInCopy.message(for: failure)
            sentences.insert(message)
            #expect(!message.isEmpty, "\(failure) has no sentence")
            #expect(message.last == ".", "\(failure) is not a sentence: \(message)")
            for token in ["Error", "error", "http", "HTTP", "NSError", "Optional(", "code=", "_", "{"] {
                #expect(!message.contains(token), "\(failure) leaked \(token): \(message)")
            }
        }
        #expect(sentences.count == SignInFailure.allCases.count, "two failures share a sentence")

        // One surface has no error channel at all; the other has one and must render only the
        // sentences above. `SignInView.swift` is scanned too (PR #159's review, F6) — a direct
        // `error.localizedDescription` added to that view would pass the `allCases` half untouched,
        // because the mapping would still be complete and simply no longer be what is displayed.
        for file in ["ScreenAccessOnboarding.swift", "SignInView.swift", "FirstRunSequence.swift"] {
            let source = try MacAgentSource.read(file)
            #expect(MacAgentSource.count(of: "localizedDescription", inText: source) == 0, "\(file)")
        }
        // The screen-access surface's own error channel, whole: everything the catch does with the
        // failure is record that there was one. An error read here — its description, its case, the
        // status inside it — would be a leak this file's `localizedDescription` scan cannot see.
        let catchBlock = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("ScreenAccessOnboarding.swift"),
            openedBy: "} catch {"
        )
        #expect(catchBlock.trimmingCharacters(in: .whitespacesAndNewlines) == "relaunchFailed = true")

        // And the one place a sign-in failure is drawn renders the mapped sentence and nothing else.
        // `localizedDescription` is the obvious leak and the scan above covers it; this covers the
        // rest of the family — `String(describing:)`, a debug description, the error itself — by
        // pinning what that block draws rather than listing what it may not.
        let messages = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("SignInView.swift"),
            openedBy: "private var messages: some View {"
        )
        #expect(MacAgentSource.count(of: "Text(SignInCopy.message(for: failure))", inText: messages) == 1)
        #expect(MacAgentSource.count(of: "Text(notice)", inText: messages) == 1)
        #expect(MacAgentSource.count(of: "Text(", inText: messages) == 2, "a third thing is drawn here")
    }

    // MARK: - What the sequence deliberately does not contain

    /// **A second sign-in method slots in without this file being rebuilt** (SONNY-129, deferred
    /// behind SONNY-280's sitting; the founder's requirement of 2026-08-17 that the flow hold for
    /// two methods and then for three). The step is satisfied by "a session is held", so nothing
    /// here can name a method — the scan is the claim, because a file that named one would be a file
    /// a third method has to be added to.
    @Test
    func theSequenceNamesNoSignInMethod() throws {
        let source = try MacAgentSource.read("FirstRunSequence.swift").lowercased()
        for method in ["google", "apple id", "sign in with", "oauth", "magic link", "verification code"] {
            #expect(!source.contains(method), "the sequence names a sign-in method: \(method)")
        }
    }

    /// **The app asks for nothing about training consent and offers no control for it**, which is
    /// what "correct for a user who has not given it" means here: consent is captured in the website
    /// signup flow before the app is ever opened (founder, 2026-08-16), and an in-app toggle would
    /// have to explain itself. The scan covers the sequence and both dialogs it hosts, which is
    /// every surface a first run puts in front of a new user.
    @Test
    func nothingInTheFirstRunSurfacesAsksForConsentOrOffersAToggleForIt() throws {
        for file in ["FirstRunSequence.swift", "SignInView.swift", "ScreenAccessOnboarding.swift"] {
            let source = try MacAgentSource.read(file).lowercased()
            for token in ["consent", "training", "opt in", "opt-out", "improve sonny"] {
                #expect(!source.contains(token), "\(file) mentions \(token)")
            }
        }
    }

    // MARK: - Where the sequence is wired

    /// **The launch path routes the first-run decision through one method, and that method reads the
    /// Keychain before it decides.** A scan rather than a runtime assertion because
    /// `applicationDidFinishLaunching` cannot be called in a test process — see `MacAgentSource`'s
    /// own doc for what a textual scan can and cannot hold.
    ///
    /// **What this holds and what it deliberately does not** (PR #159's review, F3). It holds
    /// *shape*: one decision path, inside the launch method, awaiting the read before deciding. It
    /// says nothing about the *values* handed to `begin`, and two edits that keep this shape and
    /// break the value reproduce the same user-visible bug — a read hoisted above the `await`, and a
    /// literal `false`. Both survived this scan when it was the only pin. The value is held
    /// behaviourally instead, by
    /// `ProductShellTests.theLaunchDecidesFirstRunOnTheSessionTheKeychainActuallyHeld`, which drives
    /// the real method over a seeded Keychain. Neither replaces the other: that test cannot see a
    /// second decision path added elsewhere, and this one cannot see a stale value.
    ///
    /// The region is anchored on the extracted method by name rather than on the first `Task {` in
    /// the file. There is exactly one such block today, so the old anchor was correct — and an
    /// earlier `Task` added later would have made this fail loudly against the wrong block, with a
    /// message pointing at the wrong thing.
    @Test
    func theLaunchPathHasOneFirstRunDecisionAndItAwaitsTheKeychainRead() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")

        // The launch method delegates; it does not carry a second copy of the decision.
        let launch = try MacAgentSource.braceBlock(
            of: delegate,
            openedBy: "func applicationDidFinishLaunching(_ notification: Notification) {"
        )
        #expect(MacAgentSource.count(of: "decideFirstRunAfterRestoringTheSession()", inText: launch) == 1)
        #expect(MacAgentSource.count(of: "firstRunCoordinator.begin(", inText: launch) == 0)

        let decision = try MacAgentSource.braceBlock(
            of: delegate,
            openedBy: "func decideFirstRunAfterRestoringTheSession() async {"
        )
        #expect(decision.contains("await accountModel.restore()"))
        #expect(decision.contains("firstRunCoordinator.begin("))
        let restoreOffset = try #require(decision.range(of: "await accountModel.restore()")).lowerBound
        let beginOffset = try #require(decision.range(of: "firstRunCoordinator.begin(")).lowerBound
        #expect(restoreOffset < beginOffset, "first run is decided before the Keychain is read")

        // And there is exactly one `begin` in the whole target, so a second decision path cannot be
        // added beside this one.
        var beginSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() {
            let count = MacAgentSource.count(of: ".begin(", inText: try MacAgentSource.read(url))
            if count > 0 { beginSites[MacAgentSource.relativePath(of: url)] = count }
        }
        #expect(beginSites == ["AppDelegate.swift": 1], "found \(beginSites)")
    }

    /// **Command Center presents the sequence, and the two controls that decline a step both reach
    /// `skipCurrentStep()`.** Without this, deleting the entire first-run sheet compiles and leaves
    /// the whole suite green — the sequence is simply never shown to anybody, on any launch — and so
    /// does turning the hosted dialog's close control into a no-op. Both were live mutants in PR
    /// #159's review (M4 and M5, both SURVIVED); acceptance criterion 1 was pinned at the resolver
    /// and nowhere else, which is a claim about a function rather than about the product.
    ///
    /// A scan is the right instrument rather than a fallback: this repository has no view-inspection
    /// harness, which is why every UI property in it is a source scan.
    @Test
    func commandCenterPresentsTheSequenceAndBothDecliningControlsReachTheSameCall() throws {
        // M4: the sheet exists, in exactly one place, on the shared coordinator.
        #expect(try Self.sitesOf("FirstRunSequenceView(") == ["CommandCenterView.swift": 1])

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        let presentation = try MacAgentSource.region(
            of: commandCenter,
            from: ".sheet(isPresented: Binding(",
            to: "FirstRunSequenceView("
        )
        // What decides whether it is on screen is the coordinator's own step, not a local flag that
        // could be set anywhere.
        #expect(presentation.contains("firstRunCoordinator.presentedStep != nil"))
        // And the sheet's own dismissal — Escape, a drag — declines the step rather than losing it.
        #expect(presentation.contains("firstRunCoordinator.skipCurrentStep()"))

        // M5: the hosted dialog's close control, which is the *primary* declining mechanism, routes
        // to the same call rather than to a setter that discards it.
        let sequence = try MacAgentSource.read("FirstRunSequence.swift")
        let skipBinding = try MacAgentSource.braceBlock(
            of: sequence,
            openedBy: "private var skipBinding: Binding<Bool> {"
        )
        #expect(MacAgentSource.count(of: "coordinator.skipCurrentStep()", inText: skipBinding) == 1)
        // Both dialogs are handed that binding, so neither can close without declining.
        let stepContent = try MacAgentSource.braceBlock(
            of: sequence,
            openedBy: "private var stepContent: some View {"
        )
        #expect(MacAgentSource.count(of: "isPresented: skipBinding", inText: stepContent) == 2)
        // Two routes into that call in this file and no third: the binding both dialogs are handed,
        // and the deferral button. (This comment said *three* beside the correct `== 2` — the count
        // was right and the sentence beside it was not, which is the shape a reader trusts and a
        // compiler cannot see. PR #159's cycle-2 review.)
        #expect(MacAgentSource.count(of: "coordinator.skipCurrentStep()", inText: sequence) == 2)
    }

    /// **Both dialogs have exactly two doors each: the manual one, and the sequence.** An exact map
    /// in both directions, so a third door fails here rather than becoming a second, differently
    /// behaved way into the same surface — the thing `SignInSurfaceTests.commandCenterOpensTheSignIn
    /// DialogFromTheAccountMenuAndNowhereElse` holds for Command Center, widened to the target now
    /// that first run is a second host.
    @Test
    func eachHostedDialogHasItsManualDoorAndTheSequenceAndNoOther() throws {
        #expect(try Self.sitesOf("SignInDialogView(") == [
            "CommandCenterView.swift": 1,
            "FirstRunSequence.swift": 1
        ])
        #expect(try Self.sitesOf("ScreenAccessOnboardingView(") == [
            "CommandCenterView.swift": 1,
            "FirstRunSequence.swift": 1
        ])
        // And the sequence hosts them rather than reimplementing either: no second state machine, no
        // second permission model.
        let source = try MacAgentSource.read("FirstRunSequence.swift")
        #expect(MacAgentSource.count(of: "SonnyAccountModel(", inText: source) == 0)
        #expect(MacAgentSource.count(of: "ScreenAccessOnboardingModel(", inText: source) == 0)
    }

    /// **One screen-access model, shared by the sequence and by Settings › Security & Access.** Two
    /// would be two answers to `screenRecordingRequestedThisLaunch`: a user who pressed Request
    /// access in first run would find the Settings page showing no relaunch guidance for a request
    /// it never saw, on the one step where the relaunch is the entire mechanic.
    @Test
    func theScreenAccessModelIsBuiltOnceAndSharedByBothDoors() throws {
        var constructionSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() {
            let count = MacAgentSource.count(of: "ScreenAccessOnboardingModel(", inText: try MacAgentSource.read(url))
            if count > 0 { constructionSites[MacAgentSource.relativePath(of: url)] = count }
        }
        #expect(constructionSites == ["main.swift": 1], "found \(constructionSites)")

        // And it is threaded rather than rebuilt on the way down: three declarations in Command
        // Center — the view, the Settings dialog it forwards through, and the Security & Access page
        // that used to own one — and no `@StateObject`, which is what owning one would look like.
        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        #expect(MacAgentSource.count(of: "@StateObject private var screenAccessModel", inText: commandCenter) == 0)
        #expect(MacAgentSource.count(of: "@ObservedObject var screenAccessModel", inText: commandCenter) == 3)
    }

    // MARK: - Helpers

    /// **Derived from `allCases`, not written out** (PR #159's review, F7). A literal four-element
    /// array survives a third step: the power set becomes eight, the loop still runs 64
    /// combinations, `combinationsChecked == 64` still passes, and the exhaustive property quietly
    /// stops being exhaustive. `theSequenceIsSignInThenScreenAccessAndNothingElse` would catch the
    /// third step — in a different function — but a property test that cannot see its own
    /// incompleteness is the wrong shape for the one assertion the ordering rests on.
    static var everySkipSet: [Set<FirstRunStep>] {
        FirstRunStep.allCases.reduce(into: [Set<FirstRunStep>]([[]])) { sets, step in
            sets += sets.map { $0.union([step]) }
        }
    }

    static func stepOnAFreshMac(
        isSignedIn: Bool,
        screenRecordingGranted: Bool,
        accessibilityTrusted: Bool
    ) -> FirstRunStep? {
        FirstRunSequence.step(
            isSignedIn: isSignedIn,
            screenRecordingGranted: screenRecordingGranted,
            accessibilityTrusted: accessibilityTrusted,
            skipped: [],
            hasFinished: false
        )
    }

    static func sitesOf(_ needle: String) throws -> [String: Int] {
        var sites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() {
            let count = MacAgentSource.count(of: needle, inText: try MacAgentSource.read(url))
            if count > 0 { sites[MacAgentSource.relativePath(of: url)] = count }
        }
        return sites
    }
}
