import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - QRCodeView
//
// Renders an `olcrtc://` URI as a QR code using CIFilter.
// Displayed at ~250×250 pt with nearest-neighbour scaling so pixels
// stay sharp and no anti-aliasing blurs the modules.

struct QRCodeView: View {
    let uri: String

    var body: some View {
        Group {
            if let image = generateQR(from: uri) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .accessibilityLabel(L10n.qrCodeURIA11y.localized())
                    .accessibilityHint(L10n.qrCodeHintA11y.localized())
            } else {
                // Fallback — should never happen for a non-empty string
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Private

    private func generateQR(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up to a crisp raster — CIFilter output is typically tiny (~33×33 px)
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
