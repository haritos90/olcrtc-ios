import SwiftUI

// MARK: - ShareConnectionView (#304)
//
// Reusable "Share connection" sheet — explanation + the mono `olcrtc://` URI block
// (OlcCard) + Copy / Share / QR. Extracted from ConnectionsView and moved to the
// Manage VPS server card (#304): the connection is configured on the server card,
// and that's where sharing belongs (matching AmneziaVPN). The QR is a NavigationLink
// push (the sheet is already in a NavigationStack), so no second-sheet handoff is
// needed.
//
// #135: optional FULL-ACCESS share (co-admin). When the sheet is created with a
// `fullAccess` payload (the host's SSH fields + the Keychain password — read by
// the caller, ServersView), it adds an opt-in section behind a destructive-style
// warning that shares an `olcrtc://host/v1/…` link carrying BOTH the connection
// URI and the SSH credentials, so the recipient can MANAGE the VPS, not just
// connect (#366: the familiar olcrtc:// scheme — FullAccessShare for the format,
// App.handleIncomingURL for the recipient-side import). The secret is never logged.

struct ShareConnectionView: View {
    let conn: ConnectionRecord
    /// #135: present only when the caller supplies full-access credentials.
    let fullAccess: FullAccessShare?
    @Environment(\.dismiss) private var dismiss

    /// #135: gate the credential blob behind an explicit reveal so it isn't on
    /// screen until the user opts in past the warning.
    @State private var fullAccessRevealed = false

    init(conn: ConnectionRecord, fullAccess: FullAccessShare? = nil) {
        self.conn = conn
        self.fullAccess = fullAccess
    }

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

                    // #135: opt-in full-access (co-admin) share — only when the
                    // caller passed SSH credentials.
                    if let fa = fullAccess {
                        fullAccessSection(fa)
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

    // MARK: - Full-access (co-admin) section (#135)

    /// Opt-in section that shares an `olcrtc://host/v1/…` link carrying the SSH
    /// credentials AND the connection URI. Until the user taps "Reveal", only
    /// the destructive-style warning shows; revealing exposes the blob + the
    /// Copy / Share actions. The secret is never logged — only the action is.
    @ViewBuilder
    private func fullAccessSection(_ fa: FullAccessShare) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.Palette.separator).padding(.vertical, 4)

            Text(L10n.shareFullAccessHeader.localized())
                .tracking(0.6)
                .font(Theme.Typography.sectionHeader)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Palette.textSecondary)

            // Destructive-style warning — always visible, even before reveal.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.red)
                Text(L10n.shareFullAccessWarning.localized())
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.redWeak,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))

            if !fullAccessRevealed {
                OlcButton(L10n.shareFullAccessReveal.localized(), systemImage: "eye",
                          role: .danger, fillWidth: true) {
                    fullAccessRevealed = true
                }
            } else if let link = fa.encoded() {
                OlcCard {
                    Text(link)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(spacing: 8) {
                    OlcButton(L10n.shareFullAccessCopy.localized(), systemImage: "doc.on.doc",
                              role: .danger, fillWidth: true) {
                        UIPasteboard.general.string = link
                        // #135: log the ACTION only — never the credential blob.
                        LogStore.shared.log(.connection, L10n.shareFullAccessCopied_fmt.formatted(conn.displayName))
                        dismiss()
                    }
                    // ShareLink styled to match OlcButton(.secondary), like the URI row.
                    ShareLink(item: link, subject: Text(conn.displayName)) {
                        Label(L10n.shareAction.localized(), systemImage: "square.and.arrow.up")
                            .font(Theme.Typography.button)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: Theme.Metrics.controlHeight)
                            .background(Theme.Palette.fill,
                                        in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius, style: .continuous))
                    }
                }
            }
        }
    }
}
