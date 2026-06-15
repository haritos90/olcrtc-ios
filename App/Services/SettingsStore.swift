import Foundation
import SwiftUI

// MARK: - LogLevel

enum LogLevel: Int, CaseIterable, Codable, Comparable {
    case off     = 0
    case error   = 1
    case info    = 2   // current level (non-debug)
    case debug   = 3   // current debugLogging=true
    case verbose = 4   // everything including Pion noise

    var label: String {
        switch self {
        case .off:     return "Off"
        case .error:   return "Errors only"
        case .info:    return "Normal"
        case .debug:   return "Debug"
        case .verbose: return "Verbose (all)"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - AppearanceMode (#340)

/// App appearance: System follows iOS, Light/Dark force a scheme. Replaces
/// the Info.plist `UIUserInterfaceStyle = Dark` enforcement (project.yml);
/// applied via `.preferredColorScheme` on the root in App.swift.
/// #299: `.gray` is a real third colour scheme — it forces dark system chrome
/// but swaps the pure-black grounds for neutral mid-gray (see `Theme.isGray`).
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.appearanceSystem.localized()
        case .light:  return L10n.appearanceLight.localized()
        case .dark:   return L10n.appearanceDark.localized()
        case .gray:   return L10n.appearanceGray.localized()   // #299
        }
    }

    /// nil = follow the system appearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        // #299: Gray keeps dark system chrome (the mid-gray grounds are dark-side).
        case .dark, .gray: return .dark
        }
    }
}

// MARK: - SettingsStore
//
// Singleton ObservableObject for app-wide preferences. UserDefaults is the
// source of truth — @Published mirrors it so SwiftUI views can observe and
// non-view callers (TunnelManager, SOCKSSession) can read synchronously.
//
// Numeric properties clamp themselves in didSet: any out-of-range write
// (from UserDefaults corruption or code bugs) is silently corrected before
// reaching the Go runtime or SSH layer.
//
// UserDefaults writes are dispatched to a serial background queue so a
// slider drag (which fires didSet ~60×/sec) doesn't block the MainActor on
// the `CFPreferences` plumbing. Order is preserved because the queue is
// serial — the last write to a key wins, matching the synchronous semantics.

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: Defaults

    enum Defaults {
        static let socksPort            = 8808          // arbitrary, avoids common app ports
        static let socksPortRange       = 1024...65535
        static let dnsServer            = "77.88.8.8:53" // Yandex — reliable from RU VPS
        static let startTimeoutSeconds  = 60
        static let startTimeoutRange    = 5...600
        static let keepAliveSeconds     = 30            // 0 = disabled
        static let keepAliveRange       = 0...300
        static let vp8FPS               = 60            // Telemost/wbstream room limit
        static let vp8FPSRange          = 1...60
        static let vp8BatchSize         = 64            // tested on Telemost + wbstream
        static let vp8BatchRange        = 1...256
        static let logBufferSize        = 5000
        static let logBufferRange       = 50...10000
        static let containerLogsTail    = 200
        static let containerLogsTailRange = 50...2000
        static let fontSizeIndex        = 3
        static let vpsAutoPingEnabled   = true
        static let vpsAutoPingInterval  = 30
        static let vpsAutoPingRange     = 10...300
        static let updateCheckEnabled   = true          // #360: opt-out
    }

    // MARK: Persistence dispatch
    //
    // Serial queue guarantees FIFO ordering: multiple rapid writes to the
    // same key (slider drag → settle) end with the final value persisted.
    // `Task.detached` would not give that guarantee.

    private static let writeQueue = DispatchQueue(label: "olcrtc.settings.userdefaults")

    private static func persist<T>(_ value: T, forKey key: String) {
        writeQueue.async {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    /// #360: persist a nullable value — store it when present, remove the key
    /// when nil. The generic `persist` would store a wrapped `Optional.none`,
    /// which `object(forKey:)` reads back as non-nil. Used for `lastUpdateCheck`.
    private static func persistOptionalDate(_ value: Date?, forKey key: String) {
        writeQueue.async {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Test-only synchronization point — blocks until the write queue drains.
    /// NOT for production code. Used by `SettingsStoreTests` to assert that
    /// a clamp's persistence side-effect has landed in UserDefaults.
    static func flushPendingWrites() {
        writeQueue.sync { }
    }

    // MARK: Published properties

    @Published var socksPort: Int {
        didSet {
            let v = socksPort.clamped(to: Defaults.socksPortRange)
            if v != socksPort { socksPort = v } else { Self.persist(socksPort, forKey: Keys.socksPort) }
        }
    }
    @Published var fontSizeIndex: Int {
        didSet {
            let v = fontSizeIndex.clamped(to: 0...(Self.fontSizes.count - 1))
            if v != fontSizeIndex { fontSizeIndex = v } else { Self.persist(fontSizeIndex, forKey: Keys.fontSizeIndex) }
        }
    }
    @Published var dnsServer: String {
        didSet { Self.persist(dnsServer, forKey: Keys.dnsServer) }
    }
    @Published var logLevel: LogLevel {
        didSet { Self.persist(logLevel.rawValue, forKey: Keys.logLevel) }
    }

    /// Backward-compatibility shim. True when log level is debug or higher.
    var debugLogging: Bool { logLevel >= .debug }

    @Published var startTimeoutSeconds: Int {
        didSet {
            let v = startTimeoutSeconds.clamped(to: Defaults.startTimeoutRange)
            if v != startTimeoutSeconds { startTimeoutSeconds = v } else { Self.persist(startTimeoutSeconds, forKey: Keys.startTimeout) }
        }
    }
    @Published var vp8FPS: Int {
        didSet {
            let v = vp8FPS.clamped(to: Defaults.vp8FPSRange)
            if v != vp8FPS { vp8FPS = v } else { Self.persist(vp8FPS, forKey: Keys.vp8FPS) }
        }
    }
    @Published var vp8BatchSize: Int {
        didSet {
            let v = vp8BatchSize.clamped(to: Defaults.vp8BatchRange)
            if v != vp8BatchSize { vp8BatchSize = v } else { Self.persist(vp8BatchSize, forKey: Keys.vp8BatchSize) }
        }
    }
    @Published var logBufferSize: Int {
        didSet {
            let v = logBufferSize.clamped(to: Defaults.logBufferRange)
            if v != logBufferSize { logBufferSize = v } else { Self.persist(logBufferSize, forKey: Keys.logBufferSize) }
        }
    }
    @Published var containerLogsTailLines: Int {
        didSet {
            let v = containerLogsTailLines.clamped(to: Defaults.containerLogsTailRange)
            if v != containerLogsTailLines { containerLogsTailLines = v } else { Self.persist(containerLogsTailLines, forKey: Keys.containerLogsTail) }
        }
    }
    @Published var autoConnectOnLaunch: Bool {
        didSet { Self.persist(autoConnectOnLaunch, forKey: Keys.autoConnectOnLaunch) }
    }
    @Published var autoRemoveConnectionOnUninstall: Bool {
        didSet { Self.persist(autoRemoveConnectionOnUninstall, forKey: Keys.autoRemoveConnectionOnUninstall) }
    }
    @Published var backgroundAudio: Bool {
        didSet { Self.persist(backgroundAudio, forKey: Keys.backgroundAudio) }
    }
    /// #337: screenshot-safe mode — when true, IP addresses in the Connections
    /// diagnostics and on VPS cards are masked for display only (copy actions
    /// and stored values stay real; Logs are deliberately never masked).
    @Published var maskIPs: Bool {
        didSet { Self.persist(maskIPs, forKey: Keys.maskIPs) }
    }
    @Published var localSocksAuthEnabled: Bool {
        didSet { Self.persist(localSocksAuthEnabled, forKey: Keys.localSocksAuthEnabled) }
    }
    @Published var localSocksUser: String {
        didSet { Self.persist(localSocksUser, forKey: Keys.localSocksUser) }
    }
    /// Password is NOT @Published — stored and read via Keychain only.
    var localSocksPass: String {
        get { KeychainHelper.get(service: "olcrtc.local.socks", account: "password") ?? "" }
        set { _ = KeychainHelper.set(newValue, service: "olcrtc.local.socks", account: "password") }
    }
    @Published var vpsAutoPingEnabled: Bool {
        didSet { Self.persist(vpsAutoPingEnabled, forKey: Keys.vpsAutoPingEnabled) }
    }
    @Published var vpsAutoPingInterval: Int {
        didSet {
            let v = vpsAutoPingInterval.clamped(to: Defaults.vpsAutoPingRange)
            if v != vpsAutoPingInterval { vpsAutoPingInterval = v } else { Self.persist(vpsAutoPingInterval, forKey: Keys.vpsAutoPingInterval) }
        }
    }
    /// Language code consumed by `L10n.localized()` via `AppLocale.current`.
    /// Empty / unknown values fall back to English at the resolver layer.
    @Published var language: String {
        didSet { Self.persist(language, forKey: Keys.language) }
    }
    // #299 was: @Published var designConsole — the Refined/Console "design
    // direction" (#267/#281) that only reskinned shape, never colours. Removed
    // when Theme switched to real colour schemes (System/Light/Dark/Gray).
    /// #340: appearance (System/Light/Dark/Gray). Defaults to .dark — the app was
    /// forced-dark until now, so existing users see no change on update.
    @Published var appearanceMode: AppearanceMode {
        didSet { Self.persist(appearanceMode.rawValue, forKey: Keys.appearanceMode) }
    }
    @Published var keepAliveSeconds: Int {
        didSet {
            let v = keepAliveSeconds.clamped(to: Defaults.keepAliveRange)
            if v != keepAliveSeconds { keepAliveSeconds = v } else { Self.persist(keepAliveSeconds, forKey: Keys.keepAlive) }
        }
    }
    /// #286: which `AppConstants.ipCheckServices` labels the IP check queries.
    /// Persisted as an array (Set isn't a plist type). An empty set falls back
    /// to the defaults at query time so the check never silently does nothing.
    @Published var enabledIPSources: Set<String> {
        didSet { Self.persist(Array(enabledIPSources), forKey: Keys.enabledIPSources) }
    }
    /// #285: which speed-test provider a run uses (id into `AppConstants.SpeedTest.providers`).
    @Published var speedTestProviderID: String {
        didSet { Self.persist(speedTestProviderID, forKey: Keys.speedTestProviderID) }
    }
    /// #360: opt-out toggle for the in-app GitHub-Releases update check. The
    /// check is anonymous (no install id), interval-gated, and fails silently —
    /// this is the only user control over it.
    @Published var updateCheckEnabled: Bool {
        didSet { Self.persist(updateCheckEnabled, forKey: Keys.updateCheckEnabled) }
    }
    /// #360: timestamp of the last *completed* update check (nil = never).
    /// Drives the 24h interval gate so the network call runs at most once a day.
    /// Persisted explicitly (write the Date / remove the key) rather than via the
    /// generic `persist`, which would wrap a nil `Date?` in a double-optional that
    /// `UserDefaults.set` can't store cleanly.
    @Published var lastUpdateCheck: Date? {
        didSet { Self.persistOptionalDate(lastUpdateCheck, forKey: Keys.lastUpdateCheck) }
    }

    // MARK: Init

    private init() {
        let d = UserDefaults.standard
        // Clamp on read — guards against UserDefaults corruption or values
        // written by older app versions outside the current valid range.
        socksPort           = (d.object(forKey: Keys.socksPort)           as? Int)  .map { $0.clamped(to: Defaults.socksPortRange) }       ?? Defaults.socksPort
        fontSizeIndex       = (d.object(forKey: Keys.fontSizeIndex)       as? Int)  .map { $0.clamped(to: 0...(Self.fontSizes.count-1)) }   ?? Defaults.fontSizeIndex
        dnsServer           =  d.string(forKey: Keys.dnsServer)                                                                              ?? Defaults.dnsServer
        // Migration: old Bool key → new Int enum. If neither exists, default to .info.
        if let raw = d.object(forKey: Keys.logLevel) as? Int, let level = LogLevel(rawValue: raw) {
            logLevel = level
        } else if let oldBool = d.object(forKey: Keys.debugLoggingLegacy) as? Bool {
            logLevel = oldBool ? .debug : .info
        } else {
            logLevel = .info
        }
        startTimeoutSeconds = (d.object(forKey: Keys.startTimeout)        as? Int)  .map { $0.clamped(to: Defaults.startTimeoutRange) }      ?? Defaults.startTimeoutSeconds
        vp8FPS              = (d.object(forKey: Keys.vp8FPS)              as? Int)  .map { $0.clamped(to: Defaults.vp8FPSRange) }            ?? Defaults.vp8FPS
        vp8BatchSize        = (d.object(forKey: Keys.vp8BatchSize)        as? Int)  .map { $0.clamped(to: Defaults.vp8BatchRange) }          ?? Defaults.vp8BatchSize
        logBufferSize       = (d.object(forKey: Keys.logBufferSize)       as? Int)  .map { $0.clamped(to: Defaults.logBufferRange) }         ?? Defaults.logBufferSize
        containerLogsTailLines = (d.object(forKey: Keys.containerLogsTail) as? Int) .map { $0.clamped(to: Defaults.containerLogsTailRange) } ?? Defaults.containerLogsTail
        autoConnectOnLaunch = (d.object(forKey: Keys.autoConnectOnLaunch) as? Bool)                                                          ?? false
        autoRemoveConnectionOnUninstall = (d.object(forKey: Keys.autoRemoveConnectionOnUninstall) as? Bool)                                  ?? true
        backgroundAudio          = (d.object(forKey: Keys.backgroundAudio)          as? Bool)   ?? false
        maskIPs                  = (d.object(forKey: Keys.maskIPs)                  as? Bool)   ?? false   // #337
        localSocksAuthEnabled    = (d.object(forKey: Keys.localSocksAuthEnabled)    as? Bool)   ?? false
        localSocksUser           = (d.string(forKey: Keys.localSocksUser))                      ?? ""
        language                 = (d.string(forKey: Keys.language))                            ?? Self.defaultLanguage()
        appearanceMode           = AppearanceMode(rawValue: d.string(forKey: Keys.appearanceMode) ?? "") ?? .dark   // #340
        keepAliveSeconds    = (d.object(forKey: Keys.keepAlive)           as? Int)  .map { $0.clamped(to: Defaults.keepAliveRange) }         ?? Defaults.keepAliveSeconds
        vpsAutoPingEnabled  = (d.object(forKey: Keys.vpsAutoPingEnabled)  as? Bool)                                                          ?? Defaults.vpsAutoPingEnabled
        vpsAutoPingInterval = (d.object(forKey: Keys.vpsAutoPingInterval) as? Int)  .map { $0.clamped(to: Defaults.vpsAutoPingRange) }       ?? Defaults.vpsAutoPingInterval
        if let arr = d.object(forKey: Keys.enabledIPSources) as? [String] {
            enabledIPSources = Set(arr)
        } else {
            enabledIPSources = AppConstants.defaultEnabledIPCheckLabels
        }
        speedTestProviderID = d.string(forKey: Keys.speedTestProviderID) ?? AppConstants.SpeedTest.defaultProviderID
        updateCheckEnabled  = (d.object(forKey: Keys.updateCheckEnabled) as? Bool)  ?? Defaults.updateCheckEnabled   // #360
        lastUpdateCheck     = d.object(forKey: Keys.lastUpdateCheck)     as? Date                                    // #360 (nil = never)
    }

    // MARK: Reset

    /// Restores all settings to their default values and persists them.
    func reset() {
        socksPort              = Defaults.socksPort
        fontSizeIndex          = Defaults.fontSizeIndex
        dnsServer              = Defaults.dnsServer
        logLevel               = .info
        startTimeoutSeconds    = Defaults.startTimeoutSeconds
        vp8FPS                 = Defaults.vp8FPS
        vp8BatchSize           = Defaults.vp8BatchSize
        logBufferSize          = Defaults.logBufferSize
        containerLogsTailLines = Defaults.containerLogsTail
        autoConnectOnLaunch    = false
        autoRemoveConnectionOnUninstall = true
        backgroundAudio        = false
        maskIPs                = false   // #337
        localSocksAuthEnabled  = false
        localSocksUser         = ""
        language               = Self.defaultLanguage()
        appearanceMode         = .dark   // #340
        keepAliveSeconds       = Defaults.keepAliveSeconds
        vpsAutoPingEnabled     = Defaults.vpsAutoPingEnabled
        vpsAutoPingInterval    = Defaults.vpsAutoPingInterval
        enabledIPSources       = AppConstants.defaultEnabledIPCheckLabels
        speedTestProviderID    = AppConstants.SpeedTest.defaultProviderID
        updateCheckEnabled     = Defaults.updateCheckEnabled   // #360
        lastUpdateCheck        = nil                           // #360: re-arm the check
    }

    /// Picks Russian if the device's preferred language starts with `ru`,
    /// otherwise English. Called from init() and reset().
    private static func defaultLanguage() -> String {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("ru") ? "ru" : "en"
    }

    // MARK: Font

    static let fontSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]

    static let fontSizeLabels: [String] = [
        "XS", "S", "M", "L", "XL", "XXL", "XXXL"
    ]

    var resolvedTypeSize: DynamicTypeSize {
        Self.fontSizes[fontSizeIndex.clamped(to: 0...(Self.fontSizes.count - 1))]
    }

    // MARK: Keys

    private enum Keys {
        static let socksPort           = "settings.socksPort"
        static let fontSizeIndex       = "settings.fontSizeIndex"
        static let dnsServer           = "settings.dnsServer"
        static let logLevel              = "settings.logLevel"
        static let debugLoggingLegacy    = "settings.debugLogging"   // migration only
        static let startTimeout        = "settings.startTimeoutSeconds"
        static let vp8FPS              = "settings.vp8FPS"
        static let vp8BatchSize        = "settings.vp8BatchSize"
        static let logBufferSize       = "settings.logBufferSize"
        static let containerLogsTail   = "settings.containerLogsTailLines"
        static let autoConnectOnLaunch = "settings.autoConnectOnLaunch"
        static let autoRemoveConnectionOnUninstall = "settings.autoRemoveConnectionOnUninstall"
        static let backgroundAudio           = "settings.backgroundAudio"
        static let maskIPs                   = "settings.maskIPs"   // #337
        static let localSocksAuthEnabled     = "settings.localSocksAuthEnabled"
        static let localSocksUser            = "settings.localSocksUser"
        static let language                  = "settings.language"
        // #299 was: designConsole = "settings.designConsole" — direction removed.
        static let appearanceMode            = "settings.appearanceMode"   // #340
        static let keepAlive                 = "settings.keepAliveSeconds"
        static let vpsAutoPingEnabled        = "settings.vpsAutoPingEnabled"
        static let vpsAutoPingInterval       = "settings.vpsAutoPingInterval"
        static let enabledIPSources          = "settings.enabledIPSources"
        static let speedTestProviderID       = "settings.speedTestProviderID"
        static let updateCheckEnabled        = "settings.updateCheckEnabled"   // #360
        static let lastUpdateCheck           = "settings.lastUpdateCheck"      // #360
    }
}

// MARK: - Clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
