import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - LogExport
//
// #432: self-describing log exports. Before this, "Share" handed iOS a bare
// String, so a saved log landed as "text.txt" / "text 2.txt" with no way to tell
// which log it was, on which build, from which device — every shared log had to be
// guessed at. Now every export carries BOTH:
//   • a descriptive FILENAME  — olcrtc-connection-v1.3-b263-20260714-133041.log
//   • a content HEADER block   — log name, app version+build, device/OS, capture
//     window and line count, pinned at the very top of the file.
// So a log is identifiable from its filename in Files/Mail AND from its first lines
// once opened, with zero context. The header is deliberately fixed English (a
// diagnostic artifact read by tooling/support), matching the existing
// "# olcrtc-ios <v> build <b>" session banner in LogStore.
//
// The pure formatting helpers (fileName / header / stamps / safeToken) take every
// input as a parameter so they unit-test deterministically; only the thin file-I/O
// wrappers touch Bundle / UIDevice / disk.

enum LogExport {

    /// One log's worth of material for the combined "Export all" file.
    struct Section {
        let title: String     // human name, e.g. "Connection" or "prod — container"
        let file: String      // on-disk file name this buffer maps to
        let entries: [LogEntry]
    }

    // MARK: - Pure formatting (unit-tested)

    /// Filesystem-safe compact stamp for filenames: `20260714-133041`.
    static func fileStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        stampFormatter("yyyyMMdd-HHmmss", timeZone).string(from: date)
    }

    /// Human, timezone-aware stamp for the header: `2026-07-14 13:30:41 +0300`.
    static func headerStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        stampFormatter("yyyy-MM-dd HH:mm:ss ZZZZ", timeZone).string(from: date)
    }

    /// Lowercases and reduces an arbitrary label to `[a-z0-9-]` so it's safe in a
    /// filename across Files / Mail / other apps. Collapses runs of other chars to
    /// a single `-` and trims leading/trailing `-`.
    static func safeToken(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                // Keep ASCII letters/digits only; drop accents/non-ASCII to a dash.
                if ch.isASCII { out.append(ch); lastDash = false }
                else if !lastDash { out.append("-"); lastDash = true }
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "log" : out
    }

    /// Export filename for one log:
    /// `olcrtc-<label>-v<version>-b<build>-<stamp>.log`.
    static func fileName(label: String, version: String, build: String,
                         date: Date, timeZone: TimeZone = .current) -> String {
        "olcrtc-\(safeToken(label))-v\(safeToken(version))-b\(safeToken(build))-\(fileStamp(date, timeZone: timeZone)).log"
    }

    /// Filename for the combined "Export all" file.
    static func combinedFileName(version: String, build: String,
                                 date: Date, timeZone: TimeZone = .current) -> String {
        "olcrtc-all-logs-v\(safeToken(version))-b\(safeToken(build))-\(fileStamp(date, timeZone: timeZone)).log"
    }

    /// The self-describing header block prepended to an exported log. `first`/`last`
    /// bound the capture window (nil when the log is empty). `order` states the line
    /// order so a reader never has to infer it.
    static func header(title: String, fileName: String,
                       version: String, build: String,
                       device: String, os: String,
                       lineCount: Int, first: Date?, last: Date?,
                       exportedAt: Date, timeZone: TimeZone = .current,
                       order: String = "newest first") -> String {
        let bar = String(repeating: "═", count: 52)
        let thin = String(repeating: "─", count: 52)
        func row(_ k: String, _ v: String) -> String {
            " " + k.padding(toLength: 10, withPad: " ", startingAt: 0) + ": " + v
        }
        let range: String
        if let f = first, let l = last {
            range = "\(headerStamp(f, timeZone: timeZone)) … \(headerStamp(l, timeZone: timeZone))"
        } else {
            range = "(empty)"
        }
        return [
            bar,
            " olcrtc-ios · diagnostic log export",
            thin,
            row("Log", title),
            row("File", fileName),
            row("App", "olcrtc-ios \(version) (build \(build))"),
            row("Device", "\(device) · \(os)"),
            row("Exported", headerStamp(exportedAt, timeZone: timeZone)),
            row("Lines", "\(lineCount)"),
            row("Range", range),
            row("Order", order),
            bar,
        ].joined(separator: "\n")
    }

    private static func stampFormatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }

    // MARK: - Environment (thin, non-pure)

    static func appVersionBuild() -> (version: String, build: String) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return (v, b)
    }

    /// The hardware model identifier (e.g. "iPhone15,2"), or the simulator's
    /// modelled device when running on the simulator.
    static func deviceModel() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var sys = utsname()
        uname(&sys)
        let chars = Mirror(reflecting: sys.machine).children.compactMap { child -> Character? in
            guard let code = child.value as? Int8, code != 0 else { return nil }
            return Character(UnicodeScalar(UInt8(code)))
        }
        let id = String(chars)
        return id.isEmpty ? "unknown" : id
    }

    static func osString() -> String {
        #if canImport(UIKit)
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        return "\(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }

    // MARK: - File I/O

    /// Header + newest-first body for one log, as a self-contained string (used by
    /// both the file export and the "Copy all" clipboard action so the pasted text
    /// is just as identifiable as the file).
    @MainActor
    static func rendered(title: String, displayFileName: String, entries: [LogEntry],
                         now: Date = Date()) -> String {
        let (version, build) = appVersionBuild()
        let dates = entries.map(\.date)
        let head = header(title: title, fileName: displayFileName,
                          version: version, build: build,
                          device: deviceModel(), os: osString(),
                          lineCount: entries.count, first: dates.min(), last: dates.max(),
                          exportedAt: now)
        let body = LogRendering.plain(entries.reversed())   // newest-first, matches the on-screen order
        return head + "\n\n" + body + "\n"
    }

    /// Writes one log to a named temp file and returns its URL for ShareLink.
    @MainActor
    static func exportCurrent(title: String, label: String,
                              displayFileName: String, entries: [LogEntry]) -> URL? {
        let now = Date()
        let (version, build) = appVersionBuild()
        let name = fileName(label: label, version: version, build: build, date: now)
        return writeTemp(name: name,
                         contents: rendered(title: title, displayFileName: displayFileName,
                                            entries: entries, now: now))
    }

    /// Bundles every non-empty log into ONE combined file with a top banner and a
    /// per-section header, so the whole diagnostic picture ships in a single share.
    @MainActor
    static func exportAll(sections: [Section]) -> URL? {
        let now = Date()
        let (version, build) = appVersionBuild()
        let nonEmpty = sections.filter { !$0.entries.isEmpty }
        let totalLines = nonEmpty.reduce(0) { $0 + $1.entries.count }
        let allDates = nonEmpty.flatMap { $0.entries.map(\.date) }

        let bar = String(repeating: "█", count: 52)
        var parts: [String] = [
            bar,
            " olcrtc-ios · FULL diagnostic log export (\(nonEmpty.count) logs)",
            header(title: "All logs", fileName: combinedFileName(version: version, build: build, date: now),
                   version: version, build: build,
                   device: deviceModel(), os: osString(),
                   lineCount: totalLines, first: allDates.min(), last: allDates.max(),
                   exportedAt: now),
            bar,
            "",
        ]
        if nonEmpty.isEmpty {
            parts.append("(no log entries captured)")
        }
        for section in nonEmpty {
            parts.append("")
            parts.append(rendered(title: section.title, displayFileName: section.file,
                                  entries: section.entries, now: now))
        }
        return writeTemp(name: combinedFileName(version: version, build: build, date: now),
                         contents: parts.joined(separator: "\n"))
    }

    /// Writes `contents` into a per-session temp subfolder and returns the URL.
    /// Sweeps exports older than an hour first so the folder can't accumulate
    /// across many sessions (the OS also purges the temp dir, but this keeps it
    /// tidy between shares).
    private static func writeTemp(name: String, contents: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sweepOld(in: dir, olderThan: 3600)
        let url = dir.appendingPathComponent(name)
        do {
            try Data(contents.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func sweepOld(in dir: URL, olderThan seconds: TimeInterval) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for f in files {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }
}
