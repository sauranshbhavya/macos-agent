import AppKit
import MacAgentCore

/// Builds the V2 kernel this app runs on: one `TaskController` with the typed operations, screen
/// control and the instant path, and the `TaskDesk` every entry point goes through.
@MainActor
enum SonnyKernel {
    /// Where the gateway is when this build has no host configured: nothing answers there, so a
    /// model-backed request fails at once with the plain server error (decision 13).
    static let unreachableGateway = URL(string: "https://gateway.invalid")!

    static func makeDesk(client: SonnyBackendClient, stores: KernelStores, defaults: UserDefaults = .standard) -> TaskDesk {
        let base = SonnyBackendHost.resolve()?.baseURL ?? unreachableGateway
        let context: @MainActor @Sendable () -> CapabilityExecutionContext = { [stores] in
            stores.capabilityContext(
                eventKit: EventKitStore.forThisMac(),
                focusRestorer: FocusRestorer.forThisMac(),
                permissions: PermissionReadinessService()
            )
        }
        let checker = SystemScreenCapturePermissionChecker()
        let standing = KernelStores.standing(approvedApps: stores.approvedApps)
        let controller = TaskController(
            url: GatewayEndpoint.sessionURL(base: base),
            transport: URLSessionGatewayTransport(),
            credentials: client,
            identity: .init(
                deviceID: GatewayDeviceIdentity.deviceID(),
                appVersion: String(SonnyClientIdentity.version.prefix(32)),
                osVersion: String(SonnyClientIdentity.platform.prefix(32))
            ),
            ledgers: stores.ledgers,
            capabilities: StandardCapabilities.all(
                context: context,
                finderRevealer: { NSWorkspace.shared.activateFileViewerSelecting($0) },
                routines: stores.routines
            ),
            localCapabilities: InstantPath.localCapabilities(context: context),
            screenTools: Set(ScreenToolName.allCases),
            screenFactory: {
                ScreenController(dependencies: .init(
                    driver: { manifest in try CuaDriverLibrary(manifest: manifest) },
                    standing: standing
                ))
            },
            permissions: {
                .init(
                    accessibility: checker.isAccessibilityTrusted() ? .granted : .denied,
                    screenRecording: checker.hasScreenRecordingPermission() ? .granted : .denied,
                    automation: []
                )
            }
        )
        return TaskDesk(
            controller: controller,
            history: stores.history,
            routines: stores.routines,
            watchers: stores.watchers,
            instant: { text in
                let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                guard case .plan(let plan)? = stores.instantResolver(runningApps: running).resolve(command: text) else { return nil }
                return InstantPath.actions(for: plan)
            },
            mode: {
                defaults.string(forKey: SonnyAppModel.modeKey).flatMap(AgentInteractionMode.init(rawValue:)) ?? .normal
            },
            context: {
                guard let front = NSWorkspace.shared.frontmostApplication,
                      front.processIdentifier != getpid(),
                      let bundleID = front.bundleIdentifier else { return .init() }
                return .init(frontmostApp: WireAppRef(bundleID: bundleID, name: front.localizedName ?? bundleID))
            }
        )
    }
}
