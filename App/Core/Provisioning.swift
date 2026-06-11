import Foundation
@preconcurrency import Citadel
import NIO

// MARK: - Provisioning
//
// Manages remote operations against a ServerHost via SSH:
//   - install   — uploads scripts/srv.sh to the VPS, runs it with env vars
//                 set from InstallOptions, parses OLCRTC_URI= and
//                 OLCRTC_CONTAINER= from the output, returns InstallResult.
//   - uninstall — stops + removes any olcrtc-server-* containers and cleans up.
//   - reboot    — issues `sudo reboot`.
//   - ping      — TCP-22 reachability check.
//
// scripts/srv.sh is a full copy of upstream olcrtc-upstream/script/srv.sh with our
// modifications marked using # boc olcrtc-ios / # eoc olcrtc-ios markers.
// parity_check.py (run as a build phase) verifies that unmarked lines stay
// identical to upstream — if upstream changes a flag or command we rely on,
// the build fails until we deliberately update scripts/srv.sh.
//
// All interactive prompts in srv.sh are replaced in our boc/eoc patches
// with env var reads (OLCRTC_CARRIER, OLCRTC_TRANSPORT, OLCRTC_ROOM_ID,
// etc.) so the script can run non-interactively over SSH.

/// Errors thrown by SSHRunner and surfaced to the UI via Provisioner.status.
/// `.sshConnect` / `.sshCommand` wrap Citadel errors; `.parseFailed` covers
/// missing output keys or install timeouts.
enum ProvisionError: LocalizedError {
    case missingPassword
    case sshConnect(String)
    case sshCommand(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPassword:      return L10n.provisionPasswordMissing.localized()
        case .sshConnect(let m):    return L10n.provisionSSHPrefix_fmt.formatted(m)
        case .sshCommand(let m):    return L10n.provisionCommandPrefix_fmt.formatted(m)
        case .parseFailed(let m):   return L10n.provisionParsePrefix_fmt.formatted(m)
        }
    }
}

struct InstallResult: Sendable {
    let uri: String              // olcrtc://...
    let containerName: String    // for later uninstall
}

/// User-chosen install parameters. Everything else (client-id, key, dns) is
/// filled in with defaults inside the install script.
///
/// Carrier matrix (mirrors upstream `script/srv.sh`):
///   - telemost, wbstream, jitsi → room ID must be supplied (created by the
///                                  user on telemost.yandex.ru / stream.wb.ru,
///                                  or a Jitsi room name/URL)
///
/// Transport defaults per carrier — wbstream disabled datachannel on their
/// side so we fall back to vp8channel for that one. Users can override in
/// the install sheet if a carrier changes what works.
struct InstallOptions: Sendable, Equatable {
    var carrier:   String       // "telemost" | "wbstream" | "jitsi"
    var transport: String       // "datachannel" | "vp8channel" | "seichannel" | "videochannel"
    var roomID:    String       // required; the server needs an explicit room ID

    /// Jitsi rendezvous base URL, sent as `OLCRTC_JITSI_URL` only when
    /// `carrier == "jitsi"` (#256). Pre-filled from `AppConstants.defaultJitsiBaseURL`
    /// but user-overridable in the install sheet, so users can point at their own
    /// instance instead of the shared public default. Never empty (the sheet falls
    /// back to the default if cleared).
    var jitsiBaseURL: String = AppConstants.defaultJitsiBaseURL

    // SEI channel tunables — only consumed by installEnv() when transport == "seichannel".
    var seiFPS  : Int = 30
    var seiBatch: Int = 10
    var seiFrag : Int = 1200
    var seiACK  : Int = 1

    static let `default` = InstallOptions(carrier: "wbstream",
                                          transport: "datachannel",
                                          roomID: "")

    var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    static func defaultTransport(for carrier: String) -> String {
        CarrierTransportMatrix.defaultTransport(for: carrier)
    }
}

enum ProvisionStatus: Equatable {
    case idle
    case running(String)
    case success(String)
    case failure(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Live state of the olcrtc container on a VPS, parsed from `podman ps`.
///
/// `podman ps -a --filter "name=^<cname>$" --format "{{.Status}}"` prints
/// one line like "Up 2 hours" for running containers, "Exited (137) 5
/// minutes ago" for stopped, and nothing at all when the container doesn't
/// exist. We compress those into the three cases below.
/// Richer VPS readiness state — what's actually installed on the server.
/// Probed via `Provisioner.probeReadiness(on:password:)` which runs a single
/// SSH call checking Podman, golang image, and the named container.
enum VPSReadinessState: Equatable, Sendable {
    case noPodman                    // Podman not installed → first install takes full ~5-7 min
    case noImage                     // Podman present, image not cached → ~3-5 min
    case imageReady                  // Image cached, no container → reinstall ~1-2 min
    case containerStopped(String)    // Container exists but not running
    case containerRunning(String)    // Container up and running

    var label: String {
        switch self {
        case .noPodman:                return L10n.readinessNoPodman.localized()
        case .noImage:                 return L10n.readinessNoImage.localized()
        case .imageReady:              return L10n.readinessImageReady.localized()
        case .containerStopped(let s): return L10n.readinessContainerStopped_fmt.formatted(s)
        case .containerRunning(let s): return L10n.readinessContainerRunning_fmt.formatted(s)
        }
    }

    var dot: String {
        switch self {
        case .containerRunning: return "🟢"
        case .containerStopped: return "🔴"
        case .imageReady:       return "🟡"
        default:                return "⚪"
        }
    }
}

enum ContainerStatus: Equatable, Sendable {
    case running(String)   // "Up 2 hours"
    case stopped(String)   // "Exited (137) 5 minutes ago"
    case notFound

    /// Short label shown next to the indicator dot on the host card.
    var shortLabel: String {
        switch self {
        case .running(let s): return s
        case .stopped(let s): return s
        case .notFound:       return L10n.containerNotFoundShort.localized()
        }
    }

    /// Parses raw `podman ps --format "{{.Status}}"` output.
    /// Empty string → notFound; "Up …" → running; anything else → stopped.
    static func parse(from raw: String) -> ContainerStatus {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty         { return .notFound }
        if s.hasPrefix("Up") { return .running(s) }
        return .stopped(s)
    }
}

/// Coordinates SSH-based VPS operations and publishes a single `status`
/// so the UI can show a progress banner. Delegates all SSH work to the
/// nonisolated `SSHRunner` enum; only one operation runs at a time.
@MainActor
final class Provisioner: ObservableObject {
    @Published var status: ProvisionStatus = .idle

    // MARK: Ping

    /// TCP-22 reachability check. Doesn't need creds, so we route directly
    /// to NetPing without going through Citadel.
    func ping(host: ServerHost) async {
        status = .running("Ping \(host.host):\(host.port)…")
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Ping \(host.host):\(host.port)")
        let result = await NetPing.tcp(host: host.host, port: UInt16(host.port))
        if result.success, let ms = result.ms {
            let msg = L10n.pingTCPOK_fmt.formatted(host.port, String(format: "%.0f", ms))
            LogStore.shared.log(.provisioning, "✓ \(msg)")
            status = .success(msg)
        } else {
            let msg = L10n.pingTCPFail_fmt.formatted(host.port)
            LogStore.shared.log(.provisioning, "✗ \(msg)")
            status = .failure(msg)
        }
    }

    // MARK: Reachability pre-probe
    //
    // Quick TCP-22 ping before each SSH-driven action. Citadel itself has a
    // 30 s connect timeout × 2 retries = up to 64 s before failure surfaces.
    // For a completely unreachable VPS (power off, ISP block, wrong IP) that's
    // a painful wait. A 5 s probe finds the bad cases up-front and surfaces
    // a friendly "Server is not responding" message instead.

    private static let probeTimeout: TimeInterval = 5

    /// Throws `ProvisionError.sshConnect(serverUnreachable_fmt)` if TCP-port
    /// is not reachable within `probeTimeout` seconds. On success returns
    /// quickly (~50–200 ms) and the caller proceeds with SSH.
    private func ensureReachable(_ host: ServerHost) async throws {
        let result = await NetPing.tcp(host: host.host,
                                        port: UInt16(host.port),
                                        timeout: Self.probeTimeout)
        guard result.success else {
            let target = "\(host.host):\(host.port)"
            let msg = L10n.serverUnreachable_fmt.formatted(target)
            LogStore.shared.log(.provisioning, "✗ \(msg)")
            throw ProvisionError.sshConnect(msg)
        }
        if let ms = result.ms {
            LogStore.shared.log(.provisioning,
                "✓ TCP/\(host.port) reachable (\(String(format: "%.0f", ms)) ms)")
        }
    }

    // MARK: Install / Uninstall / Reboot

    func install(on host: ServerHost, password: String,
                 options: InstallOptions) async throws -> InstallResult {
        status = .running(L10n.provisioningSSHConnecting.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Install: SSH \(host.username)@\(host.host):\(host.port) carrier=\(options.carrier) transport=\(options.transport)" +
            (options.requiresRoomID ? " room=\(options.roomID.prefix(8))…" : " room=auto"))
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.install(host: host, password: password,
                                                      options: options,
                                                      onStep: stepHandler())
            status = .success(L10n.installResultSuccess_fmt.formatted(options.carrier, options.transport))
            return result
        } catch {
            LogStore.shared.log(.provisioning, "✗ Install failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func uninstall(on host: ServerHost, password: String, containerName: String?) async throws {
        status = .running(L10n.provisioningUninstallSSH.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Uninstall on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.uninstall(host: host, password: password,
                                           containerName: containerName,
                                           onStep: stepHandler())
            status = .success(L10n.uninstallResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func update(on host: ServerHost, password: String, containerName: String?) async throws {
        status = .running(L10n.provisioningUpdating.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Update on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.update(host: host, password: password,
                                       containerName: containerName,
                                       onStep: stepHandler())
            status = .success(L10n.updateResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func start(on host: ServerHost, password: String, containerName: String) async throws {
        status = .running(L10n.provisioningStarting.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Start on \(host.host): \(containerName)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.start(host: host, password: password,
                                      containerName: containerName,
                                      onStep: stepHandler())
            status = .success(L10n.startResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func stop(on host: ServerHost, password: String, containerName: String) async throws {
        status = .running(L10n.provisioningStopping.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Stop on \(host.host): \(containerName)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.stop(host: host, password: password,
                                     containerName: containerName,
                                     onStep: stepHandler())
            status = .success(L10n.stopResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func deepUninstall(on host: ServerHost, password: String,
                       containerName: String?, removeImage: Bool) async throws {
        status = .running(L10n.provisioningUninstalling.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Deep uninstall on \(host.host) removeImage=\(removeImage)")
        do {
            try await ensureReachable(host)
            try await SSHRunner._withConnection(host: host, password: password) { client in
                _ = try await SSHRunner._execute(
                    client: client, label: "deep-uninstall",
                    command: SSHRunner.deepUninstallScript(containerName: containerName,
                                                          removeImage: removeImage))
            }
            status = .success(L10n.deepUninstallResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: Scan for existing containers

    func scanContainers(on host: ServerHost, password: String) async throws -> [SSHRunner.FoundContainer] {
        status = .running(L10n.scanningContainers.localized())
        LogStore.shared.log(.provisioning, "→ Scanning \(host.host) for olcrtc containers…")
        do {
            try await ensureReachable(host)
            let output = try await SSHRunner._withConnection(host: host, password: password) { client in
                try await SSHRunner._execute(client: client, label: "scan",
                                             command: SSHRunner.scanContainersScript())
            }
            let found = SSHRunner.parseScannedContainers(from: output)
            LogStore.shared.log(.provisioning, "✓ Found \(found.count) olcrtc container(s)")
            status = .idle
            return found
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: VPS readiness probe

    /// Single SSH call that checks Podman, the golang image, and the container.
    /// Cheap (~1 s RTT), safe to call on every Status refresh.
    /// Does NOT touch `status` — callers that want spinner/button-lock use
    /// `checkReadiness` instead.
    func probeReadiness(on host: ServerHost, password: String,
                        containerName: String?) async throws -> (VPSReadinessState, SSHRunner.VPSStats?) {
        LogStore.shared.startSession(.provisioning)
        try await ensureReachable(host)
        let output = try await SSHRunner._withConnection(host: host, password: password) { client in
            try await SSHRunner._execute(client: client, label: "readiness",
                                         command: SSHRunner.readinessScript(containerName: containerName))
        }
        let state = SSHRunner.parseReadiness(from: output, containerName: containerName)
        let stats = SSHRunner.parseVPSStats(from: output)
        return (state, stats)
    }

    /// Same as `probeReadiness` but sets `status` so the card shows a yellow
    /// in-progress indicator and buttons are disabled. Use for explicit user-
    /// initiated checks; internal post-operation probes call `probeReadiness`
    /// directly to avoid overwriting the operation's own status.
    func checkReadiness(on host: ServerHost, password: String,
                        containerName: String?) async throws -> (VPSReadinessState, SSHRunner.VPSStats?) {
        status = .running(L10n.provisioningStatusFetching.localized())
        do {
            let result = try await probeReadiness(on: host, password: password, containerName: containerName)
            status = .idle
            return result
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // MARK: Container status + logs

    /// Probes `podman ps` over SSH and reports whether the named container
    /// is running. Cheap (one short command), so it's safe to bind to a
    /// "refresh" button on the host card.
    func containerStatus(on host: ServerHost, password: String,
                          containerName: String) async throws -> ContainerStatus {
        status = .running(L10n.provisioningStatusFetching.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Status: \(containerName) on \(host.host)")
        do {
            try await ensureReachable(host)
            let result = try await SSHRunner.containerStatus(
                host: host, password: password,
                containerName: containerName,
                onStep: stepHandler())
            let msg: String
            switch result {
            case .running(let s): msg = L10n.containerRunning_fmt.formatted(s)
            case .stopped(let s): msg = L10n.containerStopped_fmt.formatted(s)
            case .notFound:       msg = L10n.containerNotFound.localized()
            }
            LogStore.shared.log(.provisioning, "✓ \(msg)")
            status = .success(msg)
            return result
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    /// Pulls `podman logs --tail N` over SSH. Returns the raw text and ALSO
    /// dumps each line into this server's per-host `.containerLogs` buffer/file
    /// (#295: `<host.logFilePrefix>_container.log`) so the user can scroll
    /// through it in the Logs tab Container tab later. Returned string is
    /// what the calling view shows in its sheet.
    func containerLogs(on host: ServerHost, password: String,
                        containerName: String, tail: Int = 200) async throws -> String {
        status = .running(L10n.provisioningLogsFetching.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Logs: \(containerName) on \(host.host) (tail=\(tail))")
        do {
            try await ensureReachable(host)
            let output = try await SSHRunner.containerLogs(
                host: host, password: password,
                containerName: containerName, tail: tail,
                onStep: stepHandler())

            // Persist into this server's own container-log file so it
            // survives the sheet being dismissed. #278: parse each line's Go
            // timestamp ("2006/01/02 15:04:05") into a real Date so the
            // container lines interleave chronologically with the client
            // stream instead of all clustering at fetch-time; lines without
            // their own stamp carry the previous line's date forward
            // (multi-line panics etc.). #295: per-server file/buffer, keyed
            // by the sanitised server-name prefix.
            let prefix = host.logFilePrefix
            LogStore.shared.startContainerSession(serverPrefix: prefix)
            var carry = Date()
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                let raw = String(line)
                if let parsed = LogStore.parseExternalTimestamp(raw) {
                    carry = parsed.date
                    LogStore.shared.logContainer(serverPrefix: prefix, parsed.rest, date: parsed.date)
                } else {
                    LogStore.shared.logContainer(serverPrefix: prefix, raw, date: carry)
                }
            }
            // Remember this host/container so the Logs tab can re-pull directly.
            LogStore.shared.noteContainerTarget(hostID: host.id, containerName: containerName, serverPrefix: prefix)

            status = .success(L10n.logsBytesReceived_fmt.formatted(output.count))
            return output
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func reconfigure(on host: ServerHost, password: String,
                     containerName: String, options: InstallOptions) async throws -> String? {
        status = .running(L10n.provisioningReconfiguring.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning,
            "→ Reconfigure on \(host.host): carrier=\(options.carrier) transport=\(options.transport)" +
            (options.requiresRoomID ? " room=\(options.roomID.prefix(8))…" : " room=auto"))
        do {
            try await ensureReachable(host)
            let env = SSHRunner.installEnv(options)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }
            let newURI = try await SSHRunner.reconfigure(host: host, password: password,
                                                         containerName: containerName, env: env,
                                                         onStep: stepHandler())
            if let uri = newURI {
                LogStore.shared.log(.provisioning, "✓ New URI: \(LogStore.redactSecrets(uri))")
            } else {
                LogStore.shared.log(.provisioning, "⚠ Reconfigure succeeded but server did not emit URI — ConnectionRecord not updated. Run Status to refresh.")
            }
            status = .success(L10n.reconfigureResultSuccess_fmt.formatted(options.carrier, options.transport))
            return newURI
        } catch {
            LogStore.shared.log(.provisioning, "✗ Reconfigure failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    // #303: read-only recovery of an existing server's connection params
    // (carrier/transport/room/key) from its deployed server.yaml, for hosts
    // where a container was found (#302 auto-detect) but no ConnectionRecord
    // is linked — e.g. fresh install / reinstall with an empty Connections tab.
    func recoverConfig(on host: ServerHost, password: String,
                       containerName: String) async throws -> SSHRunner.RecoveredConfig {
        status = .running(L10n.provisioningRecovering.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Recover config: \(containerName) on \(host.host)")
        do {
            try await ensureReachable(host)
            let cfg = try await SSHRunner.recoverConfig(host: host, password: password,
                                                        containerName: containerName,
                                                        onStep: stepHandler())
            LogStore.shared.log(.provisioning,
                "✓ Recovered config: carrier=\(cfg.carrier) transport=\(cfg.transport) room=\(cfg.roomID.prefix(8))…")
            status = .success(L10n.recoverResultSuccess_fmt.formatted(cfg.carrier, cfg.transport))
            return cfg
        } catch {
            LogStore.shared.log(.provisioning, "✗ Recover config failed: \(error.localizedDescription)")
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    func reboot(on host: ServerHost, password: String) async throws {
        status = .running(L10n.provisioningRebootSSH.localized())
        LogStore.shared.startSession(.provisioning)
        LogStore.shared.log(.provisioning, "→ Reboot on \(host.host)")
        do {
            try await ensureReachable(host)
            try await SSHRunner.reboot(host: host, password: password,
                                        onStep: stepHandler())
            status = .success(L10n.rebootResultSuccess.localized())
        } catch {
            status = .failure(error.localizedDescription)
            throw error
        }
    }

    private func stepHandler() -> @Sendable (String) -> Void {
        return { [weak self] step in
            Task { @MainActor in self?.status = .running(step) }
        }
    }
}

// SSH transport moved to SSHRunner.swift on 2026-05-16.
