import SwiftUI

// MARK: - FormField
//
// Small reusable label + input combo used inside `Form` sections in
// AddConnectionView and AddServerHostView. Both views started with
// their own private `field()` helper; consolidating here means one
// place to tweak styling and disabled-state handling.

struct FormField: View {
    let label       : String
    let placeholder : String
    @Binding var text: String
    var secure      : Bool = false
    var keyboard    : UIKeyboardType = .default
    var focusBinding: FocusState<Bool>.Binding? = nil

    @State private var isRevealed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                input
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if secure {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var input: some View {
        if secure && !isRevealed {
            SecureField(placeholder, text: $text)
                .accessibilityLabel(label)
        } else if let fb = focusBinding {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .focused(fb)
                .accessibilityLabel(label)
        } else {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .accessibilityLabel(label)
        }
    }
}
