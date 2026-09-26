import Foundation

public struct CapabilityRiskEscalation: Codable, Equatable, Sendable {
    /// What kind of consequence this escalation is warning about — the axis the founder's
    /// consequence rule (2026-08-13) gates on. The kernel raises an operation's effect to
    /// `destructive` or `external` from these (`AdapterCapabilities`), and the action gate asks
    /// from there.
    public enum Consequence: String, Codable, CaseIterable, Equatable, Sendable {
        /// Destroys or replaces something the user already has: a file overwrite, a
        /// replace-on-save of a routine or snippet, a deletion.
        case destructive
        /// Reaches someone other than the user: send, post, share, publish, purchase. Carried by
        /// `create_reminder`'s escalation, because the default Reminders list may be shared and
        /// EventKit cannot say whether it is (SONNY-453; the founders chose this class for it on
        /// 2026-09-13).
        case affectsOthers = "affects_others"
        /// A fact worth telling the user, not a consent worth interrupting them for, such as an
        /// out-of-scope resource. Advisory escalations still raise `effectiveTier` honestly; they
        /// do not raise the operation's effect.
        case advisory
    }

    public var fromTier: CapabilityRiskTier
    public var toTier: CapabilityRiskTier
    public var reason: String
    /// Non-defaulted in the initializer deliberately: every construction site must classify its
    /// consequence, so a new escalation cannot land unclassified. When genuinely unsure, classify
    /// `.destructive`/`.affectsOthers` (fail closed: ask) and flag it, never `.advisory`.
    public var consequence: Consequence

    public init(
        fromTier: CapabilityRiskTier,
        toTier: CapabilityRiskTier,
        reason: String,
        consequence: Consequence
    ) {
        self.fromTier = fromTier
        self.toTier = toTier
        self.reason = reason
        self.consequence = consequence
    }
}

public struct CapabilityRiskAssessment: Codable, Equatable, Sendable {
    public var defaultTier: CapabilityRiskTier
    public var effectiveTier: CapabilityRiskTier
    public var escalations: [CapabilityRiskEscalation]

    public init(
        defaultTier: CapabilityRiskTier,
        effectiveTier: CapabilityRiskTier? = nil,
        escalations: [CapabilityRiskEscalation] = []
    ) {
        self.defaultTier = defaultTier
        self.effectiveTier = effectiveTier ?? Self.highestTier(defaultTier: defaultTier, escalations: escalations)
        self.escalations = escalations
    }

    private static func highestTier(
        defaultTier: CapabilityRiskTier,
        escalations: [CapabilityRiskEscalation]
    ) -> CapabilityRiskTier {
        let highestRaw = escalations
            .map(\.toTier.rawValue)
            .reduce(defaultTier.rawValue, max)
        return CapabilityRiskTier(rawValue: highestRaw) ?? defaultTier
    }
}
