import ARKit

/// What decides the ARKit configuration of one capture: the scan mode and the user's scan
/// settings. Engines hand it to `ARSessionHub(profile:)` and recorders receive it in
/// `ScanRecorder.beginRecording(into:profile:startTimestamp:)`.
struct ScanProfile: Equatable, Sendable {
    /// Scan mode of the capture (Room, House, Quick Measure and so on).
    var mode: ScanMode
    /// Detail, photo, room finding and distance settings of the capture.
    var settings: ScanSettings

    /// Creates a profile.
    init(mode: ScanMode, settings: ScanSettings) {
        self.mode = mode
        self.settings = settings
    }

    /// Plane detection only for Quick Measure (D14); planes flatten the raw mesh.
    var wantsPlaneDetection: Bool { mode == .quickMeasure }
}

/// Builds Mapper's one `ARWorldTrackingConfiguration` (ARCHITECTURE 4.1, D14) and describes
/// configurations for the diagnostics log (D22). Pure: nothing here runs a session.
enum ScanConfigurationFactory {
    /// sceneReconstruction .meshWithClassification (else .mesh) when supported; frameSemantics
    /// [.sceneDepth] when supported; planeDetection [] unless `wantsPlaneDetection` then
    /// [.horizontal, .vertical]; environmentTexturing .none; isLightEstimationEnabled true;
    /// default video format (never 4K or HDR).
    static func make(_ profile: ScanProfile) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = [.sceneDepth]
        }
        if profile.wantsPlaneDetection {
            configuration.planeDetection = [.horizontal, .vertical]
        } else {
            configuration.planeDetection = []
        }
        configuration.environmentTexturing = ARWorldTrackingConfiguration.EnvironmentTexturing.none
        configuration.isLightEstimationEnabled = true
        // videoFormat is deliberately left at its default (RESEARCH 3.8 disputed 10).
        return configuration
    }

    /// True when the device can reconstruct a LiDAR mesh (`ARWorldTrackingConfiguration`).
    static var supportsMesh: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// True when the device delivers LiDAR scene depth (`ARWorldTrackingConfiguration`).
    static var supportsDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Human-readable lines for CaptureSessionRecord.configLog, one fact per line
    /// ("name: value"). A nil configuration gives one line saying so.
    static func describe(_ configuration: ARConfiguration?) -> [String] {
        guard let configuration else { return ["configuration: none"] }
        var lines: [String] = []
        lines.append("type: \(String(describing: type(of: configuration)))")
        lines.append("frameSemantics: \(semanticsText(configuration.frameSemantics))")
        lines.append("lightEstimation: \(configuration.isLightEstimationEnabled)")
        lines.append("videoFormat: \(videoFormatText(configuration.videoFormat))")
        if let world = configuration as? ARWorldTrackingConfiguration {
            lines.append("sceneReconstruction: \(reconstructionText(world.sceneReconstruction))")
            lines.append("planeDetection: \(planeText(world.planeDetection))")
            lines.append("environmentTexturing: \(texturingText(world.environmentTexturing))")
            lines.append("initialWorldMap: \(world.initialWorldMap != nil)")
        }
        return lines
    }

    // MARK: - Text helpers

    /// Frame semantics as names ("sceneDepth", "smoothedSceneDepth"), or the raw value for
    /// anything else, or "none".
    static func semanticsText(_ semantics: ARConfiguration.FrameSemantics) -> String {
        var names: [String] = []
        var rest = semantics
        if semantics.contains(.sceneDepth) {
            names.append("sceneDepth")
            rest.remove(.sceneDepth)
        }
        if semantics.contains(.smoothedSceneDepth) {
            names.append("smoothedSceneDepth")
            rest.remove(.smoothedSceneDepth)
        }
        if !rest.isEmpty { names.append("other(\(rest.rawValue))") }
        return names.isEmpty ? "none" : names.joined(separator: " ")
    }

    /// Scene reconstruction as "meshWithClassification", "mesh" or "none".
    static func reconstructionText(_ reconstruction: ARConfiguration.SceneReconstruction) -> String {
        if reconstruction.contains(.meshWithClassification) { return "meshWithClassification" }
        if reconstruction.contains(.mesh) { return "mesh" }
        return reconstruction.isEmpty ? "none" : "other(\(reconstruction.rawValue))"
    }

    /// Plane detection as "horizontal vertical", "horizontal", "vertical" or "none".
    static func planeText(_ detection: ARWorldTrackingConfiguration.PlaneDetection) -> String {
        var names: [String] = []
        if detection.contains(.horizontal) { names.append("horizontal") }
        if detection.contains(.vertical) { names.append("vertical") }
        return names.isEmpty ? "none" : names.joined(separator: " ")
    }

    /// Environment texturing as its case name.
    static func texturingText(_ texturing: ARWorldTrackingConfiguration.EnvironmentTexturing) -> String {
        switch texturing {
        case .none: return "none"
        case .manual: return "manual"
        case .automatic: return "automatic"
        @unknown default: return "unknown(\(texturing.rawValue))"
        }
    }

    /// Video format as "1920x1440 @ 60 fps, hiRes true".
    static func videoFormatText(_ format: ARConfiguration.VideoFormat) -> String {
        let width = Int(format.imageResolution.width.rounded())
        let height = Int(format.imageResolution.height.rounded())
        let hiRes = format.isRecommendedForHighResolutionFrameCapturing
        return "\(width)x\(height) @ \(format.framesPerSecond) fps, hiRes \(hiRes)"
    }

    /// Run options as names, for the log ("none" for the empty set).
    static func runOptionsText(_ options: ARSession.RunOptions) -> String {
        var names: [String] = []
        if options.contains(.resetTracking) { names.append("resetTracking") }
        if options.contains(.removeExistingAnchors) { names.append("removeExistingAnchors") }
        if options.contains(.stopTrackedRaycasts) { names.append("stopTrackedRaycasts") }
        if options.contains(.resetSceneReconstruction) { names.append("resetSceneReconstruction") }
        return names.isEmpty ? "none" : names.joined(separator: " ")
    }
}
