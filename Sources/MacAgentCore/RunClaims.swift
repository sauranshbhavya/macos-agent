import Foundation

/// What earlier units of one chain have already done, carried forward to the units after them
/// (SONNY-76).
///
/// **Two sets rather than one, because they answer two different questions and have two different
/// scopes.** Collapsing them would make one of the two answers wrong.
///
/// - ``destinations`` answers *"has this run already written here?"* It is accumulated from every
///   unit's `ActionPreview.writes`, so it covers writes from **any** capability: a PDF this run
///   produced is this run's whether a conversion or something else made it. A document whose
///   preferred destination is in here collides with something this run wrote, so it renames rather
///   than being told it was skipped for a file the user never had.
/// - ``convertedSources`` answers *"has this run already converted this document?"* That question is
///   docx-shaped and has no meaning for a capability that does not convert a source, so this set is
///   deliberately narrower — it is not a narrowing of the property above, it is a second property
///   with its own honest scope.
///
/// **Why the second set exists** (PR #65 review, F1). The first alone was wrong whenever two units'
/// scan scopes overlap — a nested folder pair is enough, since `regularFiles(in:)` recurses. The
/// later unit re-finds the *same* document, sees its preferred destination already claimed, and
/// renames: one source document converted twice, and a summary announcing a collision with "another
/// document" that does not exist. Keyed on the source rather than on the destination, because
/// "already converted" is a fact about the document, not about where it landed.
///
/// Both sets hold `DestinationKey.folded` keys, so two spellings of one path on a case-insensitive
/// volume are one entry — the same question that helper already answers everywhere else.
public struct RunClaims: Equatable, Sendable {
    public var destinations: Set<String>
    public var convertedSources: Set<String>

    public static let none = RunClaims()

    public init(destinations: Set<String> = [], convertedSources: Set<String> = []) {
        self.destinations = destinations
        self.convertedSources = convertedSources
    }

    public func hasWritten(_ path: String) -> Bool {
        destinations.contains(DestinationKey.folded(path))
    }

    public func hasConverted(_ sourcePath: String) -> Bool {
        convertedSources.contains(DestinationKey.folded(sourcePath))
    }

    public mutating func recordWrite(_ path: String) {
        destinations.insert(DestinationKey.folded(path))
    }

    public mutating func recordConversion(ofSource sourcePath: String) {
        convertedSources.insert(DestinationKey.folded(sourcePath))
    }
}
