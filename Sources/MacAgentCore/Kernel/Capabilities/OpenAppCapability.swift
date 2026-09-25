import AppKit
import Foundation

/// `open_app` v1: opens an installed app or brings it forward. Floor effect: navigate.
public struct OpenAppCapability: Capability {
    public let name = "open_app"
    public let version = 1

    struct Args: Decodable {
        let app: String
    }

    struct Resolved: Sendable {
        let app: InstalledApp
    }

    private let resolver: any InstalledAppResolving
    private let opener: @Sendable (InstalledApp) async throws -> Void

    public init(
        resolver: any InstalledAppResolving = InstalledAppResolver.shared,
        opener: @escaping @Sendable (InstalledApp) async throws -> Void = OpenAppCapability.openWithWorkspace
    ) {
        self.resolver = resolver
        self.opener = opener
    }

    public func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        let decoded: Args
        do {
            decoded = try JSONValue.object(args).decode(Args.self)
        } catch {
            throw CapabilityPrepareError.invalidArguments("open_app needs the app's name or bundle id")
        }
        guard let app = resolver.resolve(decoded.app) else {
            throw CapabilityPrepareError.targetNotFound("No installed app matches \"\(decoded.app)\".")
        }
        return PreparedAction(
            actionID: actionID,
            effect: .navigate,
            targetIdentity: app.bundleIdentifier,
            content: app.applicationURL.path,
            preview: ApprovalPreview(title: "Open \(app.displayName)"),
            retry: .idempotent,
            payload: Resolved(app: app)
        )
    }

    public func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        guard let resolved = prepared.payload as? Resolved else {
            return .failed(.executionError, "open_app was prepared by another capability")
        }
        if Task.isCancelled { return .failed(.cancelled, "Stopped before opening \(resolved.app.displayName).") }
        do {
            try await opener(resolved.app)
            return .done("\(resolved.app.displayName) is open.")
        } catch {
            return .failed(.executionError, "\(resolved.app.displayName) could not be opened.")
        }
    }

    @MainActor
    public static func openWithWorkspace(_ app: InstalledApp) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app.applicationURL, configuration: configuration)
    }
}
