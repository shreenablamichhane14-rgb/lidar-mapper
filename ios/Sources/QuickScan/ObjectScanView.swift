import SwiftUI
import RealityKit
import ModelIO

/// Object scan with Apple's Object Capture: guided photo capture around the object,
/// then an on-device photogrammetry reconstruction into a textured USDZ with real scale.
struct ObjectScanView: View {
    var onFinished: (SavedProject) -> Void
    var onCancel: () -> Void

    @State private var session: ObjectCaptureSession?
    @State private var folder: URL?
    @State private var reconstructing = false
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var detectionFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if reconstructing {
                reconstructionView
            } else if let session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                captureOverlay(session)
            } else if let errorText {
                failureView(errorText)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task { await run() }
    }

    // MARK: - Capture

    private func run() async {
        guard session == nil, !reconstructing else { return }
        guard ObjectCaptureSession.isSupported else {
            errorText = "This iPhone does not support object scanning."
            return
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        let base = ProjectStore.root.appendingPathComponent("\(stamp.string(from: Date())) Object", isDirectory: true)
        let images = base.appendingPathComponent("Images/", isDirectory: true)
        let checkpoint = base.appendingPathComponent("Checkpoint/", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        } catch {
            errorText = "Could not create the scan folder: \(error.localizedDescription)"
            return
        }
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpoint
        let newSession = ObjectCaptureSession()
        newSession.start(imagesDirectory: images, configuration: configuration)
        folder = base
        session = newSession
        LogStore.shared.write("object capture started, max images \(newSession.maximumNumberOfInputImages)", category: "object")

        for await state in newSession.stateUpdates {
            switch state {
            case .completed:
                LogStore.shared.write("object capture completed with \(newSession.numberOfShotsTaken) shots", category: "object")
                await reconstruct()
                return
            case .failed(let error):
                LogStore.shared.write("object capture failed: \(error.localizedDescription)", category: "object")
                session = nil
                errorText = "The scan stopped: \(error.localizedDescription)"
                return
            default:
                continue
            }
        }
    }

    @ViewBuilder
    private func captureOverlay(_ session: ObjectCaptureSession) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel") {
                    session.cancel()
                    onCancel()
                }
                .buttonStyle(.bordered).tint(.white)
                Spacer()
                if case .capturing = session.state {
                    Text("\(session.numberOfShotsTaken) photos")
                        .font(.caption.bold()).padding(8)
                        .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white)
                }
            }
            .padding(.horizontal)
            if let hint = feedbackText(session.feedback) {
                Text(hint)
                    .font(.headline).padding(10)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
            Spacer()
            bottomControls(session)
                .padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func bottomControls(_ session: ObjectCaptureSession) -> some View {
        switch session.state {
        case .ready:
            VStack(spacing: 8) {
                instruction(detectionFailed
                            ? "Could not find the object. Put it on a table or the floor, point at it, and try again."
                            : "Place the object on a table or the floor with space around it. Point the circle at it.")
                primaryButton("Continue") {
                    detectionFailed = !session.startDetecting()
                }
            }
        case .detecting:
            VStack(spacing: 8) {
                instruction("Drag the box edges so the box fits the object, then start.")
                primaryButton("Start scanning") { session.startCapturing() }
                Button("Find the object again") { session.resetDetection() }
                    .foregroundStyle(.white)
            }
        case .capturing:
            if session.userCompletedScanPass {
                VStack(spacing: 8) {
                    instruction("Nice. For a complete model, scan again from a lower or higher angle, or turn the object over.")
                    primaryButton("Finish and build the model") { session.finish() }
                    HStack {
                        Button("Scan another angle") { session.beginNewScanPass() }
                        Button("Turn object over") { session.beginNewScanPassAfterFlip() }
                    }
                    .buttonStyle(.bordered).tint(.white)
                }
            } else {
                VStack(spacing: 8) {
                    instruction("Walk slowly all the way around the object. Keep it in the middle of the screen.")
                    if session.numberOfShotsTaken >= 20 {
                        Button("Finish now") { session.finish() }
                            .buttonStyle(.bordered).tint(.white)
                    }
                }
            }
        case .finishing:
            instruction("Saving photos...")
        default:
            EmptyView()
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.callout).multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .padding(.horizontal)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: 280, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }

    private func feedbackText(_ feedback: Set<ObjectCaptureSession.Feedback>) -> String? {
        let order: [ObjectCaptureSession.Feedback] = [.environmentTooDark, .environmentLowLight, .movingTooFast,
                                                      .objectTooClose, .objectTooFar, .outOfFieldOfView,
                                                      .objectNotDetected, .overCapturing, .objectNotFlippable]
        for item in order where feedback.contains(item) {
            switch item {
            case .environmentTooDark: return "Too dark. Turn on more lights."
            case .environmentLowLight: return "Lighting is poor."
            case .movingTooFast: return "Move slower."
            case .objectTooClose: return "Too close. Step back a little."
            case .objectTooFar: return "Too far. Move closer."
            case .outOfFieldOfView: return "Keep the object in view."
            case .objectNotDetected: return "Object not found. Point at it."
            case .overCapturing: return "Enough photos here. Move to another side."
            case .objectNotFlippable: return "This object should not be turned over."
            @unknown default: return nil
            }
        }
        return nil
    }

    // MARK: - Reconstruction

    private var reconstructionView: some View {
        VStack(spacing: 16) {
            Text("Building your 3D model").font(.title2.bold()).foregroundStyle(.white)
            ProgressView(value: progress).tint(.white).frame(maxWidth: 280)
            Text("\(Int(progress * 100)) %  This runs on the iPhone and can take a few minutes. Keep the app open.")
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal)
            if let errorText {
                Text(errorText).foregroundStyle(.red).padding(.horizontal)
                Button("Close") { onCancel() }.buttonStyle(.bordered).tint(.white)
            }
        }
    }

    private func failureView(_ text: String) -> some View {
        VStack(spacing: 16) {
            Text(text).foregroundStyle(.white).multilineTextAlignment(.center).padding()
            Button("Close") { onCancel() }.buttonStyle(.borderedProminent)
        }
    }

    private func reconstruct() async {
        guard let folder else { return }
        session = nil  // release the capture session before photogrammetry (memory and GPU)
        reconstructing = true
        progress = 0
        let images = folder.appendingPathComponent("Images/", isDirectory: true)
        let modelURL = folder.appendingPathComponent("object.usdz")
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            var configuration = PhotogrammetrySession.Configuration()
            configuration.checkpointDirectory = folder.appendingPathComponent("Checkpoint/", isDirectory: true)
            let photogrammetry = try PhotogrammetrySession(input: images, configuration: configuration)
            try photogrammetry.process(requests: [.modelFile(url: modelURL)])
            outputLoop: for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(_, let fraction):
                    progress = fraction
                case .requestError(_, let error):
                    errorText = "Could not build the model: \(error.localizedDescription)"
                    LogStore.shared.write("photogrammetry error: \(error.localizedDescription)", category: "object")
                case .processingComplete, .processingCancelled:
                    break outputLoop
                default:
                    continue
                }
            }
        } catch {
            errorText = "Could not build the model: \(error.localizedDescription)"
            LogStore.shared.write("photogrammetry failed: \(error.localizedDescription)", category: "object")
            return
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            if errorText == nil { errorText = "The model could not be built from these photos. Try more light and a matte object." }
            return
        }
        do {
            let project = try ProjectStore.saveObject(folder: folder, modelURL: modelURL)
            onFinished(project)
        } catch {
            errorText = "The model was built but could not be saved: \(error.localizedDescription)"
        }
    }
}

/// Result of an object scan: 3D model, size, exports.
struct ObjectResultView: View {
    let project: SavedProject
    @State private var showModel = false
    @State private var prefs = UnitPreferences.load()

    var body: some View {
        List {
            Section {
                Button { showModel = true } label: { Label("View 3D model", systemImage: "cube.transparent") }
                    .disabled(!FileManager.default.fileExists(atPath: project.objectModelURL.path))
            }
            if let size = project.report.objectSize, size.count == 3 {
                Section("Size (box around the object)") {
                    sizeRow("Width", size[0])
                    sizeRow("Depth", size[2])
                    sizeRow("Height", size[1])
                    HStack {
                        Text("Box volume")
                        Spacer()
                        Text(VolumeFormat.both(size[0] * size[1] * size[2], prefs: prefs)).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Export") {
                share("3D model with photo texture (USDZ)", project.objectModelURL)
                share("3D model (OBJ)", project.folder.appendingPathComponent("object.obj"))
                share("For 3D printing (STL)", project.folder.appendingPathComponent("object.stl"))
            }
            Section {
                Picker("Units", selection: $prefs.system) {
                    ForEach(UnitSystem.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: prefs) { _, newValue in newValue.save() }
            } footer: {
                Text("Sizes come from the LiDAR-scaled photo reconstruction and are estimates. The original photos are kept in the project folder.")
            }
        }
        .navigationTitle(project.report.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModel) {
            QuickLookView(url: project.objectModelURL).ignoresSafeArea()
        }
    }

    private func sizeRow(_ title: String, _ meters: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(LengthFormat.both(meters, prefs: prefs)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func share(_ title: String, _ url: URL) -> some View {
        if FileManager.default.fileExists(atPath: url.path) {
            ShareLink(item: url) { Label(title, systemImage: "square.and.arrow.up") }
        } else {
            Label("\(title): not available", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
    }
}
