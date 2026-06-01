import XCTest
@testable import olcrtc_ios

// Tests for SSHRunner.extract(key:from:) and parseInstallResult().
// These pure functions drive the install poll loop — getting them wrong
// would either miss a successful install or report failure spuriously.

final class SSHRunnerExtractTests: XCTestCase {

    // MARK: extract(key:from:)

    func testExtractSimpleKeyValue() {
        let output = "OLCRTC_URI=olcrtc://telemost?datachannel@r#k"
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_URI", from: output),
                       "olcrtc://telemost?datachannel@r#k")
    }

    func testExtractFromMultilineOutput() {
        let output = """
        Some other log lines
        OLCRTC_CONTAINER=olcrtc-server-abc123
        OLCRTC_URI=olcrtc://wbstream?vp8channel@room-x#key1234
        another line
        """
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_CONTAINER", from: output),
                       "olcrtc-server-abc123")
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_URI", from: output),
                       "olcrtc://wbstream?vp8channel@room-x#key1234")
    }

    func testExtractMissingKeyReturnsNil() {
        let output = "OLCRTC_OTHER=foo"
        XCTAssertNil(SSHRunner.extract(key: "OLCRTC_URI", from: output))
    }

    func testExtractEmptyOutputReturnsNil() {
        XCTAssertNil(SSHRunner.extract(key: "OLCRTC_URI", from: ""))
    }

    func testExtractIgnoresKeyPrefix() {
        // Ensure "OLCRTC_URI" doesn't match "OLCRTC_URI_PREFIX"
        let output = "OLCRTC_URI_PREFIX=ignored\nOLCRTC_URI=real-value"
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_URI", from: output),
                       "real-value")
    }

    func testExtractTrimsLeadingWhitespace() {
        let output = "    OLCRTC_URI=indented-value"
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_URI", from: output),
                       "indented-value")
    }

    func testExtractEmptyValue() {
        let output = "OLCRTC_URI="
        XCTAssertEqual(SSHRunner.extract(key: "OLCRTC_URI", from: output), "")
    }

    // MARK: extract(keys:from:) — single-pass multi-key overload.

    func testExtractMultipleKeysSinglePass() {
        // Both keys present; both should be returned in one walk.
        let output = """
        Building olcrtc...
        OLCRTC_CONTAINER=olcrtc-server-abc123
        more log
        OLCRTC_URI=olcrtc://telemost?datachannel@r#k
        end
        """
        let result = SSHRunner.extract(keys: ["OLCRTC_URI", "OLCRTC_CONTAINER"], from: output)
        XCTAssertEqual(result["OLCRTC_URI"], "olcrtc://telemost?datachannel@r#k")
        XCTAssertEqual(result["OLCRTC_CONTAINER"], "olcrtc-server-abc123")
    }

    func testExtractMultipleKeysPartialMatch() {
        // One key present, one absent — absent key is simply missing from the dict.
        let output = "OLCRTC_URI=value"
        let result = SSHRunner.extract(keys: ["OLCRTC_URI", "OLCRTC_CONTAINER"], from: output)
        XCTAssertEqual(result["OLCRTC_URI"], "value")
        XCTAssertNil(result["OLCRTC_CONTAINER"])
    }

    func testExtractMultipleKeysEmptyOutput() {
        XCTAssertTrue(
            SSHRunner.extract(keys: ["OLCRTC_URI", "OLCRTC_CONTAINER"], from: "").isEmpty)
    }

    func testExtractMultipleKeysFirstOccurrenceWins() {
        // Mirrors extract(key:from:) — first match wins on duplicate keys.
        let output = """
        OLCRTC_URI=first
        OLCRTC_URI=second
        """
        let result = SSHRunner.extract(keys: ["OLCRTC_URI"], from: output)
        XCTAssertEqual(result["OLCRTC_URI"], "first")
    }

    // MARK: parsePollPayload — install poll loop response splitter.
    //
    // The poll command produces:
    //   <wc -c byte count>\n---NEW---\n<new tail body>\n---STATUS---\n<DONE|RUNNING>
    // parsePollPayload must extract all three parts, tolerate missing
    // markers (fallback path when log file doesn't exist yet), and report
    // the DONE/RUNNING token.

    func testParsePollPayloadHappyPath() {
        let output = """
        4096
        ---NEW---
        Building olcrtc...
        OLCRTC_URI=olcrtc://r?datachannel@x#k
        \n---STATUS---
        RUNNING
        """
        // Note: the literal string above has the exact "\n---STATUS---\n"
        // separator the runtime produces; XCTAssert against the parser.
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertEqual(parts.newSize, 4096)
        XCTAssertTrue(parts.body.contains("OLCRTC_URI=olcrtc://r?datachannel@x#k"))
        XCTAssertFalse(parts.isDone)
    }

    func testParsePollPayloadDoneMarker() {
        let output = "1024\n---NEW---\nfinal log line\n---STATUS---\nDONE\n"
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertEqual(parts.newSize, 1024)
        XCTAssertEqual(parts.body, "final log line")
        XCTAssertTrue(parts.isDone)
    }

    func testParsePollPayloadEmptyBody() {
        // Server reports the file size but produced no new bytes since the
        // last offset — common when polling is faster than srv.sh emits.
        let output = "8192\n---NEW---\n\n---STATUS---\nRUNNING\n"
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertEqual(parts.newSize, 8192)
        XCTAssertEqual(parts.body, "")
        XCTAssertFalse(parts.isDone)
    }

    func testParsePollPayloadMissingWCFallsBackToNilSize() {
        // wc -c failed (file not created yet) — header line is empty.
        // Parser should report newSize=nil but still split the body/status.
        let output = "\n---NEW---\nearly output\n---STATUS---\nRUNNING\n"
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertNil(parts.newSize)
        XCTAssertEqual(parts.body, "early output")
        XCTAssertFalse(parts.isDone)
    }

    func testParsePollPayloadGarbledHeaderFallsBackToNilSize() {
        // wc -c output was non-numeric — defensive, shouldn't happen but
        // the parser must not crash or guess. nil size triggers the
        // poll-loop fallback "full-tail" mode.
        let output = "not a number\n---NEW---\nbody\n---STATUS---\nRUNNING\n"
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertNil(parts.newSize)
        XCTAssertEqual(parts.body, "body")
    }

    func testParsePollPayloadMissingNewMarker() {
        // Older / non-conforming output (no ---NEW--- marker). Parser
        // returns the whole pre-STATUS chunk as body and nil size, so the
        // poll loop falls back to treating it like a tail-c dump.
        let output = "raw log content here\n---STATUS---\nDONE\n"
        let parts = SSHRunner.parsePollPayload(output)
        XCTAssertNil(parts.newSize)
        XCTAssertEqual(parts.body, "raw log content here")
        XCTAssertTrue(parts.isDone)
    }

    func testParsePollPayloadMissingStatusMarker() {
        // Defensive: if the status marker is somehow absent, isDone defaults
        // to false (we shouldn't claim "done" without explicit DONE).
        let output = "100\n---NEW---\nsome body"
        let parts = SSHRunner.parsePollPayload(output)
        // Without the status marker the body parsing also fails — we get
        // newSize but body falls back to "everything before status" which
        // here is the whole input. That's fine; the poll loop just retries.
        XCTAssertFalse(parts.isDone)
    }

    // MARK: parseInstallResult(from:)

    func testParseSuccessfulInstallResult() {
        let output = """
        Building olcrtc...
        OLCRTC_URI=olcrtc://telemost?datachannel@r#\(String(repeating: "a", count: 64))
        OLCRTC_CONTAINER=olcrtc-server-xyz
        Done.
        """
        let result = SSHRunner.parseInstallResult(from: output)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.uri.hasPrefix("olcrtc://") ?? false)
        XCTAssertEqual(result?.containerName, "olcrtc-server-xyz")
    }

    func testParseMissingURIReturnsNil() {
        let output = "OLCRTC_CONTAINER=olcrtc-server-xyz"
        XCTAssertNil(SSHRunner.parseInstallResult(from: output))
    }

    func testParseMissingContainerReturnsNil() {
        let output = "OLCRTC_URI=olcrtc://telemost?datachannel@r#k"
        XCTAssertNil(SSHRunner.parseInstallResult(from: output))
    }

    func testParseEmptyOutputReturnsNil() {
        XCTAssertNil(SSHRunner.parseInstallResult(from: ""))
    }

    // MARK: shellSafe — env-var value sanitization

    func testShellSafeStripsSpacesInsideValue() {
        // Telemost UI displays room IDs with spaces like "3528 5410 1234";
        // we strip them so the value doesn't break the launch shell command.
        XCTAssertEqual(SSHRunner.shellSafe("3528 5410 1234"), "352854101234")
    }

    func testShellSafeStripsShellMetacharacters() {
        // Dangerous chars must not survive — they would let a user-supplied
        // room ID break out of the env-var assignment.
        XCTAssertEqual(SSHRunner.shellSafe("foo; rm -rf /"), "foorm-rf/")
        XCTAssertEqual(SSHRunner.shellSafe("a|b&c<d>e"), "abcde")
        XCTAssertEqual(SSHRunner.shellSafe("$(whoami)"), "whoami")
        XCTAssertEqual(SSHRunner.shellSafe("`cmd`"), "cmd")
        XCTAssertEqual(SSHRunner.shellSafe("\"q\"\\\\"), "q")
    }

    func testShellSafeKeepsSafePunctuation() {
        // DNS values, room UUIDs, config names need these characters intact.
        XCTAssertEqual(SSHRunner.shellSafe("77.88.8.8:53"), "77.88.8.8:53")
        XCTAssertEqual(SSHRunner.shellSafe("auto-provisioned"), "auto-provisioned")
        XCTAssertEqual(SSHRunner.shellSafe("ios_abc-123.4"), "ios_abc-123.4")
    }

    func testShellSafeStripsTabsAndNewlines() {
        XCTAssertEqual(SSHRunner.shellSafe("foo\tbar"), "foobar")
        XCTAssertEqual(SSHRunner.shellSafe("line1\nline2"), "line1line2")
    }

    func testShellSafeDNSInjectionPayload() {
        // Defensive: the Settings UI clamps the DNS field to IP:port, but the
        // install env-var builder must not trust UI validation. A pasted
        // payload like "8.8.8.8; rm -rf /" must have every shell metacharacter
        // (semicolon, spaces, &, |, etc.) stripped so the result cannot be
        // re-interpreted as a command when expanded inside OLCRTC_DNS=<value>.
        // Note: "/" is not a shell metacharacter and is intentionally kept;
        // the resulting "8.8.8.8rm-rf" is harmless garbage, not a command.
        let sanitized = SSHRunner.shellSafe("8.8.8.8; rm -rf /")
        XCTAssertFalse(sanitized.contains(";"))
        XCTAssertFalse(sanitized.contains(" "))
        XCTAssertFalse(sanitized.contains("&"))
        XCTAssertFalse(sanitized.contains("|"))
        XCTAssertFalse(sanitized.contains("`"))
        XCTAssertFalse(sanitized.contains("$"))

        // Benign IPv4:port DNS values must pass through unchanged.
        XCTAssertEqual(SSHRunner.shellSafe("8.8.8.8"), "8.8.8.8")
        XCTAssertEqual(SSHRunner.shellSafe("8.8.8.8:53"), "8.8.8.8:53")
    }

    // MARK: classifySSHError — install poll loop connectivity classification.
    //
    // The pollUntilDone() loop uses this to decide whether an SSH-layer error
    // mid-install is fatal (auth changed) or worth retrying (transient TCP
    // glitch). The invariant the loop assumes:
    //   - .auth → throw .sshConnect immediately
    //   - .transient → count toward 3-in-a-row abort

    private struct StubError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    func testClassifyAuthFailureIsFatal() {
        // Citadel surfaces auth rejections with several phrasings depending
        // on which NIOSSH path failed — match the common ones.
        let phrases = [
            "authentication failed",
            "Permission denied (publickey,password)",
            "auth failed: server rejected password",
            "Unable to authenticate with remote SSH server",
            "All authentication methods failed",
            "Bad password",
        ]
        for p in phrases {
            XCTAssertEqual(SSHRunner.classifySSHError(StubError(msg: p)), .auth,
                "Expected .auth for: \(p)")
        }
    }

    func testClassifyTransientErrorsAreRetryable() {
        // These all happen during normal install (VPS reboots during apt-get,
        // firewall blip, NIO idle-channel kicking us out, etc.) — we should
        // count them toward the 3-in-a-row threshold, not abort immediately.
        let phrases = [
            "Connection refused",
            "Connection reset by peer",
            "Broken pipe",
            "I/O timeout",
            "channel closed",
            "EOF before handshake",
            "NIOConnectionError: ECONNREFUSED",
        ]
        for p in phrases {
            XCTAssertEqual(SSHRunner.classifySSHError(StubError(msg: p)), .transient,
                "Expected .transient for: \(p)")
        }
    }

    func testClassifyUnknownErrorDefaultsToTransient() {
        // Defensive default — an unrecognized error should not be treated as
        // .auth (that would permanently lock the user out on a fluke). The
        // 3-in-a-row abort still catches genuinely broken sessions.
        XCTAssertEqual(SSHRunner.classifySSHError(StubError(msg: "something weird happened")),
                       .transient)
        XCTAssertEqual(SSHRunner.classifySSHError(StubError(msg: "")),
                       .transient)
    }

    // MARK: uninstallScript — container-name prefix parity with scripts/srv.sh.
    //
    // The server script names containers `olcrtc-server-$PODMAN_ID`
    // (scripts/srv.sh:8). If the client uninstall fallback filter ever drifts
    // away from that prefix, the "sweep all olcrtc containers when we have
    // no recorded name" path will silently find zero containers and leave
    // them running on the VPS. These tests pin the prefix on both branches.

    func testUninstallScriptPrefixMatchesServer() {
        XCTAssertEqual(SSHRunner.containerNamePrefix, "olcrtc-server-")
    }

    func testUninstallScriptExactMatchBranchUsesContainerName() {
        let script = SSHRunner.uninstallScript(containerName: "olcrtc-server-abc123")
        XCTAssertTrue(script.contains("'^olcrtc-server-abc123$'"),
                      "exact-match grep should anchor on the recorded container name")
        XCTAssertTrue(script.contains(#"podman stop "olcrtc-server-abc123""#))
        XCTAssertTrue(script.contains(#"podman rm   "olcrtc-server-abc123""#))
    }

    func testUninstallScriptSweepBranchUsesServerPrefix() {
        let script = SSHRunner.uninstallScript(containerName: nil)
        XCTAssertTrue(script.contains("--filter 'name=olcrtc-server-'"),
                      "no-name fallback sweep must filter on the server-side prefix")
        XCTAssertFalse(script.contains("olcrtc-srv-"),
                      "stale `olcrtc-srv-` prefix must not leak back")
    }
}
