import Foundation

/// The one door from AppKit's main menu into Command Center's own state. `AppDelegate` builds the
/// main menu and holds no reference to the SwiftUI view that owns Settings' presentation, so a
/// menu press cannot set that view's `@State` directly — it bumps this counter instead, and
/// `CommandCenterView`'s `onChange` turns the bump into the same presentation its own account-menu
/// row drives. Owned by `AppWindowCoordinator`, one instance for the app's lifetime, injected into
/// the Command Center root beside `appearanceModel`.
@MainActor
final class CommandCenterCommands: ObservableObject {
    @Published var settingsRequests = 0
    /// Set by the ⌘K jump-to palette (phase 5) when it activates a routine row: the id
    /// (`StoredRoutine.id`, which is the routine's name) `RoutinesView` should open its detail
    /// sheet for. Consumed the same two-door way `TasksFoundationView.consumeTaskDetailRequest`
    /// consumes `taskDetailRequest` — an `onAppear` for a request that arrived while Routines was
    /// not mounted, and an `onChange` for one that arrives while it is — and cleared either way.
    @Published var routineToOpen: String?
    /// The workspace-jump twin of `routineToOpen`, holding a `StoredWorkspace.name` for
    /// `WorkspacesView` to resolve the same way its own card taps do.
    @Published var workspaceToOpen: String?
}
