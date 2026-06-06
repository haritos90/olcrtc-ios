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
    case ip
    case speed
    case provisioning    // SSH-driven server install / uninstall / reboot
    case containerLogs   // podman logs from the olcrtc container on the VPS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection:    return L10n.categoryConnection.localized()
        case .ip:            return L10n.categoryIP.localized()
        case .speed:         return L10n.categorySpeed.localized()
        case .provisioning:  return L10n.categoryProvisioning.localized()
        case .containerLogs: return L10n.categoryContainerLogs.localized()
        }
    }

    var systemImage: String {
        switch self {
        case .connection:    return "network"
        case .ip:            return "globe"
        case .speed:         return "speedometer"
        case .provisioning:  return "server.rack"
        case .containerLogs: return "shippingbox"
        }
    }
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
struct ContainerLogTarget: Equatable {
    let hostID: UUID
    let containerName: String
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
final class LogFileWriter {
    private var handle: FileHandle?
    private var mirrorHandle: FileHandle?
    private(set) var fileURL: URL?

    init(category: LogCategory) {
        guard let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("FileManager.urls(.documentDirectory) returned empty — iOS sandbox invariant violated")
        }
        let logsDir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Use a fixed filename per category so history accumulates across
        // sessions instead of starting a new file on every startSession call.
        let filename = "\(category.rawValue).log"
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
        handle?.write(data)
        mirrorHandle?.write(data)
    }

    deinit {
        handle?.closeFile()
        mirrorHandle?.closeFile()
    }
}

/// Central log sink for the whole app. Maintains bounded in-memory buffers
/// per `LogCategory` (for SwiftUI observation) and rotating on-disk files.
/// On simulator, mirrors every write to `/tmp/olcrtc-ios-logs/` for tooling access.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    // Bounded buffers per category. UI scrolls these; older entries are dropped.
    // Cap comes from SettingsStore.logBufferSize so the user can tune it
    // in the Settings tab.
    @Published var entries: [LogCategory: [LogEntry]] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map { ($0, []) }
    )

    @Published var fileURLs: [LogCategory: URL] = [:]

    // Bumped on every appended line so views can cheaply observe "something
    // changed" — the merged stream (#276) collapses the per-category counts, so a
    // count-diff alone misses same-cap appends (oldest dropped, newest added).
    @Published private(set) var revision: Int = 0

    // Last container targeted by a logs fetch (#278); drives the Logs-tab refresh.
    @Published private(set) var lastContainerTarget: ContainerLogTarget?

    private var writers: [LogCategory: LogFileWriter] = [:]

    // Monotonic, assigned per appended line — the merged stream's stable
    // tiebreaker when two lines share the same timestamp.
    private var seqCounter = 0

    private init() {}

    /// Start a new log file for the given category.
    /// Called at the start of each operation (connect, ip check run, speed test run).
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

    static func appVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "olcrtc-ios \(v) build \(b)"
    }

    /// Drops every in-memory entry across all categories. File-on-disk
    /// logs are NOT deleted — they're forensic and live across sessions.
    func clearAll() {
        for cat in LogCategory.allCases {
            entries[cat] = []
        }
        revision &+= 1
    }

    /// Drops in-memory entries for a single category only.
    func clear(category: LogCategory) {
        entries[category] = []
        revision &+= 1
    }

    /// All categories flattened into one chronological stream (#276), oldest
    /// first. Sorted by timestamp, then insertion order (`seq`) so same-second
    /// lines keep their original sequence. The Logs view renders this reversed
    /// (newest-first, #277).
    var merged: [LogEntry] {
        entries.values.flatMap { $0 }.sorted {
            $0.date == $1.date ? $0.seq < $1.seq : $0.date < $1.date
        }
    }

    /// Remembers the host+container a logs fetch ran against (#278) so the Logs
    /// tab can re-pull without sending the user back to the server card.
    func noteContainerTarget(hostID: UUID, containerName: String) {
        lastContainerTarget = ContainerLogTarget(hostID: hostID, containerName: containerName)
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
        writers[category]?.write("\(Self.format(date: date)) \(safe)")
        revision &+= 1
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
