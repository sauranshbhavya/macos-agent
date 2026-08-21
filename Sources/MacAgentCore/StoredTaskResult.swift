import Foundation

/// What a finished task produced, stored with **a declaration of where the text came from**
/// (SONNY-147).
///
/// **Why this is not a `String`.** Row I's lesson, recorded in
/// `docs/sonny-v1-implementation-changelog.md` and restated on `PriorTaskContext.escapeForPlanner`,
/// is that "a structural guarantee is only as wide as the type that carries it":
/// `plannerContextText` escaped two of its four interpolated fields and skipped two, which was
/// harmless for as long as every run summary was a code-authored adapter template and stopped being
/// harmless the day a model that had just read the user's screen wrote one. Persisting a summary
/// widens that surface along a new axis — the live exposure was bounded to
/// `PriorTaskContext.defaultExpirationInterval`, and a stored one has no bound at all. So the text
/// travels with a statement of what kind of text it is, and a reader that is not
/// `plannerContextText` can refuse to treat model-authored text as trusted.
///
/// **What it buys, and what it cannot.** It forces every writer to say which kind it has. It does
/// **not** verify that redaction happened, because by this point nothing can: a vision session's
/// summary is de-redacted to a plain `String` at `VisionSessionRunner.swift:34,37` before it ever
/// becomes `AgentRunResult.summary`, and `RedactedPayload` is deliberately not `Codable` — its own
/// comment says a `Decodable` conformance would be "a public initializer in disguise". Do not make
/// that type `Codable` to close this gap; the precedent to copy is `RedactionReportEntry`, which is
/// `Codable` by design while the payload it summarises is not. Persist a narrower type, never the
/// payload.
///
/// **No plain-`String` initialiser**, deliberately: the memberwise initialiser is suppressed by the
/// `private init` below, so a call site must name a provenance. `declaring(_:text:)` exists for the
/// one seam that is handed a provenance rather than knowing one — see its own comment.
public struct StoredTaskResult: Codable, Equatable, Sendable {
    /// Who wrote this text.
    ///
    /// **The line is who composed the prose, not whether any substring came from a model** — and
    /// that distinction has to be stated, because the looser reading makes the whole enum useless.
    /// Nearly every code-authored summary interpolates a value a planner chose: "Zipped 5 files to
    /// …/Desktop/large-files.zip" gets its path from the plan, and `AgentPlan` is what a model
    /// returned. So does an error's `localizedDescription`, including
    /// `VisionDecisionParseError.unknownAction`, which prints the action name the model asked for
    /// inside a sentence this repository wrote. Under a "contains nothing model-derived" reading
    /// almost nothing would qualify as code-authored. Under this one the cases separate the thing
    /// that actually matters: `.modelAuthored` text can be an entire injected paragraph, while a
    /// `.codeAuthored` template bounds a model's contribution to the slots it interpolates.
    ///
    /// Two cases rather than a spectrum, because only one distinction changes what a reader may do
    /// with the value: whether a model composed it. Enumerated at `ebd6c1d` — `grep -rn
    /// "AgentRunResult(" Sources | wc -l` finds 27 construction sites, 26 of which interpolate
    /// counts, names and paths into code-authored templates, and exactly one of which
    /// (`VisionSessionCapabilityAdapter.swift:278`) carries free text a model wrote after reading
    /// the user's screen. Two more sites *propagate* a provenance they were handed rather than
    /// authoring one: `RunRoutineCapabilityAdapter` wraps a nested run's summary in its own
    /// sentence, and `AgentActionExecutor.executeChain` joins one summary per chain segment. Both
    /// carry `.modelAuthored` forward when any part of what they joined was, which is why the
    /// enumeration above is about *authorship* and not about which file the string was assembled in.
    /// Of those two only the chain is reachable today: a plan may mix ordinary steps with a vision
    /// step, and `AgentActionExecutor.visionSplitDisclosure` writes the sentence that describes that
    /// shape to the user, while `StoredRoutine.forbiddenStepOperations` refuses `.visionSession`
    /// inside a routine outright. The routine wrapper forwards anyway, for the reason written there.
    public enum Provenance: String, Codable, Equatable, Sendable, CaseIterable {
        /// Free-form prose a model composed. Untrusted input wearing the shape of a result.
        case modelAuthored = "model_authored"
        /// A sentence this repository composed, with counts, names and paths interpolated into its
        /// slots — including values a planner chose, and including an error's own description.
        case codeAuthored = "code_authored"
    }

    /// The stored text's ceiling, in characters.
    ///
    /// **A cap exists because exactly one producer is unbounded** and because
    /// `TaskHistoryStore.record(_:)` decodes and re-encrypts the entire history file on every
    /// finished task — so one pathological model response would not merely be large once, it would
    /// tax every future task for as long as it stayed in the window.
    ///
    /// **1,000 rather than something tighter, and the arithmetic that picked it.** Record size is
    /// additive in this field: SONNY-119 measured today's record at 374 bytes encoded through
    /// `TaskHistoryStore`'s real encoder (at `36cef9e`), and its own table's "+ result 200 chars"
    /// row lands at exactly 374 + 200 + the steps it also added, so a stored result costs its own
    /// length and essentially nothing else. 1,000 therefore bounds a record at ~1.4 kB and the file
    /// at ~13 MiB when a user is at the 10,000-record cap — against ~3.6 MiB today, and against the
    /// ~40 MiB the pre-split design measured at. Typical is far below it: real summaries are one to
    /// three sentences naming a path, so the cap bounds the outlier without touching the common
    /// case, which is what the ticket asked for.
    ///
    /// Truncation happens **at storage time, not at render time** — including on the decode path
    /// below, so a value that reached the file by some other route is bounded when it is read back
    /// rather than only when it is written.
    public static let maxTextLength = 1_000

    public let provenance: Provenance
    public let text: String

    private init(provenance: Provenance, text: String) {
        self.provenance = provenance
        self.text = Self.capped(text)
    }

    /// Free text a model composed.
    public static func modelAuthored(_ text: String) -> StoredTaskResult {
        StoredTaskResult(provenance: .modelAuthored, text: text)
    }

    /// A deterministic string this repository built.
    public static func codeAuthored(_ text: String) -> StoredTaskResult {
        StoredTaskResult(provenance: .codeAuthored, text: text)
    }

    /// For the seam that carries a provenance it was handed rather than one it knows — the point
    /// where an `AgentRunResult` becomes a stored record. The provenance is still named at the call
    /// site; it is simply named by a value that travelled from the adapter that authored the text
    /// instead of by a literal. Nothing here weakens the rule the two factories above enforce: there
    /// is no way to build one of these without a provenance.
    public static func declaring(_ provenance: Provenance, text: String) -> StoredTaskResult {
        StoredTaskResult(provenance: provenance, text: text)
    }

    private enum CodingKeys: String, CodingKey {
        case provenance
        case text
    }

    /// Written out rather than synthesized so the decode path runs through the same cap the writers
    /// do. A synthesized `init(from:)` would assign `text` directly and hand back a value the type's
    /// own initialisers could not have produced.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provenance: try container.decode(Provenance.self, forKey: .provenance),
            text: try container.decode(String.self, forKey: .text)
        )
    }

    private static func capped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTextLength else {
            return trimmed
        }
        // The ellipsis is the signal, and it is inside the budget rather than beyond it — a cap that
        // its own truncation marker can push past is not a cap.
        return String(trimmed.prefix(maxTextLength - 1)) + "\u{2026}"
    }
}
