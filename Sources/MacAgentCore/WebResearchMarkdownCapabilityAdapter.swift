import Foundation

public struct WebResearchMarkdownCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.web.research-markdown",
        displayName: "Web research Markdown",
        description: "Fetch public web pages or preset sources, synthesize Markdown, and save source-linked notes.",
        operations: [.openHackerNews, .fetchHNHeadlines, .writeMarkdown, .webToMarkdown],
        plannerTools: [
            AgentTool(
                operation: .openHackerNews,
                name: "Open Hacker News",
                description: "Open Hacker News in the default browser as part of the headline workflow.",
                requiredFields: [],
                sideEffects: ["open browser"],
                dryRunBehavior: "Show that Hacker News would open.",
                examples: ["Open Hacker News"]
            ),
            AgentTool(
                operation: .fetchHNHeadlines,
                name: "Fetch Hacker News headlines",
                description: "Fetch the top Hacker News headlines from the public API. Defaults to the top 5 when count is omitted.",
                requiredFields: [],
                sideEffects: ["network request"],
                dryRunBehavior: "Show the number of headlines that would be fetched.",
                examples: ["Grab the top 5 headlines"]
            ),
            AgentTool(
                operation: .writeMarkdown,
                name: "Write Markdown file",
                description: "Write fetched Hacker News headlines to Markdown in a whitelisted output path.",
                requiredFields: [],
                sideEffects: ["write file"],
                dryRunBehavior: "Show the Markdown path without writing it.",
                examples: ["Save to a Markdown file"]
            ),
            AgentTool(
                operation: .webToMarkdown,
                name: "Web page to Markdown",
                description: "Fetch one public http/https URL, resolve a topic through a configured search provider, or fetch multiple http/https sourceURLs for comparison, synthesize a research note, and save Markdown in a whitelisted output path. Sources that cannot be retrieved are skipped and listed in the note; the step fails only when every source fails.",
                requiredFields: ["targetURL, sourceURLs, or searchQuery"],
                sideEffects: ["network request", "send fetched public page content to OpenAI", "write file"],
                dryRunBehavior: "Show source URL(s), search query, and Markdown output path without fetching pages or writing files.",
                examples: [
                    "Summarize https://example.com/article and save as Markdown",
                    "Compare these source URLs and save a Markdown note",
                    "Research Swift concurrency and save a Markdown note"
                ]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .networkAccess),
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)
        ],
        defaultRiskTier: .tier2
    )

    /// The preset write and the research note are two different destinations, so a plan carrying
    /// both needs both resolved. This used to resolve the first `.writeMarkdown` step and
    /// *return*, which left the `.webToMarkdown` step of a Hacker-News-preset-then-research chain
    /// with no resolved path at all — its output was neither previewed as a concrete path nor
    /// checked for a collision, even though the run wrote it.
    ///
    /// Still one step of each kind, deliberately: `execute` resolves one preset spec or one
    /// research spec from the first matching step, so resolving a *second* `.writeMarkdown` step
    /// would advertise a destination nothing ever writes.
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolvedPlan = plan
        if let markdownIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .writeMarkdown }) {
            resolvedPlan.steps[markdownIndex].outputPath = try hackerNewsSpec(in: resolvedPlan, context: context).outputURL.path
        }

        if let stepIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .webToMarkdown }) {
            resolvedPlan.steps[stepIndex].outputPath = try webResearchSpec(in: resolvedPlan, context: context).outputURL.path
        }

        return resolvedPlan
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        if isHackerNewsPreset(plan) {
            let spec = try hackerNewsSpec(in: plan, context: context)
            return [
                ActionPreview(
                    title: "Fetch Hacker News top \(spec.count)",
                    details: [
                        "Open https://news.ycombinator.com",
                        "Fetch top \(spec.count) headlines",
                        "Save Markdown to \(spec.outputURL.path)"
                    ],
                    writes: [spec.outputURL.path],
                    opens: [Self.hackerNewsURL.absoluteString]
                )
            ]
        }

        let spec = try webResearchSpec(in: plan, context: context)
        return [
            ActionPreview(
                title: previewTitle(for: spec.input),
                details: previewDetails(for: spec.input) + [
                    "Save Markdown to \(spec.outputURL.path)"
                ],
                writes: [spec.outputURL.path]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let escalations = try outputURLsForRiskAssessment(in: plan, context: context)
            .filter { context.fileManager.fileExists(atPath: $0.path) }
            .map { outputURL in
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Markdown output already exists at \(outputURL.path)."
                )
            }
        return CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier, escalations: escalations)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let resolvedPlan = try resolveDefaultOutputs(in: plan, context: context)
        if isHackerNewsPreset(resolvedPlan) {
            return try await executeHackerNewsPreset(plan: resolvedPlan, context: context, log: log)
        }

        let previews = try preview(plan: resolvedPlan, context: context)
        let spec = try webResearchSpec(in: resolvedPlan, context: context)
        let sourceURLs = try await sourceURLs(for: spec, context: context, log: log)

        // One unreachable source (404, paywall, robots-disallowed) must not throw away the
        // sources that did load — synthesize from what succeeded and name what was skipped.
        var pages: [ReadableWebPage] = []
        var skippedSources: [SkippedSource] = []
        for sourceURL in sourceURLs {
            log(.act, "Fetching \(sourceURL.absoluteString)")
            do {
                let page = try await context.webPageLoader.load(rawURL: sourceURL.absoluteString)
                log(.observe, "Extracted readable content from \(page.sourceURL.absoluteString)")
                pages.append(page)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log(.observe, "Skipped \(sourceURL.absoluteString): \(error.localizedDescription)")
                skippedSources.append(
                    SkippedSource(url: sourceURL, reason: error.localizedDescription)
                )
            }
        }

        if pages.isEmpty, let firstFailure = skippedSources.first {
            throw WebResearchError.allSourcesFailed(
                skippedSources.map(\.url.absoluteString),
                firstFailure.reason
            )
        }

        return try await synthesizeAndWrite(
            resolvedPlan: resolvedPlan,
            spec: spec,
            previews: previews,
            pages: pages,
            skippedSources: skippedSources,
            context: context,
            log: log
        )
    }

    public struct SkippedSource: Equatable, Sendable {
        public var url: URL
        public var reason: String

        public init(url: URL, reason: String) {
            self.url = url
            self.reason = reason
        }
    }

    @MainActor
    private func synthesizeAndWrite(
        resolvedPlan: AgentPlan,
        spec: WebResearchSpec,
        previews: [ActionPreview],
        pages: [ReadableWebPage],
        skippedSources: [SkippedSource],
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let prompt = WebResearchPromptBuilder.prompt(
            trustedPlan: resolvedPlan,
            trustedUserInstruction: spec.instruction,
            pages: pages
        )
        log(.act, "Synthesizing web research note")
        let note = try await context.webResearchSynthesizer.synthesize(prompt: prompt)
        let markdown = WebResearchMarkdownWriter.markdown(
            note: note,
            pages: pages,
            skippedSources: skippedSources,
            generatedAt: context.now()
        )
        try Data(markdown.utf8).write(to: spec.outputURL, options: .atomic)
        log(.summarize, "Saved web research Markdown")

        let summary = summary(for: spec, sourceCount: pages.count, skippedSources: skippedSources)
        return AgentRunResult(
            plan: resolvedPlan,
            previews: previews,
            summary: summary,
            suggestions: suggestions(for: spec.outputURL)
        )
    }

    private struct WebResearchSpec {
        var input: WebResearchInput
        var outputURL: URL
        var instruction: String
    }

    private enum WebResearchInput {
        case urls([URL])
        case search(query: String, limit: Int)
    }

    private static let hackerNewsURL = URL(string: "https://news.ycombinator.com")!

    private struct HackerNewsSpec {
        var count: Int
        var outputURL: URL
    }

    private func isHackerNewsPreset(_ plan: AgentPlan) -> Bool {
        plan.steps.contains { step in
            [.openHackerNews, .fetchHNHeadlines, .writeMarkdown].contains(step.operation)
        }
    }

    /// Every Markdown file this plan would write: the preset's, the research note's, or both.
    ///
    /// The `if`s used to be an either/or — "is this the Hacker News preset?" answered first and
    /// returned the preset's path alone, so a plan carrying both never checked the research note's
    /// output. `AgentActionExecutor` now assesses chains segment by segment and so hands this
    /// adapter one kind at a time, which makes the both-kinds case unreachable from there; keeping
    /// it correct here means a future change to how segments are cut (adding `.webToMarkdown` to
    /// the preset's absorb list, say) cannot quietly restore the under-assessment.
    ///
    /// One URL per kind, matching what `execute` writes — a second `.writeMarkdown` step in the
    /// same plan is dropped by `hackerNewsSpec`'s first-match pick, so assessing it would gate on
    /// a file nothing ever writes.
    private func outputURLsForRiskAssessment(
        in plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> [URL] {
        var outputURLs: [URL] = []
        if isHackerNewsPreset(plan) {
            outputURLs.append(try hackerNewsSpec(in: plan, context: context).outputURL)
        }

        if plan.steps.contains(where: { $0.operation == .webToMarkdown }) {
            outputURLs.append(try webResearchSpec(in: plan, context: context).outputURL)
        }

        return outputURLs
    }

    @MainActor
    private func executeHackerNewsPreset(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try hackerNewsSpec(in: plan, context: context)
        log(.act, "Opening Hacker News")
        try await context.browserOpener.open(Self.hackerNewsURL)
        log(.act, "Fetching top \(spec.count) headlines")
        let headlines = try await context.hackerNewsFetcher.topHeadlines(limit: spec.count)
        log(.observe, "Fetched \(headlines.count) headlines")
        let markdown = MarkdownWriter.hackerNewsMarkdown(headlines: headlines, date: context.now())
        try markdown.data(using: .utf8)?.write(to: spec.outputURL, options: .atomic)
        log(.summarize, "Saved Markdown")

        let summary = "Saved \(headlines.count) Hacker News headlines to \(spec.outputURL.path)."
        return AgentRunResult(plan: plan, previews: previews, summary: summary, suggestions: suggestions(for: spec.outputURL))
    }

    private func webResearchSpec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> WebResearchSpec {
        guard let step = plan.steps.first(where: { $0.operation == .webToMarkdown }) else {
            throw AgentExecutionError.invalidPlan("web_to_markdown step is missing.")
        }

        let input = try webResearchInput(in: step)
        let outputURL = try outputURL(for: step.outputPath, context: context)
        let instruction = [plan.summary, step.description]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Create a concise Markdown research note from the supplied web source(s)."

        return WebResearchSpec(input: input, outputURL: outputURL, instruction: instruction)
    }

    private func hackerNewsSpec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> HackerNewsSpec {
        let writeStep = plan.steps.first { $0.operation == .writeMarkdown }
        let fetchStep = plan.steps.first { $0.operation == .fetchHNHeadlines }
        let count = max(fetchStep?.count ?? writeStep?.count ?? 5, 1)

        let outputURL = try context.whitelist.resolveOutputPath(
            rawPath: writeStep?.outputPath,
            defaultName: "hacker-news-\(Timestamp.fileSafe(context.now()))",
            extension: "md",
            fileManager: context.fileManager
        )

        return HackerNewsSpec(count: count, outputURL: outputURL)
    }

    private func webResearchInput(in step: AgentStep) throws -> WebResearchInput {
        let fromList = (step.sourceURLs ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fromList.isEmpty {
            return .urls(try fromList.map { try SafeURL.validateWebURL($0) })
        }

        if let targetURL = step.targetURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetURL.isEmpty {
            return .urls([try SafeURL.validateWebURL(targetURL)])
        }

        if let searchQuery = step.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !searchQuery.isEmpty {
            return .search(query: searchQuery, limit: max(step.count ?? 3, 1))
        }

        throw AgentExecutionError.invalidPlan("web_to_markdown needs targetURL, sourceURLs, or searchQuery.")
    }

    @MainActor
    private func sourceURLs(
        for spec: WebResearchSpec,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> [URL] {
        switch spec.input {
        case .urls(let sourceURLs):
            return sourceURLs
        case .search(let query, let limit):
            log(.act, "Searching web for \(query)")
            let results = try await context.webSearchProvider.search(query: query, limit: limit)
            let urls = try uniqueURLs(results.map { result in
                try SafeURL.validateWebURL(result.url.absoluteString)
            })
            guard !urls.isEmpty else {
                throw WebResearchError.noSearchResults(query)
            }
            log(.observe, "Resolved \(urls.count) search result source(s)")
            return urls
        }
    }

    private func previewTitle(for input: WebResearchInput) -> String {
        switch input {
        case .urls(let sourceURLs):
            return sourceURLs.count == 1 ? "Save web article Markdown" : "Save web comparison Markdown"
        case .search:
            return "Save web research Markdown"
        }
    }

    private func previewDetails(for input: WebResearchInput) -> [String] {
        switch input {
        case .urls(let sourceURLs):
            return ["Sources: \(sourceURLs.map(\.absoluteString).joined(separator: ", "))"]
        case .search(let query, let limit):
            return [
                "Search query: \(query)",
                "Search result limit: \(limit)"
            ]
        }
    }

    private func summary(
        for spec: WebResearchSpec,
        sourceCount: Int,
        skippedSources: [SkippedSource]
    ) -> String {
        let base: String
        switch spec.input {
        case .urls:
            base = sourceCount == 1
                ? "Saved web research Markdown to \(spec.outputURL.path)."
                : "Saved comparison Markdown for \(sourceCount) sources to \(spec.outputURL.path)."
        case .search(let query, _):
            // Singular matters here: partial synthesis (some sources skipped) can reduce the
            // surviving count to one, same as the skipped-source clause below already handles.
            base = "Saved web research Markdown for search query \"\(query)\" using \(sourceCount) source\(sourceCount == 1 ? "" : "s") to \(spec.outputURL.path)."
        }

        guard !skippedSources.isEmpty else {
            return base
        }
        let names = skippedSources.map(\.url.absoluteString).joined(separator: ", ")
        return "\(base) Skipped \(skippedSources.count) unreachable source\(skippedSources.count == 1 ? "" : "s"): \(names)."
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted {
            result.append(url)
        }
        return result
    }

    private func outputURL(for rawOutput: String?, context: CapabilityExecutionContext) throws -> URL {
        try context.whitelist.resolveOutputPath(
            rawPath: rawOutput,
            defaultName: "web-research-\(Timestamp.fileSafe(context.now()))",
            extension: "md",
            fileManager: context.fileManager
        )
    }

    private func suggestions(for outputURL: URL) -> [RunSuggestion] {
        [
            RunSuggestion(
                title: "Open Markdown",
                kind: .openFile,
                value: outputURL.path
            ),
            RunSuggestion(
                title: "Reveal Markdown in Finder",
                kind: .revealInFinder,
                value: outputURL.path
            )
        ]
    }
}

public enum WebResearchMarkdownWriter {
    public static func markdown(
        note: WebResearchNote,
        pages: [ReadableWebPage],
        skippedSources: [WebResearchMarkdownCapabilityAdapter.SkippedSource] = [],
        generatedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# \(escape(note.title))",
            "",
            "Generated: \(formatter.string(from: generatedAt))",
            ""
        ]

        if !note.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(escape(note.summary))
            lines.append("")
        }

        if !note.keyPoints.isEmpty {
            lines.append("## Key Points")
            lines.append("")
            for point in note.keyPoints {
                lines.append("- \(escape(point))")
            }
            lines.append("")
        }

        if !note.citations.isEmpty {
            lines.append("## Citations")
            lines.append("")
            for citation in note.citations {
                lines.append("- \(escape(citation))")
            }
            lines.append("")
        }

        lines.append("## Sources")
        lines.append("")
        for page in pages {
            lines.append("- [\(escape(page.title))](\(page.sourceURL.absoluteString))")
            lines.append("  - Retrieved: \(formatter.string(from: page.retrievedAt))")
            if let author = page.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  - Author: \(escape(author))")
            }
            if let publishedDate = page.publishedDate, !publishedDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  - Published: \(escape(publishedDate))")
            }
        }
        lines.append("")

        if !skippedSources.isEmpty {
            lines.append("## Skipped Sources")
            lines.append("")
            lines.append("These sources could not be retrieved, so this note does not cover them:")
            lines.append("")
            for skipped in skippedSources {
                lines.append("- \(skipped.url.absoluteString)")
                lines.append("  - Reason: \(escape(skipped.reason))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
