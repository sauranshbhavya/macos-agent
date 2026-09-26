import Foundation

extension String {
    /// This text cut to at most `limit` UTF-16 code units, the measure the gateway's schema checks a
    /// string's length in. Swift counts Characters, and one Character can be several units (an emoji
    /// is two or more), so text cut to the right number of Characters can still be refused.
    ///
    /// The cut falls between Characters: it never leaves half a surrogate pair, an accent without its
    /// letter, or part of an emoji. A Character that would cross the limit is left out whole.
    func clipped(toUTF16 limit: Int) -> String {
        guard utf16.count > limit else { return self }
        var end = startIndex
        var used = 0
        while end < endIndex {
            let next = index(after: end)
            used += self[end..<next].utf16.count
            guard used <= limit else { break }
            end = next
        }
        return String(self[..<end])
    }
}
