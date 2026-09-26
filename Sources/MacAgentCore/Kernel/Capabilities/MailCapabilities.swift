import Foundation

/// Milestone B's workflow (V2 plan phase 5): a Mail message composed from typed arguments and sent
/// only with a fresh approval of its exact recipients and content.
///
/// Mail's message body can't be written through Accessibility, so both steps are reviewed AppleScript
/// templates. `compose_mail` leaves a visible, unsent draft. `send_mail` reads that draft back as it
/// is now — the person may have edited it — and that reading is what the approval covers: the
/// runtime prepares again just before sending, and any change since the approval voids it. A send
/// that runs past its deadline, that Mail doesn't answer in time, or that is stopped midway may or
/// may not have gone out, so it ends outcome_unknown and is never tried again.
public enum MailCapabilities {
    public static let bundleIdentifier = "com.apple.mail"
    static let timeout: TimeInterval = 30
    /// Between the fields of a draft read back from Mail: ASCII record separator, which a person's
    /// text doesn't contain.
    static let separator = "\u{1E}"

    static let composeScript = """
    on run argv
      set theSubject to item 2 of argv
      set theBody to item 3 of argv
      set toCount to (item 4 of argv) as integer
      tell application "Mail"
        set theMessage to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
        tell theMessage
          repeat with i from 1 to toCount
            make new to recipient at end of to recipients with properties {address:(item (4 + i) of argv)}
          end repeat
          repeat with i from (5 + toCount) to (count of argv)
            make new cc recipient at end of cc recipients with properties {address:(item i of argv)}
          end repeat
        end tell
        return (id of theMessage) as string
      end tell
    end run
    """

    static let readScript = """
    on run argv
      set theID to (item 2 of argv) as integer
      set separator to ASCII character 30
      tell application "Mail"
        set theMessage to first outgoing message whose id is theID
        set AppleScript's text item delimiters to linefeed
        set toList to (address of every to recipient of theMessage) as string
        set ccList to (address of every cc recipient of theMessage) as string
        set AppleScript's text item delimiters to ""
        return (subject of theMessage) & separator & (content of theMessage as string) & separator & toList & separator & ccList
      end tell
    end run
    """

    static let sendScript = """
    on run argv
      set theID to (item 2 of argv) as integer
      tell application "Mail"
        send (first outgoing message whose id is theID)
      end tell
      return "sent"
    end run
    """

    public static func all(runner: any AppleScriptRunning = OsascriptRunner()) -> [any Capability] {
        [ComposeMailCapability(runner: runner), SendMailCapability(runner: runner)]
    }

    static func addresses(_ value: JSONValue?, required: Bool) throws -> [String] {
        switch value {
        case nil, .null?:
            if required { throw CapabilityPrepareError.invalidArguments("to needs at least one address.") }
            return []
        case .array(let items)?:
            let addresses = try items.map { item -> String in
                guard case .string(let address) = item else {
                    throw CapabilityPrepareError.invalidArguments("Each address must be text.")
                }
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else {
                    throw CapabilityPrepareError.invalidArguments("\"\(trimmed)\" isn't an email address.")
                }
                return trimmed
            }
            if required && addresses.isEmpty { throw CapabilityPrepareError.invalidArguments("to needs at least one address.") }
            return addresses
        default:
            throw CapabilityPrepareError.invalidArguments("Addresses must be a list.")
        }
    }

    static func outcome(for error: Error, sending: Bool) -> CapabilityOutcome {
        switch error as? AppleScriptRunError {
        case .notAuthorized?:
            return .failed(.permissionDenied, "Sonny isn't allowed to control Mail. Allow it in System Settings › Privacy & Security › Automation.")
        case .timedOut? where sending:
            return CapabilityOutcome(
                status: .outcomeUnknown,
                error: OutcomeError(code: .timeout, message: "Mail didn't answer in time, so Sonny can't tell whether the message went out.")
            )
        case .timedOut?:
            return .failed(.timeout, "Mail didn't answer in time.")
        case .failed(let message)?:
            return .failed(.executionError, "Mail refused: \(message.prefix(300))")
        case nil where error is CancellationError && sending:
            return CapabilityOutcome(
                status: .outcomeUnknown,
                error: OutcomeError(code: .cancelled, message: "Sonny stopped while Mail was sending, so it can't tell whether the message went out.")
            )
        case nil where error is CancellationError:
            return .failed(.cancelled, "Stopped while Mail was writing the draft.")
        case nil:
            return .failed(.executionError, "Mail couldn't be reached.")
        }
    }
}

struct ComposeMailCapability: Capability {
    let name = "compose_mail"
    let version = 1
    let runner: any AppleScriptRunning

    struct Draft: Sendable {
        let to: [String]
        let cc: [String]
        let subject: String
        let body: String
    }

    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        let to = try MailCapabilities.addresses(args["to"], required: true)
        let cc = try MailCapabilities.addresses(args["cc"], required: false)
        guard case .string(let subject)? = args["subject"], case .string(let body)? = args["body"] else {
            throw CapabilityPrepareError.invalidArguments("compose_mail needs a subject and a body.")
        }
        return PreparedAction(
            actionID: actionID,
            effect: .create,
            targetIdentity: "mail:new",
            content: ([to.joined(separator: ","), cc.joined(separator: ","), subject, body]).joined(separator: MailCapabilities.separator),
            preview: ApprovalPreview(
                title: "Write a new email in Mail",
                details: ["To: \(to.joined(separator: ", "))"] + (cc.isEmpty ? [] : ["Cc: \(cc.joined(separator: ", "))"])
                    + ["Subject: \(subject)", String(body.prefix(500))]
            ),
            retry: .never,
            payload: Draft(to: to, cc: cc, subject: subject, body: body)
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let draft = prepared.payload as? Draft else { return .failed(.executionError, "compose_mail was prepared elsewhere.") }
        do {
            let id = try await runner.run(
                MailCapabilities.composeScript,
                arguments: [draft.subject, draft.body, String(draft.to.count)] + draft.to + draft.cc,
                timeout: MailCapabilities.timeout
            )
            guard Int(id) != nil else { return .failed(.executionError, "Mail made the draft but didn't say which it is.") }
            return .done("Draft \(id) is open in Mail, unsent. send_mail with draft \"\(id)\" sends it.")
        } catch {
            return MailCapabilities.outcome(for: error, sending: false)
        }
    }
}

struct SendMailCapability: Capability {
    let name = "send_mail"
    let version = 1
    let runner: any AppleScriptRunning

    struct Planned: Sendable {
        let draft: String
    }

    /// Reads the draft as it is right now. Called for the approval and again just before sending,
    /// and the approval holds only while the two readings match.
    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        guard case .string(let draft)? = args["draft"], Int(draft) != nil else {
            throw CapabilityPrepareError.invalidArguments("send_mail needs the draft id compose_mail reported.")
        }
        let reading: String
        do {
            reading = try await runner.run(MailCapabilities.readScript, arguments: [draft], timeout: MailCapabilities.timeout)
        } catch AppleScriptRunError.notAuthorized {
            throw CapabilityPrepareError.permissionDenied("Sonny isn't allowed to control Mail.")
        } catch {
            throw CapabilityPrepareError.targetNotFound("That draft isn't open in Mail any more.")
        }
        let fields = reading.components(separatedBy: MailCapabilities.separator)
        guard fields.count == 4 else { throw CapabilityPrepareError.targetNotFound("Mail's draft couldn't be read.") }
        let subject = fields[0]
        let body = fields[1]
        let to = fields[2].split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let cc = fields[3].split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !to.isEmpty else { throw CapabilityPrepareError.invalidArguments("The draft has no recipient.") }
        return PreparedAction(
            actionID: actionID,
            effect: .external,
            targetIdentity: "mail:draft:\(draft)",
            content: [to.joined(separator: ","), cc.joined(separator: ","), subject, body].joined(separator: MailCapabilities.separator),
            preview: ApprovalPreview(
                title: "Send this email",
                details: ["To: \(to.joined(separator: ", "))"] + (cc.isEmpty ? [] : ["Cc: \(cc.joined(separator: ", "))"])
                    + ["Subject: \(subject)", String(body.prefix(1000))]
            ),
            retry: .never,
            payload: Planned(draft: draft)
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let planned = prepared.payload as? Planned else { return .failed(.executionError, "send_mail was prepared elsewhere.") }
        do {
            _ = try await runner.run(MailCapabilities.sendScript, arguments: [planned.draft], timeout: MailCapabilities.timeout)
            return .done("Mail sent draft \(planned.draft).")
        } catch {
            return MailCapabilities.outcome(for: error, sending: true)
        }
    }
}
