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
}
