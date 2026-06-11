import XCTest
@testable import olcrtc_ios

// #303: tests for SSHRunner.parseRecoveredConfig(from:), which turns the
// output of recoverConfigScript() (a `cat` of the deployed server.yaml,
// see scripts/srv.sh "Generate YAML config", plus ~/.olcrtc_key) into a
// RecoveredConfig used to rebuild an olcrtc:// URI for the "Recover
// connection" flow (#303).

final class SSHRunnerRecoverConfigTests: XCTestCase {

    private let key64 = String(repeating: "a", count: 64)

    // MARK: datachannel — minimal config, no transport-specific block

    func testParsesDatachannelConfig() throws {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        mode: srv
        auth:
          provider: "telemost"
        room:
          id: "https://meet.example.com/room-x"
        crypto:
          key: "ignored-from-yaml"
        net:
          transport: "datachannel"
          dns: "1.1.1.1:53"
        data: data
        debug: false
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        let cfg = try SSHRunner.parseRecoveredConfig(from: output)
        XCTAssertEqual(cfg.carrier, "telemost")
        XCTAssertEqual(cfg.transport, "datachannel")
        XCTAssertEqual(cfg.roomID, "https://meet.example.com/room-x")
        // OLCRTC_RECOVER_KEY (live ~/.olcrtc_key) wins over the in-YAML value.
        XCTAssertEqual(cfg.key, key64)
        XCTAssertNil(cfg.vp8FPS)
        XCTAssertNil(cfg.vp8BatchSize)
    }

    // MARK: vp8channel — extracts fps/batch_size from the vp8 block

    func testParsesVP8ChannelConfigWithTuning() throws {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        mode: srv
        auth:
          provider: "wbstream"
        room:
          id: "room-123"
        crypto:
          key: "\(key64)"
        net:
          transport: "vp8channel"
          dns: "8.8.8.8:53"
        vp8:
          fps: 60
          batch_size: 8
        data: data
        debug: false
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        let cfg = try SSHRunner.parseRecoveredConfig(from: output)
        XCTAssertEqual(cfg.carrier, "wbstream")
        XCTAssertEqual(cfg.transport, "vp8channel")
        XCTAssertEqual(cfg.roomID, "room-123")
        XCTAssertEqual(cfg.key, key64)
        XCTAssertEqual(cfg.vp8FPS, 60)
        XCTAssertEqual(cfg.vp8BatchSize, 8)
        // Not seichannel — sei fields stay nil.
        XCTAssertNil(cfg.seiFPS)
        XCTAssertNil(cfg.seiBatch)
        XCTAssertNil(cfg.seiFrag)
        XCTAssertNil(cfg.seiACK)
    }

    // MARK: seichannel — sei: block is preserved, and not mistaken for vp8

    func testParsesSeiChannelConfigPreservesTuning() throws {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        mode: srv
        auth:
          provider: "jitsi"
        room:
          id: "room-sei"
        crypto:
          key: "\(key64)"
        net:
          transport: "seichannel"
          dns: "1.1.1.1:53"
        sei:
          fps: 60
          batch_size: 20
          fragment_size: 1400
          ack_timeout_ms: 2
        data: data
        debug: false
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        let cfg = try SSHRunner.parseRecoveredConfig(from: output)
        XCTAssertEqual(cfg.transport, "seichannel")
        // sei.fps / sei.batch_size must NOT leak into vp8FPS/vp8BatchSize.
        XCTAssertNil(cfg.vp8FPS)
        XCTAssertNil(cfg.vp8BatchSize)
        // Non-default sei: tuning must be preserved, not silently dropped.
        XCTAssertEqual(cfg.seiFPS, 60)
        XCTAssertEqual(cfg.seiBatch, 20)
        XCTAssertEqual(cfg.seiFrag, 1400)
        XCTAssertEqual(cfg.seiACK, 2)
    }

    // MARK: Falls back to crypto.key when ~/.olcrtc_key is missing/empty

    func testFallsBackToYAMLKeyWhenKeyFileEmpty() throws {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        auth:
          provider: "telemost"
        room:
          id: "room-x"
        crypto:
          key: "\(key64)"
        net:
          transport: "datachannel"
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=
        """
        let cfg = try SSHRunner.parseRecoveredConfig(from: output)
        XCTAssertEqual(cfg.key, key64)
    }

    // MARK: Error paths

    func testThrowsWhenYAMLMarkersMissing() {
        let output = "no markers here at all"
        XCTAssertThrowsError(try SSHRunner.parseRecoveredConfig(from: output)) { error in
            guard case SSHRunner.RecoverConfigError.missingYAML = error else {
                return XCTFail("expected .missingYAML, got \(error)")
            }
        }
    }

    func testThrowsWhenProviderMissing() {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        room:
          id: "room-x"
        net:
          transport: "datachannel"
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=\(key64)
        """
        XCTAssertThrowsError(try SSHRunner.parseRecoveredConfig(from: output)) { error in
            guard case SSHRunner.RecoverConfigError.missingField(let field) = error else {
                return XCTFail("expected .missingField, got \(error)")
            }
            XCTAssertEqual(field, "auth.provider")
        }
    }

    func testThrowsWhenKeyMissingEverywhere() {
        let output = """
        OLCRTC_RECOVER_YAML_BEGIN
        auth:
          provider: "telemost"
        room:
          id: "room-x"
        net:
          transport: "datachannel"
        OLCRTC_RECOVER_YAML_END
        OLCRTC_RECOVER_KEY=
        """
        XCTAssertThrowsError(try SSHRunner.parseRecoveredConfig(from: output)) { error in
            guard case SSHRunner.RecoverConfigError.missingField(let field) = error else {
                return XCTFail("expected .missingField, got \(error)")
            }
            XCTAssertEqual(field, "crypto.key")
        }
    }

    // MARK: recoverConfigScript — sanity checks on the read-only shell script

    func testRecoverConfigScriptIsReadOnly() {
        let script = SSHRunner.recoverConfigScript(containerName: "olcrtc-server-abc123")
        // Must locate server.yaml the same way reconfigureScript does.
        XCTAssertTrue(script.contains("podman inspect"))
        XCTAssertTrue(script.contains("server.yaml"))
        XCTAssertTrue(script.contains("OLCRTC_RECOVER_YAML_BEGIN"))
        XCTAssertTrue(script.contains("OLCRTC_RECOVER_YAML_END"))
        XCTAssertTrue(script.contains("OLCRTC_RECOVER_KEY="))
        // Must NOT mutate anything — no restart/sed/rm.
        XCTAssertFalse(script.contains("podman restart"))
        XCTAssertFalse(script.contains("sed -i"))
        XCTAssertFalse(script.contains("podman rm"))
    }

    func testRecoverConfigScriptShellSafesContainerName() {
        let script = SSHRunner.recoverConfigScript(containerName: "olcrtc-server-abc; rm -rf /")
        XCTAssertFalse(script.contains("rm -rf /"))
    }
}
