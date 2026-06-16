import Foundation

// MARK: - UpdateChecker (#360)
//
// Sideloaded users get no App Store update signal, so this polls the repo's
// GitHub Releases for a newer build and, when one exists, surfaces an
// "Update available" sheet that links the install actions release.yml already
// emits (the release page + the sidestore:///livecontainer:// deep links to
// the unsigned .ipa). CHECK-AND-LINK ONLY — a sandboxed sideload can't
// download/install itself, so there is no in-app updater.
//
// Privacy (zero-tracking stance): the request is an unauthenticated GET to the
// public releases endpoint with no body, no install id, no query params — the
// only thing it reveals is "an olcrtc-ios is asking GitHub for the latest
// release", which is unavoidable for any update check. It is opt-out via
// `SettingsStore.updateCheckEnabled` and interval-gated so it runs at most once
// per `checkInterval`. Network failures are swallowed silently.
//
// The version-compare and interval-due logic are pure static functions
// (`isNewer`, `isCheckDue`) so they are unit-tested without hitting the network.

@MainActor
final class UpdateChecker: ObservableObject {

    /// Parsed result of a successful check that found a newer release. Drives
    /// the sheet in the UI; nil means "no update to show".
    struct Available: Identifiable, Equatable {
        let id = UUID()
        let version: String           // display tag, e.g. "1.4" (leading "v" stripped)
        let releasePageURL: URL       // the GitHub Release page
        let sideStoreURL: URL?        // sidestore://install?url=<ipa>
        let liveContainerURL: URL?    // livecontainer://install?url=<ipa>

        static func == (lhs: Available, rhs: Available) -> Bool {
            lhs.version == rhs.version
        }
    }

    /// Set when a newer release is found; the App-root `.sheet` observes it.
    @Published var available: Available?

    // MARK: Config

    /// Once per 24h. Stored as a constant (not user-tunable) — the only thing
    /// the user controls is the on/off toggle. `nonisolated` so the pure
    /// `isCheckDue` helper and the unit tests can read it off the MainActor.
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Short timeout — a missed check just retries on the next launch, so there
    /// is no reason to make the user wait.
    private static let requestTimeout: TimeInterval = 10

    // MARK: Entry point

    /// Interval-gated check. No-op when the feature is off or a check ran
    /// within `checkInterval`. Tolerates every failure silently (the whole
    /// body is wrapped — a broken response must never disturb the app).
    /// Records `lastCheck` only on a completed network round-trip, so a
    /// failed attempt retries on the next launch rather than waiting 24h.
    func checkIfDue(settings: SettingsStore = .shared, now: Date = Date()) async {
        guard settings.updateCheckEnabled else { return }
        let last = settings.lastUpdateCheck
        guard Self.isCheckDue(lastCheck: last, now: now, interval: Self.checkInterval) else { return }

        guard let tag = await Self.fetchLatestTag() else { return }   // silent on failure
        settings.lastUpdateCheck = now

        let current = Self.currentVersion()
        guard Self.isNewer(latestTag: tag, thanCurrent: current) else { return }

        let version = Self.normalize(tag)
        available = Available(
            version: version,
            releasePageURL: AppConstants.Update.releasePageURL(tag: tag),
            sideStoreURL: AppConstants.Update.sideStoreURL(tag: tag),
            liveContainerURL: AppConstants.Update.liveContainerURL(tag: tag))
        LogStore.shared.log(.connection, "⬆ Update available: \(version) (running \(current))")
    }

    // MARK: Network (impure; not exercised by tests)

    /// GETs `…/releases/latest` and returns the release tag, or nil on any
    /// failure (no network, blocked, non-2xx, malformed JSON, no releases).
    private static func fetchLatestTag() async -> String? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        var req = URLRequest(url: AppConstants.Update.latestReleaseAPIURL,
                             timeoutInterval: requestTimeout)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // GitHub recommends an explicit Accept for the REST API. No auth header,
        // no user-specific data — the call is anonymous (#360 privacy).
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let release = try? JSONDecoder().decode(LatestRelease.self, from: data)
        else { return nil }

        // `tag_name` is authoritative (e.g. "v1.4"); `name` is the title, used
        // as a fallback if a release ever ships without a tag in the payload.
        let tag = release.tag_name ?? release.name
        guard let tag, !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return tag
    }

    private struct LatestRelease: Decodable {
        let tag_name: String?
        let name: String?
    }

    // MARK: Pure helpers (unit-tested)

    /// The running app version, as `MARKETING_VERSION.BUILD` (e.g. "1.3.253").
    /// #404: releases are tagged `vMARKETING.BUILD` (the maintainer's annotated
    /// `git tag -a v1.3.253`), so the comparison must include the build number.
    /// #404 was: `CFBundleShortVersionString` alone (e.g. "1.3") — the tag's
    /// trailing build segment then always read as a newer trailing version, so
    /// `isNewer` returned true and the "Update available" sheet showed on every
    /// launch even when the installed build IS the latest release.
    nonisolated static func currentVersion() -> String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(marketing).\(build)"
    }

    /// True when `now` is at least `interval` after `lastCheck`. A nil
    /// `lastCheck` (never checked) is always due.
    nonisolated static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// True when `latestTag` (the release tag, with or without a leading "v") is
    /// strictly newer than `current` (the running marketing version). Compares
    /// dotted numeric segments left-to-right; missing trailing segments count as
    /// 0 (so "1.4" > "1.3" and "1.4.1" > "1.4"). Non-numeric/garbage input is
    /// treated conservatively as "not newer" so a malformed tag never nags.
    nonisolated static func isNewer(latestTag: String, thanCurrent current: String) -> Bool {
        let latest = segments(normalize(latestTag))
        let running = segments(normalize(current))
        guard !latest.isEmpty, !running.isEmpty else { return false }
        let count = max(latest.count, running.count)
        for i in 0..<count {
            let l = i < latest.count ? latest[i] : 0
            let r = i < running.count ? running[i] : 0
            if l != r { return l > r }
        }
        return false   // equal
    }

    /// Strips a single leading "v"/"V" and surrounding whitespace from a tag.
    nonisolated static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first == "v" || first == "V" {
            t.removeFirst()
        }
        return t
    }

    /// Splits "1.4.2" → [1, 4, 2]. Returns [] if any segment is non-numeric,
    /// which `isNewer` treats as "can't compare → not newer".
    nonisolated private static func segments(_ version: String) -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p) else { return [] }
            out.append(n)
        }
        return out
    }
}
