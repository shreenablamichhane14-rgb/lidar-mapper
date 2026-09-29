import SwiftUI
import UIKit
import ARKit
import RoomPlan
import RealityKit

/// One module's on-device self-test: a name and a function returning failing assertions.
struct SelfTestSuite {
    /// Module name as shown and logged ("Units" logs as "units self-test: ...").
    let name: String
    /// The module's `<Module>SelfTest.run`: one line per failing check, empty when all pass.
    let run: () -> [String]
}

/// Result of running one suite on this device.
struct SelfTestResult: Identifiable {
    /// Identity of this result row.
    let id = UUID()
    /// The suite's name.
    let name: String
    /// Failing checks as "name: detail"; empty when the suite passed.
    let failures: [String]
    /// Wall time of the suite in seconds.
    let seconds: Double
}

/// The capability probe of the old first screen (RESEARCH 3.9 "Runtime capability gates"): the
/// five rows, logged at every launch as "capabilities: name=true, ..." exactly as before, plus
/// the memory facts. Main actor (`ObjectCaptureSession.isSupported` is main-actor isolated).
@MainActor enum AppCapabilityProbe {
    /// The five capability rows: name and whether this device supports it.
    static func rows() -> [(String, Bool)] {
        [
            (Copy.AppShell.probeMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)),
            (Copy.AppShell.probeDepth, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)),
            (Copy.AppShell.probeRoomPlan, RoomCaptureSession.isSupported),
            (Copy.AppShell.probeObjectCapture, ObjectCaptureSession.isSupported),
            (Copy.AppShell.probePhotogrammetry, PhotogrammetrySession.isSupported),
        ]
    }

    /// Logs the capability line and the memory line (launch probe, ARCHITECTURE 15 question 6).
    static func logLaunchFacts() {
        let summary = rows().map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        LogStore.shared.write("capabilities: \(summary)", category: "app")
        let available = ProcessingGuards.megabytes(ProcessingGuards.availableMemory())
        let physical = ProcessingGuards.megabytes(ProcessInfo.processInfo.physicalMemory)
        LogStore.shared.write("memory: available \(available), physical \(physical), model \(LogStore.hardwareModel)",
                              category: "app")
    }
}

/// Settings > Diagnostics (docs/MODULES.md 3.29): the capability rows, device facts
/// (`os_proc_available_memory`, `ProcessInfo.physicalMemory`, model, iOS version), every
/// module's self-test (run off main one after another, logged exactly as the old first screen
/// did), Demo Mode, snapshot recording, the capture delegate relay, the texture orientation
/// check (`ViewerDiagnostics.uvCheckerContent()` in a `ViewerContainer`) and Share Log.
struct DiagnosticsScreen: View {
    /// Every module with a self-test, one line per module. The lead adds new lines here.
    static let suites: [SelfTestSuite] = [
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
        SelfTestSuite(name: "Keyframes", run: KeyframesSelfTest.run),
        SelfTestSuite(name: "Room capture", run: RoomCaptureSelfTest.run),
        SelfTestSuite(name: "Quality", run: QualitySelfTest.run),
        SelfTestSuite(name: "Quality UI", run: QualityUISelfTest.run),
        SelfTestSuite(name: "Export UI", run: ExportUISelfTest.run),
        SelfTestSuite(name: "Scan UI", run: ScanUISelfTest.run),
        SelfTestSuite(name: "Results", run: ResultsSelfTest.run),
        SelfTestSuite(name: "App shell", run: AppShellSelfTest.run),
        SelfTestSuite(name: "Object model", run: ObjectModelSelfTest.run),
        SelfTestSuite(name: "Live mesh view", run: LiveMeshViewSelfTest.run),
    ]

    /// The shared self-test runner (the launch run and this screen show the same results).
    @ObservedObject private var tests: AppSelfTestRunner
    /// Diagnostics > Demo Mode (ScanUI's key).
    @AppStorage(SettingsKey.demoMode) private var demoMode = false
    /// Diagnostics > Record Scan Snapshots (ScanUI's key).
    @AppStorage(SettingsKey.recordSnapshots) private var recordSnapshots = false
    /// Diagnostics > Capture Delegate Relay (CaptureCore's key, absent means on).
    @AppStorage(SettingsKey.captureRelay) private var captureRelay = true
    /// The texture orientation check is showing.
    @State private var showsUVCheck = false

    /// Creates the screen.
    init() {
        _tests = ObservedObject(wrappedValue: AppSelfTestRunner.shared)
    }

    /// The diagnostics list.
    var body: some View {
        List {
            capabilitySection
            deviceSection
            selfTestSection
            testingSections
            toolsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Copy.AppShell.diagnosticsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsUVCheck) {
            AppUVCheckerView()
        }
        .task {
            if !tests.hasRun {
                await tests.runAll(priority: .userInitiated)
            }
        }
    }

    // MARK: - Sections

    /// The five capability rows.
    private var capabilitySection: some View {
        Section {
            ForEach(AppCapabilityProbe.rows(), id: \.0) { row in
                AppDiagnosticsRow(title: row.0, isOK: row.1,
                                  value: row.1 ? Copy.AppShell.supported : Copy.AppShell.notSupported)
            }
        } header: {
            Text(Copy.AppShell.supportSection)
        }
    }

    /// Model, iOS version and memory.
    private var deviceSection: some View {
        Section {
            AppFactRow(title: Copy.AppShell.deviceModel, value: LogStore.hardwareModel)
            AppFactRow(title: Copy.AppShell.systemVersion, value: UIDevice.current.systemVersion)
            AppFactRow(title: Copy.AppShell.availableMemory, value: memoryText(ProcessingGuards.availableMemory()))
            AppFactRow(title: Copy.AppShell.physicalMemory, value: memoryText(ProcessInfo.processInfo.physicalMemory))
        } header: {
            Text(Copy.AppShell.deviceSection)
        }
    }

    /// Self-test results with Run Again.
    private var selfTestSection: some View {
        Section {
            ForEach(tests.results) { result in
                AppSelfTestRow(result: result)
            }
            if tests.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(Copy.AppShell.runningSelfTests)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await tests.runAll(priority: .userInitiated) }
                } label: {
                    Label(Copy.AppShell.runSelfTests, systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text(Copy.AppShell.selfTests)
        }
    }

    /// Demo Mode and snapshots, then the capture relay, each with its footer.
    @ViewBuilder private var testingSections: some View {
        Section {
            Toggle(Copy.AppShell.demoMode, isOn: $demoMode)
                .onChange(of: demoMode) { _, isOn in
                    DiagnosticsScreen.log("demo mode \(isOn ? "on" : "off")")
                }
            Toggle(Copy.AppShell.recordSnapshots, isOn: $recordSnapshots)
                .onChange(of: recordSnapshots) { _, isOn in
                    DiagnosticsScreen.log("record snapshots \(isOn ? "on" : "off")")
                }
        } header: {
            Text(Copy.AppShell.testingSection)
        } footer: {
            Text(Copy.AppShell.demoModeFooter)
        }
        Section {
            Toggle(Copy.AppShell.captureRelay, isOn: $captureRelay)
                .onChange(of: captureRelay) { _, isOn in
                    DiagnosticsScreen.log("capture delegate relay \(isOn ? "on" : "off")")
                }
        } footer: {
            Text(Copy.AppShell.captureRelayFooter)
        }
    }

    /// Texture orientation check and Share Log.
    private var toolsSection: some View {
        Section {
            Button {
                showsUVCheck = true
            } label: {
                Label(Copy.AppShell.uvCheck, systemImage: "checkerboard.rectangle")
            }
            AppShareLogLink()
        }
    }

    // MARK: - Helpers

    /// Bytes as a memory size ("5.9 GB").
    private func memoryText(_ bytes: UInt64) -> String {
        let clamped = Int64(clamping: bytes)
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .memory)
    }

    /// Writes one line to the app log.
    static func log(_ message: String) {
        LogStore.shared.write("diagnostics: " + message, category: AppRouter.logCategory)
    }
}

/// A capability row: check or cross, the name, and a VoiceOver value.
struct AppDiagnosticsRow: View {
    /// The capability name.
    let title: String
    /// Supported or passed.
    let isOK: Bool
    /// VoiceOver value ("Yes" or "No").
    let value: String

    /// The row.
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOK ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(isOK ? Color.green : Color.red)
                .accessibilityHidden(true)
            Text(title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(value))
    }
}

/// A fact row: title on the leading side, value on the trailing side (stacked at large text).
struct AppFactRow: View {
    /// What the value is.
    let title: String
    /// The value.
    let value: String

    /// The row.
    var body: some View {
        LabeledContent(title, value: value)
            .textSelection(.enabled)
    }
}

/// One self-test result: status, name, time and the first five failures.
struct AppSelfTestRow: View {
    /// The result.
    let result: SelfTestResult

    /// The row.
    var body: some View {
        let passed = result.failures.isEmpty
        let title = passed ? Copy.AppShell.selfTestPassed(result.name)
            : Copy.AppShell.selfTestFailed(result.name, count: result.failures.count)
        let time = Copy.AppShell.seconds(String(format: "%.2f", result.seconds))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(passed ? Color.green : Color.red)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 8)
                Text(time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(result.failures.prefix(5).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
