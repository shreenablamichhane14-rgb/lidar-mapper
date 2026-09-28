import SwiftUI
import UIKit
import RoomPlan

/// Full-screen room scan using Apple's RoomCaptureView (live guidance, coaching,
/// wall/door/window/object detection, and the processed 3D result).
struct RoomScanView: UIViewControllerRepresentable {
    var onFinished: (CapturedRoom) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> RoomCaptureViewController {
        let controller = RoomCaptureViewController()
        controller.onFinished = onFinished
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: RoomCaptureViewController, context: Context) {}
}

/// Hosts RoomCaptureView with Cancel / Done / Save buttons.
final class RoomCaptureViewController: UIViewController, RoomCaptureViewDelegate {
    var onFinished: ((CapturedRoom) -> Void)?
    var onCancel: (() -> Void)?

    private var roomCaptureView: RoomCaptureView?
    private var finalResult: CapturedRoom?
    private var isScanning = false
    private let doneButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)
        roomCaptureView = captureView

        configure(cancelButton, title: "Cancel", action: #selector(cancelTapped))
        configure(doneButton, title: "Done", action: #selector(doneTapped))
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            doneButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configure(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 18
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        view.addSubview(button)
    }

    private func startSession() {
        guard !isScanning, let captureView = roomCaptureView else { return }
        isScanning = true
        finalResult = nil
        doneButton.setTitle("Done", for: .normal)
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        LogStore.shared.write("room scan started", category: "scan")
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func stopSession() {
        guard isScanning, let captureView = roomCaptureView else { return }
        isScanning = false
        captureView.captureSession.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        LogStore.shared.write("room scan stopped", category: "scan")
    }

    @objc private func cancelTapped() {
        stopSession()
        onCancel?()
    }

    @objc private func doneTapped() {
        if let result = finalResult {
            onFinished?(result)
            return
        }
        stopSession()
        doneButton.setTitle("Processing...", for: .normal)
        doneButton.isEnabled = false
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            LogStore.shared.write("room scan data error: \(error.localizedDescription)", category: "scan")
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            LogStore.shared.write("room processing error: \(error.localizedDescription)", category: "scan")
        }
        finalResult = processedResult
        doneButton.setTitle("Save", for: .normal)
        doneButton.isEnabled = true
        LogStore.shared.write("room processed: walls \(processedResult.walls.count), doors \(processedResult.doors.count), windows \(processedResult.windows.count), objects \(processedResult.objects.count)", category: "scan")
    }
}
