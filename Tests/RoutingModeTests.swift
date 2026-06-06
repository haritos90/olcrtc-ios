import XCTest
@testable import olcrtc_ios

// Tests for `RoutingMode` (#273). The routing segmented control in ConnectionsView
// renders `allCases`, and the selection persists via `@AppStorage("olcrtc_routing_mode")`
// as the raw string — so the cases and their raw values are a small contract.

final class RoutingModeTests: XCTestCase {

    // Raw values are persisted; renaming one would silently reset saved preferences.
    func testRawValuesAreStable() {
        XCTAssertEqual(RoutingMode.allTunnel.rawValue, "allTunnel")
        XCTAssertEqual(RoutingMode.allDirect.rawValue, "allDirect")
    }

    // A bad/empty stored value falls back to `.allTunnel` (the ConnectionsView
    // accessor uses `?? .allTunnel`), so an unknown raw must not resolve.
    func testUnknownRawValueIsNotAMode() {
        XCTAssertNil(RoutingMode(rawValue: "nonsense"))
    }

    // The control must offer a real choice now — Direct (#273) is present, and both
    // modes carry a non-empty, distinct title (so neither chip is blank).
    func testBothModesPresentWithDistinctTitles() {
        let saved = SettingsStore.shared.language
        defer { SettingsStore.shared.language = saved }
        SettingsStore.shared.language = "en"

        let modes = RoutingMode.allCases
        XCTAssertEqual(modes.count, 2)
        XCTAssertTrue(modes.contains(.allTunnel))
        XCTAssertTrue(modes.contains(.allDirect))
        XCTAssertFalse(RoutingMode.allTunnel.title.isEmpty)
        XCTAssertFalse(RoutingMode.allDirect.title.isEmpty)
        XCTAssertNotEqual(RoutingMode.allTunnel.title, RoutingMode.allDirect.title)
    }
}
