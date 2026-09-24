import Foundation
import Testing
@testable import MacAgentCore

/// **No address `main` refused for naming account creation loads, over a whole class of addresses rather
/// than over the ones that happen to ship** (SONNY-539).
///
/// **Why a class.** SONNY-529 rewrote `SkillPackStartPageRule.namesAccountCreation` to read a query as
/// keys and values, and three rounds measured the result against every address the shipped packs carry.
/// All three came back clean while shapes `main` refused were loading: a key that holds a second `?`
/// (`index.php?/register?ref=home`), and a single-page route's own query that holds a second `#`
/// (`#/login?register#top`). The measurements were right about the shipped addresses and blind to
/// these, because no shipped address has either shape: a population drawn from what exists cannot test
/// what does not. A reviewer thinking about the class found the first. Lane-529's run over every short
/// address built from a few tokens found the second and counted both, and this suite is that run made
/// permanent, so the next change to the matcher is measured against the class and not against the
/// catalogue again.
///
/// **What it is compared with.** A test cannot fetch another commit, so `main`'s verdicts are held by
/// value in `AccountCreationClassTable`, which has how they are generated and how to read a row. The floor
/// is `main` as wave 12 closed it, the last matcher before that rewrite and the one every measurement on
/// SONNY-529 compares against. The matcher refuses more than that today and may go on to; what it may not
/// do is refuse less. A refusal it adds is `SkillPackTests.knownRefusalsOfTheWiderMatchAreHeld`'s to hold,
/// and it fails closed.
///
/// **An address goes in through the decoder's door.** The pack decoder makes a URL with
/// `URLComponents(string:)?.url` (`SkillPack.swift`, `httpsURL`), so that is how every address here is
/// made: a sample built some other way would be testing a matcher the loader never calls. It matters
/// here, because the second `#` of an address is written `%23` by that door and read back decoded by the
/// matcher.
///
/// **It has to be able to fail, and is shown failing on every run.**
/// `theWalkReportsEveryAddressAMatcherLetsThrough` drives the same walk with matchers that refuse
/// nothing, everything, and everything but one address. Both of those cuts were put back into the real
/// matcher and watched dying, and PR #284 records how many addresses each let through: 2,110 and 146.
@Suite
struct AccountCreationClassTests {
    private typealias Table = AccountCreationClassTable

    /// What one walk of the class found. The two counts are by length: `[0]` is the one-token addresses.
    struct Walk {
        /// Every address visited.
        var addresses: [Int]
        /// The ones the table says `main` refused: the only ones a matcher is asked about.
        var refusedByMain: [Int]
        /// Refused by `main`, and not a URL to the decoder's door on this machine.
        var unparsed = 0
        /// Refused by `main`, and the matcher asked says it loads.
        var refusedLess: [String] = []
    }

    /// The class to `length` tokens: what the table says `main` answered, and which of its refusals
    /// `matcher` lets through. Addresses `main` loaded are counted and not asked about, since nothing is
    /// claimed of them. With no matcher nothing is asked and no URL is made, which is a reading of the
    /// table alone.
    static func walk(toLength length: Int = Table.depth, asking matcher: ((URL) -> Bool)? = nil) -> Walk {
        var walk = Walk(addresses: Array(repeating: 0, count: length), refusedByMain: Array(repeating: 0, count: length))
        extend("https://example.com/", at: 0, length: 0, asking: matcher, into: &walk)
        return walk
    }

    private static func extend(_ address: String, at row: Int, length: Int, asking matcher: ((URL) -> Bool)?, into walk: inout Walk) {
        guard length < walk.addresses.count else { return }
        for (token, next) in zip(Table.tokens, Table.shapes[row].next) {
            let longer = address + token
            walk.addresses[length] += 1
            if Table.shapes[next].refused {
                walk.refusedByMain[length] += 1
                if let matcher {
                    if let url = URLComponents(string: longer)?.url {
                        if !matcher(url) { walk.refusedLess.append(longer) }
                    } else {
                        walk.unparsed += 1
                    }
                }
            }
            extend(longer, at: next, length: length + 1, asking: matcher, into: &walk)
        }
    }

    /// What the table says `main` answered about `https://example.com/` + `tail`, or nil when `tail` is
    /// not one to `Table.depth` of the class's tokens. No token begins another, so the cut is unambiguous.
    static func mainRefused(_ tail: String) -> Bool? {
        var rest = Substring(tail)
        var row = 0
        while !rest.isEmpty {
            guard let index = Table.tokens.firstIndex(where: { rest.hasPrefix($0) }), Table.shapes[row].next.indices.contains(index) else {
                return nil
            }
            row = Table.shapes[row].next[index]
            rest = rest.dropFirst(Table.tokens[index].count)
        }
        return row == 0 ? nil : Table.shapes[row].refused
    }

    /// **The guard.** Both counts are the class run's own, held here by hand and not in the generated
    /// block (`scripts/account-creation-class-table --check` prints `177155 addresses, 75546 refused`
    /// for the floor, `8f3d1d02`), so a walk that stopped visiting the class, or stopped asking, fails
    /// here instead of passing on nothing. `unparsed` is held at none because the table was generated
    /// where every address of the class is a URL; if that stops being so, Foundation's parser has moved
    /// and what the loader hands the matcher has moved with it.
    @Test
    func noAddressOfTheClassThatMainRefusedLoads() {
        let walk = Self.walk(asking: SkillPackStartPageRule.namesAccountCreation)
        #expect(walk.addresses.reduce(0, +) == 177_155)
        #expect(walk.refusedByMain.reduce(0, +) == 75_546)
        #expect(walk.unparsed == 0)
        // The count and not the list is what is expected, so a failure prints one number and the first
        // fifteen addresses rather than every one of them.
        let nowLoad = walk.refusedLess.count
        #expect(nowLoad == 0, "\(nowLoad) addresses main refused now load, first \(walk.refusedLess.prefix(15))")
    }

    /// **The table is `main`'s verdicts and not an empty or a moved one**, read without any matcher. The
    /// commit, the tokens and the length are repeated here by value so that a table regenerated from
    /// another commit or another class fails until somebody holds the new one on purpose. The refusals
    /// by length are the generator's own figures for the floor (`2, 32, 432, 5560, 69520 by length`, in
    /// the block's header), and the first of them can be checked by eye: of the eleven one-token
    /// addresses, `main` refused `signup` and `Register`.
    ///
    /// Then the shapes this suite exists for, each by name. `??signup` and `?x?signup` are the doubled `?`
    /// that a key cut at `/` and `.` let through on SONNY-529, and `#?signup#x` and `#?#signup` the second
    /// `#` that a cut at `/`, `.` and `?` would have. A table that did not hold them as refusals could not
    /// fail on either.
    @Test
    func theTableIsMainsVerdictsByValue() {
        #expect(Table.floorCommit == "8f3d1d02a14f9ebac84da2aaa3750667bcbfe40b")
        #expect(Table.tokens == ["signup", "Register", "x", "/", "?", "&", "=", ".", "#", "-", "_"])
        #expect(Table.depth == 5)
        #expect(Table.shapes.map(\.id) == Array(Table.shapes.indices))
        for shape in Table.shapes {
            #expect(shape.next.isEmpty || shape.next.count == Table.tokens.count, "row \(shape.id)")
            #expect(shape.next.allSatisfy(Table.shapes.indices.contains), "row \(shape.id)")
        }

        let table = Self.walk()
        #expect(table.addresses == [11, 121, 1_331, 14_641, 161_051])
        #expect(table.refusedByMain == [2, 32, 432, 5_560, 69_520])

        for tail in [
            "signup", "Register", "-signup_", "x/Register", "#/signup", "?x=signup", "?/signup", "?x.Register",
            "??signup", "?x?signup", "#?signup#x", "#?#signup"
        ] {
            #expect(Self.mainRefused(tail) == true, "\(tail) is not a refusal in the table")
        }
        // What `main` loaded: a word inside a longer one, two words run together, and a key that only
        // contains a word, which is the shape of Snov's `signup_source`.
        for tail in ["x", "signupx", "signup-x", "signupRegister", "?signup_x", "#?x_Register"] {
            #expect(Self.mainRefused(tail) == false, "\(tail) does not load in the table")
        }
        #expect(Self.mainRefused("") == nil)
        #expect(Self.mainRefused("login") == nil)
        #expect(Self.mainRefused("xxxxxx") == nil)
    }

    /// **The walk can fail, and names what failed.** None of the three matchers here is the real one, so
    /// this holds the walk and the table whatever the rule decides. A matcher that refuses nothing is
    /// reported for every address `main` refused, so every one of them is asked about (6,026 to four
    /// tokens: the first four figures above, summed). One that refuses everything is reported for none.
    /// And one that refuses everything but a single address is reported for exactly that address, which
    /// is the doubled `?` at its shortest.
    @Test
    func theWalkReportsEveryAddressAMatcherLetsThrough() {
        let nothingRefused = Self.walk(toLength: 4, asking: { _ in false })
        #expect(nothingRefused.addresses.reduce(0, +) == 16_104)
        #expect(nothingRefused.refusedLess.count == 6_026)
        #expect(Self.walk(toLength: 4, asking: { _ in true }).refusedLess.isEmpty)

        let doubled = "https://example.com/??signup"
        let oneLetThrough = Self.walk(toLength: 3, asking: { $0.absoluteString != doubled })
        #expect(oneLetThrough.refusedLess == [doubled])
    }
}
