import Foundation

/// **What `main`'s account-creation matcher answered about a whole class of addresses, held by value**
/// (SONNY-539). `AccountCreationClassTests` reads it and has the reason it exists.
///
/// **The class** is `https://example.com/` followed by one to `depth` tokens, each one of `tokens`: two of
/// the words that name account creation, a filler, and every separator the matcher splits on, cuts at or
/// folds. It is lane-529's class run on SONNY-529, unchanged.
///
/// **A row is a shape and its verdict.** Walking the class one token at a time is a tree. Two addresses
/// whose whole subtrees carry the same verdicts are one row, because from there on the matcher at
/// `floorCommit` could not tell them apart, and that merging is the only thing that makes the table small:
/// expanding the rows from row 0 gives back every verdict of the run, one for one. So a row is `refused`,
/// what that matcher said about an address that ends here, and `next`, the row each token leads to in
/// `tokens`' order; a row at the class's full length has nowhere to lead. To read an address, start at row
/// 0 and follow its tokens: `?/signup` goes 0, 3, 7, 11, and row 11 is a refusal. Each row's note gives how
/// many addresses of the class reach it and the shortest one that does.
///
/// **No rule about addresses is written here.** A row is what the matcher answered, not a description of
/// how it decides, so nothing in this file can be wrong about the rule in a way the rule's own code was
/// not.
///
/// **It is generated, and the generator is the only thing that reads the other commit.** A test cannot
/// fetch a commit, so `scripts/account-creation-class-table` compiles the matcher as `floorCommit` wrote
/// it, asks it about every address through the pack decoder's own door, and writes the block below;
/// `--check` exits 2 when the block is not what that run produces. The figures in the block's header are
/// that run's and are measured of `floorCommit`'s code, whatever commit the script is run at. The counts
/// the suite holds are written by hand in `AccountCreationClassTests`, deliberately outside the block, so
/// a table regenerated from another commit or another class fails there until somebody re-counts it on
/// purpose.
enum AccountCreationClassTable {
    struct Shape: Sendable {
        /// The row's own number, which is its position in `shapes`. Written in the row so that a reader
        /// following an address does not have to count lines; the suite holds that the two agree.
        let id: Int
        /// Whether the matcher at `floorCommit` said an address ending here names account creation.
        let refused: Bool
        /// The row each of `tokens` leads to, in that order. Empty at the class's full length.
        let next: [Int]

        init(_ id: Int, refused: Bool, next: [Int]) {
            self.id = id
            self.refused = refused
            self.next = next
        }
    }

    // BEGIN GENERATED TABLE: scripts/account-creation-class-table --write. Do not edit by hand.
    // The matcher of 8f3d1d02a14f9ebac84da2aaa3750667bcbfe40b, asked about 177155 addresses; it refused 75546
    // (2, 32, 432, 5560, 69520 by length). 18 rows.
    static let floorCommit = "8f3d1d02a14f9ebac84da2aaa3750667bcbfe40b"
    static let tokens = ["signup", "Register", "x", "/", "?", "&", "=", ".", "#", "-", "_"]
    static let depth = 5
    static let shapes: [Shape] = [
        Shape( 0, refused: false, next: [ 1,  1,  2,  3,  3,  3,  3,  3,  3,  3,  3]), // the bare address
        Shape( 1, refused: true,  next: [ 4,  4,  4,  5,  5,  5,  5,  5,  5,  6,  6]), // 2 of the class, shortest "signup"
        Shape( 2, refused: false, next: [ 4,  4,  4,  7,  7,  7,  7,  7,  7,  4,  4]), // 1 of the class, shortest "x"
        Shape( 3, refused: false, next: [ 6,  6,  4,  7,  7,  7,  7,  7,  7,  7,  7]), // 8 of the class, shortest "/"
        Shape( 4, refused: false, next: [ 8,  8,  8,  9,  9,  9,  9,  9,  9,  8,  8]), // 19 of the class, shortest "signupsignup"
        Shape( 5, refused: true,  next: [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10]), // 12 of the class, shortest "signup/"
        Shape( 6, refused: true,  next: [ 8,  8,  8, 10, 10, 10, 10, 10, 10, 11, 11]), // 20 of the class, shortest "signup-"
        Shape( 7, refused: false, next: [11, 11,  8,  9,  9,  9,  9,  9,  9,  9,  9]), // 70 of the class, shortest "x/"
        Shape( 8, refused: false, next: [12, 12, 12, 13, 13, 13, 13, 13, 13, 12, 12]), // 225 of the class, shortest "signupsignupsignup"
        Shape( 9, refused: false, next: [14, 14, 12, 13, 13, 13, 13, 13, 13, 13, 13]), // 674 of the class, shortest "signupsignup/"
        Shape(10, refused: true,  next: [15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15]), // 252 of the class, shortest "signup/signup"
        Shape(11, refused: true,  next: [12, 12, 12, 15, 15, 15, 15, 15, 15, 14, 14]), // 180 of the class, shortest "signup--"
        Shape(12, refused: false, next: [16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16]), // 2339 of the class, shortest "signupsignupsignupsignup"
        Shape(13, refused: false, next: [17, 17, 16, 16, 16, 16, 16, 16, 16, 16, 16]), // 6742 of the class, shortest "signupsignupsignup/"
        Shape(14, refused: true,  next: [16, 16, 16, 17, 17, 17, 17, 17, 17, 17, 17]), // 1708 of the class, shortest "signupsignup/signup"
        Shape(15, refused: true,  next: [17, 17, 17, 17, 17, 17, 17, 17, 17, 17, 17]), // 3852 of the class, shortest "signup/signupsignup"
        Shape(16, refused: false, next: []), // 91531 of the class, shortest "signupsignupsignupsignupsignup"
        Shape(17, refused: true,  next: []), // 69520 of the class, shortest "signupsignupsignup/signup"
    ]
    // END GENERATED TABLE
}
