import AppKit
import Testing
@testable import MacAgent

/// Sonny quits while a sheet is up (SONNY-448).
///
/// **What is held here and what only the founders can hold.** A test process cannot call
/// `NSApp.terminate` — reaching it ends the run rather than failing it — so nothing here watches the
/// app quit. What is held is the property the quit depends on, read off real windows: every window's
/// `preventsApplicationTerminationWhenModal` is off once a sheet begins, which is the one thing AppKit
/// checks before refusing. That the refusal is AppKit's, silent, and answers every route including
/// the Dock's was measured outside this repository with a standalone probe, recorded in the
/// changelog entry for `fix/quit-under-a-sheet`; that ⌘Q, the menus, the Dock and Relaunch Sonny now
/// end the packaged app is the manual-test rows beside it.
@Suite
@MainActor
struct SheetTerminationReleaseTests {
    /// **The hold is released on every window the moment any sheet begins.** Both windows start
    /// held, read rather than assumed, so the `false` afterwards is the observer's doing and not a
    /// default that happened to agree. The sheet is released although it is in no parent's `sheets`
    /// — which is exactly the state AppKit is in when it posts this notification.
    @Test
    func aSheetBeginningReleasesEveryWindowsHoldOnTermination() {
        let center = NotificationCenter()
        let parent = Self.makeWindow()
        let sheet = Self.makeWindow()
        #expect(parent.preventsApplicationTerminationWhenModal, "AppKit's default, which the fix exists for")
        #expect(sheet.preventsApplicationTerminationWhenModal)
        let observation = SheetTerminationRelease.install(on: center, windows: { [parent, sheet] })
        defer { center.removeObserver(observation) }

        center.post(name: NSWindow.willBeginSheetNotification, object: parent)

        #expect(!parent.preventsApplicationTerminationWhenModal)
        #expect(!sheet.preventsApplicationTerminationWhenModal)
    }

    /// Keyed to a sheet beginning and to nothing else, so the observer is not merely clearing the
    /// flag on whatever arrives. The two notifications posted are the ones a sheet's own life does
    /// post around it.
    @Test
    func nothingIsReleasedBeforeASheetBegins() {
        let center = NotificationCenter()
        let window = Self.makeWindow()
        let observation = SheetTerminationRelease.install(on: center, windows: { [window] })
        defer { center.removeObserver(observation) }

        center.post(name: NSWindow.didEndSheetNotification, object: window)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.preventsApplicationTerminationWhenModal)
    }

    /// **A real sheet, begun by AppKit, is released by the time it is attached.** The two tests above
    /// post the notification themselves, so they would pass unchanged if AppKit stopped posting it
    /// for a sheet, or posted it after the sheet was already up; this one begins a sheet the way
    /// SwiftUI's own presentation does and reads the attached window.
    @Test
    func aSheetAppKitBeginsIsAttachedAlreadyReleased() throws {
        let parent = Self.makeWindow()
        let sheet = Self.makeWindow()
        #expect(sheet.preventsApplicationTerminationWhenModal, "held before it begins")
        let observation = SheetTerminationRelease.install(on: .default, windows: { [parent, sheet] })
        defer { NotificationCenter.default.removeObserver(observation) }
        // AppKit attaches no sheet to a window that was never on screen.
        parent.orderFrontRegardless()
        defer { parent.orderOut(nil) }

        parent.beginSheet(sheet)
        defer { parent.endSheet(sheet) }

        let attached = try #require(parent.attachedSheet, "the sheet attached")
        #expect(attached === sheet)
        #expect(!attached.preventsApplicationTerminationWhenModal)
    }

    /// **The app installs it at launch, over its real windows, before any sheet can exist.** A scan,
    /// because `applicationDidFinishLaunching` cannot run in a test process. Before the first-run
    /// decision and before Command Center is shown, since either can put a sheet up; on the default
    /// center, which is where AppKit posts; over `NSApp.windows`, which is what holds the sheet at the
    /// moment the notification arrives; and kept in a property. One installation in the target.
    @Test
    func theAppInstallsTheReleaseAtLaunchBeforeAnySheetCanExist() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let launch = try MacAgentSource.braceBlock(
            of: delegate,
            openedBy: "func applicationDidFinishLaunching(_ notification: Notification) {"
        )
        let installation = "sheetTerminationObservation = SheetTerminationRelease.install("
        #expect(MacAgentSource.count(of: installation, inText: launch) == 1)
        let install = try #require(launch.range(of: installation)).lowerBound
        let arguments = try MacAgentSource.region(of: launch, from: installation, to: ")\n")
        #expect(arguments.contains("on: .default"))
        #expect(arguments.contains("windows: { NSApp.windows }"))
        let firstRunDecision = try #require(launch.range(of: "decideFirstRunAfterRestoringTheSession()")).lowerBound
        let commandCenterShown = try #require(launch.range(of: "windowCoordinator.showCommandCenter()")).lowerBound
        #expect(install < firstRunDecision, "installed before first run can present its sheet")
        #expect(install < commandCenterShown, "installed before Command Center, which hosts every sheet")

        var installSites: [String: Int] = [:]
        for url in try MacAgentSource.appSourceFiles() {
            let count = MacAgentSource.count(of: "SheetTerminationRelease.install(", inText: try MacAgentSource.read(url))
            if count > 0 { installSites[MacAgentSource.relativePath(of: url)] = count }
        }
        #expect(installSites == ["AppDelegate.swift": 1], "found \(installSites)")
    }

    private static func makeWindow() -> NSWindow {
        // `NSApp` is nil in a test process until something asks for it, and a window needs one.
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
