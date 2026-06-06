import SwiftUI

// MARK: - ReconfigureOptionsView
//
// Sheet shown when the user taps "Change Room / Transport" in the server menu.
// Identical layout to InstallOptionsView but with a different title and
// confirm-button label — no apt-get / go build, just stop + restart the
// existing container with new -carrier/-id/-transport flags.
//
// #258: carrier / transport use OlcChipPicker; the confirm action is a single
// full-width OlcButton(.primary) footer, with one close (✕) control.

struct ReconfigureOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier   = "telemost"
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "telemost")
    @State private var roomID    = ""

    let onConfirm: (InstallOptions) -> Void

    private var requiresRoomID: Bool { CarrierTransportMatrix.requiresRoomID(carrier: carrier) }

    private var canSubmit: Bool {
        !requiresRoomID || !roomID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                carrierSection
                transportSection
                roomIDSection
                infoSection
            }
            .navigationTitle(L10n.reconfigureTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.actionChangeRoomTransport.localized(),
                      icon: "slider.horizontal.3", disabled: !canSubmit) { submit() }
        }
    }

    // MARK: Sections

    private var carrierSection: some View {
        Section(L10n.sectionCarrier.localized()) {
            OlcChipPicker(selection: $carrier,
                          options: CarrierTransportMatrix.carriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) })
                .onChange(of: carrier) { _, c in
                    transport = CarrierTransportMatrix.defaultTransport(for: c)
                }
        }
    }

    private var transportSection: some View {
        Section {
            OlcChipPicker(selection: $transport,
                          options: CarrierTransportMatrix.transports.map { ($0, CarrierTransportMatrix.transportLabel($0)) })
        } header: {
            Text(L10n.transportSectionHeader.localized())
        } footer: {
            Text(transportFooter).font(.caption2)
        }
    }

    @ViewBuilder
    private var roomIDSection: some View {
        if requiresRoomID {
            Section {
                TextField(L10n.fieldRoomID.localized(), text: $roomID)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text(L10n.roomIDSectionHeader.localized())
            } footer: {
                Text(roomFooter).font(.caption2)
            }
        } else {
            Section {
                Label(L10n.roomIDAutoGenHint.localized(),
                      systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var infoSection: some View {
        Section {
            Text(L10n.reconfigureInfoFooter.localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Logic

    private func submit() {
        let cleanedRoom = roomID
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        onConfirm(InstallOptions(
            carrier:   carrier,
            transport: transport,
            roomID:    requiresRoomID ? cleanedRoom : ""
        ))
        dismiss()
    }

    // MARK: Footer helpers

    private var transportFooter: String {
        let compat: String
        switch CarrierTransportMatrix.compat(carrier: carrier, transport: transport) {
        case .recommended: compat = L10n.matrixRecommended_fmt.formatted(carrier)
        case .ok:          compat = L10n.matrixWorks_fmt.formatted(carrier)
        case .question:    compat = L10n.matrixQuestion_fmt.formatted(carrier)
        case .fail:        compat = L10n.matrixFail_fmt.formatted(carrier)
        case .unknown:     compat = L10n.matrixUnknown_fmt.formatted(carrier)
        }
        if transport == "seichannel" || transport == "videochannel" {
            return compat + "\n" + L10n.transportUsesServerDefaults_fmt.formatted(transport)
        }
        return compat
    }

    private var roomFooter: String {
        switch carrier {
        case "telemost": return L10n.roomIDTelemostHint.localized()
        case "wbstream": return L10n.roomIDWbstreamHint.localized()
        default:         return ""
        }
    }
}
