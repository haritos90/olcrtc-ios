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

/// A single timestamped line in the in-memory log buffer for a given category.
struct LogEntry: Identifiable, Equatable {
    let id   = UUID()
    let date = Date()
    let text : String
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
        try? handle?.seekToEnd()
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
        try? mirrorHandle?.seekToEnd()
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

    private var writers: [LogCategory: LogFileWriter] = [:]

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
    }

    /// Drops in-memory entries for a single category only.
    func clear(category: LogCategory) {
        entries[category] = []
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

    @MainActor func log(_ category: LogCategory, _ msg: String) {
        let level = SettingsStore.shared.logLevel

        // Off — drop everything (file writes also suppressed)
        if level == .off { return }

        // Below verbose — drop Pion-level noise
        if level < .verbose {
            let lower = msg.lowercased()
            if Self.pionNoisePatterns.contains(where: { lower.contains($0.lowercased()) }) { return }
        }

        let safe = Self.redactSecrets(msg)
        let line = "\(Self.timestamp()) \(safe)"
        var list = entries[category] ?? []
        list.append(LogEntry(text: line))
        let cap = max(50, SettingsStore.shared.logBufferSize)
        if list.count > cap { list.removeFirst(list.count - cap) }
        entries[category] = list
        writers[category]?.write(line)
    }

    private static let _timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static func timestamp() -> String { _timestampFormatter.string(from: Date()) }

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
