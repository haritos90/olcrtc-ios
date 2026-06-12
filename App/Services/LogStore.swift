import Foundation

// MARK: - LogStore
//
// Centralised, category-aware logging for the whole app.
//
// Why categories? The user runs three independent operations
// (connecting, IP checks, speed tests). Mixing their log output
// in one stream makes debugging painful. Each category gets its
// own in-memory buffer and its own rotating file.
//
// Why singleton? Producers live in different places (TunnelManager,
// IPChecker, SpeedTest) and creating per-instance loggers would
// require threading the same dependency everywhere. The store is a
// pure sink — no business logic, so global state is fine here.
//
// Log files go to the app's Documents/logs/ folder on both simulator and device.

enum LogCategory: String, CaseIterable, Identifiable {
    case connection
    // #294 was: separate `.ip` / `.speed` categories, each with its own
    // ip.log / speed.log. Both are short, user-triggered diagnostic runs the
    // user reads together, so they're merged into one "Diagnostics" tab/file.
    case diagnostics
    case provisioning    // SSH-driven server install / uninstall / reboot
    case containerLogs   // podman logs from the olcrtc container on the VPS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection:    return L10n.categoryConnection.localized()
        case .diagnostics:   return L10n.categoryDiagnostics.localized()
        case .provisioning:  return L10n.categoryProvisioning.localized()
        case .containerLogs: return L10n.categoryContainerLogs.localized()
        }
    }

    /// #316: abbreviated label for the Logs tab's segmented control — short
    /// enough that four segments never wrap; `title` stays the VoiceOver name.
    var segmentTitle: String {
        switch self {
        case .connection:    return L10n.logsSegConnection.localized()
        case .diagnostics:   return L10n.logsSegDiagnostics.localized()
        case .provisioning:  return L10n.logsSegVPS.localized()
        case .containerLogs: return L10n.logsSegContainer.localized()
        }
    }

    /// #294: short description of what the category contains.
    /// #316 was: shown under each Logs tab title (LogTabHeader) — now feeds
    /// the empty-state hint instead.
    var tabDescription: String {
        switch self {
        case .connection:    return L10n.logsTabDescConnection.localized()
        case .diagnostics:   return L10n.logsTabDescDiagnostics.localized()
        case .provisioning:  return L10n.logsTabDescVPS.localized()
        case .containerLogs: return L10n.logsTabDescContainer.localized()
        }
    }

    var systemImage: String {
        switch self {
        case .connection:    return "network"
        case .diagnostics:   return "stethoscope"
        case .provisioning:  return "server.rack"
        case .containerLogs: return "shippingbox"
        }
    }

    /// #294: the on-disk file name for the fixed (non-per-server) categories.
    /// `LogFileWriter`'s default filename for these matches this value —
    /// the Logs tab's file-header row reads it from here so the displayed
    /// name can't drift from what's actually written (#316). Not meaningful for `.containerLogs`,
    /// which is per-server (#295) — see `ServerHost.logFilePrefix`.
    var logFileName: String { "\(rawValue).log" }
}

/// Per-line severity for colour-coding the merged Logs stream (#276). Distinct
/// from `LogLevel` (a global *verbosity threshold* with no "warning" rung): this
/// classifies one line's importance, inferred from its text when not given
/// explicitly. Order matters — `.debug < .info < .warn < .error`.
enum LogLineLevel: Int, Comparable, CaseIterable {
    case debug, info, warn, error
    static func < (a: LogLineLevel, b: LogLineLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Host + container of the most recent `podman logs` fetch (#278), so the Logs
/// tab can offer an in-place "Refresh from server" without re-selecting a host.
/// #295: also carries the sanitised server-name prefix that selects the
/// per-server `%servername%_container.log` file/buffer.
struct ContainerLogTarget: Equatable {
    let hostID: UUID
    let containerName: String
    let serverPrefix: String
}

/// A single line in the in-memory log buffer. `text` is the *message only* — the
/// timestamp lives in `date` (formatted at display time, #277) and the origin in
/// `category` (so the merged stream can tag each line, #276). `seq` is a
/// monotonic tiebreaker for stable ordering when timestamps collide (e.g.
/// container lines whose Go timestamps share the same whole second).
struct LogEntry: Identifiable, Equatable {
    let id   = UUID()
    let date : Date
    let category : LogCategory
    let level : LogLineLevel
    let text : String
    let seq  : Int

    init(date: Date = Date(), category: LogCategory, level: LogLineLevel = .info,
         text: String, seq: Int = 0) {
        self.date = date
        self.category = category
        self.level = level
        self.text = text
        self.seq = seq
    }
}

// Writes plain text lines to a per-category rotating file.
// On simulator also mirrors to /tmp/olcrtc-ios-logs/ so Claude Code can read them.
// #332: writes used to run synchronously on the caller's (main) thread, so a
// teardown log storm stacked two disk writes per line inside UI updates —
// the "slow disconnect" freeze. They now hop onto one shared serial
// background queue; the caller hands over an already-redacted line
// (LogStore redacts before calling `write`), so nothing unredacted can
// reach disk from the queue either.
final class LogFileWriter {
    /// #332: a single serial queue shared by every writer keeps the exact
    /// append order — within a file and across files (a replaced writer's
    /// queued lines land before its successor's) — while keeping file I/O
    /// off the main actor.
    private static let ioQueue = DispatchQueue(label: "olcrtc.log-file-writer", qos: .utility)

    private var handle: FileHandle?
    private var mirrorHandle: FileHandle?
    private(set) var fileURL: URL?

    /// `filename` defaults to `"<category>.log"`, giving each of the fixed
    /// categories (connection/diagnostics/provisioning) a stable name. #295:
    /// containerLogs passes an explicit `"<serverPrefix>_container.log"` so
    /// each server's container output lands in its own file.
    init(category: LogCategory, filename: String? = nil) {
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("FileManager.urls(.documentDirectory) returned empty — iOS sandbox invariant violated")
        }
        let logsDir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Use a fixed filename per category (or per-server, for containerLogs)
        // so history accumulates across sessions instead of starting a new
        // file on every startSession call.
        let filename = filename ?? category.logFileName
        let url = logsDir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        fileURL = url

        #if targetEnvironment(simulator)
        let mirrorDir = "/tmp/olcrtc-ios-logs"
        try? FileManager.default.createDirectory(
            atPath: mirrorDir, withIntermediateDirectories: true, attributes: nil)
        let mirrorPath = "\(mirrorDir)/\(filename)"
        if !FileManager.default.fileExists(atPath: mirrorPath) {
            FileManager.default.createFile(atPath: mirrorPath, contents: nil)
        }
        mirrorHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: mirrorPath))
        _ = try? mirrorHandle?.seekToEnd()
        #endif
    }

    func write(_ line: String) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        // #332 was: handle?.write(data) + mirrorHandle?.write(data) inline —
        // synchronous disk I/O on the main actor, twice per log line.
        Self.ioQueue.async { [handle, mirrorHandle] in
            handle?.write(data)
            mirrorHandle?.write(data)
        }
    }

    deinit {
        // #332: close on the same serial queue so every queued write lands
        // before the handle closes (writing to a closed FileHandle raises).
        Self.ioQueue.async { [handle, mirrorHandle] in
            handle?.closeFile()
            mirrorHandle?.closeFile()
        }
    }
}

// boc #332
/// Leading+trailing throttle for the UI `revision` counter. Pure state
/// machine — no clocks or tasks inside, the caller supplies `now` — so the
/// coalescing rules are unit-testable: the first event after a quiet period
/// fires immediately, a burst schedules exactly one trailing flush
/// `minInterval` after the last fire, and everything in between is dropped.
/// Net effect: observers see at most one update per `minInterval` regardless
/// of the log rate, and the newest lines always surface within `minInterval`.
struct LogUpdateCoalescer {
    enum Action: Equatable {
        case fireNow                          // bump the published value now
        case scheduleFlush(after: Duration)   // bump once after this delay
        case alreadyScheduled                 // a trailing flush is pending — drop
    }

    let minInterval: Duration
    private var lastFire: ContinuousClock.Instant?
    private var flushPending = false

    init(minInterval: Duration) { self.minInterval = minInterval }

    /// Record one event (an appended log line) and learn what to do about it.
    mutating func recordEvent(now: ContinuousClock.Instant) -> Action {
        if flushPending { return .alreadyScheduled }
        if let last = lastFire {
            let elapsed = last.duration(to: now)
            if elapsed < minInterval {
                flushPending = true
                return .scheduleFlush(after: minInterval - elapsed)
            }
        }
        lastFire = now
        return .fireNow
    }

    /// The scheduled trailing flush has fired.
    mutating func flushFired(now: ContinuousClock.Instant) {
        flushPending = false
        lastFire = now
    }
}
// eoc #332

/// Central log sink for the whole app. Maintains bounded in-memory buffers
/// per `LogCategory` (for SwiftUI observation) and rotating on-disk files.
/// On simulator, mirrors every write to `/tmp/olcrtc-ios-logs/` for tooling access.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    // Bounded buffers per category. UI scrolls these; older entries are dropped.
    // Cap comes from SettingsStore.logBufferSize so the user can tune it
    // in the Settings tab.
    // #332 was: @Published — publishing per appended line invalidated the
    // observing view on every line *in addition to* the `revision` bump,
    // defeating any coalescing. The buffers are plain storage now; views
    // refresh off the coalesced `revision` below.
    private(set) var entries: [LogCategory: [LogEntry]] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map { ($0, []) }
    )

    @Published var fileURLs: [LogCategory: URL] = [:]

    // #295: per-server container-log buffers, keyed by `ServerHost.logFilePrefix`.
    // `.containerLogs` no longer shares a single buffer/file across servers —
    // each server gets its own `<prefix>_container.log` and in-memory list.
    // #332 was: @Published — same per-line invalidation as `entries`.
    private(set) var containerEntries: [String: [LogEntry]] = [:]
    @Published var containerFileURLs: [String: URL] = [:]

    // Bumped when appended lines should reach the UI — a count-diff alone
    // misses same-cap appends (oldest dropped, newest added). #332: bumps are
    // coalesced (leading+trailing throttle, ≤4/s) so a log storm — e.g. the
    // carrier teardown on disconnect — can't re-render the Logs tab per line.
    @Published private(set) var revision: Int = 0

    // #332: throttle state behind `bumpRevisionCoalesced()`. 250 ms ⇒ at most
    // ~4 UI updates per second however fast lines arrive.
    private var revisionCoalescer = LogUpdateCoalescer(minInterval: .milliseconds(250))

    // Last container targeted by a logs fetch (#278); drives the Logs-tab refresh.
    @Published private(set) var lastContainerTarget: ContainerLogTarget?

    private var writers: [LogCategory: LogFileWriter] = [:]

    // #295: per-server container-log file writers, keyed the same way as
    // `containerEntries`.
    private var containerWriters: [String: LogFileWriter] = [:]

    // Monotonic, assigned per appended line — the stable tiebreaker when two
    // lines share the same timestamp (used by the per-tab newest-first sort).
    private var seqCounter = 0

    private init() {
        Self.cleanupOrphanedLogFiles()
    }

    // boc #332
    /// Every per-line `revision` bump goes through here. The clears
    /// (`clearAll` & co.) keep bumping `revision` directly — they're one-shot
    /// user actions that want instant feedback, not part of a storm.
    private func bumpRevisionCoalesced() {
        switch revisionCoalescer.recordEvent(now: .now) {
        case .fireNow:
            revision &+= 1
        case .scheduleFlush(let delay):
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                self.revisionCoalescer.flushFired(now: .now)
                self.revision &+= 1
            }
        case .alreadyScheduled:
            break
        }
    }
    // eoc #332

    /// #318: delete pre-#294/#295 log files that nothing writes anymore —
    /// `ip.log`/`speed.log` (merged into `diagnostics.log` by #294) and the
    /// old shared `containerLogs.log` (replaced by per-server
    /// `<prefix>_container.log` by #295). Runs once per launch; `try?` since
    /// a fresh install/Documents wipe has none of these to remove.
    private static func cleanupOrphanedLogFiles() {
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logsDir = docs.appendingPathComponent("logs", isDirectory: true)
        for name in ["ip.log", "speed.log", "containerLogs.log"] {
            try? FileManager.default.removeItem(at: logsDir.appendingPathComponent(name))
        }
    }

    /// Start a new log file for the given category.
    /// Called at the start of each operation (connect, ip check run, speed test run).
    /// Not used for `.containerLogs` — see `startContainerSession`.
    func startSession(_ category: LogCategory, clearMemory: Bool = false) {
        let w = LogFileWriter(category: category)
        writers[category] = w
        fileURLs[category] = w.fileURL
        if clearMemory {
            entries[category] = []
        }
        if !(entries[category]?.isEmpty ?? true) {
            log(category, "── new session ──────────────────────────")
        }
        log(category, "# \(Self.appVersionString())")
    }

    /// #295: start (or resume) the per-server container-log file for
    /// `serverPrefix` (a sanitised `ServerHost.logFilePrefix`). Each server's
    /// container output accumulates in `<serverPrefix>_container.log`.
    /// #338: a caller-supplied `divider` (command + time, design_handoff §2)
    /// replaces the generic "── new session ──" + version pair; logged at
    /// `.debug` so the Logs tab renders it tertiary.
    func startContainerSession(serverPrefix: String, divider: String? = nil) {
        let w = LogFileWriter(category: .containerLogs, filename: "\(serverPrefix)_container.log")
        containerWriters[serverPrefix] = w
        containerFileURLs[serverPrefix] = w.fileURL
        if containerEntries[serverPrefix] == nil {
            containerEntries[serverPrefix] = []
        }
        if let divider {
            logContainer(serverPrefix: serverPrefix, divider, level: .debug)
            return
        }
        if !(containerEntries[serverPrefix]?.isEmpty ?? true) {
            logContainer(serverPrefix: serverPrefix, "── new session ──────────────────────────")
        }
        logContainer(serverPrefix: serverPrefix, "# \(Self.appVersionString())")
    }

    static func appVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "olcrtc-ios \(v) build \(b)"
    }

    /// Drops every in-memory entry across all categories, including every
    /// per-server container-log buffer (#295). File-on-disk logs are NOT
    /// deleted — they're forensic and live across sessions.
    func clearAll() {
        for cat in LogCategory.allCases {
            entries[cat] = []
        }
        for prefix in containerEntries.keys {
            containerEntries[prefix] = []
        }
        revision &+= 1
    }

    /// Drops in-memory entries for a single category only. Not used for
    /// `.containerLogs` — see `clearContainer(serverPrefix:)`.
    func clear(category: LogCategory) {
        entries[category] = []
        revision &+= 1
    }

    /// #295: drops the in-memory buffer for one server's container log.
    func clearContainer(serverPrefix: String) {
        containerEntries[serverPrefix] = []
        revision &+= 1
    }

    /// Remembers the host+container a logs fetch ran against (#278) so the Logs
    /// tab can re-pull without sending the user back to the server card.
    /// #295: also remembers the sanitised server prefix that selects the
    /// per-server container-log file/buffer.
    func noteContainerTarget(hostID: UUID, containerName: String, serverPrefix: String) {
        lastContainerTarget = ContainerLogTarget(hostID: hostID, containerName: containerName, serverPrefix: serverPrefix)
    }

    /// Substrings that identify Pion-level noise suppressed below `.verbose`.
    private static let pionNoisePatterns: [String] = [
        "duplicated packet",
        "pion/turn",
        "TURN refresh",
        "DEBUG DTLS",
        "pion/ice",
        "pion/sctp",
        "pion/srtp",
        "pion/webrtc",
    ]

    /// Appends a line to `category`. `level` defaults to a text-inferred severity
    /// (#276); `date` defaults to now but callers ingesting external logs pass the
    /// line's own parsed timestamp so it interleaves chronologically (#278).
    @MainActor func log(_ category: LogCategory, _ msg: String,
                        level: LogLineLevel? = nil, date: Date = Date()) {
        let verbosity = SettingsStore.shared.logLevel

        // Off — drop everything (file writes also suppressed)
        if verbosity == .off { return }

        // Below verbose — drop Pion-level noise
        if verbosity < .verbose {
            let lower = msg.lowercased()
            if Self.pionNoisePatterns.contains(where: { lower.contains($0.lowercased()) }) { return }
        }

        let safe = Self.redactSecrets(msg)
        let lvl = level ?? Self.classify(safe)
        seqCounter &+= 1
        var list = entries[category] ?? []
        list.append(LogEntry(date: date, category: category, level: lvl, text: safe, seq: seqCounter))
        let cap = max(50, SettingsStore.shared.logBufferSize)
        if list.count > cap { list.removeFirst(list.count - cap) }
        entries[category] = list
        // The on-disk line keeps the timestamp inline so exported files stay
        // self-describing (the in-memory entry carries it as a real `Date`).
        // #332: `safe` (redacted above) is what reaches the writer — redaction
        // still precedes anything touching disk, even with async file I/O.
        writers[category]?.write("\(Self.format(date: date)) \(safe)")
        // #332 was: revision &+= 1 — per-line UI invalidation.
        bumpRevisionCoalesced()
    }

    /// #295: appends a line to the per-server container-log buffer/file for
    /// `serverPrefix`. Mirrors `log(_:_:level:date:)` but keyed by server
    /// instead of `LogCategory` since `.containerLogs` is now per-server.
    @MainActor func logContainer(serverPrefix: String, _ msg: String,
                                  level: LogLineLevel? = nil, date: Date = Date()) {
        let verbosity = SettingsStore.shared.logLevel
        if verbosity == .off { return }

        let safe = Self.redactSecrets(msg)
        let lvl = level ?? Self.classify(safe)
        seqCounter &+= 1
        var list = containerEntries[serverPrefix] ?? []
        list.append(LogEntry(date: date, category: .containerLogs, level: lvl, text: safe, seq: seqCounter))
        let cap = max(50, SettingsStore.shared.logBufferSize)
        if list.count > cap { list.removeFirst(list.count - cap) }
        containerEntries[serverPrefix] = list
        containerWriters[serverPrefix]?.write("\(Self.format(date: date)) \(safe)")
        // #332 was: revision &+= 1 — per-line UI invalidation.
        bumpRevisionCoalesced()
    }

    // #277: dated, millisecond timestamps everywhere (was time-only "HH:mm:ss.SSS"),
    // so it's clear which day/session a line belongs to across the merged stream.
    private static let _displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy.MM.dd HH:mm:ss.SSS"
        return f
    }()
    static func format(date: Date) -> String { _displayFormatter.string(from: date) }
    static func timestamp() -> String { _displayFormatter.string(from: Date()) }

    // Go's default log stamp ("2006/01/02 15:04:05", no millis) used by the
    // server/container lines (#278) — plus our own format, so re-ingesting an
    // already-stamped line is a no-op rather than a double stamp.
    private static let _goTSFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()

    /// Splits a leading timestamp off an externally-sourced line (container /
    /// server logs). Returns the parsed `Date` + the remaining message, or `nil`
    /// when the line carries no recognised timestamp — the caller then carries
    /// the previous line's date forward so continuation lines stay adjacent.
    static func parseExternalTimestamp(_ line: String) -> (date: Date, rest: String)? {
        func strip(_ count: Int, _ formatter: DateFormatter) -> (Date, String)? {
            guard line.count >= count else { return nil }
            guard let d = formatter.date(from: String(line.prefix(count))) else { return nil }
            let rest = String(line.dropFirst(count)).drop(while: { $0 == " " })
            return (d, String(rest))
        }
        // Try our own format (23 chars, with .SSS) first: DateFormatter treats
        // "." and "/" as interchangeable separators, so the shorter Go pattern
        // would otherwise match a dotted line and swallow the millis as `rest`.
        if let r = strip(23, _displayFormatter) { return r }     // 2006.01.02 15:04:05.000
        if let r = strip(19, _goTSFormatter) { return r }        // 2006/01/02 15:04:05
        return nil
    }

    // #276: infer a line's severity for colour-coding. Order:
    //   1. noise first, so a pion line containing "failed"/"unreachable" stays
    //      `.debug` rather than masquerading as an error;
    //   2. our own emoji severity prefixes (✗/❌ = error, ⚠ = warn) — the
    //      strongest, deliberate signal (e.g. "⚠ Network lost" must read warn,
    //      not error, even though it contains the "lost" keyword);
    //   3. keyword fallback for emoji-less lines (mostly server/container text).
    private static let _debugMarkers = ["[pc]", "[ice]", "[sctp]", "[dtls]", "pion/",
        "traffic:", "duplicated packet", "sid=", "kcp", "debug"]
    private static let _errorMarkers = ["error", "failed", "failure", "fatal", "panic",
        "cfnetwork", "not responding", "lost", "unreachable", "gave up", "missed_pongs=3"]
    private static let _warnMarkers = ["warn", "missed pong", "retry", "reconnect",
        "timeout", "busy", "degrad", "settle"]
    static func classify(_ text: String) -> LogLineLevel {
        let s = text.lowercased()
        if _debugMarkers.contains(where: { s.contains($0) }) { return .debug }
        if s.contains("✗") || s.contains("❌") { return .error }
        if s.contains("⚠") { return .warn }
        if _errorMarkers.contains(where: { s.contains($0) }) { return .error }
        if _warnMarkers.contains(where: { s.contains($0) }) { return .warn }
        return .info
    }

    // Redacts encryption credentials before anything lands in the in-memory
    // buffer or on disk. Two passes:
    //   1. The post-`#` key segment of any olcrtc:// URI is stripped.
    //      URI shape: olcrtc://carrier?transport@roomID#KEY[%clientID][$mimo].
    //      We replace KEY (everything up to %/$/whitespace) but keep the URI
    //      prefix readable so install-log dumps remain debuggable.
    //   2. Any standalone 64-hex run is redacted to catch srv.sh banners that
    //      print the key on its own line ("Encryption key: <64hex>").
    // Ordering: URI pass runs first so its specific replacement wins; the
    // hex pass mops up the bare-line cases. Both passes are idempotent.
    private static let _uriKeyRegex = try! NSRegularExpression(pattern: #"(olcrtc://[^\s#]+#)[^\s%$]+"#)
    private static let _hexKeyRegex = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{64}\b"#)
    static func redactSecrets(_ s: String) -> String {
        var out = s
        let r = NSRange(out.startIndex..<out.endIndex, in: out)
        out = _uriKeyRegex.stringByReplacingMatches(in: out, range: r, withTemplate: "$1<redacted>")
        let r2 = NSRange(out.startIndex..<out.endIndex, in: out)
        out = _hexKeyRegex.stringByReplacingMatches(in: out, range: r2, withTemplate: "<redacted-key>")
        return out
    }
}
