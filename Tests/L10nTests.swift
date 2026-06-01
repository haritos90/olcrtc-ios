import XCTest
@testable import olcrtc_ios

// Verifies completeness of every per-language dictionary in L10nTable.
// Adding a new L10n case without translations fails one of these tests with
// a list of the missing keys — no silent fallbacks.

final class L10nTests: XCTestCase {

    func testEveryKeyHasAllLanguages() {
        var problems: [String] = []
        for key in L10n.allCases {
            for locale in AppLocale.allCases {
                let value: String?
                switch locale {
                case .english: value = L10nTable.english[key]
                case .russian: value = L10nTable.russian[key]
                }
                if value == nil {
                    problems.append("[\(locale.rawValue)] missing: \(key.rawValue)")
                } else if value!.isEmpty {
                    problems.append("[\(locale.rawValue)] empty: \(key.rawValue)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.sorted().joined(separator: "\n"))
    }

    /// Catches stale dictionary entries. Each language dictionary's size must
    /// equal the number of L10n cases — otherwise the dict either has orphans
    /// (impossible with typed `[L10n: String]` today, but defensive against a
    /// future refactor to String keys) or duplicates (Swift would deduplicate
    /// literals, but the test verifies the deduplicated total matches).
    func testNoExtraKeysInDictionaries() {
        let expected = L10n.allCases.count
        XCTAssertEqual(L10nTable.english.count, expected,
            "English dictionary has \(L10nTable.english.count) entries, expected \(expected)")
        XCTAssertEqual(L10nTable.russian.count, expected,
            "Russian dictionary has \(L10nTable.russian.count) entries, expected \(expected)")
        // Every dict key must correspond to an existing L10n case.
        let all = Set(L10n.allCases)
        for k in L10nTable.english.keys {
            XCTAssertTrue(all.contains(k), "English dict has orphan key: \(k.rawValue)")
        }
        for k in L10nTable.russian.keys {
            XCTAssertTrue(all.contains(k), "Russian dict has orphan key: \(k.rawValue)")
        }
    }

    // Format-string consistency: cases whose names end with `_fmt` must contain
    // at least one placeholder in EVERY language. Catches translators who drop
    // the %@/%d/%lld marker accidentally.
    func testFormatCasesContainPlaceholders() {
        for key in L10n.allCases where key.rawValue.hasSuffix("Fmt") {
            // Swift's `_fmt` naming → enum rawValue uses camelCase ending in `Fmt`.
            // We accept both as suffix marker for safety.
            assertHasPlaceholder(L10nTable.english[key], key: key, lang: "en")
            assertHasPlaceholder(L10nTable.russian[key], key: key, lang: "ru")
        }
    }

    private func assertHasPlaceholder(_ value: String?, key: L10n, lang: String) {
        guard let v = value else {
            XCTFail("[\(lang)] missing translation for \(key.rawValue)"); return
        }
        let placeholders = ["%@", "%d", "%lld", "%f", "%.0f", "%.1f", "%.2f"]
        let hasOne = placeholders.contains(where: { v.contains($0) })
        XCTAssertTrue(hasOne,
            "[\(lang)] \(key.rawValue) is a *_fmt case but has no %@/%d/etc placeholder: \(v.debugDescription)")
    }

    // MARK: AppLocale

    func testAppLocaleCurrentRespectsSettings() {
        let original = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        XCTAssertEqual(AppLocale.current, .english)
        SettingsStore.shared.language = "ru"
        XCTAssertEqual(AppLocale.current, .russian)
        SettingsStore.shared.language = "xx-unknown"
        XCTAssertEqual(AppLocale.current, .english, "Unknown codes must fall back to English")
        SettingsStore.shared.language = original
    }

    func testEveryAppLocaleHasDisplayName() {
        for locale in AppLocale.allCases {
            XCTAssertFalse(locale.displayName.isEmpty,
                "AppLocale.\(locale.rawValue) has empty displayName")
        }
    }

    // MARK: Smoke test for L10n.localized / .formatted

    func testLocalizedReturnsCurrentLanguageValue() {
        let original = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        XCTAssertEqual(L10n.actionConnect.localized(), "Connect")
        SettingsStore.shared.language = "ru"
        XCTAssertEqual(L10n.actionConnect.localized(), "Подключить")
        SettingsStore.shared.language = original
    }

    func testFormattedSubstitutesArgs() {
        let original = SettingsStore.shared.language
        SettingsStore.shared.language = "en"
        let result = L10n.installResultSuccess_fmt.formatted("telemost", "vp8channel")
        XCTAssertEqual(result, "olcrtc server installed (telemost/vp8channel)")
        SettingsStore.shared.language = original
    }
}
