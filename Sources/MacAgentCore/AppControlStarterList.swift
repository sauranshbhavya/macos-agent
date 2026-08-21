import Foundation

/// The apps Normal mode lets Sonny control without asking, before the user has allowed anything.
///
/// **Founder decision, 2026-08-16 (SONNY-104), and its ground.** Apps a non-technical Mac user has.
/// **Every IDE and code editor is off the list**, and the reason is kept because it is the reasoning
/// rather than a detail: *the exclusion is about embedded shells, not about the apps being
/// dangerous.* An IDE with a built-in terminal is exactly the gap no name list can reach, so it does
/// not get silent standing. A developer who wants Sonny inside VS Code approves it by hand — one
/// click, once, ever.
///
/// **Derived, never `MacAppCatalog.default`.** That table
/// (`Sources/MacAgentCore/MacAppService.swift`) is an alias table for resolving a spoken app name
/// and has gated nothing since C12; it contains `com.apple.Terminal` and `com.microsoft.VSCode`, so
/// reusing it here would have shipped a terminal *and* an embedded-shell host on the silent side of
/// the gate. This is a separate, purpose-made list, and
/// `theStarterListIsNotTheAppCatalogAndContainsNeitherOfItsTwoDisqualifyingEntries` pins that it
/// stays one.
///
/// **Lowercased, because that is the form membership compares in.** Same shape as
/// `ScreenControlPolicy.terminalBundleIdentifiers`: entries are already
/// ``ScreenControlPolicy/normalize(_:)``'s output, so a comparison folds the candidate and nothing
/// else. Several bundles spell themselves with capitals — Launch Services says `com.apple.Notes`,
/// `com.apple.iWork.Pages`, `com.google.Chrome` — and those spellings are the ones macOS is *asked*
/// with, never the ones compared. Do not "restore" the capitals here;
/// `everyEntryIsAlreadyInTheCanonicalComparisonForm` fails if anyone does.
///
/// ## Evidence, split by how each identifier was obtained
///
/// Provenance only, in the manner the deny list's record uses, and split rather than averaged
/// because the two claims have different strengths and a reader deciding whether to trust an entry
/// deserves to know which kind it is.
///
/// - **Read from the bundle's own `Info.plist` on the founder's Mac, 2026-08-20 (38):** every Apple
///   entry, plus Chrome, the four Microsoft Office apps, Teams, Slack, Zoom, Spotify, WhatsApp,
///   Telegram, Notion and Discord. Enumerated by walking `/Applications`, `/System/Applications` and
///   `/System/Applications/Utilities` and reading `CFBundleIdentifier` out of each bundle, then
///   lowercasing — not recalled.
/// - **From each project's published bundle configuration, no bundle inspected (3):** Firefox,
///   Microsoft Edge, Signal. Not installed on that Mac, so nothing there could confirm them.
///
/// **A wrong identifier on this list fails safe**, which is the opposite of the deny list and worth
/// saying: an allow-list entry that matches nothing simply means the app prompts, the way an
/// unlisted app does. That is why the second group is acceptable at all here and why a correction is
/// cheap. `theEvidenceSplitMatchesTheStarterList` fails if this list changes without this record
/// changing with it.
///
/// ## What this list cannot do — stated plainly, not discovered later
///
/// This is a **name-based list with the same incompleteness SONNY-102 is about**, inverted. A
/// name-based list is never complete: an app nobody thought of is not on it. Inverted, that failure
/// is the safe one — an unlisted app *prompts* rather than being driven silently — which is
/// genuinely better than the deny list's direction and still leaves a curated list somebody
/// maintains. Nobody should read a green suite as proof that this list is complete; it is proof
/// that what is on it is allowed to be.
///
/// ## Deliberately absent, each for its own reason
///
/// Every one of these is an app a non-technical Mac user has, so absence here is a decision rather
/// than an oversight:
///
/// - **Finder** (`com.apple.finder`) — the file system's own interface. Driving it silently is
///   driving the file system silently, and Sonny's path whitelist does not reach synthesized clicks.
/// - **System Settings** (`com.apple.systempreferences`) — the one app whose entire content is the
///   machine's authority switches: privacy, security, accounts, network. Familiar is not the same as
///   safe to drive unasked.
/// - **Passwords** (`com.apple.passwords`) — the credential vault.
/// - **Home** (`com.apple.home`) — physical devices, in a house that may contain other people.
/// - **Shortcuts** (`com.apple.shortcuts`) — on the founder's own ground rather than a new one: a
///   Shortcut can contain a Run Shell Script action, which is the embedded-shell gap wearing a
///   different icon. It is in ``excludedCodeAndScriptEditorIdentifiers`` for that reason.
///
/// None of these is a *refusal*. They are apps this list does not pre-allow, so Sonny asks about
/// them, and the user may allow any of them by hand. The only refusals in this product are the
/// terminal deny list and the runtime screen check, and both sit above the consent model entirely.
public enum AppControlStarterList {
    /// The starter entries, lowercased. Comments name the app each identifier belongs to.
    public static let bundleIdentifiers: Set<String> = [
        // Apple, on any Mac a non-technical user has.
        "com.apple.safari",             // Safari
        "com.apple.notes",              // Notes
        "com.apple.mail",               // Mail
        "com.apple.ical",               // Calendar — the identifier still says iCal
        "com.apple.reminders",          // Reminders
        "com.apple.mobilesms",          // Messages — the identifier still says SMS
        "com.apple.preview",            // Preview
        "com.apple.photos",             // Photos
        "com.apple.music",              // Music
        "com.apple.maps",               // Maps
        "com.apple.addressbook",        // Contacts — the identifier still says AddressBook
        "com.apple.facetime",           // FaceTime
        "com.apple.textedit",           // TextEdit
        "com.apple.calculator",         // Calculator
        "com.apple.iwork.pages",        // Pages
        "com.apple.iwork.numbers",      // Numbers
        "com.apple.iwork.keynote",      // Keynote
        "com.apple.freeform",           // Freeform
        "com.apple.ibooksx",            // Books — the identifier still says iBooks
        "com.apple.podcasts",           // Podcasts
        "com.apple.tv",                 // TV
        "com.apple.news",               // News
        "com.apple.weather",            // Weather
        "com.apple.voicememos",         // Voice Memos
        "com.apple.stickies",           // Stickies

        // The browsers and productivity apps a non-technical Mac user actually installs.
        "com.google.chrome",            // Google Chrome
        "org.mozilla.firefox",          // Firefox — published configuration, no bundle inspected
        "com.microsoft.edgemac",        // Microsoft Edge — published configuration, no bundle inspected
        "com.microsoft.word",           // Microsoft Word
        "com.microsoft.excel",          // Microsoft Excel
        "com.microsoft.powerpoint",     // Microsoft PowerPoint
        "com.microsoft.outlook",        // Microsoft Outlook
        "com.microsoft.teams2",         // Microsoft Teams — Teams classic is a retired build and is
                                        // deliberately absent; anyone still on it gets asked, which
                                        // is the safe direction
        "com.tinyspeck.slackmacgap",    // Slack
        "us.zoom.xos",                  // Zoom
        "com.spotify.client",           // Spotify
        "net.whatsapp.whatsapp",        // WhatsApp
        "ru.keepcoder.telegram",        // Telegram
        "org.whispersystems.signal-desktop", // Signal — published configuration, no bundle inspected
        "com.hnc.discord",              // Discord
        "notion.id"                     // Notion
    ]

    /// Code editors, IDEs and script hosts — the founder's exclusion, by identifier.
    ///
    /// **This is a guard, not a deny list, and the difference matters.** Nothing in production
    /// refuses an app for being here; an app on this list is simply one that must never appear on
    /// the starter list, which is what `noStarterEntryIsACodeEditorOrScriptHost` checks. So an
    /// editor missing from here is not a hole in the product — the user is still asked about it,
    /// like any unlisted app — it only makes that one guard less sharp. Adding an entry costs a
    /// line.
    ///
    /// **Script hosts are here on the founder's own ground rather than a widened rule.** The stated
    /// reason for excluding editors is embedded shells; Script Editor's purpose is running
    /// AppleScript, `do shell script` included, Automator has a Run Shell Script action and so does
    /// Shortcuts. Calling those "IDEs" would be a stretch, and leaving them out while excluding VS
    /// Code for having a terminal panel would apply the founder's reason to some of its own cases and
    /// not others.
    ///
    /// **Evidence.** Read from the bundle's own `Info.plist` on the founder's Mac, 2026-08-20 (9):
    /// Visual Studio Code, Cursor, IntelliJ IDEA, PyCharm, Xcode, Sublime Text, Script Editor,
    /// Automator, Shortcuts. From each project's published bundle configuration, no bundle inspected
    /// (3): VS Code Insiders, Zed, WebStorm. `theEvidenceSplitMatchesTheExcludedEditorList` fails if
    /// this list changes without that record changing with it.
    public static let excludedCodeAndScriptEditorIdentifiers: Set<String> = [
        "com.microsoft.vscode",              // Visual Studio Code
        "com.microsoft.vscodeinsiders",      // VS Code Insiders — published configuration
        "com.todesktop.230313mzl4w4u92",     // Cursor — the opaque id is real, it is a ToDesktop build
        "com.jetbrains.intellij",            // IntelliJ IDEA
        "com.jetbrains.pycharm",             // PyCharm
        "com.jetbrains.webstorm",            // WebStorm — published configuration
        "com.apple.dt.xcode",                // Xcode
        "com.sublimetext.4",                 // Sublime Text
        "dev.zed.zed",                       // Zed — published configuration
        "com.apple.scripteditor2",           // Script Editor — AppleScript, `do shell script` included
        "com.apple.automator",               // Automator — has a Run Shell Script action
        "com.apple.shortcuts"                // Shortcuts — has a Run Shell Script action
    ]
}
