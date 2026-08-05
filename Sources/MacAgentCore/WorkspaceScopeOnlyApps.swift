import Foundation

/// The one place that answers "is this workspace app name launchable, or scope-only?", plus the
/// wording both sides of that answer use.
///
/// **Scope listing and the launch catalog are deliberately decoupled** (founder decision,
/// 2026-08-05, recorded on SONNY-44). A workspace may list an app `MacAppCatalog` does not carry,
/// for scope membership only; the catalog keeps exactly one meaning — the allowlist of what Sonny
/// may *launch* — and listing an app in a workspace grants no launch capability whatsoever.
///
/// That decision solves a class rather than an instance. `convert_docx_to_pdf` AppleScript-drives
/// Microsoft Word from a hardcoded `/Applications/Microsoft Word.app`, so `PlanScopedResources`
/// reports Word as an app resource with no plan field naming it. Until this shipped, no workspace
/// could ever *list* Word — so once SONNY-37 wires the scope verdict into risk assessment, every
/// DOCX conversion inside an apps-listing workspace would have escalated to tier 3 forever with
/// nothing the user could do to clear it. Any future AppleScript-driven app has the same shape.
/// Widening `MacAppCatalog` instead was considered and declined: it would turn every future listing
/// gap into a capability grant.
///
/// Two call sites read this rule — `CreateWorkspaceCapabilityAdapter` (what may be listed) and
/// `OpenWorkspaceCapabilityAdapter` (what actually launches). They live here together rather than as
/// two `try? resolve` calls that can drift apart, and so the user-facing wording for "scope only"
/// is written once.
public enum WorkspaceScopeOnlyApps {
    /// The names `catalog` cannot resolve, in the order given.
    ///
    /// Note what this is deliberately *not*: a typo detector. "Microsft Word" and "Microsoft Word"
    /// are equally unresolvable and nothing here can tell them apart. That is precisely why the
    /// result is surfaced as a soft note rather than swallowed — an unvalidated name that never
    /// matches anything sits inertly inside a security boundary, and the note is the only thing
    /// that makes it observable at the moment it is typed. It is never a hard failure: refusing the
    /// name is the behavior the 2026-08-05 decision exists to remove.
    public static func names(in appNames: [String], catalog: MacAppCatalog) -> [String] {
        appNames.filter { (try? catalog.resolve($0)) == nil }
    }

    /// The soft signal naming every scope-only entry at once, or `nil` when they all resolve.
    ///
    /// Worded to explain the *status*, not just the miss: a user who typed a real app name needs to
    /// know it still counts for scope (so the workspace boundary they just drew is intact), and a
    /// user who typo'd needs enough to notice. "Sonny can't launch it" alone would read as a
    /// rejection of exactly the thing the decision now permits.
    ///
    /// Used by both the create and open previews, and by the creation act log. The open *execution*
    /// path uses `openSkipNote` instead — see there for why the two are worded differently.
    public static func scopeOnlyNote(for scopeOnlyNames: [String]) -> String? {
        guard !scopeOnlyNames.isEmpty else {
            return nil
        }
        let names = scopeOnlyNames.joined(separator: ", ")
        let subject = scopeOnlyNames.count == 1 ? "isn't an app" : "aren't apps"
        return "\(names) \(subject) Sonny can launch — counted for workspace scope only."
    }

    /// The open-time skip line for one scope-only entry.
    ///
    /// Follows the SONNY-9 fallback precedent: opening the rest of a workspace beats failing an
    /// otherwise-good open, so this is logged and the open continues. Separate wording from
    /// `scopeOnlyNote` on purpose, and per entry rather than collapsed: this line is interleaved
    /// with the "Opening …" lines in the act log, so it has to read as one event in a launch
    /// sequence ("why did that one not appear?") rather than as a summary of the whole list.
    public static func openSkipNote(for storedName: String) -> String {
        "Skipping \(storedName) — not an app Sonny can launch; it counts for workspace scope only."
    }
}
