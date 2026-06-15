import XCTest
@testable import olcrtc_ios

// #360: pure-logic tests for the in-app update checker — version comparison
// and the 24h interval gate. Deliberately never touches the network; the
// `fetchLatestTag` round-trip is the only impure part and is out of scope.

final class UpdateCheckerTests: XCTestCase {

    // MARK: isNewer — version comparison

    func testNewerMinorVersionIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "v1.4", thanCurrent: "1.3"))
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "1.4", thanCurrent: "1.3"))
    }

    func testNewerMajorVersionIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "v2.0", thanCurrent: "1.9"))
    }

    func testEqualVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v1.3", thanCurrent: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "1.3", thanCurrent: "1.3"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v1.2", thanCurrent: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v1.0", thanCurrent: "2.0"))
    }

    func testTrailingSegmentsTreatedAsZero() {
        // "1.4" == "1.4.0", and "1.4.1" > "1.4".
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "1.4", thanCurrent: "1.4.0"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "1.4.0", thanCurrent: "1.4"))
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "1.4.1", thanCurrent: "1.4"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "1.4", thanCurrent: "1.4.1"))
    }

    func testMultiDigitSegmentsCompareNumericallyNotLexically() {
        // Lexical "10" < "9" would be wrong — numeric "10" > "9" is right.
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "1.10", thanCurrent: "1.9"))
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "1.100", thanCurrent: "1.99"))
    }

    func testLeadingVStrippedCaseInsensitive() {
        XCTAssertTrue(UpdateChecker.isNewer(latestTag: "V1.4", thanCurrent: "v1.3"))
        XCTAssertEqual(UpdateChecker.normalize("v1.4"), "1.4")
        XCTAssertEqual(UpdateChecker.normalize("V2.0"), "2.0")
        XCTAssertEqual(UpdateChecker.normalize("  v1.4  "), "1.4")
    }

    func testNonNumericTagIsNeverNewer() {
        // A garbage/unparseable tag must never nag the user.
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "latest", thanCurrent: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v1.x", thanCurrent: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "", thanCurrent: "1.3"))
        XCTAssertFalse(UpdateChecker.isNewer(latestTag: "v1.4", thanCurrent: "bad"))
    }

    // MARK: isCheckDue — interval gate

    func testNeverCheckedIsAlwaysDue() {
        XCTAssertTrue(UpdateChecker.isCheckDue(lastCheck: nil, now: Date(),
                                               interval: UpdateChecker.checkInterval))
    }

    func testCheckedJustNowIsNotDue() {
        let now = Date()
        XCTAssertFalse(UpdateChecker.isCheckDue(lastCheck: now, now: now,
                                                interval: UpdateChecker.checkInterval))
    }

    func testCheckedWithinIntervalIsNotDue() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdateChecker.isCheckDue(lastCheck: oneHourAgo, now: now,
                                                interval: UpdateChecker.checkInterval))
    }

    func testCheckedBeyondIntervalIsDue() {
        let now = Date()
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertTrue(UpdateChecker.isCheckDue(lastCheck: twoDaysAgo, now: now,
                                               interval: UpdateChecker.checkInterval))
    }

    func testExactlyAtIntervalBoundaryIsDue() {
        let now = Date()
        let exactly = now.addingTimeInterval(-UpdateChecker.checkInterval)
        XCTAssertTrue(UpdateChecker.isCheckDue(lastCheck: exactly, now: now,
                                               interval: UpdateChecker.checkInterval))
    }

    // MARK: AppConstants.Update — URL shape matches release.yml

    func testLatestReleaseAPIURLUsesRepoSlug() {
        XCTAssertEqual(AppConstants.Update.latestReleaseAPIURL.absoluteString,
                       "https://api.github.com/repos/\(AppConstants.Update.repoSlug)/releases/latest")
    }

    func testReleasePageURLForTag() {
        XCTAssertEqual(AppConstants.Update.releasePageURL(tag: "v1.4").absoluteString,
                       "https://github.com/\(AppConstants.Update.repoSlug)/releases/tag/v1.4")
    }

    func testIpaDownloadURLMatchesReleaseWorkflowShape() {
        // Must mirror release.yml's IPA_URL exactly so the deep links resolve.
        XCTAssertEqual(AppConstants.Update.ipaDownloadURL(tag: "v1.4"),
                       "https://github.com/\(AppConstants.Update.repoSlug)/releases/download/v1.4/olcrtc-ios-unsigned.ipa")
    }

    func testSideloadDeepLinksWrapTheIpaURL() {
        let ipa = AppConstants.Update.ipaDownloadURL(tag: "v1.4")
        XCTAssertEqual(AppConstants.Update.sideStoreURL(tag: "v1.4")?.absoluteString,
                       "sidestore://install?url=\(ipa)")
        XCTAssertEqual(AppConstants.Update.liveContainerURL(tag: "v1.4")?.absoluteString,
                       "livecontainer://install?url=\(ipa)")
    }
}
