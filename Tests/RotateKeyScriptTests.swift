import XCTest
@testable import olcrtc_ios

// #314: tests for the "generate new key" fallback of the #303 recover flow.
//
// scripts/rotate-key.sh rotates ~/.olcrtc_key and rewrites server.yaml when
// the read-only recovery (#303) finds it unreadable/unparseable. Two contracts
// are guarded here:
//
//   1. srv.sh parity — blocks marked `# boc srv.sh` / `# eoc srv.sh` in
//      rotate-key.sh are verbatim copies of scripts/srv.sh lines (the key
//      generation, the "Generate YAML config" heredocs, the URI assembly).
//      This test is rotate-key.sh's equivalent of parity_check.py: if either
//      file drifts, it fails — no silent divergence. Comparison is
//      whitespace-trimmed because srv.sh nests some copied lines inside
//      if/else blocks (different indent, identical content).
//
//   2. Output contract — the script must emit the same OLCRTC_URI= /
//      OLCRTC_CONTAINER= lines as srv.sh so SSHRunner.parseInstallResult
//      (and OlcrtcURI.parse downstream) are reused unchanged.

final class RotateKeyScriptTests: XCTestCase {

    /// Loads scripts/<name>.sh — bundle resource first (device builds), source
    /// tree fallback for simulator runs. Same strategy as ServerScriptParityTests.
    private func loadScript(_ name: String) throws -> String {
        let url: URL = Bundle.main.url(forResource: name, withExtension: "sh")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()          // Tests/
                .deletingLastPathComponent()          // olcrtc-ios/
                .appendingPathComponent("scripts/\(name).sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: srv.sh parity

    func testSrvShOriginBlocksStayVerbatim() throws {
        let rotate = try loadScript("rotate-key")
        let srv    = try loadScript("srv")
        let srvLines = Set(srv.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })

        var inBlock = false
        var checked = 0
        for (idx, raw) in rotate.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# boc srv.sh") {
                XCTAssertFalse(inBlock, "rotate-key.sh:\(idx + 1): nested '# boc srv.sh'")
                inBlock = true
                continue
            }
            if line.hasPrefix("# eoc srv.sh") {
                XCTAssertTrue(inBlock, "rotate-key.sh:\(idx + 1): '# eoc srv.sh' without boc")
                inBlock = false
                continue
            }
            // Blank lines and comments inside a block may differ (same rule
            // parity_check.py applies to srv.sh vs upstream).
            guard inBlock, !line.isEmpty, !line.hasPrefix("#") else { continue }
            XCTAssertTrue(srvLines.contains(line),
                "rotate-key.sh:\(idx + 1) marked srv.sh-origin but not found verbatim in scripts/srv.sh: \(line)")
            checked += 1
        }
        XCTAssertFalse(inBlock, "rotate-key.sh: unclosed '# boc srv.sh' block")
        // The copied blocks (key gen + YAML heredocs + URI assembly) are ~100
        // lines; a much smaller count means the markers broke and the parity
        // guarantee silently evaporated.
        XCTAssertGreaterThan(checked, 80,
            "only \(checked) lines inside '# boc srv.sh' blocks — markers broken?")
    }

    // MARK: Output contract (same as srv.sh → parseInstallResult reuse)

    func testEmitsSrvShOutputContract() throws {
        let rotate = try loadScript("rotate-key")
        XCTAssertTrue(rotate.contains("echo \"OLCRTC_URI=$OLC_URI\""))
        XCTAssertTrue(rotate.contains("echo \"OLCRTC_CONTAINER=$CONTAINER_NAME\""))
    }

    func testParseInstallResultParsesRotateKeyOutput() throws {
        let key = String(repeating: "a", count: 64)
        // Shaped like real rotate-key.sh output (banner + uri: + contract lines).
        let output = """
        [*] Repairing olcrtc-server-ab12cd34: carrier=jitsi transport=datachannel room=https://meet1.arbitr.ru/olcrtc-ab12cd34
        [*] Generating new encryption key...
        ==========================================
        NEW ENCRYPTION KEY (saved to /root/.olcrtc_key):
        \(key)
        ==========================================
        [*] Restarting olcrtc-server-ab12cd34 so the new key takes effect...
        uri: olcrtc://jitsi?datachannel@https://meet1.arbitr.ru/olcrtc-ab12cd34#\(key)$auto-provisioned
        OLCRTC_URI=olcrtc://jitsi?datachannel@https://meet1.arbitr.ru/olcrtc-ab12cd34#\(key)$auto-provisioned
        OLCRTC_CONTAINER=olcrtc-server-ab12cd34
        """
        let result = try XCTUnwrap(SSHRunner.parseInstallResult(from: output))
        XCTAssertEqual(result.containerName, "olcrtc-server-ab12cd34")

        // End-to-end: the emitted URI must survive OlcrtcURI.parse — that is
        // what ServersView.rotateKey() builds the new connection from.
        let cfg = try OlcrtcURI.parse(result.uri)
        XCTAssertEqual(cfg.carrier,   "jitsi")
        XCTAssertEqual(cfg.transport, "datachannel")
        XCTAssertEqual(cfg.roomID,    "https://meet1.arbitr.ru/olcrtc-ab12cd34")
        XCTAssertEqual(cfg.key,       key)
        XCTAssertEqual(cfg.mimo,      "auto-provisioned")
    }

    func testParseInstallResultParsesVP8PayloadFromRotateOutput() throws {
        let key = String(repeating: "b", count: 64)
        let output = """
        OLCRTC_URI=olcrtc://wbstream?vp8channel<vp8-fps=45&vp8-batch=6>@room-1#\(key)$auto-provisioned
        OLCRTC_CONTAINER=olcrtc-server-xy98zz76
        """
        let result = try XCTUnwrap(SSHRunner.parseInstallResult(from: output))
        let cfg = try OlcrtcURI.parse(result.uri)
        XCTAssertEqual(cfg.transport,    "vp8channel")
        // Salvaged server-side tuning must reach the new ConnectionRecord.
        XCTAssertEqual(cfg.vp8FPS,       45)
        XCTAssertEqual(cfg.vp8BatchSize, 6)
    }

    // MARK: Rotation semantics

    func testKeyRotationReusesSrvShCommands() throws {
        let rotate = try loadScript("rotate-key")
        // The exact srv.sh key-generation lines — the "same key/yaml semantics"
        // requirement of #314 (rotate must not invent a different mechanism).
        XCTAssertTrue(rotate.contains("KEY_FILE=\"$HOME/.olcrtc_key\""))
        XCTAssertTrue(rotate.contains("KEY=$(openssl rand -hex 32)"))
        XCTAssertTrue(rotate.contains("chmod 600 \"$KEY_FILE\""))
        XCTAssertTrue(rotate.contains("validate_key"))
        // srv.sh's "load existing key" branch must NOT be copied — this is a
        // rotation, a pre-existing key must never be reused.
        XCTAssertFalse(rotate.contains("Loading existing encryption key"))
    }

    func testRestartsExistingContainerInsteadOfRecreating() throws {
        let rotate = try loadScript("rotate-key")
        // Same mechanism as SSHRunner.reconfigureScript: the container CMD
        // re-reads server.yaml on restart. Recreating (podman run/rm) would
        // change the container identity the app has recorded.
        XCTAssertTrue(rotate.contains("podman restart \"$CONTAINER_NAME\""))
        XCTAssertFalse(rotate.contains("podman run"))
        XCTAssertFalse(rotate.contains("podman rm"))
    }

    func testRequiresContainerEnvVar() throws {
        let rotate = try loadScript("rotate-key")
        // SSHRunner.rotateKey passes OLCRTC_CONTAINER; the script must hard-fail
        // without it rather than guessing a container.
        XCTAssertTrue(rotate.contains("${OLCRTC_CONTAINER:?"))
    }
}
