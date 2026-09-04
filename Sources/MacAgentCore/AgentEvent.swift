import Combine
import Foundation

public enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case plan
    case validate
    case risk
    case preview
    case confirm
    case act
    case observe
    case summarize
}

public struct AgentEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var phase: AgentPhase
    public var message: String

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        phase: AgentPhase,
        message: String
    ) {
        self.id = id
        self.date = date
        self.phase = phase
        self.message = message
    }
}

@MainActor
public final class AgentLogStore: ObservableObject {
    @Published public private(set) var events: [AgentEvent]

    public init(events: [AgentEvent] = []) {
        self.events = events
    }

    public func append(_ phase: AgentPhase, _ message: String) {
        events.append(AgentEvent(phase: phase, message: message))
    }

    public func reset() {
        events.removeAll()
    }
}

/// One document a capability converts, and where its output lands.
///
/// The destination is the *file*, not its folder — this type states what the run will do, and
/// `RunClaims` decides which part of that is the claim's key (see ``ConversionClaim``). Keeping the
/// narrowing there rather than here means a reader of a preview sees the real destination and only
/// the claim logic has an opinion about it.
public struct ConvertedSource: Equatable, Sendable {
    public var sourcePath: String
    public var destinationPath: String

    public init(sourcePath: String, destinationPath: String) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

public struct ActionPreview: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var details: [String]
    public var writes: [String]
    public var opens: [String]
    public var conversions: [String]
    /// What this preview's capability will convert, as identities rather than as display text
    /// (SONNY-76, PR #65 review F1).
    ///
    /// Parallel to `conversions`, which carries the same information formatted for a human as
    /// `"<source> -> <destination>"`. The executor needs these as identities to stop a later chain
    /// unit re-converting a document an earlier one already did, and deriving that from the display
    /// string would mean splitting on `" -> "` — a separator that is legal inside a macOS filename
    /// and that exists to be read, not parsed. A correctness decision taken from a presentation
    /// format is the shape that already bit this repo once, where a `grep '^designated'` silently
    /// dropped the very case its warning existed for because the display form differed.
    ///
    /// **Source and destination travel together in one value** (PR #65 re-check, F5), rather than as
    /// this array and `writes` read positionally. The claim the executor builds from it needs both
    /// halves, and a pair spread across two arrays is a correspondence nothing enforces — the same
    /// class of implicit contract as parsing the display string, one step quieter.
    ///
    /// Empty for every capability that does not convert a source, which is all of them but one.
    public var convertedSources: [ConvertedSource]

    public init(
        id: UUID = UUID(),
        title: String,
        details: [String] = [],
        writes: [String] = [],
        opens: [String] = [],
        conversions: [String] = [],
        convertedSources: [ConvertedSource] = []
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.writes = writes
        self.opens = opens
        self.conversions = conversions
        self.convertedSources = convertedSources
    }

    public var sideEffects: [String] {
        writes.map { "Write: \($0)" } + opens.map { "Open: \($0)" } + conversions.map { "Convert: \($0)" }
    }
}

public struct AgentRunResult: Equatable, Sendable {
    public var plan: AgentPlan
    public var previews: [ActionPreview]
    public var summary: String
    /// Who wrote `summary` (SONNY-147).
    ///
    /// **Declared where the text is authored, and carried from there**, because by the time this
    /// value becomes a `CompletedTaskRecord.result` the string has passed through three layers and
    /// nothing downstream can tell a model's sentence from an adapter's template.
    ///
    /// **Defaulted to `.codeAuthored`, and the enumeration is what makes that honest rather than
    /// convenient.** At `ef0cf7c`, `grep -rn "AgentRunResult(" Sources | wc -l` finds 27
    /// construction sites: 26 interpolate counts, names and paths into templates written in this
    /// repository, and one — `VisionSessionCapabilityAdapter.swift:278` — carries free text a model
    /// composed after reading the user's screen. Two of those 26 do not author at all, they
    /// *forward*: `RunRoutineCapabilityAdapter` wraps a nested run's summary in a sentence of its
    /// own, and `AgentActionExecutor.executeChain` joins one summary per chain segment. Both pass
    /// this field through, so a routine carrying a screen-control step and a chain with a vision
    /// segment both come out `.modelAuthored`. A default that a new model-authored producer forgets
    /// to override would be a real hole; the defence is that this comment, the type's own
    /// enumeration and `theOnlyModelAuthoredRunSummaryIsTheVisionSessions` all point at the same
    /// list.
    ///
    /// **That scan is a backstop, not the guard** (SONNY-200). It is textual, and a list of
    /// property spellings kept missing shapes — most recently `executeChain`'s own accumulator,
    /// `var summaryProvenance: StoredTaskResult.Provenance = .codeAuthored`, whose type annotation
    /// sits between the name and the value and matched neither search term. It now counts mentions
    /// of the *value* instead, which has no spelling hole. The guard on the chain's behaviour is a
    /// pair of tests that never look at source at all:
    /// `VisionSessionRunTests.aChainWhoseScreenControlSegmentWrotePartOfTheSummaryStoresItAsModelAuthored`
    /// for a segment raising the join, and
    /// `AgentActionExecutorTests.anOrdinaryChainsJoinedSummaryStaysCodeAuthored` for two ordinary
    /// segments leaving it alone.
    public var summaryProvenance: StoredTaskResult.Provenance
    public var suggestions: [RunSuggestion]
    /// The items of a job over many items that could not be done, in the order they failed
    /// (SONNY-235). Empty for every run that is not a job, and for a job in which nothing failed.
    ///
    /// **Here as well as in the stored record, and the two are not two homes for one fact.** This is
    /// what *this* run reports when it returns — what the summary is authored from and what a
    /// surface renders honestly rather than by reading a sentence. `ResumableTask.itemJobFailures`
    /// is the durable checkpoint, written as the run goes, which is the only thing left when a job
    /// is interrupted at item thirty and never returns a result at all. `executeChain` accumulates
    /// once and feeds both.
    public var itemJobFailures: [ItemJobFailure]

    public init(
        plan: AgentPlan,
        previews: [ActionPreview],
        summary: String,
        summaryProvenance: StoredTaskResult.Provenance = .codeAuthored,
        suggestions: [RunSuggestion] = [],
        itemJobFailures: [ItemJobFailure] = []
    ) {
        self.plan = plan
        self.previews = previews
        self.summary = summary
        self.summaryProvenance = summaryProvenance
        self.suggestions = suggestions
        self.itemJobFailures = itemJobFailures
    }

    /// This run's summary as it will be stored, with the provenance it was authored under.
    public var storedResult: StoredTaskResult {
        StoredTaskResult.declaring(summaryProvenance, text: summary)
    }
}

public struct RunSuggestion: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: RunSuggestionKind
    public var value: String

    public init(
        id: UUID = UUID(),
        title: String,
        kind: RunSuggestionKind,
        value: String
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
    }
}

public enum RunSuggestionKind: String, Codable, Equatable, Sendable {
    case revealInFinder
    case openFile
}
