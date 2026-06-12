import SwiftUI

// MARK: - ConfigView (#301)
//
// Placeholder tab between Manage VPS and Logs — the future home for routing /
// config options (the README "Route" scope: the `.allDirect` routing mode #273,
// and per-app rules if a NetworkExtension packet tunnel ever lands #112). Shows a
// "Coming soon" empty state for now; the shell (NavigationStack + large title)
// matches the other tabs so the tab bar stays consistent.

struct ConfigView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    OlcEmptyState(systemImage: "slider.horizontal.3",
                                  title: L10n.configComingSoonTitle.localized(),
                                  hint: L10n.configComingSoonHint.localized())
                        .olcCardRow()
                }
            }
            .navigationTitle(L10n.tabConfig.localized())
        }
    }
}

// #340: both appearance variants.
#if DEBUG
#Preview("Config — Dark") {
    ConfigView().preferredColorScheme(.dark)
}
#Preview("Config — Light") {
    ConfigView().preferredColorScheme(.light)
}
#endif
