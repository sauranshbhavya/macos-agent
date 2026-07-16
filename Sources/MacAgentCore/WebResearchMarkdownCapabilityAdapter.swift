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
                description: "Fetch the top Hacker News headlines from the public API.",
                requiredFields: ["count"],
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
                description: "Fetch one public http/https URL, resolve a topic through a configured search provider, or fetch multiple http/https sourceURLs for comparison, synthesize a research note, and save Markdown in a whitelisted output path.",
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

    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolvedPlan = plan
        if let markdownIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .writeMarkdown }) {
            resolvedPlan.steps[markdownIndex].outputPath = try hackerNewsSpec(in: resolvedPlan, context: context).outputURL.path
            return resolvedPlan
        }

        guard let stepIndex = resolvedPlan.steps.firstIndex(where: { $0.operation == .webToMarkdown }) else {
            return resolvedPlan
        }

        resolvedPlan.steps[stepIndex].outputPath = try webResearchSpec(in: resolvedPlan, context: context).outputURL.path
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
        let outputURL = try outputURLForRiskAssessment(in: plan, context: context)
        let escalations = context.fileManager.fileExists(atPath: outputURL.path)
            ? [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Markdown output already exists at \(outputURL.path)."
                )
            ]
            : []
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

        var pages: [ReadableWebPage] = []
        for sourceURL in sourceURLs {
            log(.act, "Fetching \(sourceURL.absoluteString)")
            let page = try await context.webPageLoader.load(rawURL: sourceURL.absoluteString)
            log(.observe, "Extracted readable content from \(page.sourceURL.absoluteString)")
            pages.append(page)
        }

        let prompt = WebResearchPromptBuilder.prompt(
            trustedPlan: resolvedPlan,
            trustedUserInstruction: spec.instruction,
            pages: pages
        )
        log(.act, "Synthesizing web research note")
        let note = try await context.webResearchSynthesizer.synthesize(prompt: prompt)
        let markdown = WebResearchMarkdownWriter.markdown(note: note, pages: pages, generatedAt: context.now())
        try Data(markdown.utf8).write(to: spec.outputURL, options: .atomic)
        log(.summarize, "Saved web research Markdown")

        let summary = summary(for: spec, sourceCount: sourceURLs.count)
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

    private func outputURLForRiskAssessment(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> URL {
        if isHackerNewsPreset(plan) {
            return try hackerNewsSpec(in: plan, context: context).outputURL
        }

        return try webResearchSpec(in: plan, context: context).outputURL
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

    private func summary(for spec: WebResearchSpec, sourceCount: Int) -> String {
        switch spec.input {
        case .urls:
            return sourceCount == 1
                ? "Saved web research Markdown to \(spec.outputURL.path)."
                : "Saved comparison Markdown for \(sourceCount) sources to \(spec.outputURL.path)."
        case .search(let query, _):
            return "Saved web research Markdown for search query \"\(query)\" using \(sourceCount) sources to \(spec.outputURL.path)."
        }
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
    public static func markdown(note: WebResearchNote, pages: [ReadableWebPage], generatedAt: Date) -> String {
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

        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
