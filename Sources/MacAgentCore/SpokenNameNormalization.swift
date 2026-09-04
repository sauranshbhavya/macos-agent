import Foundation

/// The one definition of the words a person puts in front of a name that are never part of the name.
///
/// Extracted rather than copied. `InstantCommandResolver` proved the rule for app, routine,
/// workspace and Shortcut names — "open my Safari" means Safari — and SONNY-242 needed the same rule
/// one layer away, for a folder. "write me a short note about today's plan and save it to my
/// Desktop" resolved to `~/my Desktop`, a sibling of `Desktop` that does not exist, and the refusal
/// then named `~/Desktop` as an allowed root in its very next clause. The product already knew what
/// "my Desktop" means; it knew it in one code path and not in the neighbouring one.
///
/// Two independently maintained lists is the shape where one gains a word and the other does not,
/// and the product then understands "our Documents" when it is an app name and not when it is a
/// folder. So there is one list, here, and `InstantCommandResolver` reads it rather than holding a
/// second copy.
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
        withoutLeadingArticle(raw, from: leadingArticles)
    }

    /// The same reading, restricted to a caller's own subset of the list.
    ///
    /// **Here for exactly one caller, and the subset is derived rather than chosen** (PR #106 review,
    /// F3). `InstantCommandResolver.runningAppCandidate` cannot keep the original beside the
    /// stripped one — a plan carries one `appName` — so every word this strips there is a word an
    /// app can no longer be called. That site strips an article for one reason: to undo its own
    /// plausibility guard, whose `leadingStopWords` would otherwise reject "the code app". So the
    /// words it may strip are the ones that guard rejects, and it passes that intersection here.
    /// The alternative offered in review — a second two-word constant — is the drifting pair this
    /// ticket exists to remove, and it would not have been self-maintaining: a stop word added to
    /// the guard later would silently stop being strippable.
    static func withoutLeadingArticle(_ raw: String, from articles: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) else {
            return trimmed
        }
        guard articles.contains(String(trimmed[..<separator.lowerBound]).lowercased()) else {
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

/// A path field as a person phrased it, turned into the path they meant.
///
/// **Deliberately above `PathWhitelist` rather than inside it** (SONNY-242). The whitelist's
/// `canonical` is the arithmetic every containment check in the app compares through, including
/// a workspace's narrower restriction scope; a step that rewrote path *text* in there would mean a
/// workspace boundary the user drew around "my notes" silently became a boundary around "notes",
/// and the security check and the thing it is checking would no longer be the same string for
/// reasons no reader of either could see. Normalising before the path reaches the boundary keeps the
/// boundary's job to one question: is this resolved path inside a root.
///
/// **And it is not a planner-prompt rule** — that was the third candidate. The prompt is where the
/// name comes from ("Include user-supplied paths exactly as written", which is the rule producing
/// the defect and the right rule for a real path), but a sentence added there is obeyed with a
/// probability rather than a guarantee, it is untestable without a live model, and it would have to
/// be kept in step across two providers. This is a deterministic function with a suite over it. The
/// prompt is left as it is, so the honest description of the fix is that Sonny now understands a
/// name the model faithfully copied, rather than that the model was asked to stop copying it.
public enum SpokenPath {
    /// The path a phrase means, or the phrase unchanged when it was already a path.
    ///
    /// **A `/`-absolute value is returned untouched; a `~/` one is not, and the difference is the
    /// whole of PR #106's F1.** The first version guarded on both, on the reasoning that
    /// `/Users/me/my Desktop` names a real place and a person who typed it means it. That holds for
    /// `/` and does not transfer to `~/`: `PathWhitelist.expandPath` expands the tilde and then
    /// resolves the rest against the same home directory a bare name goes to, so `~/my Desktop` and
    /// `my Desktop` are the *same* location — one of them was fixed and the other still threw the
    /// founder's exact error. And the author of these strings is the planner, not a person: the
    /// system prompt models the tilde spelling in its own worked examples
    /// (`git show 4a44288:Sources/MacAgentCore/OpenAIPlanner.swift | grep -c "~/Documents"` prints
    /// 2 lines, carrying 4 occurrences), so `~/` is precisely the spelling a model reaches for.
    ///
    /// A `~` or `~user` leading component is a *home prefix rather than a name*, so the component
    /// the article comes off is the one after it. Everything else is resolved relative to the home
    /// directory, which is why those are the values this rewrites at all — exactly the population
    /// where "my Desktop" is a phrase and not a place.
    ///
    /// **The remaining `/` guard is redundant, and a battery says so rather than a reading of the
    /// code**: deleting it leaves the whole suite green (`scripts/mutate`, M5 at `fa40d21`, still
    /// equivalent after F1 narrowed it), because an absolute path's first component is the empty
    /// string, which is not an article, and the `head.isEmpty` fallback below then returns the
    /// original anyway. It is kept as an equivalent mutant on purpose. Without it the rule holds
    /// only as a consequence of how `components(separatedBy:)` treats a leading separator — true
    /// today, invisible to a reader, and exactly the sort of thing a later edit removes without
    /// noticing it was load-bearing.
    ///
    /// The article comes off the **named component only**. `Desktop/my notes` keeps its folder:
    /// only the leading component is the one the home directory is searched for, and a possessive
    /// deeper in the path is part of a name the user really did type.
    ///
    /// The trailing noun comes off only when **nothing sits below the named component** — a bare
    /// phrase such as "my downloads folder", or "~/my downloads folder", which is the same phrase
    /// with the home spelled out. A value with a component below it is a path someone spelled, and
    /// `Documents/Client folder` names a folder that can genuinely be called that. The narrower
    /// rule costs nothing: the only *named* components that can resolve inside the whitelist at all
    /// are `Desktop` and `Documents` — a relative value and a `~/` one land in the same home
    /// directory — and neither ends in one of these nouns, so stripping one can never turn a path
    /// that works today into a different path that works.
    ///
    /// **Idempotent, and it has to be**, because the resolve phase runs at all three executor gates:
    /// `prepare` previews a path, `assessRisk` checks that path for a collision, and `execute`
    /// writes it. A function that gave a different answer on its second pass would preview one file
    /// and write another. So the article comes off to a fixed point rather than once — the first
    /// draft of this stripped once, and `my The Archive` then resolved to `The Archive` at preview
    /// and to `Archive` at execution.
    ///
    /// Stripping to a fixed point does mean a folder genuinely called `The Archive`, named
    /// relatively, reads as `Archive`. **That cannot cost anybody a folder**, and the reason is
    /// structural rather than lucky: a relative value is resolved against the home directory, and
    /// every whitelist in production is built on the default roots (`git grep -n "PathWhitelist("
    /// 94afca1 -- Sources | grep -v PathWhitelist.swift` prints 6 sites, all of them
    /// `= PathWhitelist()`), so the only leading components that can land inside the whitelist at
    /// all are `Desktop` and `Documents`. `~/The Archive` and `~/Archive` are both refused, with or
    /// without this. What the strip can change is a refusal into a success — never a success into a
    /// different success.
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

    /// Every path a plan names, normalised — the whole plan, including the steps nested inside a
    /// `save_routine`.
    ///
    /// **Nested steps are covered here rather than left to run time**, even though a routine's steps
    /// resolve through this same funnel when the routine is later run. `SaveRoutineCapabilityAdapter`
    /// persists `routineSteps` exactly as the plan carried them, so skipping the recursion would
    /// store "my Desktop" in the routine's own record — a stored routine that reads wrong in the
    /// detail sheet and re-derives the right answer on every run.
    public static func normalizingFolderPhrases(in plan: AgentPlan) -> AgentPlan {
        var result = plan
        result.steps = plan.steps.map(normalizingFolderPhrases(in:))
        return result
    }

    /// One step's path fields.
    ///
    /// The four of them are `inputPath`, `outputPath`, `workspaceFileLocations` and
    /// `workspaceFileLocationsToRemove` — every field on `AgentStep` whose value is a filesystem
    /// path. A fifth added later and not added here is caught by
    /// `SpokenPathTests.everyPathFieldOnAStepIsNormalisedAndNothingElseIs`, which takes the property
    /// population off `Mirror` and classifies it against a table asserted in both directions — so a
    /// new field stops the suite whatever it is called, rather than only when its name ends in
    /// "Path" (PR #106 review, F6).
    ///
    /// A removal list is normalised alongside the addition list on purpose: removals are matched
    /// against what is stored, and what is stored went through this function on its way in.
    static func normalizingFolderPhrases(in step: AgentStep) -> AgentStep {
        var result = step
        result.inputPath = step.inputPath.map(normalized)
        result.outputPath = step.outputPath.map(normalized)
        result.workspaceFileLocations = step.workspaceFileLocations?.map(normalized)
        result.workspaceFileLocationsToRemove = step.workspaceFileLocationsToRemove?.map(normalized)
        result.routineSteps = step.routineSteps?.map(normalizingFolderPhrases(in:))
        return result
    }
}
