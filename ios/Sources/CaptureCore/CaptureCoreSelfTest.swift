import ARKit
import CoreVideo
import simd

/// Plain-Swift checks for CaptureCore (no XCTest). `run()` returns one line per failing check
/// ("name: detail"); empty means all passed. Deterministic, well under 2 s, and it never runs
/// an ARSession, the camera or the network: it only builds configurations, feeds the pure
/// watchdog, tracking and memory logic with synthetic timestamps, unpacks hand-made byte
/// buffers and drives the thermal and storage monitors through injected readers. No files.
enum CaptureCoreSelfTest {
    /// Runs every check and returns the failures.
    static func run() -> [String] {
        var failures: [String] = []
        checkConfiguration(&failures)
        checkRelocalization(&failures)
        checkWatchdog(&failures)
        checkStorageAndMemory(&failures)
        checkThermal(&failures)
        checkTracking(&failures)
        checkUnpacking(&failures)
        checkSpeedsAndStats(&failures)
        return failures
    }

    /// Appends "name: detail" when `condition` is false.
    private static func expect(_ failures: inout [String], _ name: String, _ condition: Bool,
                               _ detail: @autoclosure () -> String = "failed") {
        if !condition { failures.append("\(name): \(detail())") }
    }

    /// True when `a` and `b` differ by at most `tolerance`.
    private static func near(_ a: Float, _ b: Float, _ tolerance: Float) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Configuration (D14)

    /// Profile plane rule, factory settings per mode, support-dependent fields, describe().
    private static func checkConfiguration(_ f: inout [String]) {
        for mode in ScanMode.allCases {
            let profile = ScanProfile(mode: mode, settings: ScanSettings.defaults(for: mode))
            expect(&f, "profile.planes.\(mode.rawValue)", profile.wantsPlaneDetection == (mode == .quickMeasure),
                   "wantsPlaneDetection \(profile.wantsPlaneDetection)")
        }
        let noPlaneModes: [ScanMode] = [.room, .house, .advancedSpace, .object, .advancedObject]
        for mode in noPlaneModes {
            let configuration = ScanConfigurationFactory.make(ScanProfile(mode: mode, settings: .defaults(for: mode)))
            expect(&f, "make.planes.\(mode.rawValue)", configuration.planeDetection.isEmpty,
                   ScanConfigurationFactory.planeText(configuration.planeDetection))
            expect(&f, "make.texturing.\(mode.rawValue)",
                   configuration.environmentTexturing == ARWorldTrackingConfiguration.EnvironmentTexturing.none,
                   ScanConfigurationFactory.texturingText(configuration.environmentTexturing))
            expect(&f, "make.light.\(mode.rawValue)", configuration.isLightEstimationEnabled)
        }
        let quick = ScanConfigurationFactory.make(ScanProfile(mode: .quickMeasure, settings: .defaults(for: .quickMeasure)))
        let bothPlanes: ARWorldTrackingConfiguration.PlaneDetection = [.horizontal, .vertical]
        expect(&f, "make.planes.quickMeasure", quick.planeDetection == bothPlanes,
               ScanConfigurationFactory.planeText(quick.planeDetection))
        expect(&f, "make.light.quickMeasure", quick.isLightEstimationEnabled)

        let room = ScanConfigurationFactory.make(ScanProfile(mode: .room, settings: .room))
        if ScanConfigurationFactory.supportsMesh {
            expect(&f, "make.mesh", room.sceneReconstruction.contains(.mesh),
                   ScanConfigurationFactory.reconstructionText(room.sceneReconstruction))
        } else {
            expect(&f, "make.noMesh", room.sceneReconstruction.isEmpty,
                   ScanConfigurationFactory.reconstructionText(room.sceneReconstruction))
        }
        let depthOnly: ARConfiguration.FrameSemantics = [.sceneDepth]
        if ScanConfigurationFactory.supportsDepth {
            expect(&f, "make.depth", room.frameSemantics == depthOnly,
                   ScanConfigurationFactory.semanticsText(room.frameSemantics))
        } else {
            expect(&f, "make.noDepth", !room.frameSemantics.contains(.sceneDepth),
                   ScanConfigurationFactory.semanticsText(room.frameSemantics))
        }
        expect(&f, "make.noSmoothedDepth", !room.frameSemantics.contains(.smoothedSceneDepth))
        expect(&f, "describe.nil", ScanConfigurationFactory.describe(nil) == ["configuration: none"])
        let lines = ScanConfigurationFactory.describe(room)
        expect(&f, "describe.planes", lines.contains("planeDetection: none"), lines.joined(separator: "; "))
        expect(&f, "describe.texturing", lines.contains("environmentTexturing: none"), lines.joined(separator: "; "))
        expect(&f, "runOptions.none", ScanConfigurationFactory.runOptionsText([]) == "none")
        expect(&f, "runOptions.reset", ScanConfigurationFactory.runOptionsText([.resetTracking]) == "resetTracking")
    }

    // MARK: - Relocalization configuration (MODULES 3.30b)

    /// `make(profile, initialWorldMap: nil)` equals `make(profile)` field by field for every mode,
    /// has no world map, describes itself with "initialWorldMap: false", and the run event text
    /// names the options and the world map flag. No ARWorldMap is built (ARKit makes one only
    /// from a running session or a saved archive).
    private static func checkRelocalization(_ f: inout [String]) {
        for mode in ScanMode.allCases {
            let profile = ScanProfile(mode: mode, settings: ScanSettings.defaults(for: mode))
            let plain = ScanConfigurationFactory.make(profile)
            let noMap = ScanConfigurationFactory.make(profile, initialWorldMap: nil)
            let noMapIsNil: Bool = noMap.initialWorldMap == nil
            let plainIsNil: Bool = plain.initialWorldMap == nil
            expect(&f, "reloc.nilMap.\(mode.rawValue)", noMapIsNil && plainIsNil)
            let sameReconstruction = noMap.sceneReconstruction == plain.sceneReconstruction
            let sameSemantics = noMap.frameSemantics == plain.frameSemantics
            let samePlanes = noMap.planeDetection == plain.planeDetection
            expect(&f, "reloc.sameFields.\(mode.rawValue)", sameReconstruction && sameSemantics && samePlanes,
                   ScanConfigurationFactory.describe(noMap).joined(separator: "; "))
            let sameTexturing = noMap.environmentTexturing == plain.environmentTexturing
            let sameLight = noMap.isLightEstimationEnabled == plain.isLightEstimationEnabled
            expect(&f, "reloc.sameExtras.\(mode.rawValue)", sameTexturing && sameLight)
        }
        let house = ScanProfile(mode: .house, settings: .defaults(for: .house))
        let lines = ScanConfigurationFactory.describe(ScanConfigurationFactory.make(house, initialWorldMap: nil))
        expect(&f, "reloc.describe.noMap", lines.contains("initialWorldMap: false"), lines.joined(separator: "; "))
        let plainLines = ScanConfigurationFactory.describe(ScanConfigurationFactory.make(house))
        expect(&f, "reloc.describe.equal", lines == plainLines, lines.joined(separator: "; "))

        let reset: ARSession.RunOptions = [.resetTracking, .removeExistingAnchors]
        expect(&f, "reloc.runOptions", ScanConfigurationFactory.runOptionsText(reset) == "resetTracking removeExistingAnchors",
               ScanConfigurationFactory.runOptionsText(reset))
        let mapEvent = ScanConfigurationFactory.runEventText(options: reset, initialWorldMap: true)
        expect(&f, "reloc.event.map",
               mapEvent == "session run, options resetTracking removeExistingAnchors, initialWorldMap: true", mapEvent)
        let plainEvent = ScanConfigurationFactory.runEventText(options: [], initialWorldMap: false)
        expect(&f, "reloc.event.plain", plainEvent == "session run, options none, initialWorldMap: false", plainEvent)
    }

    // MARK: - Depth and mesh watchdog

    /// Feeds frames every `step` seconds for t in start...end (computed from an index, so no
    /// drift) and returns the non-`.none` actions with their timestamps.
    private static func feed(_ logic: inout CaptureWatchdogLogic, from start: Double, to end: Double,
                             depth: Bool, mesh: Int, normal: Bool, step: Double = 0.1) -> [(t: Double, action: WatchdogAction)] {
        var actions: [(t: Double, action: WatchdogAction)] = []
        let count = Int(((end - start) / step).rounded())
        guard count >= 0 else { return actions }
        for index in 0...count {
            let t = start + Double(index) * step
            let action = logic.observe(timestamp: t, depthPresent: depth, meshAnchorCount: mesh, trackingNormal: normal)
            if action != WatchdogAction.none { actions.append((t, action)) }
        }
        return actions
    }

    /// True when the action is a re-apply.
    private static func isReapply(_ action: WatchdogAction) -> Bool {
        if case .reapply = action { return true }
        return false
    }

    /// The watchdog sequences of MODULES 3.11.
    private static func checkWatchdog(_ f: inout [String]) {
        var healthy = CaptureWatchdogLogic()
        let quiet = feed(&healthy, from: 0, to: 10, depth: true, mesh: 3, normal: true)
        expect(&f, "watchdog.healthy", quiet.isEmpty, "\(quiet.count) actions")

        var depthLogic = CaptureWatchdogLogic()
        let first = feed(&depthLogic, from: 0, to: 2.1, depth: false, mesh: 3, normal: true)
        let reapplyTime = first.first?.t ?? -1
        expect(&f, "watchdog.depth.reapplyOnce", first.count == 1 && isReapply(first[0].action),
               "\(first.map { "\($0.t) \($0.action)" })")
        expect(&f, "watchdog.depth.reapplyAt2s", reapplyTime >= 1.95 && reapplyTime <= 2.11, "at \(reapplyTime)")
        let second = feed(&depthLogic, from: 2.2, to: 6, depth: false, mesh: 3, normal: true)
        let degradeTime = second.first?.t ?? -1
        expect(&f, "watchdog.depth.degradeOnce", second.count == 1 && second.first?.action == .degrade(.depthStripped),
               "\(second.map { "\($0.t) \($0.action)" })")
        expect(&f, "watchdog.depth.degradeAfter2s",
               degradeTime >= reapplyTime + 1.95 && degradeTime <= reapplyTime + 2.11, "at \(degradeTime)")

        var recovering = CaptureWatchdogLogic()
        _ = feed(&recovering, from: 0, to: 2.1, depth: false, mesh: 3, normal: true)
        let recovered = feed(&recovering, from: 2.2, to: 6, depth: true, mesh: 3, normal: true)
        expect(&f, "watchdog.depth.recovered", recovered.isEmpty, "\(recovered.count) actions")

        var meshLogic = CaptureWatchdogLogic()
        let early = feed(&meshLogic, from: 0, to: 7.8, depth: true, mesh: 0, normal: true)
        expect(&f, "watchdog.mesh.none7.8s", early.isEmpty, "\(early.count) actions")
        let late = feed(&meshLogic, from: 7.9, to: 8.2, depth: true, mesh: 0, normal: true)
        expect(&f, "watchdog.mesh.reapply8s", late.count == 1 && isReapply(late[0].action),
               "\(late.map { "\($0.t) \($0.action)" })")
        let stripped = feed(&meshLogic, from: 8.3, to: 11, depth: true, mesh: 0, normal: true)
        expect(&f, "watchdog.mesh.degrade", stripped.count == 1 && stripped.first?.action == .degrade(.meshStripped),
               "\(stripped.map { "\($0.t) \($0.action)" })")

        var limitedLogic = CaptureWatchdogLogic()
        let limited = feed(&limitedLogic, from: 0, to: 10, depth: true, mesh: 0, normal: false)
        expect(&f, "watchdog.mesh.limitedIgnored", limited.isEmpty, "\(limited.count) actions")
        let almost = feed(&limitedLogic, from: 10.1, to: 17.8, depth: true, mesh: 0, normal: true)
        expect(&f, "watchdog.mesh.limitedNotCounted", almost.isEmpty, "\(almost.map { $0.t })")
        let due = feed(&limitedLogic, from: 17.9, to: 18.3, depth: true, mesh: 0, normal: true)
        expect(&f, "watchdog.mesh.normalCounted", due.count == 1 && isReapply(due[0].action), "\(due.map { $0.t })")

        depthLogic.reset()
        expect(&f, "watchdog.reset.equal", depthLogic == CaptureWatchdogLogic())
        let again = feed(&depthLogic, from: 0, to: 2.1, depth: false, mesh: 3, normal: true)
        expect(&f, "watchdog.reset.reappliesAgain", again.count == 1 && isReapply(again[0].action), "\(again.count)")
    }

    // MARK: - Storage and memory (D17, D18)

    /// Storage thresholds, the injected sampler and the two-tick memory rule.
    private static func checkStorageAndMemory(_ f: inout [String]) {
        expect(&f, "storage.5GB", StorageWatchdog.state(forFreeBytes: 5_000_000_000) == .ok)
        expect(&f, "storage.900MB", StorageWatchdog.state(forFreeBytes: 900_000_000) == .stopKeyframes)
        expect(&f, "storage.200MB", StorageWatchdog.state(forFreeBytes: 200_000_000) == .pause)
        let watchdog = StorageWatchdog(interval: 10, freeBytes: { 900_000_000 })
        expect(&f, "storage.sample", watchdog.sample() == .stopKeyframes)
        expect(&f, "storage.sampleStored", watchdog.state == .stopKeyframes && watchdog.freeBytes == 900_000_000,
               "\(watchdog.state) \(watchdog.freeBytes)")

        let gb: UInt64 = 1_000_000_000, mb550: UInt64 = 550_000_000, mb350: UInt64 = 350_000_000
        expect(&f, "memory.1GB", MemoryPolicy.state(available: gb, previous: gb, warning: false) == .ok)
        expect(&f, "memory.first550", MemoryPolicy.state(available: mb550, previous: gb, warning: false) == .ok)
        expect(&f, "memory.firstSample550", MemoryPolicy.state(available: mb550, previous: nil, warning: false) == .ok)
        expect(&f, "memory.second550", MemoryPolicy.state(available: mb550, previous: mb550, warning: false) == .low)
        expect(&f, "memory.first350", MemoryPolicy.state(available: mb350, previous: mb550, warning: false) == .low)
        expect(&f, "memory.second350", MemoryPolicy.state(available: mb350, previous: mb350, warning: false) == .critical)
        expect(&f, "memory.warning", MemoryPolicy.state(available: gb, previous: gb, warning: true) == .critical)
        expect(&f, "memory.warningFirst", MemoryPolicy.state(available: gb, previous: nil, warning: true) == .critical)
    }

    // MARK: - Thermal

    /// Policies per level, the ThermalLevel mapping and the governor with a fake reader.
    private static func checkThermal(_ f: inout [String]) {
        let nominal = ThermalPolicy.forLevel(.nominal)
        expect(&f, "thermal.nominal", nominal.keyframeIntervalScale == 1 && nominal.coverageHz == 3
               && nominal.overlayEnabled && !nominal.mustStop, "\(nominal)")
        expect(&f, "thermal.fair", ThermalPolicy.forLevel(.fair) == nominal)
        let serious = ThermalPolicy.forLevel(.serious)
        expect(&f, "thermal.serious", serious.keyframeIntervalScale == 2 && serious.coverageHz == 1
               && !serious.overlayEnabled && !serious.mustStop, "\(serious)")
        let critical = ThermalPolicy.forLevel(.critical)
        expect(&f, "thermal.critical", critical.coverageHz == 0 && !critical.overlayEnabled && critical.mustStop,
               "\(critical)")
        expect(&f, "thermal.level.critical", ThermalLevel(ProcessInfo.ThermalState.critical) == .critical)
        expect(&f, "thermal.level.fair", ThermalLevel(ProcessInfo.ThermalState.fair) == .fair)

        let center = NotificationCenter()
        let reader = SelfTestThermalReader()
        let governor = ThermalGovernor(notificationCenter: center, stateReader: { reader.state })
        expect(&f, "governor.initial", governor.level == .nominal, "\(governor.level)")
        let queue = DispatchQueue(label: "mapper.selftest.thermal")
        let received = SelfTestThermalReader()
        governor.start(on: queue) { level in received.append(level) }
        reader.state = .serious
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        queue.sync {}
        expect(&f, "governor.changed", governor.level == .serious && governor.policy.keyframeIntervalScale == 2,
               "\(governor.level)")
        expect(&f, "governor.callback", received.levels == [.serious], "\(received.levels)")
        governor.stop()
        reader.state = .critical
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        queue.sync {}
        expect(&f, "governor.stopped", received.levels == [.serious], "\(received.levels)")
    }

    // MARK: - Tracking

    /// Limited fraction, relocalization count, reset and the ARKit state mapping.
    private static func checkTracking(_ f: inout [String]) {
        let fraction = TrackingMonitor.limitedFraction(of: [(.normal, 0), (.normal, 1), (.excessiveMotion, 2),
                                                             (.excessiveMotion, 3), (.normal, 4)])
        expect(&f, "tracking.fraction", abs(fraction - 0.5) < 1e-9, "\(fraction)")
        let monitor = TrackingMonitor()
        monitor.record(.normal, timestamp: 0)
        monitor.record(.relocalizing, timestamp: 1)
        monitor.record(.relocalizing, timestamp: 2)
        monitor.record(.normal, timestamp: 3)
        monitor.record(.relocalizing, timestamp: 4)
        monitor.record(.normal, timestamp: 5)
        expect(&f, "tracking.relocalizations", monitor.relocalizations == 2, "\(monitor.relocalizations)")
        expect(&f, "tracking.fraction2", abs(monitor.limitedFraction - 0.6) < 1e-9, "\(monitor.limitedFraction)")
        monitor.reset()
        let resetCounts = monitor.relocalizations == 0 && monitor.limitedFraction == 0
        expect(&f, "tracking.reset", resetCounts && monitor.summary == .initializing)
        expect(&f, "tracking.map.normal", TrackingMonitor.summary(.normal) == .normal)
        expect(&f, "tracking.map.relocalizing", TrackingMonitor.summary(.limited(.relocalizing)) == .relocalizing)
        expect(&f, "tracking.map.motion", TrackingMonitor.summary(.limited(.excessiveMotion)) == .excessiveMotion)
        expect(&f, "tracking.map.notAvailable", TrackingMonitor.summary(.notAvailable) == .notAvailable)
        let codes: [UInt8] = [TrackingMonitor.poseCode(.notAvailable), TrackingMonitor.poseCode(.limited(.initializing)),
                              TrackingMonitor.poseCode(.normal)]
        expect(&f, "tracking.poseCode", codes == [0, 1, 2], "\(codes)")
        let summaryCodes: [UInt8] = [TrackingMonitor.poseCode(summary: .notAvailable),
                                     TrackingMonitor.poseCode(summary: .relocalizing),
                                     TrackingMonitor.poseCode(summary: .normal)]
        expect(&f, "tracking.poseCodeSummary", summaryCodes == [0, 1, 2], "\(summaryCodes)")
    }

    // MARK: - Buffer unpacking (RESEARCH 3.1 gotcha 2, 3.9 gotcha 4)

    /// Little-endian bytes of float3 values at `offset`, `step` bytes apart (filler 0xEE).
    private static func packedFloat3(_ points: [SIMD3<Float>], step: Int, offset: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xEE, count: offset + step * points.count)
        for (index, point) in points.enumerated() {
            let components: [Float] = [point.x, point.y, point.z]
            for (component, value) in components.enumerated() {
                putUInt32(value.bitPattern, into: &bytes, at: offset + index * step + component * 4)
            }
        }
        return bytes
    }

    /// Writes a UInt32 little-endian.
    private static func putUInt32(_ value: UInt32, into bytes: inout [UInt8], at position: Int) {
        for byte in 0..<4 { bytes[position + byte] = UInt8(truncatingIfNeeded: value >> (8 * UInt32(byte))) }
    }

    /// unpackFloat3 with stride 12 and 16 at offset 8, unpackUInt32, bounds and face filtering.
    private static func checkUnpacking(_ f: inout [String]) {
        let points: [SIMD3<Float>] = [SIMD3(1, 2, 3), SIMD3(-4.5, 5.25, 6), SIMD3(0.125, -0.5, 1e3)]
        for step in [12, 16] {
            let bytes = packedFloat3(points, step: step, offset: 8)
            let unpacked = bytes.withUnsafeBytes { raw -> [SIMD3<Float>] in
                guard let base = raw.baseAddress else { return [] }
                return MeshAnchorCopier.unpackFloat3(base, count: points.count, offset: 8, stride: step)
            }
            expect(&f, "unpackFloat3.stride\(step)", unpacked == points, "\(unpacked)")
        }
        let tooSmall = [UInt8](repeating: 0, count: 64).withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return MeshAnchorCopier.unpackFloat3(base, count: 2, offset: 0, stride: 8).count
        }
        expect(&f, "unpackFloat3.badStride", tooSmall == 0, "\(tooSmall)")

        let values: [UInt32] = [0, 7, 65_536, 4_000_000_000]
        for (step, offset) in [(4, 0), (8, 4)] {
            var bytes = [UInt8](repeating: 0xAB, count: offset + step * values.count)
            for (index, value) in values.enumerated() { putUInt32(value, into: &bytes, at: offset + index * step) }
            let unpacked = bytes.withUnsafeBytes { raw -> [UInt32] in
                guard let base = raw.baseAddress else { return [] }
                return MeshAnchorCopier.unpackUInt32(base, count: values.count, offset: offset, stride: step)
            }
            expect(&f, "unpackUInt32.stride\(step)", unpacked == values, "\(unpacked)")
        }
        expect(&f, "fits.exact", MeshAnchorCopier.fits(count: 3, offset: 8, stride: 16, width: 12, length: 8 + 32 + 12))
        expect(&f, "fits.short", !MeshAnchorCopier.fits(count: 3, offset: 8, stride: 16, width: 12, length: 8 + 32 + 11))
        let kept = MeshAnchorCopier.dropInvalidFaces(indices: [0, 1, 2, 0, 5, 1, 2, 1, 0], classes: [1, 2, 3], vertexCount: 3)
        expect(&f, "dropInvalidFaces", kept.indices == [0, 1, 2, 2, 1, 0] && kept.classes == [1, 3],
               "\(kept.indices) \(kept.classes)")
        expect(&f, "fourCC.depth", CaptureDiagnostics.fourCC(kCVPixelFormatType_DepthFloat32) == "fdep",
               CaptureDiagnostics.fourCC(kCVPixelFormatType_DepthFloat32))
    }

    // MARK: - Speeds, stats, recorder defaults

    /// Angular and linear speed, RecorderStats +, HubStatus defaults, ScanRecorder defaults.
    private static func checkSpeedsAndStats(_ f: inout [String]) {
        let identity = matrix_identity_float4x4
        let yaw = simd_float4x4(simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let quarter = ARFrameReading.angularSpeed(from: identity, to: yaw, seconds: 1)
        expect(&f, "angularSpeed.90deg", near(quarter, Float.pi / 2, 1e-4), "\(quarter)")
        let half = ARFrameReading.angularSpeed(from: yaw, to: simd_mul(yaw, yaw), seconds: 0.5)
        expect(&f, "angularSpeed.relative", near(half, Float.pi, 1e-3), "\(half)")
        expect(&f, "angularSpeed.still", near(ARFrameReading.angularSpeed(from: yaw, to: yaw, seconds: 1), 0, 1e-3))
        expect(&f, "angularSpeed.zeroTime", ARFrameReading.angularSpeed(from: identity, to: yaw, seconds: 0) == 0)
        var moved = identity
        moved.columns.3 = SIMD4<Float>(0.5, 0, 0, 1)
        let speed = ARFrameReading.linearSpeed(from: identity, to: moved, seconds: 0.25)
        expect(&f, "linearSpeed.2mps", near(speed, 2, 1e-5), "\(speed)")

        var a = RecorderStats()
        a.meshAnchors = 2
        a.keyframes = 5
        a.writeFailures = 1
        var b = RecorderStats()
        b.meshAnchors = 3
        b.meshFaces = 7
        b.skippedKeyframes = 2
        b.photos = 4
        b.poseSamples = 10
        let sum = a + b
        var expected = RecorderStats()
        expected.meshAnchors = 5
        expected.meshFaces = 7
        expected.keyframes = 5
        expected.skippedKeyframes = 2
        expected.photos = 4
        expected.poseSamples = 10
        expected.writeFailures = 1
        expect(&f, "stats.sum", sum == expected, "\(sum)")
        expect(&f, "stats.zero", RecorderStats() + RecorderStats() == RecorderStats())

        let status = HubStatus()
        let statesOK = status.tracking == .initializing && status.memory == .ok && status.storage == .ok
        let valuesOK = status.degraded == .allGood && status.centerDistance == nil
        expect(&f, "status.defaults", statesOK && valuesOK)

        let recorder = SelfTestRecorder()
        recorder.flushNow()
        var finished = false
        recorder.finishRecording { finished = true }
        expect(&f, "recorder.defaults", finished && recorder.stats == RecorderStats())
    }
}

/// Thread-safe holder of a fake thermal state and of the levels a governor reported.
private final class SelfTestThermalReader {
    /// Guards both properties.
    private let lock = NSLock()
    /// Backing store of `state`.
    private var storedState: ProcessInfo.ThermalState = .nominal
    /// Backing store of `levels`.
    private var storedLevels: [ThermalLevel] = []

    /// The fake system thermal state.
    var state: ProcessInfo.ThermalState {
        get { lock.lock(); defer { lock.unlock() }; return storedState }
        set { lock.lock(); storedState = newValue; lock.unlock() }
    }

    /// Levels received so far.
    var levels: [ThermalLevel] {
        lock.lock()
        defer { lock.unlock() }
        return storedLevels
    }

    /// Records a reported level.
    func append(_ level: ThermalLevel) {
        lock.lock()
        storedLevels.append(level)
        lock.unlock()
    }
}

/// A recorder implementing only the required members, proving the protocol defaults exist.
private final class SelfTestRecorder: ScanRecorder {
    /// Nothing to begin.
    func beginRecording(into folder: RawScanFolder, profile: ScanProfile, startTimestamp: TimeInterval) {}
    /// Finishes at once.
    func finishRecording(completion: @escaping () -> Void) { completion() }
    /// Always zero.
    var stats: RecorderStats { RecorderStats() }
}
