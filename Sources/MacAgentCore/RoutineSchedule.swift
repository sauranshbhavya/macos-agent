import Foundation

public enum RoutineCadence: String, Codable, Equatable, Sendable, CaseIterable {
    case daily
    case weekly
    case monthly

    /// How long after a missed occurrence a catch-up run still makes sense.
    ///
    /// Bounded by duration rather than by "the rest of the scheduled period" on purpose: for a
    /// daily 9am routine, period-bounded catch-up would still allow a fire at 11:59pm — one
    /// occurrence, but arriving at a moment the user has no reason to expect it, which is the same
    /// unexpected-unattended-firing problem that ruled out unbounded catch-up. The principle is
    /// that a catch-up run should only happen while it still makes sense in the context it was
    /// scheduled for: a morning routine at 11am is fine, at 11pm it is not. Longer cadences
    /// tolerate longer delays, and no window reaches its own cadence length.
    public var catchUpWindow: TimeInterval {
        switch self {
        case .daily:
            return 3 * 60 * 60
        case .weekly:
            return 24 * 60 * 60
        case .monthly:
            return 3 * 24 * 60 * 60
        }
    }

    public var displayName: String {
        switch self {
        case .daily:
            return "Daily"
        case .weekly:
            return "Weekly"
        case .monthly:
            return "Monthly"
        }
    }
}

/// Whether a schedule is on, and — when it is off — whose decision that was.
///
/// One value rather than the `isEnabled: Bool` + `pausedReason: String?` pair it replaces
/// (SONNY-46). That pair carried a prose-only invariant, "a non-nil reason implies not enabled",
/// which every caller honoured and nothing enforced: both fields were public vars with a public
/// init parameter, and synthesized `Decodable` bypassed even that. The violating combination
/// compiled, decoded, and *rendered* — `RoutineRowPresentation` and `RoutineDetailView` both derive
/// "paused" from the reason alone, so an enabled schedule carrying a stale reason painted "Paused"
/// and "Sonny paused this schedule" on a routine that was still firing on time, while suppressing
/// the next-run caption that slot exists for. The row said the opposite of the truth.
///
/// As an enum the combination is not a bug to be caught, it is a value that cannot be written
/// down. It is also the shape that would have made SONNY-31's F1 — a schedule rebuilt through a
/// factory with no `pausedReason` parameter, silently dropping it — a compile error rather than a
/// silent drop.
public enum RoutineActivation: Equatable, Sendable {
    /// Firing on schedule.
    case enabled
    /// Off because the user switched it off. Needs no explanation, and deliberately carries none:
    /// attaching one would grow a "Sonny paused this" caption on every manually disabled routine.
    case disabledByUser
    /// Off because Sonny could not run it, in the user's words. Useless without the reason, which
    /// is why the reason is part of the case rather than a field alongside it.
    case pausedBySonny(reason: String)
}

/// Encoded as `{"state": "…"}` plus a `reason` for the paused case, rather than through the
/// synthesized enum representation (`{"pausedBySonny": {"reason": "…"}}`). A `routines.json` is a
/// file a person occasionally has to read while debugging a schedule, and the flat shape stays
/// legible; it also keeps the payload stable if a case is ever renamed in Swift.
///
/// A `state` this build does not know throws rather than defaulting, and a `pausedBySonny` with no
/// `reason` throws too — a paused state with no reason is precisely what this type exists to
/// forbid, so silently inventing one would reintroduce the bug through the decoder. Per the store
/// convention, a load that cannot decode is surfaced, never collapsed into empty state.
extension RoutineActivation: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case reason
    }

    private enum State: String, Codable {
        case enabled
        case disabledByUser
        case pausedBySonny
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .enabled:
            self = .enabled
        case .disabledByUser:
            self = .disabledByUser
        case .pausedBySonny:
            self = .pausedBySonny(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .enabled:
            try container.encode(State.enabled, forKey: .state)
        case .disabledByUser:
            try container.encode(State.disabledByUser, forKey: .state)
        case .pausedBySonny(let reason):
            try container.encode(State.pausedBySonny, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// When a saved routine runs on its own, and whether it is allowed to do so unattended.
///
/// `unattendedTrusted` is the per-routine trust opt-in that lets a run of this routine bypass the
/// every-run tier-2 gate — originally scheduled triggers only, and manual dispatches too since
/// SONNY-54 (the name predates that widening; it is a persisted coding key, so it keeps the old
/// spelling). Running a saved routine is *itself* tier 2 by default, independent of its steps
/// (`RunRoutineCapabilityAdapter.defaultRiskTier`), so without an explicit exception every
/// scheduled run would simply stall waiting for an approval nobody is there to give, and every
/// manual run would re-confirm on each invocation. It is deliberately per-routine rather than a
/// blanket policy, and it is never a tier-3+ exception: that backstop lives in `AgentRunner`,
/// which re-assesses at execute time and requires the approved tier to be at least the effective
/// tier, so a trusted run can only ever carry a tier-2 approval and structurally cannot execute a
/// tier-3+ plan.
public struct RoutineSchedule: Codable, Equatable, Sendable {
    public var cadence: RoutineCadence
    public var hour: Int
    public var minute: Int
    /// `Calendar` convention (Sunday == 1). Required for `.weekly`, ignored otherwise.
    public var weekday: Int?
    /// Required for `.monthly`, ignored otherwise. Values past the end of a short month are
    /// accepted here and resolved by the scheduler — "run this on the 31st" is a legitimate ask,
    /// not a reason to refuse the schedule.
    public var dayOfMonth: Int?
    /// On, off by the user, or paused by Sonny with its reason — see `RoutineActivation` for why
    /// this is one value rather than a `Bool` and a `String?`.
    ///
    /// `private(set)` so `setEnabled(_:now:)` and `pause(reason:)` stay the only mutators, which
    /// is what keeps the catch-up-baseline re-anchoring in `setEnabled` unbypassable: assigning a
    /// schedule "on" without going through it is the hazard `newlyCreated` exists to document.
    public private(set) var activation: RoutineActivation
    public var unattendedTrusted: Bool
    /// The catch-up baseline: the scheduler treats occurrences after this instant as candidates
    /// for a missed run. Set by `setEnabled(_:now:)` on every off → on transition, never left nil
    /// while enabled — see that method for why that matters.
    public var lastRunAt: Date?

    /// Firing on schedule. Derived, so "enabled" and "carrying a pause reason" cannot disagree.
    public var isEnabled: Bool {
        activation == .enabled
    }

    /// Why Sonny switched this schedule off by itself, in the user's words, or nil when the
    /// schedule's state is the user's own doing. Non-nil implies `isEnabled == false` — now
    /// structurally, because both read the same enum.
    public var pausedReason: String? {
        guard case .pausedBySonny(let reason) = activation else {
            return nil
        }
        return reason
    }

    /// The presentation-facing form of the above: Sonny switched this off and the user has to
    /// resolve it. Distinct from `!isEnabled`, which is also true for the user's own disable, and
    /// safe to render as "Paused" precisely because it cannot be true of a running schedule.
    public var isPausedBySonny: Bool {
        pausedReason != nil
    }

    /// Takes `isEnabled` rather than a `RoutineActivation` on purpose: with no way to pass a pause
    /// reason, the illegal enabled-and-paused combination has no door into the type at all.
    /// A paused schedule is produced by `pause(reason:)` or `newlyCreated(pausedReason:)` — both
    /// of which switch it off in the same motion, because that is what pausing means.
    public init(
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil,
        isEnabled: Bool = false,
        unattendedTrusted: Bool = false,
        lastRunAt: Date? = nil
    ) {
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
        self.activation = isEnabled ? .enabled : .disabledByUser
        self.unattendedTrusted = unattendedTrusted
        self.lastRunAt = lastRunAt
    }

    /// Builds a schedule for a routine that does not have one, with the catch-up baseline anchored.
    ///
    /// **Use this rather than the initializer for anything user-created.** `init` defaults
    /// `lastRunAt` to nil, and `RoutineScheduler.decision` reads a nil baseline as `.distantPast` —
    /// so `RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)` built at 3pm
    /// resolves *this morning's* 09:00 as outstanding, and either fires an immediate unattended run
    /// or posts a "did not run at its scheduled time" notice for a schedule that is seconds old.
    /// That is precisely the hazard `setEnabled(_:now:)` exists to prevent, and it is reachable
    /// through any creation path that sets `isEnabled` directly. This constructs disabled and then
    /// goes through `setEnabled`, so there is one anchoring path rather than two.
    public static func newlyCreated(
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil,
        isEnabled: Bool = true,
        unattendedTrusted: Bool = false,
        pausedReason: String? = nil,
        now: Date
    ) -> RoutineSchedule {
        var schedule = RoutineSchedule(
            cadence: cadence,
            hour: hour,
            minute: minute,
            weekday: weekday,
            dayOfMonth: dayOfMonth,
            isEnabled: false,
            unattendedTrusted: unattendedTrusted
        )
        // Applied before `setEnabled` deliberately, so the one rule about clearing a pause lives in
        // one place: enabling clears it, staying disabled keeps it. A caller rebuilding an
        // existing schedule (editing its run time) passes the old reason through here, and whether
        // it survives is then decided by the same `setEnabled` every other path uses.
        if let pausedReason {
            schedule.activation = .pausedBySonny(reason: pausedReason)
        }
        schedule.setEnabled(isEnabled, now: now)
        return schedule
    }

    /// Switches cadence, filling in whatever the new cadence requires.
    ///
    /// Weekly needs a weekday and monthly needs a day of the month; carrying over a nil from the
    /// previous cadence would produce a schedule `validate()` rejects. Defaulting from `now` means
    /// switching to Weekly gives "today's weekday", which is the least surprising answer and is
    /// always in range.
    public mutating func setCadence(_ newCadence: RoutineCadence, now: Date, calendar: Calendar = .current) {
        cadence = newCadence
        switch newCadence {
        case .daily:
            break
        case .weekly:
            if weekday == nil {
                weekday = calendar.component(.weekday, from: now)
            }
        case .monthly:
            if dayOfMonth == nil {
                dayOfMonth = calendar.component(.day, from: now)
            }
        }
    }

    /// Flips `isEnabled`, re-anchoring the catch-up baseline on every off → on transition.
    ///
    /// The anchor starts at the moment of enabling rather than at nil/zero because a nil baseline
    /// reads as "every past occurrence was missed": enabling a 9am daily routine at 3pm would
    /// immediately look like this morning's run was skipped and fire a catch-up, making the act of
    /// turning scheduling on itself the trigger for an unattended run. Re-anchoring on *re*-enable
    /// covers the same hazard at longer range — a routine switched off for three weeks and back on
    /// must not treat those three weeks as a backlog.
    ///
    /// Only an off → on transition re-anchors. An idempotent write on an already-enabled schedule
    /// leaves the baseline alone, or any incidental re-save would silently erase a pending
    /// catch-up window. Disabling keeps the old anchor rather than clearing it; the re-anchor on
    /// the way back on is what actually protects the window.
    /// Turning a schedule on is also how the user acknowledges a pause, so it clears the reason.
    /// Clearing on any `enabled == true` write rather than only on the transition means an
    /// enabled schedule can never carry a stale "Sonny paused this" caption, whatever order the
    /// writes arrive in.
    public mutating func setEnabled(_ enabled: Bool, now: Date) {
        let isTurningOn = enabled && !isEnabled
        if enabled {
            // Clearing the pause is not a special case of turning on — with one field it *is*
            // turning on, which is the point of the fold.
            activation = .enabled
        } else if activation == .enabled {
            // Only a running schedule becomes the user's own disable. A schedule that is already
            // off stays exactly as it is, so an incidental "off" write can never overwrite why
            // Sonny paused it with an anonymous user disable — which is what makes editing a
            // paused routine's run time non-destructive.
            activation = .disabledByUser
        }
        if isTurningOn {
            lastRunAt = now
        }
    }

    /// Switches the schedule off because Sonny could not run it, recording why.
    ///
    /// Distinct from `setEnabled(false, now:)`, which is the user turning their own schedule off
    /// and leaves no reason behind. The distinction is the whole point of the field: a routine the
    /// user switched off needs no explanation, and a routine Sonny switched off is useless without
    /// one.
    ///
    /// Deliberately leaves `lastRunAt` alone. The occurrence that triggered the pause has already
    /// been resolved by the caller, and the re-anchor that matters happens on the way back on, in
    /// `setEnabled`.
    public mutating func pause(reason: String) {
        activation = .pausedBySonny(reason: reason)
    }

    // MARK: - Persistence

    /// Hand-written because SONNY-46 changed the encoded shape: `isEnabled` + `pausedReason`
    /// became `activation`. Every `routines.json` on disk today carries the old pair, and this is
    /// a store whose files are encrypted and already carry one legacy-plaintext migration — the
    /// tolerant decode below is what keeps a user's existing routines from failing to load.
    ///
    /// The non-activation keys keep exactly the synthesized behaviour they had: `decode` for the
    /// required ones (so a genuinely corrupt file still throws rather than quietly defaulting) and
    /// `decodeIfPresent`/`encodeIfPresent` for the Optionals, which is what let `weekday`,
    /// `dayOfMonth` and `lastRunAt` be added tolerantly in the first place.
    private enum CodingKeys: String, CodingKey {
        case cadence
        case hour
        case minute
        case weekday
        case dayOfMonth
        case unattendedTrusted
        case lastRunAt
        case activation
        /// Read-only. The two keys `activation` replaced; never written again.
        case isEnabled
        case pausedReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cadence = try container.decode(RoutineCadence.self, forKey: .cadence)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday)
        dayOfMonth = try container.decodeIfPresent(Int.self, forKey: .dayOfMonth)
        unattendedTrusted = try container.decode(Bool.self, forKey: .unattendedTrusted)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)

        if let activation = try container.decodeIfPresent(RoutineActivation.self, forKey: .activation) {
            self.activation = activation
            return
        }

        // Legacy two-field shape. `isEnabled` is decoded rather than defaulted because every file
        // any previous build wrote has it — a file with neither key is corrupt, and throwing is
        // what the synthesized decoder did before this change.
        let wasEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let legacyReason = try container.decodeIfPresent(String.self, forKey: .pausedReason)
        switch (wasEnabled, legacyReason) {
        case (true, _):
            // The self-repair. An enabled schedule carrying a reason is the illegal state this
            // fold removes, and it is on disk in exactly one way: hand-edited, or written by some
            // future caller of the old public API. Enabled is the fact the scheduler acts on and
            // the reason is the stale half, so the reason is dropped — the same answer
            // `setEnabled(true, now:)` has always given, applied at the last door it can be.
            // Deliberately not a decode failure: a display glitch must not cost a user their
            // routines.
            self.activation = .enabled
        case (false, .some(let reason)):
            self.activation = .pausedBySonny(reason: reason)
        case (false, .none):
            self.activation = .disabledByUser
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encodeIfPresent(weekday, forKey: .weekday)
        try container.encodeIfPresent(dayOfMonth, forKey: .dayOfMonth)
        try container.encode(unattendedTrusted, forKey: .unattendedTrusted)
        try container.encodeIfPresent(lastRunAt, forKey: .lastRunAt)
        try container.encode(activation, forKey: .activation)
    }

    /// Checked at the single choke point every write goes through (`RoutineStore.save`), the same
    /// way `SnippetStore.save` validates a trigger — not in `init`, which `Decodable` bypasses.
    func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw AutomationStoreError.invalidSchedule("Run time must be a real time of day.")
        }

        switch cadence {
        case .daily:
            break
        case .weekly:
            guard let weekday, (1...7).contains(weekday) else {
                throw AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")
            }
        case .monthly:
            guard let dayOfMonth, (1...31).contains(dayOfMonth) else {
                throw AutomationStoreError.invalidSchedule("A monthly routine needs a day of the month.")
            }
        }
    }
}
