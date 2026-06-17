import XCTest
@testable import olcrtc_ios

// Tests for the bot feature (#416–#420): the SSHRunner script-builders +
// parser, the error mapping, and the BotPlatform/BotIdentity defaults. Pure
// string/JSON logic — no network, no SSH.

final class BotTests: XCTestCase {

    private func sampleConfig(marker: String = "olcrtc_server_bot",
                              platform: BotPlatform = .telegram) -> BotDeployConfig {
        BotDeployConfig(marker: marker, platform: platform, token: "123:ABC-secret",
                        startCmd: "go", stopCmd: "halt",
                        startReply: "Success", stopReply: "Success",
                        unknownReply: "Please try again later")
    }

    /// Builds one checkBots-style block (config base64'd with the token blanked,
    /// as the server does) so the parser tests mirror real `checkBotsScript` output.
    private func block(marker: String, active: String, config: BotDeployConfig?) -> String {
        var s = "OLCRTC_BOT_BEGIN\nmarker=\(marker)\nactive=\(active)\n"
        if let c = config {
            let json: [String: String] = [
                "platform": c.platform.rawValue, "token": "",
                "start_cmd": c.startCmd, "stop_cmd": c.stopCmd,
                "start_reply": c.startReply, "stop_reply": c.stopReply,
                "unknown_reply": c.unknownReply, "marker": c.marker,
            ]
            let b64 = (try! JSONSerialization.data(withJSONObject: json)).base64EncodedString()
            s += "config=\(b64)\n"
        } else {
            s += "config=\n"
        }
        return s + "OLCRTC_BOT_END\n"
    }

    /// Decodes every single-quoted base64 blob in a script back to text — used to
    /// verify the deploy script embeds the config JSON.
    private func base64Blobs(in script: String) -> [String] {
        script.components(separatedBy: "'").compactMap { p in
            guard p.count > 8, let d = Data(base64Encoded: p) else { return nil }
            return String(data: d, encoding: .utf8)
        }
    }

    // MARK: parseBotStatus

    func testParseFindsActiveBot() {
        let out = block(marker: "olcrtc_server_bot", active: "active", config: sampleConfig())
            + "OLCRTC_BOT_CHECK_DONE=ok\n"
        let bots = SSHRunner.parseBotStatus(from: out)
        XCTAssertEqual(bots.count, 1)
        let b = bots[0]
        XCTAssertEqual(b.marker, "olcrtc_server_bot")
        XCTAssertTrue(b.active)
        XCTAssertEqual(b.platform, .telegram)
        XCTAssertEqual(b.startCmd, "go")
        XCTAssertEqual(b.stopCmd, "halt")
        XCTAssertEqual(b.startReply, "Success")
        XCTAssertEqual(b.unknownReply, "Please try again later")
    }

    func testParseInactiveWithoutConfigFillsDefaults() {
        let bots = SSHRunner.parseBotStatus(from: block(marker: "ghost", active: "inactive", config: nil))
        XCTAssertEqual(bots.count, 1)
        XCTAssertFalse(bots[0].active)
        XCTAssertEqual(bots[0].marker, "ghost")
        XCTAssertEqual(bots[0].platform, .telegram)   // default when config absent
        XCTAssertEqual(bots[0].startCmd, "")
    }

    func testParseMaxPlatformRoundTrips() {
        let out = block(marker: "m2", active: "active", config: sampleConfig(marker: "m2", platform: .max))
        XCTAssertEqual(SSHRunner.parseBotStatus(from: out).first?.platform, .max)
    }

    func testParseEmptyOutput() {
        XCTAssertTrue(SSHRunner.parseBotStatus(from: "OLCRTC_BOT_CHECK_DONE=ok\n").isEmpty)
        XCTAssertTrue(SSHRunner.parseBotStatus(from: "").isEmpty)
    }

    func testParseMultipleBlocks() {
        let out = block(marker: "a", active: "active", config: sampleConfig(marker: "a"))
                + block(marker: "b", active: "inactive", config: nil)
        XCTAssertEqual(Set(SSHRunner.parseBotStatus(from: out).map(\.marker)), ["a", "b"])
    }

    // MARK: deployBotScript

    func testDeployScriptShape() {
        let script = SSHRunner.deployBotScript(config: sampleConfig(marker: "my_bot"), botPy: "print('hi')\n")
        XCTAssertTrue(script.contains("systemctl enable --now \"my_bot.service\""))
        XCTAssertTrue(script.contains("/etc/systemd/system/my_bot.service"))
        XCTAssertTrue(script.contains("my_bot.json"))   // written under $BOT_DIR
        XCTAssertTrue(script.contains("chmod 600"))
        XCTAssertTrue(script.contains("for cfg in"))                 // one-bot-per-server sweep
        XCTAssertTrue(script.contains("OLCRTC_BOT_ERROR=no-systemd"))
        XCTAssertTrue(script.contains("OLCRTC_BOT_ERROR=no-python3"))
        XCTAssertTrue(script.contains("OLCRTC_BOT_DEPLOYED=ok"))
    }

    func testDeployScriptEmbedsConfigJSON() {
        let script = SSHRunner.deployBotScript(config: sampleConfig(marker: "my_bot"), botPy: "x")
        let configJSON = base64Blobs(in: script).first { $0.contains("\"token\"") }
        XCTAssertNotNil(configJSON, "config JSON should be embedded as a base64 blob")
        XCTAssertTrue(configJSON!.contains("123:ABC-secret"))        // token shipped to the server
        XCTAssertTrue(configJSON!.contains("\"unknown_reply\""))
        XCTAssertTrue(configJSON!.contains("\"start_cmd\":\"go\""))
    }

    // MARK: checkBotsScript / removeBotScript

    func testCheckScriptProbesGivenNames() {
        let script = SSHRunner.checkBotsScript(markers: ["alpha", "beta"])
        XCTAssertTrue(script.contains("alpha"))
        XCTAssertTrue(script.contains("beta"))
        XCTAssertTrue(script.contains("is-active"))
        XCTAssertTrue(script.contains("/opt/olcrtc-bot"))
        XCTAssertTrue(script.contains("OLCRTC_BOT_BEGIN"))
        XCTAssertTrue(script.contains("OLCRTC_BOT_CHECK_DONE=ok"))
    }

    func testRemoveScriptDisablesAndRemovesUnit() {
        let script = SSHRunner.removeBotScript(marker: "my_bot")
        XCTAssertTrue(script.contains("systemctl disable --now \"my_bot.service\""))
        XCTAssertTrue(script.contains("/etc/systemd/system/my_bot.service"))
        XCTAssertTrue(script.contains("/opt/olcrtc-bot/my_bot.json"))
        XCTAssertTrue(script.contains("OLCRTC_BOT_REMOVED=ok"))
    }

    func testMarkerShellInjectionNeutralized() {
        // shellSafe strips ';' and whitespace, so a marker can't inject a command.
        let script = SSHRunner.removeBotScript(marker: "bad; rm -rf /tmp")
        XCTAssertFalse(script.contains("bad; rm -rf /tmp"))
        XCTAssertFalse(script.contains("; rm -rf /tmp"))
    }

    // MARK: botErrorMessage

    func testBotErrorMessageMapping() {
        XCTAssertEqual(SSHRunner.botErrorMessage("no-systemd"), L10n.botErrorNoSystemd.localized())
        XCTAssertEqual(SSHRunner.botErrorMessage("no-python3"), L10n.botErrorNoPython.localized())
        XCTAssertEqual(SSHRunner.botErrorMessage("no-root"),    L10n.botErrorNoRoot.localized())
        XCTAssertTrue(SSHRunner.botErrorMessage("weird").contains("weird"))   // generic fallback
    }

    // MARK: BotPlatform / BotIdentity

    func testPlatformDefaultsAndOrder() {
        XCTAssertEqual(BotIdentity(name: "x").platform, .telegram)   // default
        XCTAssertEqual(BotPlatform.allCases, [.telegram, .max])      // Telegram offered first
    }
}
