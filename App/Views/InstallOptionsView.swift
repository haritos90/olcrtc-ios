import SwiftUI

// MARK: - InstallOptionsView
//
// Sheet shown before "Install" runs SSH. The user picks carrier,
// transport and a room ID. Compatibility reference is
// in the Servers tab (always visible), not here.
//
// #258: carrier / transport use OlcChipPicker; the confirm action is a single
// full-width OlcButton(.primary) footer, with one close (✕) control.

struct InstallOptionsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var carrier   = "telemost"
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "telemost")
    @State private var roomID    = ""
    // #256: Jitsi rendezvous base URL — editable, pre-filled with the shared
    // default so users can point at their own instance. Only sent for jitsi.
    @State private var jitsiBaseURL = AppConstants.defaultJitsiBaseURL

    // SEI channel params — visible only when transport == "seichannel"
    @State private var seiFPS  : Int = 30
    @State private var seiBatch: Int = 10
    @State private var seiFrag : Int = 1200
    @State private var seiACK  : Int = 1

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
                jitsiSection
                seiSection
                defaultsInfoSection
            }
            .navigationTitle(L10n.installTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.actionInstall.localized(), icon: "arrow.down.app",
                      disabled: !canSubmit) { submit() }
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
                .onChange(of: transport) { _, newTransport in
                    if newTransport != "seichannel" {
                        seiFPS = 30; seiBatch = 10; seiFrag = 1200; seiACK = 1
                    }
                }
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

    // #256: only Jitsi has a user-pickable rendezvous instance (Telemost/WBStream
    // use fixed backends). Shown for jitsi so users aren't silently funnelled onto
    // the shared public default.
    @ViewBuilder
    private var jitsiSection: some View {
        if carrier == "jitsi" {
            Section {
                TextField(L10n.fieldJitsiURL.localized(), text: $jitsiBaseURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            } header: {
                Text(L10n.jitsiServerHeader.localized())
            } footer: {
                Text(L10n.jitsiServerFooter.localized()).font(.caption2)
            }
        }
    }

    @ViewBuilder
    private var seiSection: some View {
        if transport == "seichannel" {
            Section {
                Stepper("FPS: \(seiFPS)", value: $seiFPS, in: 1...120)
                Stepper("Batch: \(seiBatch)", value: $seiBatch, in: 1...256)
                Stepper("Frag: \(seiFrag)", value: $seiFrag, in: 100...65535, step: 100)
                Stepper("ACK: \(seiACK)", value: $seiACK, in: 0...10)
            } header: {
                Text(L10n.seiSettingsHeader.localized())
            } footer: {
                Text(L10n.seiSettingsFooter.localized()).font(.caption2)
            }
        }
    }

    private var defaultsInfoSection: some View {
        Section {
            Text(L10n.carrierFooter.localized())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Logic

    private func submit() {
        // Telemost shows room IDs with spaces ("3528 5410 1234") for readability;
        // the API form has no spaces. Strip them so users can paste either form.
        let cleanedRoom = roomID
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        // Never send an empty OLCRTC_JITSI_URL (srv.sh's `:-` default only fills
        // an *unset* var, not an empty one) — fall back to the shared default.
        let cleanedJitsi = jitsiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(InstallOptions(
            carrier:      carrier,
            transport:    transport,
            roomID:       requiresRoomID ? cleanedRoom : "",
            jitsiBaseURL: cleanedJitsi.isEmpty ? AppConstants.defaultJitsiBaseURL : cleanedJitsi,
            seiFPS:       seiFPS,
            seiBatch:     seiBatch,
            seiFrag:      seiFrag,
            seiACK:       seiACK
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
        // #097 was: the warning also covered seichannel — stale since the install
        // sheet gained the SEI steppers (seiSection → installEnv → OLCRTC_SEI_*).
        // `vp8channel` tunes via the Settings sliders, `seichannel` via the
        // steppers above; only `videochannel` still installs with the server-side
        // defaults from scripts/srv.sh (OLCRTC_VIDEO_* deliberately has no UI —
        // #097 decision: ten niche knobs aren't worth the sheet sprawl).
        if transport == "videochannel" {
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
