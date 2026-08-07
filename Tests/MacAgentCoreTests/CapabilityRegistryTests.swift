import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct CapabilityRegistryTests {
    @Test
    func defaultRegistryCoversAllExecutableOperations() throws {
        let actual = CapabilityRegistry.default.metadata
            .flatMap(\.operations)
            .map(\.rawValue)
            .sorted()
        let expected = AgentOperation.allCases
            .filter { $0 != .unsupported }
            .map(\.rawValue)
            .sorted()

        #expect(actual == expected)
    }

    @Test
    func defaultRegistryRoutesOperationsToStableCapabilityIDs() throws {
        let registry = CapabilityRegistry.default

        #expect(try registry.adapter(for: .scanSelectLargestFiles).metadata.id == "local.files.largest-files-zip")
        #expect(try registry.adapter(for: .createZip).metadata.id == "local.files.largest-files-zip")
        #expect(try registry.adapter(for: .scanSelectLargestFiles) is LargestFilesZipCapabilityAdapter)
        #expect(try registry.adapter(for: .createZip) is LargestFilesZipCapabilityAdapter)
        #expect(try registry.adapter(for: .convertDocxToPDF).metadata.id == "local.documents.docx-to-pdf")
        #expect(try registry.adapter(for: .scanDocx) is DocxConversionCapabilityAdapter)
        #expect(try registry.adapter(for: .convertDocxToPDF) is DocxConversionCapabilityAdapter)
        #expect(try registry.adapter(for: .openHackerNews).metadata.id == "local.web.research-markdown")
        #expect(try registry.adapter(for: .fetchHNHeadlines).metadata.id == "local.web.research-markdown")
        #expect(try registry.adapter(for: .writeMarkdown).metadata.id == "local.web.research-markdown")
        #expect(try registry.adapter(for: .openHackerNews) is WebResearchMarkdownCapabilityAdapter)
        #expect(try registry.adapter(for: .fetchHNHeadlines) is WebResearchMarkdownCapabilityAdapter)
        #expect(try registry.adapter(for: .writeMarkdown) is WebResearchMarkdownCapabilityAdapter)
        #expect(try registry.adapter(for: .webToMarkdown).metadata.id == "local.web.research-markdown")
        #expect(try registry.adapter(for: .webToMarkdown) is WebResearchMarkdownCapabilityAdapter)
        #expect(try registry.adapter(for: .openURL).metadata.id == "local.browser.open-url")
        #expect(try registry.adapter(for: .openURL) is OpenSafeURLCapabilityAdapter)
        #expect(try registry.adapter(for: .openAppSearchURL).metadata.id == "local.browser.open-app-search-url")
        #expect(try registry.adapter(for: .openAppSearchURL) is OpenAppSearchURLCapabilityAdapter)
        #expect(try registry.adapter(for: .openApp).metadata.id == "local.apps.open-allowlisted-app")
        #expect(try registry.adapter(for: .openApp) is OpenAllowlistedAppCapabilityAdapter)
        #expect(try registry.adapter(for: .openGeneratedArtifact).metadata.id == "local.files.open-generated-artifact")
        #expect(try registry.adapter(for: .openGeneratedArtifact) is OpenGeneratedArtifactCapabilityAdapter)
        #expect(try registry.adapter(for: .createLocalDraft).metadata.id == "local.files.create-local-draft")
        #expect(try registry.adapter(for: .createLocalDraft) is CreateLocalDraftCapabilityAdapter)
        #expect(try registry.adapter(for: .calculateUtility).metadata.id == "local.instant.calculator")
        #expect(try registry.adapter(for: .calculateUtility) is CalculatorCapabilityAdapter)
        #expect(try registry.adapter(for: .lookupClipboardHistory).metadata.id == "local.instant.clipboard-history")
        #expect(try registry.adapter(for: .lookupClipboardHistory) is ClipboardHistoryCapabilityAdapter)
        #expect(try registry.adapter(for: .saveSnippet).metadata.id == "local.instant.snippet-save")
        #expect(try registry.adapter(for: .saveSnippet) is SnippetSaveCapabilityAdapter)
        #expect(try registry.adapter(for: .expandSnippet).metadata.id == "local.instant.snippet-expansion")
        #expect(try registry.adapter(for: .expandSnippet) is SnippetExpansionCapabilityAdapter)
        #expect(try registry.adapter(for: .switchRunningApp).metadata.id == "local.instant.running-app-switch")
        #expect(try registry.adapter(for: .switchRunningApp) is RunningAppSwitchCapabilityAdapter)
        #expect(try registry.adapter(for: .lookupRecentArtifacts).metadata.id == "local.instant.recent-artifacts")
        #expect(try registry.adapter(for: .lookupRecentArtifacts) is RecentArtifactsCapabilityAdapter)
        #expect(try registry.adapter(for: .playMedia).metadata.id == "local.media.open-result")
        #expect(try registry.adapter(for: .playMedia) is OpenMediaResultCapabilityAdapter)
        #expect(try registry.adapter(for: .getFinderSelection).metadata.id == "local.finder.read-selection")
        #expect(try registry.adapter(for: .getFinderSelection) is FinderSelectionCapabilityAdapter)
        #expect(try registry.adapter(for: .revealInFinder).metadata.id == "local.finder.reveal-path")
        #expect(try registry.adapter(for: .revealInFinder) is RevealInFinderCapabilityAdapter)
        #expect(try registry.adapter(for: .showPermissionReadiness).metadata.id == "local.permissions.readiness")
        #expect(try registry.adapter(for: .showPermissionReadiness) is PermissionReadinessCapabilityAdapter)
        #expect(try registry.adapter(for: .saveRoutine).metadata.id == "local.routines.save")
        #expect(try registry.adapter(for: .saveRoutine) is SaveRoutineCapabilityAdapter)
        #expect(try registry.adapter(for: .runRoutine).metadata.id == "local.routines.run")
        #expect(try registry.adapter(for: .runRoutine) is RunRoutineCapabilityAdapter)
        #expect(try registry.adapter(for: .createWorkspace).metadata.id == "local.workspaces.create")
        #expect(try registry.adapter(for: .createWorkspace) is CreateWorkspaceCapabilityAdapter)
        #expect(try registry.adapter(for: .editWorkspace).metadata.id == "local.workspaces.edit")
        #expect(try registry.adapter(for: .editWorkspace) is EditWorkspaceCapabilityAdapter)
        #expect(try registry.adapter(for: .openWorkspace).metadata.id == "local.workspaces.open")
        #expect(try registry.adapter(for: .openWorkspace) is OpenWorkspaceCapabilityAdapter)
        #expect(try registry.adapter(for: .invokeShortcut).metadata.id == "local.shortcuts.invoke")
        #expect(try registry.adapter(for: .invokeShortcut) is InvokeShortcutCapabilityAdapter)
        #expect(throws: CapabilityRegistryError.unsupportedOperation(.unsupported)) {
            _ = try registry.adapter(for: .unsupported)
        }
    }

    @Test
    func defaultRegistryMetadataIsComplete() {
        for metadata in CapabilityRegistry.default.metadata {
            #expect(metadata.id.hasPrefix("local."))
            #expect(!metadata.displayName.isEmpty)
            #expect(!metadata.description.isEmpty)
            #expect(metadata.version == "1.0")
            #expect(!metadata.operations.isEmpty)
            #expect(metadata.executorLocation == .localMac)
            #expect(CapabilityRiskTier.allCases.contains(metadata.defaultRiskTier))
            if metadata.plannerTools.isEmpty {
                #expect(metadata.id.hasPrefix("local.instant."))
            } else {
                #expect(metadata.operations.map(\.rawValue).sorted() == metadata.plannerTools.map(\.operation.rawValue).sorted())
            }

            for tool in metadata.plannerTools {
                #expect(!tool.name.isEmpty)
                #expect(!tool.description.isEmpty)
                #expect(!tool.dryRunBehavior.isEmpty)
            }
        }
    }

    @Test
    func permissionsMetadataIsDescriptiveOnlyForNow() throws {
        for metadata in CapabilityRegistry.default.metadata {
            #expect(metadata.requiredPermissions.allSatisfy { $0.enforcement == .descriptiveOnly })
        }

        let docx = try #require(CapabilityRegistry.default.metadata.first { $0.id == "local.documents.docx-to-pdf" })
        #expect(docx.requiredPermissions.map(\.requirement).contains(.desktopDocumentsAccess))
        #expect(docx.requiredPermissions.map(\.requirement).contains(.wordAutomation))

        let readiness = try #require(CapabilityRegistry.default.metadata.first { $0.id == "local.permissions.readiness" })
        #expect(readiness.defaultRiskTier == .tier0)
        #expect(readiness.requiredPermissions.isEmpty)
    }

    @Test
    func appWebsiteActionDescriptorsDeclarePermissionsRiskAndFallbacks() {
        let descriptors = AppWebsiteActionDescriptors.all
        let operations = descriptors.flatMap(\.supportedActions)

        #expect(operations.contains(.openApp))
        #expect(operations.contains(.openAppSearchURL))
        #expect(operations.contains(.openURL))
        #expect(operations.contains(.openGeneratedArtifact))
        #expect(operations.contains(.createLocalDraft))
        #expect(operations.contains(.openWorkspace))
        #expect(descriptors.allSatisfy { !$0.requiredPermissions.isEmpty })
        #expect(descriptors.allSatisfy { !$0.fallbackBehavior.isEmpty })
        #expect(AppWebsiteActionDescriptors.openAppSearchURL.defaultRiskTier == .tier1)
        #expect(AppWebsiteActionDescriptors.openGeneratedArtifact.defaultRiskTier == .tier1)
        #expect(AppWebsiteActionDescriptors.createLocalDraft.defaultRiskTier == .tier2)
    }

    @Test
    func registryRejectsDuplicateCapabilityIDs() {
        #expect(throws: CapabilityRegistryError.duplicateCapabilityID("local.test.duplicate")) {
            _ = try CapabilityRegistry(adapters: [
                MetadataOnlyCapabilityAdapter(metadata: testMetadata(id: "local.test.duplicate", operation: .openURL)),
                MetadataOnlyCapabilityAdapter(metadata: testMetadata(id: "local.test.duplicate", operation: .openApp))
            ])
        }
    }

    @Test
    func registryRejectsDuplicateOperations() {
        #expect(throws: CapabilityRegistryError.duplicateOperation(.openURL, "local.test.first", "local.test.second")) {
            _ = try CapabilityRegistry(adapters: [
                MetadataOnlyCapabilityAdapter(metadata: testMetadata(id: "local.test.first", operation: .openURL)),
                MetadataOnlyCapabilityAdapter(metadata: testMetadata(id: "local.test.second", operation: .openURL))
            ])
        }
    }

    private func testMetadata(id: String, operation: AgentOperation) -> CapabilityMetadata {
        CapabilityMetadata(
            id: id,
            displayName: "Test capability",
            description: "Test capability.",
            operations: [operation],
            plannerTools: [
                AgentTool(
                    operation: operation,
                    name: "Test tool",
                    description: "Test tool.",
                    requiredFields: [],
                    sideEffects: [],
                    dryRunBehavior: "Preview test tool."
                )
            ],
            defaultRiskTier: .tier0
        )
    }
}
