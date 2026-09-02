import Foundation
import Testing

/// **The unprivileged gate cannot be inverted, moved, or dropped** (SONNY-123, PR #72 F4, F5, C2 and
/// C3; narrowed by SONNY-172).
///
/// Four tests in this repository force a write or a delete to fail by locking a directory to `0o500`.
/// Root bypasses directory permission bits, so `.requiresUnprivilegedProcess` skips them on a
/// root-running process. Nothing here runs as root and this repository has no CI, so that gate has
/// never fired anywhere and its correctness is neither exercised nor observable from inside a run —
/// which is why it is pinned as source text instead. Inverting `geteuid() != 0` to `== 0` survived
/// the whole suite once: three tests silently stopped running, the suite still reported green, and
/// the total dropped from 1377 to 1374 with nobody told.
///
/// **This file used to also hold three twin comparisons, and no longer does** (SONNY-172). Until then
/// `DeterministicPermissions.swift` and `UnprivilegedProcess.swift` each existed once per test target
/// and were kept in step by hand, so `theTwinnedPermissionStubsAreTheSameCode`,
/// `theTwinnedUnprivilegedTraitsAreTheSameCode` and `neitherTwinIsExtendedOutsideItsClassBody` — the
/// last of which existed only to cover the first one's blind spot — compared the copies and failed on
/// drift. Both files now live once, in `MacAgentTestSupport`, so those three compare a thing to
/// itself and are gone. The two tests below were never about twinning and are untouched in substance:
/// the gate is one file's text now rather than two, and the `0o500` scan always read the whole tree.
///
/// **Formerly `TwinnedTestSupportTests.swift`**, renamed by SONNY-172 when the twins were
/// consolidated. Five changelog entries written before that date still name it that way and are not
/// rewritten, because they were true when written — this line is the forwarding address, so a grep
/// for the old name out of an old record lands here rather than nowhere.
@Suite
struct UnprivilegedGateTests {
    /// This file carries the scan's search strings as literals, so it matches itself unless excluded
    /// — the same self-reference the permission scan exempts by path.
    private static let thisFile = "MacAgentCoreTests/UnprivilegedGateTests.swift"

    /// The one copy of the trait, since SONNY-172.
    private static let gateFile = "MacAgentTestSupport/UnprivilegedProcess.swift"

    /// The gate's predicate, pinned as text because there is no way to observe a skip from inside
    /// the run that was skipped. Inverting it is a mutant this kills; nothing else does.
    @Test
    func theUnprivilegedGatePredicateIsNotInverted() throws {
        let source = try String(
            contentsOf: TestSourceTree.root.appendingPathComponent(Self.gateFile),
            encoding: .utf8
        )
        #expect(source.contains("if: geteuid() != 0,"), "the gate is not the expected predicate")
        #expect(
            !source.contains("geteuid() == 0"),
            "the gate is inverted: it would run these tests only as root, and skip them everywhere else"
        )
    }

    /// **Every test that locks a directory carries the gate, and no other test does — matched per
    /// test rather than in aggregate** (PR #72 C2).
    ///
    /// The first version counted two populations across the tree and compared totals, which never
    /// asked whether a given `chmod` and a given tag belonged to the same test. Measured: moving
    /// `@Test(.requiresUnprivilegedProcess)` off the directory-locking test and onto its neighbour
    /// left both totals at four and the suite green, with one forced-failure test silently ungated
    /// and an unrelated one needlessly gated. That is a plausible merge accident — an attribute
    /// landing on the wrong function is what an inserted test does — not only an adversarial one.
    ///
    /// So each file is segmented at its `@Test` lines and the two facts are required to agree inside
    /// every segment. Both directions matter: a lock without a gate fails on a root runner for a
    /// reason that is not a defect, and a gate without a lock silently stops running a test that had
    /// no need of it.
    @Test
    func everyDirectoryLockingTestCarriesTheGateAndNoOtherTestDoes() throws {
        var lockedAndGated = 0
        var mismatches: [String] = []

        for target in TestSourceTree.targets {
            for file in try TestSourceTree.swiftFiles(in: target)
            where file.relativePath != Self.thisFile {
                var header: (number: Int, text: String)?
                var locksDirectory = false

                func closeSegment() {
                    guard let header else { return }
                    let gated = header.text.contains(".requiresUnprivilegedProcess")
                    if gated && locksDirectory {
                        lockedAndGated += 1
                    } else if gated != locksDirectory {
                        mismatches.append(
                            "\(file.relativePath):\(header.number) — locks=\(locksDirectory) gated=\(gated)"
                        )
                    }
                }

                for line in TestSourceTree.codeLines(of: try TestSourceTree.read(file)) {
                    if line.text.trimmingCharacters(in: .whitespaces).hasPrefix("@Test") {
                        closeSegment()
                        header = line
                        locksDirectory = false
                    } else if line.text.contains("posixPermissions: 0o500") {
                        locksDirectory = true
                    }
                }
                closeSegment()
            }
        }

        // Six since row E (SONNY-151, PR #89's two fix rounds). Those two make the plan store's
        // directory read-only while task history stays writable, which is the only way to fail the
        // second of a path's two writes without failing the first — one per path, because the
        // scheduled and foreground writes are separate functions rather than one shared helper:
        // `ScheduledRoutineRunTests.aPlanWriteFailureKeepsTheScheduledRowAndSaysWhatActuallyFailed`
        // and `ProductShellTests.aPlanWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed`.
        //
        // Eight since SONNY-201, which added each path's mirror image: the *row* write failing while
        // the plan store stays writable, one directory changed in each of the two above —
        // `ScheduledRoutineRunTests.aRowWriteFailureIsAStorageNoticeRatherThanAFailedScheduledRun`
        // and `ProductShellTests.aRowWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed`.
        //
        // Unchanged by SONNY-172: consolidating the trait moved no test and locked no new directory,
        // so this branch's rebase past SONNY-201 takes that ticket's count rather than reconciling one.
        // Eleven since SONNY-239, whose three gated tests all lock a directory so a *rename* fails
        // rather than a write — the first three to do that. `LocalDataQuarantineTests` has two: one
        // for a store file that cannot be moved aside, one for a set-aside file the whole wipe
        // cannot delete, which is the branch that decides whether a privacy wipe reports a file it
        // could not remove. `MemoryCommandCenterTests` has the third, added in PR #110's fix round
        // for a mutant that survived: a Delete that silently did nothing must leave the row still
        // saying "Can't be read" rather than clearing a banner that is still true.
        //
        // Twelve since SONNY-266, whose one gated test locks the directory so Settings' narrower
        // control cannot unlink the file it was pressed for:
        // `MemoryCommandCenterTests.aSetAsideFileTheControlCannotDeleteStaysOnTheLineAndIsNamed`,
        // which is the branch that decides whether the Data page's line keeps counting a file the
        // press could not remove, and names it, rather than going quiet because the press happened.
        //
        // Fourteen since SONNY-144, whose two gated tests lock the grants store's directory so a
        // *revocation* write fails — one for the per-row Remove and one for Remove All, because they
        // are separate commit paths with separate messages, and the property being pinned is that
        // each reports its own failed write rather than borrowing the load failure's "could not be
        // decrypted or decoded". Both are in `VisionSessionRunTests`:
        // `aFailedRemoveSaysTheWriteFailedAndNeverBorrowsTheLoadFailuresWords` and
        // `aFailedRemoveAllSaysWhichPressFailedAndNeverBorrowsTheLoadFailuresWords`.
        //
        // Fifteen since SONNY-382, whose one gated test locks the watcher store's directory so the
        // rewrite a Stop press needs fails while the record itself stays perfectly readable:
        // `StandingWatcherStopTests.aStopThatCannotBeWrittenReportsOnTheChannelForAPressedControl`,
        // which is the branch that decides whether a failed Stop reports on `errorMessage` — the
        // channel for a control the user pressed — rather than on the storage notice, where it would
        // leave the user believing the watcher had stopped.
        #expect(lockedAndGated == 15, "expected fifteen gated directory-locking tests, found \(lockedAndGated)")
        #expect(
            mismatches.isEmpty,
            """
            A test locks a directory to 0o500 without .requiresUnprivilegedProcess, or carries the \
            trait without locking one. Root bypasses directory permission bits, so an ungated lock \
            fails on a root-running runner for a reason that is not a defect, and a stray gate skips \
            a test that never needed gating (SONNY-106 section D). \(mismatches.joined(separator: " | "))
            """
        )
    }
}
