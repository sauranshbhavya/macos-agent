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

/// When a saved routine runs on its own, and whether it is allowed to do so unattended.
///
/// `unattendedTrusted` is the per-routine opt-in that lets a scheduled trigger bypass the tier-2
/// gate a manual click keeps — running a saved routine is *itself* tier 2 by default, independent
/// of its steps (`RunRoutineCapabilityAdapter.defaultRiskTier`), so without an explicit exception
/// every scheduled run would simply stall waiting for an approval nobody is there to give. It is
/// deliberately per-routine rather than a blanket policy, and it is never a tier-3+ exception:
/// that backstop lives in `AgentRunner`, which re-assesses at execute time and requires the
/// approved tier to be at least the effective tier, so an unattended run can only ever carry a
/// tier-2 approval and structurally cannot execute a tier-3+ plan.
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
    public var isEnabled: Bool
    public var unattendedTrusted: Bool
    /// The catch-up baseline: the scheduler treats occurrences after this instant as candidates
    /// for a missed run. Set by `setEnabled(_:now:)` on every off → on transition, never left nil
    /// while enabled — see that method for why that matters.
    public var lastRunAt: Date?
    /// Why Sonny switched this schedule off by itself, in the user's words, or nil when the
    /// schedule's state is the user's own doing.
    ///
    /// Non-nil implies `isEnabled == false`: the only writer is `pause(reason:)`, which disables,
    /// and `setEnabled(true, now:)` clears it. Optional for the same decoding reason as `schedule`
    /// and `recentRunDates` on `StoredRoutine` — synthesized `Decodable` calls `decodeIfPresent`
    /// for an Optional property, so a routines.json written before this field existed still
    /// decodes, where a non-Optional with a Swift-side default would throw `keyNotFound`.
    public var pausedReason: String?

    public init(
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int? = nil,
        dayOfMonth: Int? = nil,
        isEnabled: Bool = false,
        unattendedTrusted: Bool = false,
        lastRunAt: Date? = nil,
        pausedReason: String? = nil
    ) {
        self.cadence = cadence
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.dayOfMonth = dayOfMonth
        self.isEnabled = isEnabled
        self.unattendedTrusted = unattendedTrusted
        self.lastRunAt = lastRunAt
        self.pausedReason = pausedReason
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
        isEnabled = enabled
        if enabled {
            pausedReason = nil
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
        isEnabled = false
        pausedReason = reason
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
