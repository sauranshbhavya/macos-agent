import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-46 — folding `isEnabled: Bool` + `pausedReason: String?` into `RoutineActivation`.
///
/// Deliberately a new file rather than additions to `RoutineScheduleTests`. That suite is
/// SONNY-31's, and this ticket's measure of "all legal-state behaviour is byte-identical" is that
/// it passes *unchanged* — a claim a reviewer can check with `git diff` on the file rather than by
/// reading it. Everything here is about the shape change itself: the persisted representation, the
/// legacy decode, and the invariant the fold makes structural.
@Suite
struct RoutineActivationTests {
    // MARK: - Legacy decode: all three mappings

    /// The two legal legacy shapes plus the ordinary enabled one. Every `routines.json` in
    /// existence today is written this way, so this is the mapping that decides whether a user's
    /// routines survive the update at all.
    @Test
    func legacyTwoFieldJSONDecodesToEachOfTheThreeActivationStates() throws {
        let enabled = try decodeLegacySchedule(isEnabled: true, pausedReason: nil)
        #expect(enabled.activation == .enabled)
        #expect(enabled.isEnabled)
        #expect(enabled.pausedReason == nil)
        #expect(enabled.isPausedBySonny == false)

        let paused = try decodeLegacySchedule(isEnabled: false, pausedReason: "Draft output already exists at /tmp/weekly.md.")
        #expect(paused.activation == .pausedBySonny(reason: "Draft output already exists at /tmp/weekly.md."))
        #expect(paused.isEnabled == false)
        #expect(paused.pausedReason == "Draft output already exists at /tmp/weekly.md.")
        #expect(paused.isPausedBySonny)

        let userDisabled = try decodeLegacySchedule(isEnabled: false, pausedReason: nil)
        #expect(userDisabled.activation == .disabledByUser)
        #expect(userDisabled.isEnabled == false)
        #expect(userDisabled.pausedReason == nil)
        #expect(userDisabled.isPausedBySonny == false)

        // The rest of the schedule decodes exactly as before — the fold changed one pair of keys,
        // not the record around them.
        #expect(paused.cadence == .daily)
        #expect(paused.hour == 9)
        #expect(paused.minute == 0)
        #expect(paused.unattendedTrusted)
        #expect(paused.lastRunAt == Self.anchored)
    }

    /// **The self-repair.** The fourth legacy shape is the illegal one this ticket exists to make
    /// unrepresentable: enabled *and* carrying a pause reason. It is on disk in exactly one way —
    /// hand-edited, or written by a caller of the old public API that never read the doc comment —
    /// and it rendered as "Paused" on a routine that was still firing on time.
    ///
    /// Enabled is the fact the scheduler acts on and the reason is the stale half, so the reason is
    /// dropped rather than the schedule being switched off. Repairing rather than throwing is the
    /// point: a display glitch must never cost a user their routines file.
    @Test
    func legacyJSONInTheIllegalStateSelfRepairsToEnabledAndDropsTheStaleReason() throws {
        let repaired = try decodeLegacySchedule(
            isEnabled: true,
            pausedReason: "Snippet trigger ;sig already exists and would be replaced."
        )

        #expect(repaired.activation == .enabled)
        #expect(repaired.isEnabled)
        #expect(repaired.pausedReason == nil)
        #expect(repaired.isPausedBySonny == false)
        // The repair is a repair, not a reset: nothing else about the schedule is disturbed, so
        // the routine keeps firing on exactly the schedule it had.
        #expect(repaired.cadence == .daily)
        #expect(repaired.hour == 9)
        #expect(repaired.lastRunAt == Self.anchored)
        // And it is durable — re-encoding writes the repaired shape, so the file stops lying the
        // first time anything saves it.
        let reEncoded = try JSONDecoder().decode(
            RoutineSchedule.self,
            from: JSONEncoder().encode(repaired)
        )
        #expect(reEncoded.activation == .enabled)
    }

    /// A file carrying both shapes — the one a partial hand-edit or a downgrade-then-upgrade round
    /// trip would produce. `activation` is the current field, so it wins; the legacy pair is read
    /// only when there is no `activation` at all.
    @Test
    func activationWinsOverLegacyKeysWhenAFileSomehowCarriesBoth() throws {
        let json = """
        {
          "cadence": "daily",
          "hour": 9,
          "minute": 0,
          "unattendedTrusted": false,
          "isEnabled": true,
          "pausedReason": "stale",
          "activation": { "state": "disabledByUser" }
        }
        """

        let schedule = try JSONDecoder().decode(RoutineSchedule.self, from: Data(json.utf8))

        #expect(schedule.activation == .disabledByUser)
        #expect(schedule.isEnabled == false)
        #expect(schedule.pausedReason == nil)
    }

    /// A schedule with neither `activation` nor `isEnabled` is corrupt, and throwing is what the
    /// synthesized decoder did before this change. Pinned so the tolerant legacy branch above can
    /// never quietly become "default to disabled" for a file that is actually damaged.
    @Test
    func aScheduleCarryingNeitherActivationNorTheLegacyFlagStillFailsToDecode() {
        let json = """
        { "cadence": "daily", "hour": 9, "minute": 0, "unattendedTrusted": false }
        """

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RoutineSchedule.self, from: Data(json.utf8))
        }
    }

    // MARK: - The new shape

    @Test
    func everyActivationStateSurvivesAnEncodeDecodeRoundTrip() throws {
        var enabled = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        enabled.setEnabled(true, now: Self.anchored)

        var userDisabled = enabled
        userDisabled.setEnabled(false, now: Self.anchored)

        var paused = enabled
        paused.pause(reason: "Markdown output already exists at /tmp/hn.md.")

        for schedule in [enabled, userDisabled, paused] {
            let decoded = try JSONDecoder().decode(
                RoutineSchedule.self,
                from: JSONEncoder().encode(schedule)
            )
            #expect(decoded == schedule)
            #expect(decoded.activation == schedule.activation)
        }
    }

    /// New encodes use the new shape and only the new shape. Without this, a decoder that happened
    /// to prefer the legacy keys would still pass every round-trip test above while leaving the
    /// old pair on disk as a second, drifting source of truth.
    @Test
    func newEncodesWriteActivationAndNeitherOfTheKeysItReplaced() throws {
        var paused = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        paused.setEnabled(true, now: Self.anchored)
        paused.pause(reason: "Zip output already exists at /tmp/a.zip.")

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(paused)) as? [String: Any]
        )

        #expect(object["isEnabled"] == nil)
        #expect(object["pausedReason"] == nil)
        let activation = try #require(object["activation"] as? [String: Any])
        #expect(activation["state"] as? String == "pausedBySonny")
        #expect(activation["reason"] as? String == "Zip output already exists at /tmp/a.zip.")
        // The surrounding record is untouched by the fold.
        #expect(object["cadence"] as? String == "daily")
        #expect(object["hour"] as? Int == 9)
        #expect(object["unattendedTrusted"] as? Bool == false)
    }

    @Test
    func anEnabledStateEncodesWithoutAReasonKeyAtAll() throws {
        var enabled = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        enabled.setEnabled(true, now: Self.anchored)

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(enabled)) as? [String: Any]
        )
        let activation = try #require(object["activation"] as? [String: Any])

        #expect(activation["state"] as? String == "enabled")
        #expect(activation["reason"] == nil)
    }

    /// A paused state with no reason is exactly what this type forbids, so inventing one at the
    /// decoder would reintroduce the bug through the back door. Same for a `state` this build does
    /// not know: per the store convention a load that cannot be decoded is surfaced, never
    /// collapsed into a default.
    @Test
    func amalformedActivationIsADecodeFailureRatherThanAGuess() {
        let pausedWithNoReason = """
        {
          "cadence": "daily", "hour": 9, "minute": 0, "unattendedTrusted": false,
          "activation": { "state": "pausedBySonny" }
        }
        """
        let unknownState = """
        {
          "cadence": "daily", "hour": 9, "minute": 0, "unattendedTrusted": false,
          "activation": { "state": "hibernating" }
        }
        """

        for json in [pausedWithNoReason, unknownState] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(RoutineSchedule.self, from: Data(json.utf8))
            }
        }
    }

    // MARK: - The invariant the fold makes structural

    /// The runtime shadow of a compile-time property. `RoutineSchedule` has no door that produces
    /// enabled-and-paused: `init` takes `isEnabled: Bool` and no reason, `activation` is
    /// `private(set)`, and the only mutators are `setEnabled(_:now:)` and `pause(reason:)`. So this
    /// asserts the derivations agree across every state reachable at all — which, with the enum,
    /// is every state that exists.
    @Test
    func noReachableScheduleIsBothEnabledAndPaused() {
        var enabled = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        enabled.setEnabled(true, now: Self.anchored)
        var paused = enabled
        paused.pause(reason: "Anything.")
        var resumed = paused
        resumed.setEnabled(true, now: Self.anchored)
        var userDisabled = enabled
        userDisabled.setEnabled(false, now: Self.anchored)
        let fromCreation = RoutineSchedule.newlyCreated(
            cadence: .daily,
            hour: 9,
            minute: 0,
            isEnabled: true,
            pausedReason: "Anything.",
            now: Self.anchored
        )
        let decodedFromIllegalLegacy = try? decodeLegacySchedule(isEnabled: true, pausedReason: "Anything.")

        let every = [enabled, paused, resumed, userDisabled, fromCreation, decodedFromIllegalLegacy].compactMap { $0 }
        #expect(every.count == 6)
        for schedule in every {
            #expect(!(schedule.isEnabled && schedule.isPausedBySonny))
            // The two accessors are one value seen two ways, so they can never disagree either.
            #expect(schedule.isPausedBySonny == (schedule.pausedReason != nil))
            #expect(schedule.isEnabled == (schedule.activation == .enabled))
        }
        // ...and the states are genuinely distinct, so the loop above is not passing on six copies
        // of the same value.
        #expect(enabled.activation == .enabled)
        #expect(paused.activation == .pausedBySonny(reason: "Anything."))
        #expect(userDisabled.activation == .disabledByUser)
    }

    // MARK: - Through the store




    // MARK: - Helpers

    private static let anchored = Date(timeIntervalSince1970: 1_700_000_000)

    private static let legacyStepJSON = """
    { "id": "open", "operation": "open_app", "description": "Open Safari.", "appName": "Safari" }
    """

    /// A schedule in the pre-SONNY-46 encoded shape: `isEnabled` and `pausedReason`, no
    /// `activation` key. Written as a literal rather than produced by an encoder on purpose — the
    /// encoder that wrote these files no longer exists, and a fixture generated by today's code
    /// could not pin yesterday's format.
    private func legacyScheduleJSON(isEnabled: Bool, pausedReason: String?) -> String {
        let reasonLine = pausedReason.map { ",\n  \"pausedReason\": \"\($0)\"" } ?? ""
        return """
        {
          "cadence": "daily",
          "hour": 9,
          "minute": 0,
          "isEnabled": \(isEnabled),
          "unattendedTrusted": true,
          "lastRunAt": \(Self.anchored.timeIntervalSinceReferenceDate)\(reasonLine)
        }
        """
    }

    private func decodeLegacySchedule(isEnabled: Bool, pausedReason: String?) throws -> RoutineSchedule {
        try JSONDecoder().decode(
            RoutineSchedule.self,
            from: Data(legacyScheduleJSON(isEnabled: isEnabled, pausedReason: pausedReason).utf8)
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutineActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension AgentStep {
    static let fixture = AgentStep(
        id: "open",
        operation: .openApp,
        description: "Open Safari.",
        appName: "Safari"
    )
}

/// A routine in the pre-SONNY-46 encoded shape, as an `Encodable` so it can be written through the
/// real `LocalStorageEncryption`. The encoder that produced these files no longer exists, so the
/// shape is declared here rather than generated by today's types — a fixture built from
/// `RoutineSchedule` would emit `activation` and pin nothing.
///
/// `pausedReason` is Optional so synthesized `Encodable` omits the key entirely when nil, which is
/// exactly what a schedule written before that field existed looks like on disk.
private struct LegacyRoutineFixture: Encodable {
    struct Schedule: Encodable {
        let cadence = "daily"
        let hour = 9
        let minute = 0
        let isEnabled: Bool
        let unattendedTrusted = true
        let lastRunAt: Date
        let pausedReason: String?
    }

    let name: String
    let steps: [AgentStep]
    let schedule: Schedule

    init(name: String, isEnabled: Bool, pausedReason: String?, at lastRunAt: Date) {
        self.name = name
        self.steps = [.fixture]
        self.schedule = Schedule(isEnabled: isEnabled, lastRunAt: lastRunAt, pausedReason: pausedReason)
    }
}

/// The same file-private fixed key manager `LocalStorageSecurityTests`, `ClipboardHistoryTests`,
/// `AgentViewModelLocalStorageTests` and `ProductShellTests` each declare — one per test file is
/// the established pattern here, not a variant. A literal key keeps the test hermetic and off the
/// real login Keychain.
private struct FixedRoutineActivationKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}
