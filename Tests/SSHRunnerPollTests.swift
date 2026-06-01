import XCTest
@testable import olcrtc_ios

// Tests for SSHRunner.pollLoop() — the install poll-loop logic.
//
// All tests inject a MockSSHClient so no real SSH connection is opened.
// sleepFn is replaced with a no-op so the tests complete instantly.
// probeFn always returns true so TCP-22 probes never interfere (the probe
// fires every 5 polls and none of these tests reach poll 5).

final class SSHRunnerPollTests: XCTestCase {

    // Minimal ServerHost used in every test. The host/port values are never
    // actually connected to — they're only referenced by the probe callback
    // (which we override) and by LogStore messages.
    private let stubHost = ServerHost(
        label: "test-vps",
        host: "192.0.2.1",   // TEST-NET-1, guaranteed non-routable
        port: 22,
        username: "root"
    )

    // Poll response that indicates the script is still running (no URI yet).
    private func runningResponse(body: String = "") -> String {
        "100\n---NEW---\n\(body)\n---STATUS---\nRUNNING\n"
    }

    // Poll response that indicates the script finished successfully.
    // Includes OLCRTC_URI and OLCRTC_CONTAINER in the tail so the loop can
    // parse them immediately without issuing a second "cat" command.
    private func doneResponse(
        uri: String = "olcrtc://telemost?datachannel@room#key1234567890123456789012345678901234567890123456789012345678901234",
        container: String = "olcrtc-server-abc123"
    ) -> String {
        let body = "Install complete.\nOLCRTC_URI=\(uri)\nOLCRTC_CONTAINER=\(container)\n"
        let size = body.utf8.count
        return "\(size)\n---NEW---\n\(body)\n---STATUS---\nDONE\n"
    }

    // Shared no-op sleep and always-success probe for all poll tests.
    private let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }
    private let alwaysProbeOK: @Sendable (String, Int) async -> Bool = { _, _ in true }

    // MARK: - testPollLoopCompletesOnDoneMarker
    //
    // Happy path: the very first poll returns DONE with the URI already in the
    // tail. The loop parses it immediately and returns an InstallResult.

    func testPollLoopCompletesOnDoneMarker() async throws {
        let expectedURI       = "olcrtc://telemost?datachannel@room#key1234"
        let expectedContainer = "olcrtc-server-abc123"

        let mock = MockSSHClient(responses: [
            ("poll 1", .success(doneResponse(uri: expectedURI, container: expectedContainer))),
        ])

        let result = try await SSHRunner.pollLoop(
            sshClient: mock,
            host: stubHost,
            onStep: { _ in },
            maxPolls: 5,
            pollInterval: 0,
            sleepFn: noSleep,
            probeFn: alwaysProbeOK
        )

        XCTAssertEqual(result.uri, expectedURI)
        XCTAssertEqual(result.containerName, expectedContainer)
        XCTAssertEqual(mock.history.count, 1,
                       "loop should stop after the first successful DONE response")
    }

    // MARK: - testPollLoopRetriesOnTransientError
    //
    // Transient errors (connection refused) are retried. The loop counts them
    // toward the 3-in-a-row abort threshold; a successful poll resets the
    // counter. Here: 2 errors → success → InstallResult returned.

    func testPollLoopRetriesOnTransientError() async throws {
        struct ConnRefused: LocalizedError {
            var errorDescription: String? { "Connection refused" }
        }

        let expectedURI       = "olcrtc://jitsi?vp8channel@auto#key9999"
        let expectedContainer = "olcrtc-server-xyz789"

        let mock = MockSSHClient(responses: [
            ("poll 1 — refused", .failure(ConnRefused())),
            ("poll 2 — refused", .failure(ConnRefused())),
            ("poll 3 — success", .success(doneResponse(uri: expectedURI,
                                                        container: expectedContainer))),
        ])

        let result = try await SSHRunner.pollLoop(
            sshClient: mock,
            host: stubHost,
            onStep: { _ in },
            maxPolls: 5,
            pollInterval: 0,
            sleepFn: noSleep,
            probeFn: alwaysProbeOK
        )

        XCTAssertEqual(result.uri, expectedURI)
        XCTAssertEqual(result.containerName, expectedContainer)
        // All 3 responses consumed: 2 errors + 1 success.
        XCTAssertEqual(mock.history.count, 3)
    }

    // MARK: - testPollLoopAbortsOnAuthError
    //
    // Auth failures are non-retryable. The loop must throw immediately on the
    // first call that surfaces an auth-classified error, without consuming
    // any further responses.

    func testPollLoopAbortsOnAuthError() async throws {
        struct AuthFailed: LocalizedError {
            var errorDescription: String? { "authentication failed" }
        }

        let mock = MockSSHClient(responses: [
            ("poll 1 — auth", .failure(AuthFailed())),
            // This response must never be consumed.
            ("poll 2 — should not reach", .success(doneResponse())),
        ])

        do {
            _ = try await SSHRunner.pollLoop(
                sshClient: mock,
                host: stubHost,
                onStep: { _ in },
                maxPolls: 5,
                pollInterval: 0,
                sleepFn: noSleep,
                probeFn: alwaysProbeOK
            )
            XCTFail("Expected ProvisionError.sshConnect to be thrown for auth failure")
        } catch let err as ProvisionError {
            // Must throw sshConnect, not parseFailed or sshCommand.
            if case .sshConnect = err {
                // Correct — auth errors surface as sshConnect.
            } else {
                XCTFail("Expected .sshConnect, got: \(err)")
            }
        }

        // Only 1 call made — the loop aborts immediately.
        XCTAssertEqual(mock.history.count, 1,
                       "auth error must abort the loop immediately without retrying")
    }

    // MARK: - testPollLoopAbortsOnConsecutiveErrors
    //
    // Three consecutive transient errors hit sshErrorAbortThreshold (3).
    // The loop must throw ProvisionError.sshConnect after the third error.

    func testPollLoopAbortsOnConsecutiveErrors() async throws {
        struct BrokenPipe: LocalizedError {
            var errorDescription: String? { "Broken pipe" }
        }

        let mock = MockSSHClient(responses: [
            ("poll 1 — broken pipe", .failure(BrokenPipe())),
            ("poll 2 — broken pipe", .failure(BrokenPipe())),
            ("poll 3 — broken pipe", .failure(BrokenPipe())),
            // Must not be reached.
            ("poll 4 — should not reach", .success(doneResponse())),
        ])

        do {
            _ = try await SSHRunner.pollLoop(
                sshClient: mock,
                host: stubHost,
                onStep: { _ in },
                maxPolls: 10,
                pollInterval: 0,
                sleepFn: noSleep,
                probeFn: alwaysProbeOK
            )
            XCTFail("Expected ProvisionError.sshConnect after 3 consecutive transient errors")
        } catch let err as ProvisionError {
            if case .sshConnect = err {
                // Correct.
            } else {
                XCTFail("Expected .sshConnect, got: \(err)")
            }
        }

        // Exactly 3 error responses consumed before abort.
        XCTAssertEqual(mock.history.count, 3,
                       "loop must abort after exactly sshErrorAbortThreshold (3) consecutive errors")
    }
}
