import SwiftUI

// #258: Design-system tokens — the single source of truth for color, spacing,
// shape, and type. App/UI/DesignSystem.swift and (later) every screen read from
// here instead of hardcoding `.controlSize(...)`, ad-hoc hex, or per-call tints.
//
// Values come from design_handoff_ui_redesign, "Refined" direction (the handoff
// default: pure-black ground, soft borderless cards). Where the handoff's hex
// matches an iOS system color we use the *semantic* color — noted per token — so
// Dynamic Type, contrast, and the dark palette keep working. The app is
// dark-only; this palette is authored for the dark appearance and the previews
// force it. Enforcing app-wide dark is a shell concern (App.swift), handled in a
// later step — not here.
//
// To switch to the "Console" direction later, change only the values marked
// `Console:` below (cooler ground, hairline card border, tighter radii).

enum Theme {

    // #267: runtime design direction (Refined default / Console). The few tokens
    // that differ read the live setting, so the Settings picker reskins the app.
    fileprivate static var console: Bool { SettingsStore.shared.designConsole }

    // MARK: - Colors
    enum Palette {
        // Grounds & surfaces (bg/card/segActive switch with the direction)
        static var bg        : Color { Theme.console ? Color(hex: 0x0B0D10) : .black }                              // Refined #000000
        static var card      : Color { Theme.console ? Color(hex: 0x15181D) : Color(.secondarySystemGroupedBackground) }
        static let fill      = Color(.tertiarySystemFill)                // rgba(118,118,128,0.22) — secondary-button / chip fill
        static var segActive : Color { Theme.console ? Color(hex: 0x2A2F37) : Color(hex: 0x48484A) }                // selected segment
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
        static var controlRadius:   CGFloat { Theme.console ? 11 : 13 }
        static var cardRadius:      CGFloat { Theme.console ? 14 : 20 }
        static let cardPadding:     CGFloat = 16
        static var cardBorderWidth: CGFloat { Theme.console ? 0.5 : 0 }
        static let rowMinHeight:    CGFloat = 52   // Compact density: 44
        static let sectionGap:      CGFloat = 22   // Compact density: 16
        static let segmentedRadius: CGFloat = 10
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
        static let statusSubtitle = Font.caption                                              // ~12.5
        static let sectionHeader  = Font.caption.weight(.semibold)                            // ~12.5 / 600 (tracked + uppercased by the view)
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
