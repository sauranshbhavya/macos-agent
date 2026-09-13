import Foundation
import MacAgentCore

/// One row of the Skills page, as values a test can assert rather than literals inside a view
/// (SONNY-452).
struct SkillRowPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let caption: String
    let isAdded: Bool

    /// The row's one button. Add and Remove are the same control in two states, so the row never
    /// carries both.
    var buttonTitle: String { isAdded ? "Remove" : "Add" }

    /// Spoken with the site's name, so a list of identical "Add" buttons is not a list a screen
    /// reader cannot tell apart.
    var buttonAccessibilityLabel: String { "\(buttonTitle) \(title)" }

    static let addedBadge = "Added"
    static let searchPrompt = "Search skills"
    static let noMatchTitle = "No skills match"
    static let noMatchMessage = "Try the site's name or its web address."

    /// Every shipped pack whose name, domain, one line or trigger words contain the query, folded the
    /// way every other search in the app folds — in the catalogue's name order. A blank query lists
    /// every pack.
    @MainActor
    static func rows(for viewModel: AgentViewModel, query: String) -> [SkillRowPresentation] {
        rows(packs: viewModel.skillPackCatalog.packs, addedIDs: Set(viewModel.addedSkills.map(\.id)), query: query)
    }

    static func rows(packs: [SkillPack], addedIDs: Set<String>, query: String) -> [SkillRowPresentation] {
        let needle = SearchText.normalizedQuery(query)
        return packs
            .filter { pack in
                guard !needle.isEmpty else { return true }
                return ([pack.name, pack.domain, pack.summary] + pack.triggers)
                    .contains { SearchText.normalized($0).contains(needle) }
            }
            .map { pack in
                SkillRowPresentation(
                    id: pack.id,
                    title: pack.name,
                    caption: pack.summary,
                    isAdded: addedIDs.contains(pack.id)
                )
            }
    }
}
