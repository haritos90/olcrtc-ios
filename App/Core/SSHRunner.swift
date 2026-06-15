import Foundation
@preconcurrency import Citadel
import NIO

// SSH transport helpers for Provisioner. Pure static functions over Citadel.
// Extracted from Provisioning.swift on 2026-05-16.

// MARK: - SSHRunner (nonisolated)

enum SSHRunner {

    // MARK: Install

    /// Client-side conventions only — srv.sh never reads or references these paths.
    /// The client creates them via the nohup launch pipeline; renaming any path
    /// here requires no change to srv.sh.
    private enum RemotePaths {
        static let script = "/tmp/olcrtc-ios-srv.sh"
        static let log    = "/tmp/olcrtc-install.log"
        static let exit   = "/tmp/olcrtc-install.exit"
        // #314: key-rotation fallback script (see rotateKey below).
        static let rotateScript = "/tmp/olcrtc-ios-rotate-key.sh"
    }

    private static let installMaxPolls: Int               = 100   // 100 × 15 s = 25 min max
    private static let installPollInterval: TimeInterval  = 15
    private static let sshRetryDelay: TimeInterval        = 4    // pause between SSH connect retries — matches L10n.sshRetryIn4s

    // Connectivity-loss thresholds during the install poll loop.
    //
    // Why both counters? They detect different failure modes:
    //   - sshErrorAbortThreshold catches SSH-layer breakage (auth churn,
    //     port reset by firewall, broken Citadel channel) when the TCP-22
    //     probe might still succeed.
    //   - probeFailureAbortThreshold catches "the VPS dropped off the
    //     network entirely" (power off, ISP block, kernel panic during
    //     apt-get upgrade) — even if our last SSH-attempt error string
    //     looked benign.
    //
    // The values are deliberately small so the user learns about lost
    // connectivity within ~45 s (3 × 15 s) instead of the full 25-minute
    // budget.
    private static let sshErrorAbortThreshold:    Int = 3   // 3 × 15 s ≈ 45 s
    private static let probeIntervalPolls:        Int = 5   // probe every 5 polls (~75 s)
    private static let probeFailureAbortThreshold: Int = 2  // 2 consecutive probes ≈ 150 s of confirmed unreachability
    private static let probeTimeout: TimeInterval = 5       // TCP-22 probe timeout

    /// Coarse classification of SSH-layer errors thrown during the install
    /// poll. We don't have a structured error type from Citadel, so we sniff
    /// the error description for auth-failure markers — those are
    /// unrecoverable and should abort immediately. Everything else is treated
    /// as transient (timeouts, broken pipes, "connection refused" while the
    /// VPS is rebooting mid-apt-get) and counted toward
    /// `sshErrorAbortThreshold` before we give up.
    enum SSHErrorKind: Equatable {
        case auth          // unrecoverable — bad creds / sshd rejected us
        case transient     // retry: timeout, refused, broken pipe, channel closed
    }

    /// Pure helper exposed for tests. Inspects the lowercased error string
    /// for known auth-failure phrases. New unmatched phrases default to
    /// `.transient` so a poll-loop quirk never permanently locks a user out
    /// of installs — they can still hit the 3-in-a-row abort.
    static func classifySSHError(_ error: Error) -> SSHErrorKind {
        let desc = error.localizedDescription.lowercased()
        // Citadel surfaces auth failures with several different wordings
        // depending on the underlying NIOSSH error path; match all of them.
        let authMarkers = [
            "authentication", "auth failed", "permission denied",
            "password", "unable to authenticate", "all authentication methods failed",
        ]
        if authMarkers.contains(where: { desc.contains($0) }) { return .auth }
        return .transient
    }

    /// Coordinates the three install phases: upload → background launch → poll.
    static func install(host: ServerHost, password: String,
                        options: InstallOptions,
                        onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        let script = try loadScript()
        await MainActor.run { LogStore.shared.log(.provisioning,
            "✓ srv.sh \(script.count) bytes") }
        try await uploadScript(host: host, password: password, script: script, onStep: onStep)
        try await launchBackground(host: host, password: password, options: options, onStep: onStep)
        return try await pollUntilDone(host: host, password: password, onStep: onStep)
    }

    // boc #314: generalize the srv.sh-only loader so rotate-key.sh ships and
    // loads the same way (bundle resource, source-tree fallback for dev builds).
    // was: loadScript() with the "srv" resource name hardcoded inside.
    /// Phase 1 — loads srv.sh from app bundle, falling back to the source tree
    /// for simulator / development builds. Pure: no network, no async.
    private static func loadScript() throws -> String {
        try loadBundledScript(named: "srv")
    }

    /// Loads `<name>.sh` from the app bundle, falling back to the source tree
    /// for simulator / development builds. Pure: no network, no async.
    private static func loadBundledScript(named name: String) throws -> String {
        let url: URL? = Bundle.main.url(forResource: name, withExtension: "sh")
            ?? {
                let srcFile = URL(fileURLWithPath: #filePath)
                // #314: third delete added — #filePath is App/Core/SSHRunner.swift,
                // so two deletes landed on App/ and the dev-tree fallback never fired.
                let projectRoot = srcFile
                    .deletingLastPathComponent()  // App/Core/
                    .deletingLastPathComponent()  // App/
                    .deletingLastPathComponent()  // project root
                let candidate = projectRoot.appendingPathComponent("scripts/\(name).sh")
                return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            }()
        guard let url, let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ProvisionError.parseFailed(
                "\(name).sh not found — rebuild the app (xcodegen + clean build)")
        }
        return script
    }
    // eoc #314

    /// Phase 2 — uploads srv.sh to the VPS via base64-encoded printf.
    private static func uploadScript(host: ServerHost, password: String,
                                     script: String,
                                     onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.installStep1Upload.localized())
        let b64 = Data(script.utf8).base64EncodedString()
        try await _withConnection(host: host, password: password) { client in
            _ = try await execute(client: client, label: "upload srv.sh",
                command: "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.script)" +
                         " && chmod +x \(RemotePaths.script)")
        }
    }

    /// Phase 3 — fires srv.sh under nohup and returns immediately.
    /// The script writes stdout/stderr to RemotePaths.log and its exit code to
    /// RemotePaths.exit; pollUntilDone reads both to track progress.
    private static func launchBackground(host: ServerHost, password: String,
                                         options: InstallOptions,
                                         onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.installStep2Launch.localized())
        let env = installEnv(options)
        // #096: srv.sh accepts a `--no-cache` flag that purges the server's Go cache
        // before building; we run the script with no args, so the cache is always
        // reused and installs/rebuilds stay fast. A future "clean rebuild" option
        // (#109) would append --no-cache here. (Cache location is OLCRTC_CACHE_DIR —
        // see #093.)
        let cmd = "rm -f \(RemotePaths.log) \(RemotePaths.exit); " +
                  "nohup sh -c '\(env) \(RemotePaths.script); echo $? > \(RemotePaths.exit)' " +
                  "> \(RemotePaths.log) 2>&1 & echo LAUNCH_OK"
        try await _withConnection(host: host, password: password) { client in
            _ = try await execute(client: client, label: "launch srv.sh", command: cmd)
        }
    }

    /// Phase 4 — polls RemotePaths.log every 15 s until OLCRTC_URI= appears
    /// or the script exits. Each poll is a short SSH command (<1 s) so the
    /// NIO idle-channel timeout never fires.
    ///
    /// Connectivity-loss handling (invariants):
    ///   1. SSH errors are caught explicitly and classified:
    ///        - `.auth` → throw `.sshConnect` immediately (no point retrying).
    ///        - `.transient` → log, increment `consecutiveSSHErrors`, continue.
    ///      After `sshErrorAbortThreshold` (3) consecutive transient errors,
    ///      we abort with `.sshConnect` so the user learns about the drop
    ///      within ~45 s instead of waiting the full 25-minute timeout.
    ///   2. Every `probeIntervalPolls` (5) iterations we run a short TCP-22
    ///      probe via NetPing.tcp. After `probeFailureAbortThreshold` (2)
    ///      consecutive probe failures (~150 s of confirmed unreachability)
    ///      we abort with `.sshConnect(serverUnreachable_fmt)`.
    ///   3. Any successful SSH poll or successful probe resets BOTH counters.
    private static func pollUntilDone(host: ServerHost, password: String,
                                      onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        let client = CitadelSSHClient(host: host, password: password)
        return try await pollLoop(
            sshClient: client,
            host: host,
            onStep: onStep,
            maxPolls: installMaxPolls,
            pollInterval: installPollInterval,
            sleepFn: { secs in try await Task.sleep(for: .seconds(secs)) },
            probeFn: { h, port in await NetPing.tcp(host: h, port: UInt16(port), timeout: Self.probeTimeout).success }
        )
    }

    private static func installPhase(from line: String) -> String? {
        let l = line.lowercased()
        if l.contains("installing podman") || l.contains("apt install") { return L10n.installPhaseSystemDeps.localized() }
        if l.contains("cloning") || l.contains("git clone") { return L10n.installPhaseClone.localized() }
        if l.contains("pulling go image") || l.contains("podman pull") { return L10n.installPhasePullImage.localized() }
        if l.contains("go: downloading") || l.contains("go mod tidy") { return L10n.installPhaseDeps.localized() }
        if l.contains("building olcrtc") || l.contains("go build") { return L10n.installPhaseBuild.localized() }
        if l.contains("starting olcrtc") || l.contains("podman run -d") { return L10n.installPhaseStart.localized() }
        return nil
    }

    /// Core install poll loop, extracted for testability.
    ///
    /// All I/O is mediated through `sshClient` (inject `MockSSHClient` in
    /// tests, `CitadelSSHClient` in production). `sleepFn` and `probeFn`
    /// are also injectable so tests run instantly without real sleeps or
    /// network probes.
    ///
    /// `host` is kept as a parameter solely so the probe function has the
    /// host/port strings for log messages; it is NOT used to open connections
    /// — all SSH work goes through `sshClient.execute(command:)`.
    static func pollLoop(
        sshClient: any SSHClientProtocol,
        host: ServerHost,
        onStep: @Sendable @escaping (String) -> Void,
        maxPolls: Int = installMaxPolls,
        pollInterval: TimeInterval = installPollInterval,
        sleepFn:  @Sendable (TimeInterval) async throws -> Void = { secs in try await Task.sleep(for: .seconds(secs)) },
        probeFn:  @Sendable (String, Int)  async       -> Bool  = { h, port in await NetPing.tcp(host: h, port: UInt16(port)).success }
    ) async throws -> InstallResult {
        var consecutiveSSHErrors:    Int = 0
        var consecutiveProbeFailures: Int = 0

        // Byte offset into RemotePaths.log already fetched. Each poll asks the
        // server for `wc -c` of the file plus the slice starting at this
        // offset, so an install that emits ~30 lines doesn't re-transfer those
        // lines on every one of the (up to 100) polls. Without this we pulled
        // the last 32 KiB per poll = ~3.2 MiB per install, and each line was
        // re-persisted into LogStore via execute()'s line-by-line logger
        // (dozens of duplicates per line over the install).
        var currentPhase = L10n.installPhaseWaiting.localized()
        var logOffset: Int = 0
        // Set true once on parse failure of the wc -c probe so we don't spam
        // the log on every subsequent poll if the format is somehow off.
        var loggedParseFallback = false

        for poll in 1...maxPolls {
            try await sleepFn(pollInterval)

            // Periodic TCP-22 reachability probe — catches "VPS dropped off
            // the network" cases that the SSH-error sniffing alone misses.
            if poll % probeIntervalPolls == 0 {
                let probeSuccess = await probeFn(host.host, host.port)
                if probeSuccess {
                    consecutiveProbeFailures = 0
                } else {
                    consecutiveProbeFailures += 1
                    let failures = consecutiveProbeFailures
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "✗ TCP/\(host.port) probe failed (poll \(poll), \(failures)/\(Self.probeFailureAbortThreshold))")
                    }
                    if consecutiveProbeFailures >= probeFailureAbortThreshold {
                        let target = "\(host.host):\(host.port)"
                        let msg = L10n.serverUnreachable_fmt.formatted(target)
                        await MainActor.run {
                            LogStore.shared.log(.provisioning,
                                "✗ Aborting install: lost connectivity to \(target) mid-install")
                        }
                        throw ProvisionError.sshConnect(msg)
                    }
                }
            }

            let output: String
            do {
                // Stream only the bytes after logOffset. The leading `wc -c`
                // reports the current file size so we can advance the offset
                // for the next poll. `head -c 32768` caps a single response
                // even when a burst of output landed between polls.
                let offset = logOffset
                let pollCmd =
                    "wc -c < \(RemotePaths.log) 2>/dev/null; " +
                    "echo '---NEW---'; " +
                    "tail -c +\(offset + 1) \(RemotePaths.log) 2>/dev/null | head -c 32768; " +
                    "echo '---STATUS---'; " +
                    "[ -f \(RemotePaths.exit) ] && echo DONE || echo RUNNING"
                output = try await sshClient.execute(command: pollCmd)
                // Successful SSH round-trip — reset both connectivity counters.
                consecutiveSSHErrors    = 0
                consecutiveProbeFailures = 0
            } catch let error {
                let kind = classifySSHError(error)
                let desc = error.localizedDescription
                switch kind {
                case .auth:
                    // Unrecoverable — credentials changed or sshd rejected us.
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "✗ SSH auth failure during poll \(poll): \(desc)")
                    }
                    throw ProvisionError.sshConnect(desc)
                case .transient:
                    consecutiveSSHErrors += 1
                    let errors = consecutiveSSHErrors
                    await MainActor.run {
                        LogStore.shared.log(.provisioning,
                            "⚠ SSH error during poll \(poll) (\(errors)/\(Self.sshErrorAbortThreshold)): \(desc)")
                    }
                    if consecutiveSSHErrors >= sshErrorAbortThreshold {
                        await MainActor.run {
                            LogStore.shared.log(.provisioning,
                                "✗ Aborting install: \(sshErrorAbortThreshold) consecutive SSH errors")
                        }
                        throw ProvisionError.sshConnect(desc)
                    }
                    onStep(L10n.installStep3PollRetry_fmt.formatted(poll))
                    continue
                }
            }

            guard !output.isEmpty else {
                onStep(L10n.installStep3PollRetry_fmt.formatted(poll)); continue
            }

            let parsed = parsePollPayload(output)
            let logTail = parsed.body
            let isDone  = parsed.isDone

            // Advance the offset for the next poll. If wc -c failed to parse
            // (newSize == nil), log the fallback once and don't advance the
            // offset — the next poll will receive the full tail-c-style body
            // because we asked for "tail -c +1" which is "everything from
            // byte 1" = the entire file. Functionally identical to the
            // pre-change behavior, just on the rare degenerate path.
            if let newSize = parsed.newSize {
                // Defensive: if the file shrank (rotated, server rebooted,
                // temp file wiped) we still trust the server's reported size
                // and just reset to it. `tail -c +(N+1)` against a file
                // shorter than N silently produces empty output, which is
                // harmless — we just won't re-see lines that vanished.
                // `max(0,…)` defends against an unexpected negative (wc -c
                // never returns negative, but Int(parsedString) on a stray
                // "-1" or similar would round-trip; cheap to defend).
                logOffset = max(0, newSize)
            } else if !loggedParseFallback {
                loggedParseFallback = true
                await MainActor.run {
                    LogStore.shared.log(.provisioning,
                        "⚠ poll wc -c parse failed; falling back to full-tail mode for the rest of the install")
                }
            }

            if let lastLine = logTail.split(separator: "\n")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                for line in logTail.split(separator: "\n") {
                    if let phase = installPhase(from: String(line)) {
                        currentPhase = phase
                    }
                }
                onStep("[3/3] \(currentPhase)\n\(String(lastLine.prefix(60)))")
            }

            // The new-tail-only stream usually won't contain OLCRTC_URI lines
            // (they're emitted near the end of srv.sh once) so this is mostly
            // a fast-path for the very poll in which they appear. The
            // post-`isDone` full-log read below is the real safety net.
            if let result = parseInstallResult(from: logTail) { return result }

            // Script exited without emitting URI in the tail — read the full log.
            if isDone {
                // Re-use the same sshClient for the full-log read so tests can
                // supply a second canned response for the "cat" command.
                let fullLog = (try? await sshClient.execute(
                    command: "cat \(RemotePaths.log) 2>/dev/null")) ?? logTail
                if let result = parseInstallResult(from: fullLog) { return result }
                let tail20 = fullLog.split(separator: "\n").suffix(20).joined(separator: "\n")
                throw ProvisionError.parseFailed(L10n.installFailedNoURI_fmt.formatted(tail20))
            }
        }
        throw ProvisionError.parseFailed(L10n.installTimeout25min.localized())
    }

    /// Pure helper exposed for tests. Splits the `poll N` SSH response into
    /// its three parts:
    ///   `<wc-c-line>\n---NEW---\n<new-tail-body>\n---STATUS---\n<DONE|RUNNING>`
    ///
    /// Returns:
    ///   - `newSize`: parsed `wc -c` byte count, or `nil` if the line was
    ///     empty / non-numeric (e.g. log file not yet created on first poll,
    ///     or some `wc` quirk on a non-GNU coreutils install).
    ///   - `body`: the new-tail slice (everything between `---NEW---\n` and
    ///     `\n---STATUS---\n`). If markers are missing — e.g. older server
    ///     produced a different shape — we fall back to "everything before
    ///     `---STATUS---`" so the parser still finds OLCRTC_URI=… lines.
    ///   - `isDone`: trailing token is exactly "DONE" (trimmed).
    static func parsePollPayload(_ output: String) -> (newSize: Int?, body: String, isDone: Bool) {
        // Status marker first — used to split the trailing DONE/RUNNING off.
        let statusParts = output.components(separatedBy: "\n---STATUS---\n")
        let beforeStatus = statusParts.first ?? ""
        let isDone = (statusParts.count > 1
                        ? statusParts.last ?? ""
                        : "").trimmingCharacters(in: .whitespacesAndNewlines) == "DONE"

        // Split out the wc -c header from the body via the ---NEW--- marker.
        // Use the first occurrence so a literal "---NEW---" inside the log
        // body (extremely unlikely but cheap to be defensive about) doesn't
        // shift the split.
        if let range = beforeStatus.range(of: "\n---NEW---\n") {
            let header = String(beforeStatus[..<range.lowerBound])
            let body   = String(beforeStatus[range.upperBound...])
            let trimmedHeader = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSize = Int(trimmedHeader)
            return (newSize, body, isDone)
        }
        // Marker missing entirely — treat the whole pre-status chunk as body,
        // size unknown. Backward-compatible with the pre-change command shape.
        return (nil, beforeStatus, isDone)
    }

    /// Extracts OLCRTC_URI + OLCRTC_CONTAINER from script output.
    /// Returns nil when either key is absent (install still in progress).
    static func parseInstallResult(from output: String) -> InstallResult? {
        // Single-pass extract — walks the log once for both keys instead of
        // twice. Bounded log (final URI + container live within the last few
        // KiB), so the win is microseconds; we do it because each poll's
        // full-log fallback (the `isDone` branch) can be much larger than the
        // incremental tail. Keep parseInstallResult cheap so the fallback
        // path can run unconditionally.
        let values = extract(keys: ["OLCRTC_URI", "OLCRTC_CONTAINER"], from: output)
        guard let uri       = values["OLCRTC_URI"],
              let container = values["OLCRTC_CONTAINER"]
        else { return nil }
        return InstallResult(uri: uri, containerName: container)
    }

    /// Builds the env var prefix for the non-interactive script invocation.
    /// Variable names must match the boc olcrtc-ios patches in scripts/srv.sh.
    static func installEnv(_ options: InstallOptions) -> String {
        var vars: [String] = [
            "OLCRTC_CARRIER=\(shellSafe(options.carrier))",
            "OLCRTC_TRANSPORT=\(shellSafe(options.transport))",
            // No client-id: upstream dropped it from the URI scheme and srv.sh
            // (the YAML config has no client-id field). ConnectionRecord.clientID
            // defaults to "default" when the parsed URI omits the %clientID part.
            "OLCRTC_DNS=\(shellSafe(SettingsStore.shared.dnsServer))",
            // Marker for iOS-app installs. Survives into the URI as
            // `$auto-provisioned` (the mimo / sub-config-name field) and
            // surfaces in ConnectionRecord, which lets us spot iOS-installed
            // VPSes vs ones provisioned manually via curl|sh. The server-side
            // default in scripts/srv.sh matches this literal, but we set it
            // explicitly so the marker is unconditional — even if a future
            // server-script revision drops the default we still produce the
            // marker. If you rename, update both sides together.
            // cross-ref: scripts/srv.sh, the `sub_configname=` boc block.
            "OLCRTC_CONFIG_NAME=auto-provisioned",
        ]
        if !options.roomID.isEmpty {
            vars.append("OLCRTC_ROOM_ID=\(shellSafe(options.roomID))")
        }
        if options.carrier == "jitsi" {
            // Base Jitsi server (#256): user-chosen in the install sheet, pre-filled
            // from AppConstants.defaultJitsiBaseURL and guaranteed non-empty there.
            // srv.sh prefixes a short room name with this, or uses it for the
            // auto-generated room; a full http(s) URL in OLCRTC_ROOM_ID is used
            // verbatim and this base is ignored.
            vars.append("OLCRTC_JITSI_URL=\(shellSafe(options.jitsiBaseURL))")
        }
        if options.transport == "vp8channel" {
            vars.append("OLCRTC_VP8_FPS=\(SettingsStore.shared.vp8FPS)")
            vars.append("OLCRTC_VP8_BATCH=\(SettingsStore.shared.vp8BatchSize)")
        }
        if options.transport == "seichannel" {
            vars.append("OLCRTC_SEI_FPS=\(options.seiFPS)")
            vars.append("OLCRTC_SEI_BATCH=\(options.seiBatch)")
            vars.append("OLCRTC_SEI_FRAG=\(options.seiFrag)")
            vars.append("OLCRTC_SEI_ACK=\(options.seiACK)")
        }
        // NOTE: videochannel uses OLCRTC_VIDEO_{W,H,FPS,BITRATE,HW,CODEC,
        // QR_RECOVERY,QR_SIZE,TILE_MODULE,TILE_RS} per scripts/srv.sh.
        // #097 was: "Server defaults apply — not yet exposed in the UI."
        // #097 decision: deliberately never exposed — ten niche knobs for a
        // works-but-slow transport aren't worth the UI sprawl; the install
        // sheet's videochannel footer tells the user server defaults apply.
        //
        // #093: OLCRTC_CACHE_DIR is another server-side knob (scripts/srv.sh:
        // CACHE_DIR="${OLCRTC_CACHE_DIR:-$HOME/.cache/olcrtc}") that relocates the Go
        // module/build cache. We deliberately don't set it — the default
        // $HOME/.cache/olcrtc persists across VPS reboots and is correct for the
        // single-purpose VPSes we provision. Surface it in Settings only if a custom
        // cache location is ever needed. (Cache *purging* is --no-cache — see #096.)
        return vars.joined(separator: " ")
    }

    /// Strips shell metacharacters and whitespace from values embedded as
    /// `KEY=VALUE` env vars in the launch command.
    ///
    /// Whitespace is critical: env var assignments are space-separated, so a
    /// value containing a space would split into a new positional argument and
    /// the rest of the value would be interpreted as a command. Telemost room
    /// IDs in particular often arrive copy-pasted in display form with spaces
    /// like "3528 5410 1234" — we strip those down to "352854101234".
    static func shellSafe(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            // > 0x20 (not >= 0x20) drops space + all control chars.
            ($0.value > 0x20 && $0.value < 0x7F) &&
            $0 != "\"" && $0 != "\\" && $0 != "`" && $0 != "$" && $0 != "'" &&
            $0 != ";"  && $0 != "&"  && $0 != "|" && $0 != "<" && $0 != ">" &&
            $0 != "("  && $0 != ")"
        })
    }

    // ── old Phase-based install removed ──
    // The multi-phase approach (apt / clone / build / run) is now handled
    // entirely by scripts/srv.sh. See that file and scripts/parity_check.py
    // for how we stay in sync with upstream olcrtc-upstream/script/srv.sh.


    static func uninstall(host: ServerHost, password: String, containerName: String?,
                           onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningUninstalling.localized())
        try await _withConnection(host: host, password: password) { client in
            _ = try await execute(client: client, label: "uninstall",
                                  command: uninstallScript(containerName: containerName))
        }
    }

    // MARK: Update script

    /// Shell script that git-pulls and rebuilds the binary inside a running
    /// olcrtc container, then restarts it — without re-running apt-get.
    ///
    /// Strategy: find the container by name (or the first olcrtc-server-*
    /// container when no name is recorded), exec `git pull` + `go build` inside
    /// it, then restart the container so the new binary is picked up.
    static func updateScript(containerName: String?) -> String {
        let target = containerName ?? containerNamePrefix
        return #"""
        set -e
        if podman ps -a --format '{{.Names}}' | grep -q '^\#(target)$' 2>/dev/null; then
            CNAME="\#(target)"
        else
            CNAME=$(podman ps -aq --filter 'name=\#(containerNamePrefix)' --format '{{.Names}}' | head -1)
        fi
        if [ -z "$CNAME" ]; then
            echo "ERROR: no olcrtc container found" >&2; exit 1
        fi
        echo "UPDATE: container=$CNAME"
        podman exec "$CNAME" sh -c 'cd /app && git pull --ff-only'
        # #227 was: go build -o /usr/local/bin/olcrtc .  — wrong on both counts: the container
        # runs /app/olcrtc (workdir /app, START_CMD ./olcrtc) and the entrypoint moved to the
        # multi-file ./cmd/olcrtc package, so `.` no longer builds. Match scripts/srv.sh exactly
        # so `podman restart` actually picks up the rebuilt binary.
        podman exec "$CNAME" sh -c "cd /app && go build -trimpath -ldflags='-s -w' -o olcrtc ./cmd/olcrtc"
        podman restart "$CNAME"
        echo "OLCRTC_UPDATED=ok"
        """#
    }

    static func update(host: ServerHost, password: String, containerName: String?,
                       onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningUpdating.localized())
        try await _withConnection(host: host, password: password) { client in
            _ = try await execute(client: client, label: "update",
                                  command: updateScript(containerName: containerName))
        }
    }

    // MARK: Scan for existing olcrtc containers

    /// Lists all olcrtc-server-* containers (running or stopped) and their args.
    /// Output per line: <name>\t<status>\t<cmd>
    static func scanContainersScript() -> String {
        """
        podman ps -a --filter 'name=olcrtc-server-' \
            --format '{{.Names}}\t{{.Status}}\t{{join .Command " "}}' 2>/dev/null || true
        """
    }

    struct VPSStats: Sendable {
        let disk: String    // e.g. "14G/20G"
        let ram: String     // e.g. "241M/2048M"
        let uptime: String  // e.g. "3 days, 4:22"
    }

    struct FoundContainer: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let status: ContainerStatus
        let carrier: String
        let transport: String
        let roomID: String
    }

    static func parseScannedContainers(from output: String) -> [FoundContainer] {
        output.components(separatedBy: "\n")
            .compactMap { line -> FoundContainer? in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("olcrtc-server-") else { return nil }
                let statusStr = parts[1].trimmingCharacters(in: .whitespaces)
                let cmd = parts.count >= 3 ? parts[2] : ""
                let status = ContainerStatus.parse(from: statusStr)
                // Extract args from cmd: olcrtc -mode srv -carrier X -id Y -transport Z ...
                func arg(_ flag: String) -> String {
                    let pattern = " \(flag) "
                    guard let r = cmd.range(of: pattern) else { return "" }
                    let after = String(cmd[r.upperBound...])
                    return String(after.prefix(while: { !$0.isWhitespace }))
                }
                return FoundContainer(
                    name: name, status: status,
                    carrier:   arg("-carrier"),
                    transport: arg("-transport"),
                    roomID:    arg("-id")
                )
            }
    }

    static func startScript(containerName: String) -> String {
        let safe = shellSafe(containerName)
        // Recreate the bind-mount source dir if it was wiped (e.g. /tmp cleared on VPS reboot).
        // Uses `podman inspect` to find the actual host path rather than hard-coding /tmp.
        // Exit 1 on failure so _execute throws and the UI shows an error instead of "Done".
        return """
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "\(safe)" 2>/dev/null)
        [ -n "$DEPLOY_DIR" ] && mkdir -p "$DEPLOY_DIR"
        if podman start "\(safe)" 2>&1; then
            echo OLCRTC_STARTED=ok
        else
            echo OLCRTC_STARTED=error
            exit 1
        fi
        """
    }

    static func start(host: ServerHost, password: String, containerName: String,
                      onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningStarting.localized())
        try await _withConnection(host: host, password: password) { client in
            _ = try await _execute(client: client, label: "start", command: startScript(containerName: containerName))
        }
    }

    static func stopScript(containerName: String) -> String {
        let safe = shellSafe(containerName)
        // Exit 1 on failure so _execute throws and the UI shows an error.
        return """
        if podman stop "\(safe)" 2>&1; then
            echo OLCRTC_STOPPED=ok
        else
            echo OLCRTC_STOPPED=error
            exit 1
        fi
        """
    }

    static func stop(host: ServerHost, password: String, containerName: String,
                     onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningStopping.localized())
        try await _withConnection(host: host, password: password) { client in
            _ = try await _execute(client: client, label: "stop", command: stopScript(containerName: containerName))
        }
    }

    /// Single-call readiness probe. Output format (one per line):
    ///   PODMAN=yes|no
    ///   IMAGE=yes|no
    ///   CONTAINER=<podman ps status line or empty>
    static func readinessScript(containerName: String?) -> String {
        let containerCmd: String
        if let name = containerName {
            let safe = shellSafe(name)
            containerCmd = "podman ps -a --filter 'name=^\(safe)$' --format '{{.Status}}' 2>/dev/null | head -1"
        } else {
            containerCmd = "echo ''"
        }
        return """
        command -v podman >/dev/null 2>&1 && echo 'PODMAN=yes' || echo 'PODMAN=no'
        podman image exists docker.io/library/golang:1.26-alpine3.22 2>/dev/null && echo 'IMAGE=yes' || echo 'IMAGE=no'
        printf 'CONTAINER='
        \(containerCmd)
        df -h / 2>/dev/null | awk 'NR==2{printf "DISK=%s/%s\\n",$3,$2}'
        free -m 2>/dev/null | awk 'NR==2{printf "RAM=%sM/%sM\\n",$3,$2}'
        uptime 2>/dev/null | sed 's/.*up *//;s/,.*load.*//' | awk '{printf "UPTIME=%s\\n",$0}'
        """
    }

    static func parseReadiness(from output: String,
                                containerName: String?) -> VPSReadinessState {
        var podman = false
        var image  = false
        var containerStatus = ""
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "PODMAN=yes" { podman = true }
            if t == "IMAGE=yes"  { image  = true }
            if t.hasPrefix("CONTAINER=") {
                containerStatus = String(t.dropFirst("CONTAINER=".count))
            }
        }
        guard podman else { return .noPodman }
        guard image  else { return .noImage }
        if containerName == nil || containerStatus.isEmpty { return .imageReady }
        if containerStatus.hasPrefix("Up") { return .containerRunning(containerStatus) }
        // Normalize raw podman status strings for display.
        // "Initialized" = container created but never started; show nothing extra.
        // "Exited (0) …" = clean stop; show approximate time if available.
        // "Exited (N) …" = crashed; flag it.
        let displayLabel: String
        if containerStatus == "Initialized" || containerStatus.isEmpty {
            displayLabel = ""
        } else if containerStatus.hasPrefix("Exited (0)") {
            let tail = containerStatus.dropFirst("Exited (0) ".count)
            displayLabel = tail.isEmpty ? "stopped" : "stopped \(tail)"
        } else if containerStatus.hasPrefix("Exited") {
            displayLabel = "exited with error — check container logs"
        } else {
            displayLabel = containerStatus
        }
        return .containerStopped(displayLabel)
    }

    static func parseVPSStats(from output: String) -> VPSStats? {
        var disk = ""; var ram = ""; var uptime = ""
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("DISK=")   { disk   = String(t.dropFirst(5)) }
            if t.hasPrefix("RAM=")    { ram    = String(t.dropFirst(4)) }
            if t.hasPrefix("UPTIME=") { uptime = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        }
        guard !disk.isEmpty || !ram.isEmpty || !uptime.isEmpty else { return nil }
        return VPSStats(disk: disk, ram: ram, uptime: uptime)
    }

    static func containerStatus(host: ServerHost, password: String,
                                 containerName: String,
                                 onStep: @Sendable @escaping (String) -> Void) async throws -> ContainerStatus {
        onStep("podman ps…")
        // `-a` so stopped containers also surface; `^…$` anchors the name filter so a
        // partial match (olcrtc-server-abc vs olcrtc-server-abc-2) can't fool us.
        let raw = try await _withConnection(host: host, password: password) { client in
            try await execute(client: client, label: "container status",
                              command: "podman ps -a --filter 'name=^\(containerName)$' --format '{{.Status}}'")
        }
        return ContainerStatus.parse(from: raw)
    }

    static func containerLogs(host: ServerHost, password: String,
                               containerName: String, tail: Int,
                               onStep: @Sendable @escaping (String) -> Void) async throws -> String {
        onStep("podman logs --tail \(tail)…")
        // Container name comes from our own install script so single-quoting is safe.
        // #331: `logBody: false` — this output IS the container's own log, so the
        // caller (Provisioner.containerLogs) routes it to the per-server Container
        // tab; provisioning keeps just the pointer line instead of duplicating it.
        return try await _withConnection(host: host, password: password) { client in
            try await _execute(client: client, label: "container logs",
                               command: "podman logs --tail \(tail) '\(containerName)'",
                               logBody: false)
        }
    }

    static func reboot(host: ServerHost, password: String,
                        onStep: @Sendable @escaping (String) -> Void) async throws {
        onStep(L10n.provisioningRebooting.localized())
        // sshd dies as soon as reboot runs — any error from execute is expected and ignored.
        try await _withConnection(host: host, password: password) { client in
            _ = try? await execute(client: client, label: "reboot",
                                   command: "nohup sudo reboot >/dev/null 2>&1 &\nexit 0")
        }
    }

    // MARK: SSH primitives

    /// Runs `body` with an SSH connection and guarantees the connection is closed
    /// whether the body succeeds or throws — replaces the repeated
    /// `try? await client.close()` pattern that existed in every SSHRunner function.
    ///
    /// Named with a `_` prefix to signal it is implementation-internal; exposed
    /// as `internal` (not `private`) so `CitadelSSHClient` in the same module
    /// can bridge the `SSHClientProtocol` abstraction to real Citadel transport.
    @discardableResult
    static func _withConnection<T>(
        host: ServerHost, password: String,
        _ body: (SSHClient) async throws -> T
    ) async throws -> T {
        let client = try await connect(host: host, password: password)
        do {
            let result = try await body(client)
            try? await client.close()
            return result
        } catch {
            try? await client.close()
            throw error
        }
    }

    // Retries once after 4 s — handles transient TCP hiccups without the full
    // 30 s wait twice. If both attempts fail, surfaces the host+port so the
    // user knows exactly what couldn't be reached.
    private static func connect(host: ServerHost, password: String) async throws -> SSHClient {
        for attempt in 1...2 {
            do {
                let client = try await SSHClient.connect(
                    host: host.host,
                    port: host.port,
                    authenticationMethod: .passwordBased(username: host.username, password: password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                await MainActor.run { LogStore.shared.log(.provisioning, "✓ SSH connected \(host.host):\(host.port)") }
                return client
            } catch {
                let desc = "\(error)"
                await MainActor.run {
                    LogStore.shared.log(.provisioning,
                        L10n.sshAttemptFailed_fmt.formatted(attempt, desc))
                }
                if attempt < 2 {
                    await MainActor.run {
                        LogStore.shared.log(.provisioning, L10n.sshRetryIn4s.localized())
                    }
                    try await Task.sleep(for: .seconds(Self.sshRetryDelay))
                } else {
                    let isTimeout = desc.lowercased().contains("timeout")
                    let hint = isTimeout
                        ? L10n.sshPortNotResponding_fmt.formatted(host.port, host.host)
                        : desc
                    throw ProvisionError.sshConnect(hint)
                }
            }
        }
        preconditionFailure("unreachable: connect() loop must always return")
    }

    /// Executes one shell command. stderr is merged into stdout so the user
    /// sees error detail (apt errors, podman errors etc.) in the log instead
    /// of just a bare "exit code 1" from Citadel.
    ///
    /// Named with a `_` prefix to signal it is implementation-internal; exposed
    /// as `internal` so `CitadelSSHClient` can call it from the same module.
    @discardableResult
    static func _execute(client: SSHClient,
                          label: String,
                          command: String,
                          // #331: classify the body by ORIGIN. Orchestration
                          // commands (the default) dump their output into the
                          // .provisioning stream as before. A command whose
                          // output is *container-produced* (e.g. `podman logs`)
                          // passes `logBody: false`: the caller routes that body
                          // to the per-server container log (logContainer, #295),
                          // and provisioning records only a single pointer line
                          // so the orchestration narrative stays followable
                          // without repeating the container output in two tabs.
                          logBody: Bool = true) async throws -> String {
        // Wrap in a brace group so the redirect applies to everything.
        // Trim long previews in the input log entry so we don't dump
        // 50 lines of shell into the buffer.
        let preview = command
            .replacingOccurrences(of: "\n", with: " | ")
            .prefix(120)
        await MainActor.run {
            LogStore.shared.log(.provisioning, "→ exec: \(label)")
            LogStore.shared.log(.provisioning, "    $ \(preview)\(command.count > 120 ? "…" : "")")
        }

        let wrapped = "{ \(command); } 2>&1"

        do {
            let buffer = try await client.executeCommand(wrapped)
            let bytes  = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            let output = String(decoding: bytes, as: UTF8.self)
            await MainActor.run {
                LogStore.shared.log(.provisioning, "← \(output.count) bytes:")
                if logBody {
                    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                        LogStore.shared.log(.provisioning, "    \(line)")
                    }
                } else {
                    // #331: hand-off pointer — the body lives in the Container tab.
                    LogStore.shared.log(.provisioning, "    → container output → Container tab")
                }
            }
            return output
        } catch {
            // Citadel's command-failed errors usually include the exit code
            // and sometimes captured stderr. Log the raw error to surface that
            // detail, plus the command label so the user knows which step.
            let detail = "\(error)"
            await MainActor.run {
                LogStore.shared.log(.provisioning, "✗ exec failed: \(label)")
                LogStore.shared.log(.provisioning, "    error: \(detail)")
            }
            throw ProvisionError.sshCommand("\(label) — \(error.localizedDescription)")
        }
    }

    private static func execute(client: SSHClient,
                                 label: String,
                                 command: String) async throws -> String {
        try await _execute(client: client, label: label, command: command)
    }

    /// Pulls VALUE from a line shaped like `KEY=VALUE` in the script output.
    static func extract(key: String, from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key)=") {
                return String(trimmed.dropFirst(key.count + 1))
            }
        }
        return nil
    }

    /// Single-pass multi-key extract. Walks `output` once and returns a
    /// `[key: value]` dict for every requested key that was found. Keys
    /// missing from the output are simply absent from the returned dict.
    ///
    /// If a key appears more than once the first occurrence wins, matching
    /// `extract(key:from:)` semantics (which also takes the first match).
    /// That choice matters for `OLCRTC_URI`: the server emits the line once,
    /// but if a future patch ever logged it twice (e.g. for retry diagnostics),
    /// we still resolve the first value the install produced.
    static func extract(keys: [String], from output: String) -> [String: String] {
        var remaining = Set(keys)
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            if remaining.isEmpty { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for key in remaining {
                if trimmed.hasPrefix("\(key)=") {
                    result[key] = String(trimmed.dropFirst(key.count + 1))
                    remaining.remove(key)
                    break
                }
            }
        }
        return result
    }

    // MARK: Reconfigure script

    /// Shell script that rewrites the running container's `server.yaml`
    /// in-place (provider / room id / transport) and restarts the container so
    /// the new config is picked up. Everything else in the file — encryption
    /// key, DNS, SOCKS, transport-specific blocks — is preserved verbatim.
    ///
    /// Strategy:
    ///   1. `podman inspect` → find the bind-mount source dir on the host; that
    ///      is where `srv.sh` wrote `server.yaml` (mounted at /app).
    ///   2. `sed -i` the three mutable YAML fields in `server.yaml`.
    ///   3. `podman restart` — the container CMD is unchanged
    ///      (`sh -c "./olcrtc server.yaml"`), so a restart just re-reads the
    ///      edited file.
    ///
    /// Why `podman restart` (vs the old remove/recreate)? The process arguments
    /// no longer change — only the mounted YAML does — so a restart suffices and
    /// keeps the container, its name, and its writable layer (e.g. the
    /// apk-installed ffmpeg for videochannel) intact.
    ///
    /// Why not re-run srv.sh? That would run apt-get + git clone + go build —
    /// the whole 10–20 min install — just to change three fields.
    static func reconfigureScript(containerName: String, env: [String]) -> String {
        // env is ["OLCRTC_CARRIER=jitsi","OLCRTC_TRANSPORT=vp8channel","OLCRTC_ROOM_ID=…"]
        func envVal(_ key: String) -> String {
            (env.first(where: { $0.hasPrefix("\(key)=") }).map { String($0.dropFirst(key.count + 1)) }) ?? ""
        }
        let safeCarrier   = shellSafe(envVal("OLCRTC_CARRIER"))
        let safeTransport = shellSafe(envVal("OLCRTC_TRANSPORT"))
        let safeRoomID    = shellSafe(envVal("OLCRTC_ROOM_ID"))
        let safeCname     = shellSafe(containerName)
        // sed delimiter is `|`; shellSafe strips `|`, `&`, and `\` from the
        // values, so neither the delimiter nor sed replacement metachars can
        // appear in them. srv.sh indents these YAML keys exactly 2 spaces and
        // each appears once (provider→auth, id→room, transport→net), so the
        // anchored `^  key:` patterns are unambiguous.
        return #"""
        set -e
        CNAME="\#(safeCname)"
        if ! podman ps -a --format '{{.Names}}' | grep -q "^${CNAME}$" 2>/dev/null; then
            echo "ERROR: container ${CNAME} not found" >&2; exit 1
        fi
        echo "RECONFIGURE: locating server.yaml for ${CNAME}…"
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}")
        CONFIG="${DEPLOY_DIR}/server.yaml"
        if [ -z "$DEPLOY_DIR" ] || [ ! -f "$CONFIG" ]; then
            echo "ERROR: server.yaml not found for ${CNAME} (deploy dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        echo "RECONFIGURE: updating ${CONFIG}…"
        sed -i \
            -e 's|^  provider: .*|  provider: "\#(safeCarrier)"|' \
            -e 's|^  id: .*|  id: "\#(safeRoomID)"|' \
            -e 's|^  transport: .*|  transport: "\#(safeTransport)"|' \
            "$CONFIG"
        echo "RECONFIGURE: restarting ${CNAME} with carrier=\#(safeCarrier) transport=\#(safeTransport) id=\#(safeRoomID)…"
        podman restart "${CNAME}"
        KEY=$(cat ~/.olcrtc_key 2>/dev/null || echo "")
        echo "OLCRTC_URI=olcrtc://\#(safeCarrier)?\#(safeTransport)@\#(safeRoomID)#${KEY}"
        echo "OLCRTC_RECONFIGURED=ok"
        """#
    }

    /// Returns the new `olcrtc://` URI emitted by the reconfigure script,
    /// or nil if the script did not emit one (older server without ~/.olcrtc_key).
    @discardableResult
    static func reconfigure(host: ServerHost, password: String,
                             containerName: String, env: [String],
                             onStep: @Sendable @escaping (String) -> Void) async throws -> String? {
        onStep(L10n.provisioningReconfiguring.localized())
        let output = try await _withConnection(host: host, password: password) { client in
            try await execute(client: client, label: "reconfigure",
                              command: reconfigureScript(containerName: containerName, env: env))
        }
        return extract(key: "OLCRTC_URI", from: output)
    }

    // MARK: #303 — Recover config script
    //
    // Reads the deployed `server.yaml` (written by srv.sh, see scripts/srv.sh
    // "Generate YAML config") and `~/.olcrtc_key` for an existing container,
    // dumping both verbatim between sentinel markers so `parseRecoveredConfig`
    // can rebuild an `olcrtc://` URI without any server-side mutation.
    //
    // Strategy mirrors `reconfigureScript`: `podman inspect` finds the bind-mount
    // source dir (where srv.sh wrote server.yaml), then `cat` the file and the
    // key file. No restart, no edits — read-only.
    static func recoverConfigScript(containerName: String) -> String {
        let safeCname = shellSafe(containerName)
        return #"""
        set -e
        CNAME="\#(safeCname)"
        if ! podman ps -a --format '{{.Names}}' | grep -q "^${CNAME}$" 2>/dev/null; then
            echo "ERROR: container ${CNAME} not found" >&2; exit 1
        fi
        DEPLOY_DIR=$(podman inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{break}}{{end}}{{end}}' "${CNAME}")
        CONFIG="${DEPLOY_DIR}/server.yaml"
        if [ -z "$DEPLOY_DIR" ] || [ ! -f "$CONFIG" ]; then
            echo "ERROR: server.yaml not found for ${CNAME} (deploy dir: ${DEPLOY_DIR:-unknown})" >&2; exit 1
        fi
        echo "OLCRTC_RECOVER_YAML_BEGIN"
        # #314: tolerate an unreadable file (was: bare `cat "$CONFIG"`) — the
        # sentinels then bracket an empty body, parseRecoveredConfig throws a
        # typed RecoverConfigError, and the UI can offer the "generate new
        # key" fallback instead of surfacing an opaque SSH exit-1 error.
        cat "$CONFIG" 2>/dev/null || true
        echo "OLCRTC_RECOVER_YAML_END"
        echo "OLCRTC_RECOVER_KEY=$(cat ~/.olcrtc_key 2>/dev/null | tr -d '[:space:]' || echo "")"
        """#
    }

    /// Recovered server-side config, parsed from `recoverConfigScript` output.
    /// Mirrors the subset of `server.yaml` (scripts/srv.sh "Generate YAML config")
    /// needed to rebuild an `olcrtc://` URI.
    struct RecoveredConfig: Equatable, Sendable {
        var carrier  : String
        var transport: String
        var roomID   : String
        var key      : String
        var vp8FPS      : Int?
        var vp8BatchSize: Int?
        // #303: seichannel tuning — only populated when transport == "seichannel".
        // nil means "use OlcrtcConnection's defaults" (matches vp8FPS/vp8BatchSize
        // convention above).
        var seiFPS  : Int?
        var seiBatch: Int?
        var seiFrag : Int?
        var seiACK  : Int?
    }

    enum RecoverConfigError: LocalizedError {
        case missingYAML
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .missingYAML:          return L10n.recoverErrorMissingYAML.localized()
            case .missingField(let f):  return L10n.recoverErrorMissingField_fmt.formatted(f)
            }
        }
    }

    /// Parses the `OLCRTC_RECOVER_*` block emitted by `recoverConfigScript` into
    /// a `RecoveredConfig`. The YAML between the BEGIN/END sentinels is the exact
    /// `server.yaml` written by srv.sh (see scripts/srv.sh "Generate YAML config"):
    /// a flat, 2-space-indented structure — no lists, no multi-line scalars — so a
    /// line-based `key: "value"` scan is sufficient and avoids a YAML dependency.
    static func parseRecoveredConfig(from output: String) throws -> RecoveredConfig {
        guard let beginIdx = output.range(of: "OLCRTC_RECOVER_YAML_BEGIN"),
              let endIdx   = output.range(of: "OLCRTC_RECOVER_YAML_END"),
              endIdx.lowerBound > beginIdx.upperBound else {
            throw RecoverConfigError.missingYAML
        }
        let yaml = String(output[beginIdx.upperBound..<endIdx.lowerBound])

        // Strip surrounding quotes (server.yaml quotes all string scalars).
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }

        // Single-pass line scan. server.yaml keys are unique within their section
        // and srv.sh never repeats a top-level key, so "last value wins" and
        // "first value wins" are equivalent here — last is simplest.
        var values: [String: String] = [:]
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let val = unquote(String(trimmed[trimmed.index(after: colonIdx)...]))
            values[key] = val
        }

        guard let carrier = values["provider"], !carrier.isEmpty else {
            throw RecoverConfigError.missingField("auth.provider")
        }
        guard let roomID = values["id"], !roomID.isEmpty else {
            throw RecoverConfigError.missingField("room.id")
        }
        guard let transport = values["transport"], !transport.isEmpty else {
            throw RecoverConfigError.missingField("net.transport")
        }
        let recoveredKey = extract(key: "OLCRTC_RECOVER_KEY", from: output) ?? ""
        let key = recoveredKey.isEmpty ? (values["key"] ?? "") : recoveredKey
        guard !key.isEmpty else {
            throw RecoverConfigError.missingField("crypto.key")
        }

        var vp8FPS: Int?
        var vp8BatchSize: Int?
        if transport == "vp8channel" {
            vp8FPS       = values["fps"].flatMap(Int.init)
            vp8BatchSize = values["batch_size"].flatMap(Int.init)
        }

        // #303: seichannel tuning (scripts/srv.sh "sei:" block) — same flat
        // scan as vp8 above; the gate on transport keeps this from picking up
        // unrelated "fps"/"batch_size" keys from a different transport block.
        var seiFPS  : Int?
        var seiBatch: Int?
        var seiFrag : Int?
        var seiACK  : Int?
        if transport == "seichannel" {
            seiFPS   = values["fps"].flatMap(Int.init)
            seiBatch = values["batch_size"].flatMap(Int.init)
            seiFrag  = values["fragment_size"].flatMap(Int.init)
            seiACK   = values["ack_timeout_ms"].flatMap(Int.init)
        }

        return RecoveredConfig(carrier: carrier, transport: transport, roomID: roomID, key: key,
                               vp8FPS: vp8FPS, vp8BatchSize: vp8BatchSize,
                               seiFPS: seiFPS, seiBatch: seiBatch, seiFrag: seiFrag, seiACK: seiACK)
    }

    /// Reads the deployed `server.yaml` + `~/.olcrtc_key` for `containerName` and
    /// returns the parsed config — read-only, no server mutation.
    static func recoverConfig(host: ServerHost, password: String,
                               containerName: String,
                               onStep: @Sendable @escaping (String) -> Void) async throws -> RecoveredConfig {
        onStep(L10n.provisioningRecovering.localized())
        let output = try await _withConnection(host: host, password: password) { client in
            try await execute(client: client, label: "recover-config",
                              command: recoverConfigScript(containerName: containerName))
        }
        return try parseRecoveredConfig(from: output)
    }

    // MARK: #314 — Rotate key ("generate new key" fallback for #303)
    //
    // When recoverConfig finds server.yaml unreadable/unparseable, the
    // read-only path cannot extract the key/params. scripts/rotate-key.sh
    // repairs the server instead: it rotates `~/.olcrtc_key` and rewrites
    // server.yaml using srv.sh's verbatim key-generation / YAML-writing lines
    // (parity guarded by Tests/RotateKeyScriptTests.swift), restarts the
    // container, and prints the same OLCRTC_URI= / OLCRTC_CONTAINER= contract
    // as srv.sh — so `parseInstallResult` is reused unchanged.
    //
    // Destructive by design: the new key cuts off every other client of that
    // server. The UI confirms explicitly before calling this.
    static func rotateKey(host: ServerHost, password: String, containerName: String,
                          onStep: @Sendable @escaping (String) -> Void) async throws -> InstallResult {
        onStep(L10n.provisioningRotatingKey.localized())
        let script = try loadBundledScript(named: "rotate-key")
        await MainActor.run { LogStore.shared.log(.provisioning,
            "✓ rotate-key.sh \(script.count) bytes") }
        let b64 = Data(script.utf8).base64EncodedString()
        let safeCname = shellSafe(containerName)
        // Upload over the same base64-printf channel as srv.sh (uploadScript),
        // then run synchronously: openssl + config rewrite + podman restart
        // take seconds (like reconfigureScript), so the nohup/poll install
        // pipeline would be overkill. OLCRTC_CONFIG_NAME is set explicitly to
        // keep the auto-provisioned marker unconditional (see installEnv).
        let output = try await _withConnection(host: host, password: password) { client in
            _ = try await execute(client: client, label: "upload rotate-key.sh",
                command: "printf '%s' '\(b64)' | base64 -d > \(RemotePaths.rotateScript)" +
                         " && chmod +x \(RemotePaths.rotateScript)")
            return try await execute(client: client, label: "rotate key",
                command: "OLCRTC_CONTAINER=\(safeCname) OLCRTC_CONFIG_NAME=auto-provisioned " +
                         RemotePaths.rotateScript)
        }
        guard let result = parseInstallResult(from: output) else {
            throw ProvisionError.parseFailed(L10n.rotateKeyFailedNoURI.localized())
        }
        return result
    }

    // MARK: Uninstall script

    // Container name prefix used by `scripts/srv.sh` (`CONTAINER_NAME="olcrtc-server-$PODMAN_ID"`).
    // Must stay in sync with the server script — a mismatch silently breaks
    // the no-name sweep below and orphans containers on the VPS.
    static let containerNamePrefix = "olcrtc-server-"

    static func deepUninstallScript(containerName: String?, removeImage: Bool) -> String {
        var lines: [String] = []
        if let name = containerName {
            lines.append("podman stop \"\(shellSafe(name))\" 2>/dev/null || true")
            lines.append("podman rm \"\(shellSafe(name))\" 2>/dev/null || true")
        } else {
            lines.append("podman ps -a --filter 'name=olcrtc-server-' --format '{{.Names}}' | xargs -r podman stop 2>/dev/null || true")
            lines.append("podman ps -a --filter 'name=olcrtc-server-' --format '{{.Names}}' | xargs -r podman rm 2>/dev/null || true")
        }
        lines.append("rm -rf /tmp/olcrtc-deploy-* 2>/dev/null || true")
        lines.append("rm -rf ~/.cache/olcrtc 2>/dev/null || true")
        lines.append("rm -f ~/.olcrtc_key 2>/dev/null || true")
        if removeImage {
            lines.append("podman rmi docker.io/library/golang:1.26-alpine3.22 2>/dev/null || true")
        }
        lines.append("echo OLCRTC_DEEP_UNINSTALLED=ok")
        return lines.joined(separator: "\n")
    }

    static func uninstallScript(containerName: String?) -> String {
        // The `target` literal is only used to make the exact-match grep
        // deterministically fail when we have no recorded name — the real
        // cleanup then happens in the `else` sweep branch. Keep it equal
        // to the prefix for readability.
        let target = containerName ?? containerNamePrefix
        return #"""
        set +e
        if podman ps -a --format '{{.Names}}' | grep -q '^\#(target)$' 2>/dev/null; then
            podman stop "\#(target)" 2>/dev/null
            podman rm   "\#(target)" 2>/dev/null
        else
            for c in $(podman ps -aq --filter 'name=\#(containerNamePrefix)'); do
                podman stop "$c" 2>/dev/null
                podman rm   "$c" 2>/dev/null
            done
        fi
        rm -rf /tmp/olcrtc-deploy /tmp/olcrtc-build /tmp/olcrtc-deploy-*
        rm -f ~/.olcrtc_key
        echo "OLCRTC_UNINSTALLED=ok"
        """#
    }
}
