import SwiftUI

// MARK: - AddConnectionView
//
// Editor sheet for ConnectionRecord. Two visible modes:
//
//  CREATE mode (existing == nil)
//    – URI paste field at the top so the user can paste any supported
//      proxy link (currently `olcrtc://...`; more protocols are coming).
//      Hitting "Parse" autofills the parameter fields below.
//    – Manual fields are always visible so the user can verify what was
//      parsed or build a record from scratch.
//
//  EDIT mode (existing != nil)
//    – URI field is hidden. Editing means tweaking existing parameters,
//      and a stale URI from the original server is confusing here.
//
// Today the form only knows how to render an olcrtc-shaped configuration
// (carrier + transport pickers, room/key/clientID fields). When other
// protocols (vless / xray / reality / rprx-vision / awg 2.0 / xhttp) come
// online, this view branches on the user-chosen ProtocolType and swaps to
// the appropriate protocol-specific editor. The URI parser is shared and
// already protocol-agnostic at the call site.
//
// Implementation note: SwiftUI's TextEditor doesn't support a native
// placeholder, so we overlay a Text view that disappears as the user
// starts typing.

struct AddConnectionView: View {
    var existing: ConnectionRecord? = nil
    /// Group names already used by other connections. The editor surfaces
    /// them in a quick-pick menu next to the freeform Group field.
    var existingGroups: [String] = []
    var onSave: (ConnectionRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var uriText      = ""
    @State private var parseError   = ""
    @State private var showQRScan   = false

    @State private var name      = ""
    @State private var groupName = L10n.groupDefault.localized()
    @State private var carrier   = "wbstream"
    // #284: default to the carrier's recommended transport (wbstream+datachannel
    // is now `.question`); keeps the initial pick consistent with the matrix and
    // with InstallOptions / ReconfigureOptions.
    @State private var transport = CarrierTransportMatrix.defaultTransport(for: "wbstream")
    @State private var roomID    = ""
    @State private var key       = ""
    @State private var clientID  = "default"
    @State private var socksUser = ""
    @State private var socksPass = ""
    @State private var vp8FPS      : Int? = nil
    @State private var vp8BatchSize: Int? = nil

    private var isCreate: Bool { existing == nil }

    private var isVP8: Bool { transport == "vp8channel" }

    private var isValid: Bool {
        !name.isEmpty && !groupName.isEmpty && !carrier.isEmpty && !transport.isEmpty
            && !roomID.isEmpty && !key.isEmpty && !clientID.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreate {
                    uriSection
                }
                manualFields
            }
            .navigationTitle(isCreate
                             ? L10n.newConnectionTitle.localized()
                             : L10n.editConnectionTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: shared sheet chrome (✕ close + full-width primary footer).
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
        }
        .onAppear { prefill() }
        .sheet(isPresented: $showQRScan) {
            QRScannerSheet { scanned in
                uriText = scanned
                parseURI()
            }
        }
    }

    // MARK: URI paste

    // #258: Scan-QR / Paste-URI shortcuts. Both feed `parseURI()`, which fills the
    // manual fields below (was an inline TextEditor paste box).
    private var uriSection: some View {
        Section {
            HStack(spacing: 8) {
                OlcButton(L10n.scanQRAction.localized(), systemImage: "qrcode.viewfinder",
                          role: .secondary, fillWidth: true) {
                    showQRScan = true
                }
                OlcButton(L10n.pasteURIAction.localized(), systemImage: "doc.on.clipboard",
                          role: .secondary, fillWidth: true) {
                    uriText = UIPasteboard.general.string ?? ""
                    parseURI()
                }
            }
            .padding(.vertical, 4)

            // #265: manual entry — type or paste-and-edit a URI here; auto-parses
            // into the fields below (the redesign had left only Scan/Paste).
            TextField("olcrtc://…", text: $uriText, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: uriText) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let cfg = try? OlcrtcURI.parse(trimmed) else { return }
                    carrier = cfg.carrier; transport = cfg.transport; roomID = cfg.roomID
                    key = cfg.key; clientID = cfg.clientID
                    vp8FPS = cfg.vp8FPS; vp8BatchSize = cfg.vp8BatchSize
                    if name.isEmpty { name = cfg.mimo.isEmpty ? "\(cfg.carrier) · \(cfg.transport)" : cfg.mimo }
                    parseError = ""
                }

            if !parseError.isEmpty {
                Text(parseError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(L10n.importByURI.localized())
        } footer: {
            Text(L10n.importHint.localized())
                .font(.caption2)
        }
    }

    // MARK: Manual fields

    @ViewBuilder private var manualFields: some View {
        Section(L10n.parametersHeader.localized()) {
            FormField(label: L10n.nameSettingLabel.localized(), placeholder: L10n.namePlaceholder.localized(), text: $name)

            groupField

            // #258: carrier / transport via OlcChipPicker (was Picker). The
            // per-transport compatibility symbols live in the Manage VPS matrix.
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.sectionCarrier.localized())
                    .font(.caption).foregroundStyle(.secondary)
                OlcChipPicker(selection: $carrier,
                              options: CarrierTransportMatrix.carriers.map { ($0, CarrierTransportMatrix.carrierLabel($0)) })
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.labelTransport.localized())
                    .font(.caption).foregroundStyle(.secondary)
                OlcChipPicker(selection: $transport,
                              options: CarrierTransportMatrix.transports.map { ($0, CarrierTransportMatrix.transportLabel($0)) })
            }

            FormField(label: "Room ID",   placeholder: L10n.roomIDLabel.localized(),  text: $roomID)
                .onChange(of: roomID) { _, new in
                    let stripped = new.filter { !$0.isWhitespace }
                    if stripped != new { roomID = stripped }
                }
            FormField(label: "Client ID", placeholder: "default",                     text: $clientID)
            Text(L10n.clientIDFooter.localized())
                .font(.caption2)
                .foregroundStyle(.secondary)
            FormField(label: "Key (hex)", placeholder: L10n.keyPlaceholder.localized(), text: $key, secure: true)
        }

        if isVP8 {
            vp8Section
        }
        // SOCKS auth (socksUser/socksPass) is configured globally in Settings,
        // not per-connection — removed from here to avoid confusion.
    }

    /// Group: freeform TextField + Menu of existing groups. Tap the menu
    /// icon to fill the field from the existing set (avoids typos like
    /// "Russia" vs "russia" splitting the same logical group), or just
    /// type a new name to create a new group implicitly.
    private var groupField: some View {
        HStack {
            Text(L10n.groupField.localized())
            TextField(L10n.groupDefault.localized(), text: $groupName)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
            if !existingGroups.isEmpty {
                Menu {
                    ForEach(existingGroups, id: \.self) { g in
                        Button(g) { groupName = g }
                    }
                } label: {
                    Image(systemName: "list.bullet.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: VP8 per-connection override

    private var vp8Section: some View {
        Section {
            HStack {
                Text(L10n.vp8FpsLabel.localized())
                Spacer()
                Text(vp8FPS.map(String.init)
                     ?? L10n.globalDefault_fmt.formatted(SettingsStore.shared.vp8FPS))
                    .foregroundStyle(vp8FPS == nil ? .secondary : .primary)
                Stepper("", value: Binding(
                    get: { vp8FPS ?? SettingsStore.shared.vp8FPS },
                    set: { vp8FPS = $0 }
                ), in: 1...120)
                .labelsHidden()
                if vp8FPS != nil {
                    Button { vp8FPS = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(L10n.vp8BatchLabel.localized())
                Spacer()
                Text(vp8BatchSize.map(String.init)
                     ?? L10n.globalDefault_fmt.formatted(SettingsStore.shared.vp8BatchSize))
                    .foregroundStyle(vp8BatchSize == nil ? .secondary : .primary)
                Stepper("", value: Binding(
                    get: { vp8BatchSize ?? SettingsStore.shared.vp8BatchSize },
                    set: { vp8BatchSize = $0 }
                ), in: 1...64)
                .labelsHidden()
                if vp8BatchSize != nil {
                    Button { vp8BatchSize = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(L10n.vp8ParamsHeader.localized())
        } footer: {
            Text(L10n.overrideHint.localized())
                .font(.caption2)
        }
    }

    // MARK: SOCKS auth

    private var socksAuthSection: some View {
        Section {
            FormField(label: L10n.socksUserLabel.localized(),
                      placeholder: L10n.socksUserPlaceholder.localized(),
                      text: $socksUser)
            FormField(label: L10n.socksPassLabel.localized(),
                      placeholder: L10n.socksUserPlaceholder.localized(),
                      text: $socksPass, secure: true)
        } header: {
            Text(L10n.socksAuthHeader.localized())
        } footer: {
            Text(L10n.socksAuthFooter.localized())
                .font(.caption2)
        }
    }

    // MARK: Logic

    private func parseURI() {
        parseError = ""
        do {
            let cfg = try OlcrtcURI.parse(uriText)
            carrier      = cfg.carrier
            transport    = cfg.transport
            roomID       = cfg.roomID
            key          = cfg.key
            clientID     = cfg.clientID
            vp8FPS       = cfg.vp8FPS
            vp8BatchSize = cfg.vp8BatchSize
            if name.isEmpty {
                name = cfg.mimo.isEmpty ? "\(cfg.carrier) · \(cfg.transport)" : cfg.mimo
            }
            LogStore.shared.log(.connection,
                "✓ URI parsed: carrier=\(cfg.carrier) transport=\(cfg.transport) room=\(cfg.roomID.prefix(8))…")
        } catch {
            parseError = error.localizedDescription
            LogStore.shared.log(.connection, "✗ URI parse failed: \(error.localizedDescription)")
        }
    }

    private func save() {
        let params = OlcrtcConnection(
            carrier:      carrier,
            transport:    transport,
            roomID:       roomID,
            key:          key,
            clientID:     clientID,
            vp8FPS:       vp8FPS,
            vp8BatchSize: vp8BatchSize,
            socksUser:    socksUser,
            socksPass:    socksPass
        )
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        // #283: store the canonical default token when the user left the group at
        // the (localised) default or empty, so it localises at display time
        // instead of freezing the language it was created in.
        let resolvedGroup = (trimmedGroup.isEmpty || trimmedGroup == L10n.groupDefault.localized())
            ? ConnectionRecord.defaultGroupName : trimmedGroup
        let record = ConnectionRecord(
            id:        existing?.id ?? UUID(),
            name:      name,
            groupName: resolvedGroup,
            details:   .olcrtc(params)
        )
        onSave(record)
        dismiss()
    }

    private func prefill() {
        guard let r = existing else {
            // Create mode: reset all fields to defaults
            name = ""; groupName = L10n.groupDefault.localized()
            carrier = "wbstream"; transport = CarrierTransportMatrix.defaultTransport(for: "wbstream")
            roomID = ""; key = ""; clientID = "default"
            socksUser = ""; socksPass = ""; vp8FPS = nil; vp8BatchSize = nil
            uriText = ""; parseError = ""
            return
        }
        name      = r.name
        // #283: show the localised default ("Основная") in the edit field, not the
        // raw "Servers" token; `save()` maps it back to the canonical token.
        groupName = ConnectionRecord.displayGroupName(r.groupName)
        if case .olcrtc(let p) = r.details {
            carrier      = p.carrier
            transport    = p.transport
            roomID       = p.roomID
            key          = p.key
            clientID     = p.clientID
            vp8FPS       = p.vp8FPS
            vp8BatchSize = p.vp8BatchSize
            socksUser    = p.socksUser
            socksPass    = p.socksPass
        }
    }
}
