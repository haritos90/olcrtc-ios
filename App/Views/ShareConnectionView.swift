import SwiftUI

// MARK: - ShareConnectionView (#304)
//
// Reusable "Share connection" sheet — explanation + the mono `olcrtc://` URI block
// (OlcCard) + Copy / Share / QR. Extracted from ConnectionsView and moved to the
// Manage VPS server card (#304): the connection is configured on the server card,
// and that's where sharing belongs (matching AmneziaVPN). The QR is a NavigationLink
// push (the sheet is already in a NavigationStack), so no second-sheet handoff is
// needed. The full-access share variant (SSH creds) is the separate #135.

struct ShareConnectionView: View {
    let conn: ConnectionRecord
    @Environment(\.dismiss) private var dismiss

    private var uri: String {
        switch conn.details {
        case .olcrtc(let p): return OlcrtcURI.encode(p)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.shareConnectionExplanation.localized())
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.shareConnectionURIHeader.localized())
                            .tracking(0.6)
                            .font(Theme.Typography.sectionHeader)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        OlcCard {
                            Text(uri)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    VStack(spacing: 8) {
                        OlcButton(L10n.copyURIAction.localized(), systemImage: "doc.on.doc",
                                  role: .secondary, fillWidth: true) {
                            UIPasteboard.general.string = uri
                            LogStore.shared.log(.connection, L10n.copiedURI_fmt.formatted(conn.displayName))
                            dismiss()
                        }
                        // ShareLink styled to match OlcButton(.secondary).
                        ShareLink(item: uri, subject: Text(conn.displayName)) {
                            Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.controlHeight)
                                .background(Theme.Palette.fill,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                        }
                        // #304: QR pushes within the sheet's own NavigationStack
                        // (was a second-sheet handoff in ConnectionsView).
                        NavigationLink {
                            QRCodeView(uri: uri)
                                .padding(32)
                                .navigationTitle(conn.displayName)
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label(L10n.actionQR.localized(), systemImage: "qrcode")
                                .font(Theme.Typography.button)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: Theme.Metrics.controlHeight)
                                .background(Theme.Palette.fill,
                                            in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(L10n.shareConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.closeAction.localized())
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
