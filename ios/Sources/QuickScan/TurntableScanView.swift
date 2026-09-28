import SwiftUI
import AVFoundation
import RealityKit

/// Turntable object scan: phone on a stand, the object turns. Three passes (side, higher
/// angle, turned over) of about 36 photos each, then on-device reconstruction and cleanup.
struct TurntableScanView: View {
    var onFinished: (SavedProject) -> Void
    var onCancel: () -> Void

    @StateObject private var camera: TurntableCamera
    private let folder: URL
    @State private var phase: Phase = .setup
    @State private var pass = 1
    @State private var progress: Double = 0
    @State private var errorText: String?

    private let shotsPerPass = 36
    private let passPrompts = [
        "Pass 1: object standing normally. Turn it one full circle.",
        "Pass 2: raise or tilt the phone to look down more, then turn the object one full circle.",
        "Pass 3: lay the object on its side (or upside down), then turn it one full circle.",
    ]

    enum Phase { case setup, capturing, betweenPasses, reconstructing, failed }

    init(onFinished: @escaping (SavedProject) -> Void, onCancel: @escaping () -> Void) {
        self.onFinished = onFinished
        self.onCancel = onCancel
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let base = ProjectStore.root.appendingPathComponent("\(stamp.string(from: Date())) Object", isDirectory: true)
        let images = base.appendingPathComponent("Images/", isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        folder = base
        _camera = StateObject(wrappedValue: TurntableCamera(imagesFolder: images))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if phase == .reconstructing {
                reconstructionView
            } else if phase == .failed {
                VStack(spacing: 16) {
                    Text(errorText ?? "Something went wrong.").foregroundStyle(.white).multilineTextAlignment(.center).padding()
                    Button("Close") { camera.stop(); onCancel() }.buttonStyle(.borderedProminent)
                }
            } else {
                CameraPreview(session: camera.session).ignoresSafeArea()
                overlay
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.shots) { _, count in
            if phase == .capturing && count >= shotsPerPass * pass {
                camera.pauseCapture()
                phase = .betweenPasses
            }
        }
        .onChange(of: camera.errorText) { _, text in
            if let text { errorText = text; phase = .failed }
        }
    }

    private var overlay: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") { camera.stop(); onCancel() }
                    .buttonStyle(.bordered).tint(.white)
                Spacer()
                Text("\(camera.shots) photos").font(.caption.bold()).padding(8)
                    .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
            }
            .padding(.horizontal)
            // aim guide: keep the object inside the circle
            Circle().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                .frame(width: 240, height: 240)
                .padding(.top, 40)
            if camera.tooMuchMotion && phase == .capturing {
                banner("Too fast. Turn more slowly.")
            }
            Spacer()
            controls.padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var controls: some View {
        switch phase {
        case .setup:
            VStack(spacing: 10) {
                banner("Put the phone on a stand or lean it on something so it does not move, 30 to 60 cm from the object. Use a plain surface and background (a sheet of paper helps). Keep the object inside the circle.")
                if !camera.hasDepth && camera.ready {
                    banner("Depth is not available on this camera, so sizes may not be to scale.")
                }
                primary(camera.ready ? "Start" : "Starting camera...") {
                    phase = .capturing
                    camera.beginCapture()
                }
                .disabled(!camera.ready)
            }
        case .capturing:
            VStack(spacing: 10) {
                banner(passPrompts[min(pass - 1, passPrompts.count - 1)])
                banner(camera.rhythm.rawValue)
                ProgressView(value: Double(camera.shots - shotsPerPass * (pass - 1)), total: Double(shotsPerPass))
                    .tint(.white).frame(maxWidth: 260)
                if camera.shots >= 20 {
                    Button("Finish and build the model") { finish() }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
        case .betweenPasses:
            VStack(spacing: 10) {
                banner("Pass \(pass) done. More passes give a more complete model.")
                if pass < passPrompts.count {
                    primary("Next pass") {
                        pass += 1
                        phase = .capturing
                        camera.beginCapture()
                    }
                }
                Button("Finish and build the model") { finish() }
                    .buttonStyle(.bordered).tint(.white)
            }
        case .reconstructing, .failed:
            EmptyView()
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(.callout).multilineTextAlignment(.center).padding(12)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white).padding(.horizontal)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.headline).frame(maxWidth: 280, minHeight: 44) }
            .buttonStyle(.borderedProminent)
    }

    private var reconstructionView: some View {
        VStack(spacing: 16) {
            Text("Building your 3D model").font(.title2.bold()).foregroundStyle(.white)
            ProgressView(value: progress).tint(.white).frame(maxWidth: 280)
            Text("\(Int(progress * 100)) %  This runs on the iPhone and can take a few minutes. Keep the app open.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8)).padding(.horizontal)
        }
    }

    private func finish() {
        camera.stop()
        phase = .reconstructing
        LogStore.shared.write("turntable finished with \(camera.shots) photos in \(pass) passes", category: "turntable")
        Task { @MainActor in
            do {
                let modelURL = try await ObjectReconstruction.build(folder: folder) { value in progress = value }
                let project = try ProjectStore.saveObject(folder: folder, modelURL: modelURL)
                onFinished(project)
            } catch {
                LogStore.shared.write("turntable reconstruction failed: \(error.localizedDescription)", category: "turntable")
                errorText = "The model could not be built from these photos (\(error.localizedDescription)). Use a plain background, more light, and keep the phone completely still."
                phase = .failed
            }
        }
    }
}

/// On-device photogrammetry from a folder of photos, with object masking so a still
/// background is ignored while the object turns.
enum ObjectReconstruction {
    @MainActor
    static func build(folder: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let images = folder.appendingPathComponent("Images/", isDirectory: true)
        let modelURL = folder.appendingPathComponent("object.usdz")
        var configuration = PhotogrammetrySession.Configuration()
        configuration.isObjectMaskingEnabled = true
        configuration.featureSensitivity = .high
        configuration.sampleOrdering = .sequential
        let samples = TurntableSamples(folder: images)
        LogStore.shared.write("turntable reconstruction: \(samples.urls.count) photos, masking each with Vision", category: "turntable")
        let session = try PhotogrammetrySession(input: samples, configuration: configuration)
        try session.process(requests: [.modelFile(url: modelURL)])
        var failure: Error?
        outputLoop: for try await output in session.outputs {
            switch output {
            case .requestProgress(_, let fraction):
                progress(fraction)
            case .requestError(_, let error):
                failure = error
            case .processingComplete, .processingCancelled:
                break outputLoop
            default:
                continue
            }
        }
        if let failure { throw failure }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw CocoaError(.fileNoSuchFile) }
        return modelURL
    }
}

/// Live camera preview for an AVCaptureSession.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
