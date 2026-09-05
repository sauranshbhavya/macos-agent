import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct AgentPlanDecoderTests {
    @Test
    func decodesGoldenPlan() throws {
        let json = """
        {
          "summary": "Zip the three largest files.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "scan",
              "operation": "scan_select_largest_files",
              "description": "Scan the folder.",
              "inputPath": "~/Desktop",
              "outputPath": null,
              "count": 3,
              "targetURL": null
            },
            {
              "id": "zip",
              "operation": "create_zip",
              "description": "Create the archive.",
              "inputPath": "~/Desktop",
              "outputPath": "~/Desktop/largest.zip",
              "count": 3,
              "targetURL": null
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        #expect(plan.summary == "Zip the three largest files.")
        #expect(plan.steps.map(\.operation) == [.scanSelectLargestFiles, .createZip])
        #expect(plan.steps[0].count == 3)
    }

    /// **The schema and the decoder have to agree about `browserName`, or plans fail at runtime**
    /// (SONNY-157). The schema tells the model it may send the key; `AgentPlanDecoder.stepKeys` is an
    /// allowlist that rejects any step key it does not know. Adding a field to one and not the other
    /// is the drift this pins: a plan carrying the key would be refused wholesale, which presents as
    /// the planner failing rather than as a missing browser.
    @Test
    func decodesTheBrowserNameAStepCarries() throws {
        let json = """
        {
          "summary": "Open the release notes in Chrome.",
          "requiresConfirmation": false,
          "steps": [
            {
              "id": "open",
              "operation": "open_url",
              "description": "Open the release notes.",
              "targetURL": "https://example.com/notes",
              "browserName": "Chrome"
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        #expect(plan.steps[0].browserName == "Chrome")
    }

    /// The same key omitted decodes to `nil` rather than failing — the ordinary case, and the one
    /// SONNY-152's guarantee rests on.
    @Test
    func aStepWithNoBrowserNameDecodesToNil() throws {
        let json = """
        {
          "summary": "Open the release notes.",
          "requiresConfirmation": false,
          "steps": [
            {
              "id": "open",
              "operation": "open_url",
              "description": "Open the release notes.",
              "targetURL": "https://example.com/notes"
            }
          ]
        }
        """

        #expect(try AgentPlanDecoder.decodeStrict(from: json).steps[0].browserName == nil)
    }

    @Test
    func rejectsUnexpectedTopLevelKey() throws {
        let json = """
        {
          "summary": "Nope",
          "requiresConfirmation": false,
          "steps": [],
          "shell": "rm -rf"
        }
        """

        #expect(throws: AgentPlanDecodingError.unexpectedTopLevelKey("shell")) {
            try AgentPlanDecoder.decodeStrict(from: json)
        }
    }

    @Test
    func rejectsUnexpectedStepKey() throws {
        let json = """
        {
          "summary": "Nope",
          "requiresConfirmation": false,
          "steps": [
            {
              "id": "bad",
              "operation": "unsupported",
              "description": "Nope",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null,
              "appleScript": "display dialog"
            }
          ]
        }
        """

        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("appleScript")) {
            try AgentPlanDecoder.decodeStrict(from: json)
        }
    }

    @Test
    func rejectsUnknownOperation() throws {
        let json = """
        {
          "summary": "Nope",
          "requiresConfirmation": false,
          "steps": [
            {
              "id": "bad",
              "operation": "delete_everything",
              "description": "Nope",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null
            }
          ]
        }
        """

        #expect(throws: (any Error).self) {
            try AgentPlanDecoder.decodeStrict(from: json)
        }
    }

    @Test
    func decodesAppURLAndClarifyPlans() throws {
        let appJSON = """
        {
          "summary": "Open Safari.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "open-app",
              "operation": "open_app",
              "description": "Open Safari.",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null,
              "appName": "Safari",
              "question": null
            }
          ]
        }
        """

        let urlJSON = """
        {
          "summary": "Open GitHub.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "open-url",
              "operation": "open_url",
              "description": "Open GitHub.",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": "https://github.com",
              "appName": null,
              "question": null
            }
          ]
        }
        """

        let clarifyJSON = """
        {
          "summary": "Need a folder.",
          "requiresConfirmation": false,
          "steps": [
            {
              "id": "clarify",
              "operation": "clarify",
              "description": "Ask which folder to scan.",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null,
              "appName": null,
              "question": "Which folder should I scan?"
            }
          ]
        }
        """

        #expect(try AgentPlanDecoder.decodeStrict(from: appJSON).steps[0].operation == .openApp)
        #expect(try AgentPlanDecoder.decodeStrict(from: urlJSON).steps[0].operation == .openURL)
        let clarify = try AgentPlanDecoder.decodeStrict(from: clarifyJSON)
        #expect(clarify.steps[0].operation == .clarify)
        #expect(clarify.steps[0].question == "Which folder should I scan?")
    }

    @Test
    func decodesMediaOpenPlan() throws {
        let json = """
        {
          "summary": "Open Jimmy Cooks.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "play-media",
              "operation": "play_media",
              "description": "Open Jimmy Cooks by Drake in Apple Music.",
              "inputPath": null,
              "outputPath": null,
              "count": null,
              "targetURL": null,
              "appName": null,
              "question": null,
              "mediaProvider": "apple_music",
              "mediaTitle": "Jimmy Cooks",
              "mediaArtist": "Drake"
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        #expect(plan.steps[0].operation == .playMedia)
        #expect(plan.steps[0].mediaProvider == .appleMusic)
        #expect(plan.steps[0].mediaTitle == "Jimmy Cooks")
        #expect(plan.steps[0].mediaArtist == "Drake")
    }

    @Test
    func parsesResponsesOutputText() throws {
        let response = """
        {
          "id": "resp_123",
          "output": [
            {
              "type": "message",
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"summary\\":\\"HN\\",\\"requiresConfirmation\\":true,\\"steps\\":[{\\"id\\":\\"fetch\\",\\"operation\\":\\"fetch_hn_headlines\\",\\"description\\":\\"Fetch\\",\\"inputPath\\":null,\\"outputPath\\":null,\\"count\\":5,\\"targetURL\\":\\"https://news.ycombinator.com\\"}]}"
                }
              ]
            }
          ]
        }
        """

        let text = try OpenAIResponseParser.outputText(from: Data(response.utf8))
        let plan = try AgentPlanDecoder.decodeStrict(from: text)

        #expect(plan.steps[0].operation == .fetchHNHeadlines)
    }

    @Test
    func malformedPlannerJSONSurfacesAsSonnysOwnDecodingError() throws {
        // Truncated JSON: raw Foundation errors must not reach the user.
        #expect(throws: AgentPlanDecodingError.invalidJSON) {
            _ = try AgentPlanDecoder.decodeStrict(from: "{\"summary\":\"broken\"")
        }

        // A wrong field type passes the key allowlist and only fails inside JSONDecoder.
        let wrongType = """
        {"summary":"Zip","requiresConfirmation":true,"steps":[{"id":"scan","operation":"scan_select_largest_files","description":"Scan","count":"three"}]}
        """
        do {
            _ = try AgentPlanDecoder.decodeStrict(from: wrongType)
            Issue.record("Expected a type mismatch to be reported as a plan decoding error.")
        } catch let error as AgentPlanDecodingError {
            guard case .malformedPlan(let detail) = error else {
                Issue.record("Expected .malformedPlan, got \(error).")
                return
            }
            #expect(detail.contains("count"))
            #expect(error.errorDescription?.contains("could not read") == true)
        }

        // An unknown operation value likewise decodes past the key check.
        let unknownOperation = """
        {"summary":"X","requiresConfirmation":false,"steps":[{"id":"a","operation":"format_hard_drive","description":"No"}]}
        """
        #expect(throws: AgentPlanDecodingError.self) {
            _ = try AgentPlanDecoder.decodeStrict(from: unknownOperation)
        }
    }

    @Test
    func nonJSONResponseBodySurfacesAsMissingOutputText() throws {
        #expect(throws: PlannerError.missingOutputText) {
            _ = try OpenAIResponseParser.outputText(from: Data("<html>502 Bad Gateway</html>".utf8))
        }
    }

    /// Pins `AgentPlanDecoder.stepKeys` — a `private` allowlist that `decodeStrict` rejects anything
    /// outside — against the four fields `edit_workspace` introduced.
    ///
    /// It is a second list, not the same one `PlannerBoundaryTests` already pins:
    /// `AgentPlanSchema.stepRequiredKeys` is what the *model* is told to emit, `stepKeys` is what the
    /// decoder will *accept*, and nothing couples them. They agree today, and they can drift apart
    /// with the whole suite green — at which point a well-formed planner response for a real user
    /// command dies at `unexpectedStepKey`, at runtime, with no test having failed. Decoding a plan
    /// that actually carries all four keys is what makes that drift impossible in this direction.
    @Test
    func decodesAnEditWorkspacePlanCarryingEveryNewStepKey() throws {
        let json = """
        {
          "summary": "Edit the Client Alpha workspace.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "edit",
              "operation": "edit_workspace",
              "description": "Edit the workspace.",
              "workspaceName": "Client Alpha",
              "workspaceApps": ["Notes"],
              "workspaceURLs": ["https://github.com"],
              "workspaceFileLocations": ["~/Documents/ClientAlpha"],
              "workspaceAppsToRemove": ["Slack"],
              "workspaceURLsToRemove": ["https://example.com"],
              "workspaceFileLocationsToRemove": ["~/Documents/Old"]
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        let step = try #require(plan.steps.first)
        #expect(step.operation == .editWorkspace)
        #expect(step.workspaceName == "Client Alpha")
        #expect(step.workspaceApps == ["Notes"])
        #expect(step.workspaceURLs == ["https://github.com"])
        #expect(step.workspaceFileLocations == ["~/Documents/ClientAlpha"])
        #expect(step.workspaceAppsToRemove == ["Slack"])
        #expect(step.workspaceURLsToRemove == ["https://example.com"])
        #expect(step.workspaceFileLocationsToRemove == ["~/Documents/Old"])
    }

    /// The same drift, for `rename`'s own key (SONNY-385, PR #200 F2).
    ///
    /// **`newName` is `required` in the schema, so this drift is not one field going missing — it is
    /// every rename command a real user types dying at `unexpectedStepKey`, at run time.** The
    /// structured-output subset makes the model send every property in `stepRequiredKeys`, so a
    /// well-formed planner response for "rename this to invoice-march" carries the key whether or
    /// not the decoder will accept it.
    ///
    /// The asymmetry is what makes it invisible: the schema half is pinned **by value** in two
    /// places (`PlannerBoundaryTests.theAgentPlanSchemaKeepsItsStrictShape` and the serialized
    /// fixture), and before this test the decoder half was pinned by nothing — a reviewer's mutant
    /// dropping `"newName"` from `stepKeys` survived the whole suite while the mirror mutant on the
    /// schema list died by two tests. `AutomationStoresTests`' `plannerWritable` set names the key,
    /// but that is a claim *about* `stepKeys` rather than a check *of* it, which is the distinction
    /// that file's own doc comment already draws about `resolverOnly`.
    @Test
    func decodesARenamePlanCarryingTheNewNameKey() throws {
        let json = """
        {
          "summary": "Rename the scan.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "rename",
              "operation": "rename",
              "description": "Rename the file.",
              "inputPath": "~/Documents/scan1.pdf",
              "newName": "invoice-march.pdf"
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: json)

        let step = try #require(plan.steps.first)
        #expect(step.operation == .rename)
        #expect(step.inputPath == "~/Documents/scan1.pdf")
        // Asserted by value rather than for being non-nil: a decoder that accepted the key and
        // dropped the value would leave `renameSpec` refusing every rename for a missing newName,
        // which is the same run-time failure by a quieter route.
        #expect(step.newName == "invoice-march.pdf")
    }

    /// The other half of the same allowlist: a key outside it is still rejected, so the test above
    /// pins acceptance of exactly four new names rather than the removal of the check itself.
    @Test
    func aStepKeyOutsideTheAllowlistIsStillRejected() throws {
        let json = """
        {"summary":"X","requiresConfirmation":false,"steps":[{"id":"a","operation":"edit_workspace","description":"No","workspaceFolders":["~/Documents"]}]}
        """

        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("workspaceFolders")) {
            _ = try AgentPlanDecoder.decodeStrict(from: json)
        }
    }
}
