import AVFoundation
import UIKit
import QuartzCore

/// Turntable capture: the phone stays still and the object turns. Takes HEIC photos with
/// embedded LiDAR depth (for real scale) and decides by itself when to shoot:
/// - stop-and-go (turning by hand): shoot each time the object has moved and is still again
/// - continuous (motorized turntable): shoot at a fixed interval while it turns
final class TurntableCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Rhythm: String {
        case waiting = "Waiting for the object to turn"
        case stopAndGo = "Turn a little, then hold still. A click means a photo was taken."
        case continuous = "Turntable detected. Keep it turning slowly."
    }

    @Published private(set) var shots = 0
    @Published private(set) var rhythm: Rhythm = .waiting
    @Published private(set) var ready = false
    @Published private(set) var hasDepth = false
    @Published private(set) var errorText: String?
    @Published private(set) var tooMuchMotion = false

    let session = AVCaptureSession()
    let imagesFolder: URL

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "turntable.camera")
    private var device: AVCaptureDevice?

    // All below are only touched on `queue`.
    private var capturing = false
    private var photoInFlight = false
    private var shotIndex = 0
    private var previous: [UInt8] = []
    private var stillSince: Double?
    private var movingSince: Double?
    private var movedSinceLastShot = true
    private var lastShot: Double = 0
    private var mode: Rhythm = .waiting

    /// Luma difference (0-255 scale, averaged over a center grid) above which the object is
    /// moving, and below which it is still.
    private let movingThreshold: Float = 2.5
    private let stillThreshold: Float = 1.0
    private let stillHold: Double = 0.35
    private let continuousAfter: Double = 4.0
    private let continuousInterval: Double = 1.2

    init(imagesFolder: URL) {
        self.imagesFolder = imagesFolder
        super.init()
    }

    // MARK: - Session

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.errorText = "Camera access is off. Turn it on in Settings > Mapper." }
                return
            }
            self.queue.async { self.configure() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        guard let camera = lidar ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorText = "The camera could not be started." }
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        let depth = photoOutput.isDepthDataDeliverySupported
        photoOutput.isDepthDataDeliveryEnabled = depth
        session.commitConfiguration()
        device = camera
        session.startRunning()
        LogStore.shared.write("turntable camera started, lidar \(lidar != nil), depth \(depth)", category: "turntable")
        DispatchQueue.main.async {
            self.hasDepth = depth
            self.ready = true
        }
    }

    /// Starts shooting. Locks exposure, focus and white balance after a moment so every photo matches.
    func beginCapture() {
        queue.async {
            self.capturing = true
            self.movedSinceLastShot = true
            self.stillSince = nil
            self.movingSince = nil
        }
        queue.asyncAfter(deadline: .now() + 1.0) { self.lockCamera() }
    }

    /// Pauses shooting (between passes).
    func pauseCapture() {
        queue.async { self.capturing = false }
    }

    func stop() {
        queue.async {
            self.capturing = false
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func lockCamera() {
        guard let camera = device, (try? camera.lockForConfiguration()) != nil else { return }
        if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked }
        if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked }
        if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
        camera.unlockForConfiguration()
    }

    // MARK: - Motion analysis (video frames)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let gridX = 48, gridY = 36
        var small = [UInt8](repeating: 0, count: gridX * gridY)
        for gy in 0..<gridY {
            let y = height / 5 + gy * (height * 3 / 5) / gridY
            for gx in 0..<gridX {
                let x = width / 5 + gx * (width * 3 / 5) / gridX
                small[gy * gridX + gx] = pixels[y * rowBytes + x]
            }
        }
        var difference: Float = 0
        if previous.count == small.count {
            var sum = 0
            for i in 0..<small.count { sum += abs(Int(small[i]) - Int(previous[i])) }
            difference = Float(sum) / Float(small.count)
        }
        previous = small
        decide(difference: difference, now: CACurrentMediaTime())
    }

    private func decide(difference: Float, now: Double) {
        let moving = difference > movingThreshold
        let still = difference < stillThreshold
        if moving {
            movingSince = movingSince ?? now
            stillSince = nil
            movedSinceLastShot = true
        } else if still {
            stillSince = stillSince ?? now
            movingSince = nil
        }
        let blurRisk = difference > movingThreshold * 6
        DispatchQueue.main.async { self.tooMuchMotion = blurRisk }
        guard capturing, !photoInFlight else { return }

        if let since = movingSince, now - since > continuousAfter, mode != .continuous {
            setMode(.continuous)
        }
        switch mode {
        case .continuous:
            if !moving && !still && now - lastShot >= continuousInterval && !blurRisk {
                shoot(now: now)
            } else if moving && now - lastShot >= continuousInterval && !blurRisk {
                shoot(now: now)
            } else if let since = stillSince, now - since > 2.0 {
                setMode(.stopAndGo)
            }
        case .stopAndGo, .waiting:
            if let since = stillSince, now - since >= stillHold, movedSinceLastShot {
                if mode == .waiting && shotIndex > 0 { setMode(.stopAndGo) }
                shoot(now: now)
            }
        }
    }

    private func setMode(_ newMode: Rhythm) {
        mode = newMode
        LogStore.shared.write("turntable rhythm: \(newMode)", category: "turntable")
        DispatchQueue.main.async { self.rhythm = newMode }
    }

    // MARK: - Photos

    private func shoot(now: Double) {
        photoInFlight = true
        lastShot = now
        movedSinceLastShot = false
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        settings.photoQualityPrioritization = .balanced
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async {
            self.photoInFlight = false
            guard let data else {
                LogStore.shared.write("turntable photo failed: \(error?.localizedDescription ?? "no data")", category: "turntable")
                return
            }
            self.shotIndex += 1
            let url = self.imagesFolder.appendingPathComponent(String(format: "IMG_%04ld.HEIC", self.shotIndex))
            do {
                try data.write(to: url, options: .atomic)
                let count = self.shotIndex
                DispatchQueue.main.async {
                    self.shots = count
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            } catch {
                LogStore.shared.write("turntable photo save failed: \(error.localizedDescription)", category: "turntable")
            }
        }
    }
}
