import Foundation
import Testing
@testable import MacAgentCore

/// A stand-in for the system's foreground: which pid is in front, and what asking and opening do.
private final class FakeForeground: @unchecked Sendable {
    private let lock = NSLock()
    private var front: pid_t?
    private var activateWorks: Bool
    private var openWorks: Bool
    private(set) var calls: [String] = []

    init(front: pid_t?, activateWorks: Bool, openWorks: Bool) {
        self.front = front
        self.activateWorks = activateWorks
        self.openWorks = openWorks
    }

    var seam: WorkspaceScreenApps.Foreground {
        WorkspaceScreenApps.Foreground(
            frontmost: { self.lock.withLock { self.front } },
            activate: { pid in
                self.lock.withLock {
                    self.calls.append("activate")
                    // The request is accepted either way; whether the app comes forward is the question.
                    if self.activateWorks { self.front = pid }
                    return true
                }
            },
            open: { pid in
                self.lock.withLock {
                    self.calls.append("open")
                    if self.openWorks { self.front = pid }
                    return self.openWorks
                }
            },
            settle: {}
        )
    }
}

@Suite
struct WorkspaceScreenAppsTests {
    private func apps(_ fake: FakeForeground) -> WorkspaceScreenApps {
        WorkspaceScreenApps(resolver: InstalledAppResolver(source: FixedAppSource([])), foreground: fake.seam)
    }

    @Test
    func anAppAlreadyInFrontNeedsNothing() async {
        let fake = FakeForeground(front: 42, activateWorks: false, openWorks: false)
        #expect(await apps(fake).activate(pid: 42))
        #expect(fake.calls.isEmpty)
    }

    @Test
    func anAppThatComesForwardWhenAskedIsNotOpenedAgain() async {
        let fake = FakeForeground(front: 7, activateWorks: true, openWorks: true)
        #expect(await apps(fake).activate(pid: 42))
        #expect(fake.calls == ["activate"])
    }

    /// What macOS 14 does to a request from an app that isn't in front: accepted, and ignored.
    @Test
    func whenAskingIsIgnoredTheAppIsOpenedTheWayOpenAppOpensIt() async {
        let fake = FakeForeground(front: 7, activateWorks: false, openWorks: true)
        #expect(await apps(fake).activate(pid: 42))
        #expect(fake.calls == ["activate", "open"])
    }

    @Test
    func anAppThatComesForwardNeitherWayIsReportedAsNotInFront() async {
        let fake = FakeForeground(front: 7, activateWorks: false, openWorks: false)
        #expect(await apps(fake).activate(pid: 42) == false)
    }
}
