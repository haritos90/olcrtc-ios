import XCTest
@testable import olcrtc_ios

// #415: coverage for the subscription-refresh helpers (#362 + #411) — the
// `fetchURL(for:)` scheme mapping and the refresh loop's skip-on-failure /
// due-vs-force behaviour. The fetch is injected, so no network is touched.
// Per-source assertions keep the tests robust to any subscription meta left in
// the shared UserDefaults by other tests.

// `@MainActor`: ConnectionStore (and its static `fetchURL`) is MainActor-isolated.
@MainActor
final class SubscriptionRefreshTests: XCTestCase {

    // MARK: fetchURL(for:) — static, pure

    func testFetchURLMapsOlcrtcSubToHTTPS() {
        XCTAssertEqual(
            ConnectionStore.fetchURL(for: "olcrtc-sub://host.example/list")?.absoluteString,
            "https://host.example/list")
    }

    func testFetchURLPassesHTTPSThrough() {
        XCTAssertEqual(
            ConnectionStore.fetchURL(for: "https://host.example/list")?.absoluteString,
            "https://host.example/list")
    }

    func testFetchURLRejectsOtherSchemes() {
        XCTAssertNil(ConnectionStore.fetchURL(for: "olcrtc://wbstream?datachannel@room#key"))
        XCTAssertNil(ConnectionStore.fetchURL(for: "ftp://host.example/list"))
        XCTAssertNil(ConnectionStore.fetchURL(for: "mailto:x@example.com"))
    }

    // MARK: refresh loop

    /// A fetch failure for one source is skipped; the others still refresh.
    @MainActor
    func testRefreshSkipsFailedSourceAndContinues() async {
        let store = ConnectionStore()
        var sub = OlcrtcSubscription()
        sub.refresh = "60s"   // #refresh → 60 s interval; due in the future
        store.importSubscription(sub, source: "https://skip-a.example/sub")
        store.importSubscription(sub, source: "https://ok-b.example/sub")

        let future = Date().addingTimeInterval(3600)   // both sources are now due
        let refreshed = await store.refreshDueSources(now: future) { url in
            if url.host == "skip-a.example" { throw URLError(.timedOut) }
            return "# refreshed list"
        }

        XCTAssertTrue(refreshed.contains("https://ok-b.example/sub"))   // succeeded
        XCTAssertFalse(refreshed.contains("https://skip-a.example/sub")) // fetch threw → skipped
    }

    /// #411: refreshAllSources re-fetches a source even when its `#refresh`
    /// interval hasn't elapsed; refreshDueSources leaves it alone until then.
    @MainActor
    func testRefreshAllForcesEvenWhenNotDue() async {
        let store = ConnectionStore()
        var sub = OlcrtcSubscription()
        sub.refresh = "1d"   // #refresh → a day; not due right after import
        store.importSubscription(sub, source: "https://force-c.example/sub")

        let fetch: (URL) async throws -> String = { _ in "# list" }
        let due = await store.refreshDueSources(fetch: fetch)
        XCTAssertFalse(due.contains("https://force-c.example/sub"))   // not due yet
        let all = await store.refreshAllSources(fetch: fetch)
        XCTAssertTrue(all.contains("https://force-c.example/sub"))    // force-refreshed
    }
}
