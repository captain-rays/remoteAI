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
    @State private var camera: CameraAvailability = .needsPermission
    @Environment(\.dismiss) private var dismiss

    public init(model: PairingViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                #if os(iOS)
                    if camera.showsViewfinder {
                        QRScannerRepresentable(
                            onScan: { scanned in
                                Task { await model.pair(scannedText: scanned) }
                            },
                            onUnavailable: { camera = .unavailable }
                        )
                        .frame(maxWidth: .infinity, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let message = camera.message {
                        // Never a black rectangle: say what stopped the camera
                        // and what to do instead.
                        Label(message, systemImage: "video.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("pairing-camera-unavailable")
                    }
                #endif

                if camera.showsViewfinder {
                    Text("Point the camera at the pairing code shown on your Mac. The code is valid for five minutes and can be used once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

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
            .task { await resolveCameraAccess() }
        }
    }

    /// Ask for the camera once, and record what the answer means.
    ///
    /// Without this the capture session simply produced no frames when access
    /// had been refused, which on screen is indistinguishable from a camera
    /// pointed at an unreadable code.
    private func resolveCameraAccess() async {
        #if os(iOS)
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let hasCamera = AVCaptureDevice.default(for: .video) != nil
            if status == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                camera = CameraAvailability.of(granted ? .granted : .denied, hasCamera: hasCamera)
                return
            }
            camera = CameraAvailability.of(Self.permission(for: status), hasCamera: hasCamera)
        #else
            camera = .unavailable
        #endif
    }

    #if os(iOS)
        private static func permission(for status: AVAuthorizationStatus) -> CameraPermission {
            switch status {
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .undetermined
            @unknown default: return .denied
            }
        }
    #endif
}

#if os(iOS)
    /// Thin AVFoundation QR reader.
    ///
    /// NOT covered by automated tests: it needs camera hardware. Verify during
    /// on-device integration.
    struct QRScannerRepresentable: UIViewControllerRepresentable {
        let onScan: (String) -> Void
        let onUnavailable: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

        func makeUIViewController(context: Context) -> ScannerViewController {
            let controller = ScannerViewController()
            controller.delegate = context.coordinator
            controller.onUnavailable = onUnavailable
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
        /// Called when the camera cannot be opened, so the screen can say so
        /// instead of showing an empty rectangle for ever.
        var onUnavailable: (() -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                onUnavailable?()
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onUnavailable?()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.preview = preview
        }

        /// `viewDidLoad` runs before the view has its final size, so the layer
        /// has to follow the layout rather than be sized once.
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard preview != nil, !session.isRunning else { return }
            // Starting a session blocks; never on the main thread.
            Task.detached { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard session.isRunning else { return }
            Task.detached { [session] in session.stopRunning() }
        }
    }
#endif
