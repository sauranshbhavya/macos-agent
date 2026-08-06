import Foundation

/// The one place that answers "is this workspace app name launchable, or scope-only?", plus the
/// wording every surface that reports the answer uses.
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
/// two `try? resolve` calls that can drift apart, and so the user-facing wording is written once.
public enum WorkspaceScopeOnlyApps {
    /// The names `catalog` cannot resolve, in the order given, **including repeats**.
    ///
    /// Order and repeats are preserved because the open path narrates an actual walk — one log line
    /// per stored entry, in position — and collapsing here would desynchronise that from the list
    /// the user typed. The note builders dedupe for themselves.
    ///
    /// Note what this is deliberately *not*: a typo detector. "Microsft Word" and "Microsoft Word"
    /// are equally unresolvable and nothing here can tell them apart. That is precisely why the
    /// result is surfaced rather than swallowed — an unvalidated name that never matches anything
    /// sits inertly inside a security boundary, and saying it out loud is the only thing that makes
    /// it observable at the moment it is typed. It is never a hard failure: refusing the name is
    /// the behavior the 2026-08-05 decision exists to remove.
    public static func names(in appNames: [String], catalog: MacAppCatalog) -> [String] {
        appNames.filter { (try? catalog.resolve($0)) == nil }
    }

    /// The note naming every scope-only entry, or `nil` when they all resolve.
    ///
    /// Worded to explain the *status*, not just the miss: a user who typed a real app name needs to
    /// know it still counts for scope (so the workspace boundary they just drew is intact), and a
    /// user who typo'd needs enough to notice. "Sonny can't launch it" alone would read as a
    /// rejection of exactly the thing the decision now permits.
    ///
    /// Used by the create and open previews and appended to the *saved* run summary. The open run
    /// summary uses `notOpenedNote` instead — at open time the salient fact is not "this counts for
    /// scope" but "this did not start".
    public static func scopeOnlyNote(for scopeOnlyNames: [String]) -> String? {
        guard let names = listed(scopeOnlyNames) else {
            return nil
        }
        let subject = names.count == 1 ? "isn't an app" : "aren't apps"
        return "\(joined(names)) \(subject) Sonny can launch — counted for workspace scope only."
    }

    /// The note appended to a workspace-open summary, or `nil` when every entry launched.
    ///
    /// This is the one that has to carry the whole signal at open time: `AgentRunResult.summary` is
    /// the only free-text channel an adapter has that a user actually sees (both `ActionPreview` and
    /// `AgentLogStore` are rendered by nothing — see `AgentRunner.swift`'s own note on the latter),
    /// so without it the run reports "1 app(s)" and never says which of the two listed apps that
    /// was, or why.
    ///
    /// "Sees" means precisely one surface: the floating widget's result panel. Command Center
    /// renders no run summary, and its origin gating means a workspace opened from its Workspaces
    /// row shows this on no surface at all — pre-existing, applies to every run summary equally, and
    /// filed separately. Stated exactly rather than as "both surfaces", because an unverified claim
    /// about which surfaces are live is the specific mistake this note exists to undo.
    public static func notOpenedNote(for scopeOnlyNames: [String]) -> String? {
        guard let names = listed(scopeOnlyNames) else {
            return nil
        }
        let verb = names.count == 1 ? "is scope-only and was" : "are scope-only and were"
        return "\(joined(names)) \(verb) not opened."
    }

    /// The open-time skip line for one scope-only entry.
    ///
    /// Follows the SONNY-9 fallback precedent: opening the rest of a workspace beats failing an
    /// otherwise-good open, so this is logged and the open continues. Separate wording from the two
    /// note builders on purpose, and per entry rather than collapsed: this line is interleaved with
    /// the "Opening …" lines, so it has to read as one event in a launch sequence ("why did that one
    /// not appear?") rather than as a summary of the whole list.
    ///
    /// A diagnostic, not the deliverable — `AgentLogStore` has no renderer, which is exactly the
    /// mistake `notOpenedNote` exists to correct. Kept because the log is still the record a future
    /// surface (or a developer reading a run) reads.
    public static func openSkipNote(for storedName: String) -> String {
        "Skipping \(storedName) — not an app Sonny can launch; it counts for workspace scope only."
    }

    /// De-duplicated names, or `nil` when there are none.
    ///
    /// Exact-string equality, deliberately not the case-folded `MacAppCatalog.normalize` the
    /// evaluator matches on. Folding would collapse "Microsoft Word" and "microsoft word" into one
    /// line, hiding a second entry that genuinely exists in the user's list; literal repetition is
    /// the only thing worth collapsing, because it is the only thing that carries no information.
    private static func listed(_ names: [String]) -> [String]? {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    /// `A`, `A and B`, `A, B and C`.
    ///
    /// The "and" is doing real work beyond politeness. A plain `", "` join made a single
    /// unresolvable name containing a comma — "Foo, Bar", entirely possible from speech-to-text —
    /// indistinguishable from two separate entries. With this join plus the singular/plural verb the
    /// callers pick, one name reads "Foo, Bar isn't an app …" and two read "Foo and Bar aren't
    /// apps …", which tells the two cases apart without quoting anything.
    private static func joined(_ names: [String]) -> String {
        guard names.count > 1 else {
            return names.joined()
        }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
