import XCTest
import SwiftUI
@testable import olcrtc_ios

// #299 was: testConsoleIsSharperAndDenserThanRefined — pinned the Refined vs
// Console "design direction" metric tokens. The direction is gone; Theme is now
// real colour schemes (System / Light / Dark / Gray). These tests pin the new
// contract: the appearance modes and the single (Refined) metric values.

@MainActor
final class ThemeDirectionTests: XCTestCase {

    /// Gray is a first-class appearance mode, distinct from System/Light/Dark.
    func testAppearanceModesIncludeGray() {
        XCTAssertEqual(AppearanceMode.allCases,
                       [.system, .light, .dark, .gray])
        // Each mode has a non-empty, distinct title (drives the Settings picker).
        let titles = AppearanceMode.allCases.map { $0.title }
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }

    /// Gray forces dark system chrome (its grounds are on the dark side); System
    /// follows the OS (nil); Light/Dark force their own scheme.
    func testGrayUsesDarkColorScheme() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme,  .dark)
        XCTAssertEqual(AppearanceMode.gray.colorScheme,  .dark)   // #299
    }

    /// Selecting Gray changes the resolved ground tokens (no longer pure black).
    func testGrayChangesGroundTokens() {
        let saved = SettingsStore.shared.appearanceMode
        defer { SettingsStore.shared.appearanceMode = saved }

        SettingsStore.shared.appearanceMode = .dark
        let darkBG = UIColor(Theme.Palette.bg).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark))

        SettingsStore.shared.appearanceMode = .gray
        let grayBG = UIColor(Theme.Palette.bg).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark))

        // Selecting Gray changes the resolved ground…
        XCTAssertNotEqual(darkBG, grayBG)
        // …to a neutral mid-gray (systemGray6 ≈ 0x1C1C1E, white ≈ 0.106): not
        // pure-black (the dark ground) and not a light ground. Gray's bg is
        // trait-independent (same UIColor for light & dark), so its resolved
        // white component is stable regardless of how the Color→UIColor bridge
        // bakes the trait — unlike the dynamic dark token, which is why we pin
        // gray's absolute value rather than comparing it against the dark one.
        var grayWhite: CGFloat = 0
        grayBG.getWhite(&grayWhite, alpha: nil)
        XCTAssertEqual(grayWhite, 0.106, accuracy: 0.05)
    }

    /// The "design direction" tokens collapsed to single Refined values:
    /// no card border, soft radii, roomy padding.
    func testMetricsAreSingleRefinedValues() {
        XCTAssertEqual(Theme.Metrics.cardBorderWidth, 0)
        XCTAssertEqual(Theme.Metrics.cardRadius, 20)
        XCTAssertEqual(Theme.Metrics.controlRadius, 13)
        XCTAssertEqual(Theme.Metrics.cardPadding, 16)
    }
}
