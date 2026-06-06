import XCTest
@testable import olcrtc_ios

// #286: the IP-check provider catalogue + the default-enabled subset. The labels
// key the persisted on/off set (SettingsStore.enabledIPSources), so they must be
// unique and stable; every endpoint must be HTTPS; and there must be several
// RU/ru-zone options so Russian users have reachable sources.

final class IPCheckSourcesTests: XCTestCase {

    private let ruLabels = ["2ip.ru", "2ip.io", "ip.beget.ru"]

    func testCatalogueHasTenUniqueProviders() {
        let labels = AppConstants.ipCheckServices.map(\.label)
        XCTAssertEqual(labels.count, 10)
        XCTAssertEqual(Set(labels).count, 10, "labels must be unique — they key the enabled set")
    }

    func testEveryServiceUsesHTTPS() {
        for s in AppConstants.ipCheckServices {
            XCTAssertTrue(s.url.hasPrefix("https://"), "\(s.label) must be HTTPS")
        }
    }

    func testIncludesSeveralRUZoneProviders() {
        let labels = Set(AppConstants.ipCheckServices.map(\.label))
        let present = ruLabels.filter { labels.contains($0) }
        XCTAssertGreaterThanOrEqual(present.count, 3, "need several RU/ru-zone options")
    }

    func testDefaultsAreANonEmptySubsetOfTheCatalogue() {
        let labels = Set(AppConstants.ipCheckServices.map(\.label))
        XCTAssertFalse(AppConstants.defaultEnabledIPCheckLabels.isEmpty)
        XCTAssertTrue(AppConstants.defaultEnabledIPCheckLabels.isSubset(of: labels),
                      "every default-enabled label must exist in the catalogue")
    }

    func testDefaultsIncludeAtLeastOneRUSource() {
        XCTAssertTrue(AppConstants.defaultEnabledIPCheckLabels.contains { ruLabels.contains($0) },
                      "RU users should get a reachable source out of the box")
    }
}
