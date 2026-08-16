import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-92: the consequence classifier, which is the whole of the founder's standing rule.
///
/// The property under test in one sentence: **the model's own classification can add an approval and
/// can never remove one.** Everything below is that sentence from a different angle.
@Suite
struct VisionConsequenceClassifierTests {
    private static func decision(
        _ kind: VisionActionKind = .click,
        target: String = "",
        text: String? = nil,
        key: VisionActionKey? = nil,
        declared: CapabilityRiskEscalation.Consequence? = nil
    ) -> VisionDecision {
        VisionDecision(kind: kind, x: 1, y: 1, text: text, key: key, target: target, declaredConsequence: declared)
    }

    // MARK: - The direction that matters

    /// **The case the design exists for.** The model says a Delete button is ordinary; the label says
    /// otherwise; Sonny asks. If this ever passes with `.advisory`, the consequence rule has become
    /// decorative — an attacker who can write on the user's screen can talk the model into "ordinary"
    /// for free.
    @Test
    func aModelCallingADeleteButtonOrdinaryDoesNotStopSonnyAsking() {
        let sneaky = Self.decision(target: "Delete forever", declared: .advisory)
        #expect(VisionConsequenceClassifier.consequence(for: sneaky) == .destructive)
        #expect(VisionConsequenceClassifier.consequence(for: sneaky).asksFirst)
    }

    /// The other direction: a model that flags something the label does not is believed. It may know
    /// what the dialog behind "OK" actually does.
    @Test
    func aModelFlaggingAnInnocentLabelIsBelieved() {
        for declared in [CapabilityRiskEscalation.Consequence.destructive, .affectsOthers] {
            let flagged = Self.decision(target: "OK", declared: declared)
            #expect(VisionConsequenceClassifier.consequence(for: flagged) == declared, "\(declared)")
        }
    }

    /// Neither signal fires → ordinary, which is what lets Normal and Power run silently at all.
    @Test
    func anOrdinaryActionWithAnOrdinaryLabelIsAdvisory() {
        for target in ["Bookmarks", "Next", "Zoom in", "Settings", ""] {
            #expect(
                VisionConsequenceClassifier.consequence(for: Self.decision(.click, target: target, declared: .advisory)) == .advisory,
                "\(target)"
            )
        }
    }

    /// A missing or unparseable declaration leaves the label to decide alone — it must not be read
    /// as the model asserting "harmless".
    @Test
    func anAbsentDeclarationLetsTheLabelDecideAlone() {
        #expect(VisionConsequenceClassifier.consequence(for: Self.decision(target: "Delete", declared: nil)) == .destructive)
        #expect(VisionConsequenceClassifier.consequence(for: Self.decision(target: "Next", declared: nil)) == .advisory)
    }

    // MARK: - The vocabularies

    @Test
    func everyDestructiveWordFiresAndSaysDestructive() {
        for word in VisionConsequenceClassifier.destructiveLabelWords {
            #expect(
                VisionConsequenceClassifier.consequence(for: Self.decision(.click, target: word, declared: .advisory)) == .destructive,
                "\(word)"
            )
        }
    }

    @Test
    func everyAffectsOthersWordFiresAndSaysAffectsOthers() {
        for word in VisionConsequenceClassifier.affectsOthersLabelWords {
            #expect(
                VisionConsequenceClassifier.consequence(for: Self.decision(.click, target: word, declared: .advisory)) == .affectsOthers,
                "\(word)"
            )
        }
    }

    /// The two vocabularies must not overlap, or the same label would classify differently depending
    /// on which set is consulted first.
    @Test
    func theTwoVocabulariesAreDisjoint() {
        #expect(
            VisionConsequenceClassifier.destructiveLabelWords
                .isDisjoint(with: VisionConsequenceClassifier.affectsOthersLabelWords)
        )
    }

    /// **Whole words, not substrings**, and the near-misses are the point. A rule that fired on
    /// "Undelete" and "Deleted items" would train the user to click through approvals, which costs
    /// more safety than it buys.
    @Test
    func nearMissWordsDoNotFire() {
        for target in ["Undelete", "Deleted items", "Sender", "Resend later", "Undo", "Sendai"] {
            #expect(
                VisionConsequenceClassifier.consequence(for: Self.decision(.click, target: target, declared: .advisory)) == .advisory,
                "\(target)"
            )
        }
    }

    /// Real button labels are punctuated, capitalized and padded. The word inside still has to be
    /// found.
    @Test
    func punctuationAndCasingDoNotHideTheWord() {
        for target in ["Delete\u{2026}", "Delete (3)", "DELETE ALL", "Send/Post", "delete_all", "  Send  "] {
            #expect(
                VisionConsequenceClassifier.consequence(for: Self.decision(.click, target: target, declared: .advisory)).asksFirst,
                "\(target)"
            )
        }
    }

    // MARK: - Submission, which no button label names

    /// **The case a label vocabulary alone misses entirely.** A trailing newline is delivered as a
    /// real Return keypress, which is what turns a composed message into a sent one — and there is no
    /// button involved, so nothing in the target label could ever have caught it.
    @Test
    func typedTextEndingInReturnIsTreatedAsSending() {
        let submitted = Self.decision(.type, target: "compose field", text: "hello there\n", declared: .advisory)
        #expect(VisionConsequenceClassifier.consequence(for: submitted) == .affectsOthers)

        let unsubmitted = Self.decision(.type, target: "compose field", text: "hello there", declared: .advisory)
        #expect(VisionConsequenceClassifier.consequence(for: unsubmitted) == .advisory)
    }

    /// **A field's own label is not a button label**, and reading it as one would put an approval in
    /// front of the user for every character typed into a box labelled "Message". Pinned as its own
    /// property because the first version of the classifier did exactly that.
    @Test
    func aTextFieldsLabelIsNotReadAsAButtonLabel() {
        for target in ["Message", "Send a message", "Delete search", "Share note title"] {
            #expect(
                VisionConsequenceClassifier.consequence(
                    for: Self.decision(.type, target: target, text: "hello", declared: .advisory)
                ) == .advisory,
                "\(target)"
            )
        }
    }

    /// Delete destroys whatever is selected, with no button and no label anywhere — the destructive
    /// twin of the Return case, and reachable only by enumerating the keys.
    @Test
    func pressingDeleteIsTreatedAsDestructive() {
        #expect(
            VisionConsequenceClassifier.consequence(
                for: Self.decision(.key, key: .delete, declared: .advisory)
            ) == .destructive
        )
    }

    /// Scrolling changes what is visible and nothing else, whatever the label says.
    @Test
    func scrollingIsNeverConsequential() {
        for target in ["Delete", "Send", "Publish"] {
            #expect(
                VisionConsequenceClassifier.consequence(
                    for: Self.decision(.scroll, target: target, declared: .advisory)
                ) == .advisory,
                "\(target)"
            )
        }
    }

    @Test
    func pressingReturnIsTreatedAsSending() {
        #expect(
            VisionConsequenceClassifier.consequence(
                for: Self.decision(.key, key: .enterKey, declared: .advisory)
            ) == .affectsOthers
        )
        for key in VisionActionKey.allCases where key != .enterKey && key != .delete {
            #expect(
                VisionConsequenceClassifier.consequence(
                    for: Self.decision(.key, key: key, declared: .advisory)
                ) == .advisory,
                "\(key)"
            )
        }
    }

    // MARK: - Actions that do not act

    /// A `done` whose target label happens to read "Delete" is not deleting anything. Only actions
    /// that drive the machine can have a consequence.
    @Test
    func nonSynthesizingActionsNeverEscalateOnTheirLabel() {
        for kind in VisionActionKind.allCases where !kind.synthesizesInput {
            #expect(
                VisionConsequenceClassifier.consequence(
                    for: Self.decision(kind, target: "Delete everything", declared: .advisory)
                ) == .advisory,
                "\(kind)"
            )
        }
    }

    /// The declared-consequence input still applies to those kinds, because it is about the action
    /// rather than about a control — but since none of them synthesizes input, no approval can
    /// actually gate on it. Pinned so the asymmetry is deliberate rather than discovered.
    @Test
    func exactlyTheFourInputKindsSynthesize() {
        #expect(VisionActionKind.allCases.filter(\.synthesizesInput) == [.click, .type, .scroll, .key])
    }
}
