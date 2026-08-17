import Foundation

/// The one definition of how text is normalised before it is searched.
///
/// Extracted rather than copied. `RecentArtifactStore.recent(matching:)` already proved this recipe
/// — trim the query, fold away case and diacritics against the current locale, lowercase, then
/// `contains` — and SONNY-118 needed the same rule for task history. Two independently maintained
/// normalisations is the shape where one gains a locale fix or a fold option and the other does not,
/// and the user meets a search box that matches "Cafe" against "Café" on one surface and not the
/// other.
public enum SearchText {
    /// Folds a haystack or a needle to the form both are compared in.
    ///
    /// `.folding` with `.diacriticInsensitive` is what makes "café" and "cafe" the same string, and
    /// `.caseInsensitive` plus the trailing `lowercased()` is deliberate belt and braces: folding
    /// handles case for most scripts, and `lowercased()` settles the ones where it does not.
    public static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    /// A user-typed query, normalised. Whitespace is trimmed first so a stray space does not make a
    /// query match nothing.
    public static func normalizedQuery(_ raw: String) -> String {
        normalized(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
