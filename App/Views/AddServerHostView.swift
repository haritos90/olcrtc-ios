import SwiftUI

// MARK: - AddServerHostView
//
// Sheet for creating/editing a ServerHost. Password is loaded from Keychain
// on open (edit mode) and saved there on submit. We pre-fill port 22 and
// username root since that's the Timeweb default.

struct AddServerHostView: View {
    var existing: ServerHost? = nil
    var existingPassword: String? = nil          // pre-fill on edit; nil for add-new flow
    var onSave: (ServerHost, String) -> Void   // (host, password)

    @Environment(\.dismiss) private var dismiss

    @State private var label    = ""
    @State private var host     = ""
    @State private var port     = "22"
    @State private var username = "root"
    @State private var password = ""

    @FocusState private var portFocused: Bool

    @State private var isTesting: Bool = false
    @State private var testResult: String? = nil
    @State private var testTask: Task<Void, Never>? = nil

    private var isValid: Bool {
        !label.isEmpty && !host.isEmpty && Int(port) != nil
            && !username.isEmpty && !password.isEmpty
    }

    private var canTest: Bool {
        !host.isEmpty && Int(port) != nil && !username.isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.sectionDescription.localized()) {
                    FormField(label: L10n.nameField.localized(), placeholder: "TW Moscow", text: $label)
                }
                Section(L10n.sshAccessHeader.localized()) {
                    FormField(label: L10n.hostField.localized(),     placeholder: "1.2.3.4", text: $host)
                    FormField(label: L10n.portField.localized(),     placeholder: "22",      text: $port, keyboard: .numberPad, focusBinding: $portFocused)
                    FormField(label: L10n.loginField.localized(),    placeholder: "root",    text: $username)
                    FormField(label: L10n.passwordField.localized(), placeholder: "•••",     text: $password, secure: true)
                }
                if canTest {
                    Section {
                        VStack(spacing: 6) {
                            Button {
                                testResult = nil
                                isTesting = true
                                testTask = Task { await testSSH() }
                            } label: {
                                HStack {
                                    if isTesting {
                                        ProgressView()
                                            .padding(.trailing, 4)
                                    }
                                    Text(L10n.testSSHAction.localized())
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .disabled(isTesting)
                            if let result = testResult {
                                Text(result)
                                    .font(.caption)
                                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
                            }
                        }
                    }
                }
            }
            .navigationTitle(existing == nil
                             ? L10n.newServerTitle.localized()
                             : L10n.editServerTitle.localized())
            .navigationBarTitleDisplayMode(.inline)
            // #262: keep the numeric-field keyboard toolbar; ✕ close + footer
            // come from the shared `.olcSheet` chrome below.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.actionDone.localized()) { portFocused = false }
                }
            }
            .olcSheet(confirm: L10n.save.localized(), disabled: !isValid) { save() }
            .onAppear { prefill() }
            .onDisappear {
                testTask?.cancel()
                testTask = nil
            }
        }
    }

    @MainActor
    private func testSSH() async {
        guard !Task.isCancelled else { return }
        guard let portInt = Int(port), portInt > 0, portInt <= 65535 else {
            testResult = "✗ Invalid port"
            isTesting = false
            return
        }
        let result = await NetPing.tcp(host: host, port: UInt16(portInt))
        if result.success, let ms = result.ms {
            testResult = String(format: "✓ Reachable (%.0f ms)", ms)
        } else {
            testResult = "✗ Unreachable"
        }
        isTesting = false
    }

    private func save() {
        var h = existing ?? ServerHost(label: "", host: "")
        h.label    = label
        h.host     = host
        h.port     = Int(port) ?? 22
        h.username = username
        onSave(h, password)
        dismiss()
    }

    private func prefill() {
        guard let h = existing else { return }
        label    = h.label
        host     = h.host
        port     = String(h.port)
        username = h.username
        // Password is fetched from Keychain by the caller and passed in;
        // leave the field empty if it wasn't available.
        if let pw = existingPassword { password = pw }
    }
}
