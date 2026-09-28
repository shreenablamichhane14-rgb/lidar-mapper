import SwiftUI
import ARKit
import RoomPlan
import RealityKit

/// Placeholder first screen: proves the frameworks link and reports what this phone supports.
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

    /// Failing assertions from the units module, run once on this device.
    @State private var unitFailures: [String] = []
    @State private var unitsChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mapper").font(.largeTitle.bold())
            Text("Build 2: capability check").foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Image(systemName: row.1 ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(row.1 ? .green : .red)
                    Text(row.0)
                }
            }
            if unitsChecked {
                HStack {
                    Image(systemName: unitFailures.isEmpty ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(unitFailures.isEmpty ? .green : .red)
                    Text(unitFailures.isEmpty ? "Units self-test passed" : "Units self-test: \(unitFailures.count) failed")
                }
                ForEach(unitFailures.prefix(5), id: \.self) { failure in
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                }
                Text("Example: \(LengthFormat.both(3.845, prefs: .standard))")
                    .font(.callout)
            }
            Spacer()
        }
        .padding()
        .onAppear {
            let summary = rows.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            LogStore.shared.write("capabilities: \(summary)", category: "app")
            let failures = UnitsSelfTest.run()
            unitFailures = failures
            unitsChecked = true
            LogStore.shared.write("units self-test: \(failures.isEmpty ? "passed" : "\(failures.count) failed")", category: "app")
            for failure in failures {
                LogStore.shared.write("units self-test FAIL: \(failure)", category: "app")
            }
        }
    }
}
