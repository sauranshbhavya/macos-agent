import Foundation

/// The words the two version states show, owned here rather than anywhere the wire can reach.
///
/// **The same rule and the same reason as `SignInCopy`, `SonnyBackendCopy` and `EntitlementCopy`**:
/// §7.1 forbids displaying the server's `message`, because a sentence authored on the server and
/// rendered in the app is editable by whoever edits the server with no review from anyone who knows
/// Sonny's copy rules. The gateway's own refusal reads "This client is older than the minimum
/// supported version 2.0.0." — a true sentence, and not one this product would ever show.
///
/// **Functional, not explanatory** (founder, 2026-08-14, standing): what happened and what the user
/// can do next. Nothing here says what a version is, why a gateway refuses one, or where the number
/// comes from. There is deliberately no sentence about the link either — the founder's decision of
/// 2026-09-04 chose a button over a visible URL precisely so that no extra line is needed.
///
/// **One owner for the wall's sentence, shared with `SignInCopy`.** A too-old build is refused on
/// every route including the three unauthenticated sign-in ones (`version/gate.ts` runs before the
/// auth gate), so the same user meets this state on the sign-in sheet and in the widget. Two
/// literals would be two sentences about one condition, which is the defect
/// `ScreenControlSessionPresentation` exists to prevent on the other surface pair.
public enum ClientVersionCopy {
    // MARK: - The wall (§8.3)

    public static let tooOldTitle = "Update needed"
    public static let tooOldMessage = "This version of Sonny is too old. Update to carry on."

    // MARK: - The warning (§8.4)

    public static let updateAvailableTitle = "Update available"
    public static let updateAvailableMessage = "A new version of Sonny is out."

    // MARK: - Controls

    /// The founder's own words for this control, 2026-09-04.
    ///
    /// Shown only when the state carries a link — see ``ClientUpgradeLink``, which is what decides
    /// whether there is one. A build told it is too old by a deployment that published no usable
    /// upgrade URL shows the message and no button, which is the same decision's second half.
    public static let updateLabel = "Update Sonny"

    /// Offered on the warning and never on the wall.
    ///
    /// **The warning has to be dismissible or it is not a warning, it is a permanent occupant.**
    /// §8.4's band lasts until the user updates, and both surfaces render this state from the
    /// attention precedence — so with no way out, the widget would carry an update banner over every
    /// idle moment for weeks and Command Center would never be without one. The wall gets no
    /// dismissal for the mirror-image reason: nothing works, so hiding the only actionable thing on
    /// screen would leave the user with an app that fails silently.
    public static let dismissLabel = "Not now"

    /// Everything the two surfaces render for one state, or `nil` when there is nothing to say.
    ///
    /// **One owner, for the same reason `ScreenControlSessionPresentation` is one owner** — the
    /// widget's System B panel and Command Center's System A panel cannot share a *view*, because
    /// neither token set may cross into the other's surface, so the thing that has to have exactly
    /// one home is the sentence. A hand-written copy on either side is one condition described two
    /// ways, and nothing in either file would catch it;
    /// `ClientVersionSurfaceTests.bothSurfacesReadTheVersionPromptFromOneOwnerAndNeitherHandWritesIt`
    /// is the scan that does.
    ///
    /// **`updateLabel` is `nil` exactly when the state carries no link**, which is the whole of the
    /// founder's decision of 2026-09-04: an Update Sonny button that opens the URL when it parses as
    /// http or https, and otherwise the message with no button. Deciding it here rather than at each
    /// surface means one surface cannot grow a dead control the other does not have.
    ///
    /// **`dismissLabel` is `nil` for the wall and set for the warning**, which ``dismissLabel``
    /// argues at its own declaration.
    public static func prompt(for state: ClientVersionState) -> ClientVersionPrompt? {
        switch state {
        case .current:
            return nil
        case .updateAvailable(let link):
            return ClientVersionPrompt(
                title: updateAvailableTitle,
                message: updateAvailableMessage,
                updateLabel: link == nil ? nil : updateLabel,
                dismissLabel: dismissLabel,
                link: link
            )
        case .tooOld(let link):
            return ClientVersionPrompt(
                title: tooOldTitle,
                message: tooOldMessage,
                updateLabel: link == nil ? nil : updateLabel,
                dismissLabel: nil,
                link: link
            )
        }
    }
}

/// What a surface draws for ``ClientVersionState``, decided once in ``ClientVersionCopy/prompt(for:)``.
public struct ClientVersionPrompt: Equatable, Sendable {
    public let title: String
    public let message: String
    /// `nil` when there is no link this app will open, and therefore no button.
    public let updateLabel: String?
    /// `nil` on the wall, which has no way out but updating.
    public let dismissLabel: String?
    public let link: URL?

    public init(title: String, message: String, updateLabel: String?, dismissLabel: String?, link: URL?) {
        self.title = title
        self.message = message
        self.updateLabel = updateLabel
        self.dismissLabel = dismissLabel
        self.link = link
    }
}
