import SwiftUI

// MARK: - UpdateAvailableSheet (#360)
//
// Presented from the App root when `UpdateChecker` finds a newer GitHub
// release. CHECK-AND-LINK ONLY — a sandboxed sideload can't update itself, so
// this just links the install actions release.yml already emits: the release
// page (https) plus the sidestore:// / livecontainer:// deep links to the
// unsigned .ipa. The deep links only appear when their URL built — they always
// do for a normal tag, but the optionals keep a malformed tag from crashing.
//
// All actions dismiss; closing without acting is fine — the next launch past
// the 24h gate re-checks, and the user can flip the toggle off in Settings.

struct UpdateAvailableSheet: View {
    let update: UpdateChecker.Available
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.updateAvailableBody.localized())
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textSecondary)

                    VStack(spacing: 8) {
                        // Release page — a plain https link, always present.
                        OlcButton(L10n.updateOpenReleasePage.localized(),
                                  systemImage: "safari", role: .primary, fillWidth: true) {
                            openURL(update.releasePageURL)
                            dismiss()
                        }
                        // Sideload deep links — same shape as release.yml's
                        // install lines. Shown only when the URL parsed.
                        if let url = update.sideStoreURL {
                            OlcButton(L10n.updateInstallSideStore.localized(),
                                      systemImage: "arrow.down.app", role: .secondary, fillWidth: true) {
                                openURL(url)
                                dismiss()
                            }
                        }
                        if let url = update.liveContainerURL {
                            OlcButton(L10n.updateInstallLiveContainer.localized(),
                                      systemImage: "arrow.down.app", role: .secondary, fillWidth: true) {
                                openURL(url)
                                dismiss()
                            }
                        }
                        OlcButton(L10n.updateLater.localized(),
                                  role: .ghost, fillWidth: true) {
                            dismiss()
                        }
                    }
                }
                .padding(Theme.Metrics.cardPadding)
            }
            .navigationTitle(L10n.updateAvailableTitle_fmt.formatted(update.version))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
