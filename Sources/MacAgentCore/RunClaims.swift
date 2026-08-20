import Foundation

/// One conversion this run has already performed: which document, and into which folder.
///
/// **A pair rather than a source path** (PR #65 re-check, F5). Keyed on the source alone, the claim
/// suppressed a conversion the user had asked for: a later unit naming a *different* output folder
/// was told the PDF already existed, at a destination where none did.
///
/// **The folder, not the full destination path**, and that is the load-bearing half. A destination
/// filename is not stable across units — a document whose basename another document of the same
/// scan already claimed is renamed to `report-2.pdf`, and only its folder survives that. Keyed on
/// the full path, the renamed document's later re-scan would compute `report.pdf`, miss its own
/// `report-2.pdf` claim, and convert a second time to `report-3.pdf` — reintroducing F1 for exactly
/// the documents the rename rule touches. The folder is also the honest unit of what the user asked
/// for: "convert these into that folder" says nothing about the filename, which is this code's to
/// choose.
///
/// Both halves are folded through ``DestinationKey/folded(_:)`` **in this initializer**, so the
/// invariant holds by construction rather than by every call site remembering it.
public struct ConversionClaim: Hashable, Sendable {
    public let source: String
    public let destinationFolder: String

    public init(source: String, destinationFolder: String) {
        self.source = DestinationKey.folded(source)
        self.destinationFolder = DestinationKey.folded(destinationFolder)
    }
}

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
/// - ``convertedSources`` answers *"has this run already converted this document into this folder?"*
///   That question is docx-shaped and has no meaning for a capability that does not convert a
///   source, so this set is deliberately narrower — it is not a narrowing of the property above, it
///   is a second property with its own honest scope.
///
/// **Why the second set exists** (PR #65 review, F1). The first alone was wrong whenever two units'
/// scan scopes overlap — a nested folder pair is enough, since `regularFiles(in:)` recurses. The
/// later unit re-finds the *same* document, sees its preferred destination already claimed, and
/// renames: one source document converted twice, and a summary announcing a collision with "another
/// document" that does not exist.
///
/// **Why it is keyed on a pair** (PR #65 re-check, F5). Keying on the source alone made the opposite
/// error one step over. "Already converted" is not a fact about the document on its own: a later
/// unit naming a different output folder is asking for something this run has not done, and it was
/// being skipped with a sentence pointing at a PDF that did not exist there. The run already treated
/// the request that way in the case where the earlier unit *skipped* rather than converted — the
/// same intent got opposite outcomes depending on which branch the earlier unit took, which is the
/// contradiction that showed the key was wrong. See ``ConversionClaim`` for why the pair's second
/// half is the folder rather than the filename.
///
/// **Both sets enforce their own key rule rather than trusting callers to apply it** (SONNY-165).
/// ``destinations`` holds `DestinationKey.folded` keys — folded by this type's initializer and by
/// ``recordWrite(_:)``, the only two ways a key gets in — and ``convertedSources`` holds
/// ``ConversionClaim``s, which fold both of their halves in their own initializer. Reading either
/// set from outside is what the four accessors below are for; the stored properties are
/// `private(set)` so there is no second way to add a key, and therefore no second place the rule
/// could be spelled differently.
///
/// That symmetry is the point. The destination side used to be copied out raw and folded by hand at
/// four call sites in `FileInventory.docxFiles`, so this type's own guarantee was true only because
/// four separate places remembered it — while ``ConversionClaim``, added one review round later,
/// folded inside itself. One file, one rule, two enforcement mechanisms, agreeing right up until
/// one of them was edited.
public struct RunClaims: Equatable, Sendable {
    public private(set) var destinations: Set<String>
    public private(set) var convertedSources: Set<ConversionClaim>

    public static let none = RunClaims()

    /// Folds `destinations` on the way in, so a `RunClaims` built anywhere satisfies the type's
    /// stated invariant. `convertedSources` needs no fold here — ``ConversionClaim`` has already
    /// folded both of its halves by the time one exists.
    public init(destinations: Set<String> = [], convertedSources: Set<ConversionClaim> = []) {
        self.destinations = Set(destinations.map(DestinationKey.folded))
        self.convertedSources = convertedSources
    }

    /// Whether this run has already claimed or written `path`. The counterpart to
    /// ``recordWrite(_:)``, and the reason no caller needs to know that these keys are folded.
    public func hasWritten(_ path: String) -> Bool {
        destinations.contains(DestinationKey.folded(path))
    }

    public func hasConverted(_ sourcePath: String, intoFolder folderPath: String) -> Bool {
        convertedSources.contains(ConversionClaim(source: sourcePath, destinationFolder: folderPath))
    }

    public mutating func recordWrite(_ path: String) {
        destinations.insert(DestinationKey.folded(path))
    }

    /// Records a conversion from the destination *file* it produced — the folder is derived here, so
    /// the "a conversion claims its destination's folder" rule has one home rather than one per
    /// caller.
    public mutating func recordConversion(ofSource sourcePath: String, to destinationPath: String) {
        convertedSources.insert(
            ConversionClaim(
                source: sourcePath,
                destinationFolder: URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
            )
        )
    }
}
