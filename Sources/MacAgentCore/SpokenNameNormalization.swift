import Foundation

/// The one definition of the words a person puts in front of a name that are never part of the name.
///
/// `InstantCommandResolver` reads it for app, routine and Shortcut names — "open my Safari" means
/// Safari.
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
}
