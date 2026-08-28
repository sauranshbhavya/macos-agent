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
    func asecondLaunchOverTheSameMacResumesRatherThanRestarting() {
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let relauncher = NoOpRelauncher()
        let screenAccess = makeHermeticScreenAccessModel(
            screenRecordingGranted: false,
            accessibilityTrusted: false,
            relauncher: relauncher
        )

        let firstLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        firstLaunch.begin(isSignedIn: true, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .screenAccess)

        screenAccess.requestScreenRecording()
        #expect(screenAccess.needsRelaunchGuidance)
        screenAccess.relaunchNow()
        #expect(relauncher.relaunchCount == 1)

        // The process that comes back shares only the two things that survive it: the Keychain, and
        // this suite.
        let secondLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
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
        let coordinator = makeHermeticFirstRunCoordinator()

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
        let coordinator = makeHermeticFirstRunCoordinator()
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
        let coordinator = makeHermeticFirstRunCoordinator()
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
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let firstLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        firstLaunch.skipCurrentStep()
        #expect(firstLaunch.presentedStep == .screenAccess)

        let secondLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        secondLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(secondLaunch.presentedStep == .screenAccess, "the declined step is behind us; the outstanding one is not")
    }

    /// Declining everything ends the sequence and leaves it ended. The user is not asked again, and
    /// what they have is the app — the two places that finish a step later are permanent surfaces,
    /// not something this sequence has to keep offering.
    @Test
    func decliningEveryStepEndsTheSequenceAndLeavesItEnded() {
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let firstLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        firstLaunch.skipCurrentStep()
        firstLaunch.skipCurrentStep()
        #expect(firstLaunch.presentedStep == nil)

        let secondLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        secondLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(secondLaunch.presentedStep == nil)
        #expect(makeHermeticFirstRunStoreOver(suite).hasFinished)
    }

    /// Skipping with nothing on screen does nothing at all. The sheet's own dismissal routes here,
    /// and a sheet closing because the sequence *ended* must not record a skip against a step that
    /// is no longer presented.
    @Test
    func skippingWithNothingPresentedRecordsNothing() {
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let coordinator = makeHermeticFirstRunCoordinator(suiteName: suite)
        coordinator.begin(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)
        #expect(coordinator.presentedStep == nil)

        coordinator.skipCurrentStep()

        #expect(coordinator.presentedStep == nil)
        #expect(makeHermeticFirstRunStoreOver(suite).skippedSteps.isEmpty)
    }

    // MARK: - Completing it, once

    /// **Acceptance criterion 4.** Going through it once means it does not run again — and
    /// *including after signing out*, which is the case that decides whether "finished" is a flag or
    /// a derivation. Signing out is not a new first run.
    @Test
    func completingTheSequenceOnceMeansItNeverRunsAgainEvenAfterSigningOut() {
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let firstLaunch = makeHermeticFirstRunCoordinator(suiteName: suite)
        firstLaunch.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .signIn)

        firstLaunch.refresh(isSignedIn: true, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(firstLaunch.presentedStep == .screenAccess)
        firstLaunch.refresh(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)
        #expect(firstLaunch.presentedStep == nil)

        let afterSigningOut = makeHermeticFirstRunCoordinator(suiteName: suite)
        afterSigningOut.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)

        #expect(afterSigningOut.presentedStep == nil)
    }

    /// A Mac that was already signed in and already granted — every user who had the app before this
    /// sequence existed — is never walked through it, and is marked done on that first launch rather
    /// than being asked again the launch after.
    @Test
    func aMacThatIsAlreadySetUpIsNeverWalkedThroughTheSequence() {
        let suite = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let coordinator = makeHermeticFirstRunCoordinator(suiteName: suite)

        coordinator.begin(isSignedIn: true, screenRecordingGranted: true, accessibilityTrusted: true)

        #expect(coordinator.presentedStep == nil)
        #expect(makeHermeticFirstRunStoreOver(suite).hasFinished)
    }

    // MARK: - The store

    /// A stored step this build does not recognise is dropped rather than guessed at, and the
    /// direction it fails in is the safe one: an unknown step reads as not-skipped, so the worst
    /// case is being asked again.
    @Test
    func anUnrecognisedStoredStepIsDroppedRatherThanGuessedAt() {
        let suiteName = "com.sonny.tests.firstRun.\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defaults.set(["signIn", "somethingAVersionFromTheFutureWrote"], forKey: "com.sonny.state.firstRunSkippedSteps")

        let store = FirstRunStore(userDefaults: defaults)

        #expect(store.skippedSteps == [.signIn])
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
    }

    // MARK: - What the sequence says

    /// **Two labels, and that is the whole of the copy this sequence adds.** Concrete strings,
    /// because the requirement is that a declined step says where it is finished later — a test that
    /// only asserted the labels are non-empty would pass on "Skip".
    @Test
    func theDeferralLabelsSayWhereTheStepIsFinishedLater() {
        #expect(FirstRunCopy.deferralLabel(for: .signIn) == "Sign in later")
        #expect(FirstRunCopy.deferralLabel(for: .screenAccess) == "Set up later in Settings")

        let coordinator = makeHermeticFirstRunCoordinator()
        #expect(coordinator.deferralLabel == nil)
        coordinator.begin(isSignedIn: false, screenRecordingGranted: false, accessibilityTrusted: false)
        #expect(coordinator.deferralLabel == "Sign in later")
        coordinator.skipCurrentStep()
        #expect(coordinator.deferralLabel == "Set up later in Settings")
    }

    /// **No raw error can reach this sequence, and the reason is structural rather than a promise.**
    /// It has two failure surfaces and only one of them can fail: `ScreenAccessOnboardingModel`
    /// throws nothing and holds no error state at all, and every `SignInFailure` maps to one of
    /// `SignInCopy`'s own sentences. Asserted over `allCases` so a case added later has to be given
    /// a sentence rather than inheriting silence, and against the wire vocabulary a raw error would
    /// carry.
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

        // The other surface has no error channel to leak one through.
        let onboarding = try MacAgentSource.read("ScreenAccessOnboarding.swift")
        #expect(MacAgentSource.count(of: "throws", inText: onboarding) == 0)
        #expect(MacAgentSource.count(of: "localizedDescription", inText: onboarding) == 0)
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

    /// **First run is decided after the Keychain read, in the same task, and nowhere else.** A scan
    /// rather than a runtime assertion because `applicationDidFinishLaunching` cannot be driven in a
    /// test process — see `MacAgentSource`'s own doc for what a textual scan can and cannot hold.
    /// Both halves matter: `begin` inside the task that awaits `restore()`, and exactly one `begin`
    /// call in the whole target so a second one cannot be added outside it.
    @Test
    func theLaunchPathDecidesFirstRunOnlyAfterTheKeychainHasBeenRead() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let launchTask = try MacAgentSource.braceBlock(of: delegate, openedBy: "Task {")

        #expect(launchTask.contains("await accountModel.restore()"))
        #expect(launchTask.contains("firstRunCoordinator.begin("))
        let restoreOffset = try #require(launchTask.range(of: "await accountModel.restore()")).lowerBound
        let beginOffset = try #require(launchTask.range(of: "firstRunCoordinator.begin(")).lowerBound
        #expect(restoreOffset < beginOffset, "first run is decided before the Keychain is read")

        var beginSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() {
            let count = MacAgentSource.count(of: ".begin(", inText: try MacAgentSource.read(url))
            if count > 0 { beginSites[MacAgentSource.relativePath(of: url)] = count }
        }
        #expect(beginSites == ["AppDelegate.swift": 1], "found \(beginSites)")
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

    static let everySkipSet: [Set<FirstRunStep>] = [
        [],
        [.signIn],
        [.screenAccess],
        [.signIn, .screenAccess]
    ]

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

@MainActor
private func makeHermeticFirstRunStoreOver(_ suiteName: String) -> FirstRunStore {
    makeHermeticFirstRunStore(suiteName: suiteName)
}
