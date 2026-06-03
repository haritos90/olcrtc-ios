import SwiftUI

// MARK: - ContainerLogsView
//
// Sheet shown after the user taps "Container logs" on a host card. The
// SSH fetch already ran by the time we get here — we just present the
// captured text. Each invocation creates a fresh sheet because
// `ContainerLogsPayload` is Identifiable, so `.sheet(item:)` re-renders
// on every new fetch.
//
// The output is also persisted to `LogStore.containerLogs` so the user
// can re-browse it from the Logs tab after dismissing this sheet.

/// Carries the container name and captured log output to the detail sheet.
struct ContainerLogsPayload: Identifiable {
    let id = UUID()
    let containerName: String
    let output: String
}

struct ContainerLogsView: View {
    let payload: ContainerLogsPayload
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if payload.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(L10n.emptyLogsTitle.localized())
                            .foregroundStyle(.secondary)
                        Text(L10n.emptyLogsHint_fmt.formatted(payload.output.isEmpty ? "200" : "—"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .padding(.top, 80)
                } else {
                    // #258: monospaced log dump wrapped in a design-system card.
                    OlcCard {
                        Text(payload.output)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(payload.containerName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.closeAction.localized()) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !payload.output.isEmpty {
                        ShareLink(item: payload.output) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = payload.output
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(payload.output.isEmpty)
                }
            }
        }
    }
}
