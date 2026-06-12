import SwiftUI
import UIKit  // #340: UIColor trait closures back the dynamic light/dark tokens

// #258: Design-system tokens — the single source of truth for color, spacing,
// shape, and type. App/UI/DesignSystem.swift and (later) every screen read from
// here instead of hardcoding `.controlSize(...)`, ad-hoc hex, or per-call tints.
//
// Values come from design_handoff_ui_redesign, "Refined" direction (the handoff
// default: pure-black ground, soft borderless cards). Where the handoff's hex
// matches an iOS system color we use the *semantic* color — noted per token — so
// Dynamic Type, contrast, and the dark palette keep working.
// #340 was: "The app is dark-only; this palette is authored for the dark
// appearance" — light values come from design_handoff_logs_theme §4; the
// appearance now follows SettingsStore.appearanceMode (System/Light/Dark)
// via preferredColorScheme in App.swift. Semantic system colors adapt for
// free; the handful of hardcoded grounds are dynamic via UIColor traits.
//
// To switch to the "Console" direction later, change only the values marked
// `Console:` below (cooler ground, hairline card border, tighter radii).

enum Theme {

    // #267: runtime design direction (Refined default / Console). The few tokens
    // that differ read the live setting, so the Settings picker reskins the app.
    fileprivate static var console: Bool { SettingsStore.shared.designConsole }

    /// #340: dark/light pair → one Color that resolves per the active trait.
    fileprivate static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    // MARK: - Colors
    enum Palette {
        // Grounds & surfaces (bg/card/segActive switch with the direction).
        // #340: light values per the handoff §4 token table.
        // #340 was: bg = console ? Color(hex: 0x0B0D10) : .black (dark-only)
        static var bg        : Color {
            Theme.console
                ? Theme.dynamic(dark: UIColor(hex: 0x0B0D10), light: UIColor(hex: 0xEDEFF2))
                : Theme.dynamic(dark: .black, light: .systemGroupedBackground)   // light = #F2F2F7
        }
        // #340 was: card = console ? Color(hex: 0x15181D) : …(already adaptive)
        static var card      : Color {
            Theme.console
                ? Theme.dynamic(dark: UIColor(hex: 0x15181D), light: .white)
                : Color(.secondarySystemGroupedBackground)
        }
        static let fill      = Color(.tertiarySystemFill)                // rgba(118,118,128,0.22) — secondary-button / chip fill
        // #340 was: segActive = console ? 0x2A2F37 : 0x48484A (dark-only);
        // light = white in both directions (+ OlcSegmented's existing soft shadow)
        static var segActive : Color {
            Theme.console
                ? Theme.dynamic(dark: UIColor(hex: 0x2A2F37), light: .white)
                : Theme.dynamic(dark: UIColor(hex: 0x48484A), light: .white)
        }
        /// #340: Console card hairline — was hardcoded `Color.white.opacity(0.16)`
        /// in OlcCard (#281 bumped dark from the handoff's 8% for visibility);
        /// light uses the handoff's black 8%.
        static var cardBorder: Color {
            Theme.dynamic(dark: UIColor.white.withAlphaComponent(0.16),
                          light: UIColor.black.withAlphaComponent(0.08))
        }
        static let separator = Color(.separator)                         // rgba(84,84,88,0.5)

        // Text
        static let textPrimary   = Color.primary           // #FFFFFF
        static let textSecondary = Color.secondary         // rgba(235,235,245,0.62)
        static let textTertiary  = Color(.tertiaryLabel)   // rgba(235,235,245,0.32)

        // Accent + the ONE status vocabulary (unknown = gray, progress = amber,
        // ok = green, warn = orange, error = red), used identically everywhere.
        static let accent = Color.accentColor   // #0A84FF — existing AccentColor asset
        static let green  = Color.green          // #30D158
        static let amber  = Color.yellow         // #FFD60A
        static let orange = Color.orange         // #FF9F0A
        static let red    = Color.red            // #FF453A

        // Tinted (weak) fills
        static let redWeak  = Color.red.opacity(0.16)      // danger-button background
        static let star     = Color.yellow                 // #FFD60A — primary marker
        static let starWeak = Color.yellow.opacity(0.16)
    }

    // MARK: - Metrics (spacing / shape)
    enum Metrics {
        static let controlHeight:   CGFloat = 44   // every button, always
        // #281: Console is the sharp, dense, terminal direction — tight radii,
        // a visible hairline card border, and denser spacing — so it reads
        // clearly different from Refined (soft, borderless, roomy). Previously
        // the two differed by only 2pt/0.5pt and looked identical.
        static var controlRadius:   CGFloat { Theme.console ? 5  : 13 }
        static var cardRadius:      CGFloat { Theme.console ? 7  : 20 }
        static var cardPadding:     CGFloat { Theme.console ? 12 : 16 }
        static var cardBorderWidth: CGFloat { Theme.console ? 1  : 0 }
        static var rowMinHeight:    CGFloat { Theme.console ? 44 : 52 }
        static var sectionGap:      CGFloat { Theme.console ? 14 : 22 }
        static var segmentedRadius: CGFloat { Theme.console ? 5  : 10 }
        static let chipHeight:      CGFloat = 34   // handoff range 32–38
    }

    // MARK: - Type
    // Mapped to Dynamic Type text styles (not fixed points) so the app's existing
    // font-size slider — `.dynamicTypeSize(...)` in App.swift — keeps scaling
    // these. Approx. handoff sizes noted in comments.
    enum Typography {
        static let largeTitle     = Font.largeTitle.bold()                                    // 32 / 800
        static let button         = Font.callout.weight(.semibold)                            // ~16 / 600
        static let statusTitle    = Font.subheadline.weight(.semibold)                        // ~15 / 600
        // #281: Console reskins the caption-level labels to monospaced for its
        // terminal feel; Refined keeps the proportional system font.
        static var statusSubtitle: Font { Theme.console ? Font.system(.caption, design: .monospaced) : Font.caption }
        static var sectionHeader:  Font { Theme.console ? Font.system(.caption, design: .monospaced).weight(.semibold) : Font.caption.weight(.semibold) }
        static let chip           = Font.subheadline.weight(.semibold)                        // ~14 / 600
        static let segment        = Font.subheadline.weight(.semibold)                        // ~14 / 600
        static let metricLabel    = Font.caption2.weight(.semibold)                           // ~11 / 600 (tracked + uppercased)
        static let metricValue    = Font.system(.body, design: .monospaced).weight(.semibold) // ~17 / 600 mono
    }
}

extension Color {
    /// `0xRRGGBB` literal → opaque sRGB Color. Used only for the handful of tokens
    /// with no iOS system-color equivalent (e.g. the segmented control's active
    /// fill). Prefer a semantic `Color(.xxx)` whenever one matches.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

extension UIColor {
    /// #340: UIColor twin of `Color(hex:)` — the dynamic light/dark tokens are
    /// built from UIColor trait closures, which need UIColor end points.
    convenience init(hex: UInt32) {
        self.init(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8)  & 0xFF) / 255,
                  blue:  CGFloat( hex        & 0xFF) / 255,
                  alpha: 1)
    }
}
