import SwiftUI
import ARKit
import RoomPlan
import RealityKit

/// One module's on-device self-test: a name and a function returning failing assertions.
struct SelfTestSuite {
    let name: String
    let run: () -> [String]
}

/// Result of running one suite on this device.
struct SelfTestResult: Identifiable {
    let id = UUID()
    let name: String
    let failures: [String]
    let seconds: Double
}

/// Placeholder first screen: reports what this phone supports and runs every module's
/// self-test on the device, logging the results for `tools/phone_log.py`.
struct ContentView: View {
    private var rows: [(String, Bool)] {
        [
            ("LiDAR mesh (ARKit scene reconstruction)", ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)),
            ("Scene depth", ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)),
            ("RoomPlan", RoomCaptureSession.isSupported),
            ("Object Capture", ObjectCaptureSession.isSupported),
            ("On-device photogrammetry", PhotogrammetrySession.isSupported),
        ]
    }

    /// Every module with a self-test. New modules add one line here.
    private static let suites: [SelfTestSuite] = [
        SelfTestSuite(name: "Units", run: UnitsSelfTest.run),
        SelfTestSuite(name: "Geometry", run: GeometrySelfTest.run),
        SelfTestSuite(name: "Export", run: ExportSelfTest.run),
        SelfTestSuite(name: "Core", run: CoreSelfTest.run),
        SelfTestSuite(name: "Texturing", run: TexturingSelfTest.run),
        SelfTestSuite(name: "Coverage", run: CoverageSelfTest.run),
        SelfTestSuite(name: "Mesh processing", run: MeshProcessingSelfTest.run),
        SelfTestSuite(name: "Guidance UI", run: GuidanceUISelfTest.run),
        SelfTestSuite(name: "Pipeline", run: PipelineSelfTest.run),
        SelfTestSuite(name: "Mesh model", run: MeshModelSelfTest.run),
        SelfTestSuite(name: "Store", run: StoreSelfTest.run),
        SelfTestSuite(name: "Measure core", run: MeasureCoreSelfTest.run),
        SelfTestSuite(name: "Viewer3D", run: Viewer3DSelfTest.run),
        SelfTestSuite(name: "Capture core", run: CaptureCoreSelfTest.run),
        SelfTestSuite(name: "Room model", run: RoomModelSelfTest.run),
        SelfTestSuite(name: "Floor plan", run: FloorPlanSelfTest.run),
        SelfTestSuite(name: "Mesh record", run: MeshRecordSelfTest.run),
        SelfTestSuite(name: "Home UI", run: HomeUISelfTest.run),
        SelfTestSuite(name: "Texture job", run: TextureJobSelfTest.run),
    ]

    @State private var results: [SelfTestResult] = []
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Mapper").font(.largeTitle.bold())
                Text("Build 3: capability and self-test check").foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { row in
                    HStack {
                        Image(systemName: row.1 ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(row.1 ? .green : .red)
                        Text(row.0)
                    }
                }
                Divider()
                if running {
                    HStack {
                        ProgressView()
                        Text("Running self-tests...")
                    }
                }
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: result.failures.isEmpty ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(result.failures.isEmpty ? .green : .red)
                            Text(result.failures.isEmpty
                                 ? "\(result.name) self-test passed"
                                 : "\(result.name) self-test: \(result.failures.count) failed")
                            Spacer()
                            Text(String(format: "%.2f s", result.seconds))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(result.failures.prefix(5), id: \.self) { failure in
                            Text(failure).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !results.isEmpty {
                    Text("Example: \(LengthFormat.both(3.845, prefs: .standard))")
                        .font(.callout)
                }
            }
            .padding()
        }
        .task {
            await runAll()
        }
    }

    /// Runs the suites off the main thread one after another and logs every failure.
    private func runAll() async {
        guard results.isEmpty, !running else { return }
        running = true
        let summary = rows.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        LogStore.shared.write("capabilities: \(summary)", category: "app")
        for suite in ContentView.suites {
            let result = await Task.detached(priority: .userInitiated) { () -> SelfTestResult in
                let start = CFAbsoluteTimeGetCurrent()
                let failures = suite.run()
                return SelfTestResult(name: suite.name, failures: failures, seconds: CFAbsoluteTimeGetCurrent() - start)
            }.value
            results.append(result)
            let status = result.failures.isEmpty ? "passed" : "\(result.failures.count) failed"
            LogStore.shared.write("\(suite.name.lowercased()) self-test: \(status) in \(String(format: "%.2f", result.seconds)) s", category: "app")
            for failure in result.failures {
                LogStore.shared.write("\(suite.name.lowercased()) self-test FAIL: \(failure)", category: "app")
            }
        }
        running = false
    }
}
