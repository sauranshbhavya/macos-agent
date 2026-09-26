import Foundation

/// The one definition of the words a person puts in front of a name that are never part of the name.
///
/// `InstantCommandResolver` reads it for app, routine and Shortcut names — "open my Safari" means
/// Safari — and `SpokenPath` reads it for folders, so "my Desktop" means `Desktop` (SONNY-242).
/// One list, so a word added for one reading is a word the other gains.
public enum SpokenName {
    /// The possessive determiners a speaker can use for something of their own, plus the definite
    /// article.
    ///
    /// Closed over a stated rule rather than collected by anecdote, which is what makes it
    /// reviewable: a person naming their own folder to their own assistant reaches for a
    /// first-person or second-person possessive, or for "the". The third-person possessives —
    /// "his", "her", "their", "its" — are deliberately absent, because no command of that shape
    /// refers to a folder Sonny can reach, and a name that genuinely starts with one would be
    /// damaged by stripping it.
    static let leadingArticles = ["my", "the", "our", "your"]

    /// The words a person appends to a folder's name when they are describing it rather than
    /// spelling it: "my downloads folder" is `Downloads`, not `downloads folder`.
    ///
    /// Two words, both spoken. "dir" is absent on purpose — it is typed shorthand, and someone who
    /// types `dir` is typing a path, not describing one.
    static let trailingFolderNouns = ["folder", "directory"]

    /// A name as the user said it, with one leading possessive or article removed.
    ///
    /// Case-insensitive on the match and case-preserving on what survives: "My Desktop" and "MY
    /// Desktop" both leave `Desktop`, never `desktop`. Only the separated *word* is lowercased and
    /// compared, never a prefix of the original, because lowercasing is not always
    /// length-preserving and a prefix comparison has to drop exactly the characters it matched.
    ///
    /// **The separator is any whitespace, not a literal space** (PR #106 review, F5). Dictation and
    /// pasted rich text produce U+00A0, and "my\u{00A0}Desktop" read as a folder called that under
    /// the first version of this — the same family as the case folding above, and invisible on
    /// screen. `rangeOfCharacter(from: .whitespacesAndNewlines)` covers every Unicode space
    /// separator, and the trims at both ends already did.
    ///
    /// **One article, not a loop, and that is this function's contract rather than an oversight.**
    /// Its callers in `InstantCommandResolver` keep the original candidate *beside* the stripped one
    /// and match both against a store, so a routine really called `The Archive` is still found by
    /// its own name; stripping to a fixed point there would spend that candidate for nothing.
    /// `SpokenPath` needs the opposite — one surviving string, so it applies this to a fixed point
    /// itself and says why.
    public static func withoutLeadingArticle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) else {
            return trimmed
        }
        guard leadingArticles.contains(String(trimmed[..<separator.lowerBound]).lowercased()) else {
            return trimmed
        }
        let remainder = String(trimmed[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return trimmed
        }
        return remainder
    }

    /// A name with one trailing "folder"/"directory" removed, under the same case and separator
    /// rules as above.
    static func withoutTrailingFolderNoun(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) else {
            return trimmed
        }
        guard trailingFolderNouns.contains(String(trimmed[separator.upperBound...]).lowercased()) else {
            return trimmed
        }
        let remainder = String(trimmed[..<separator.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            return trimmed
        }
        return remainder
    }
}

/// A path argument as a person phrased it, turned into the path they meant (SONNY-242).
///
/// The gateway's operation catalogue tells the model to pass a path "as the user said it"
/// (`server/src/agent/operations.ts`), which is the right rule for a real path and the wrong one for
/// "zip my downloads folder": copied faithfully, that phrase resolves to `~/my downloads folder`, a
/// folder nobody has. `AdapterCapability.prepare` runs every step it builds through
/// `normalizingFolderPhrases(in:)` before an adapter resolves a path, so each typed operation that
/// takes a folder or a file reads the phrase the same way.
///
/// **Deliberately above `PathWhitelist` rather than inside it.** The whitelist's `canonical` is the
/// arithmetic every containment check compares through; a step that rewrote path *text* in there
/// would mean the security check and the thing it is checking were no longer the same string for
/// reasons no reader of either could see. Normalising before the path reaches the boundary keeps the
/// boundary's job to one question: is this resolved path inside a root.
///
/// **And it is not a prompt rule.** A sentence in the catalogue is obeyed with a probability, it is
/// untestable without a live model, and it would be wrong for a real path. This is a deterministic
/// function with a suite over it: Sonny understands a name the model faithfully copied.
public enum SpokenPath {
    /// The path a phrase means, or the phrase unchanged when it was already a path.
    ///
    /// **A `/`-absolute value is returned untouched; a `~/` one is not** (PR #106 review, F1).
    /// `PathWhitelist.expandPath` expands the tilde and resolves the rest against the same home
    /// directory a bare name goes to, so `~/my Desktop` and `my Desktop` are the *same* location, and
    /// `~/` is a spelling a model reaches for. A `~` or `~user` leading component is a home prefix
    /// rather than a name, so the component the article comes off is the one after it.
    ///
    /// The `/` guard is redundant by construction — an absolute path's first component is the empty
    /// string, which is not an article, and the `head.isEmpty` fallback below then returns the
    /// original anyway — and it is kept so the rule does not rest on how `components(separatedBy:)`
    /// treats a leading separator.
    ///
    /// The article comes off the **named component only**. `Desktop/my notes` keeps its folder:
    /// only the leading component is the one the home directory is searched for, and a possessive
    /// deeper in the path is part of a name the user really did type.
    ///
    /// The trailing noun comes off only when **nothing sits below the named component** — a bare
    /// phrase such as "my downloads folder", or "~/my downloads folder". A value with a component
    /// below it is a path someone spelled, and `Documents/Client folder` names a folder that can
    /// genuinely be called that.
    ///
    /// **Idempotent**, because a path Sonny reported back can come in again as an argument ("as an
    /// earlier step reported it"), and it must read the same the second time. So the article comes
    /// off to a fixed point rather than once: stripping once, `my The Archive` read as `The Archive`
    /// on one pass and `Archive` on the next.
    ///
    /// Stripping to a fixed point does mean a folder genuinely called `The Archive`, named
    /// relatively, reads as `Archive`. That cannot cost anybody a folder: a relative value resolves
    /// against the home directory, and the whitelist `KernelStores.capabilityContext` builds is
    /// `PathWhitelist()`, whose only roots are `Desktop` and `Documents`. `~/The Archive` and
    /// `~/Archive` are both refused, with or without this. What the strip can change is a refusal
    /// into a success — never a success into a different success.
    public static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            return trimmed
        }

        var components = trimmed.components(separatedBy: "/")
        // `~` and `~user` name the home, not a folder, so the component the user named is the next
        // one. `components(separatedBy:)` on a non-empty string always yields at least one element,
        // so index 0 is safe; index 1 is checked because "~" on its own is a whole value.
        let named = components[0].hasPrefix("~") ? 1 : 0
        guard components.indices.contains(named) else {
            return trimmed
        }

        var head = components[named]
        var stripped = SpokenName.withoutLeadingArticle(head)
        while stripped != head {
            head = stripped
            stripped = SpokenName.withoutLeadingArticle(head)
        }
        if components[(named + 1)...].allSatisfy(\.isEmpty) {
            head = SpokenName.withoutTrailingFolderNoun(head)
        }
        guard !head.isEmpty else {
            return trimmed
        }

        components[named] = head
        return components.joined(separator: "/")
    }

    /// One step's path fields: `inputPath` and `outputPath`, every field on `AgentStep` whose value
    /// is a filesystem path. A field added later and not added here is caught by
    /// `SpokenPathTests.everyPathFieldOnAStepIsNormalisedAndNothingElseIs`, which takes the property
    /// population off `Mirror` and classifies it against a table asserted in both directions.
    static func normalizingFolderPhrases(in step: AgentStep) -> AgentStep {
        var result = step
        result.inputPath = step.inputPath.map(normalized)
        result.outputPath = step.outputPath.map(normalized)
        return result
    }
}
