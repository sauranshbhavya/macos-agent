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
    /// The app menu's "About Sonny" item, the same shape as `settingsRequests`: the account
    /// menu's own row sets `isAboutPresented` directly, and the menu bar reaches it through here.
    @Published var aboutRequests = 0
    /// The Help menu's "Keyboard shortcuts" item, the third of the same shape. The window keeps
    /// its own hidden ⌘/ button for when it is key; this door is for the menu, which also answers
    /// ⌘/ while the widget is key and puts the item under Help's own search field.
    @Published var shortcutsRequests = 0
}
