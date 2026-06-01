import SwiftUI

struct LogsView: View {
    @ObservedObject private var store = LogStore.shared
    @State private var selected: LogCategory = .connection
    @State private var copied = false
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
                Picker("", selection: $selected) {
                    ForEach(LogCategory.allCases) { cat in
                        Label(cat.title, systemImage: cat.systemImage).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
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
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.logsSearchPlaceholder.localized())
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Share opens native sheet (AirDrop, copy, notes, etc.)
                    if !filteredItems.isEmpty {
                        ShareLink(item: cachedFullText) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    // Quick-copy keeps the old single-tap path
                    Button {
                        UIPasteboard.general.string = cachedFullText
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(filteredItems.isEmpty)
                    // Clear only the currently selected category (#166)
                    Button(role: .destructive) {
                        LogStore.shared.clear(category: selected)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(filteredItems.isEmpty)
                }
            }
            .onAppear {
                cachedFullText = filteredItems.reversed().map(\.text).joined(separator: "\n")
            }
            .onChange(of: filteredItems.count) {
                cachedFullText = filteredItems.reversed().map(\.text).joined(separator: "\n")
            }
            .onChange(of: selected) {
                cachedFullText = filteredItems.reversed().map(\.text).joined(separator: "\n")
            }
        }
    }

    @ViewBuilder
    private var logContent: some View {
        if filteredItems.isEmpty {
            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(spacing: 8) {
                Image(systemName: isSearching ? "magnifyingglass" : selected.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(isSearching ? L10n.noSearchResults.localized() : L10n.emptyLogsGeneric.localized())
                    .foregroundStyle(.secondary)
                Text(isSearching
                     ? L10n.noSearchResultsHint_fmt.formatted(searchText)
                     : L10n.emptyLogsGenericHint.localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
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
