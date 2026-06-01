import SwiftUI
import VisionKit

/// Camera-based QR scanner using DataScannerViewController (iOS 16+).
/// Calls `onResult` with the first scanned string, then dismisses.
struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult, dismiss: dismiss) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onResult: (String) -> Void
        private let dismiss: DismissAction
        private var didReport = false

        init(onResult: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onResult = onResult
            self.dismiss  = dismiss
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !didReport else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let str = code.payloadStringValue {
                    didReport = true
                    dataScanner.stopScanning()
                    onResult(str)
                    dismiss()
                    return
                }
            }
        }
    }
}

/// Wrapper that checks device support before presenting the scanner.
struct QRScannerSheet: View {
    var onResult: (String) -> Void

    var body: some View {
        Group {
            if DataScannerViewController.isSupported {
                QRScannerView(onResult: onResult)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    L10n.cameraUnavailableTitle.localized(),
                    systemImage: "camera.slash",
                    description: Text(L10n.cameraUnavailableBody.localized())
                )
            }
        }
    }
}
