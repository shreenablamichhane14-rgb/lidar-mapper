import SwiftUI
import QuickLook
import RoomPlan

/// Home: New Scan, saved projects, diagnostics.
struct HomeView: View {
    @State private var projects: [SavedProject] = ProjectStore.list()
    @State private var scanning = false
    @State private var objectScanning = false
    @State private var path: [SavedProject] = []
    @State private var saveError: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section(Copy.Home.newScan) {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan a room", systemImage: "square.split.bottomrightquarter")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!RoomCaptureSession.isSupported)
                    Button {
                        objectScanning = true
                    } label: {
                        Label("Scan an object", systemImage: "cube")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                    if !RoomCaptureSession.isSupported {
                        Text("This iPhone has no LiDAR scanner, so room scanning is not available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let saveError {
                        Text(saveError).font(.footnote).foregroundStyle(.red)
                    }
                }
                Section(Copy.Home.title) {
                    if projects.isEmpty {
                        Text("No scans yet. Tap New Scan, then walk slowly around the room.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(projects) { project in
                        NavigationLink(value: project) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.report.name).font(.headline)
                                Text(summary(project.report)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { ProjectStore.archive(projects[index]) }
                        projects = ProjectStore.list()
                    }
                }
                Section {
                    NavigationLink("Diagnostics") { ContentView() }
                } footer: {
                    Text(Copy.Home.privacyFooter)
                }
            }
            .navigationTitle("Mapper")
            .navigationDestination(for: SavedProject.self) { project in
                if project.report.isObject {
                    ObjectResultView(project: project)
                } else {
                    RoomResultView(project: project)
                }
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            RoomScanView(onFinished: { room in
                do {
                    let project = try ProjectStore.save(room: room)
                    projects = ProjectStore.list()
                    saveError = nil
                    scanning = false
                    path = [project]
                } catch {
                    saveError = "Could not save the scan: \(error.localizedDescription)"
                    scanning = false
                }
            }, onCancel: {
                scanning = false
            })
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $objectScanning) {
            ObjectScanView(onFinished: { project in
                projects = ProjectStore.list()
                objectScanning = false
                path = [project]
            }, onCancel: {
                objectScanning = false
                projects = ProjectStore.list()
            })
        }
    }

    private func summary(_ report: RoomReport) -> String {
        let prefs = UnitPreferences.load()
        var parts: [String] = []
        if report.isObject, let size = report.objectSize, size.count == 3 {
            return "Object · " + [size[0], size[2], size[1]].map { LengthFormat.primary($0, prefs: prefs) }.joined(separator: " × ")
        }
        if let area = report.floorArea { parts.append(AreaFormat.primary(area, prefs: prefs)) }
        parts.append("\(report.walls.count) walls, \(report.doors.count) doors, \(report.windows.count) windows")
        return parts.joined(separator: " · ")
    }
}

/// Result of one scan: 3D model, floor plan, measurements and exports.
struct RoomResultView: View {
    let project: SavedProject
    @State private var showModel = false
    @State private var prefs = UnitPreferences.load()

    private var report: RoomReport { project.report }

    var body: some View {
        List {
            Section {
                Button {
                    showModel = true
                } label: {
                    Label("View 3D model", systemImage: "cube.transparent")
                }
                .disabled(!FileManager.default.fileExists(atPath: project.modelURL.path))
            }
            Section("Floor plan") {
                FloorPlanCanvas(plan: report.plan(prefs: prefs))
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section("Room") {
                row("Floor area", report.floorArea.map { AreaFormat.both($0, prefs: prefs) } ?? "Not measured")
                row("Perimeter", LengthFormat.both(report.perimeter, prefs: prefs))
                row("Ceiling height", LengthFormat.both(report.ceilingHeight, prefs: prefs))
                row("Wall area (minus doors and windows)", AreaFormat.both(report.wallArea, prefs: prefs))
            }
            Section("Walls") {
                ForEach(Array(report.walls.enumerated()), id: \.offset) { index, wall in
                    row("Wall \(index + 1)", "\(LengthFormat.primary(wall.length, prefs: prefs)) × \(LengthFormat.primary(wall.height, prefs: prefs))",
                        note: wall.confidence == "low" ? "Low confidence, rescan this section" : nil)
                }
            }
            if !report.doors.isEmpty || !report.windows.isEmpty {
                Section("Doors and windows") {
                    ForEach(Array((report.doors + report.windows).enumerated()), id: \.offset) { _, item in
                        row(item.kind.capitalized, "\(LengthFormat.primary(item.length, prefs: prefs)) × \(LengthFormat.primary(item.height, prefs: prefs))")
                    }
                }
            }
            if !report.objects.isEmpty {
                Section("Detected objects (editable later)") {
                    ForEach(Array(report.objects.enumerated()), id: \.offset) { _, object in
                        row(object.category.capitalized,
                            "\(LengthFormat.primary(object.width, prefs: prefs)) W × \(LengthFormat.primary(object.depth, prefs: prefs)) D × \(LengthFormat.primary(object.height, prefs: prefs)) H")
                    }
                }
            }
            Section("Export") {
                exportLink("3D model (USDZ)", project.modelURL)
                exportLink("Floor plan (PDF)", project.pdfURL)
                exportLink("Floor plan for CAD (DXF)", project.dxfURL)
                exportLink("Floor plan (SVG)", project.svgURL)
            }
            Section {
                Picker("Units", selection: $prefs.system) {
                    ForEach(UnitSystem.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: prefs) { _, newValue in newValue.save() }
            } footer: {
                Text("Measurements come from the iPhone LiDAR scanner and are estimates, typically within about 1 to 2 percent. They are not survey grade.")
            }
        }
        .navigationTitle(report.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModel) {
            QuickLookView(url: project.modelURL).ignoresSafeArea()
        }
    }

    private func row(_ title: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func exportLink(_ title: String, _ url: URL) -> some View {
        if FileManager.default.fileExists(atPath: url.path) {
            ShareLink(item: url) { Label(title, systemImage: "square.and.arrow.up") }
        } else {
            Label("\(title): not available", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
    }
}

/// Draws a Plan2D (lines, polylines, dimensions and labels) fitted to the view.
struct FloorPlanCanvas: View {
    let plan: Plan2D

    var body: some View {
        Canvas { context, size in
            var points: [SIMD2<Double>] = []
            for entity in plan.entities {
                switch entity.geometry {
                case let .line(from, to): points += [from, to]
                case let .polyline(pts, _): points += pts
                case let .dimension(from, to, _, _): points += [from, to]
                case let .text(position, _, _, _): points.append(position)
                case let .circle(center, radius): points += [center - SIMD2(radius, radius), center + SIMD2(radius, radius)]
                case let .arc(center, radius, _, _): points += [center - SIMD2(radius, radius), center + SIMD2(radius, radius)]
                }
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
                context.draw(Text("No floor plan in this scan").foregroundColor(.secondary),
                             at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let margin = 24.0
            let spanX = max(maxX - minX, 0.5), spanY = max(maxY - minY, 0.5)
            let scale = min((Double(size.width) - 2 * margin) / spanX, (Double(size.height) - 2 * margin) / spanY)
            let offsetX = (Double(size.width) - spanX * scale) / 2
            let offsetY = (Double(size.height) - spanY * scale) / 2
            func map(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(x: offsetX + (p.x - minX) * scale, y: offsetY + (maxY - p.y) * scale)
            }
            func color(_ layer: String) -> Color {
                switch layer {
                case "Walls": return .primary
                case "Doors": return .blue
                case "Windows": return .teal
                case "Objects": return .gray
                case "Dimensions": return .red
                default: return .primary
                }
            }
            for entity in plan.entities {
                let c = color(entity.layer)
                switch entity.geometry {
                case let .line(from, to):
                    var path = Path()
                    path.move(to: map(from)); path.addLine(to: map(to))
                    context.stroke(path, with: .color(c), lineWidth: entity.layer == "Walls" ? 4 : 3)
                case let .polyline(pts, closed):
                    guard let first = pts.first else { continue }
                    var path = Path()
                    path.move(to: map(first))
                    for p in pts.dropFirst() { path.addLine(to: map(p)) }
                    if closed { path.closeSubpath() }
                    context.stroke(path, with: .color(c), lineWidth: 1)
                case let .dimension(from, to, _, label):
                    let mid = map((from + to) / 2)
                    context.draw(Text(label).font(.system(size: 9)).foregroundColor(.red), at: CGPoint(x: mid.x, y: mid.y - 9))
                case let .text(position, _, string, _):
                    context.draw(Text(string).font(.caption.bold()), at: map(position))
                case .circle, .arc:
                    continue
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Apple's QuickLook viewer for the USDZ model (orbit, zoom, and view in AR).
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
