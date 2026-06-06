import XCTest
@testable import olcrtc_ios

// #281: the Refined / Console directions must be *visibly* distinct (they used to
// differ by only ~2pt radius / 0.5pt border and looked identical). This pins the
// key metric tokens so a future tweak can't quietly collapse them back together.

@MainActor
final class ThemeDirectionTests: XCTestCase {

    func testConsoleIsSharperAndDenserThanRefined() {
        let saved = SettingsStore.shared.designConsole
        defer { SettingsStore.shared.designConsole = saved }

        SettingsStore.shared.designConsole = false
        let refinedCardRadius   = Theme.Metrics.cardRadius
        let refinedCtrlRadius   = Theme.Metrics.controlRadius
        let refinedBorder       = Theme.Metrics.cardBorderWidth
        let refinedPadding      = Theme.Metrics.cardPadding
        let refinedSectionGap   = Theme.Metrics.sectionGap

        SettingsStore.shared.designConsole = true
        // Console = sharper radii, a real border, denser spacing.
        XCTAssertLessThan(Theme.Metrics.cardRadius, refinedCardRadius)
        XCTAssertLessThan(Theme.Metrics.controlRadius, refinedCtrlRadius)
        XCTAssertGreaterThan(Theme.Metrics.cardBorderWidth, refinedBorder)
        XCTAssertLessThan(Theme.Metrics.cardPadding, refinedPadding)
        XCTAssertLessThan(Theme.Metrics.sectionGap, refinedSectionGap)
        // Refined draws no card border at all.
        XCTAssertEqual(refinedBorder, 0)
    }
}
