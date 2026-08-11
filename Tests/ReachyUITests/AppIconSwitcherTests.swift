@testable import ReachyDesign
@testable import ReachyUI
import Testing

/// UIKit refuses to change an icon outside a foreground-active app, so the switch
/// itself is device-only. What is testable here is the decision *around* it: which
/// name a theme resolves to, and that the no-op cases are treated as success rather
/// than as a refusal the picker would report to the reader.
@Suite("App icon switcher")
struct AppIconSwitcherTests {
    @Test("the fallback theme resolves to the primary icon")
    func fallbackResolvesToPrimary() {
        #expect(AppIconSwitcher.iconName(for: .graphite) == nil)
    }

    @Test("a themed icon resolves to its bundle name")
    func themedResolvesToBundleName() {
        #expect(AppIconSwitcher.iconName(for: .rose) == "AppIcon-Rose")
    }

    @Test("applying the icon already in use is a no-op success")
    func alreadyInUseIsSuccess() {
        #expect(AppIconSwitcher.isAlreadyApplied(.rose, current: "AppIcon-Rose"))
        #expect(AppIconSwitcher.isAlreadyApplied(.graphite, current: nil))
    }

    @Test("applying a different icon is not a no-op")
    func differentIconIsNotANoOp() {
        #expect(AppIconSwitcher.isAlreadyApplied(.rose, current: nil) == false)
        #expect(AppIconSwitcher.isAlreadyApplied(.graphite, current: "AppIcon-Rose") == false)
    }
}
