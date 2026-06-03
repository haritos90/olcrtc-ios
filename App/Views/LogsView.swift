import SwiftUI

// #258: design-system pass. The three trailing toolbar icons (share / copy /
// trash) collapse into one OlcOverflowMenu (the single trailing slot, matching
// every other tab); the category picker is an OlcSegmented; the title is large.

struct LogsView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var selected: LogCategory = .connection
    @State private var searchText = ""
    @State private var cachedFullText: String = ""

    private var filteredItems: [LogEntry] {
        let all = store.entries[selected] ?? []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return all }
        return all.filter { $0.text.localizedStandardContains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                OlcSegmented(selection: $selected,
                             options: LogCategory.allCases.map { ($0, $0.title) })
                    .padding(.horizontal)
                    .padding(.top, 8)

                if let url = store.fileURLs[selected] {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                logContent
            }
            .navigationTitle(L10n.logsTitle.localized())
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    OlcOverflowMenu(items: [
                        .share(L10n.shareAction.localized(), systemImage: "square.and.arrow.up", item: cachedFullText),
                        .action(L10n.copyAllAction.localized(), systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = cachedFullText
                        },
                        .divider,
                        .action(L10n.clearCategoryAction.localized(), systemImage: "trash", role: .destructive) {
                            LogStore.shared.clear(category: selected)
                        },
                    ])
                    .disabled(filteredItems.isEmpty)
                }
            }
            .onAppear { refreshCache() }
            .onChange(of: filteredItems.count) { refreshCache() }
            .onChange(of: selected) { refreshCache() }
        }
    }

    private func refreshCache() {
        cachedFullText = filteredItems.reversed().map(\.text).joined(separator: "\n")
    }

    @ViewBuilder
    private var logContent: some View {
        if filteredItems.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            OlcEmptyState(
                systemImage: isSearching ? "magnifyingglass" : selected.systemImage,
                title: isSearching ? L10n.noSearchResults.localized() : L10n.emptyLogsGeneric.localized(),
                hint: isSearching
                      ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                      : L10n.emptyLogsGenericHint.localized()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    // Single Text block avoids per-row layout issues and lets the
                    // system handle wrapping and selection as one coherent region.
                    Text(cachedFullText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: filteredItems.count) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}
