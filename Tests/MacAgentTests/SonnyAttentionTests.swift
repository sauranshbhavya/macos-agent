import Foundation
import Testing
@testable import MacAgent

/// The notification gate (SONNY-56). Asserted as a rule rather than by observing a posted
/// notification, which no test in this repository can reach — delivery needs real bundle identity,
/// and `observeNotificationTriggers` returns early without it.
struct SonnyAttentionTests {
    /// **The trap this type exists for.** The widget is a `.nonactivatingPanel`, deliberately, so
    /// typing into it does not make Sonny the active app. A gate written as `!NSApp.isActive` would
    /// read as correct in a diff and interrupt the user mid-sentence the first time anyone used it.
    ///
    /// This is the case that fails if only the activation half is checked.
    @Test
    func typingIntoTheWidgetCountsAsWorkingInSonnyEvenThoughTheAppIsNotActive() {
        #expect(SonnyAttention.isUserWorkingInSonny(isApplicationActive: false, isWidgetPanelKey: true))
        #expect(!SonnyAttention.shouldNotify(isApplicationActive: false, isWidgetPanelKey: true))
    }

    @Test
    func sonnyNotifiesOnlyWhenTheUserIsWorkingSomewhereElse() {
        // The whole truth table, so neither half can be dropped unnoticed.
        #expect(SonnyAttention.shouldNotify(isApplicationActive: false, isWidgetPanelKey: false))
        #expect(!SonnyAttention.shouldNotify(isApplicationActive: true, isWidgetPanelKey: false))
        #expect(!SonnyAttention.shouldNotify(isApplicationActive: false, isWidgetPanelKey: true))
        #expect(!SonnyAttention.shouldNotify(isApplicationActive: true, isWidgetPanelKey: true))
    }

    @Test
    func shouldNotifyIsExactlyTheNegationOfWorkingInSonny() {
        for active in [true, false] {
            for key in [true, false] {
                #expect(
                    SonnyAttention.shouldNotify(isApplicationActive: active, isWidgetPanelKey: key)
                        == !SonnyAttention.isUserWorkingInSonny(isApplicationActive: active, isWidgetPanelKey: key)
                )
            }
        }
    }

    /// The old gate, written out so the difference is on the record rather than in a commit message.
    ///
    /// `isAnySonnySurfaceVisible` was `widgetController.isVisible || commandCenterWindow?.isKeyWindow
    /// == true`. The widget panel is shown at launch and never hidden — `hide()` has zero callers,
    /// and the panel's `hidesOnDeactivate` is `false` (measured, not assumed, for its exact
    /// `[.borderless, .nonactivatingPanel]` construction), so it stays visible when the app
    /// deactivates. The first term was therefore permanently true and no notification could fire.
    ///
    /// Under the new rule the same situation — widget on screen, user working in another app —
    /// notifies.
    @Test
    func theSituationTheOldGateCouldNeverEscapeNowNotifies() {
        // Widget visible (as it always is), app not active, panel not key: the user is elsewhere.
        let widgetIsVisibleButNobodyIsUsingIt = SonnyAttention.shouldNotify(
            isApplicationActive: false,
            isWidgetPanelKey: false
        )
        #expect(widgetIsVisibleButNobodyIsUsingIt)
    }
}
