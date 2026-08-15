import Foundation

/// Decides what class of consequence a pending vision action carries — the input the founder's
/// standing rule gates on ("destructive or affects-others still asks, in every mode, mid-loop
/// included").
///
/// **Two independent inputs, unioned toward asking, because one of them is the model's own word for
/// it.** SONNY-92's contract says the model classifies the pending action, and it does: every
/// decision may carry a `consequence`. But that input alone cannot carry this rule. The consequence
/// rule is the one safety property that survives in *every* interaction mode — it is what Normal and
/// Power still ask about after the founder made screen control silent — and a rule whose sole input
/// is a self-report from the model being asked to obey it is decorative. Worse, the model is reading
/// a screen that may contain text written by someone else: text that talks it into "ordinary" costs
/// an attacker nothing.
///
/// So there is a second input that reads no model opinion at all — the visible label the action is
/// aimed at, matched against a vocabulary of words that name irreversible or outward-facing
/// controls. The two combine by **taking the stricter answer**, never by averaging or by letting
/// either override:
///
/// - Model says destructive, label looks ordinary → asks. The model may know something about the
///   dialog that the word "OK" does not say.
/// - Model says ordinary, label says "Delete" → asks. This is the case the whole design exists for.
/// - Neither flags anything → runs without asking in Normal and Power, and still asks in Safe,
///   because Safe's floor is applied by the approval policy afterwards and has nothing to do with
///   this classifier.
///
/// **The label is untrusted input and that is safe here, in exactly one direction.** Screen text can
/// only ever *add* an approval through this path. An attacker who controls the label can make Sonny
/// ask about a harmless click; they cannot make it stop asking about a harmful one, because removing
/// a word from the label only returns the decision to the model's own classification, which is the
/// other input. This is the same asymmetry that makes over-reporting a scope resource safe and
/// under-reporting unsafe.
public enum VisionConsequenceClassifier {
    /// Words that name a control which destroys or replaces something the user already has.
    ///
    /// Matched as whole words against the target label, case-insensitively. Whole words rather than
    /// substrings on purpose: "Undelete", "Deleted items" and a contact named "Trash" are not delete
    /// buttons, and a substring rule that fires on all of them trains the user to click through
    /// approvals — which costs more safety than it buys.
    public static let destructiveLabelWords: Set<String> = [
        "delete", "remove", "trash", "erase", "discard", "destroy", "wipe",
        "overwrite", "replace", "reset", "clear", "revoke", "uninstall",
        "unsubscribe", "deactivate", "archive", "empty", "purge", "drop",
        "forget", "eliminate", "shred"
    ]

    /// Words that name a control which reaches someone other than the user.
    public static let affectsOthersLabelWords: Set<String> = [
        "send", "post", "publish", "share", "submit", "tweet", "reply",
        "buy", "purchase", "pay", "order", "checkout", "confirm",
        "invite", "email", "message", "broadcast", "upload", "transfer",
        "book", "subscribe", "donate", "bid", "apply"
    ]

    /// The consequence class Sonny will act on for this decision.
    ///
    /// Returns `.advisory` for anything neither input flags — deliberately the same class the engine
    /// already uses for "worth telling the user, not worth interrupting them for", so an ordinary
    /// vision action's reason still reaches the ran-without-asking trace instead of vanishing.
    public static func consequence(for decision: VisionDecision) -> CapabilityRiskEscalation.Consequence {
        let fromLabel = labelConsequence(decision)
        let fromModel = decision.declaredConsequence
        return stricter(fromLabel, fromModel)
    }

    /// Whether the local, model-independent evidence alone would have asked.
    ///
    /// Exposed so the journal and the approval copy can say *why* they are asking — "the control is
    /// labelled Delete" reads very differently to a user than "the model said this is destructive",
    /// and a user who can see which one fired can tell a cautious model from a dangerous button.
    public static func labelConsequence(_ decision: VisionDecision) -> CapabilityRiskEscalation.Consequence {
        // Only actions that actually drive the machine can have a consequence. A `wait` or a `done`
        // whose target label happens to read "Delete" is not deleting anything.
        guard decision.kind.synthesizesInput else {
            return .advisory
        }

        // Typed text that ends in a Return is a submit: the newline is delivered as a real Return
        // keypress, which is what turns a composed message into a sent one. Same for an explicit
        // Enter press while text is focused. This is the case a label vocabulary alone misses
        // entirely, because there is no button label involved at all.
        if decision.kind == .type, decision.text?.hasSuffix("\n") == true {
            return .affectsOthers
        }
        if decision.kind == .key, decision.key == .enterKey {
            return .affectsOthers
        }

        let words = labelWords(in: decision.target)
        if !words.isDisjoint(with: destructiveLabelWords) {
            return .destructive
        }
        if !words.isDisjoint(with: affectsOthersLabelWords) {
            return .affectsOthers
        }
        return .advisory
    }

    /// The label split into lowercased alphabetic words.
    ///
    /// Splitting on anything non-alphabetic means "Delete…", "Delete (3)", "Send/Post" and
    /// "delete_all" all yield the word that matters, while "Undelete" correctly does not.
    static func labelWords(in label: String) -> Set<String> {
        Set(
            label
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
    }

    /// The stricter of two consequence classes, where "stricter" means "more likely to ask".
    ///
    /// `destructive` outranks `affectsOthers` outranks `advisory`. The ordering between the two
    /// asking classes never changes an approval outcome today — both have `asksFirst == true` — so
    /// it only decides which sentence the user reads. Destructive wins there because losing data is
    /// the harder consequence to undo, and the sentence should name the worse one.
    private static func stricter(
        _ first: CapabilityRiskEscalation.Consequence,
        _ second: CapabilityRiskEscalation.Consequence?
    ) -> CapabilityRiskEscalation.Consequence {
        guard let second else {
            return first
        }
        func rank(_ consequence: CapabilityRiskEscalation.Consequence) -> Int {
            switch consequence {
            case .destructive:
                return 2
            case .affectsOthers:
                return 1
            case .advisory:
                return 0
            }
        }
        return rank(first) >= rank(second) ? first : second
    }
}
