import AVFoundation
import SwiftUI
import UIKit

// The camera side of scanning a printed field marker or a pairing code.
//
// `AVCaptureMetadataOutput` rather than a QR library, per the work order and
// for a better reason than dependency hygiene: the metadata output runs QR
// detection on the capture pipeline itself, so it finds a symbol on a dusty
// column in worse light and at a steeper angle than anything decoding
// individual frames handed up to it, and it costs no frame copies.
//
// The view reports raw strings. It does not know what a `pixmy://` payload is
// — parsing lives in `QrPayload.swift`, which is testable, and this file is
// not. That boundary is the same one the rest of the app uses to keep logic
// out of the parts a Linux CI cannot compile.

/// A live camera preview that reports QR payloads as it sees them.
struct QrScannerView: UIViewControllerRepresentable {
    /// Called for each newly-seen payload string. Repeats of the payload
    /// already reported are suppressed, so a code held in frame fires once.
    var onScan: (String) -> Void
    /// Called once if the camera cannot be started at all.
    var onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QrScannerController {
        let controller = QrScannerController()
        controller.onScan = onScan
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: QrScannerController, context: Context) {
        controller.onScan = onScan
        controller.onFailure = onFailure
    }
}

final class QrScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// The payload most recently reported, so a code sitting in frame at 30 fps
    /// does not fire thirty times a second.
    private var lastPayload: String?
    private var lastPayloadAt: Date = .distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop on the way out rather than in deinit: a running capture session
        // behind a dismissed sheet holds the camera and the torch.
        if session.isRunning {
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
        preview?.connection?.videoOrientation = currentOrientation
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onFailure?("This device has no camera PIXMYD can use for scanning.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onFailure?("The camera could not be set up to read QR codes.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Set after the output is attached — the available types are empty
        // until then, and assigning an unavailable type raises.
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            resume()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted
                        ? self?.resume()
                        : self?.onFailure?("PIXMYD needs camera access to read markers. Enable it in Settings.")
                }
            }
        default:
            onFailure?("PIXMYD needs camera access to read markers. Enable it in Settings.")
        }
    }

    private func resume() {
        guard !session.isRunning else { return }
        // `startRunning` blocks; off the main thread or the sheet visibly
        // hitches as it appears.
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private var currentOrientation: AVCaptureVideoOrientation {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft:      return .landscapeLeft
        case .landscapeRight:     return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default:                  return .portrait
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let payload = object.stringValue,
              !payload.isEmpty else { return }

        // Same code still in frame: ignore. A different code, or the same one
        // after two seconds, is a deliberate re-scan.
        let now = Date()
        if payload == lastPayload, now.timeIntervalSince(lastPayloadAt) < 2 { return }
        lastPayload = payload
        lastPayloadAt = now

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(payload)
    }
}
