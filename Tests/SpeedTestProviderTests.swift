import XCTest
@testable import olcrtc_ios

// #285: the speed-test provider model — mode-aware URLs (smaller on the tunnel),
// the upload/ping fallbacks for fixed-file providers, and the id lookup.

final class SpeedTestProviderTests: XCTestCase {

    private func provider(_ id: String) -> SpeedTestProvider { AppConstants.SpeedTest.provider(id: id) }

    func testUnknownProviderFallsBackToFirst() {
        XCTAssertEqual(AppConstants.SpeedTest.provider(id: "nope").id,
                       AppConstants.SpeedTest.providers[0].id)
        XCTAssertEqual(AppConstants.SpeedTest.defaultProviderID, "cloudflare")
    }

    func testCloudflareIsParametricAndScalesByMode() {
        let cf = provider("cloudflare")
        XCTAssertTrue(cf.parametric)
        XCTAssertTrue(cf.supportsUpload)
        XCTAssertTrue(cf.downloadURL(mode: .tunnel).contains("bytes=\(AppConstants.SpeedTest.downloadBytesTunnel)"))
        XCTAssertTrue(cf.downloadURL(mode: .direct).contains("bytes=\(AppConstants.SpeedTest.downloadBytesDirect)"))
        XCTAssertNotNil(cf.uploadURLString)
        XCTAssertTrue(cf.pingURL().contains("/cdn-cgi/trace"))
    }

    func testOVHIsFixedFileDownloadOnly() {
        let ovh = provider("ovh")
        XCTAssertFalse(ovh.parametric)
        XCTAssertFalse(ovh.supportsUpload)
        XCTAssertNil(ovh.uploadURLString)                                       // upload → n/a
        XCTAssertEqual(ovh.downloadURL(mode: .tunnel), "https://proof.ovh.net/files/1Mb.dat")
        XCTAssertEqual(ovh.downloadURL(mode: .direct), "https://proof.ovh.net/files/10Mb.dat")
        XCTAssertEqual(ovh.pingURL(), "https://proof.ovh.net/files/1Mb.dat")    // HEAD on small file
    }

    // #291: a fixed-file provider (OVH) has no upload sink, so the upload leg
    // falls back to Cloudflare's parametric /__up; an upload-capable provider
    // keeps itself.
    func testUploadFallsBackToCloudflareForFixedFileProvider() {
        let up = AppConstants.SpeedTest.uploadProvider(for: provider("ovh"))
        XCTAssertEqual(up.id, "cloudflare")
        XCTAssertTrue(up.supportsUpload)
        XCTAssertNotNil(up.uploadURLString)
    }

    func testUploadKeepsSelectedProviderWhenItUploads() {
        XCTAssertEqual(AppConstants.SpeedTest.uploadProvider(for: provider("cloudflare")).id, "cloudflare")
    }

    func testTunnelDegradesPayloadsAndTimeouts() {
        XCTAssertLessThan(AppConstants.SpeedTest.downloadBytesTunnel, AppConstants.SpeedTest.downloadBytesDirect)
        XCTAssertLessThan(AppConstants.SpeedTest.uploadBytesTunnel, AppConstants.SpeedTest.uploadBytesDirect)
        XCTAssertGreaterThan(AppConstants.SpeedTest.xferTimeoutTunnel, AppConstants.SpeedTest.xferTimeoutDirect)
        XCTAssertGreaterThan(AppConstants.SpeedTest.pingTimeoutTunnel, AppConstants.SpeedTest.pingTimeoutDirect)
    }
}
