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
}
