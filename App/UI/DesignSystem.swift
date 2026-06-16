import SwiftUI

// #258: Design system — the reusable SwiftUI components every screen will adopt.
// One button system, one card, one section header, one status vocabulary, one
// overflow menu, one segmented control, one chip picker, one metric. They read
// only from `Theme` (App/UI/Theme.swift). No screen is touched yet; these are
// built and previewed in isolation. Component names map 1:1 to the prototype's
// `design_handoff_ui_redesign/app/ds.jsx`.

// MARK: - Shared

/// Press feedback shared by every tappable design-system surface (scale 0.96).
struct OlcPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A selectable option for `OlcSegmented` / `OlcChipPicker`. (Tuples can't back a
/// `ForEach(id:)` keypath, so options are modeled as an Identifiable value.)
struct OlcOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    /// #316: full name for VoiceOver when `label` is abbreviated (e.g. the
    /// Logs categories "Conn"/"Diag"). Nil = `label` is already the full name.
    var a11yLabel: String? = nil
    var id: Value { value }
}

// MARK: - 1. OlcButton
//
// The ONE button. Four roles, fixed 44pt height, one corner radius. Replaces
// every `.buttonStyle(.bordered)` + `.controlSize(...)` call in the codebase.

struct OlcButton: View {
    enum Role { case primary, secondary, danger, ghost }

    private let title: String?
    private let systemImage: String?
    private let role: Role
    private let isBusy: Bool
    private let fillWidth: Bool
    /// #342: 32pt inline-row variant (the hero's compact Retry) — same roles
    /// and chrome, smaller type/height, so it stays inside the button system.
    private let compact: Bool
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String? = nil,
         systemImage: String? = nil,
         role: Role = .secondary,
         isBusy: Bool = false,
         fillWidth: Bool = false,
         compact: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isBusy = isBusy
        self.fillWidth = fillWidth
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(OlcPressStyle())
            .disabled(isBusy)                       // busy = spinner + non-interactive…
            .opacity(isEnabled ? 1 : 0.4)           // …but only a parent `.disabled` dims it
    }

    private var label: some View {
        HStack(spacing: 7) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .tint(foreground)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 13 : 17, weight: .semibold))
            }
            if let title { Text(title) }
        }
        .font(compact ? Font.caption.weight(.semibold) : Theme.Typography.button)
        .foregroundStyle(foreground)
        .modifier(Chrome(isIconOnly: title == nil, fillWidth: fillWidth,
                         height: compact ? 32 : Theme.Metrics.controlHeight,
                         hPad: compact ? 12 : 16,
                         background: background))
    }

    /// Sizing + fill + corner radius. Icon-only buttons are a height×height
    /// square; text buttons are `height` tall with `hPad` side padding,
    /// optionally full-width. (#342: height/hPad parameterized for `compact`.)
    private struct Chrome: ViewModifier {
        let isIconOnly: Bool
        let fillWidth: Bool
        let height: CGFloat
        let hPad: CGFloat
        let background: Color
        func body(content: Content) -> some View {
            Group {
                if isIconOnly {
                    content.frame(width: height, height: height)
                } else {
                    content
                        .padding(.horizontal, hPad)
                        .frame(maxWidth: fillWidth ? .infinity : nil)
                        .frame(height: height)
                }
            }
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
        }
    }

    private var background: Color {
        switch role {
        case .primary:   return Theme.Palette.accent
        case .secondary: return Theme.Palette.fill
        case .danger:    return Theme.Palette.redWeak
        case .ghost:     return .clear
        }
    }
    private var foreground: Color {
        switch role {
        case .primary:           return .white
        case .secondary, .ghost: return Theme.Palette.accent
        case .danger:            return Theme.Palette.red
        }
    }
}

// MARK: - 2. OlcCard
//
// Rounded container: card fill, card radius, 16pt padding, optional hairline
// (#299: `cardBorderWidth` is 0, so the stroke overlay is a no-op — kept as a
// hook in case a future scheme wants a bordered card).

struct OlcCard<Content: View>: View {
    private let padding: CGFloat
    private let content: () -> Content

    init(padding: CGFloat = Theme.Metrics.cardPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            .overlay {
                // #299: card border width is 0, so this stroke is a no-op today;
                // the dynamic token (#340) is kept for a future bordered scheme.
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.cardBorder, lineWidth: Theme.Metrics.cardBorderWidth)
            }
    }
}

// MARK: - 3. OlcSectionHeader
//
// Uppercase, tracked label + optional trailing view. One treatment for every
// grouped section.

struct OlcSectionHeader<Trailing: View>: View {
    private let title: String
    private let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .tracking(0.6)
                .font(Theme.Typography.sectionHeader)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 7)
    }
}

extension OlcSectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title, trailing: { EmptyView() }) }
}

// MARK: - 4. OlcStatusPill
//
// The single status display: a colored dot + title + optional subtitle (+ an
// optional trailing view). `.progress` pulses. Replaces the per-state
// `circle.fill`/`play.fill`/`stop.fill` + bespoke-color soup.

enum OlcStatusTone: Hashable {
    case unknown, progress, ok, warn, error

    var color: Color {
        switch self {
        case .unknown:  return Theme.Palette.textTertiary
        case .progress: return Theme.Palette.amber
        case .ok:       return Theme.Palette.green
        case .warn:     return Theme.Palette.orange
        case .error:    return Theme.Palette.red
        }
    }
    var pulses: Bool { self == .progress }
}

/// A 9pt status dot; `.progress` emits a fading expanding ring.
struct OlcStatusDot: View {
    let tone: OlcStatusTone
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 9, height: 9)
            .overlay {
                if tone.pulses {
                    Circle()
                        .stroke(tone.color, lineWidth: 2)
                        .scaleEffect(animate ? 2.4 : 1)
                        .opacity(animate ? 0 : 0.6)
                }
            }
            .onAppear(perform: restart)
            .onChange(of: tone) { _, _ in restart() }
    }

    private func restart() {
        animate = false
        guard tone.pulses else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            animate = true
        }
    }
}

struct OlcStatusPill<Trailing: View>: View {
    private let tone: OlcStatusTone
    private let title: String
    private let subtitle: String?
    private let trailing: () -> Trailing

    init(tone: OlcStatusTone,
         title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.tone = tone
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            OlcStatusDot(tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.statusTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.statusSubtitle)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension OlcStatusPill where Trailing == EmptyView {
    init(tone: OlcStatusTone, title: String, subtitle: String? = nil) {
        self.init(tone: tone, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - 5. OlcOverflowMenu
//
// The ONE menu — a native `Menu` holding the COMPLETE action set for a row/card.
// Items carry an optional `.destructive` role (system red). A card's visible
// buttons should always be a subset of these items, never menu-exclusive.

struct OlcMenuItem: Identifiable {
    enum Kind {
        case button(role: ButtonRole?, action: () -> Void)
        case share(String)                       // renders a system ShareLink(item:)
        // #353: the share text is built lazily inside the Menu's content
        // closure — which SwiftUI only evaluates when the menu is opened — so a
        // large export string (e.g. the whole Logs buffer) isn't constructed on
        // every body refresh of the view that *holds* the menu.
        case shareLazy(() -> String)
        case divider
    }
    let id = UUID()
    var title: String = ""
    var systemImage: String? = nil
    var kind: Kind

    static func action(_ title: String,
                       systemImage: String? = nil,
                       role: ButtonRole? = nil,
                       _ action: @escaping () -> Void) -> OlcMenuItem {
        OlcMenuItem(title: title, systemImage: systemImage, kind: .button(role: role, action: action))
    }
    static func share(_ title: String, systemImage: String? = nil, item: String) -> OlcMenuItem {
        OlcMenuItem(title: title, systemImage: systemImage, kind: .share(item))
    }
    /// #353: deferred-content share — `item` is only called when the menu opens.
    static func shareLazy(_ title: String, systemImage: String? = nil,
                          item: @escaping () -> String) -> OlcMenuItem {
        OlcMenuItem(title: title, systemImage: systemImage, kind: .shareLazy(item))
    }
    static var divider: OlcMenuItem { OlcMenuItem(kind: .divider) }
}

struct OlcOverflowMenu: View {
    let items: [OlcMenuItem]
    var systemImage: String = "ellipsis.circle"

    var body: some View {
        Menu {
            ForEach(items) { item in
                switch item.kind {
                case .divider:
                    Divider()
                case let .button(role, action):
                    Button(role: role, action: action) {
                        if let img = item.systemImage {
                            Label(item.title, systemImage: img)
                        } else {
                            Text(item.title)
                        }
                    }
                case let .share(text):
                    if let img = item.systemImage {
                        ShareLink(item: text) { Label(item.title, systemImage: img) }
                    } else {
                        ShareLink(item: text) { Text(item.title) }
                    }
                case let .shareLazy(makeText):
                    // #353: `makeText()` runs here, inside the Menu content the
                    // system evaluates lazily on open — not on the holder's body.
                    let text = makeText()
                    if let img = item.systemImage {
                        ShareLink(item: text) { Label(item.title, systemImage: img) }
                    } else {
                        ShareLink(item: text) { Text(item.title) }
                    }
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.Palette.textSecondary)
                // #370 was: .frame(width: 32, height: 32) was the hit region —
                // below Apple's 44pt minimum. The glyph keeps its size; the
                // TOUCH region grows to 44×44 (the contentShape covers it).
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - 6. OlcSegmented
//
// One treatment for every "pick one of N": Routing and the Logs category picker.

struct OlcSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [OlcOption<Value>]

    init(selection: Binding<Value>, options: [OlcOption<Value>]) {
        self._selection = selection
        self.options = options
    }
    init(selection: Binding<Value>, options: [(Value, String)]) {
        self._selection = selection
        self.options = options.map { OlcOption(value: $0.0, label: $0.1) }
    }
    /// #316: (value, short label, full VoiceOver name) — for abbreviated segments.
    init(selection: Binding<Value>, options: [(Value, String, String)]) {
        self._selection = selection
        self.options = options.map { OlcOption(value: $0.0, label: $0.1, a11yLabel: $0.2) }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { opt in
                let active = opt.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = opt.value }
                } label: {
                    Text(opt.label)
                        .font(Theme.Typography.segment)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)   // keep ≤5 localized labels (e.g. Logs categories) on one line
                        .foregroundStyle(active ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Theme.Palette.segActive : Color.clear)
                                .shadow(color: active ? .black.opacity(0.3) : .clear, radius: 1, y: 1)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // #316: abbreviated labels stay readable to VoiceOver.
                .accessibilityLabel(opt.a11yLabel ?? opt.label)
            }
        }
        .padding(3)
        .background(Theme.Palette.fill,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.segmentedRadius, style: .continuous))
    }
}

// MARK: - 7. OlcChipPicker
//
// A wrapping row of equal-height selectable chips, single size. Replaces the
// `.mini`/`.small` quick-pick rows in Settings and the carrier/transport pickers
// in the sheets.

struct OlcChipPicker<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [OlcOption<Value>]

    init(selection: Binding<Value>, options: [OlcOption<Value>]) {
        self._selection = selection
        self.options = options
    }
    init(selection: Binding<Value>, options: [(Value, String)]) {
        self._selection = selection
        self.options = options.map { OlcOption(value: $0.0, label: $0.1) }
    }

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(options) { opt in
                let active = opt.value == selection
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(Theme.Typography.chip)
                        .foregroundStyle(active ? .white : Theme.Palette.textSecondary)
                        .padding(.horizontal, 14)
                        .frame(height: Theme.Metrics.chipHeight)
                        .background(Capsule().fill(active ? Theme.Palette.accent : Theme.Palette.fill))
                }
                .buttonStyle(OlcPressStyle())
            }
        }
    }
}

/// Minimal flow layout: lays children left→right, wrapping to the next line when
/// the proposed width runs out. Backs `OlcChipPicker`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0; y += rowHeight + lineSpacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - OlcIconButton (#341)
//
// 44×44 icon-only button on the standard fill with a per-action tint, so a
// row of quick actions reads apart at a glance (the Manage VPS card's
// Check / Container logs / Reconfigure). Parent `.disabled` dims to 0.35.

struct OlcIconButton: View {
    let systemImage: String
    var tint: Color = Theme.Palette.accent
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Theme.Metrics.controlHeight,
                       height: Theme.Metrics.controlHeight)
                .background(Theme.Palette.fill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
        }
        .buttonStyle(OlcPressStyle())
        .opacity(isEnabled ? 1 : 0.35)
    }
}

// MARK: - OlcMiniStat (#341)
//
// One-line compact metric for dense strips: caption2 uppercase label + a
// footnote (≈13pt) monospaced value, side by side. The Manage VPS card uses
// these where the two-deck OlcMetric row used to be.

struct OlcMiniStat: View {
    let label: String
    let value: String
    var tone: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.4)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(value)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(tone ?? Theme.Palette.textPrimary)
        }
        .lineLimit(1)
        // #369: the label + value were two separate Text nodes, so VoiceOver
        // read e.g. "Disk" and "36/40G" as disconnected fragments. Speak each
        // mini-stat as one element ("Disk 36/40G").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}

// MARK: - OlcProgressBar (#338)
//
// The ONE determinate progress bar: a 4pt amber capsule on the standard fill,
// shared by the Manage VPS card's operation progress and the Logs tab's
// container fetch — one monotonic-phase visual contract in both places.

struct OlcProgressBar: View {
    /// 0…1; values outside the range are clamped.
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.fill)
                Capsule()
                    .fill(Theme.Palette.amber)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(.easeInOut(duration: 0.3), value: fraction)
        .accessibilityElement()
        .accessibilityValue("\(Int((max(0, min(1, fraction))) * 100))%")
    }
}

// MARK: - 8. OlcMetric
//
// Uppercase caption label above a monospaced value. Used for Ping/DL/UL and the
// VPS Disk/RAM/Uptime numbers so technical values read consistently.

struct OlcMetric: View {
    let label: String
    let value: String
    var tone: Color? = nil
    /// #342: optional unit ("ms"/"Mbps") rendered as smaller secondary text
    /// after the value, so the unit doesn't inflate the mono number.
    var unit: String? = nil
    /// #405: render the unit up on the label line ("DL · Mbps") instead of after
    /// the value, so a long decimal value ("40.7") keeps the full column width
    /// and never wraps the fractional part to a second line. Default false keeps
    /// the legacy after-value placement.
    var unitInLabel: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .tracking(0.4)
                    .font(Theme.Typography.metricLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.textTertiary)
                // #405: the unit keeps its own case ("Mbps", not "MBPS") next to
                // the uppercased label.
                if unitInLabel, let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.Typography.metricValue)
                    .foregroundStyle(tone ?? Theme.Palette.textPrimary)
                    .lineLimit(1)   // #405: never wrap the number
                if !unitInLabel, let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        // #369: label / value / unit were three separate Text nodes, so the
        // Ping·DL·UL trio read as disconnected fragments to VoiceOver. Speak
        // each metric as one element ("Ping 42 ms").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([label, value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - OlcEmptyState
//
// Centered icon + title + hint + an optional primary CTA. One reusable empty
// state for the Connections / Manage VPS lists (#258, from the handoff's "New
// states").

struct OlcEmptyState: View {
    let systemImage: String
    let title: String
    let hint: String
    var ctaTitle: String? = nil
    var ctaSystemImage: String? = "plus"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 56, height: 56)
                .background(Theme.Palette.fill, in: Circle())
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let ctaTitle, let action {
                OlcButton(ctaTitle, systemImage: ctaSystemImage, role: .primary, fillWidth: true, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }
}

// MARK: - List & sheet chrome (#262)

extension View {
    /// Chrome for a full-width design-system card on a cleared List row (hero /
    /// routing / diagnostics / host cards / empty states).
    func olcCardRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
    }

    /// Shared editor/options-sheet chrome: one ✕ close control + a full-width
    /// primary footer button. `onConfirm` is responsible for dismissing on success.
    func olcSheet(confirm title: String, icon: String? = nil,
                  disabled: Bool = false, onConfirm: @escaping () -> Void) -> some View {
        modifier(OlcSheetChrome(confirmTitle: title, confirmIcon: icon,
                                confirmDisabled: disabled, onConfirm: onConfirm))
    }
}

private struct OlcSheetChrome: ViewModifier {
    let confirmTitle: String
    let confirmIcon: String?
    let confirmDisabled: Bool
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
            .safeAreaInset(edge: .bottom) {
                OlcButton(confirmTitle, systemImage: confirmIcon, role: .primary,
                          fillWidth: true, action: onConfirm)
                    .disabled(confirmDisabled)
                    .padding(16)
                    .background(.bar)
            }
    }
}

// MARK: - Previews (dark-only)

#if DEBUG

/// Local state holder so the interactive previews work without `@Previewable`.
private struct PreviewState<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content
    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }
    var body: some View { content($value) }
}

private extension View {
    /// Common ground for every component preview. #340 was: dark-only —
    /// now parameterized so components get a light variant too.
    func olcPreview(_ scheme: ColorScheme = .dark) -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.Palette.bg)
            .preferredColorScheme(scheme)
    }
}

#Preview("OlcButton") {
    VStack(spacing: 12) {
        OlcButton("Connect", systemImage: "play.fill", role: .primary) {}
        OlcButton("Check", systemImage: "globe", role: .secondary) {}
        OlcButton("Run test", role: .secondary, isBusy: true) {}
        OlcButton("Uninstall", systemImage: "trash", role: .danger) {}
        OlcButton("Retry", role: .ghost) {}
        HStack(spacing: 8) {
            OlcButton(systemImage: "stop.fill", role: .danger) {}
            OlcButton(systemImage: "slider.horizontal.3", role: .secondary) {}
            OlcButton(systemImage: "ellipsis", role: .ghost) {}
        }
        OlcButton("Install", systemImage: "arrow.down.app", role: .primary, fillWidth: true) {}
        OlcButton("Disabled", systemImage: "lock", role: .secondary) {}.disabled(true)
    }
    .olcPreview()
}

#Preview("OlcCard") {
    OlcCard {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").foregroundStyle(Theme.Palette.textPrimary)
            Text("Sources agree · 203.0.113.7")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
    .olcPreview()
}

#Preview("OlcSectionHeader") {
    VStack(spacing: 18) {
        OlcSectionHeader("Connections")
        OlcSectionHeader("Manage VPS") {
            OlcButton(systemImage: "plus", role: .ghost) {}
        }
    }
    .olcPreview()
}

#Preview("OlcStatusPill") {
    VStack(alignment: .leading, spacing: 16) {
        OlcStatusPill(tone: .ok,       title: "Connected",      subtitle: "socks5 · 127.0.0.1:8808")
        OlcStatusPill(tone: .progress, title: "Connecting…",    subtitle: "starting transport")
        OlcStatusPill(tone: .warn,     title: "Stopped",        subtitle: "container exists, not running")
        OlcStatusPill(tone: .error,    title: "Error",          subtitle: "ssh: handshake failed")
        OlcStatusPill(tone: .unknown,  title: "Status unknown", subtitle: "tap to check")
    }
    .olcPreview()
}

#Preview("OlcOverflowMenu") {
    OlcOverflowMenu(items: [
        .action("Connect", systemImage: "play.fill") {},
        .action("Ping",    systemImage: "bolt.horizontal.circle") {},
        .action("Check time-to-ready", systemImage: "stopwatch") {},
        .divider,
        .action("Edit", systemImage: "pencil") {},
        .action("Remove from list", systemImage: "minus.circle", role: .destructive) {},
    ])
    .olcPreview()
}

#Preview("OlcSegmented") {
    PreviewState("tunnel") { sel in
        OlcSegmented(selection: sel, options: [
            ("tunnel", "All tunnel"), ("rules", "By rules"), ("direct", "Direct"),
        ])
    }
    .olcPreview()
}

#Preview("OlcChipPicker") {
    PreviewState("1.1.1.1") { sel in
        OlcChipPicker(selection: sel, options: [
            ("1.1.1.1", "Cloudflare"), ("8.8.8.8", "Google"),
            ("9.9.9.9", "Quad9"), ("77.88.8.8", "Yandex"), ("system", "System"),
        ])
    }
    .olcPreview()
}

#Preview("OlcMetric") {
    HStack(spacing: 22) {
        OlcMetric(label: "Ping", value: "42 ms", tone: Theme.Palette.green)
        OlcMetric(label: "DL",   value: "88.4")
        OlcMetric(label: "RAM",  value: "1.2 GB")
        OlcMetric(label: "Uptime", value: "12d")
    }
    .olcPreview()
}

// #340: one representative light-mode pass over the component set (each
// component keeps its detailed dark preview above).
#Preview("Components — Light") {
    PreviewState("a") { sel in
        VStack(alignment: .leading, spacing: 16) {
            OlcStatusPill(tone: .ok, title: "Connected", subtitle: "socks5 · 127.0.0.1:8808")
            OlcCard {
                Text("Card on light ground").foregroundStyle(Theme.Palette.textPrimary)
            }
            OlcSegmented(selection: sel, options: [("a", "Conn"), ("b", "Diag"), ("c", "VPS")])
            OlcChipPicker(selection: sel, options: [("a", "Cloudflare"), ("b", "Google")])
            HStack(spacing: 8) {
                OlcButton("Connect", systemImage: "play.fill", role: .primary) {}
                OlcButton("Check", role: .secondary) {}
                OlcButton("Remove", role: .danger) {}
            }
            OlcProgressBar(fraction: 0.66)
            HStack(spacing: 22) {
                OlcMetric(label: "Ping", value: "42 ms", tone: Theme.Palette.green)
                OlcMetric(label: "DL", value: "88.4")
            }
        }
    }
    .olcPreview(.light)
}

#Preview("OlcProgressBar") {
    VStack(spacing: 16) {
        OlcProgressBar(fraction: 0.33)
        OlcProgressBar(fraction: 0.66)
        OlcProgressBar(fraction: 1)
    }
    .olcPreview()
}

#Preview("OlcIconButton + OlcMiniStat") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 8) {
            OlcIconButton(systemImage: "antenna.radiowaves.left.and.right") {}
            OlcIconButton(systemImage: "arrow.down.doc", tint: Theme.Palette.green) {}
            OlcIconButton(systemImage: "slider.horizontal.3", tint: Theme.Palette.orange) {}
            OlcIconButton(systemImage: "slider.horizontal.3", tint: Theme.Palette.orange) {}.disabled(true)
        }
        HStack(spacing: 8) {
            OlcMiniStat(label: "Ping", value: "27ms", tone: Theme.Palette.green)
            OlcMiniStat(label: "Disk", value: "36/40G")
            OlcMiniStat(label: "RAM", value: "241/2048M")
            OlcMiniStat(label: "Up", value: "11d")
        }
    }
    .olcPreview()
}

#Preview("OlcEmptyState") {
    OlcEmptyState(systemImage: "network",
                  title: "No connections yet",
                  hint: "Add a connection by URI or QR code, or install olcrtc on a VPS from the Manage VPS tab.",
                  ctaTitle: "Add connection") {}
        .olcPreview()
}

#endif
