import Foundation

/// Gives one file or folder a different name, in the folder it already sits in (SONNY-385).
///
/// **Its own adapter rather than a mode of an existing one.** A rename is not a workspace edit and
/// not a conversion: it takes a path and a name, it asks first, and it is the only capability whose
/// whole effect is to replace something the user already has with the same bytes under a different
/// label. Folding it into `edit_workspace` — the operation whose name reads closest — would have put
/// a destructive filesystem action behind a verb about configuring a boundary.
public struct RenameCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.files.rename",
        displayName: "Rename file or folder",
        description: "Rename one whitelisted file or folder, keeping it in the folder it is already in.",
        operations: [.rename],
        plannerTools: [
            AgentTool(
                operation: .rename,
                name: "Rename file or folder",
                description: "Rename one whitelisted file or folder. inputPath is the item to rename and newName is what to call it — a bare name with no slashes, since the item keeps its folder. Renaming one item at a time only: if the user asks to rename several items, ask a clarification question for the new names instead.",
                requiredFields: ["inputPath", "newName"],
                sideEffects: ["rename file"],
                dryRunBehavior: "Show the current path and the name it would be given.",
                examples: ["Rename ~/Documents/scan1.pdf to invoice-march", "Rename that folder to Archive"]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .desktopDocumentsAccess)
        ],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try renameSpec(in: plan, context: context, requiresExistingSource: false)
        return [
            ActionPreview(
                title: "Rename",
                details: [
                    "Rename \(spec.source.path)",
                    "to \(spec.destination.lastPathComponent)"
                ],
                writes: [spec.destination.path]
            )
        ]
    }

    /// **Unconditionally destructive, and that is the difference from every other write in this
    /// package.** `CreateLocalDraftCapabilityAdapter` escalates only when its output path is already
    /// taken, because there the ordinary case replaces nothing. Here the ordinary case *is* the
    /// replacement: the name a file is filed under is something the user chose, renaming takes it
    /// away, and nothing in the product puts it back. So the escalation is raised on every rename
    /// rather than on the collision — and the collision is not what this is about at all, since a
    /// rename onto a name already in use is refused outright by `renameSpec` rather than approved.
    ///
    /// The consequence rule (2026-08-13) does the rest: a `.destructive` escalation asks, at every
    /// interaction mode, with no way to relax it.
    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try renameSpec(in: plan, context: context, requiresExistingSource: false)
        return CapabilityRiskAssessment(
            defaultTier: metadata.defaultRiskTier,
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Renaming \(spec.source.lastPathComponent) to \(spec.destination.lastPathComponent) replaces the name it is filed under, and Sonny cannot undo it.",
                    consequence: .destructive
                )
            ]
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try renameSpec(in: plan, context: context, requiresExistingSource: true)
        log(.act, "Renaming \(spec.source.path) to \(spec.destination.lastPathComponent)")
        try context.fileManager.moveItem(at: spec.source, to: spec.destination)
        log(.summarize, "Renamed")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Renamed \(spec.source.lastPathComponent) to \(spec.destination.lastPathComponent) in \(spec.destination.deletingLastPathComponent().path).",
            suggestions: [
                RunSuggestion(title: "Reveal in Finder", kind: .revealInFinder, value: spec.destination.path)
            ]
        )
    }

    /// What a rename would actually touch: the item now, and the item afterwards.
    ///
    /// **The destination is derived here and nowhere else**, because two things need it and a second
    /// derivation is a second answer waiting to disagree: this adapter, which performs the move, and
    /// `PlanScopedResources`, which has to name both paths so a workspace boundary can be answered
    /// about the one being written as well as the one being read.
    ///
    /// Pure and side-effect free — it composes strings and validates them against the whitelist, and
    /// touches no file. That is what lets the scope classifier call it.
    public static func destinationPath(forInputPath rawInput: String?, newName rawName: String?) -> String? {
        guard let rawInput, let rawName else {
            return nil
        }
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !name.isEmpty else {
            return nil
        }
        return (input as NSString).deletingLastPathComponent + "/" + name
    }

    private struct RenameSpec {
        var source: URL
        var destination: URL
    }

    private func renameSpec(
        in plan: AgentPlan,
        context: CapabilityExecutionContext,
        requiresExistingSource: Bool
    ) throws -> RenameSpec {
        guard let step = plan.steps.first(where: { $0.operation == .rename }) else {
            throw AgentExecutionError.invalidPlan("rename step is missing.")
        }
        guard let rawInput = step.inputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawInput.isEmpty else {
            throw AgentExecutionError.invalidPlan("rename needs inputPath: the file or folder to rename.")
        }
        let newName = try validatedNewName(step.newName)

        let source = try context.whitelist.validateInsideWhitelist(rawInput)
        guard !requiresExistingSource || context.fileManager.fileExists(atPath: source.path) else {
            throw PathValidationError.notFound(source.path)
        }
        let folder = source.deletingLastPathComponent()
        // **Validated through `validateOutputFile`, and moved to the composed path rather than to
        // what that call hands back.** The door is `PathWhitelist`'s own rule for every path this
        // package builds — it re-checks containment and that the parent is a real directory — so it
        // is called for its *refusal*, and the discard is deliberate rather than an oversight.
        //
        // What it returns is **canonical**, and canonical is the wrong thing to move to: on a
        // case-insensitive volume `fileExists` finds `readme.md` at `README.md`, so
        // `resolvingSymlinksInPath` rewrites the requested spelling to the one already on disk and
        // renaming `readme.md` to `README.md` comes back as a path identical to its own source. The
        // first version of this adapter did move to that value, and the case-change test is what
        // caught it — reporting "readme.md is already called that" for a rename that changes the
        // name.
        //
        // Composing here is safe for the reason the discard is: `folder` is canonical because
        // `source` is, `newName` holds no separator and is neither `.` nor `..`, so this is a direct
        // child of a validated directory. Anything else the leaf could be — a symbolic link, an
        // existing file — is refused below as an occupied destination.
        _ = try context.whitelist.validateOutputFile(named: newName, in: folder)
        let destination = folder.appendingPathComponent(newName)

        guard newName != source.lastPathComponent else {
            throw AgentExecutionError.invalidPlan("\(source.lastPathComponent) is already called that.")
        }
        try refuseCollision(source: source, destination: destination, context: context)
        return RenameSpec(source: source, destination: destination)
    }

    /// **A name, never a path**, and the refusal is what keeps this operation from quietly becoming
    /// a move (SONNY-385). `~/Documents/a.pdf` renamed to `../Desktop/a.pdf` would land somewhere
    /// the user was never shown, inside the whitelist and therefore past every containment check —
    /// so the separator is refused here rather than left to `validateInsideWhitelist`, which is
    /// answering a different question and would say yes.
    ///
    /// `.` and `..` are refused for the same reason by a different route: both compose to a path
    /// that is not a sibling at all.
    private func validatedNewName(_ raw: String?) throws -> String {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw AgentExecutionError.invalidPlan("rename needs newName: what to call the file or folder.")
        }
        guard !name.contains("/") else {
            throw AgentExecutionError.invalidPlan(
                "Sonny renames a file where it is — \"\(name)\" is a path, not a name. Say what to call it, and it stays in the same folder."
            )
        }
        guard name != ".", name != ".." else {
            throw AgentExecutionError.invalidPlan("\"\(name)\" is not a name Sonny can give a file.")
        }
        return name
    }

    /// **A rename onto a name that is already taken fails, and it fails here rather than at the
    /// filesystem call** (SONNY-385, and the ticket names this as the decision to make with a test).
    ///
    /// `FileManager.moveItem` happens to refuse an occupied destination on macOS today, so this
    /// check could be omitted and the observable behaviour would look the same — which is exactly
    /// why it is here. What the call gives back is `NSFileWriteFileExistsError`, whose message names
    /// neither the file that is in the way nor the item being renamed, and the behaviour would be a
    /// property of Foundation rather than of Sonny: a future overwrite flag, a different filesystem,
    /// or a call swapped for `replaceItemAt` would silently turn the refusal into a destruction of a
    /// file the user never named. So the decision is stated, the message names the file already
    /// there, and a test holds it.
    ///
    /// **A rename that only changes letter case is not a collision**, and on this Mac it looks
    /// exactly like one. APFS is case-insensitive by default, so `readme.md` "exists" at
    /// `README.md`; refusing that would refuse a rename people genuinely ask for, over a file that
    /// is the item itself. The two are told apart by file *identity* rather than by comparing the
    /// paths, because a case-insensitive volume is not the only way two paths can name one file.
    private func refuseCollision(
        source: URL,
        destination: URL,
        context: CapabilityExecutionContext
    ) throws {
        // `attributesOfItem` rather than `fileExists`, because it does not follow a symbolic link:
        // a dangling link sitting at the destination is something `moveItem` refuses, and
        // `fileExists` would report the destination free and let the run reach that refusal with
        // Foundation's wording instead of this one.
        guard (try? context.fileManager.attributesOfItem(atPath: destination.path)) != nil else {
            return
        }
        guard !isTheSourceUnderAnotherSpelling(source: source, destination: destination) else {
            return
        }
        throw AgentExecutionError.invalidPlan(
            "There is already something called \(destination.lastPathComponent) in \(destination.deletingLastPathComponent().path). Sonny will not replace it — pick a different name."
        )
    }

    /// Whether the "occupied" destination is the item being renamed, seen through a case-insensitive
    /// volume.
    ///
    /// **Both halves are required, and neither alone is right.** Differing only by case is not
    /// enough: on a case-*sensitive* volume `README.md` beside `readme.md` really is a second file,
    /// and exempting it would overwrite one the user never named. Identical file identity is not
    /// enough either — **a hard link** reports the same identity as the file it is linked to while
    /// being a second name the user can see in Finder, and `moveItem` refuses it. Requiring both
    /// confines the exemption to the one situation it exists for, and every other shape falls
    /// through to the refusal, which is the fail-closed direction.
    ///
    /// **This named a symbolic link until PR #200's F3, and that was false rather than loose.** A
    /// symbolic link reports a *different* identity from its target, so it never reached this
    /// guard's second half at all — the identity check already refuses it. Measured on this Mac,
    /// Darwin 25.6.0, by `Tests/MacAgentCoreTests/RenameTests.swift`'s own fixtures rather than by
    /// a probe that ran once: a symlink's `fileResourceIdentifier` differs from its target's, a
    /// hard link's is equal, and `moveItem` throws `NSCocoaErrorDomain 516` onto either. So the
    /// guard was right for a reason nobody had written down, while the reason that *was* written
    /// down described a case it does not handle — which is the shape `CLAUDE.md`'s
    /// claims-and-evidence section exists for, and it had reached the changelog too.
    ///
    /// **What dropping the case half would actually cost, stated because it is smaller than it
    /// sounds:** `moveItem` still refuses a hard-linked destination, so the user gets Foundation's
    /// wording instead of Sonny's. That is exactly the property `refuseCollision` above exists to
    /// guarantee, which is why the half is kept and now held by a test.
    private func isTheSourceUnderAnotherSpelling(source: URL, destination: URL) -> Bool {
        guard destination.path.compare(source.path, options: .caseInsensitive) == .orderedSame else {
            return false
        }
        guard let a = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let b = try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return a.isEqual(b)
    }
}
