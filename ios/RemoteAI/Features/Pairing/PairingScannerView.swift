import SwiftUI

#if os(iOS)
    import AVFoundation
    import UIKit
#endif

/// Scans the Mac's one-time pairing QR code.
///
/// The camera path is iOS-only; on other platforms (and in tests) the same
/// screen accepts pasted pairing text so the flow stays exercisable.
@MainActor
public struct PairingScannerView: View {
    @Bindable private var model: PairingViewModel
    @State private var pastedText = ""
    @Environment(\.dismiss) private var dismiss

    public init(model: PairingViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                #if os(iOS)
                    QRScannerRepresentable { scanned in
                        Task { await model.pair(scannedText: scanned) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                #endif

                Text("Point the camera at the pairing code shown on your Mac. The code is valid for five minutes and can be used once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                TextField("Or paste the pairing code", text: $pastedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pairing-paste-field")

                Button("Pair") {
                    Task { await model.pair(scannedText: pastedText) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pastedText.isEmpty)
                .accessibilityIdentifier("pairing-submit")

                switch model.state {
                case .paired:
                    Label("Paired", systemImage: "checkmark.seal")
                        .accessibilityIdentifier("pairing-success")
                case let .failed(message):
                    Text(message)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("pairing-error")
                case .pairing:
                    ProgressView()
                case .idle:
                    EmptyView()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Pair with your Mac")
            .toolbar {
                Button("Close") { dismiss() }
            }
            .onChange(of: model.state) { _, state in
                if state == .paired { dismiss() }
            }
        }
    }
}

#if os(iOS)
    /// Thin AVFoundation QR reader.
    ///
    /// NOT covered by automated tests: it needs camera hardware. Verify during
    /// on-device integration.
    struct QRScannerRepresentable: UIViewControllerRepresentable {
        let onScan: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

        func makeUIViewController(context: Context) -> ScannerViewController {
            let controller = ScannerViewController()
            controller.delegate = context.coordinator
            return controller
        }

        func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

        final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
            private let onScan: (String) -> Void
            private var hasScanned = false

            init(onScan: @escaping (String) -> Void) {
                self.onScan = onScan
            }

            func metadataOutput(
                _ output: AVCaptureMetadataOutput,
                didOutput objects: [AVMetadataObject],
                from connection: AVCaptureConnection
            ) {
                guard !hasScanned,
                    let object = objects.first as? AVMetadataMachineReadableCodeObject,
                    let value = object.stringValue
                else { return }
                // One code per presentation; a pairing secret is single-use.
                hasScanned = true
                onScan(value)
            }
        }
    }

    final class ScannerViewController: UIViewController {
        weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
        private let session = AVCaptureSession()

        override func viewDidLoad() {
            super.viewDidLoad()
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !session.isRunning else { return }
            Task.detached { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }
    }
#endif
