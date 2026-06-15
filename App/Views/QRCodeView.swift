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

    // #373: one CIContext for the whole app — allocating one per render (the
    // old `let context = CIContext()` inside generateQR, called straight from
    // body) is expensive and pointless: a CIContext is stateless for our use.
    private static let ciContext = CIContext()

    // #373 was: generateQR(from: uri) was called directly in `body`, so every
    // re-render of the presenting hierarchy re-rastered the QR. Raster once per
    // `uri` into @State (via .task) and just show the cached image afterwards.
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .accessibilityLabel(L10n.qrCodeURIA11y.localized())
                    .accessibilityHint(L10n.qrCodeHintA11y.localized())
            } else {
                // Fallback — also the placeholder until the first raster lands.
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 250, height: 250)
                    .foregroundStyle(.secondary)
            }
        }
        // #373: raster once per uri; re-runs only when uri actually changes.
        .task(id: uri) { image = Self.generateQR(from: uri) }
    }

    // MARK: Private

    private static func generateQR(from string: String) -> UIImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up to a crisp raster — CIFilter output is typically tiny (~33×33 px)
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // #373 was: `let context = CIContext()` — fresh per call. Reuse the shared one.
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
