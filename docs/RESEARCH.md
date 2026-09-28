# Mapper research reference

> Status: complete draft. All ten subsystem sections passed two checks (declarations against Apple documentation JSON, and fidelity to the input files). Unfinished: a final adversarial check of the synthesized parts (sections 1, 2, 4, 5 and 6) was started and stopped before it made any change, so those parts have not had an independent review yet. The open device tests are listed at the end of section 6.

This is the single verified reference for the Mapper architecture and for every implementation agent. It is synthesized from `docs/research/raw/*.json` (first research pass, with first-pass verifier verdicts) and `docs/research/verify/*.json` (second pass, tie-breaker rulings and open-question answers). Each subsystem section was drafted from those files, then checked twice: once by re-fetching Apple's documentation JSON for every declaration and availability version, and once against the input files for refuted claims, missing facts and rulings.

Platform facts that every section assumes:

- Test device: iPhone 13 Pro Max (A15, 6 GB RAM, LiDAR) on iOS 18.3.2. A second device on iOS 26 comes later.
- Deployment target: iOS 18.0. Anything introduced after 18.0 needs `if #available`.
- Toolchain: GitHub Actions, Xcode 26.6, iOS 26 SDK, XcodeGen, Swift 5.9 language mode. No Mac and no local compiler, so every compile is a CI round trip.
- Signing: free Apple ID through Sideloadly. No paid entitlements.
- Native Apple frameworks only. No Swift packages.

How to read the API tables: "iOS" is the version where Apple's documentation JSON says the symbol was introduced. Declarations are copied from that JSON. Where a Swift page does not exist (only an Objective-C page), the section says so. Items marked unverified must be confirmed by a CI compile before anything depends on them.

## Contents

1. Executive summary
2. Cross-section rulings
3. Subsystems
   - 3.1 ARKit mesh and depth
   - 3.2 RoomPlan
   - 3.3 Object Capture
   - 3.4 Texturing pipeline
   - 3.5 Rendering and viewer
   - 3.6 Floor plan and CAD output
   - 3.7 3D export formats
   - 3.8 Scan quality, coverage and measurement confidence
   - 3.9 Storage, deployment and concurrency
   - 3.10 UX patterns
4. Risk register
5. Do not do
6. Answers to open questions
7. Sources

## 1. Executive summary

- **Deployment target stays iOS 18.0.** Every API the core app needs (ARKit scene reconstruction and depth, RoomPlan including `RoomCaptureSession(arSession:)` and `StructureBuilder`, Object Capture, RealityKit `LowLevelMesh` and `LowLevelTexture`, `MDLUtility.convert(toUSDZ:writeTo:)`) is available at 18.0 or earlier. iOS 26-only APIs (`captureHighResolutionFrame(using:)`, `BGContinuedProcessingTask`) are optional extras behind `#available`. iOS 27-only APIs (all `viewRotationAngle` variants, some `LowLevelMesh.Descriptor` members) do not exist in the iOS 26 SDK and must not be used.
- **No entitlement is needed for any scan mode.** RoomPlan, ARKit and Object Capture need only `NSCameraUsageDescription`, so free Apple ID sideloading covers the whole product. Do not depend on `increased-memory-limit` or any background GPU entitlement.
- **Room and house mode use RoomPlan for the parametric model and ARKit for everything else, on one app-owned `ARSession`.** Mapper creates the session, sets its delegate first, and passes it to `RoomCaptureSession(arSession:)` (iOS 17.0). The raw mesh, depth, texture keyframes and `CapturedRoom` then share one world frame.
- **RoomPlan replaces the session configuration when it runs.** In practice `sceneDepth` disappears. Mapper re-runs its own `ARWorldTrackingConfiguration` (`.meshWithClassification`, `.sceneDepth`) with empty run options inside `captureSession(_:didStartWith:)` for every room, with a watchdog that logs depth and mesh arrival. Never pass `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction` there. This is "likely" until the first device build confirms it; a separate ARKit mesh pass is the fallback.
- **Setting `arSession.delegate` yourself is allowed** (tie-breaker ruling). A delegate multiplexer is only a fallback if an identity check after `didStartWith` shows RoomPlan replaced it.
- **Room scanning is headless.** The spec requires a live green, yellow, red and gray coverage overlay, which `RoomCaptureView` cannot host. Mapper drives `RoomCaptureSession` directly, draws its own SwiftUI UI and a RealityKit `ARView` (`.ar`) overlay. `RoomCaptureView(frame:arSession:)`, whose doc says it preserves the session's settings, is the fallback path.
- **Whole-house scans keep one `ARSession` alive** with `stop(pauseARSession: false)` between rooms and merge with `StructureBuilder(options: [.beautifyObjects])`. Rooms scanned in unrelated frames merge silently into stacked rooms, and the merge can crash on some inputs. So every room is saved as Codable JSON (plus an `ARWorldMap`) before merging, and the app offers a manual "Arrange rooms" fallback.
- **`ARWorldMap` never stores mesh anchors.** Mapper persists its own world-space mesh store keyed by anchor identifier (positions, normals, UInt32 indices, per-face classification). That store is also the raw LiDAR mesh output.
- **Object mode uses Apple Object Capture:** `ObjectCaptureSession` plus `ObjectCaptureView` for guided capture, then on-device `PhotogrammetrySession`. On iOS the only detail level is `.reduced` (under about 50k triangles, 2048 x 2048 textures). `.preview`, `.medium`, `.full`, `.raw` and `.custom` are macOS or Mac Catalyst only and fail to compile. Image limits are read at runtime; the "1000 images" figure was refuted.
- **No Apple API textures an ARKit mesh.** Mapper builds its own pipeline: motion-gated keyframes with per-keyframe pose, intrinsics and depth; best-view face selection with a depth-pass occlusion test; charting and atlas packing; seam gain correction; a Metal bake. Projection uses `camera.transform.inverse` and intrinsics directly, never the orientation or display helpers.
- **Texture stills:** the 60 fps capture stream (default 1920 x 1440) is the v1 source. `captureHighResolutionFrame(completion:)` (iOS 16.0) gives 12 MP stills only on a format flagged for high-resolution capture, and whether its intrinsics and depth line up needs a device test, so hi-res stills are a later option.
- **Rendering stack is RealityKit.** SceneKit, `SceneView` and `ARSCNView` are deprecated in the iOS 26 SDK. The viewer hosts `ARView` (`.nonAR`, 3-argument init) with Mapper's own orbit, pan and pinch camera. Geometry lives in `LowLevelMesh` chunks with one interleaved layout. Textured, solid, wireframe (`triangleFillMode = .lines`) and classification views need no custom shader. Per-vertex color needs `ShaderGraphMaterial` or `CustomMaterial` and a device spike.
- **Picking and measuring** use a static-mesh `CollisionComponent` per chunk plus `Scene.raycast`, which returns `triangleHit.faceIndex` (iOS 18.0). `pixelCast` covers taps before collision shapes exist. `MTKView` is the escape hatch if about 1M triangles is too slow on the A15.
- **The floor plan is Mapper's own model**, built from `CapturedRoom` surfaces. Area and perimeter come from the closed wall loop, not `floors[].polygonCorners` (which was a bounding rectangle on real data, about 13 percent too large). Wall thickness, door swing and custom room names do not exist in RoomPlan; they are editable fields in Mapper's model.
- **One Core Graphics `PlanRenderer`** draws the SwiftUI `Canvas`, the vector PDF (`UIGraphicsPDFRenderer`) and PNG. SVG and DXF are hand-written text. DXF is R12 (AC1009) in millimeters, with units stated in a note and the filename because `$INSUNITS` is an R2000 variable.
- **Native export writers are few.** Native: RoomPlan USDZ (`CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)`), Object Capture USDZ, `MDLUtility.convert(toUSDZ:writeTo:)` (packages a USD layer, iOS 18.0), ModelIO OBJ and STL (import-quality only), PDF and PNG. Hand-written: OBJ plus MTL, PLY, STL, GLB, textured usda, SVG, DXF, and a stored-zip USDZ fallback. ModelIO cannot write usable USD, and SceneKit's `write(to:)` is only a contained last resort.
- **Sharing and packaging are native:** zip folders with `NSFileCoordinator` `.forUploading` (there is no public ZIP writer), share with a `UIActivityViewController` wrapper or `ShareLink`, preview with `.quickLookPreview`, and expose projects in Files through `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` (already set).
- **Scan quality is computed by Mapper, not Apple.** It combines RoomPlan's six `Instruction` cases, per-surface `completedEdges` and confidence as soft hints, and a 10 cm world-space voxel hash of mesh faces gated by depth confidence, distance and view angle. Coverage is keyed by position, never by mesh face index, because anchors re-mesh.
- **Measurements carry a documented error model** (depth by range and confidence, pose drift, pick source), shown as plus or minus 2 sigma, floored at 1 cm, with a "Low confidence" badge above 4 cm. RoomPlan-derived lengths are never shown better than plus or minus 3 cm. Apple publishes no accuracy figure, so constants are calibrated with the `docs/TEST_PLAN.md` tape protocol.
- **Concurrency:** stay in Swift 5 language mode with no default MainActor isolation. ARKit and RoomPlan delegates run nonisolated on a serial queue and hand Sendable copies to the main actor. Never retain `ARFrame` or its pixel buffers past the callback; deep-copy what is needed.
- **Heavy processing runs in the foreground** with the idle timer off and resumable checkpoints. iOS 18 has no usable background path, and no iPhone gets background GPU even on iOS 26.
- **Storage:** each project is a directory package in Documents with a `raw/` folder excluded from backup (roughly 200 to 350 MB per room, estimate) and a backed-up `derived/` folder. Records are Codable JSON; mesh and depth are headered binary blobs; simd matrices are not Codable and need wrappers.
- **Memory budget is about 2.5 GB peak.** The real jetsam ceiling on this phone is unknown (community folklore 2.8 to 3.0 GB). Measure with `os_proc_available_memory` on device.
- **Deferred or impossible:** Object Capture detail above `.reduced` on the phone, background GPU processing, UVs on RoomPlan geometry, a public ZIP writer, `viewRotationAngle` APIs, and any accuracy claim of survey grade.
- **The first device builds must close the open questions** in one round trip each: RoomPlan plus depth and mesh coexistence, texture and UV orientation self-tests, vertex-color material spike, USDZ packaging self-test, runtime limits (`maximumNumberOfInputImages`, `PhotogrammetrySession.limits`, available memory), and thermal timeline.

## 2. Cross-section rulings

The subsystem sections were drafted independently. Where two sections disagreed, this is the ruling that the architecture must follow.

1. **Room capture UI: headless `RoomCaptureSession` versus `RoomCaptureView`.** The RoomPlan section recommends a headless session with Mapper's own UI. The UX section recommends `RoomCaptureView` for v1 because it gives coaching and outlines for free. Evidence: the spec requires a live green, yellow, red and gray coverage overlay and custom guidance messages, which `RoomCaptureView` cannot host. Its built-in coaching also cannot be hidden while instructions still arrive. On the other side, Apple's doc for `RoomCaptureView.init(frame:arSession:)` (iOS 17.0) says "If you pass an ARSession instance, RoomPlan preserves all of the AR session's settings" (re-fetched for this synthesis), while field reports say a bare `RoomCaptureSession` drops `sceneDepth`. Ruling: the headless session is the target, because only it meets the spec. `RoomCaptureView(frame:arSession:)` is the fallback if the first device build shows that depth and mesh cannot be kept alive on the headless path. The UX section's `RoomCaptureView` guidance applies to that fallback.
2. **Textured USDZ writer.** The export section recommended `SCNScene.write(to:)` first. The texturing section carries a tie-breaker ruling: own usda, then `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18.0, not deprecated), with an own stored-zip writer as fallback, and no reliance on `SCNScene.write`. The tie-breaker had the stronger evidence (doc JSON and SDK headers, and SceneKit is deprecated at 26.0). Ruling: follow the tie-breaker. SceneKit stays only as a contained last resort in one file. The export section's recommended approach has been updated to match.
3. **DXF details.** The export section lists a TABLES/LAYER block. The floor plan section, which had the verifier rulings on DXF, says R12 needs only HEADER plus ENTITIES, with `$INSUNITS` written as a hint, a units TEXT note, a `_mm` filename suffix and no DIMENSION entities. Ruling: the floor plan section governs DXF. A minimal LAYER table is allowed but not required.
4. **RoomPlan length accuracy cap.** Earlier drafts used plus or minus 2.5 cm (practitioner reports of about 1 inch). The quality section uses plus or minus 3 cm, the RoomPlan wall voxel size from Apple's ML research, growing with wall length. Ruling: 3 cm, because it is stricter and has the better source.
5. **Hi-res texture stills.** The ARKit section recommends `captureHighResolutionFrame(completion:)` keyframes. The texturing section keeps hi-res frames off in v1 because intrinsic rescaling and depth alignment are unverified. Ruling: v1 textures from the capture stream. Hi-res stills are an experiment for a later build, logged against the stream frame first.
6. **SceneKit.** Several sections mention SceneKit bridges. Ruling: no new SceneKit code for display. SceneKit is deprecated at 26.0 on the iOS 26 SDK; it still compiles and runs, and warnings must stay non-fatal in CI.
7. **RealityKit resource initializers.** Checkers disagreed on which overloads are async. Re-checked in the doc JSON during synthesis: `TextureResource(image:withName:options:)` has both an `async throws` and a sync `throws` overload (iOS 18.0); both documented pages of `MeshResource(from: LowLevelMesh)` are `async throws` (iOS 18.0), and the sync mesh form appears only in sample and community code. Ruling: always `try await MeshResource(from:)`; either texture overload is fine.

## 3. Subsystems

### 3.1 ARKit mesh and depth

Scope: ARKit scene reconstruction (ARMeshAnchor), LiDAR scene depth, ARFrame and ARCamera, high-resolution stills, ARWorldMap, raycasting, session lifecycle and thermal limits. Everything here is iOS and iPadOS only. Nothing in this section needs more than iOS 17, so the iOS 18.0 deployment target is safe. The only iOS 26+ symbols are listed separately and need `#available(iOS 26, *)`.

#### Verified API

All declarations below come from Apple's documentation JSON (checked by the verifiers, and the key ones re-fetched for this section). None is deprecated on the iOS 26 SDK unless stated.

**Configuration and capability checks**

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `var sceneReconstruction: ARConfiguration.SceneReconstruction { get set }` (on ARWorldTrackingConfiguration) | 13.4 | Yes |
| `static var mesh: ARConfiguration.SceneReconstruction { get }` / `static var meshWithClassification` | 13.4 | Yes |
| `class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool` (on ARWorldTrackingConfiguration, not ARConfiguration) | 13.4 | Yes |
| `class var isSupported: Bool { get }` (ARConfiguration) | 11.0 | Yes |
| `var frameSemantics: ARConfiguration.FrameSemantics { get set }` | 13.0 | Yes |
| `static var sceneDepth` / `static var smoothedSceneDepth` (ARConfiguration.FrameSemantics) | 14.0 | Yes |
| `class func supportsFrameSemantics(_ frameSemantics: ARConfiguration.FrameSemantics) -> Bool` | 13.0 | Yes |
| `var planeDetection: ARWorldTrackingConfiguration.PlaneDetection { get set }` (`.horizontal`, `.vertical`) | 11.0 | Yes |
| `var environmentTexturing: ARWorldTrackingConfiguration.EnvironmentTexturing { get set }` (`.none`, `.manual`, `.automatic`) | 12.0 | Yes |
| `var isLightEstimationEnabled: Bool { get set }` (ARConfiguration), `var lightEstimate: ARLightEstimate? { get }` (ARFrame; ambientIntensity and ambientColorTemperature are CGFloat) | 11.0 | Yes |
| `class var supportedVideoFormats: [ARConfiguration.VideoFormat] { get }` | 11.3 | Yes |
| `var videoFormat: ARConfiguration.VideoFormat { get set }` | 11.3 | Yes |
| `class var recommendedVideoFormatForHighResolutionFrameCapturing: ARConfiguration.VideoFormat? { get }` | 16.0 | Yes |
| `var isRecommendedForHighResolutionFrameCapturing: Bool { get }` (VideoFormat) | 16.0 | Yes |
| VideoFormat `imageResolution: CGSize`, `framesPerSecond: Int`, `captureDeviceType` (14.5), `isVideoHDRSupported` (16) | 11.3+ | Yes |
| `class var recommendedVideoFormatFor4KResolution: ARConfiguration.VideoFormat? { get }`, `var videoHDRAllowed: Bool` | 16.0 | Yes (not recommended) |
| `@MainActor @preconcurrency var automaticallyConfigureSession: Bool { get set }` (RealityKit ARView) | 13.0 | Yes |

**Scene depth**

```swift
// ARFrame, iOS 14.0+
var sceneDepth: ARDepthData? { get }            // nil unless .sceneDepth is in frameSemantics
var smoothedSceneDepth: ARDepthData? { get }    // temporally averaged
// ARDepthData, iOS 14.0+
unowned(unsafe) var depthMap: CVPixelBuffer { get }        // kCVPixelFormatType_DepthFloat32, meters from camera plane -> .r32Float
unowned(unsafe) var confidenceMap: CVPixelBuffer? { get }  // kCVPixelFormatType_OneComponent8 -> .r8Uint / .r8Unorm
// ARConfidenceLevel: Int, Comparable. low = 0, medium = 1, high = 2
```

Depth map is 256 x 192 landscape (same aspect and field of view as the 1920 x 1440 color image), one map per ARFrame, so 60 Hz on the default format (30 Hz on a 30 fps format). The size is not a documented constant: it is hard-coded in Apple's point-cloud sample and confirmed by third parties. Read it at runtime with `CVPixelBufferGetWidth/Height`. Useful range is roughly 0.5 m to 5 m (guidance, not an API limit).

**Frame, camera and projection**

```swift
// ARFrame
var capturedImage: CVPixelBuffer { get }        // iOS 11. '420f' bi-planar YCbCr full range, landscape sensor orientation
var timestamp: TimeInterval { get }             // iOS 11
var exifData: [String : Any] { get }            // iOS 16
var worldMappingStatus: ARFrame.WorldMappingStatus { get }  // iOS 12: notAvailable, limited, extending, mapped
var rawFeaturePoints: ARPointCloud? { get }     // iOS 11, sparse, debugging only
var anchors: [ARAnchor] { get }
// ARCamera, iOS 11
var transform: simd_float4x4 { get }            // camera to world; camera looks down -z, +y up
var intrinsics: simd_float3x3 { get }           // pixels of capturedImage: [0][0]=fx, [1][1]=fy, [2][0]=ox, [2][1]=oy
var imageResolution: CGSize { get }
var projectionMatrix: simd_float4x4 { get }
var trackingState: ARCamera.TrackingState { get } // .notAvailable, .limited(Reason), .normal
// Reason: initializing, excessiveMotion, insufficientFeatures, relocalizing
```

Orientation helpers (iOS 11.0; `unprojectPoint` 12.0). Apple's JSON marks them deprecated at 27.0, not 26. Only `unprojectPoint` has a Swift doc page; the other four are documented only as Objective-C selectors (`projectionMatrixForOrientation:viewportSize:zNear:zFar:`, `viewMatrixForOrientation:`, `projectPoint:orientation:viewportSize:`, `displayTransformForOrientation:viewportSize:`), so their Swift spellings below are the standard imported names, not taken from a Swift declaration. The iOS 26.5 SDK headers carry no deprecation macro, so Xcode 26.6 compiles them with no warning.

```swift
func projectionMatrix(for orientation: UIInterfaceOrientation, viewportSize: CGSize, zNear: CGFloat, zFar: CGFloat) -> simd_float4x4
func viewMatrix(for orientation: UIInterfaceOrientation) -> simd_float4x4
func projectPoint(_ point: simd_float3, orientation: UIInterfaceOrientation, viewportSize: CGSize) -> CGPoint
@nonobjc func unprojectPoint(_ point: CGPoint, ontoPlane planeTransform: simd_float4x4, orientation: UIInterfaceOrientation, viewportSize: CGSize) -> simd_float3?
func displayTransform(for orientation: UIInterfaceOrientation, viewportSize: CGSize) -> CGAffineTransform   // ARFrame
```

The `viewRotationAngle:` replacements, `ARSession.viewRotationAngle` (`@nonobjc var viewRotationAngle: CGFloat? { get }`) and `ARSessionObserver.session(_:didChangeViewRotationAngle:)` are iOS 27.0 only and are absent from the iOS 26.5 SDK. Do not reference them.

**Mesh anchors and geometry (all iOS 13.4, subscripts iOS 14.0)**

```swift
class ARMeshAnchor : ARAnchor { var geometry: ARMeshGeometry { get } }   // plus transform, identifier (UUID)
class ARMeshGeometry {
    var vertices: ARGeometrySource { get }         // .float3, anchor-local
    var normals: ARGeometrySource { get }          // .float3, one per VERTEX
    var faces: ARGeometryElement { get }           // .triangle, 3 indices, 4 bytes (UInt32)
    var classification: ARGeometrySource? { get } // .uchar, one per FACE; nil with .mesh
}
class ARGeometrySource { var buffer: any MTLBuffer; var count: Int; var format: MTLVertexFormat
    var componentsPerVector: Int; var offset: Int; var stride: Int }   // buffer storageMode is shared
class ARGeometryElement { var buffer: any MTLBuffer; var count: Int; var bytesPerIndex: Int
    var indexCountPerPrimitive: Int; var primitiveType: ARGeometryPrimitiveType }
// ARMeshClassification raw values: none=0, wall=1, floor=2, ceiling=3, table=4, seat=5, window=6, door=7
```

`classificationOf(faceWithIndex:)`, `vertex(at:)` and `centerOf(faceWithIndex:)` in Apple's sample are sample extensions, not SDK API. Write them by hand from the buffer layout above.

**Planes (for the floor plan)**: `ARPlaneAnchor` with `alignment`, `center`, `planeExtent: ARPlaneExtent` (iOS 16: width, height, rotationOnYAxis), `geometry: ARPlaneGeometry` (iOS 11.3), `classification` (iOS 12), `class var isClassificationSupported`. `extent: simd_float3` is deprecated since iOS 16.0.

**Session and delegate**

```swift
func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])   // iOS 11
func pause()
// RunOptions: .resetTracking, .removeExistingAnchors, .stopTrackedRaycasts, .resetSceneReconstruction
weak var delegate: (any ARSessionDelegate)? { get set }   // iOS 11
var delegateQueue: dispatch_queue_t? { get set }           // iOS 11; assign a serial DispatchQueue
@NSCopying var currentFrame: ARFrame? { get }
@NSCopying var configuration: ARConfiguration? { get }
// ARSessionDelegate / ARSessionObserver (optional)
func session(_ session: ARSession, didUpdate frame: ARFrame)
func session(_ session: ARSession, didAdd anchors: [ARAnchor])
func session(_ session: ARSession, didUpdate anchors: [ARAnchor])
func session(_ session: ARSession, didRemove anchors: [ARAnchor])
func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera)
func sessionWasInterrupted(_ session: ARSession)
func sessionInterruptionEnded(_ session: ARSession)
func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool   // iOS 11.3
func session(_ session: ARSession, didFailWithError error: any Error)
```

**High-resolution stills**

```swift
func captureHighResolutionFrame(completion: @escaping @Sendable (ARFrame?, (any Error)?) -> Void)  // iOS 16.0
func captureHighResolutionFrame() async throws -> ARFrame                                         // iOS 16.0
// iOS 26.0+ only, needs #available(iOS 26, *):
func captureHighResolutionFrame(using photoSettings: AVCapturePhotoSettings?, completion: @escaping @Sendable (ARFrame?, (any Error)?) -> Void)
func captureHighResolutionFrame(using photoSettings: AVCapturePhotoSettings?) async throws -> ARFrame
// ARConfiguration.VideoFormat, iOS 26.0+: defaultPhotoSettings: AVCapturePhotoSettings, defaultColorSpace: AVCaptureColorSpace
// Errors (iOS 16): ARError.Code.highResolutionFrameCaptureInProgress, .highResolutionFrameCaptureFailed
```

**World map (iOS 12.0)**

```swift
class ARWorldMap   // NSSecureCoding; anchors: [ARAnchor], center, extent, rawFeaturePoints: ARPointCloud
func getCurrentWorldMap(completionHandler: @escaping @Sendable (ARWorldMap?, (any Error)?) -> Void)
func currentWorldMap() async throws -> ARWorldMap   // not in Apple's topic list; compiler-imported async form, compiles in shipped code
var initialWorldMap: ARWorldMap? { get set }   // ARWorldTrackingConfiguration
// Save: try NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)   // throws -> Data
// Load: try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)   // throws -> ARWorldMap?; run with [.resetTracking, .removeExistingAnchors]
```

**Raycasting (iOS 13.0; mesh hits need sceneReconstruction, 13.4)**

```swift
init(origin: simd_float3, direction: simd_float3, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment)
// Target: existingPlaneGeometry, existingPlaneInfinite, estimatedPlane. TargetAlignment: horizontal, vertical, any
func raycastQuery(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> ARRaycastQuery // ARFrame; point NORMALIZED 0..1, top-left origin
func raycast(_ query: ARRaycastQuery) -> [ARRaycastResult]   // ARSession, nearest first
func trackedRaycast(_ query: ARRaycastQuery, updateHandler: @escaping ([ARRaycastResult]) -> Void) -> ARTrackedRaycast?
// ARRaycastResult: worldTransform, anchor (nil for estimatedPlane unless an existing plane is hit), target, targetAlignment
@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult] // RealityKit ARView, view points
```

**Thermal**: `ProcessInfo.processInfo.thermalState` (`.nominal`, `.fair`, `.serious`, `.critical`), `ProcessInfo.thermalStateDidChangeNotification`, `isLowPowerModeEnabled`, and `UIApplication.shared.isIdleTimerDisabled`. All iOS 11 or earlier.

#### Gotchas

1. Mesh vertices are in the anchor's local space. Multiply by `anchor.transform` for world space (Apple DTS, forum 682585). Forgetting this piles every chunk at the origin.
2. Mesh buffers belong to ARKit and are refreshed on the next update of that anchor. Copy bytes inside the callback, honoring `offset` and `stride` (stride can exceed 12). Never wrap the MTLBuffer by reference in SceneKit or RealityKit objects.
3. `classification` is one UInt8 per face and is nil with `.mesh`. `normals` are per vertex even though the web doc abstract says per face (the iOS 18 header says "Normal of each vertex").
4. ARMeshClassification raw values follow the header order, not the alphabetical doc list. Use `ARMeshClassification(rawValue:)`.
5. ARWorldMap does not store ARMeshAnchors (DTS, forum 705469). Plane anchors and plain ARAnchors are kept. Persist the mesh yourself. DTS suggests adding a plain ARAnchor at each mesh chunk's transform before saving, then restoring your stored geometry onto it after relocalization. `getCurrentWorldMap` fails at once on a non-world-tracking configuration.
6. Depth pixels use capturedImage intrinsics scaled by depthWidth/imageWidth and depthHeight/imageHeight. ARKit camera space looks down -z. Apple's point-cloud shader uses a "+z forward" convention, so for world points use `camera.transform * float4(x, -y, -depth, 1)`. Check against a known floor point on the first device run.
7. RoomPlan re-runs a shared ARSession with its own configuration and sceneDepth disappears (forums 763400, 808834, 710134). You must re-apply your configuration in `captureSession(_:didStartWith:)`. See Disputed. One community repo also reports that with an injected session RoomPlan reports nothing unless your configuration enables `sceneReconstruction` (community only).
8. The high-resolution still is only 12 MP (4032 x 3024) if the active video format has `isRecommendedForHighResolutionFrameCapturing == true`. On other formats it is a mildly upscaled stream frame. Only one request may be in flight. The hi-res-capable 4:3 format may run at 30 fps (one report: 1920 x 1440 at 30 fps), which also halves the depth rate. Read `framesPerSecond` and never hard-code 60.
9. The high-resolution frame can have a slightly different field of view than the stream on some iPhones (StackOverflow 77620306, iPhone 12 mini). Always use that frame's own `camera.intrinsics` and `imageResolution`.
10. Community reports say 16:9 high-resolution formats gave zero mesh geometry on iPads, while 4:3 formats kept the mesh. Choose a 4:3 format.
11. One unverified repo (Copilot-authored PR) claims `recommendedVideoFormatForHighResolutionFrameCapturing` plus `.sceneDepth` made `session.run` throw. A measured device run with mesh plus a 4:3 hi-res format worked. Wrap first use in logging.
12. Changing `videoFormat`, `frameSemantics` or `sceneReconstruction` needs `session.run(config)` again. Default options keep tracking and anchors. Configuration changes take effect a few frames later.
13. Do not retain ARFrames. Holding them starves the capture pipeline and tracking goes limited (WWDC22). Copy the pixel buffer or encode to JPEG, then drop the frame.
14. `.estimatedPlane` raycasts return only a transform: no face index, normal or classification. `ARFrame.raycastQuery(from:)` takes a normalized point, while `ARView.raycast(from:)` takes view points. `ARSCNView.raycastQuery(from:allowing:alignment:)` also takes view points and returns an Optional.
15. Mesh anchors may be removed and re-added seconds later (forum report, iPad Pro, iOS 18 era). Do not delete cached chunks on `didRemove`.
16. `ARConfiguration.EnvironmentTexturing` does not exist. The type is `ARWorldTrackingConfiguration.EnvironmentTexturing`.
17. Since iOS 16 the plane anchor transform is not rotated to fit the rectangle. Apply `planeExtent.rotationOnYAxis` yourself.
18. A resumed world map starts `.limited(.relocalizing)` and stays there forever if the place does not match. Always offer "start fresh".
19. The delegate queue defaults to main. Mesh copying on main will stall the UI.
20. A multi-minute LiDAR scan on the A15 is expected to reach `.serious` thermal state (researcher estimate, not measured). Throttling lowers the camera frame rate and hurts tracking.
21. Enabling plane detection flattens the mesh where planes are found. People-occlusion semantics remove mesh around people. Both are documented.
22. SceneKit (including `SCNGeometrySource(buffer:...)`) is deprecated at iOS 26.0. It still compiles for an iOS 18 target but warns. Prefer RealityKit or Metal for display and ModelIO or hand-written writers for export.
23. The still is a fast sensor grab (quality prioritization `.speed`, no Deep Fusion). With the iOS 26 `using:` variant, `defaultPhotoSettings` works, but bracket settings and `.quality` prioritization fail with `highResolutionFrameCaptureFailed` rather than an exception (one iPad report, iPadOS 26). The same report measured 61 to 68 ms per still with mesh running.

#### Recommended approach

1. **One app-owned ARSession.** Create `ARSession()` yourself. If an ARView is used for preview, set `automaticallyConfigureSession = false`. Hand the same session to `RoomCaptureSession(arSession:)` so mesh, depth, stills and CapturedRoom share one world frame.
2. **Scan configuration**, guarded by `supportsSceneReconstruction(.meshWithClassification)` (fall back to `.mesh`) and `supportsFrameSemantics(.sceneDepth)`:
   - `sceneReconstruction = .meshWithClassification`
   - `frameSemantics = [.sceneDepth]` (add `.smoothedSceneDepth` only for a live depth preview)
   - `planeDetection = [.horizontal, .vertical]` (accept mesh flattening on planes; it helps the clean model)
   - `environmentTexturing = .none`, `isLightEstimationEnabled = true`
   - `videoFormat`: pick from `supportedVideoFormats` a 4:3 format with `isRecommendedForHighResolutionFrameCapturing == true`, else `recommendedVideoFormatForHighResolutionFrameCapturing`, else the first entry. Do not use 4K or HDR.
3. **RoomPlan coexistence.** Set `arSession.delegate` and a serial `delegateQueue` before `run`. Run your configuration, create `RoomCaptureSession(arSession:)`, call `run(configuration:)`, then in `captureSession(_:didStartWith:)` call `arSession.run(myConfig)` with no options. Never pass `.resetTracking` or `.removeExistingAnchors` there. Add a watchdog that re-applies the configuration when `frame.sceneDepth == nil` for several frames. Repeat after every room's `run(configuration:)`. For multi-room scans reuse one RoomCaptureSession with `stop(pauseARSession: false)`. The parameter defaults to `true`, so always pass `false` explicitly.
4. **Mesh store.** A dictionary keyed by `ARMeshAnchor.identifier` holding world-space Float32 positions and normals, UInt32 indices and UInt8 face classes, replaced on `didUpdate`, marked stale on `didRemove`, re-adopted on `didAdd` with the same identifier. Copy in the callback on the delegate queue. Serialize as binary blobs plus a JSON manifest next to the ARWorldMap. This is the "raw LiDAR mesh" output and the input to the clean model and floor plan.
5. **Texture stills.** Keep the stream for tracking. Call `captureHighResolutionFrame(completion:)` at keyframes (about every 0.5 m or 20 degrees of motion, only when tracking is `.normal`), serialized one at a time. Store JPEG, `camera.transform`, `camera.intrinsics`, `imageResolution` and a copy of the frame's `sceneDepth` (if present) per keyframe, then drop the frame. On iOS 18 the async form is `captureHighResolutionFrame()`. Project onto the mesh later. Do not texture from the 60 fps stream. Use the `using:` variant only behind `#available(iOS 26, *)`, and never ask it for depth delivery.
6. **Depth use.** Use `sceneDepth` (not smoothed) with confidence at least `.medium` for dense point clouds, coverage and measurement confidence. The ARKit mesh stays the primary surface.
7. **Measurement and picking.** `session.raycast` with `.estimatedPlane` and `.any` for quick taps. For snapping, normals and classification-aware measuring, run a CPU Moller-Trumbore test over the cached world mesh (chunk bounding boxes first, then a per-chunk BVH).
8. **Custom Metal viewer.** Use the orientation variants (`projectionMatrix(for:...)`, `viewMatrix(for:)`, `displayTransform(for:...)`) and build rays yourself for `ARRaycastQuery(origin:direction:allowing:alignment:)`.
9. **Session state machine.** Map `trackingState` and `worldMappingStatus` to UX guidance. On interruption return true from `sessionShouldAttemptRelocalization`, show "return to where you were", and after a timeout offer `run(config, options: [.resetTracking, .removeExistingAnchors, .resetSceneReconstruction])`. Save a world map only when `worldMappingStatus` is `.extending` or `.mapped`. Use `.resetSceneReconstruction` when a new room starts in the same session only if the mesh should not carry over (for a house scan it usually should).
10. **Thermal policy.** Read `thermalState` once, then observe the notification. At `.serious`: drop smoothed depth, pause stills, lower render rate to 30 fps, pause mesh post-processing. At `.critical`: pause the session and tell the user. Keep the idle timer disabled during scans.
11. **First-device-run log checklist** (no local Mac): depthMap size and format; `supportedVideoFormats`; chosen format and whether the still is 4032 x 3024; `arSession.configuration` before RoomPlan, after `didStartWith`, and after the re-apply; `sceneDepth != nil` rate with RoomPlan running; sceneDepth presence and size on hi-res frames; anchor count, faces per anchor and update cadence; anchor remove/re-add churn; world map byte size and relocalization time.

#### Disputed or unsure

1. **Your ARWorldTrackingConfiguration stays in effect after `RoomCaptureSession.run(configuration:)`.**
   Researcher: yes, per WWDC23 10192 ("any custom ARSession ... will be honored"). Both first-pass verifiers: refuted. RoomPlan re-runs the session with its own configuration and sceneDepth disappears; four independent repos re-apply their configuration. Stronger side: verifiers. Apple forum 763400 states the symptom directly and its accepted answer is the re-apply fix. Threads 808834 and 710134 agree. "Honored" only means RoomPlan uses your session object. The RoomCaptureView doc line "RoomPlan preserves all of the AR session's settings" is scoped to `RoomCaptureView.init(frame:arSession:)` and is contradicted for the headless session. Thread 728601 reports different behavior for RoomCaptureView and a bare RoomCaptureSession, which fits both readings. One repo (straylite) re-applies with `.resetSceneReconstruction`; do not copy that, it discards the mesh. Tie-breaker: upheld the verifiers. **Final ruling: refuted as stated. Share one session, but re-apply your configuration with empty run options in `captureSession(_:didStartWith:)` after every room start, plus a sceneDepth watchdog.** Still log on device whether `videoFormat` is also replaced.

2. **RoomPlan owns the single `ARSession.delegate` slot, so do not set it.**
   Reality verifier: do not set it (WHCsurvey, Ledge doc); poll `currentFrame` instead. Tie-breaker: rejected. Apple's article "Scanning the rooms of a single structure" implements ARSessionObserver callbacks for the RoomPlan session. The 763400 author read depth through the delegate once the configuration was re-applied. Meta's facebookresearch/ocean and others set it. The contrary sources give no reproducible report. **Final ruling: set `arSession.delegate` (before run) and use delegate callbacks. Polling `currentFrame` is only a fallback.**

3. **`stop(pauseARSession: false)` keeps one coordinate frame across rooms.**
   Apple's article and WWDC23 say yes. StackOverflow 79208951 (unanswered) reports tracking lost when a new RoomCaptureView is created on the running session. Stronger side: Apple, since the report concerns a new view per room, which Mapper will not do. **Final ruling: reuse one RoomCaptureSession; keep ARWorldMap relocalization as the fallback; verify on device.**

4. **The hi-res ARFrame carries `sceneDepth`.**
   Researcher: unsure, leaning nil. Verifier: no evidence either way. Open-question answer: Apple staff (forum 805839, Nov 2025) say depth arrives on high-resolution frames with `.sceneDepth` enabled and default photo settings. `capturedDepthData` stays nil outside face tracking, and requesting depth delivery through `using:` settings throws. The verifier's suggested `captureHighResolutionFrame(using: nil)` is iOS 26 only; on iOS 18 use `captureHighResolutionFrame(completion:)` or `captureHighResolutionFrame()`. Wisescan logs depth on hi-res frames and relies on keyframe depth, which weakly supports the staff answer. **Final ruling: likely present, at the regular LiDAR resolution (not photo size, unverified). Read it but fall back to the nearest stream frame when nil. Device test.**

5. **The 12 MP still is automatic "for best results".** Verifier refinement: it is conditional on the video format. **Ruling: choose a 4:3 format flagged `isRecommendedForHighResolutionFrameCapturing`.**

6. **ARMeshAnchor is excluded from ARWorldMap because its geometry is not NSSecureCoding.** Both verifiers: the mesh exclusion is correct, but ARMeshAnchor does conform to NSSecureCoding (inherited). **Ruling: exclusion is a framework decision; the design (persist your own mesh) is unchanged.**

7. **`ARFrame.raycastQuery(from:)` takes view points.** Researcher left this open. Doc: normalized 0..1 coordinate, top-left origin. **Ruling: normalized.**

8. **Orientation helpers "at worst warn on a 27 SDK".** Verifier: the iOS 26.5 SDK headers have no deprecation macro, so no warning at all on Xcode 26.6. Swift-spelled doc URLs 404 because Apple now shows only ObjC pages for them, but compiled open-source Swift uses these exact names. **Ruling: safe to use.**

9. **Still unsure, needs device measurement:** mesh chunk size (community: about 1 m squares), vertex spacing and update cadence; typical world map size and relocalization success on iOS 18.3; anchor remove/re-add churn on the iPhone 13 Pro Max; the "buffers are reallocated on update" detail (copying is the safe practice regardless); whether RealityKit's automatic session disables classification (irrelevant once you run your own configuration).

### 3.2 RoomPlan

RoomPlan gives Mapper the parametric room: walls, doors, windows, openings, floors, furniture boxes, room-type sections, and a multi-room merge. It does not give the detailed mesh or textures (see ARKit mesh and depth, and the texturing pipeline). Every RoomPlan symbol was introduced in iOS 16.0 or iOS 17.0. Crawls of the current (iOS 26 SDK) doc set found about 150 declared symbols at 16.0 and 122 at 17.0, none at 18.x or 26.x, and no deprecated or beta flags. With deployment target iOS 18.0 the whole API is usable without any `#available` check. Nothing in RoomPlan needs `#available(iOS 26, *)`. The framework is iOS, iPadOS and Mac Catalyst only (Mac Catalyst ignores all capture calls). It needs a LiDAR device and a camera. No entitlement is required, so free Apple ID sideloading works.

#### Verified API

All declarations below were checked against Apple doc JSON (declaration tokens and `metadata.platforms`). "18.0 OK" means usable at the iOS 18.0 deployment target with no availability guard.

**Capture session**

```swift
import RoomPlan   // iOS 16.0+, iPadOS 16.0+, Mac Catalyst 16.0+

class RoomCaptureSession
init()                                              // iOS 16.0
init(arSession: ARSession? = nil)                   // iOS 17.0
static var isSupported: Bool { get }                // iOS 16.0, true if the device has a LiDAR Scanner
func run(configuration: RoomCaptureSession.Configuration)   // iOS 16.0
func stop()                                         // iOS 16.0
func stop(pauseARSession: Bool = true)              // iOS 17.0
weak var delegate: (any RoomCaptureSessionDelegate)?        // iOS 16.0
var arSession: ARSession                            // iOS 16.0, declared without { get }, but docs say it is set at init and throws if the app sets it

struct RoomCaptureSession.Configuration {           // iOS 16.0
  init()
  var isCoachingEnabled: Bool                       // default true; the ONLY option
}

enum RoomCaptureSession.Instruction                 // iOS 16.0, Equatable, Hashable (NOT CaseIterable)
  // cases: normal, moveCloseToWall, moveAwayFromWall, turnOnLight, slowDown, lowTexture

enum RoomCaptureSession.CaptureError                // iOS 16.0, Equatable, Error, Hashable, LocalizedError, Sendable
  // cases: deviceNotSupported, deviceTooHot, exceedSceneSizeLimit,
  //        invalidARConfiguration, worldTrackingFailure, internalError
  // var errorDescription: String?
```

**Session delegate** (iOS 16.0, all methods have default empty implementations; copy these verbatim)

```swift
protocol RoomCaptureSessionDelegate : AnyObject
func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration)
func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?)
```

`didUpdate` carries the full live snapshot. `didAdd`, `didChange` and `didRemove` carry only the affected elements. `didEndWith` fires after every stop, including `stop(pauseARSession: false)`.

**Framework view** (optional; Mapper will likely not use it, see Recommended approach)

```swift
@MainActor @objc @preconcurrency class RoomCaptureView      // UIView subclass, iOS 16.0
@MainActor @preconcurrency override dynamic init(frame: CGRect)   // iOS 16.0
@MainActor @preconcurrency init(frame: CGRect, arSession: ARSession)   // iOS 17.0
@MainActor @preconcurrency var captureSession: RoomCaptureSession! { get }
@MainActor @preconcurrency var isModelEnabled: Bool { get set }
@MainActor @preconcurrency weak var delegate: (any RoomCaptureViewDelegate)?

protocol RoomCaptureViewDelegate : NSCoding                  // iOS 16.0
func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool
func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?)
```

Return `false` from `shouldPresent` to skip the built-in 3D preview and run `RoomBuilder` yourself.

**Post-processing**

```swift
struct CapturedRoomData            // iOS 16.0, Codable, Sendable, opaque
class RoomBuilder                  // iOS 16.0
init(options: RoomBuilder.ConfigurationOptions)
func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom
struct RoomBuilder.ConfigurationOptions   // OptionSet, init(rawValue: Int); only option: static let beautifyObjects
enum RoomBuilder.BuildError        // iOS 16.0: insufficientInput, invalidInput, exceedSceneSizeLimit, internalError, deviceNotSupported

class StructureBuilder             // iOS 17.0
init(options: StructureBuilder.ConfigurationOptions)   // typealias of RoomBuilder.ConfigurationOptions
func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure
enum StructureBuilder.BuildError   // iOS 17.0: deviceNotSupported, exceedSceneSizeLimit, insufficientInput,
                                   // internalError, invalidInput, invalidRoomLocation
```

**Result model** (all properties are `{ get }`; the only initializer is `init(from:)`)

| Symbol | Declaration / cases | iOS | 18.0 OK |
|---|---|---|---|
| `CapturedRoom` | `struct`, Decodable, Encodable, Sendable | 16.0 | yes |
| `identifier` | `var identifier: UUID { get }` | 16.0 | yes |
| `walls`, `doors`, `windows`, `openings` | `var walls: [CapturedRoom.Surface] { get }` (same shape) | 16.0 | yes |
| `floors` | `var floors: [CapturedRoom.Surface] { get }` | 17.0 | yes |
| `objects` | `var objects: [CapturedRoom.Object] { get }` | 16.0 | yes |
| `sections` | `var sections: [CapturedRoom.Section] { get }` | 17.0 | yes |
| `story`, `version` | `var story: Int { get }`, `var version: Int { get }` | 17.0 | yes |
| `Confidence` | `enum`: high, medium, low | 16.0 | yes |
| `CapturedRoom.Error` | deviceNotSupported, urlInvalidFileExtension, urlInvalidFilePath, urlInvalidScheme, urlMissingFileExtension | 16.0 | yes |
| `AttributesCodableRepresentation` | `init(attributes: [any CapturedRoomAttribute])`, `let attributes: [any CapturedRoomAttribute]` | 17.0 | yes |
| Surface and Object common | `var identifier: UUID { get }`, `var confidence: CapturedRoom.Confidence { get }` (16.0), `var story: Int { get }` (17.0) | 16.0 / 17.0 | yes |
| `Object.transform`, `Object.dimensions` | `var transform: simd_float4x4 { get }`, `var dimensions: simd_float3 { get }` (bounding box) | 16.0 | yes |
| `Surface.transform` | `var transform: simd_float4x4 { get }` | 16.0 | yes |
| `Surface.dimensions` | `var dimensions: simd_float3 { get }` (width, height, depth near 0) | 16.0 | yes |
| `Surface.category` | `enum Category`: floor, `door(isOpen: Bool)`, opening, wall, window. Codable, Hashable, NOT CaseIterable | 16.0 (floor 17.0) | yes |
| `Surface.completedEdges` | `var completedEdges: Set<CapturedRoom.Surface.Edge> { get }`; Edge: top, bottom, left, right (CaseIterable) | 16.0 | yes |
| `Surface.curve` | `var curve: CapturedRoom.Surface.Curve? { get }`; Curve: `startAngle`/`endAngle: Measurement<UnitAngle>`, `radius: Float` (16.0), `center: simd_float2` (17.0) | 16.0 | yes |
| `Surface.polygonCorners` | `var polygonCorners: [simd_float3] { get }` (local plane coordinates) | 17.0 | yes |
| `Surface.parentIdentifier` | `var parentIdentifier: UUID? { get }` (door or window to wall) | 17.0 | yes |
| `Object.category` | 16 cases: bathtub, bed, chair, dishwasher, fireplace, oven, refrigerator, sink, sofa, stairs, storage, stove, table, television, toilet, washerDryer. CaseIterable, Codable, Hashable | 16.0 | yes |
| `Object.attributes` | `var attributes: [any CapturedRoomAttribute] { get }` | 17.0 | yes |
| `Object.attribute(of:)` | `func attribute<T>(of attributeType: T.Type) -> T? where T : CapturedRoomAttribute` | 17.0 | yes |
| `Object.parentIdentifier` | `UUID?` (chair to table, dishwasher to storage) | 17.0 | yes |
| `CapturedRoomAttribute` | `protocol CapturedRoomAttribute : CaseIterable, RawRepresentable, Sendable where Self.RawValue == String` | 17.0 | yes |
| Attribute enums | ChairType, ChairArmType, ChairLegType, ChairBackType, SofaType, StorageType, TableType, TableShapeType (only chair, sofa, storage, table have attributes) | 17.0 | yes |
| `Section` | `label`, `story: Int`, `center: simd_float3` | 17.0 | yes |
| `Section.Label` | livingRoom, kitchen, diningRoom, bedroom, bathroom, unidentified. RawRepresentable, Codable, Hashable, NOT CaseIterable | 17.0 | yes |
| `CapturedStructure` | `struct`, Codable, Sendable: identifier, version, `rooms: [CapturedRoom]`, walls, doors, windows, openings, floors, objects, sections (Surface/Object/Section are typealiases of the CapturedRoom types) | 17.0 | yes |

**Export**

```swift
// CapturedRoom
func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws          // iOS 16.0
func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil,
            exportOptions: CapturedRoom.USDExportOptions = .mesh) throws                        // iOS 17.0
// CapturedStructure has ONLY the 4-argument form (iOS 17.0), with CapturedStructure.ModelProvider
// and CapturedStructure.USDExportOptions (typealiases of the CapturedRoom types).

struct CapturedRoom.USDExportOptions   // OptionSet, init(rawValue: Int32), let rawValue: Int32
  // static let parametric, mesh, model   (combinable: [.parametric, .mesh, .model])

struct CapturedRoom.ModelProvider      // iOS 17.0
  init()
  mutating func setModelFileURL(_ url: URL?, for category: CapturedRoom.Object.Category) throws
  mutating func setModelFileURL(_ url: URL?, for attributes: [any CapturedRoomAttribute]) throws
  // mutating: hold the provider in a var, not a let
  // models: .usdc preferred, also .abc, .obj, .ply, .stl
  // enum Error (iOS 17.0): attributeCombinationNotSupported, nonExistingFile(url:)
```

There is no `export(to:metadataURL:exportOptions:)` overload (verified 404). Option contents per Apple's table: parametric = editable sizes and positions, boolean ops, sections; mesh = polygonal walls with door and window cutouts and sink/fireplace recesses, sections; model = mesh features plus ModelProvider models. The URL extension picks `.usdz` or `.usd`.

**ARKit symbols used alongside RoomPlan** (all well below iOS 18.0)

```swift
weak var delegate: (any ARSessionDelegate)? { get set }        // ARSession, iOS 11.0, single weak slot
func getCurrentWorldMap(completionHandler: @escaping @Sendable (ARWorldMap?, (any Error)?) -> Void)   // iOS 12.0
func currentWorldMap() async throws -> ARWorldMap              // iOS 12.0 (async form)
var initialWorldMap: ARWorldMap? { get set }                   // ARWorldTrackingConfiguration, iOS 12.0
```

**Stated operating limits** (Apple sources): single room about 30 x 30 ft (9 x 9 m) recommended (WWDC22); Apple ML Research says the pipeline handles up to 15 x 15 m and ceilings up to 3.6 m. Keep each scan under 5 minutes (battery and thermal advice). At least 50 lux of light. Multi-room works best for single-floor homes with 1 to 4 bedrooms plus living, kitchen and dining, total area up to 2,000 sq ft (about 186 m2) (WWDC23). No documented room-count limit. Supported on all LiDAR iPhone and iPad Pro models, so the iPhone 13 Pro Max qualifies. Accuracy (Apple ML Research): walls and windows about 95 percent precision and recall, doors about 90 percent, objects about 91 / 90 percent averaged over 16 categories (chairs worst, 83 / 87 percent). Apple publishes no centimeter accuracy figure.

#### Gotchas

1. `RoomCaptureSession.Configuration` has only `isCoachingEnabled`. `beautifyObjects` is a `RoomBuilder`/`StructureBuilder` option. Writing `config.beautifyObjects` will not compile.
2. Delegate signatures must match exactly. A near miss silently falls back to the default empty implementation, and the compiler only warns "nearly matches defaulted requirement". Copy the declarations above.
3. `RoomCaptureSession.delegate` and `ARSession.delegate` are both weak. Keep a strong reference to the coordinator object.
4. `RoomCaptureViewDelegate` inherits `NSCoding`. A plain delegate class must implement `encode(with:)` and `init?(coder:)`. A `UIViewController` already conforms.
5. `stop()` defaults to pausing the ARSession. For multi-room, call `stop(pauseARSession: false)` and call `run(configuration:)` again on the same session. Backgrounding between rooms breaks the shared coordinate space; only ARWorldMap relocalization can recover it.
6. RoomPlan re-optimizes the room on stop. The last `didUpdate` snapshot is not final. Use the `RoomBuilder` result from `didEndWith` as truth.
7. `Instruction.normal` arrives constantly. Show coaching only for non-normal cases, and debounce.
8. `Surface.Category` is not CaseIterable because `door` has an associated value. Match with `case .door(let isOpen)`. `Section.Label` is also not CaseIterable. `Object.Category` and `Surface.Edge` are.
9. Everything in `CapturedRoom` and `CapturedStructure` is get-only and there is no memberwise init. The editable clean model must be Mapper's own type, filled from the RoomPlan data.
10. Transforms are in the ARSession world space (y-up, meters). Do not assume the floor is at y = 0; project with `floors[].transform`. `polygonCorners` are in each surface's local plane space and need that surface's `transform`.
11. Floors are rectangles during scanning and become polygons only after the scan ends.
12. Exported walls and floors have no UV texture coordinates, and Apple DTS confirmed there is no API for them (forum 763135). Objects export as plain boxes unless a ModelProvider supplies models. A textured realistic model cannot come from RoomPlan export.
13. Before iOS 17.4 the USD file name must not start with a digit. Irrelevant at iOS 18.0, but prefixing names with a letter costs nothing.
14. The metadata file (`metadataURL`) needs a file extension (`urlMissingFileExtension` exists). Its encoding is undocumented. Apple samples use `.plist`.
15. USDZ node names (`Mesh_grp/Arch_grp/Wall_N_grp`, `Object_grp/<Category>_grp`) are community-observed, not documented. Never parse them; use the metadata map or, better, the Codable data.
16. The Codable JSON schema is Apple-private and versioned (`version`). Do not treat Room.json as a stable interchange format across OS versions.
17. `sceneDepth` and `ARMeshAnchor` delivery on RoomPlan's session is undocumented and contradictory in the field. RoomPlan's `run(configuration:)` appears to replace the ARSession configuration. See Disputed item 2.
18. `exceedSceneSizeLimit` exists twice: `RoomCaptureSession.CaptureError` (delivered in `didEndWith`) and `StructureBuilder.BuildError` (thrown by the merge). Handle both. A forum report (775853, iPhone 15 Pro) shows the capture variant firing right after relocalization, with no Apple fix.
19. Scan quality killers: full-height mirrors and glass (gaps or phantom objects), very high ceilings, very dark surfaces, strong direct sunlight, open doors letting the scan leak into the next room, furniture flush against walls (walls may encroach).
20. `CaptureError.invalidARConfiguration` means the ARKit session runs an unsupported configuration (doc abstract). Its discussion also ties it to setting `arSession`. Only run `ARWorldTrackingConfiguration` on a session handed to RoomPlan, including the depth and mesh re-apply in Recommended step 4.
21. RoomPlan does not run in the Simulator. Check `RoomCaptureSession.isSupported` at launch. Info.plist needs `NSCameraUsageDescription` (already in `ios/project.yml`).

#### Recommended approach

1. **Deployment target stays iOS 18.0.** The full RoomPlan API (17.0) is available without guards. Nothing new exists at 18 or 26, so no `#available` branches are needed for RoomPlan.
2. **Headless session, own UI.** Use `RoomCaptureSession` directly, not `RoomCaptureView`, so the SwiftUI screens, live wireframe, coaching copy (from `Copy.swift`) and multi-room flow are Mapper's. Create Mapper's own `ARSession`, set its `delegate` (and optionally `delegateQueue`) before handing it over, then `RoomCaptureSession(arSession:)`, then `run(configuration: .init())`. Bind an `ARView` (or `ARSCNView`) to the same session for the camera preview. Draw the live wireframe from `captureSession(_:didUpdate:)`.
3. **Delegate guard.** After `captureSession(_:didStartWith:)` log whether `arSession.delegate === mapperDelegate`. Only if RoomPlan replaced it, install a forwarding multiplexer that keeps a strong reference to the captured delegate.
4. **Opportunistic depth and mesh.** Build an `ARWorldTrackingConfiguration` with `sceneReconstruction = .meshWithClassification` and `frameSemantics = [.sceneDepth]` (check support first). Run it before `RoomCaptureSession(arSession:)`, and re-run it with no options (no `.resetTracking`, no `.removeExistingAnchors`) inside `didStartWith` for every room. Keep a watchdog that re-applies it if `frame.sceneDepth` goes nil. Log once per second: `frameSemantics` contains `.sceneDepth`, `frame.sceneDepth != nil`, ARMeshAnchor count, and RoomPlan `didUpdate` count. If depth still drops on iOS 18.3.2, fall back to a separate ARKit mesh pass. Do not make the raw-mesh deliverable depend on this until a device log confirms it.
5. **Finalize each room.** In `didEndWith`, if `error` is nil, run `RoomBuilder(options: [.beautifyObjects]).capturedRoom(from:)` in a `Task`. Persist per room: the JSON-encoded `CapturedRoomData` (re-processable), the JSON-encoded `CapturedRoom` (parametric truth), and the `ARWorldMap` from `currentWorldMap()`. Write USDZ only when the user exports.
6. **Multi-room.** One `ARSession` and one `RoomCaptureSession` for the whole house. After each room: `stop(pauseARSession: false)`, save, prompt for the next room, `run(configuration:)` again. When the user taps finish, merge with `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from:)`. Keep every per-room `CapturedRoom`, so a failed merge (`invalidRoomLocation`, `exceedSceneSizeLimit`, `insufficientInput`) still leaves usable single rooms that export separately.
7. **Resume after interruption or relaunch.** Run a new `ARWorldTrackingConfiguration` with `initialWorldMap` set to the last saved map. Return `true` from `sessionShouldAttemptRelocalization(_:)`. Gate the next room on tracking state leaving `.limited(.relocalizing)` and reaching `.normal`, with a "return to the last room you scanned" prompt. Then create a new `RoomCaptureSession(arSession:)`. If `exceedSceneSizeLimit` fires straight away, offer "start a fresh structure" and keep the saved rooms.
8. **Mapper's own model is the source of truth.** Copy walls, doors, windows, openings, floors, objects and sections into Mapper types. Floor plan: `floors[].polygonCorners` through `floors[].transform`; wall segments from `walls[].transform` and `dimensions.x`; attach doors and windows with `parentIdentifier`; handle `curve != nil`. Clean model and "hide furniture": drop `objects`. Room names: `sections[].label` (only six labels; the user must be able to rename). Never rebuild from the exported USDZ.
9. **Exports.** Use `export(to:metadataURL:modelProvider:exportOptions:)` with a `.usdz` URL, a `.plist` metadata URL, and `[.mesh]` by default (`.parametric` for CAD-oriented users). Name files starting with a letter. Any metadata reader should sniff the format (binary plist, XML plist, then JSON).
10. **Limits in the UX.** Warn at 4 minutes and stop at 5 per room. Watch `CaptureError.deviceTooHot` and `ProcessInfo.thermalState`. Show pre-scan tips: close doors, turn on lights, avoid mirrors, glass and direct sun. Handle every `CaptureError` case with copy from `Copy.swift`.
11. **Measurement confidence.** Show RoomPlan lengths with a tolerance from the Units module. Offer an optional per-room or per-structure reference-length correction (one tape-measured length gives a uniform scale factor), stored in the project file so it can be undone.
12. **First CI build for this module** should log: `isSupported`, delegate identity after `didStartWith`, depth and mesh availability per second, `didUpdate` counts, and `didEndWith` errors, so every open device question gets answered in one on-device run.

#### Disputed or unsure

1. **Does RoomPlan own `arSession.delegate`, so that replacing it breaks the scan?**
   Researcher: likely yes. RoomPlan installs its own ARSessionDelegate; overriding it blacks out the preview or stops SLAM; use a multiplexer or ARSCNViewDelegate callbacks.
   Verifiers: official-docs lens did not refute but kept it at "likely" (no Apple doc says so). Reality lens refuted it: Meta's shipped `facebookresearch/ocean` sets `arSession.delegate = self` after `run()` and still gets all room callbacks, and several other repos do the same. The only contrary sources are two anecdotal 2026 repos.
   Stronger evidence: the verifiers. Apple documents no internal RoomPlan delegate, `ARSession.delegate` is a single weak slot, and shipped code overrides it successfully.
   Tie-breaker ruling: claim refuted. Setting `arSession.delegate` is allowed and is the normal way to get ARFrames. The ARSCNView route also works. A multiplexer is optional. The tie-breaker also corrected the reality verifier: Apple's multi-room article does not show any `delegate =` assignment and does not prove the app must be the delegate (the `ARSessionObserver` callbacks can also arrive through `ARSCNViewDelegate`).
   Precision notes from the verifiers: `ARSCNViewDelegate` callbacks exist only on `ARSCNView`. With RealityKit's `ARView`, use `arView.session.currentFrame` or `scene.subscribe(to: SceneEvents.Update.self)`. The one reported blackout came from overriding the delegate after `run()` with `RoomCaptureView`, so assign it before `run()`.
   Final: set Mapper's delegate on its own session before `RoomCaptureSession(arSession:)`; add the identity check and fallback multiplexer from step 3; confirm on device.

2. **Do `sceneDepth` and ARMeshAnchors survive on RoomPlan's session?**
   Researcher: unsure. Forums show `sceneDepth` nil on a direct `RoomCaptureSession` (728601), lost after `run()` and restored by re-running after `didStartWith` (763400), and still nil in Dec 2025 (808834). Community repos disagree on whether a pre-run config survives.
   Verifiers (both lenses): not refuted, correctly hedged. The sentence "Apple said in 2022 you cannot capture ARMeshAnchors while RoomCaptureSession runs" has no source; drop it.
   Stronger evidence: the three forum reports that depth drops. The only Apple line on the other side (WWDC23: a custom ARSession "will be honored") never mentions depth or mesh. Community code that re-applies in `didStartWith` cites thread 763400.
   Open-question ruling (likely): for a bare `RoomCaptureSession`, the configuration is replaced by `run(configuration:)`, so re-apply it in `didStartWith` with no reset options. The `RoomCaptureView(frame:arSession:)` doc line "RoomPlan preserves all of the AR session's settings" is scoped to that view initializer.
   Final: opportunistic only (Recommended step 4). The raw-mesh feature must not depend on it until a device log on iOS 18.3.2 proves it.

3. **Availability of `USDExportOptions.model`.**
   Researcher: iOS 17.0 (WWDC23 calls it new in iOS 17). Reality verifier: Apple doc JSON lists `static let model` at iOS 16.0, and compiled community code uses it without an iOS 17 guard. Official-docs verifier noted the same 16.0 metadata and called it a likely doc glitch.
   Final: irrelevant at iOS 18.0; both readings are usable without a guard. `ModelProvider` and the 4-argument export are iOS 17.0 either way.

4. **Room-local vs world coordinates.**
   Researcher: likely world space (y-up, meters); not documented directly. Evidence: `capturedStructure(from:)` "succeeds when all of the captured rooms share compatible world space", and community parsers treat transforms as world poses. No verifier contested it.
   Final: treat as world space from the ARSession; confirm on device by checking that two rooms scanned in one session line up without any extra transform.

5. **iOS 18 behaviour improvements** (better wall boundaries, export file-name fix, custom-ARSession fixes).
   Source: a third-party blog (it-jim), not Apple. Verifiers could not fetch it; Apple release notes for iOS 17 through 26.1 contain no RoomPlan entries. Not an API claim.
   Final: unverified; do not design around it.

6. **Metadata file encoding.** Undocumented whether the extension selects plist or JSON. Ruling: pass `.plist` like Apple's samples, sniff when reading, and never use it as Mapper's store. Device test: export with `.plist` and `.json` and log the first bytes.

7. **Relocalized multi-room across app launches.** Documented as supported (shared ARSession, or ARWorldMap relocalization before a new `RoomCaptureSession(arSession:)`). Forum 775853 confirms `exceedSceneSizeLimit` right after relocalization on an iPhone 15 Pro with no workaround; 775945 could not be fetched. Ruling (likely): support it, but keep per-room results and a fresh-structure fallback. Device test: scan room A, kill the app, relaunch, relocalize, scan room B, merge, and log the error and the gap between shared walls.

8. **Metric accuracy.** No Apple centimeter figure. Field reports range from 1 to 5 cm per wall up to a 37 cm error on a 6.45 m wall. Ruling (unsure): ship the optional reference-length correction and measure per `docs/TEST_PLAN.md` (short and long walls, single room and after merge).

### 3.3 Object Capture

Object Capture is Apple's guided photo capture (`ObjectCaptureSession` + `ObjectCaptureView`) followed by on-device photogrammetry (`PhotogrammetrySession`). Both live in RealityKit. It needs a LiDAR device with an A14 chip or later, so the iPhone 13 Pro Max (A15, LiDAR) qualifies. The Simulator is not supported. No entitlement is needed, only `NSCameraUsageDescription`, so it works with a free Apple ID sideload. No Object Capture or photogrammetry symbol is deprecated in the iOS 26 SDK (only the SceneKit loaders mentioned below are). Almost everything is iOS 17.0 or iOS 18.0 (one enum case, `Feedback.objectNotDetected`, is iOS 17.4), so with the iOS 18.0 deployment target no `#available` checks are needed. The one exception is `PhotogrammetrySample.orientation`, which is iOS 26.0 and needs `if #available(iOS 26.0, *)`; Mapper does not need it.

#### Verified API

All declarations were read from Apple's documentation JSON. "OK at 18.0" means usable with the iOS 18.0 deployment target without an availability check.

##### Capture session (`ObjectCaptureSession`)

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor class ObjectCaptureSession` (Identifiable, Observable, Sendable) | 17.0 | Yes |
| `@MainActor init()` | 17.0 | Yes |
| `@MainActor static var isSupported: Bool { get }` | 17.0 | Yes |
| `@MainActor func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())` | 17.0 | Yes |
| `@MainActor var configuration: ObjectCaptureSession.Configuration { get }` | 17.0 | Yes |
| `@MainActor var state: ObjectCaptureSession.CaptureState { get }` | 17.0 | Yes |
| `@MainActor var stateUpdates: ObjectCaptureSession.Updates<ObjectCaptureSession.CaptureState> { get }` | 17.0 | Yes |
| `@MainActor func startDetecting() -> Bool` | 17.0 | Yes |
| `@discardableResult @MainActor func resetDetection() -> Bool` | 17.0 | Yes |
| `@MainActor func startCapturing()` | 17.0 | Yes |
| `@MainActor func finish()` | 17.0 | Yes |
| `@MainActor func cancel()` | 17.0 | Yes |
| `@MainActor func pause()` / `@MainActor func resume()` | 17.0 | Yes |
| `@MainActor var isPaused: Bool { get }` / `@MainActor var isPausedUpdates: ObjectCaptureSession.Updates<Bool> { get }` | 17.0 | Yes |
| `@MainActor func beginNewScanPass()` / `@MainActor func beginNewScanPassAfterFlip()` | 17.0 | Yes |
| `@MainActor var userCompletedScanPass: Bool { get }` (+ `userCompletedScanPassUpdates: ObjectCaptureSession.Updates<Bool>`) | 17.0 | Yes |
| `@MainActor func requestImageCapture()` | 17.0 | Yes |
| `@MainActor var canRequestImageCapture: Bool { get }` (+ `canRequestImageCaptureUpdates`) | 17.0 | Yes |
| `@MainActor var numberOfShotsTaken: Int { get }` (+ `numberOfShotsTakenUpdates`) | 17.0 | Yes |
| `@MainActor var maximumNumberOfInputImages: Int { get }` | 17.0 | Yes |
| `@MainActor var isAutoCaptureEnabled: Bool { get set }` | 18.0 | Yes |
| `@MainActor var shouldPlayHaptics: Bool { get set }` | 18.0 | Yes |
| `@MainActor var feedback: Set<ObjectCaptureSession.Feedback> { get }` (+ `feedbackUpdates`) | 17.0 | Yes |
| `@MainActor var cameraTracking: ObjectCaptureSession.Tracking { get }` (+ `cameraTrackingUpdates`) | 17.0 | Yes |

```swift
// All iOS 17.0+ except where noted
struct ObjectCaptureSession.Configuration {
    init()
    var checkpointDirectory: URL?
    var isOverCaptureEnabled: Bool
}
enum ObjectCaptureSession.CaptureState {   // Equatable; any .failed equals any other .failed
    case initializing, ready, detecting, capturing, finishing, completed
    case failed(any Error)
}
enum ObjectCaptureSession.Error {                // Error, LocalizedError, Sendable
    case cancelled
    case directoryNotEmpty(URL)
    case insufficientStorage(requiredBytes: Int64)
    case sensorFailed
    case trackingFailed
}
enum ObjectCaptureSession.Feedback {
    case environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected /* iOS 17.4 */,
         objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing
}
enum ObjectCaptureSession.Tracking { case normal; case notAvailable; case limited(reason: ObjectCaptureSession.Tracking.Reason) }
enum ObjectCaptureSession.Tracking.Reason { case excessiveMotion, initializing, insufficientFeatures, relocalizing }
struct ObjectCaptureSession.Updates<Element> where Element : Sendable   // AsyncSequence, Sendable; iterated with `for await`
```

State flow: `.initializing -> .ready -> (.detecting) -> .capturing -> .finishing -> .completed`, or `.failed(Error)` at any time. A session is over at `.completed` or `.failed`. There is no capture-mode enum in the API: "area mode" is only a call pattern (see Recommended approach).

##### Capture views (SwiftUI)

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor @preconcurrency struct ObjectCaptureView<Overlay> where Overlay : View` | 17.0 | Yes |
| `nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView` | 17.0 | Yes |
| `nonisolated init(session: ObjectCaptureSession, @ViewBuilder cameraFeedOverlay: () -> Overlay)` | 17.0 | Yes |
| `@MainActor @preconcurrency func hideObjectReticle(_ value: Bool = true) -> ObjectCaptureView<Overlay>` | 18.0 | Yes |
| `@MainActor struct ObjectCapturePointCloudView` | 17.0 | Yes |
| `@MainActor init(session: ObjectCaptureSession)` (point cloud view) | 17.0 | Yes |
| `@MainActor func showShotLocations(_ value: Bool = true) -> ObjectCapturePointCloudView` | 18.0 | Yes |

`ObjectCaptureView` draws the camera feed, reticle, bounding box handles, capture dial and ARKit coaching overlay. These cannot be restyled, only overlaid. Doc text: if the view is removed, "creating a new ObjectCaptureView from the original view's ObjectCaptureSession resumes the in-progress capture session". Presenting `ObjectCapturePointCloudView` pauses capture.

##### Reconstruction (`PhotogrammetrySession`)

```swift
class PhotogrammetrySession                                     // iOS 17.0, macOS 12.0
static var isSupported: Bool { get }                            // iOS 17.0
convenience init(input: URL, configuration: PhotogrammetrySession.Configuration = Configuration()) throws
convenience init<S>(input: S, configuration: PhotogrammetrySession.Configuration = Configuration()) throws
    where S : Sequence, S.Element == PhotogrammetrySample       // iterated once, lazily
var configuration: PhotogrammetrySession.Configuration { get }
var isProcessing: Bool { get }
var activeRequests: [PhotogrammetrySession.Request] { get }
var outputs: PhotogrammetrySession.Outputs { get }             // AsyncSequence of Output, never ends
func process(requests: [PhotogrammetrySession.Request]) throws
func cancel()                                                   // asynchronous
static let limits: PhotogrammetrySession.Limits                // iOS 17.0
struct PhotogrammetrySession.Limits { var maximumInputImageDimension: Int { get }; var maximumNumberOfInputImages: Int { get } }
enum PhotogrammetrySession.Error { case insufficientStorage(requiredBytes: Int64); case invalidImages(URL); case invalidOutput(URL) }
```

```swift
struct PhotogrammetrySession.Configuration {                   // iOS 17.0
    init()
    init(checkpointDirectory: URL)
    var isObjectMaskingEnabled: Bool                            // default true (Apple samples; not stated in the reference)
    var sampleOrdering: PhotogrammetrySession.Configuration.SampleOrdering   // .unordered / .sequential
    var featureSensitivity: PhotogrammetrySession.Configuration.FeatureSensitivity // .normal / .high
    var checkpointDirectory: URL?
    var ignoreBoundingBox: Bool                                 // iOS 18.0
    // customDetailSpecification and meshPrimitive exist but are macOS only
}
enum PhotogrammetrySession.Request {                            // all cases iOS 17.0
    case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced,
                   geometry: PhotogrammetrySession.Request.Geometry? = nil)
    case modelEntity(detail: PhotogrammetrySession.Request.Detail = .reduced,
                     geometry: PhotogrammetrySession.Request.Geometry? = nil)
    case bounds
    case pointCloud
    case poses
    init(modelFile: URL)
}
struct PhotogrammetrySession.Request.Geometry {
    init(bounds: BoundingBox = BoundingBox.empty, transform: Transform = Transform.identity)
    init(orientedBounds: OrientedBoundingBox, transform: Transform = Transform.identity)
    var bounds: BoundingBox { get set }
    var transform: Transform
    var orientedBounds: OrientedBoundingBox { get set }
}
enum PhotogrammetrySession.Result {
    case modelFile(URL); case modelEntity(ModelEntity); case bounds(BoundingBox)
    case pointCloud(PhotogrammetrySession.PointCloud); case poses(PhotogrammetrySession.Poses)
}
enum PhotogrammetrySession.Output : Sendable {                  // iOS 17.0
    case inputComplete
    case requestProgress(PhotogrammetrySession.Request, fractionComplete: Double)
    case requestProgressInfo(PhotogrammetrySession.Request, PhotogrammetrySession.Output.ProgressInfo)
    case requestComplete(PhotogrammetrySession.Request, PhotogrammetrySession.Result)
    case requestError(PhotogrammetrySession.Request, any Error)
    case processingComplete
    case processingCancelled
    case invalidSample(id: Int, reason: String)
    case skippedSample(id: Int)
    case automaticDownsampling
    case stitchingIncomplete
    var localizedDescription: String { get }
}
struct PhotogrammetrySession.Output.ProgressInfo {
    let estimatedRemainingTime: TimeInterval?
    let processingStage: PhotogrammetrySession.Output.ProcessingStage?
}
enum PhotogrammetrySession.Output.ProcessingStage {
    case preProcessing, imageAlignment, pointCloudGeneration, meshGeneration, textureMapping, optimization
}
```

Detail levels on iOS:

| `Request.Detail` case | iOS | Notes |
|---|---|---|
| `.reduced` | 17.0 | The only iOS level. Under 50k triangles, about 10 MB, 2048x2048 diffuse + normal + ambient occlusion maps (42.7 MB texture memory at runtime). |
| `.preview`, `.medium`, `.full`, `.raw` | not on iOS | Doc platforms: macOS 12.0 and Mac Catalyst 15.0 only. |
| `.custom` | not on iOS | macOS 14.0 and Mac Catalyst 17.0 only. |

Doc text: "On iOS, only one detail level, .reduced, is currently supported." `modelFile(url:)` doc: "saves a USDZ file if the url ends with .usdz. If url refers to a directory, the request saves an OBJ object and every texture map there."

##### Samples (`PhotogrammetrySample`)

```swift
struct PhotogrammetrySample {
    init(id: Int, image: CVPixelBuffer)                  // iOS 17.0; id in [0, 2147483647]
    init(contentsOf url: URL) async throws               // iOS 18.0; loads an ObjectCaptureSession HEIC
    let id: Int                                          // iOS 17.0
    let image: CVPixelBuffer                             // iOS 17.0
    var metadata: [String : Any] { get set }             // iOS 17.0
    var depthDataMap: CVPixelBuffer? { get set }         // iOS 17.0
    var gravity: CMAcceleration? { get set }             // iOS 17.0
    var objectMask: CVPixelBuffer? { get set }           // iOS 17.0; kCVPixelFormatType_OneComponent8, image size
    var depthConfidenceMap: CVPixelBuffer? { get }       // iOS 18.0, read-only
    var captureTime: Date? { get }                       // iOS 18.0, read-only
    var camera: PhotogrammetrySample.Camera? { get }     // iOS 18.0, read-only (struct Camera is iOS 18.0)
    var boundingBox: simd_float4x4? { get }              // iOS 18.0; unit-cube transform of the user's box
    var scanPassID: Int? { get }                         // iOS 18.0, read-only
    var sessionID: UUID? { get }                         // iOS 18.0, read-only
    var orientation: CGImagePropertyOrientation { get }  // iOS 26.0 ONLY: needs if #available(iOS 26.0, *)
}
```

##### Reading the finished model (dimensions, export)

| Declaration | Framework | iOS | OK at 18.0 |
|---|---|---|---|
| `init(url URL: URL)` | ModelIO `MDLAsset` | 9.0 | Yes |
| `var boundingBox: MDLAxisAlignedBoundingBox { get }` | `MDLAsset` | 9.0 | Yes |
| `func childObjects(of objectClass: AnyClass) -> [MDLObject]` | `MDLAsset` | 9.0 | Yes |
| `class func canExportFileExtension(_ extension: String) -> Bool` | `MDLAsset` | 9.0 | Yes |
| `func export(to URL: URL) throws` | `MDLAsset` | 9.0 | Yes |
| `@MainActor @preconcurrency convenience init(contentsOf url: URL, withName resourceName: String? = nil) async throws` | RealityKit `Entity` | 18.0 | Yes |
| `@MainActor @preconcurrency func visualBounds(recursive: Bool = true, relativeTo referenceEntity: Entity?, excludeInactive: Bool = false) -> BoundingBox` | RealityKit `HasTransform` | 13.0 | Yes |
| `@MainActor @preconcurrency var bounds: BoundingBox { get }` | `MeshResource` | 13.0 | Yes |
| `var extents: SIMD3<Float> { get }` | `BoundingBox` | 13.0 | Yes |

SceneKit `SCNScene(url:options:)` and `SCNBoundingVolume.boundingBox` also load USDZ but are deprecated in the iOS 26 SDK. No framework computes volume.

#### Gotchas

1. `ObjectCaptureSession.isSupported` must be checked before `init()`. Doc: "If false, attempting to create an ObjectCaptureSession will result in a runtime error." Gate the feature on both `ObjectCaptureSession.isSupported` and `PhotogrammetrySession.isSupported`.
2. `start(imagesDirectory:configuration:)` is valid only once per new session. It does not throw. The images directory and checkpoint directory must be empty and writable, otherwise the session goes to `.failed` (for example `directoryNotEmpty(URL)`). Use a fresh timestamped folder per scan.
3. A `.failed` session is dead. Tear it down and create a new one. `cancel()` ends in `.failed(ObjectCaptureSession.Error.cancelled)`; treat that as a normal restart, not an error. Because `CaptureState ==` treats every `.failed` as equal, use `if case let .failed(error)` to read the payload.
4. `finish()` is silently ignored unless the state is `.capturing`. `startDetecting()` returns false (no state change) outside `.ready` or when no horizontal plane is under the screen-centre ray. Show that failure to the user.
5. Per a comment in Apple's sample (not the API reference), the session pauses when `ObjectCaptureView` leaves the hierarchy, but not when it is only covered by a sheet or blur. Call `pause()` and `resume()` yourself for sheets and help screens, or shots keep being taken.
6. When `cameraTracking` is not `.normal`, Apple's ARKit coaching overlay appears automatically. Hide Mapper's own overlay then (Apple's sample shows it only when `cameraTracking == .normal && !isPaused`).
7. Only `Detail.reduced` exists on iOS. Never write `.medium`, `.full`, `.raw`, `.preview` or `.custom` in iOS code. Use the default argument: `.modelFile(url: url)`.
8. `PhotogrammetrySession.outputs` never ends. Wrap it (Apple's sample uses an `UntilProcessingCompleteFilter` that stops after `.processingComplete` or `.processingCancelled`) or the Task leaks. Add `@unknown default` to every switch over `CaptureState`, `Feedback`, `Output`, `Request` and `Result`; Apple added `requestProgressInfo` and `stitchingIncomplete` after the first (macOS 12) release.
9. `PhotogrammetrySession.cancel()` is asynchronous. Wait for `.processingCancelled` and `isProcessing == false` before creating another session. `process(requests:)` throws if a previous batch is still processing. On the first `process` call all input is ingested and `.inputComplete` arrives before any progress.
10. Release the capture session (`objectCaptureSession = nil`) before creating the `PhotogrammetrySession`. Apple's sample does this "to free GPU and memory resources". Running both was the pattern behind reported `EXC_BAD_ACCESS` crashes in `com.apple.corephotogrammetry` (the iOS 17 beta ones were fixed; one later iPhone 15 Pro Max report has no resolution).
11. `isObjectMaskingEnabled` is true in Apple's samples (the reference states no default) and removes the background. For area or scene captures set it to false, and on iOS 18 also set `ignoreBoundingBox = true`, or the scene is masked away. The `ignoreBoundingBox` doc warns the resulting mesh "will likely need post-processing".
12. `maximumNumberOfInputImages` is device-specific and undocumented. Capture stops at that limit unless `isOverCaptureEnabled` is true; extra images are kept but skipped on device (`.overCapturing` feedback). `PhotogrammetrySession` ignores samples beyond its own limit and emits `.invalidSample`. `.automaticDownsampling` means it shrank the images to fit memory; log it. Read both values at runtime.
13. OBJ output needs a URL that is a directory (pre-create it; `hasDirectoryPath` must be true). A non-directory URL without `.usdz` fails ("Output URL must be specify a .usdz extension file!"), and a URL ending in `.obj` is undefined (`.invalidOutput` on macOS). On iOS this is community-confirmed only (iOS 26). File names inside the folder are not documented; find the `.obj` by extension.
14. The model is in metres because the HEICs carry LiDAR depth ("If your source images contain depth data, RealityKit uses it to calculate the real-world size"). Bounding box extents are real dimensions. Volume and surface area must be computed from mesh buffers.
15. Object detection needs objects larger than about 8 cm (3 in) per side. Areas over about 6 ft (1.8 m) "may have reduced mesh and texture quality" at `.reduced` (WWDC24). Reflective, transparent, thin, deformable and textureless objects scan badly. `.objectNotFlippable` means too little texture to stitch after a flip; `.stitchingIncomplete` means a flipped side did not stitch. Do not flip deformable objects or objects with symmetric or repeating texture (WWDC23).
16. `beginNewScanPass()` and `beginNewScanPassAfterFlip()` are object-mode only (invalid in area mode). Call the flip variant after the object is flipped. The doc says `beginNewScanPass` "will throw" outside `.capturing` (or `.paused` from `.capturing`), but the declaration is not `throws`; guard on state instead of using `try`. `beginNewScanPassAfterFlip()` returns the session to box selection for the new orientation; `beginNewScanPass()` keeps the same box and stays in `.capturing`. Both reset `userCompletedScanPass`.
17. Storage: each HEIC is 3024x4032 with an embedded 192x256 depth map, roughly 2 to 4 MB. A few hundred images plus checkpoint and model reach 1 to 4 GB. Low space appears only as `insufficientStorage(requiredBytes:)`, with no documented threshold. Delete `Checkpoint/` after success and the whole capture folder on cancel.
18. Keep the app in the foreground and set `UIApplication.shared.isIdleTimerDisabled = true` during capture and reconstruction.

#### Recommended approach

1. **Gate.** Show Object mode only when `ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported`. On first run, log `ObjectCaptureSession.maximumNumberOfInputImages` (needs a live session instance) and `PhotogrammetrySession.limits.maximumNumberOfInputImages` / `.maximumInputImageDimension`. Drive the shot budget UI from those values, never from a hard-coded 1000.
2. **Follow Apple's sample structure** ("Scanning objects using Object Capture", targets iOS 18.0). A `@MainActor @Observable` model owns `ObjectCaptureSession?` and `PhotogrammetrySession?`. A folder manager creates `Documents/<scan id>/Images/`, `Checkpoint/` and `Models/`. Observe `stateUpdates`, `feedbackUpdates`, `cameraTrackingUpdates` and `userCompletedScanPassUpdates` with `for await` Tasks. Host the session in `ObjectCaptureView(session:cameraFeedOverlay:)` with Mapper's SwiftUI controls as ZStack siblings and `.id(session.id)`. All button text comes from `Copy.swift`; map each `Feedback` case to a Copy string. `.objectNotDetected` means detection failed and a default box is shown for manual adjustment. `.environmentTooDark` stops auto-capture.
3. **Start.** `var config = ObjectCaptureSession.Configuration(); config.checkpointDirectory = checkpointURL; config.isOverCaptureEnabled = false` (Mapper has no Mac path, so extra images only cost storage), then `session.start(imagesDirectory: imagesURL, configuration: config)`. Run a free-space pre-flight first (for example, refuse below about 3 GB, tuned once real image sizes and limits are logged) and show `requiredBytes` if `insufficientStorage` still happens.
4. **Object mode (primary).** `.ready`: user taps Continue, call `startDetecting()` and show a hint if it returns false. `.detecting`: user adjusts the box, then `startCapturing()`. When `userCompletedScanPass` becomes true, offer another pass: `beginNewScanPass()` for objects that cannot be flipped (new height) or `beginNewScanPassAfterFlip()` after the user flips a rigid, textured object. Aim for three passes, as Apple recommends. Offer `ObjectCapturePointCloudView(session:).showShotLocations()` as a review step between passes. Then `finish()` and wait for `.completed`. Apple's sample refuses to reconstruct with fewer than 10 images; Mapper should apply a similar minimum.
5. **Area mode (secondary, small scenes only).** Skip `startDetecting()`, call `startCapturing()` from `.ready`, apply `.hideObjectReticle(true)`, and at reconstruction set `isObjectMaskingEnabled = false` and `ignoreBoundingBox = true`. Limit it to textured scenes under about 1.8 m. Rooms stay on RoomPlan plus the ARKit mesh.
6. **Reconstruct.** After `.completed`, set the capture session to nil. Build `var cfg = PhotogrammetrySession.Configuration(); cfg.checkpointDirectory = checkpointURL` (plus the area-mode flags), then `try PhotogrammetrySession(input: imagesURL, configuration: cfg)`. Request `[.modelFile(url: modelsURL.appendingPathComponent("model.usdz")), .bounds]`. Iterate `outputs` through a completion filter. Show `processingStage` and `estimatedRemainingTime` from `requestProgressInfo`, and `fractionComplete` from `requestProgress`. Design the screen for 2 to 10 minutes. Log wall time, image count and `ProcessInfo.thermalState` at start and end. On success delete `Checkpoint/`. If the app was interrupted, reuse the same checkpoint folder to resume.
7. **Avoid `.modelEntity`** (keeps the whole mesh in memory on a 6 GB device). Treat `.poses` and `.pointCloud` as optional: request them only in a diagnostic build, log `requestComplete` or `requestError`, and do not depend on them.
8. **OBJ export.** Primary: a second `.modelFile` request with a pre-created directory URL (`appendingPathComponent("OBJ", isDirectory: true)`), then list the folder and pick files by extension. Verify on the iOS 18.3.2 device in the first Object Capture build. Fallback: `MDLAsset(url: usdzURL)` then `export(to:)` a `.obj` URL after checking `MDLAsset.canExportFileExtension("obj")`; materials may only partly survive, so also consider Mapper's own exporter.
9. **Measurements.** Width, height and depth: use the `.bounds` result when it arrives, else `MDLAsset(url:).boundingBox` (works off the main actor), else `Entity(contentsOf:)` plus `visualBounds(relativeTo: nil).extents` on the main actor. Before reconstruction, `PhotogrammetrySample(contentsOf:).boundingBox` (iOS 18) gives the user's box without waiting. Volume: walk `childObjects(of: MDLMesh.self)` vertex and index buffers and sum signed tetrahedra; report it only when the mesh is closed. Format every value through `ios/Sources/Units/`.
10. **Viewing.** Show the USDZ in Mapper's own viewer (see the rendering section); Apple's sample uses `QLPreviewController`, which is a quick fallback. Do not use SceneKit loaders (deprecated in the iOS 26 SDK).
11. **Crop.** The SPEC asks for manual cropping. `Request.Geometry(bounds:transform:)` or `init(orientedBounds:transform:)` passed to `.modelFile` crops at reconstruction time. Cropping after the fact is Mapper's own mesh processing.

#### Disputed or unsure

1. **Are non-`.reduced` detail levels a compile error or a runtime error on iOS?** Researcher and the official-docs verifier: compile-time, because the per-case doc platforms for `.preview`, `.medium`, `.full`, `.raw` and `.custom` list only macOS and Mac Catalyst. One reality verifier wrote "All Detail cases compile on iOS" and cited community apps that fall back at runtime. Stronger evidence: compile-time. The per-case metadata was re-fetched for this section (`.medium`: Mac Catalyst 15.0, macOS 12.0, no iOS), and an iOS 26 project (Lidar4Free) states the cases are `@available(iOS, unavailable)`. Other iOS projects wrap them in `#if os(macOS)`, and none references them in iOS code. The "compiles" side cited runtime fallbacks, which do not prove the cases compile. No tie-breaker. Ruling: never reference any case other than `.reduced` in iOS code. The practical rule is the same either way.
2. **OBJ output through a directory URL on iOS.** Researcher: documented, confirmed only by a forum thread. Tie-breaker (second pass, both lenses): the claim stands, but the forum thread (742077) never names a platform, so it is not an iOS report. Better evidence is an iOS 26 app that writes OBJ, MTL and textures (plus USDA) into a pre-created directory. WWDC21 (10076) shows the same directory output on macOS. No iOS 18 report exists. Ruling: likely works; verify on device; keep the ModelIO fallback.
3. **Do `.bounds`, `.poses`, `.pointCloud` and `.modelEntity` work on iOS?** Docs list all as iOS 17.0. Apple's iOS sample marks them "Not supported yet", but that comment only covers its own switch. Open-question answer: `.bounds` works on iPhone in a community app (iOS 26). No field evidence for the other three. Ruling: use `.bounds`; treat `.poses` and `.pointCloud` as optional; avoid `.modelEntity`.
4. **Image limit of 1000 on iOS.** Researcher cited a community forum figure. Second pass found no verifiable source. The only Apple number is up to 2000 on Macs with lots of memory. Ruling: unknown until logged on the device; never hard-code.
5. **`ObjectCaptureView(session:)` needs the Overlay type inferred.** Researcher's note. Refuted by the docs verifier: the declaration is `nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView`, so it compiles as is.
6. **Checkpoint folder name.** Researcher said the sample uses `Checkpoint/`; verifiers found `Snapshots/` in the WWDC23 sample and its forks. Both are right for different sample versions; the name is arbitrary. Ruling: Mapper uses `Checkpoint/`.
7. **`shouldPlayHaptics` availability.** The researcher grouped it with iOS 17.0 members. Apple doc JSON (fetched for this section) says iOS 18.0. Ruling: iOS 18.0, still fine at the 18.0 target.
8. **Automatic pause when the view is removed.** Comes from a comment in Apple's sample, not the API reference. The `ObjectCaptureView` overview does say re-creating the view from the same session resumes capture. Ruling: likely true; still call `pause()` explicitly whenever the view is hidden, which is safe either way.
9. **`Updates` is an AsyncSequence.** Re-checked: the doc JSON relationships list `AsyncSequence` and `Sendable` for `ObjectCaptureSession.Updates` (and `AsyncSequence` for `PhotogrammetrySession.Outputs`), and Apple's sample uses `for await` on it. Ruling: verified.
10. **Reconstruction time on the A15.** Only qualitative evidence: Apple says "a few minutes"; an iOS 26 community app says "one to a few minutes"; an independent blog (not reachable for re-check) reported iPhone 13 Pro Max times close to an M1 Mac mini. Ruling: unsure; measure on device.
11. **`Entity.visualBounds(relativeTo:)` declaration.** Researcher could not resolve the page. Resolved in the second pass: it is documented on `HasTransform` with the declaration in the table above, iOS 13.0.
12. **`PhotogrammetrySession.Error.processError`.** An undocumented internal error with cv3dapi codes seen in one forum thread (a macOS reconstruction of iOS area captures). Ruling: not an API; log `localizedDescription` for any unknown error.

### 3.4 Texturing pipeline

Scope: turn the LiDAR mesh into the "realistic model" (SPEC, Representation B and "Image / texture capture") by projecting selected camera keyframes onto a frozen snapshot of the ARKit mesh, on device, with Swift and Metal only. No first-party API textures an ARKit mesh for us. Object Capture (PhotogrammetrySession) is a separate path for objects; it cannot take our LiDAR mesh as input.

#### Verified API

All symbols below were read from Apple documentation JSON by the researcher, a verifier, or during this synthesis. "OK at 18.0" means usable at the iOS 18.0 deployment target with no `#available` check.

**Camera image, pose and intrinsics (ARKit)**

| Declaration | Type | iOS | OK at 18.0 |
|---|---|---|---|
| `var capturedImage: CVPixelBuffer { get }` | ARFrame | 11.0 | Yes |
| `var imageResolution: CGSize { get }` | ARCamera | 11.0 | Yes |
| `var intrinsics: simd_float3x3 { get }` | ARCamera | 11.0 | Yes |
| `var transform: simd_float4x4 { get }` | ARCamera | 11.0 | Yes |
| `var exposureDuration: TimeInterval { get }` | ARCamera | 13.0 | Yes |
| `var exposureOffset: Float { get }` | ARCamera | 13.0 | Yes |
| `var trackingState: ARCamera.TrackingState { get }` | ARCamera | 11.0 | Yes |
| `var exifData: [String : Any] { get }` | ARFrame | 16.0 | Yes |
| `var isAutoFocusEnabled: Bool { get set }` | ARWorldTrackingConfiguration | 11.3 | Yes (default true) |
| `class var configurableCaptureDeviceForPrimaryCamera: AVCaptureDevice? { get }` (nil without an ultra-wide camera; Apple warns extreme changes can affect ARKit features) | ARConfiguration | 16.0 | Yes |
| `optional func session(_ session: ARSession, didUpdate frame: ARFrame)` | ARSessionDelegate | 11.0 | Yes |
| `var delegateQueue: dispatch_queue_t? { get set }` | ARSession (nil = main queue) | 11.0 | Yes |

Facts from the docs: `capturedImage` is full-range bi-planar YCbCr (ITU-R 601-4), in the camera's native sensor orientation (always landscape). `intrinsics` is `[fx 0 ox; 0 fy oy; 0 0 1]` in pixels for exactly that buffer, with the principal point measured from the top-left corner. Camera space: +X right, +Y up (with respect to UIInterfaceOrientation.landscapeRight, which is UIDeviceOrientation.landscapeLeft), camera looks down -Z. Apple's documented shader conversion is `rgb = (ycbcrToRGBTransform * float4(y, cb, cr, 1)).rgb` with columns `(1, 1, 1, 0)`, `(0, -0.3441, 1.7720, 0)`, `(1.4020, -0.7141, 0, 0)`, `(-0.7010, 0.5291, -0.8860, 1)`.

**Projection convention (verified by both verifiers against Apple's point-cloud sample and ARCamera docs)**

```swift
// world point p -> pixel (u, v) in capturedImage (landscape, origin top-left)
let c = keyframe.transform.inverse * SIMD4<Float>(p, 1)   // camera space
let z = -c.z                                               // must be > 0; equals LiDAR planar depth
let u = fx * c.x / z + ox
let v = -fy * c.y / z + oy                                 // note the minus sign
// Texture coordinate into a CVMetalTextureCache texture of the same buffer: (u / W, v / H), no flip.
```

The inverse (Apple sample): `local = K.inverse * float3(u, v, 1) * depth`, then `world = camera.transform * diag(1, -1, -1, 1) * float4(local, 1)`.

**Scene depth (LiDAR)**

| Declaration | Type | iOS | OK at 18.0 |
|---|---|---|---|
| `var sceneDepth: ARDepthData? { get }` | ARFrame | 14.0 | Yes, LiDAR only |
| `var smoothedSceneDepth: ARDepthData? { get }` | ARFrame | 14.0 | Yes |
| `unowned(unsafe) var depthMap: CVPixelBuffer { get }` | ARDepthData | 14.0 | Yes |
| `unowned(unsafe) var confidenceMap: CVPixelBuffer? { get }` | ARDepthData | 14.0 | Yes |
| `static var sceneDepth: ARConfiguration.FrameSemantics { get }` | FrameSemantics | 14.0 | Yes |

Depth is planar distance from the camera plane in meters (the same quantity as `-c.z`). It covers the same field of view and orientation as `capturedImage`. Documented formats (as examples, check at runtime): depth `kCVPixelFormatType_DepthFloat32` to Metal `.r32Float`; confidence `kCVPixelFormatType_OneComponent8` to `.r8Uint`, values 0 low, 1 medium, 2 high. 256x192 is community-observed, not documented.

**Mesh snapshot (ARKit, all iOS 13.4, OK at 18.0)**

```swift
class ARMeshAnchor : ARAnchor { var geometry: ARMeshGeometry { get } }   // vertices are anchor-local
var vertices: ARGeometrySource { get }          // ARMeshGeometry, SIMD3<Float>, format .float3
var normals: ARGeometrySource { get }           // per vertex in practice
var faces: ARGeometryElement { get }            // triangles, bytesPerIndex 4 (UInt32) per Apple's overview
var classification: ARGeometrySource? { get }   // one UInt8 per FACE (ARMeshClassification raw value)
// ARGeometrySource: buffer: any MTLBuffer, count, format: MTLVertexFormat, componentsPerVector, offset, stride
// ARGeometryElement: buffer: any MTLBuffer, bytesPerIndex, count (primitives), indexCountPerPrimitive, primitiveType
```

World position is `anchor.transform * float4(vertex, 1)`. Normals rotate by the 3x3 part of the rigid anchor transform.

**Metal and image I/O**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `func supportsFamily(_ gpuFamily: MTLGPUFamily) -> Bool` (MTLDevice; `.apple8` = A15) | 13.0 | Yes |
| `class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor` | 8.0 | Yes |
| `var storageMode: MTLStorageMode { get set }` (MTLTextureDescriptor, default `.shared` on iOS) | 9.0 | Yes |
| `var usage: MTLTextureUsage { get set }` | 9.0 | Yes |
| `func CVMetalTextureCacheCreateTextureFromImage(_ allocator: CFAllocator?, _ textureCache: CVMetalTextureCache, _ sourceImage: CVImageBuffer, _ textureAttributes: CFDictionary?, _ pixelFormat: MTLPixelFormat, _ width: Int, _ height: Int, _ planeIndex: Int, _ textureOut: UnsafeMutablePointer<CVMetalTexture?>) -> CVReturn` | 8.0 | Yes |
| `func jpegRepresentation(of image: CIImage, colorSpace: CGColorSpace, options: [CIImageRepresentationOption : Any] = [:]) -> Data?` (CIContext) | 10.0 | Yes |
| `func heifRepresentation(of image: CIImage, format: CIFormat, colorSpace: CGColorSpace, options: [CIImageRepresentationOption : Any] = [:]) -> Data?` (CIContext) | 11.0 | Yes |
| `init(mtlTexture texture: any MTLTexture, commandBuffer: (any MTLCommandBuffer)?)` (CIRenderDestination) | 11.0 | Yes |
| `var isFlipped: Bool { get set }` (CIRenderDestination) | 11.0 | Yes |
| `func newTexture(cgImage: CGImage, options: [MTKTextureLoader.Option : Any]? = nil) throws -> any MTLTexture` (MTKTextureLoader) | 9.0 | Yes |
| `class MPSImageLaplacian`, `class MPSImageStatisticsMeanAndVariance` (MetalPerformanceShaders) | 10.0 / 11.0 | Yes |

Limits (Metal Feature Set Tables, May 2026): maximum 2D texture 16,384 px on Apple3 to Apple9 (A15 is Apple8), 32,768 on Apple10. A 4096x4096 RGBA8 page is 64 MiB (16.8 Mtexels); 16384x16384 would be 1 GiB. Depth, stencil and multisample textures must be `.private` or `.memoryless`; the Metal validation layer asserts otherwise.

**High-resolution frames (optional, off in v1)**

```swift
func captureHighResolutionFrame(completion: @escaping @Sendable (ARFrame?, (any Error)?) -> Void)   // ARSession, iOS 16.0
func captureHighResolutionFrame() async throws -> ARFrame                                          // ARSession, iOS 16.0
class var recommendedVideoFormatForHighResolutionFrameCapturing: ARConfiguration.VideoFormat? { get }  // iOS 16.0
class var recommendedVideoFormatFor4KResolution: ARConfiguration.VideoFormat? { get }                  // iOS 16.0
var isRecommendedForHighResolutionFrameCapturing: Bool { get }   // ARConfiguration.VideoFormat, iOS 16.0
func captureHighResolutionFrame(using photoSettings: AVCapturePhotoSettings?, completion: @escaping @Sendable (ARFrame?, (any Error)?) -> Void)   // iOS 26.0+ ONLY, needs #available
func captureHighResolutionFrame(using photoSettings: AVCapturePhotoSettings?) async throws -> ARFrame   // iOS 26.0+ ONLY, needs #available
```

The 12 MP image is 4032x3024 on iPhone 13 Pro (WWDC22). On that phone `recommendedVideoFormatForHighResolutionFrameCapturing` is still 1920x1440 at 60 fps, so the live stream is unchanged.

**Display of the textured mesh (RealityKit, corrected by the tie-breaker)**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor class LowLevelMesh` / `@MainActor init(descriptor: LowLevelMesh.Descriptor) throws` | 18.0 | Yes |
| `LowLevelMesh.Descriptor`: `vertexCapacity`, `indexCapacity`, `vertexAttributes: [LowLevelMesh.Attribute]`, `vertexLayouts: [LowLevelMesh.Layout]`, `indexType: MTLIndexType`; `init(vertexCapacity: Int = 0, vertexAttributes: [LowLevelMesh.Attribute] = [Attribute](), vertexLayouts: [LowLevelMesh.Layout] = [Layout](), indexCapacity: Int = 0, indexType: MTLIndexType = MTLIndexType.uint32)` | 18.0 | Yes |
| `init(semantic: LowLevelMesh.VertexSemantic, format: MTLVertexFormat, layoutIndex: Int = 0, offset: Int)` (Attribute; semantics include `.position`, `.normal`, `.uv0`) | 18.0 | Yes |
| `init(bufferIndex: Int, bufferOffset: Int = 0, bufferStride: Int)` (Layout) | 18.0 | Yes |
| `init(indexOffset: Int = 0, indexCount: Int = 0, topology: MTLPrimitiveType = .triangle, materialIndex: Int = 0, bounds: BoundingBox)` (Part); `@MainActor var parts: LowLevelMesh.PartsCollection { get set }` with `append(_:)`, `append(contentsOf:)`, `replaceAll(_:)`, `removeAll()` | 18.0 | Yes |
| `@MainActor func withUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)` | 18.0 | Yes |
| `@MainActor func replaceUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)` | 18.0 | Yes |
| `@MainActor func withUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)` | 18.0 | Yes |
| `@MainActor func replaceUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)` | 18.0 | Yes |
| `@MainActor func replaceIndices(using commandBuffer: any MTLCommandBuffer) -> any MTLBuffer` (GPU path) | 18.0 | Yes |
| `@MainActor @preconcurrency convenience init(from mesh: LowLevelMesh) async throws` and the documented sync overload `@MainActor @preconcurrency convenience init(from mesh: LowLevelMesh) throws` (MeshResource) | 18.0 | Yes |
| `@MainActor class LowLevelTexture` / `@MainActor init(descriptor: LowLevelTexture.Descriptor) throws` | 18.0 | Yes |
| `@MainActor func replace(using commandBuffer: any MTLCommandBuffer) -> any MTLTexture` (LowLevelTexture) | 18.0 | Yes |
| `init(textureType: MTLTextureType = .type2D, pixelFormat: MTLPixelFormat = .invalid, width: Int = 0, height: Int = 0, depth: Int = 1, mipmapLevelCount: Int = 1, arrayLength: Int = 1, textureUsage: MTLTextureUsage = .unknown, swizzle: MTLTextureSwizzleChannels = .init(red: .red, green: .green, blue: .blue, alpha: .alpha))` (LowLevelTexture.Descriptor; every parameter has a default) | 18.0 | Yes |
| `@MainActor @preconcurrency convenience init(from texture: LowLevelTexture) async throws` plus a sync `throws` overload (TextureResource) | 18.0 | Yes |
| `@MainActor @preconcurrency convenience init(image cgImage: CGImage, withName resourceName: String? = nil, options: TextureResource.CreateOptions) async throws` plus a sync `throws` overload with the same parameters (TextureResource) | 18.0 | Yes |
| `init(semantic: TextureResource.Semantic?, mipmapsMode: TextureResource.MipmapsMode = .allocateAndGenerateAll)` (TextureResource.CreateOptions) | 15.0 | Yes |
| `@MainActor @preconcurrency static func generate(from cgImage: CGImage, withName resourceName: String? = nil, options: TextureResource.CreateOptions) throws -> TextureResource` | 15.0, deprecated 18.0 | Compiles, avoid |
| `init(texture: TextureResource)` (UnlitMaterial) | 18.0 | Yes |
| `@MainActor @preconcurrency init(mesh: MeshResource, materials: [any Material] = [])` (ModelEntity) | 13.0 | Yes |
| `struct MeshDescriptor`, `init(name: String = "")`; `MeshBuffers.TextureCoordinates = MeshBuffer<SIMD2<Float>>` | 15.0 | Yes |

`MeshDescriptor.positions`, `.normals`, `.textureCoordinates` and `MeshResource.generate(from: [MeshDescriptor])` are missing from the doc JSON topic lists. Apple's MeshDescriptor overview sample and compiling packages use them, so treat them as likely, not verified. Apple's only LowLevelMesh sample app is visionOS-only; on iPhone the evidence is SDL (gated on iOS 18.0) and community code.

**Export helpers used by texturing output**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `class func convert(toUSDZ inputURL: URL, writeTo outputURL: URL)` (MDLUtility; returns Void, never throws) | 18.0 | Yes |
| `class func canExportFileExtension(_ extension: String) -> Bool` (MDLAsset; docs name only .obj and .stl) | 9.0 | Yes |
| `func write(to url: URL, options: [String : Any]? = nil, delegate: (any SCNSceneExportDelegate)?, progressHandler: SCNSceneExportProgressHandler? = nil) -> Bool` (SCNScene; docs list only .scn and .dae, usdz output comes from WWDC19 only) | 8.0, deprecated 26.0 | Compiles, avoid |

SceneKit as a whole (including SCNGeometrySource, SCNGeometryElement, SCNScene.write) is deprecated at iOS 26.0: "SceneKit is deprecated, use RealityKit instead" (WWDC25 session 288, a soft deprecation, maintenance mode).

**Deprecated orientation helpers (do not use for texturing)**

`viewMatrix(for:)`, `projectPoint(_:orientation:viewportSize:)`, `projectionMatrix(for:viewportSize:zNear:zFar:)`, `unprojectPoint(_:ontoPlane:orientation:viewportSize:)` (ARCamera) and `displayTransform(for:viewportSize:)` (ARFrame) are iOS 11.0 (`unprojectPoint` is iOS 12.0), deprecated at 27.0. Apple's current docs show the first four under their Objective-C names (for example `viewMatrixForOrientation:`); the Swift spellings above are the standard imports. Their `viewRotationAngle:` replacements are iOS 27.0+ only and need `#available` on our target. The verifiers found them not yet deprecated in the iOS 26 SDK; any warning under Xcode 26.6 would only be a warning.

#### Gotchas

1. One sign or flip error ruins every texture, and each compile is a CI round trip. Ship two self-tests in the first texturing build: (a) project a few mesh vertices with the formula and draw dots over the live `capturedImage` in landscape; (b) render a numbered 2x2 test atlas on a quad and check that tile "1" is top-left.
2. `capturedImage` is landscape even when the phone is held in portrait. Never apply the display transform or a portrait/swapped-viewport trick to texturing math (MetalWorldTextureScan does this and depends on deprecated overloads).
3. Intrinsics change per frame (autofocus moves the lens; Niantic maintainer and marslogger code confirm). Store fx, fy, ox, oy with every keyframe. Never use one global K.
4. Do not retain ARFrames. An Apple engineer (WWDC22 lounge) confirms a limited frame pool. The console warns "ARSessionDelegate is retaining 11 ARFrames" and tracking degrades at 11 to 13 retained frames in a 2026 field report. Treat 10 as a hard ceiling, and aim for zero retained beyond the callback. `sceneDepth` buffers are pooled too. `ARFrame.copy()` is not documented to deep-copy pixel buffers.
5. Do not hardcode 256x192 or the 0.1333 scale. Read `CVPixelBufferGetWidth/Height` of the depth map per frame and scale K by `depthW / imageResolution.width` (a 584x384 map with a 4K image has been reported). Use pixel-centre mapping (`uDepth = (u + 0.5) * s - 0.5`) or normalized coordinates with a linear sampler; `floor(u * s)` can be off by half a depth texel, about 4 image pixels.
6. Pixel formats are documented as examples. Check `CVPixelBufferGetPixelFormatType` and plane count (2) at runtime. The FourCC `420f` is observed, not named in ARKit docs.
7. Memory: 300 decoded 1920x1440 RGBA keyframes are about 3.3 GB. Bake one keyframe at a time and keep the peak at the atlas pages plus one or two decoded frames.
8. Depth render targets must be `.private` (or `.memoryless`, which does not survive the pass). For CPU access write linear depth to an `.r32Float` colour attachment or blit to a buffer.
9. Core Image has a bottom-left origin. `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` into an MTLTexture gives a vertically flipped image. Use `CIRenderDestination` with `isFlipped = true`, or avoid rendering CIImages into textures at all. JPEG/HEIC written by CIContext and reloaded through ImageIO plus `MTKTextureLoader` without the `.origin` option keep the top-left orientation of the CVPixelBuffer.
10. UV V-origin differs by consumer. Metal and CoreGraphics atlases are top-left; RealityKit mesh UVs, OBJ `vt` and USD `st` are bottom-left (RealityKit is community evidence). Flip once at the boundary: `v' = 1 - v`.
11. ARKit mesh anchors keep changing. Freeze a snapshot at "Done", apply anchor transforms, and weld duplicate vertices across anchor borders, or chart seams will land on anchor boundaries.
12. Seam-based gain solving needs overlap. Gate keyframes on motion, not time, so each triangle is seen by 3 or more keyframes.
13. `captureHighResolutionFrame`: one request in flight, fails if called right after `run()`, needs a format with `isRecommendedForHighResolutionFrameCapturing`, its `sceneDepth` alignment with the 12 MP image is unknown, and custom photo settings with depth delivery crash (Apple engineer answer). Hi-res frame buffers are allocated per capture, not from the live pool.
14. 4K streaming is 16:9 (3840x2160 at 30 fps) and crops the 4:3 LiDAR field of view. Stay on the default 4:3 format (1920x1440 up to 60 fps per WWDC22). Enumerate `supportedVideoFormats` at runtime rather than hardcoding; RoomPlan may run its own format.
15. `MeshResource(from:)` and `TextureResource(image:withName:options:)` are `@MainActor` (iOS 18.0). `TextureResource(image:withName:options:)` has a documented `async throws` overload and a documented sync `throws` overload (doc slug `-1pzep`). For `MeshResource(from: LowLevelMesh)` both documented pages (`init(from:)` and `init(from:)-1i7c9`) are `async throws`; a sync form appears only in community code and Apple sample code, not in the doc JSON (re-checked during synthesis). Write `try await MeshResource(from:)` everywhere; for textures, `try await` in async code and `try` in sync `@MainActor` code.
16. `MDLUtility.convert(toUSDZ:writeTo:)` reports no errors. Check the output exists, is non-empty and starts with the bytes "PK". Its input must be a USD layer (or a SceneKit-written scene), not OBJ and not .reality. It wraps Pixar's ARKit usdz packager, so the atlas JPEGs must sit beside the usda and be referenced by relative path. Our fallback writer must follow the usdz spec: stored (uncompressed) zip, default layer as the first entry, every payload 64-byte aligned, CRC32 per entry.
17. Multi-page atlases mean one submesh (LowLevelMesh part, OBJ `usemtl`, USD GeomSubset or mesh) per page. Vertices shared by triangles in different charts must be duplicated, which inflates vertex count about 2 to 3 times.

#### Recommended approach

Target: iPhone 13 Pro Max (A15, Apple8 GPU, 6 GB), about 200k to 1M triangles and 200 to 400 keyframes per room. All first-party, one Metal library, no Metal 3 or 4 features needed.

1. **Capture.** `ARWorldTrackingConfiguration` with `sceneReconstruction = .meshWithClassification`, `frameSemantics = [.sceneDepth]`, default 4:3 video format, light estimation on. Keep auto exposure but cap `activeMaxExposureDuration` near 1/120 s through `configurableCaptureDeviceForPrimaryCamera` (after `run`, inside `lockForConfiguration`) to limit blur. Do not lock exposure for the whole room.
2. **Keyframe gate** on the delegate queue: tracking `.normal`; moved more than about 15 cm or rotated more than about 10 degrees since the last keyframe; `exposureDuration` below about 1/60 s; low angular speed; optional sharpness (MPS Laplacian then mean and variance on downscaled luma, about 1 ms). Expect 1 to 2 keyframes per second. Thresholds need device tuning.
3. **Keyframe record.** For an accepted frame, inside the callback deep-copy the Y/CbCr planes (about 4.1 MB) and the depth and confidence maps (about 250 KB), then release the frame. Encode the copy to JPEG on a serial utility queue with a small in-flight cap; drop keyframes rather than queue unboundedly. A slow encode that still references the pooled buffer causes the retention storm (a 2026 field report saw a 1.2 s encode trigger it), so never hand the live `capturedImage` to the encoder. Store `{index, timestamp, fx, fy, ox, oy, imageW, imageH, transform, exposureDuration, exposureOffset, exifData subset, sharpness}` plus the JPEG file (q 0.85 to 0.9, about 0.7 MB, about 200 MB per 300 keyframes) and raw depth/confidence files. JPEG is the default; HEIC halves size but costs decode time.
4. **Freeze.** On "Done", copy all anchors into one world-space mesh, weld vertices (spatial hash, about 1 mm), drop tiny islands, compute face normals and centroids, keep the face to classification map. Make decimation a pipeline stage that is a no-op below a threshold (for example 300k faces); ModelIO has no decimator, so it is our own code (quadric or vertex clustering). Another option: texture only the raw mesh and move the atlas to the clean model by nearest-face UV transfer.
5. **View selection on the GPU.** Per keyframe, render the frozen mesh into a small depth target (960x720 is enough) using `view = transform.inverse` and a projection built from K. Then one compute dispatch over all faces: project the 3 vertices with the formula above, reject outside a margin, back-facing (`dot(n, toCam) < 0.2`), too near or far (about 0.08 to 5.5 m), or occluded (mesh depth, epsilon 1 to 2 cm plus 1 percent of depth). Use LiDAR depth as a secondary reject where confidence is high (ScanSpace uses a tolerance of 0.03 + 0.03 x depth m, min of a 2x2 neighbourhood); it catches real occluders missing from the mesh. Score = projected area x cos(angle) x sharpness x exposure weight; keep the best per face. Then 2 to 3 CPU passes of neighbour smoothing to cut chart count (ScanSpace: a candidate must keep at least 30 percent of the best score, bonus 0.35 per agreeing neighbour).
6. **Charts and packing on the CPU.** Group faces by chosen keyframe, split connected components, recursively split along the longer box axis until each chart is at most 1024 px and fill ratio at least 0.35. Add 2 to 4 px padding. Pick a global scale so everything fits N pages of 4096x4096 at 2 to 4 mm per texel (a furnished room is 1 to 3 pages). Shelf-pack. Do not use fixed per-triangle cells: 500k triangles need 4 pages at 16x16 texels and about 15 at 32x32, with half of each cell unused.
7. **Colour harmonisation.** Solve per-keyframe, per-channel log gains by weighted least squares on colour samples across chart seams (Jacobi iterations, Huber reweighting, mean gain 1, clamped). No Poisson blending in v1. Keep exifData so a metadata pre-normalisation can be added later.
8. **Bake on the GPU.** Decode keyframes (ImageIO plus `MTKTextureLoader.newTexture(cgImage:options:)`, no `.origin`) on 2 to 3 CPU threads ahead of the GPU. For each keyframe, one compute pass copies (with bilinear resample and gain) its chart rectangles into the pages, then the frame is released. Finish with a 2 to 4 px dilation pass per page. The YCbCr to RGB conversion uses Apple's matrix when working from raw planes.
9. **Output.** Split vertices per chart, keep UVs top-left internally, emit one part per page. Display with `LowLevelMesh` (attributes `.position`, `.normal`, `.uv0` as `.float2`, `v' = 1 - v`) and `LowLevelTexture` or `TextureResource(image:withName:options:)`, in a `ModelEntity` with `UnlitMaterial(texture:)` (camera colours already contain lighting). Exports: own OBJ plus MTL writer (`map_Kd atlas_N.jpg`, `v' = 1 - v`); own usda with UsdPreviewSurface and UsdUVTexture, then `MDLUtility.convert(toUSDZ:writeTo:)`, with a hand-written 64-byte-aligned stored-zip USDZ writer as the fallback.
10. **Budget.** Rough A15 estimate for 500k faces and 300 keyframes: view selection under 1 s, depth passes 0.5 to 1 s, JPEG decode about 6 s (dominant), packing 1 to 3 s, gain solve about 1 s, page encode 1 to 2 s. 15 to 30 s end to end, peak memory under 500 MB. These are estimates (ScanSpace reports 10 to 60 s on an iPhone 15 Pro with a CPU bake); measure in the first build.
11. **Runtime assertion.** Per keyframe, unproject a few LiDAR depth pixels to world and reproject; log an error if the round trip exceeds 0.5 px.
12. **Later.** `captureHighResolutionFrame` for object mode only, after the intrinsics question below is answered on device. The "SOLID COLOR" and "RAW MESH" view modes need no texturing; "TEXTURED" can fall back to per-vertex colours (weighted average of projections, seconds to compute but blurry at 3 to 8 cm vertex spacing) if the atlas bake fails.

#### Disputed or unsure

1. **RealityKit display API signatures (tie-breaker ruling: refuted as written, headline upheld).** Researcher listed `LowLevelMesh.replaceIndices(_ closure:)`, a sync `MeshResource(from:)` and `TextureResource(image:)` at iOS 13. Official-docs verifier: the closure `replaceIndices` does not exist, `MeshResource(from:)` is async and must be awaited, the CGImage init is iOS 18.0. Reality verifier: agreed on the first and third, but showed Apple's own LowLevelMesh sample and many compiling repos calling `try MeshResource(from:)` synchronously. Synthesis re-check of the doc JSON: `TextureResource(image:withName:options:)` has both an `async throws` and a sync `throws` overload (iOS 18.0), but both documented `MeshResource(from: LowLevelMesh)` pages are `async throws`; the sync mesh form rests only on sample and community code. Ruling: use `withUnsafeMutableIndices` / `replaceUnsafeMutableIndices` (CPU) or `replaceIndices(using:)` (GPU); always write `try await MeshResource(from: mesh)`; for textures either overload is fine. Avoid the deprecated `generate(from:withName:options:)`. SceneKit deprecation at 26.0 stands.
2. **ModelIO export and USDZ path (tie-breaker ruling: refuted as written).** Researcher: ModelIO cannot write usdz, USD export drops all materials, OBJ export writes Kd scalars, use SCNScene.write or a hand-rolled zip for USDZ. Verifier: omitted the official `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18.0, not deprecated, wraps Pixar's ARKit usdz packager); USD export keeps scalar UsdPreviewSurface inputs but drops URL texture properties; OBJ Kd is reported dropped or written as white; the cited forum thread is from 2018 and never tested usdz. The verifier has the stronger evidence (doc JSON plus SDK headers). Ruling: own usda, then MDLUtility, with the own stored-zip writer as fallback; do not rely on SCNScene.write; own OBJ plus MTL writer. Unproven: no third-party app was found calling MDLUtility on a device, so test once.
3. **RealityKit UV V-origin.** Community only (RealityGeometries issue #3, textures mirrored until UVs were flipped). Likely bottom-left. Ruling: flip `v` for RealityKit, OBJ and USD, and confirm with the numbered-atlas self-test.
4. **Frame pool numbers.** Researcher: warning above 10 retained frames, drops at 15 to 20, warning since iOS 15. Verifiers: the >10 warning is confirmed in the wild, but degradation was seen at 11 to 13 and the behaviour predates iOS 15. Ruling: 10 is the hard budget; design for zero.
5. **"Do not use `projectionMatrix` / `projectPoint` for texturing".** Reality verifier: with a viewport equal to `imageResolution` the aspect fill is a no-op, so they would give the same pixels; the rule is a preference, not a correctness issue. Ruling: keep the intrinsics formula (exact, version-independent, avoids deprecated overloads). Decide one half-pixel convention (`u / W` vs `(u + 0.5) / W`) and use it everywhere.
6. **Apple point-cloud sample provenance.** The quoted `worldPoint` / `flipYZ` code exists in the older Apple sample preserved by the cited mirror; the current Apple sample (Xcode 16) was rewritten with a different shader. The math is unchanged and matches the ARCamera docs. ScanSpace (0 stars, 7 commits) is weak evidence of correctness on device.
7. **Depth-must-be-private attribution.** The rule is real (Metal validation assertion), but it is not in the archived Best Practices Guide the researcher cited, and `.memoryless` is also legal. No practical change.
8. **Exact 1920x1440 default and per-frame intrinsic drift figures** (about 36 px fx, 2 px cx) are community-only; the forum threads returned 403. The design (per-keyframe K, runtime format check) does not depend on the numbers.
9. **Occlusion test choice.** Mesh depth pass (exact against the textured mesh) as primary and LiDAR depth as secondary is a researcher recommendation, not independently verified. The sign of the off-axis projection terms (`1 - 2ox/W`, `2oy/H - 1`) must be unit-tested on device against the forward formula. A debug build can also compare it with `projectionMatrix(for: .landscapeRight, viewportSize: imageResolution, zNear:zFar:)`, which the researcher says gives the same mapping (still compiles, deprecated only at iOS 27).
10. **Hi-res frame intrinsics.** Unknown whether `camera.intrinsics` is rescaled to 12 MP (forum thread from May 2026 has no reply). Safe rule: scale K by pixel-buffer size over `imageResolution` before projecting.
11. **Timing numbers** (JPEG encode 10 to 30 ms, decode 15 to 25 ms, 1 to 3 ms depth passes, 15 to 30 s total) are estimates with no published source. Measure in the first texturing build.

### 3.5 Rendering and viewer

Scope: the post-scan 3D viewer and editor (textured, solid, wireframe, vertex color and classification modes, picking, measuring, labeled object boxes) and the live LiDAR coverage overlay shown while scanning. Declarations below were checked against Apple's documentation JSON on the iOS 26 SDK, except where marked UNVERIFIED or community-only. Every API listed is usable at the iOS 18.0 deployment target unless marked otherwise. Nothing in this section needs iOS 26, so no `#available(iOS 26, *)` guards are required.

#### Verified API

##### Framework status

| API | Introduced (iOS) | Status on iOS 26 SDK | Usable at 18.0 |
|---|---|---|---|
| SceneKit (framework, `SCNView`, `SCNGeometry`, `SCNGeometrySource`, `SCNGeometryElement`, `SCNHitTestResult`, `SCNFillMode`, `SCNProgram`, `SCNTechnique`) | 8.0 | Deprecated 26.0 (soft, "maintenance mode") | Yes, but do not use |
| SwiftUI `SceneView` (`@MainActor @preconcurrency struct SceneView`) | 14.0 | Deprecated 26.0 | Yes, but do not use |
| `ARSCNView` | 11.0 | Deprecated 26.0, note "Use RealityView instead" | Yes, but do not use |
| RealityKit `ARView` (`@MainActor @objc @preconcurrency class ARView`) | 13.0 | Not deprecated | Yes |
| RealityKit `RealityView` (iOS form) | 18.0 | Not deprecated | Yes |
| RealityKit `LowLevelMesh` | 18.0 | Not deprecated | Yes |
| MetalKit `MTKView` | 9.0 | Not deprecated | Yes |

Apple's SceneKit deprecation note: "SceneKit is deprecated, use RealityKit instead." WWDC25 session 288: "This is a soft deprecation, meaning that existing applications that use SceneKit will continue to work". It also says "Apple will only fix critical bugs", "if you're planning a new app or a significant update, SceneKit is not recommended", and "there's no plan to hard deprecate SceneKit". Xcode 26 release notes confirm it. It still compiles with warnings.

##### ARView host (viewer in `.nonAR`, live scan in `.ar`)

```swift
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool) // iOS 13.0, use this one
@MainActor @preconcurrency convenience init(frame frameRect: CGRect, cameraMode: ARView.CameraMode) // iOS 13.0, DEPRECATED (unversioned), renamed to the 3-arg init
enum CameraMode { case ar; case nonAR }                                         // ARView.CameraMode, iOS 13.0
var scene: Scene { get }
dynamic var session: ARSession { get set }
var automaticallyConfigureSession: Bool { get set }
var cameraTransform: Transform { get }                                          // read-only
var debugOptions: ARView.DebugOptions
var environment: ARView.Environment
static func color(_ color: ARView.Environment.Color) -> ARView.Environment.Background   // on ARView.Environment.Background; Color = UIColor on iOS
static func cameraFeed(exposureCompensation: Float = 0.0) -> ARView.Environment.Background
@MainActor @preconcurrency func project(_ point: SIMD3<Float>) -> CGPoint?     // iOS 13.0
func unproject(_ point: CGPoint, viewport: CGRect) -> SIMD3<Float>?             // iOS 13.0
@MainActor @preconcurrency func ray(through screenPoint: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?  // iOS 13.0
@MainActor @preconcurrency func hitTest(_ point: CGPoint, query: CollisionCastQueryType = .all, mask: CollisionGroup = .all) -> [CollisionCastHit]  // iOS 13.0
func entity(at point: CGPoint) -> Entity?
func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]  // ARKit geometry, iOS only
@MainActor @preconcurrency func snapshot(saveToHDR: Bool, completion: @escaping (ARView.Image?) -> Void)  // iOS 13.0 overload
static let showSceneUnderstanding: ARView.DebugOptions                          // iOS 13.4
var sceneUnderstanding: ARView.Environment.SceneUnderstanding { mutating get set }   // member of ARView.Environment (arView.environment.sceneUnderstanding.options); options: .occlusion, .collision, .physics, .receivesLighting; iOS 13.4
```

##### RealityView host (alternative, all iOS 18.0)

```swift
nonisolated init(make: @escaping @MainActor @Sendable (inout RealityViewCameraContent) async -> Void,
                 update: (@MainActor (inout RealityViewCameraContent) -> Void)? = nil)
    where Content == RealityViewCameraContent.Body<RealityViewDefaultPlaceholder>   // plus init(make:update:placeholder:)
// RealityViewCameraContent: camera, cameraTarget: Entity?, entities, environment, audioListener, renderingEffects; add/remove via RealityViewContentProtocol
// RealityViewCamera: .virtual, .spatialTracking (.spatialTracking is iOS/iPadOS/Catalyst only)
@MainActor @preconcurrency func realityViewCameraControls(_ controls: CameraControls) -> some View   // SwiftUI View modifier
struct CameraControls   // static none, orbit, pan, tilt, dolly; Equatable, Hashable, Sendable; NOT an OptionSet
// RealityCoordinateSpaceProjecting (RealityViewCameraContent and EntityTargetValue conform), iOS 18.0:
func project(point: SIMD3<Float>, to space: some CoordinateSpaceProtocol) -> CGPoint?
func unproject(_ point: CGPoint, from space: some CoordinateSpaceProtocol, to realitySpace: some RealityCoordinateSpace, ontoPlane planeTransform: float4x4) -> SIMD3<Float>?
func ray(through point: CGPoint, in space: some CoordinateSpaceProtocol, to realitySpace: some RealityCoordinateSpace) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?
func hitTest(point: CGPoint, in space: some CoordinateSpaceProtocol, query: CollisionCastQueryType, mask: CollisionGroup) -> [CollisionCastHit]
func entity(at point: CGPoint, in space: some CoordinateSpaceProtocol) -> Entity?
@dynamicMemberLookup struct EntityTargetValue<Value>   // iOS 18.0, via Gesture.targetedToAnyEntity() + InputTargetComponent
```

Not on iOS: `RealityViewAttachments` and `init(make:update:attachments:)` (visionOS only), `RealityViewContent` (visionOS only), `RealityCoordinateSpaceConverting` (visionOS only).

##### LowLevelMesh (scan chunks; all iOS 18.0; the class and its methods are `@MainActor`, the nested Descriptor/Attribute/Layout/Part structs are not)

```swift
@MainActor class LowLevelMesh
@MainActor init(descriptor: LowLevelMesh.Descriptor) throws
// Descriptor: init(vertexCapacity: Int = 0, vertexAttributes: [LowLevelMesh.Attribute] = [Attribute](), vertexLayouts: [LowLevelMesh.Layout] = [Layout](), indexCapacity: Int = 0, indexType: MTLIndexType = MTLIndexType.uint32)
// Attribute: init(semantic: LowLevelMesh.VertexSemantic, format: MTLVertexFormat, layoutIndex: Int = 0, offset: Int)
// VertexSemantic: position, normal, tangent, bitangent, color, uv0 ... uv7, unspecified
// Layout: init(bufferIndex: Int, bufferOffset: Int = 0, bufferStride: Int)
// Part: init(indexOffset: Int = 0, indexCount: Int = 0, topology: MTLPrimitiveType = .triangle, materialIndex: Int = 0, bounds: BoundingBox)
var parts: LowLevelMesh.PartsCollection { get set }   // replaceAll(_:), append(_:), append(contentsOf:), removeAll()
@MainActor func withUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)
@MainActor func withUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)
// also: withUnsafeBytes(bufferIndex:_:), withUnsafeIndices(_:), replaceUnsafeMutableBytes/Indices, read(bufferIndex:using:), readIndices(using:)
@MainActor func replace(bufferIndex index: Int, using commandBuffer: any MTLCommandBuffer) -> any MTLBuffer   // GPU write path
@MainActor @preconcurrency convenience init(from mesh: LowLevelMesh) async throws   // MeshResource, iOS 18.0
var lowLevelMesh: LowLevelMesh? { get }                                              // MeshResource, iOS 18.0
```

NOT available at iOS 18 and will not compile on the iOS 26 SDK: `Descriptor.allowsPrimitiveRestart`, `instanceCapacity`, the 6-argument Descriptor init and `Layout.init(bufferIndex:bufferOffset:bufferStride:stepFunction:stepRate:)` (all iOS 27.0).

##### MeshDescriptor path (small static helpers only)

```swift
struct MeshDescriptor   // iOS 15.0: init(name:), primitives, materials; buffers via MeshBufferContainer: positions, normals, tangents, bitangents, textureCoordinates, textureCoordinates1..7, uv2..uv7; no color buffer
enum MeshDescriptor.Primitives { case triangles([UInt32]); case trianglesAndQuads(triangles: [UInt32], quads: [UInt32]); case polygons([UInt8], [UInt32]) }
enum MeshDescriptor.Materials { case allFaces(UInt32); case perFace([UInt32]) }        // iOS 15.0
@MainActor @preconcurrency static func generate(from content: MeshResource.Contents) throws -> MeshResource  // iOS 15.0 (documented)
// generate(from: [MeshDescriptor]) is UNVERIFIED: community code only; the MeshDescriptor overview mentions `generate(from:)-6l1q2` as plain code text, that path 404s, and MeshResource's topics list only the Contents overload
@MainActor @preconcurrency static func generateBox(size: SIMD3<Float>, cornerRadius: Float = 0) -> MeshResource   // iOS 13.0
@MainActor @preconcurrency static func generateText(_ string: String, extrusionDepth: Float = 0.25, font: MeshResource.Font = .systemFont(ofSize: defaultTextFontSize), containerFrame: CGRect = CGRect.zero, alignment: CTTextAlignment = .left, lineBreakMode: CTLineBreakMode = .byTruncatingTail) -> MeshResource
```

##### Materials and textures

| Declaration | iOS | Notes |
|---|---|---|
| `var triangleFillMode: UnlitMaterial.TriangleFillMode { get set }` (same on PhysicallyBasedMaterial, SimpleMaterial, CustomMaterial) | 18.0 | `enum MaterialParameterTypes.TriangleFillMode { case fill; case lines }`. Wireframe mode. Also on ShaderGraphMaterial and VideoMaterial. Not on OcclusionMaterial. |
| `var faceCulling: UnlitMaterial.FaceCulling { get set }` | 18.0 | SimpleMaterial version is also 18.0; PBR and Custom versions are 15.0. Cases front, back, none. |
| `var color: UnlitMaterial.BaseColor { get set }` | 15.0 | Use instead of deprecated `baseColor` / `tintColor`. |
| `init(texture: TextureResource)` (UnlitMaterial) | 18.0 | Textured atlas mode. |
| `var blending: UnlitMaterial.Blending` = `PhysicallyBasedMaterial.Blending`, `case transparent(opacity: PhysicallyBasedMaterial.Opacity)` | 15.0 | Semi-transparent coverage overlay. |
| `@MainActor @preconcurrency convenience init(image cgImage: CGImage, withName resourceName: String? = nil, options: TextureResource.CreateOptions) async throws`, plus a documented sync `throws` overload with the same parameters (doc slug `-1pzep`) | 18.0 | TextureResource from atlas CGImage. |
| `init(semantic: TextureResource.Semantic?, mipmapsMode: TextureResource.MipmapsMode = .allocateAndGenerateAll)` | 15.0 | CreateOptions; use `.color` for the atlas. |
| `init(surfaceShader: CustomMaterial.SurfaceShader, geometryModifier: CustomMaterial.GeometryModifier? = nil, lightingModel: CustomMaterial.LightingModel) throws` | 15.0 | No default for `lightingModel`. `LightingModel`: lit, clearcoat, unlit. Not on visionOS. |
| `init(materialXLabel: String, data: Data) async throws` (ShaderGraphMaterial) | 18.0 | Loads an inline MaterialX document, no Reality Composer Pro, no .metal file. Also `init(named:from:in:)`. An Occlusion Surface output fails to load on iOS 18 (`LoadError.invalidTypeFound`, forum 763404); PBR Surface loads. |

Metal side of CustomMaterial (from `#include <RealityKit/RealityKit.h>`): `[[visible]] void shader(realitykit::surface_parameters params)`, `params.geometry().color()` ("Returns the fragment's interpolated vertex color"), `uv0()`, `normal()`, `world_position()`, `params.surface().set_emissive_color(half3)`, `set_base_color(half3)`, `params.uniforms().custom_parameter()`. Under `.unlit` only `set_emissive_color()` is honoured. The shader must call at least one `set_*()` function or nothing renders. Library: `MTLCreateSystemDefaultDevice()!.makeDefaultLibrary()!`.

##### Picking, scene graph and camera

```swift
nonisolated static func generateStaticMesh(positions: [SIMD3<Float>], faceIndices: [UInt16]) async throws -> ShapeResource  // iOS 18.0, UInt16 indices
@MainActor @preconcurrency static func generateStaticMesh(from mesh: MeshResource) async throws -> ShapeResource           // iOS 18.0, no 65k limit
nonisolated static func generateStaticMesh(from meshAnchor: ARMeshAnchor) async throws -> ShapeResource                   // iOS 18.0 (iOS/iPadOS/Catalyst only), static shape straight from a live ARMeshAnchor
init(shapes: [ShapeResource], mode: CollisionComponent.Mode = .default, filter: CollisionFilter = .default)                // CollisionComponent, iOS 13.0
// CollisionComponent.init(shapes:isStatic:filter:) is iOS 18.0
@MainActor @preconcurrency func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float = 100, query: CollisionCastQueryType = .all, mask: CollisionGroup = .all, relativeTo referenceEntity: Entity? = nil) -> [CollisionCastHit]  // Scene, iOS 13.0
// also Scene.raycast(from:to:query:mask:relativeTo:), iOS 13.0; CollisionCastQueryType: nearest, all, any
// CollisionCastHit: entity, position, normal, distance, shapeIndex (iOS 18.0)
var triangleHit: CollisionCastHit.TriangleHit? { get }   // iOS 18.0; TriangleHit { faceIndex: Int; uv: SIMD2<Float> }
@MainActor @preconcurrency func pixelCast(from startPosition: SIMD3<Float>, to endPosition: SIMD3<Float>) async throws -> PixelCastHit?  // Scene, iOS 18.0
// also pixelCast(origin:direction:length: Float = 100); PixelCastHit (iOS 18.0): entity, position, normal, primitive: UInt32, meshPart: UInt64, instance: UInt32, barycentric: SIMD3<Float>?
@MainActor @preconcurrency var isEnabled: Bool { get set }                  // Entity, iOS 13.0
@MainActor @preconcurrency convenience init(anchor: ARAnchor)              // AnchorEntity, iOS 13.0
init(near: Float = 0.01, far: Float = .infinity, fieldOfViewInDegrees: Float = 60.0)   // PerspectiveCameraComponent, iOS 13.0
struct BillboardComponent                                                   // iOS 18.0, keeps text labels facing the camera
```

##### ARKit mesh input for the live overlay (see the ARKit mesh section for details)

`ARMeshAnchor.geometry: ARMeshGeometry` with `vertices`, `normals` (`ARGeometrySource`: buffer, count, format, stride, offset), `faces` (`ARGeometryElement`, Int32 triples, bytesPerIndex 4) and optional `classification` (one UInt8 per face, `ARMeshClassification` none, wall, floor, ceiling, table, seat, window, door). Enabled by `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification` after `supportsSceneReconstruction(_:)`. All iOS 13.4.

##### Metal escape hatch

`MTKView` (iOS 9.0), `MTKViewDelegate`, `MTLRenderCommandEncoder.setTriangleFillMode(_:)` with `MTLTriangleFillMode.lines`, `drawIndexedPrimitives(type:indexCount:indexType:indexBuffer:indexBufferOffset:)`. None deprecated.

#### Gotchas

- Do not build on SceneKit, `SceneView` or `ARSCNView`. They compile with warnings and run on iOS 18 and 26, but Apple has frozen them. Their conveniences (built-in orbit camera, `hitTest` with `faceIndex`, `.color` geometry source) are tempting only for throwaway prototypes. SceneKit also gets unresponsive at around 750 to 2,000 nodes on an iPad 10 (forum report).
- `ARView(frame:cameraMode:)` (2 arguments) is deprecated. Use the 3-argument init. Calling the old one only warns.
- `CameraControls` takes exactly one mode. Orbit plus two-finger pan plus pinch cannot be combined in RealityView (forum 774411, unanswered). You write your own gesture-to-camera code in either host.
- In RealityView the projection helpers live on the `content` value passed to `make`/`update`. Gesture code must keep a reference to it, or use `EntityTargetValue` in entity-targeted gestures. `hitTest` only sees entities with a `CollisionComponent`, and `unproject` returns nil when the view has no active camera.
- No fixed-function RealityKit material (Unlit, PBR, Simple) reads per-vertex color. `UnlitMaterial` and `PhysicallyBasedMaterial` render a LowLevelMesh `.color` attribute as white (Apple engineer, forum 759449). `MeshDescriptor` has no color buffer at all.
- Per-face colors (classification, coverage state) need no shader: sort indices into LowLevelMesh parts and give each part a `materialIndex` into the `ModelComponent.materials` array.
- CustomMaterial `.unlit` ignores `set_base_color()`; write `set_emissive_color()`. A surface shader that calls no `set_*()` renders nothing. `lightingModel` has no default argument.
- Apple's LowLevelMesh overview sample writes `LowLevelMesh.Descriptor()` and `try MeshResource(from:)` without `await`. Use the documented 5-argument Descriptor init (all arguments defaulted) and `try await`.
- `LowLevelMesh` capacities are fixed at creation. Over-allocate (about 1.5x) and recreate only when exceeded. All CPU write paths are `@MainActor`: build arrays off the main actor, then copy on main.
- `Descriptor.allowsPrimitiveRestart` and `instanceCapacity` are iOS 27.0. Referencing them breaks the CI build.
- `MeshResource(from: LowLevelMesh)` is documented as `async throws`; write `try await`. A second-pass verifier reports a sync overload too, but it has no doc page, so do not rely on it.
- `ShapeResource.generateStaticMesh(from:)` is async and slow ("can take a while"); build it in a low-priority Task after the chunk is visible. Only static physics bodies and `.default` collision mode are allowed. The `positions:faceIndices:` overload takes `[UInt16]`, so it only fits chunks of at most 65,535 vertices.
- `Scene.raycast` only hits entities with a `CollisionComponent`, and the ray must fully cross the triangle, so use a length slightly longer than needed. `pixelCast` needs no collision shape but is async.
- LiDAR triangles have inconsistent winding. Set `faceCulling = .none` on every scan material or parts of the mesh vanish. Note `UnlitMaterial.faceCulling` is iOS 18.0.
- Materials are structs. Declare with `var` before setting `triangleFillMode` or `faceCulling`. Wireframe line width is fixed at 1 pixel; use thin boxes if thicker edges are needed.
- `ARMeshAnchor` buffers belong to ARKit and are replaced on every update. Copy vertices, faces and classification inside the delegate callback before dispatching work.
- `.showSceneUnderstanding` is a fixed Apple debug coloring and cannot show coverage states. If `sceneUnderstanding.options` includes `.occlusion`, your overlay coincides with Apple's occlusion mesh and z-fights; scale the overlay slightly (about 1.002x) or disable occlusion while scanning.
- Deprecated spellings to avoid (they warn): `MeshResource.generateAsync` / `replaceAsync`, `TextureResource.generate(from:withName:options:)`, `generateAsync`, `loadAsync`, `UnlitMaterial.baseColor` / `tintColor`.
- Apple publishes no triangle budget for RealityKit (DTS, forum 751764: measure and iterate). The old 100k triangle QuickLook figure is a content guideline, not an engine limit. Regenerating a `MeshResource` from `MeshDescriptor` runs the mesh optimizer each time, so never do it per frame.
- One community app notes that CustomMaterial crashed when combined with AR video compositing (wisescan-ios comment). Keep CustomMaterial out of the live `.ar` overlay; it is only needed in the post-scan viewer.

#### Recommended approach

1. Viewer host: `ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)` in a `UIViewRepresentable`. Set `environment.background = .color(...)`. Add a `PerspectiveCamera` under `AnchorEntity(world: .zero)` and drive it from your own UIKit pan, two-finger pan and pinch recognizers (yaw, pitch, distance around a target point). ARView gives `project(_:)` for SwiftUI label overlays, `ray(through:)`, `hitTest`, `snapshot` and `debugOptions`. RealityView is an acceptable alternative if a pure SwiftUI host is preferred, but it saves nothing on gestures.
2. Live scan host: the same ARView class in `.ar` mode, `automaticallyConfigureSession = false`, your own `ARWorldTrackingConfiguration` with `.meshWithClassification`, and an `ARSessionDelegate` on `arView.session`.
3. Data model: one Entity per chunk (post-scan) or per `ARMeshAnchor` (live), each with a `LowLevelMesh`. Interleaved vertex: position `.float3`, normal `.float3`, uv0 `.float2`, color `.uchar4Normalized_bgra`; `UInt32` indices. Keep this layout identical to what a future MTKView renderer and the exporters would read.
4. View modes by swapping `ModelComponent.materials`, all with `faceCulling = .none`:
   - Textured: `UnlitMaterial(texture:)` from `try await TextureResource(image:withName:options:)` (use the `async throws` overload from async code; a sync `throws` overload also exists) with semantic `.color`.
   - Solid: `UnlitMaterial` with `color` set (or `PhysicallyBasedMaterial` for a lit look).
   - Wireframe: the same material with `triangleFillMode = .lines`.
   - Classification and coverage: parts split by class or state, one `UnlitMaterial` per color.
   - Vertex color: first try `ShaderGraphMaterial(materialXLabel:data:)` with an inline MaterialX document (geometry color into the RealityKit unlit surface); fallback `CustomMaterial(surfaceShader:geometryModifier:lightingModel: .unlit)` with a .metal shader writing `set_emissive_color(params.geometry().color().rgb)`; last fallback per-face parts.
5. Visibility: toggle chunks with `isEnabled` (by frustum, by room, by layer). Keep chunk count in the low hundreds.
6. Picking and measuring: after display, build a `CollisionComponent` per chunk from `ShapeResource.generateStaticMesh(from:)` in `Task(priority: .low)`. Tap goes to `arView.ray(through:)`, then `arView.scene.raycast(origin:direction:length:query: .nearest)`, giving `position` and `triangleHit?.faceIndex`. Use one static-mesh shape per chunk entity so `faceIndex` maps to that chunk's triangle order. Before shapes are ready, use `try await scene.pixelCast(from:to:)` as a per-tap fallback. Distance is `simd_distance(a.position, b.position)`; format it with `ios/Sources/Units/`. Draw segments with a `Part(topology: .line)` or a thin `generateBox`; place labels with `arView.project(midpoint)` in a SwiftUI overlay.
7. Object boxes: `MeshResource.generateBox(size:cornerRadius:)` plus `UnlitMaterial` with `triangleFillMode = .lines`, a label via `BillboardComponent` text or a projected SwiftUI label, all under one parent Entity so they toggle together.
8. Live coverage overlay: per anchor, copy buffers in the callback, compute per-face state, write indices sorted into 4 parts (green, yellow, red, gray) with 4 semi-transparent `UnlitMaterial`s (`blending = .transparent(opacity:)`). Coalesce anchors in a dirty set flushed every 0.25 to 0.5 s on the main actor, skip anchors outside the frustum, reallocate only when faces exceed capacity. Use `.showSceneUnderstanding` only as a debug toggle.
9. Escape hatch: if RealityKit is too slow at about 1M triangles on the A15, move the same chunk buffers to an `MTKView` renderer (`setTriangleFillMode(.lines)`, GPU id buffer or CPU BVH picking). Do not start there.
10. First CI spike: ARView `.nonAR` plus PerspectiveCamera, one LowLevelMesh chunk with a `.color` attribute, a `.lines` material, a ShaderGraphMaterial and a CustomMaterial reading vertex color, `generateStaticMesh(from:)` plus raycast logging `triangleHit?.faceIndex`, and one `pixelCast`. Log results through LogStore and check on the device.

#### Disputed or unsure

1. RealityView on iOS lacks projection and raycast helpers. Researcher: yes, so ARView is required. Both verifiers: false, `RealityViewCameraContent` conforms to `RealityCoordinateSpaceProjecting` (iOS 18.0) with project, unproject, ray, hitTest and entity(at:in:). Verifiers have stronger evidence (direct doc JSON, re-fetched here). Tie-breaker: upheld the verifiers. Final ruling: refuted. RealityView is a viable host. The case for ARView rests on custom UIKit gesture control, ARSession access, `raycast(from:allowing:alignment:)` against ARKit geometry, `snapshot`, `debugOptions` and `installGestures(_:for:)`. RealityView on iOS still lacks attachments.
2. `ARView(frame:cameraMode:)` is deprecated. Researcher: yes. Reality verifier: no, `deprecatedAt` is null. Tie-breaker: the doc JSON has `deprecated=true` with `renamed` pointing to the 3-argument init, which is how DocC encodes an unversioned deprecation. Re-checked here: `deprecated: True`. Final ruling: deprecated, use the 3-argument init.
3. Vertex color display needs CustomMaterial because ShaderGraphMaterial is visionOS-only. Researcher: yes. Both verifiers: false, `ShaderGraphMaterial` and `init(materialXLabel:data:)` are iOS 18.0, and the Geometry Color node is iOS 17.0. Forum 763404 shows ShaderGraphMaterial loading on iOS 18. Verifiers have stronger, current evidence; the researcher's source dates from 2023. Tie-breaker: upheld the verifiers. Final ruling: refuted; two paths exist, ShaderGraphMaterial first, CustomMaterial fallback.
4. Whether either path actually renders a LowLevelMesh `.color` attribute on iOS. No compiled iOS sample exists; the Apple engineer confirmation is on visionOS and the Metal PDF predates LowLevelMesh. Final ruling: unsure, needs a device test; keep the per-face fallback.
5. `MeshResource(from: LowLevelMesh)` sync or async. Researcher: async only (doc). Reality verifier: a sync `throws` overload also exists. Its evidence is community code calling it without `await` (wisescan-ios, PointNMap) and a reverse-engineered interface mirror; the doc slug `init(from:)-8x3s2` returns 404. No tie-breaker. The async form has the stronger evidence because it is the only one with a doc page. Final ruling: `try await` is documented and safe; treat the sync form as unconfirmed.
6. `CustomMaterial.init(surfaceShader:geometryModifier:lightingModel:)` default for `lightingModel`. Researcher wrote `= .lit`. Verifier and doc JSON (re-fetched): no default. Final ruling: pass it explicitly.
7. `MeshResource.generate(from: [MeshDescriptor])` still exists. Only community code and a plain-text mention (`generate(from:)-6l1q2`, which 404s) in the MeshDescriptor overview suggest it; MeshResource's documented topics list only `generate(from: MeshResource.Contents)`. Verify answer: likely present, because every community sample (markhorgan.com, stepinto.vision, maxxfrazer) calls `try MeshResource.generate(from: [descriptor])`. That evidence is real but may predate the iOS 26 SDK. Final ruling: unverified in the docs; prefer LowLevelMesh anyway and confirm with one compile if used.
8. `PixelCastHit.primitive` is the triangle index within `meshPart`. Apple only says "per-primitive identifier used with barycentric coordinates". No real-world iOS code calls `pixelCast`. Final ruling: plausible but unverified; use the collision raycast as the primary path.
9. `triangleHit.faceIndex` with several shapes in one CollisionComponent. Docs are silent; visionOS samples show it indexes the face list of the hit shape. Final ruling: use one shape per chunk and verify on device.
10. Minor corrections accepted without dispute: SwiftUI `SceneView` is iOS 14.0 (not 8.0); the ARSCNView note reads "Use RealityView instead"; `CollisionComponent.init(shapes:isStatic:filter:)` is iOS 18.0; `PerspectiveCameraComponent` default field of view is 60.0; `UnlitMaterial.faceCulling` is iOS 18.0.
11. Forum 825543 reports that changing `cameraTarget` during an active orbit drag gives a wrong orbit. The verifier could not fetch it (HTTP 403), so it is unverified. It only matters if RealityView camera controls are used.
12. Frame rate at about 1M triangles in 200 to 400 LowLevelMesh entities on the A15, and whether the iOS 26 RealityKit renderer changes CustomMaterial or `triangleFillMode` behavior: no public data. Needs device tests on both phones.

### 3.6 Floor plan and CAD output

Scope: turn RoomPlan output (CapturedRoom, CapturedStructure) into an editable 2D architectural plan with units, dimensions and symbols, then export it as vector PDF, SVG and DXF. Covers single room, multi-room and multi-floor. Everything below works at iOS 17.0 or earlier, so it is usable at our iOS 18.0 target. Nothing here needs iOS 26 or `#available`.

#### Verified API

Declarations were checked against Apple's documentation JSON (iOS 26 SDK era). None of the RoomPlan members below is deprecated.

**RoomPlan data we draw from**

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `struct CapturedRoom` (Codable, Sendable) | 16.0 | Yes |
| `var walls / doors / windows / openings: [CapturedRoom.Surface]` | 16.0 | Yes |
| `var objects: [CapturedRoom.Object]` | 16.0 | Yes |
| `var floors: [CapturedRoom.Surface] { get }` | 17.0 | Yes |
| `var sections: [CapturedRoom.Section]` | 17.0 | Yes |
| `var story: Int { get }` (on CapturedRoom, Surface, Object, Section) | 17.0 | Yes |
| `var identifier: UUID { get }`, `var version: Int { get }` | 16.0 / 17.0 | Yes |

```swift
// CapturedRoom.Surface (walls, doors, windows, openings and floors all use this type)
var identifier: UUID { get }
var parentIdentifier: UUID? { get }                 // iOS 17.0
var category: CapturedRoom.Surface.Category { get }
var confidence: CapturedRoom.Confidence { get }     // .high, .medium, .low
var transform: simd_float4x4 { get }                // iOS 16.0
var dimensions: simd_float3 { get }                 // iOS 16.0, "A bounding box that contains the surface"
var story: Int { get }                              // iOS 17.0
var completedEdges: Set<CapturedRoom.Surface.Edge> { get }   // Edge: .top, .bottom, .left, .right
var curve: CapturedRoom.Surface.Curve? { get }
var polygonCorners: [simd_float3] { get }           // iOS 17.0, "in local plane coordinates"

enum CapturedRoom.Surface.Category { case floor; case door(isOpen: Bool); case opening; case wall; case window }   // .floor is iOS 17.0, the rest 16.0

// CapturedRoom.Surface.Curve (struct iOS 16.0)
var startAngle: Measurement<UnitAngle> { get }      // iOS 16.0
var endAngle: Measurement<UnitAngle> { get }        // iOS 16.0
var radius: Float { get }                           // iOS 16.0
var center: simd_float2 { get }                     // iOS 17.0, local xz center

// CapturedRoom.Section (iOS 17.0)
var label: CapturedRoom.Section.Label { get }       // .livingRoom, .kitchen, .diningRoom, .bedroom, .bathroom, .unidentified
var center: simd_float3 { get }
var story: Int { get }

// CapturedRoom.Object
var identifier: UUID; var parentIdentifier: UUID?   // parent iOS 17.0
var category: CapturedRoom.Object.Category          // bathtub, bed, chair, dishwasher, fireplace, oven, refrigerator,
                                                    // sink, sofa, stairs, storage, stove, table, television, toilet, washerDryer
var transform: simd_float4x4; var dimensions: simd_float3
var attributes: [any CapturedRoomAttribute] { get } // iOS 17.0, furniture only (chair, sofa, storage, table types)
```

Surface has no `attributes` member. Only Object has it. No CapturedRoomAttribute type describes doors.

**Multi-room merge**

```swift
class StructureBuilder                                                  // iOS 17.0
init(options: StructureBuilder.ConfigurationOptions)                    // pass [.beautifyObjects] or []
// StructureBuilder.ConfigurationOptions is a typealias of RoomBuilder.ConfigurationOptions (OptionSet, iOS 16.0)
func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure   // iOS 17.0
enum StructureBuilder.BuildError { case deviceNotSupported, exceedSceneSizeLimit, insufficientInput,
                                   internalError, invalidInput, invalidRoomLocation }

struct CapturedStructure                                                // iOS 17.0, Codable, Sendable
var rooms: [CapturedRoom] { get }
var walls, doors, windows, openings, floors: [CapturedStructure.Surface]   // typealias of CapturedRoom.Surface
var objects: [CapturedStructure.Object]; var sections: [CapturedStructure.Section]
func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedStructure.ModelProvider? = nil,
            exportOptions: CapturedStructure.USDExportOptions = .mesh) throws

// Session continuity (RoomCaptureSession)
init(arSession: ARSession? = nil)                                       // iOS 17.0
func stop(pauseARSession: Bool = true)                                  // iOS 17.0
```

USDZ export options (`.parametric`, `.mesh`, `.model` with ModelProvider, iOS 16/17) are covered in the 3D export section. The `.parametric` output is a candidate for the "clean architectural model".

**Drawing, gestures, units** (SwiftUI, Foundation)

| Declaration | iOS | Notes |
|---|---|---|
| `struct Canvas<Symbols> where Symbols : View` | 15.0 | Immediate-mode renderer |
| `func withCGContext(content: (CGContext) throws -> Void) rethrows` (GraphicsContext) | 15.0 | Lets screen and PDF share one Core Graphics routine |
| `func stroke(_ path: Path, with shading: GraphicsContext.Shading, lineWidth: CGFloat = 1)` | 15.0 | |
| `func fill(_ path: Path, with shading: GraphicsContext.Shading, style: FillStyle = FillStyle())` | 15.0 | |
| `init(minimumDistance: CGFloat = 10, coordinateSpace: some CoordinateSpaceProtocol = .local)` (DragGesture) | 17.0 | Marked `@MainActor @preconcurrency` |
| `init(count: Int = 1, coordinateSpace: some CoordinateSpaceProtocol = .local)` (SpatialTapGesture) | 17.0 | Type itself is iOS 16.0 |
| `init(minimumScaleDelta: CGFloat = 0.01)` (MagnifyGesture) | 17.0 | Replaces MagnificationGesture |
| `init(minimumAngleDelta: Angle = .degrees(1))` (RotateGesture) | 17.0 | Replaces RotationGesture |
| `init(width: Measurement<UnitType>.FormatStyle.UnitWidth, locale: Locale = .autoupdatingCurrent, usage: MeasurementFormatUnitUsage<UnitType> = .general, numberFormatStyle: FloatingPointFormatStyle<Double>? = nil)` | 15.0 | No fractional-inch option |
| `var measurementSystem: Locale.MeasurementSystem { get }` | 16.0 | `.metric`, `.us`, `.uk` |

`MagnificationGesture` and `RotationGesture` (iOS 13) are marked deprecated at 27.2 in the doc JSON, as are the older `CoordinateSpace`-typed initializers of DragGesture (iOS 13) and SpatialTapGesture (iOS 16). They still compile on the iOS 26 SDK, but use MagnifyGesture, RotateGesture and the `some CoordinateSpaceProtocol` initializers. MagnifyGesture, RotateGesture and SpatialTapGesture are `nonisolated`; only DragGesture is `@MainActor @preconcurrency`. A second Measurement.FormatStyle initializer adds `hidesScaleName: Bool = false` (and defaults `width` to `.abbreviated`); neither has a fractional-inch option.

**PDF, sharing, file types**

| Declaration | iOS | Notes |
|---|---|---|
| `init(bounds: CGRect, format: UIGraphicsPDFRendererFormat)` | 10.0 | UIGraphicsPDFRenderer |
| `func writePDF(to url: URL, withActions actions: (UIGraphicsPDFRendererContext) -> Void) throws` | 10.0 | Multi-page vector PDF |
| `func beginPage()` (UIGraphicsPDFRendererContext) | 10.0 | Also `beginPage(withBounds:pageInfo:)`, `cgContext` |
| `var documentInfo: [String : Any] { get set }` (UIGraphicsPDFRendererFormat) | 10.0 | Title, author, creator keys |
| `init?(consumer: CGDataConsumer, mediaBox: UnsafePointer<CGRect>?, _ auxiliaryInfo: CFDictionary?)` (CGContext) | 2.0 | Alternative PDF path, y-up |
| `final class ImageRenderer<Content> where Content : View` | 16.0 | `render(rasterizationScale: CGFloat = 1, renderer:)` is `@MainActor` |
| `static var pdf: UTType { get }`, `static var svg: UTType { get }` | 14.0 | |
| `init?(filenameExtension: String, conformingTo supertype: UTType = .data)` | 14.0 | For `.dxf` (no system type) |
| `struct ShareLink<Data, PreviewImage, PreviewIcon, Label>` | 16.0 | Share file URLs |
| `func fileExporter<T>(isPresented: Binding<Bool>, item: T?, contentTypes: [UTType] = [], defaultFilename: String? = nil, onCompletion: @escaping (Result<URL, any Error>) -> Void, onCancellation: @escaping () -> Void = { }) -> some View where T : Transferable` | 17.0 | Preferred exporter |
| `func fileExporter<D>(isPresented:document:contentType:defaultFilename:onCompletion:) ... where D : FileDocument` | 14.0 | Deprecated at 27.2, avoid |

There is no Apple API that writes SVG or DXF. Both are hand-written text.

**Geometry conventions (verified on a real encoded CapturedRoom, not in Apple docs)**

- World is ARKit right-handed, Y up (ARKit `.gravity` alignment doc). Plan coordinates are world (x, z) with Y dropped.
- Walls, doors, windows, openings: `columns.3` = center, `columns.0` = along the wall (horizontal), `columns.1` = world up (0, 1, 0), `columns.2` = normal. `dimensions.x` = length, `dimensions.y` = height, `dimensions.z` = 0 exactly.
- Wall endpoints = `transform * SIMD4(±dimensions.x / 2, 0, 0, 1)`. In the sample these chain into shared corners within about 1 cm.
- Floors use a different local frame: `columns.2` = world up, `dimensions` = (width, depth, 0), and `polygonCorners` are local (x, y, 0).
- Rectangular walls have `polygonCorners == []`. Only non-uniform walls carry corners.
- All lengths are meters.

#### Gotchas

- `polygonCorners` are local to the surface plane. Always multiply by the full 4x4 transform, then drop world Y. Do not use Euler angles on floors: with local Z mapped to world up, the common Euler extraction hits gimbal lock and yaw looks like 0.
- The floor polygon is not a reliable room outline. In a real L-shaped, multi-section capture the single floor polygon was the 4-corner bounding rectangle and overstated area by about 13 percent. That sample had one floor per CapturedRoom, not one per section.
- `floors` can be empty (iOS 16 era data, or a very short scan). Build the outline from the wall loop, which does not need it.
- The sign of `columns.0` varies from wall to wall. Derive wall winding and the "room side" normal from connectivity (the closed wall loop), not from column signs.
- Interior partitions come back as separate single-plane walls, including short stubs (0.30 m and 0.45 m in the real sample). A community write-up (it-jim blog) also reports that walls thicker than about 50 cm are split into two thin walls. Wall-loop building must tolerate stubs and parallel face pairs.
- Wall `dimensions.x` over- or undershoots at corners. For a clean plan, intersect adjacent wall lines (when not near parallel) instead of trusting raw endpoints.
- Curved walls: when `curve != nil` the wall is an arc (center in local xz, radius, start and end angle as `Measurement<UnitAngle>`). A straight segment from `±dimensions.x / 2` is wrong for these.
- Door and window endpoints can sit slightly off the parent wall line. Project them onto the parent wall segment found through `parentIdentifier` and clamp to the wall length. `parentIdentifier` is optional, so handle nil (fall back to the nearest parallel wall).
- Sill and head heights are relative to the floor Y (`center.y ± dimensions.y / 2` minus floor y), not to world 0.
- RoomPlan has no wall thickness, no door hinge side, no swing direction, no door type (sliding, pocket), no stair direction and only 5 room labels. `door(isOpen:)` only says whether the door was open during the scan. The iOS 26 doc JSON adds nothing here.
- Wall `dimensions.y` may be the scanned height, not the true ceiling, if the scan missed the top. Prefer walls with `.high` confidence.
- StructureBuilder does not detect rooms scanned in unrelated coordinate frames. They merge silently and end up stacked on top of each other. `invalidRoomLocation` ("one or more rooms reside in a different vicinity") only seems to catch rooms that are far apart.
- After merging, room and floor identifiers are regenerated and rooms can be moved to fit the world space. Wall, door, window, opening and object identifiers are kept (developer reports).
- `exceedSceneSizeLimit` exists, but Apple publishes no limit. WWDC23 positions multi-room for single-floor homes up to about 186 m2.
- `story` assignment is undocumented. In Apple's own sample house all 10 rooms have story 0. Treat it as a hint.
- Y-axis direction: SwiftUI Canvas and UIGraphicsPDFRenderer are y-down, a raw `CGContext(consumer:mediaBox:_:)` PDF is y-up. Mixing them without a flip mirrors the plan. Also `Path.addArc(clockwise:)` looks inverted in y-down space. Test door arcs and handedness on device with an L-shaped room.
- `GraphicsContext.draw(Text)` scales with the context transform. Draw labels in screen space after converting points, or text grows with zoom.
- Canvas has no per-element hit testing. Hit-test in model space (distance from touch to segment).
- GraphicsContext is a value type. Copy it before clipping or transforming a sub-drawing.
- DXF: `$INSUNITS` is an R2000+ header variable, not R12. Numbers must use a "." decimal separator (use `Locale(identifier: "en_US_POSIX")` or a POSIX-safe formatter).
- `ImageRenderer` PDF output keeps SwiftUI-drawn shapes and text as vectors, but views composited by Core Animation become a placeholder image. Draw the plan directly in Core Graphics.

#### Recommended approach

1. **Own plan model.** Build a pure-Swift value-type `PlanModel` in meters, plan XY = world (x, z). Derive it once from CapturedRoom or CapturedStructure and never mutate RoomPlan types. Suggested shape:
   - Room: id, name, outline polygon, level id, rigid 2D alignment (translation + yaw).
   - Wall: id, p0, p1, thickness, thickness source (estimated, measured, user), height, optional arc.
   - Opening: id, wall id, kind (door with hinge end and swing side, window, opening), offset along wall, width, sill, head.
   - Fixture: id, category, center, size, yaw.
   Store the encoded CapturedRoom and CapturedStructure JSON beside it (both are Codable) so the plan can be re-derived. Store user edits keyed by the kept surface identifiers.
2. **Geometry pipeline.**
   - Wall segments from `transform * (±w/2, 0, 0, 1)`. Guard: if `abs(columns.1.y) < 0.99`, log it and use the horizontal projection of `columns.0`.
   - Room outline = closed wall loop (snap endpoints, intersect adjacent lines). Area by shoelace, perimeter by edge sum. Use the floor polygon (transformed, Y dropped) only as a fallback and cross-check, and flag a large mismatch.
   - Openings: project child endpoints onto the parent wall.
   - Arcs from `Surface.curve`.
   - Wall area = length x height minus child openings. Ceiling height = median height of high-confidence walls, or max minus min corner Y for walls with polygonCorners.
3. **Wall thickness.** Default 115 mm interior and 150 mm exterior, flagged "estimated". In a CapturedStructure, pair antiparallel walls (normal dot product below -0.95) from different rooms that overlap in plan and sit 0.05 to 0.5 m apart. Use the plane distance and flag it "measured". Keep the room-side face as the true face and offset thickness outward so room areas do not change. Thickness is always user-editable (SPEC: "change wall thickness").
4. **Door swing default** (editable, SPEC says "door swing direction when known"). Hinge at the door end nearer the closest wall corner. Swing into the room whose outline contains door center + normal x 0.3 m. Until the user confirms, the swing is a guess. Mark it as such in the UI and in exports.
5. **One renderer.** Write `PlanRenderer.draw(model, into: CGContext, scale:, style:)` in Core Graphics. Call it from Canvas through `withCGContext` for the screen and from `UIGraphicsPDFRenderer.writePDF` for export. SVG and DXF are separate string writers over the same PlanModel. Layer toggles from SPEC (furniture, measurements, room names, doors/windows, fixtures, grid, scale) are renderer style flags.
6. **Symbols and line weights.** Walls heaviest (filled polygons), fixtures medium, dimensions and annotations lightest. Door = gap + leaf line + quarter-circle arc with radius = leaf width. Window = wall outline with thin parallel lines across the gap. Opening = gap with a dashed line. Dimension strings = thin line offset 0.6 to 1 m from the wall face, extension lines, 45 degree ticks, text above; overall string outside the room string. Room tag = uppercase name with area below. Stairs = treads at about 280 mm, arrow with UP or DN (direction user-set). North arrow and graphic scale bar.
7. **Units.** Keep meters internally. Use the existing `ios/Sources/Units/` module (`LengthFormat.feetInches`, `LengthFormat.metric`, `AreaFormat`) for all plan text, as CLAUDE.md requires. Foundation's `Measurement.FormatStyle` cannot produce `12' 7 3/8"`. Default system from `Locale.current.measurementSystem`, user override in settings.
8. **PDF.** Pick sheet (Letter 612x792 pt, Tabloid 792x1224, A4 595x842, A3 842x1191) and scale (1/4" = 1', 1/8" = 1', 1:50, 1:100) automatically to fit inside margins. Points per meter = 39.3701 x 72 / scale denominator (59.055 at 1:48). One page per level, plus title block, scale text, scale bar, north arrow and a room schedule (name, area, ceiling height). Set title and creator in `documentInfo`.
9. **SVG.** `<svg xmlns="http://www.w3.org/2000/svg" width="..mm" height="..mm" viewBox="0 0 W H">` with 1 user unit = 1 mm. Group layers with `<g id="walls">` and so on. Doors as `<path d="M.. A r r 0 0 1 ..">`, text as `<text>`.
10. **DXF.** Hand-write DXF R12 (`$ACADVER` = `AC1009`): HEADER + ENTITIES only, no TABLES, no handles. Entities: LINE, ARC (CCW, degrees), CIRCLE, TEXT, POLYLINE + VERTEX + SEQEND, on layers A-WALL, A-DOOR, A-GLAZ, A-FLOR-IDEN, A-ANNO-DIMS. Coordinates in millimeters. Also write `$INSUNITS` = 4 (LibreCAD and ezdxf read it), put a "Units: millimeters" TEXT note on the drawing, and name the file with a `_mm` suffix, because an R12 reader may ignore `$INSUNITS`. Draw dimensions as LINE + TEXT, never DIMENSION entities (they need DIMSTYLE tables). An R2000 variant is optional later; if built, every LWPOLYLINE needs `100/AcDbEntity` and `100/AcDbPolyline` subclass markers. About 150 lines of String building.
11. **Sharing.** Write exports to `Documents/Exports` (file sharing is already on in `project.yml`) and hand URLs to `ShareLink`, or use the Transferable `fileExporter` (iOS 17). For DXF use `UTType(filenameExtension: "dxf")`, or declare an exported type in Info.plist for a proper icon.
12. **Editing UX.** Model-space hit test (segment distance under 12 pt / scale). SpatialTapGesture selects. DragGesture on a wall moves it along its normal and keeps neighbours joined. Endpoint handles snap to endpoints within 50 mm, to 0/45/90 degrees and to a 100 mm or 1 in grid. Pan with DragGesture, zoom with MagnifyGesture about its anchor. PlanModel is a struct, so undo is a history stack of values.
13. **Multi-room capture and merge.** Keep one ARSession across rooms: `stop(pauseARSession: false)`, then the next RoomCaptureSession on the same `arSession`. For resume across launches, save an ARWorldMap, relocalize with `initialWorldMap`, and wait for tracking to go from relocalizing to normal before the next room. Also watch `ARFrame.worldMappingStatus` (`var worldMappingStatus: ARFrame.WorldMappingStatus { get }`, iOS 12.0) before saving a map. The app must enforce frame continuity itself, since the builder will not. Apple's MergingMultipleScansIntoASingleStructure sample does not help here: it only decodes saved rooms, merges with `StructureBuilder(options: [.beautifyObjects])` and exports, with no capture or alignment code. Keep our own copy of input rooms and match merged output back by kept surface identifiers or centroids. If merge throws, or the rooms were not in one frame, load rooms as independent plan rooms and offer an "Arrange rooms" mode (drag, RotateGesture, parallel-wall snapping with gap = thickness, shared-door snapping).
14. **Multi-floor.** RoomPlan has no level, stair-link or floor-height API. Group rooms by floor world Y (cluster gap about 1.2 m), using `story` only as a hint. Let the user rename and reorder levels. Align levels by the stairs footprint (`Object.Category.stairs`) and exterior walls, user-adjustable. One plan page per level, with UP on the lower level and DN at the same plan XY above.
15. **Testing without a Mac.** Encode a real CapturedRoom on the test device, pull it over USB, and add it as a JSON fixture. Unit-test geometry, SVG and DXF writers in CI (`xcodebuild test` on the macOS runner), and validate DXF output with an `ezdxf` audit in a CI Python step. This catches axis and winding bugs without a device round trip.

#### Disputed or unsure

1. **Floor polygon as the area source.**
   Claim: `floors[].polygonCorners` is the correct source for room area and perimeter.
   Researcher: yes, citing the doc and the WWDC23 "beautified as a polygon" quote.
   Verifiers: the docs-lens verifier upheld the local-coordinates part but noted "correct source for area" is our inference, not Apple's. The reality-lens verifier refuted it: in a real encoded capture (openPlan3D sample) the floor polygon was the bounding rectangle of an L-shaped scan, 13 percent too large.
   Stronger evidence: the verifier's, because it is real data against an unstated inference. The sample's iOS version is unknown, so polygons may be better on some captures.
   Ruling: area and perimeter come from the closed wall loop. The floor polygon is a fallback and cross-check only.

2. **"Otherwise StructureBuilder throws."**
   Claim: rooms not in a shared frame make `capturedStructure(from:)` throw.
   Researcher: yes. Docs-lens verifier: not refuted, but added precision notes.
   Reality-lens verifier: refuted. Forum thread 733945 (an app that made a new ARSession per scan) shows rooms from separate sessions merged with no error, stacked on each other. No BuildError case covers a frame mismatch.
   Stronger evidence: the reality verifier (a concrete developer report, and the BuildError list has no such case).
   Ruling: the app must guarantee a shared frame itself and must not rely on an error. Confidence "likely", since it rests on one forum report. Apple Developer Forums returned HTTP 403 to the researcher, so some forum details came from search summaries.

3. **DXF R12 details.**
   Claim: an R12 file can carry `$INSUNITS`, and R2000 LWPOLYLINE needs subclass markers and handles.
   Docs-lens verifier: refuted two parts. `$INSUNITS` is an R2000+ variable (ezdxf defines it with mindxf = DXF2000 and drops it when saving R12). Handles are not required by ezdxf; only the missing `AcDbPolyline` marker triggers rejection.
   Reality-lens verifier: same corrections as minor notes. LibreCAD's libdxfrw also accepted an R2000 LWPOLYLINE without markers, so strictness varies by importer.
   Stronger evidence: the verifiers (local ezdxf 1.4.4 and libdxfrw tests plus ezdxf source).
   Ruling: R12 with mm coordinates, `$INSUNITS` written as a hint only, units stated in a TEXT note and the filename. AutoCAD's acceptance of a handle-less R2000 file is untested.

4. **Wall axis convention.**
   Claim: `columns.0` along the wall, `columns.1` up, endpoints at `±dimensions.x / 2`.
   Docs-lens: not in Apple docs, cannot be confirmed from them, nothing contradicts it. Reality-lens: confirmed on all 20 walls, 4 doors and 4 windows of a real capture, with two caveats (floors use a different frame, `columns.0` sign varies).
   Stronger evidence: the reality verifier's real data, because the docs are silent rather than contradictory. It is one sample, so confidence is "likely".
   Ruling: accepted, with the `columns.1.y` guard and connectivity-based winding. Still confirm on our own device scan.

5. **Door data.** Claim that only `door(isOpen:)` exists and there is no hinge, swing or door type. Both verifiers upheld it. Docs do not name doors or openings explicitly as having a `parentIdentifier` parent (only windows), but the real sample shows it for doors too. Ruling: accepted, handle nil parent.

6. **Wall thickness.** Claim that RoomPlan has no thickness. Both verifiers upheld it. `dimensions.z` = 0 is not written in docs but was exactly 0 for every surface in real data. Ruling: accepted.

7. **Foundation feet-inches.** Claim that Foundation cannot output fractional inches. Upheld. Small imprecisions: options also include `numberFormatStyle`, and `LengthFormatter.isForPersonHeightUse` is a second person-height path. The "whole inches" detail of `.personHeight` is unverified. Ruling: accepted; use our own Units module.

8. **ImageRenderer "rasterizes".** Verifier refinement: PDF output keeps text, shapes and fills as vectors, while Core Animation-composited views become a placeholder image. Ruling: the advice stands, draw directly into the CGContext.

9. **Unsure, to check on device:** local axes of `polygonCorners` for non-uniform walls (likely (x, y, 0), no real sample seen); how `story` is assigned; the numeric scene size limit; whether AutoCAD reads `$INSUNITS` from an AC1009 file (LibreCAD and ezdxf do; SketchUp Pro has a user-set import unit option, so it probably ignores it; QCAD untested).

### 3.7 3D export formats

Scope: every file the app hands to the user (textured model, raw LiDAR mesh, clean architectural model, object model, 2D plan, CAD files), plus zipping, sharing, Files app visibility and on-device preview. The short version: RoomPlan and SceneKit are the only documented full USDZ writers on iOS, and `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18.0) packages a USD layer into a usdz. ModelIO is reliable for import and for OBJ/STL, nothing else. Everything else (OBJ+MTL, PLY, STL, GLB, SVG, DXF) is small enough to write ourselves in pure Foundation.

#### Verified API

All declarations below were checked against Apple's documentation JSON (iOS 26 SDK doc set). "Usable at 18.0" means callable with no `#available` check at our iOS 18.0 deployment target. Nothing in this subsystem requires iOS 26, so no `#available(iOS 26, *)` gates are needed.

##### Native USDZ writers

| Declaration | iOS | Deprecated | Usable at 18.0 |
|---|---|---|---|
| `func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (RoomPlan, CapturedRoom) | 16.0 | no | yes |
| `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (CapturedRoom) | 17.0 | no | yes |
| `struct USDExportOptions` (OptionSet; `static let parametric`, `mesh`, `model`) | 16.0 (`.model` symbol only exists at runtime from 17) | no | yes |
| `struct CapturedStructure` (Codable, Sendable), `var rooms: [CapturedRoom] { get }` | 17.0 | no | yes |
| `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedStructure.ModelProvider? = nil, exportOptions: CapturedStructure.USDExportOptions = .mesh) throws` | 17.0 | no | yes |
| `func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure` (StructureBuilder) | 17.0 | no | yes |
| `init(options: StructureBuilder.ConfigurationOptions)` (StructureBuilder) | 17.0 | no | yes |
| `func write(to url: URL, options: [String : Any]? = nil, delegate: (any SCNSceneExportDelegate)?, progressHandler: SCNSceneExportProgressHandler? = nil) -> Bool` (SCNScene) | 8.0 | 26.0 | yes, with deprecation warnings |
| `optional func write(_ image: UIImage, withSceneDocumentURL documentURL: URL, originalImageURL: URL?) -> URL?` (SCNSceneExportDelegate) | 8.0 | 26.0 | yes, with warnings |
| `let SCNSceneExportDestinationURL: String` | 8.0 | 26.0 | yes, with warnings |
| `typealias SCNSceneExportProgressHandler = (Float, (any Error)?, UnsafeMutablePointer<ObjCBool>) -> Void` | 8.0 | 26.0 | yes, with warnings |
| `class func convert(toUSDZ inputURL: URL, writeTo outputURL: URL)` (MDLUtility, ModelIO) | 18.0 | no | yes, behaviour undocumented (see Disputed) |

Notes:
- RoomPlan output is USD. The `.usdz` extension comes from the URL we pass. Options combine: `[.parametric, .mesh]`.
- `SCNScene.write` doc text only documents `.scn` (iOS 10+) and `.dae` (macOS only). USDZ via a `.usdz` extension is undocumented but community-verified on device (many LiDAR apps, 2024 to 2026 commits). SceneKit writes a `.usdc` then zips it.
- SceneKit (the whole framework, including `SCNScene` and `SCNScene(mdlAsset:)`) is soft-deprecated at iOS 26.0. WWDC25 session 288: existing apps keep working, no hard deprecation planned, maintenance mode only.
- `SCNScene(mdlAsset:)`: Apple's doc JSON has only the Objective-C form `+ (instancetype) sceneWithMDLAsset:(MDLAsset *) mdlAsset;` (SCNScene, iOS 8.0, deprecated 26.0). The Swift spelling `SCNScene(mdlAsset:)` and the need for `import SceneKit.ModelIO` are not in the doc JSON (unverified; confirm with the first CI build). We do not need it: our own `Mesh` goes straight to `SCNGeometry`.

##### ModelIO (import, and OBJ/STL export only)

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `func export(to URL: URL) throws` (MDLAsset; format from `pathExtension`, must be a `file:` URL) | 9.0 | yes |
| `class func canExportFileExtension(_ extension: String) -> Bool` (documented: .obj, .stl; "additional formats may be supported") | 9.0 | yes |
| `class func canImportFileExtension(_ extension: String) -> Bool` (documented: .abc, .usd, .usda, .usdc, .usdz, .ply, .obj, .stl) | 9.0 | yes |
| `init(url URL: URL)` and `init(url URL: URL?, vertexDescriptor: MDLVertexDescriptor?, bufferAllocator: (any MDLMeshBufferAllocator)?)` (MDLAsset) | 9.0 | yes |
| `func add(_ object: MDLObject)`, `func childObjects(of objectClass: AnyClass) -> [MDLObject]` (MDLAsset) | 9.0 | yes |
| `init(vertexBuffer: any MDLMeshBuffer, vertexCount: Int, descriptor: MDLVertexDescriptor, submeshes: [MDLSubmesh])` (MDLMesh) | 9.0 | yes |
| `init(indexBuffer: any MDLMeshBuffer, indexCount: Int, indexType: MDLIndexBitDepth, geometryType: MDLGeometryType, material: MDLMaterial?)` (MDLSubmesh) | 9.0 | yes |
| `init(type: MDLMeshBufferType, data: Data?)` (MDLMeshBufferData) | 9.0 | yes |
| `init(name: String, format: MDLVertexFormat, offset: Int, bufferIndex: Int)` (MDLVertexAttribute) | 9.0 | yes |
| `init(stride: Int)` (MDLVertexBufferLayout) | 9.0 | yes |
| `init(name: String, scatteringFunction: MDLScatteringFunction)` (MDLMaterial) | 9.0 | yes |
| `convenience init(name: String, semantic: MDLMaterialSemantic, url URL: URL?)` (MDLMaterialProperty) | 9.0 | yes |
| `func addNormals(withAttributeNamed attributeName: String?, creaseThreshold: Float)` (MDLMesh) | 9.0 | yes |

Other ModelIO members listed by the researcher (verified class docs): `MDLVertexDescriptor.attributes` / `layouts` are `NSMutableArray` (assign with `desc.attributes[0] = MDLVertexAttribute(...)`), attribute name constants `MDLVertexAttributePosition`, `MDLVertexAttributeNormal`, `MDLVertexAttributeTextureCoordinate`, `MDLVertexAttributeColor`, `MDLIndexBitDepth.uInt32`, `MDLGeometryType.triangles`, `MDLMaterial.setProperty(_:)`, `MDLTextureSampler.texture`, `MDLURLTexture(url:name:)` (declared `init(url URL: URL, name: String?)`). `MDLMaterial.scatteringFunction` is read-only (set only via init).

##### RealityKit (no general mesh writer)

| Declaration | iOS | Notes |
|---|---|---|
| `@MainActor func write(to url: URL) async throws` (Entity) | 18.0 | Writes a `.reality` file only. Not USDZ, not OBJ. |
| `case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced, geometry: PhotogrammetrySession.Request.Geometry? = nil)` | 17.0 | USDZ if URL ends in `.usdz`; doc says a directory URL gives OBJ plus textures |
| `static var isSupported: Bool { get }` (PhotogrammetrySession) | 17.0 | runtime gate |
| `@MainActor static var isSupported: Bool { get }` (ObjectCaptureSession) | 17.0 (doc lists iOS and iPadOS only) | runtime gate; if false, creating an `ObjectCaptureSession` is a runtime error. The LiDAR + A14 hardware requirement is not stated on this symbol's doc page (our A15 with LiDAR already reported supported on device) |

`PhotogrammetrySession.Request.Detail`: only `.reduced` exists on iOS (17.0+). `.preview`, `.medium`, `.full`, `.raw` are macOS 12 / Catalyst 15 only; `.custom` is macOS 14 / Catalyst 17 only. Referencing them in iOS code will not compile. The newer overloads are not usable at 18.0: `struct WriteOptions` is iOS 26.0+, and `func write(to url: URL, options: Entity.WriteOptions) async throws` and `static func write(_ entities: [Entity], to url: URL, options: Entity.WriteOptions = WriteOptions()) async throws` are iOS 27.0+ (both `nonisolated(nonsending)`). They still write `.reality` and are irrelevant.

##### 2D output (PDF, PNG)

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `init(bounds: CGRect, format: UIGraphicsPDFRendererFormat)` (UIGraphicsPDFRenderer) | 10.0 | yes |
| `func writePDF(to url: URL, withActions actions: (UIGraphicsPDFRendererContext) -> Void) throws` | 10.0 | yes |
| `func pdfData(actions: (UIGraphicsPDFRendererContext) -> Void) -> Data` | 10.0 | yes |
| `var documentInfo: [String : Any] { get set }` (UIGraphicsPDFRendererFormat) | 10.0 | yes |
| `func beginPage()`, `func beginPage(withBounds bounds: CGRect, pageInfo: [String : Any])` (UIGraphicsPDFRendererContext) | 10.0 | yes |
| `init(size: CGSize, format: UIGraphicsImageRendererFormat)` (UIGraphicsImageRenderer) | 10.0 | yes |
| `func pngData(actions: (UIGraphicsImageRendererContext) -> Void) -> Data` | 10.0 | yes |
| `var cgContext: CGContext { get }` (UIGraphicsRendererContext) | 10.0 | yes |

PDF units are points (72 pt = 1 inch). A4 = 595.276 x 841.89 pt, US Letter = 612 x 792 pt. At 1:50, 1 m = 20 mm = 56.69 pt. There is no Apple SVG or DXF writer.

##### Hand-written formats (Foundation only)

| Declaration | iOS | Use |
|---|---|---|
| `class func data(withJSONObject obj: Any, options opt: JSONSerialization.WritingOptions = []) throws -> Data` | 5.0 | GLB JSON chunk (pass `.withoutEscapingSlashes` (iOS 13.0), `.sortedKeys` (iOS 11.0)) |
| `mutating func append(_ other: Data)`, `mutating func append<SourceType>(_ buffer: UnsafeBufferPointer<SourceType>)`, `mutating func append(contentsOf elements: some Sequence<UInt8>)` (Data); `func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R` (Array) | 8.0 | binary buffers for GLB, PLY, STL |
| `func pngData() -> Data?`, `func jpegData(compressionQuality: CGFloat) -> Data?` (UIImage) | no iOS version in doc JSON (long-standing, not gated) | embedded textures |

Format facts (glTF 2.0 spec, verified): GLB header is 12 bytes: magic `0x46546C67`, version 2, total length, all uint32 little endian. Chunk 0 is JSON (type `0x4E4F534A`, padded with `0x20`). Chunk 1 is BIN (type `0x004E4942`, padded with `0x00`). Both 4-byte aligned. `buffers[0]` has no `uri`. componentType 5126 float, 5125 uint32, 5123 uint16, 5121 uint8 (`normalized: true` for COLOR_0). POSITION accessors must have `min` and `max`. Images in a bufferView must set `mimeType` (`image/png` or `image/jpeg`). glTF is right-handed, +Y up, same as ARKit and RoomPlan, so no axis swap. UV (0,0) is the top-left of the image.

Binary STL: 80-byte header, uint32 triangle count, then 50 bytes per triangle (normal 3 floats, 3 vertices 9 floats, uint16 attribute), little endian, no colours, no units. PLY: `format binary_little_endian 1.0`, `property float x/y/z`, `nx/ny/nz`, `property uchar red/green/blue`, `property list uchar uint vertex_indices`. OBJ: 1-based `v`, `vn`, `vt`, `f a/b/c`, plus `mtllib`/`usemtl`; MTL: `newmtl`, `Kd`, `map_Kd <relative path>`.

DXF: R12 (`$ACADVER AC1009`) needs only the ENTITIES section and no handles. Use LINE, CIRCLE, ARC, TEXT and POLYLINE + VERTEX + SEQEND; layer is group 8, colour group 62. LWPOLYLINE does not exist in R12. It needs R2000 (AC1015), which then requires HEADER, CLASSES, TABLES, BLOCKS, OBJECTS and unique handles on every record.

##### Zip, sharing, Files app, preview

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `static var forUploading: NSFileCoordinator.ReadingOptions { get }` | 8.0 | yes |
| `func coordinate(readingItemAt url: URL, options: NSFileCoordinator.ReadingOptions = [], error outError: NSErrorPointer, byAccessor reader: (URL) -> Void)` (synchronous) | 5.0 | yes |
| `class func readingIntent(with url: URL, options: NSFileCoordinator.ReadingOptions = []) -> Self` (NSFileAccessIntent) | 8.0 | yes |
| `func coordinate(with intents: [NSFileAccessIntent], queue: OperationQueue, byAccessor accessor: @escaping @Sendable ((any Error)?) -> Void)` (asynchronous; read `intent.url` inside) | 8.0 | yes |
| `nonisolated init<I>(item: I, subject: Text? = nil, message: Text? = nil, preview: SharePreview<PreviewImage, PreviewIcon>) where Data == CollectionOfOne<I>, I : Transferable` (ShareLink) | 16.0 | yes |
| `init(exportedContentType: UTType, shouldAllowToOpenInPlace: Bool = false, exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile)` (FileRepresentation) | 16.0 | yes |
| `init(_ file: URL, allowAccessingOriginalFile: Bool = false)` (SentTransferredFile) | 16.0 | yes |
| `init(activityItems: [Any], applicationActivities: [UIActivity]?)` (UIActivityViewController) | 6.0 | yes |
| `init(forExporting urls: [URL], asCopy: Bool)` (UIDocumentPickerViewController) | 14.0 | yes |
| `static var usdz: UTType { get }` (also `.usd`, `.threeDContent`, `.pdf`, `.png`, `.svg`, `.zip`, `.json`) | 14.0 | yes |
| `init?(filenameExtension: String, conformingTo supertype: UTType = .data)` (UTType) | 14.0 | yes |
| `nonisolated func quickLookPreview(_ item: Binding<URL?>) -> some View` (SwiftUI) | 14.0 | yes |
| `class QLPreviewController`; `QLPreviewControllerDataSource`; `QLPreviewItem` (NSURL conforms) | 4.0 | yes |
| `init(fileAt url: URL)` (ARQuickLookPreviewItem, module QuickLook, not ARKit) | 13.0 | yes |

Info.plist keys (not entitlements, so they work with a free Apple ID): `UIFileSharingEnabled` (Boolean, iOS 3.2+), `LSSupportsOpeningDocumentsInPlace` (Boolean, iOS 2.0+), `UISupportsDocumentBrowser` (Boolean, iOS 11.0+). `URL.documentsDirectory` is iOS 16.0+. The `UIDocumentBrowserViewController` doc states the rule: other apps (including Files) can reach our Documents folder if we declare `UISupportsDocumentBrowser`, or both `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.

There are no UTType constants for obj, ply, stl, gltf, glb or dxf.

#### Gotchas

1. `MDLAsset.export` never writes USDZ on iOS. `canExportFileExtension("usdz")` returns false and export produces nothing. `.usdc`/`.usda` return true but the files lose materials (forum threads 111061, 737766, 745233, 764030; no counter-example found for any iOS version).
2. SceneKit is deprecated at 26.0 on the iOS 26 SDK. It compiles with warnings. Keep all SceneKit code in one file (for example `SceneKitUSDZWriter.swift`) behind a protocol. Default XcodeGen does not treat warnings as errors; do not turn that on.
3. `SCNScene.write` to `.usdz`: the second call in the same process can write a 1.5 to 2 KB corrupt file (forum 704590). The scene may need to be prepared or rendered once first. Write to `FileManager.default.temporaryDirectory.appendingPathComponent("<UUID>.usdz")`, check the Bool and the file size, then `moveItem`. On iOS 17 a URL built with `URL.appending(path:)` crashed with `stringByAppendingPathExtension: nil argument` (forum 731248); use `appendingPathComponent`. Repeated write and reload can lighten colours (forum 782858). Large scenes use a lot of memory (one report: 18 MB usdz became a 483 MB scn); keep vertex counts sane or export per chunk. Custom materials can produce a USDZ that Reality Converter flags (forum 734220). The forum points above rest on search snippets (forum pages return 403 to fetchers), so treat them as likely, not verified.
4. `SCNSceneExportDestinationURL` and a temp-dir-then-move pattern are required when the scene references external texture files. `SCNMaterial.diffuse.contents = UIImage` is embedded in the usdz.
5. ModelIO OBJ export writes a `.mtl` only if every `MDLSubmesh` has a non-nil `MDLMaterial` (Apple staff, forum 706609). Whether it writes `map_Kd` for a texture is unknown. Our own OBJ writer is about 60 lines and deterministic.
6. ModelIO cannot read binary PLY (forum 742244); ASCII PLY loads. PLY export through ModelIO is not documented. Write PLY ourselves; if we ever re-import, only accept our own files.
7. RoomPlan export: the USD file name must start with a letter (the doc says "Before iOS 17.4"; error `cannotCreateNode(path: "/9EE7...")`). Always prefix with a letter anyway. RoomPlan USDZ is untextured (flat colours).
8. RoomPlan `metadataURL` output is only a mapping of USDZ node names to `CapturedRoom` element UUIDs (WWDC23 10192), with undocumented encoding. The full room description comes from `JSONEncoder` on `CapturedRoom` / `CapturedStructure` (both Codable).
9. `StructureBuilder` merging only makes sense if rooms share one world space: stop each room with `stop(pauseARSession: false)` or relocalize via ARWorldMap. Apple suggests up to about 2,000 sq ft, single floor.
10. RealityKit cannot save a mesh as USDZ or OBJ. `Entity.write(to:)` produces `.reality` only. A search of the full RealityKit symbol index found no other writer on Entity, ModelEntity or MeshResource. An Apple engineer said the same in forum 757590 (search snippet only).
11. Object Capture on iOS: `.reduced` detail only (WWDC23 10191: "we support only the reduced detail level on iOS"; other levels need a Mac). Device support per WWDC23/24: iPhone 12 Pro, iPad Pro 2021 and later; Apple's sample lists a LiDAR Scanner and an A14 or later. Gate with `PhotogrammetrySession.isSupported` and `ObjectCaptureSession.isSupported`. For OBJ output via a directory URL, the URL must be a directory URL (`appendingPathComponent("Models/", isDirectory: true)`) and the folder must exist, otherwise the error says a `.usdz` extension is required (forum 742077).
12. glTF: uint16 indices cannot contain 65535, so switch to uint32 when vertex count is 65535 or more. Use one bufferView per attribute (a shared view needs `byteStride`). Effective vertex-attribute byte offsets must be multiples of 4. `JSONSerialization` and `JSONEncoder` throw on NaN or Inf, so sanitize positions, normals and min/max first. `KHR_materials_unlit` needs both root `extensionsUsed` and a per-material `"extensions": {"KHR_materials_unlit": {}}`.
13. No Apple viewer opens GLB, OBJ, PLY or STL. QuickLook previews only USDZ (plus PDF, PNG, text). Checking GLB needs a desktop or third-party viewer.
14. Units: STL has no units and CAD tools assume millimetres. DXF needs `$INSUNITS` (4 = mm, 6 = m). Pick "CAD formats in millimetres" once. Keep metres for glTF, USDZ, OBJ, PLY.
15. UIKit PDF context has a top-left origin with y down. A plan with +Y north needs `translateBy` to the page bottom and `scaleBy(x: s, y: -s)`. Text drawn after a flip must be un-flipped locally.
16. No public ZIP writer exists (AppleArchive writes `.aar` only; Apple staff in forum 681770 point to third-party libraries such as libarchive, which our no-packages rule excludes). The `.forUploading` zip lives only inside the accessor block (the coordinator unlinks it after), the call is synchronous, the archive root is always the folder name, and there is no control over compression or entry names (DTS, forum 688165). So stage the folder exactly as the zip should look. If we ever need custom entry names, a small store-only ZIP writer is possible (researcher estimate about 150 lines, not verified).
17. `ShareLink` with `FileRepresentation` runs the exporting closure lazily. The file must survive until the sheet closes. Keep exports in `Documents/<project>/Exports/`, not a purged temp dir. Give a `SharePreview` so the row is not blank.
18. Files app visibility needs both `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, and Documents must contain at least one file. The one-file rule comes from an Apple DTS reply (forum 765329), not from the docs. A `CFBundleVersion` bump is only a best-effort refresh. With in-place opening, other apps can edit our files, so write atomically. Sideloadly re-signs with the same bundle id every 7 days, so the container and exports survive.
19. QuickLook: return `url as QLPreviewItem`. `ARQuickLookPreviewItem(fileAt:)` failed with "Unhandled item type" for a Caches file (forum 689586). A `QLPreviewController` embedded in another view controller or hosted directly as a `UIViewControllerRepresentable` (even in a `.sheet`) loses the AR/Object toggle and Share button (forums 701842, 692364). Apple: an embedded controller shows only a thumbnail.
20. iOS 26.0/26.1 regression: AR Quick Look Share sends the `.usdz` file instead of `canonicalWebPageURL` (forum 812371). Harmless for us.

#### Recommended approach

1. **Own the mesh writers.** A Foundation-only `Exporters` module that works on our own `Mesh` struct (positions, normals, UVs, colours, uint32 indices, optional texture `Data`): OBJ + MTL (with `map_Kd`), binary little-endian PLY with vertex colours, binary STL in millimetres, and GLB. Pure Swift with no UIKit dependency, so it can be unit-tested on the macOS CI runner.
2. **Architectural model (USDZ):** `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` with `[.parametric, .mesh]` for one room, and `CapturedStructure.export(...)` for a merged house. Name files like `Room-<date>.usdz`, never starting with a digit. Save `CapturedRoom` / `CapturedStructure` with `JSONEncoder` in the project folder so we can re-export later.
3. **Textured and raw-mesh USDZ (synthesis ruling, see "Cross-section rulings" at the top of this document):** write our own `.usda` (UsdPreviewSurface plus UsdUVTexture, atlas JPEGs beside it by relative path) and package it with `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18.0, not deprecated, no throws, no return value). Check that the output exists, is larger than a few KB and starts with the bytes "PK". Fallback 1: our own stored (uncompressed) zip writer that follows the usdz rules (default layer first, 64-byte aligned payloads, CRC32 per entry). Fallback 2, only if both fail on device: one contained `SceneKitUSDZWriter` file (build `SCNGeometry` from our `Mesh`, `SCNMaterial.diffuse.contents = UIImage`, write to a unique temp URL, check the Bool and size, then move into `Exports/`). This follows the texturing tie-breaker ruling, which had stronger evidence (doc JSON plus SDK headers) than the researcher's SceneKit-first plan.
4. **Object model:** Object Capture writes `.usdz` at `.reduced`. Convert to OBJ, GLB, PLY or STL by `MDLAsset(url:)` + `childObjects(of: MDLMesh.self)` into our `Mesh`, then our own writers.
5. **ModelIO role:** import only (re-open USDZ from RoomPlan, Object Capture or our exports). Log `canExportFileExtension` results in the capability probe, but never depend on ModelIO for export.
6. **2D plan:** one `PlanRenderer.draw(in: CGContext, scale:)` shared by `UIGraphicsPDFRenderer` (vector PDF at 1:50 or 1:100 on A4 or Letter), `UIGraphicsImageRenderer` (PNG) and the on-screen SwiftUI `Canvas`. Separate string emitters for SVG (viewBox in mm) and DXF R12 (HEADER with `$ACADVER AC1009`, `$INSUNITS 4`, `$EXTMIN`/`$EXTMAX`; TABLES/LAYER; ENTITIES with LINE, POLYLINE + VERTEX + SEQEND, TEXT, CIRCLE, ARC). Only move to AC1015 if bulged LWPOLYLINEs are demanded.
7. **Packaging and sharing:** multi-file exports (OBJ + MTL + textures, full project bundle) are staged into `Documents/<project>/Exports/<Name>/` and zipped with `coordinate(readingItemAt:options: [.forUploading], ...)` on a background queue, moving the zip to `Exports/<Name>.zip` inside the block. Single files (USDZ, PDF, PNG, GLB) are shared as plain URLs with `ShareLink(item: url, preview: SharePreview(...))`. Use an `ExportPackage: Transferable` with `FileRepresentation(exportedContentType: .zip, ...)` if lazy export is wanted. Declare GLB and DXF in `UTExportedTypeDeclarations` or use `UTType(filenameExtension:)` with a nil check.
8. **Files app:** `UIFileSharingEnabled: true` and `LSSupportsOpeningDocumentsInPlace: true` are already under `info.properties` in `ios/project.yml`; keep them. Write a first file (for example a README or the projects index) at first launch so the folder appears.
9. **Preview:** `.quickLookPreview($previewURL)` for USDZ, PDF and PNG (presents the system viewer itself, AR mode included). If UIKit is needed, present `QLPreviewController` modally from the top view controller, never as an embedded representable. Our own RealityKit or SceneKit viewer for the other formats.
10. **First export CI build:** add a self-test that runs every writer on a synthetic textured cube, logs `canExportFileExtension` for obj, stl, ply, usdz, usdc, usda, abc, calls `SCNScene.write` twice, tries `MDLUtility.convert(toUSDZ:writeTo:)`, and zips a folder. Read the results through the log viewer so all open device questions close in one round trip.

#### Disputed or unsure

No tie-breaker rulings were needed for this topic: every claim survived both verifier lenses. The items below are corrections, nuances or open device questions.

1. **ModelIO export list.** Researcher: current doc lists only .obj and .stl; older doc text (mirrored on Microsoft Learn) listed .abc, .obj, .ply, .stl. Verifiers: core claim confirmed from Apple JSON, but the current Microsoft Learn pages no longer show the old list. Stronger evidence: verifiers (checked today). Ruling: only .obj and .stl are guaranteed; the historical list is irrelevant.
2. **ModelIO USDZ/USD export.** Researcher: impossible for usdz, broken for usdc/usda (confidence "likely", community only). Verifiers: not refuted; no iOS 17/18 re-test exists, but every data point from 2018 to 2024 agrees and Apple's WWDC19 session 602 names SceneKit as the USDZ path. Ruling: do not use ModelIO for USD output.
3. **SCNSceneExportDelegate signature.** Researcher and the reality verifier wrote a non-optional method with internal name `sceneDocumentURL`. The official-docs verifier and Apple JSON (re-fetched for this section) say: `optional func write(_ image: UIImage, withSceneDocumentURL documentURL: URL, originalImageURL: URL?) -> URL?`. Stronger evidence: Apple JSON, fetched directly. Ruling: use Apple's form; call sites are unaffected.
4. **"No hard deprecation planned" for SceneKit.** Comes from the WWDC25 session 288 transcript, not the doc JSON. Doc JSON shows deprecatedAt 26.0 with no replacement text, consistent with it. Ruling: accept; contain SceneKit in one file.
5. **RoomPlan digit-leading filename "before iOS 17.4".** One verifier could not find official evidence of a 17.4 fix; the second found the tip verbatim on both export pages, plus forum threads 738717/738801. Stronger evidence: the second verifier, because the tip is Apple's own doc text. Ruling: documented; always start names with a letter regardless (our iOS 18.3.2 device should not hit it).
6. **RoomPlan metadata file is "JSON".** Researcher said JSON. Verifier: it is a String to UUID mapping with undocumented encoding; Apple's sample uses a `.json` name and community code uses `.plist`. Ruling: treat it as an opaque mapping file; our room data comes from `JSONEncoder(CapturedRoom)`.
7. **`.model` export option at iOS 16.** Docs list it as 16.0 but the symbol fails to load on iOS 16 (forum 781513). Ruling: irrelevant at our 18.0 target.
8. **PhotogrammetrySession OBJ (directory) output on iOS.** Doc allows it without an iOS restriction; WWDC23 describes iOS output as USDZ only; every sampled iOS app writes `.usdz`. Forum 742077 shows the directory form works when built with `isDirectory: true`, platform not stated. Ruling: unsure; plan on USDZ then ModelIO import and our own OBJ writer; test directory output on device.
9. **`.custom` detail on iOS.** Researcher listed it without a platform. Verifier: macOS 14 / Catalyst 17 only. Ruling: verifier is right; only `.reduced` on iOS.
10. **ModelIO `map_Kd` in OBJ export.** No public evidence either way (forum 774459 unanswered). Ruling: irrelevant, we write our own MTL.
11. **`canExportFileExtension("ply")` on iOS 18.** No public test. Ruling: treat as unavailable; log it in the probe.
12. **SCNScene second-write bug on iOS 18.3 / 26.** Unsure (forum 704590, 2022; no fix report). Ruling: needs a device test; mitigate with unique temp names and a size check.
13. **`MDLUtility.convert(toUSDZ:writeTo:)`.** Declaration and iOS 18.0 availability verified from Apple JSON; the doc has no behaviour description, it does not throw and returns nothing. Ruling: candidate only, test on device before relying on it.
14. **ARQuickLookPreviewItem module.** Researcher labelled it ARKit and could not fetch the page. Verifier: it is in QuickLook, iOS 13.0+, `init(fileAt url: URL)`, `allowsContentScaling`, `canonicalWebPageURL`. Ruling: verifier is right; still prefer `url as QLPreviewItem`.
15. **QuickLook in a representable.** Researcher recommended a `UIViewControllerRepresentable`. Reality verifier: that loses AR mode and Share. Ruling: use `.quickLookPreview` or modal UIKit presentation. Whether `.quickLookPreview` keeps AR controls on iOS 18.3.2 needs a device check.
16. **glTF UV flip.** Researcher said Metal/ARKit UVs may need `v = 1 - v`. Verifier: glTF (0,0) is top-left, and camera images are also top-left, so projected UVs normally need no flip; only OpenGL-convention sources do. Ruling: no flip by default; confirm once in a viewer.
17. **CFBundleVersion bump fixes Files visibility.** Verifier: in the cited thread the bump did not fix the reporter's old project. Ruling: best-effort only; the real requirements are the two keys plus a non-empty Documents folder.
18. **UTType system identifiers for obj, stl, ply** (`public.geometry-definition-format` and so on). Researcher flagged them as from memory. Ruling: unverified; use `UTType(filenameExtension:)` with a nil check or our own Info.plist declarations.
19. **MDLAsset init with vertex descriptor.** Researcher wrote `init(url: URL, vertexDescriptor:bufferAllocator:)`. Apple JSON: `init(url: URL?, vertexDescriptor: MDLVertexDescriptor?, bufferAllocator: (any MDLMeshBufferAllocator)?)`. Ruling: use Apple's form (optional URL).
20. **Which thread calls `SCNScene.write`.** Researcher's gotcha: call it from the main thread after the scene is set up. Neither verifier checked this and the doc says nothing about threads. Ruling: unsure; start on the main thread in the first export build, measure the time, and only move it off the main thread if a device test shows it is safe.

### 3.8 Scan quality, coverage and measurement confidence

This section covers the live quality signals Apple gives us, how to turn them into a coverage score and a "Scan quality" summary (SPEC: SCAN QUALITY SYSTEM), how to attach an honest accuracy figure to each measurement (SPEC: MEASUREMENT CONFIDENCE), snapping for manual points, and thermal and battery handling. Apple publishes no accuracy specification for LiDAR, RoomPlan or Measure. Every accuracy number below is from third-party studies or practitioners and must be calibrated on the test device.

#### Verified API

All declarations below were read from Apple documentation JSON (the researcher, the verifiers, or a re-fetch during this synthesis). Everything here is available at iOS 18.0. Nothing in this subsystem needs an iOS 26 API. The only iOS 27 APIs mentioned are ones we must not use.

**RoomPlan live coaching and per-surface quality (RoomPlan)**

| Declaration | iOS | Usable at 18.0 |
|---|---|---|
| `enum Instruction` (RoomCaptureSession.Instruction) cases `normal`, `moveCloseToWall`, `moveAwayFromWall`, `turnOnLight`, `slowDown`, `lowTexture` (exactly six) | 16.0 | Yes |
| `func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)` (default empty implementation) | 16.0 | Yes |
| `var isCoachingEnabled: Bool` (RoomCaptureSession.Configuration) | 16.0 | Yes |
| `var completedEdges: Set<CapturedRoom.Surface.Edge> { get }` | 16.0 | Yes |
| `enum Edge` cases `top`, `bottom`, `left`, `right` (CapturedRoom.Surface.Edge) | 16.0 | Yes |
| `enum Confidence` cases `high`, `medium`, `low`, exposed as `confidence` on Surface and Object | 16.0 | Yes |
| `var polygonCorners: [simd_float3] { get }` (local plane coordinates) | 17.0 | Yes |
| `var curve: CapturedRoom.Surface.Curve? { get }` | 16.0 | Yes |
| `var floors: [CapturedRoom.Surface] { get }`; `CapturedRoom.Section` | 17.0 | Yes |
| `init(arSession: ARSession? = nil)` (RoomCaptureSession) | 17.0 | Yes |
| `func stop(pauseARSession: Bool = true)` | 17.0 | Yes |
| `enum CaptureError` cases `deviceNotSupported`, `deviceTooHot`, `exceedSceneSizeLimit`, `invalidARConfiguration`, `worldTrackingFailure`, `internalError` | 16.0 | Yes |
| `func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure` (StructureBuilder) | 17.0 | Yes |

Surface fields used for expected area and snapping (all iOS 16.0 unless noted): `identifier: UUID`, `parentIdentifier: UUID?` (17.0; door, window or opening to owning wall), `category`, `confidence`, `transform: simd_float4x4`, `dimensions: simd_float3` (x width, y height, z thickness), `story: Int` (17.0), `completedEdges`, `curve`, `polygonCorners` (17.0). The delegate also has `didStartWith`, `didAdd`, `didChange`, `didUpdate`, `didRemove` (each passing a `CapturedRoom`) and `captureSession(_:didEndWith: CapturedRoomData, error: (any Error)?)`.

**ARKit per-frame quality signals (ARKit)**

```swift
// ARCamera
var trackingState: ARCamera.TrackingState { get }            // iOS 11.0
@frozen enum TrackingState { case notAvailable; case limited(ARCamera.TrackingState.Reason); case normal }
// Reason: initializing, relocalizing (11.3), excessiveMotion, insufficientFeatures
var intrinsics: simd_float3x3 { get }                         // iOS 11.0
var exposureDuration: TimeInterval { get }                    // iOS 13.0
// ARSessionObserver: optional func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera)

// ARFrame
var worldMappingStatus: ARFrame.WorldMappingStatus { get }    // iOS 12.0; notAvailable, limited, extending, mapped
var sceneDepth: ARDepthData? { get }                          // iOS 14.0
var smoothedSceneDepth: ARDepthData? { get }                  // iOS 14.0
var lightEstimate: ARLightEstimate? { get }                   // iOS 11.0
var rawFeaturePoints: ARPointCloud? { get }                   // iOS 11.0 (unstable, heuristic only)

// ARDepthData (iOS 14.0)
unowned(unsafe) var depthMap: CVPixelBuffer { get }           // metres, example format kCVPixelFormatType_DepthFloat32
unowned(unsafe) var confidenceMap: CVPixelBuffer? { get }     // one ARConfidenceLevel raw value per depth pixel
enum ARConfidenceLevel                                        // Int raw values: low = 0, medium = 1, high = 2; Comparable

// ARLightEstimate
var ambientIntensity: CGFloat { get }                         // 1000 = neutral lighting, no lux mapping published
var ambientColorTemperature: CGFloat { get }                  // Kelvin

// ARConfiguration
class func supportsFrameSemantics(_ frameSemantics: ARConfiguration.FrameSemantics) -> Bool  // iOS 13.0, call on the subclass
```

**Mesh, raycast and planes (ARKit)**

```swift
var sceneReconstruction: ARConfiguration.SceneReconstruction { get set }  // ARWorldTrackingConfiguration, iOS 13.4; .mesh, .meshWithClassification
class ARMeshAnchor: ARAnchor { var geometry: ARMeshGeometry { get } }     // iOS 13.4
var vertices: ARGeometrySource { get }        // SIMD3<Float>
var normals: ARGeometrySource { get }         // PER VERTEX in practice (see Disputed)
var faces: ARGeometryElement { get }          // triangles, bytesPerIndex 4
var classification: ARGeometrySource? { get } // one UInt8 per FACE, raw ARMeshClassification, 0 = .none
enum ARMeshClassification                     // none, wall, floor, ceiling, table, seat, window, door
// ARSession.RunOptions.resetSceneReconstruction removes all mesh anchors

func raycastQuery(from point: CGPoint, allowing target: ARRaycastQuery.Target, alignment: ARRaycastQuery.TargetAlignment) -> ARRaycastQuery  // ARFrame, iOS 13.0
func raycast(_ query: ARRaycastQuery) -> [ARRaycastResult]                // ARSession, iOS 13.0
// Target: estimatedPlane, existingPlaneGeometry, existingPlaneInfinite. Alignment: any, horizontal, vertical.
var planeExtent: ARPlaneExtent { get }        // ARPlaneAnchor, iOS 16.0 (width, height, rotationOnYAxis)
// ARPlaneGeometry: @nonobjc var boundaryVertices: [simd_float3] { get } (iOS 11.3)
// ARPlaneAnchor: var classification: ARPlaneAnchor.Classification { get } (iOS 12.0)
```

**Screen projection for the coverage overlay (ARKit, iOS 26 SDK)**

| Declaration | iOS | Status on Xcode 26.6 |
|---|---|---|
| `projectPoint(_:orientation:viewportSize:)` (ObjC `projectPoint:orientation:viewportSize:`, returns CGPoint) | 11.0, deprecated 27.0 | Use. Not deprecated in the iOS 26 SDK |
| `@nonobjc func unprojectPoint(_ point: CGPoint, ontoPlane planeTransform: simd_float4x4, orientation: UIInterfaceOrientation, viewportSize: CGSize) -> simd_float3?` | 12.0, deprecated 27.0 | Use |
| `projectionMatrix(for:viewportSize:zNear:zFar:)` (ObjC `projectionMatrixForOrientation:viewportSize:zNear:zFar:`), ARFrame `displayTransform(for:viewportSize:)` (ObjC `displayTransformForOrientation:viewportSize:`) | 11.0, deprecated 27.0 | Use |
| `func projectPoint(_ point: simd_float3, viewRotationAngle: CGFloat, viewportSize: CGSize) -> CGPoint` and all other `viewRotationAngle` variants (`projectionMatrix(viewRotationAngle:viewportSize:zNear:zFar:)`, `unprojectPoint(_:ontoPlane:viewRotationAngle:viewportSize:)`, ARFrame `displayTransform(viewRotationAngle:viewportSize:)`), ARSession `@nonobjc var viewRotationAngle: CGFloat? { get }` | 27.0 | Do not use. Absent from the iOS 26 SDK |

The live doc pages for the orientation variants now show only the Objective-C declaration. The Swift spellings above are the long-standing imported names used by Apple's point-cloud sample.

**Object Capture quality feedback (RealityKit, iOS 17.0, all @MainActor)**

```swift
enum ObjectCaptureSession.Feedback { case environmentLowLight; case environmentTooDark; case movingTooFast
  case objectNotDetected /* iOS 17.4 */; case objectNotFlippable; case objectTooClose; case objectTooFar
  case outOfFieldOfView; case overCapturing }          // no `outOfRange` case exists
@MainActor var feedback: Set<ObjectCaptureSession.Feedback> { get }
@MainActor var feedbackUpdates: ObjectCaptureSession.Updates<Set<ObjectCaptureSession.Feedback>> { get }  // Updates is an AsyncSequence
@MainActor var cameraTracking: ObjectCaptureSession.Tracking { get }  // normal, limited(reason:), notAvailable
@MainActor var numberOfShotsTaken: Int { get }; @MainActor var maximumNumberOfInputImages: Int { get }
@MainActor var userCompletedScanPass: Bool { get }     // true when the capture dial is full, reset by beginNewScanPass
```

**Thermal, battery, idle (Foundation, UIKit)**

```swift
var thermalState: ProcessInfo.ThermalState { get }                   // iOS 11.0; nominal, fair, serious, critical
class let thermalStateDidChangeNotification: NSNotification.Name     // iOS 11.0
var isLowPowerModeEnabled: Bool { get }                              // iOS 9.0
var isBatteryMonitoringEnabled: Bool { get set }                     // UIDevice, iOS 3.0
var batteryLevel: Float { get }                                      // -1.0 until monitoring is enabled
var isIdleTimerDisabled: Bool { get set }                            // UIApplication, iOS 2.0
// Video format control (ARKit)
var videoFormat: ARConfiguration.VideoFormat { get set }             // iOS 11.3
class var supportedVideoFormats: [ARConfiguration.VideoFormat] { get }  // iOS 11.3, declared on ARConfiguration; call it as ARWorldTrackingConfiguration.supportedVideoFormats
func captureHighResolutionFrame() async throws -> ARFrame            // ARSession, iOS 16.0 (completion-handler form also exists)
// captureHighResolutionFrame(using: AVCapturePhotoSettings?) is iOS 26.0: do not use at an iOS 18.0 target without #available
```

Apple's thermal guidance (doc text): at `.serious` "reduce the target framerate from 60 FPS to 30 FPS", reduce CPU and GPU work, lower rendered detail. At `.critical` "if possible, stop using peripherals such as the camera".

#### Gotchas

1. `RoomCaptureSession.Instruction` is guidance only, not a numeric quality. Apple publishes no distance, speed or lux thresholds. Its ML guidance model is about 90% accurate for lighting, distance and speed (Apple ML research).
2. `CapturedRoom.Confidence` is certainty in the category (is this a wall), not dimensional accuracy. Never show it as accuracy.
3. `completedEdges` is iOS 16.0, not 17.0. Apple never says a missing edge means "not observed". It may be empty during `didUpdate` and populated only in the final room. Treat it as a soft hint.
4. RoomPlan's own ARSession does not enable `.sceneDepth` or scene reconstruction by default, and `run` overrides settings made before it. Reconfigure after `captureSession(_:didStartWith:)`. Configuration changes apply asynchronously, so read `arSession.configuration` later (for example in `didUpdate`).
5. `stop()` pauses the ARSession by default. Use `stop(pauseARSession: false)` to keep mesh anchors and world tracking alive for the next room or for post-scan measuring.
6. `ARMeshGeometry.normals` is per vertex (`normals.count == vertices.count`) despite the doc abstract saying "for each face". Size reads from `normals.count`. Compute face normals by cross product of the three vertices.
7. ARMeshAnchor face indices are not stable across updates. Key coverage by a quantized world-space face centroid (voxel hash), never by face index.
8. Depth and confidence pixel formats are documented as examples. Read `CVPixelBufferGetPixelFormatType`, `CVPixelBufferGetWidth` and `Height` at runtime. On the 13 Pro Max expect 256x192 depth at the ARFrame rate (60 Hz). Confidence raw values are 0, 1, 2 (some blogs wrongly say 1 to 3).
9. `confidenceMap` is optional. `sceneDepth` is nil unless `.sceneDepth` is in `frameSemantics`. Call `supportsFrameSemantics` on `ARWorldTrackingConfiguration`, not on `ARConfiguration`.
10. ARKit camera space: +y up, +z toward the user, so visible points have negative z. Pinhole mapping into `capturedImage` pixels is `u = fx * x / (-z) + cx`, `v = fy * (-y) / (-z) + cy`. The research notes had a sign error here. Scale u, v by depthWidth / imageWidth only because both are 4:3.
11. Mesh coverage on a wall can be inflated by furniture. Count only faces classified `.wall` (or `.floor`, `.ceiling`) and within 10 cm of the RoomPlan wall plane.
12. LiDAR confidence collapses on glass, mirrors, glossy black and back-lit windows. Those cells stay red forever. Detect "persistently low confidence near a RoomPlan window" and stop nagging. Practitioners also report that large mirrors create gaps or phantom objects in RoomPlan output.
13. Thermal throttling is silent: frame rate drops, tracking drifts, mesh slides. RoomPlan only reports it at the end as `CaptureError.deviceTooHot`. Apple (WWDC22) says avoid single RoomPlan scans over 5 minutes. Community reports put throttling at 10 to 15 minutes of LiDAR plus Metal mesh rendering.
14. Apple's RoomPlan envelope (WWDC22 10127, WWDC23 10192): one room up to 9 x 9 m (30 x 30 ft), height up to 3.6 m, lighting of at least 50 lux, multi-room up to about 186 m2 (2,000 sq ft). Apple reports 95% precision and recall for walls and windows and 90% for doors. Treat these as the limits of any "good quality" verdict.
15. Live `didUpdate` rooms carry provisional geometry. RoomPlan beautifies wall and floor polygons only at the end of the scan. The live expected-area figure is approximate; the final score must come from the finished room.
16. If plane detection is on, ARKit smooths the mesh where it detects a plane (sceneReconstruction doc). This helps flat walls but hides small real features.
17. On iOS 17 and later `UIDevice.batteryLevel` is rounded to 5% steps. A %/minute drain figure needs windows of several minutes.
18. Changing `videoFormat` requires `run` again, which restarts the camera and can drop tracking. Do it only at natural pauses.
19. Holding many ARFrame references stalls ARKit. Copy the transform, intrinsics and a small confidence sample, then release the frame.
20. `ObjectCaptureSession` owns the camera. It cannot run at the same time as our ARSession or RoomCaptureSession. Its Feedback is a non-frozen enum: switch with `@unknown default`. Writing `.outOfRange` costs a CI round trip.
21. `rawFeaturePoints` count and layout are unstable between frames and releases. Use only as a weak "low texture" hint.
22. RoomPlan's wall voxel grid is 3 cm (Apple ML research). Practitioners report that wall thickness defaults to about 16 cm and that walls thicker than about 50 cm become two thin walls. Never claim better than about ±3 cm from RoomPlan geometry alone.
23. When the app uses `RoomCaptureView` instead of a bare `RoomCaptureSession`, the view already draws the coaching hints. Do not show our own copy of the Instruction text on top of it.

#### Recommended approach

**One shared ARSession.** The app creates the ARSession and passes it with `RoomCaptureSession(arSession:)`. In `didStartWith`, re-run it with `ARWorldTrackingConfiguration` using `sceneReconstruction = .meshWithClassification` and `frameSemantics = [.sceneDepth]`. Check both supports first. Keep a flag that falls back to a separate mesh pass if the device test shows RoomPlan stops producing walls. Device test on the first build: about 5 s after the re-run, log `arSession.configuration`, whether `frame.sceneDepth` is non-nil, the ARMeshAnchor count, and confirm RoomPlan still delivers `didUpdate` rooms and a final CapturedRoom with walls. Multi-room: `stop(pauseARSession: false)` and reuse the same session so all rooms share one world frame.

**Live coverage (3 Hz, background queue).**
- Voxel hash `[UInt64: UInt8]` of 10 cm cells, keyed by packed integer (x, y, z) of a face centroid. A 9 x 9 x 3 m room is at most about 243k cells, typically 20k to 40k.
- Every 333 ms take the latest frame's camera transform, intrinsics, image resolution and confidence map, then release the frame.
- For each ARMeshAnchor whose bounds intersect the view frustum, visit every 4th face. Count it when: 0.3 m < -z < 4.0 m, the projection is inside the image, the face normal (computed from vertices) is within 60 degrees of facing the camera, and the confidence sample is at least `.medium`. Saturate the count at 255.
- Overlay colour: 0 red, 1 to 2 yellow, 3 or more green.

**Expected vs observed area (1 Hz while RoomPlan runs, final value from the finished CapturedRoom).**
- expectedArea per wall = polygon area from `polygonCorners` (fallback `dimensions.x * dimensions.y`) minus doors, windows and openings whose `parentIdentifier` equals the wall's `identifier`.
- observedArea = sum of `.wall` faces within 10 cm of the plane and inside the wall rectangle (use `inverse(transform)`).
- wallCoverage = min(1, observed / expected). Room score = area-weighted mean over walls and floor, times a factor: 0.85 if an edge is missing from `completedEdges`, 0.7 for `.medium` confidence, 0.5 for `.low`. Because `completedEdges` semantics are unverified, keep the edge factor behind a tuning constant.
- Map this to the SPEC summary lines: Walls, Floor, Ceiling (mesh `.ceiling` faces vs floor polygon area), Geometry (all cells), Missing areas (clusters of red or hole cells larger than a threshold). Textures belongs to the texturing section.

**Holes.** Per updated anchor only, throttled to at most every 0.5 s: boundary edges (edges used by one face), ignoring edges within 2 cm of the anchor's own bounds (seams). Flag the 10 cm cell. Skip at `.serious` thermal state.

**Coaching.** RoomPlan's Instruction stream is the primary coaching text during room scans. Add only what RoomPlan lacks: coverage percentage, walls with low coverage, thermal warnings, the scan timer. Use `ambientIntensity` (start with < 300 dark, < 600 dim, calibrate on device; Apple gives no lux mapping, and RoomPlan wants at least 50 lux) and `trackingState` for the mesh and measure modes. `ARCoachingOverlayView` (iOS 13.0, UIKit, wrap in `UIViewRepresentable`) only for raw mesh and measure modes. For Object Capture use Apple's own dial plus `numberOfShotsTaken / maximumNumberOfInputImages` and `userCompletedScanPass`.

**Measurement confidence (metres, all constants in one config struct).**
- sigma_depth(d, c) = (0.005 + 0.004 * d) * k_c with k_high 1, k_medium 1.5, k_low 3; divide by sqrt(min(n, 9)) for n observations of the endpoint cell; floor 0.004.
- sigma_pose(L) = 0.005 * L if tracking stayed `.normal`, 0.015 * L after any `.limited(.excessiveMotion or .insufficientFeatures)`, 0.03 * L after a relocalization.
- sigma_pick = 0.003 for a snapped high-confidence RoomPlan corner, 0.01 for a plane raycast, 0.02 for a raw mesh vertex.
- sigma_total = root-sum-square of both endpoints' depth and pick terms plus sigma_pose. Display ±2 sigma, floored at 1.0 cm (0.4 in), rounded up to 0.5 cm or 0.1 in, formatted through `ios/Sources/Units/`.
- Above 4 cm, show "Low confidence, rescan this section" (text from `Copy.swift`) instead of a number. Never show a RoomPlan-derived wall length as better than ±3 cm (±1.2 in), and let the figure grow with wall length through sigma_pose. The 3 cm cap is the RoomPlan wall voxel size (gotcha 22). It is stricter than the practitioner-based ±1 in (2.5 cm) in the research notes, so it satisfies both sources. Label floor-plan dimensions as interior face to face, accuracy class "estimated ±1 in per 10 ft".
- Calibrate after the tape-measure protocol in `docs/TEST_PLAN.md` (flat wall at 0.5, 1, 2, 3, 4 m, high confidence pixels only).

**Snapping order** (10 cm world radius or 24 pt screen radius, whichever is smaller in world space): 1) RoomPlan corners (wall polygon or rectangle corners, door, window and opening corners, wall-wall-floor intersections for wall ends within 15 cm); 2) `ARPlaneAnchor` boundary vertices when RoomPlan is not running; 3) raycast `.existingPlaneGeometry` with vertical or horizontal alignment; 4) `.estimatedPlane`. Defer mesh crease detection (adjacent normals differ by more than 35 degrees) past v1.

**Thermal and battery ladder.** Observe `thermalStateDidChangeNotification`.
- nominal, fair: default format, coverage at 3 Hz, overlay on.
- serious: coverage at 1 Hz, stop mesh overlay rendering (keep collecting), stop hole computation, show a "phone is warm" hint. Switch to a 30 fps, lowest-resolution video format only at the next pause, and never on the RoomPlan session until the device test passes.
- critical: pause the session, save state, ask the user to wait.
- Expectation for the A15 (no published data): `.fair` within minutes, `.serious` possibly after 10 to 20 minutes of RoomPlan plus mesh plus overlay, `.critical` unlikely in a normal room scan. The session log settles it.
- Always: `isIdleTimerDisabled = true` while scanning; set `isBatteryMonitoringEnabled = true` before reading `batteryLevel`; warn at 4 minutes of continuous RoomPlan scanning; suggest splitting rooms; warn below 20% battery.

**Session quality log** (stored next to the CapturedRoomData JSON, also feeds the formula): fraction of frames not `.normal`, relocalization count, time under each Instruction, min and median `ambientIntensity`, thermal timeline with elapsed seconds, battery level every 30 s, RoomPlan CaptureError, per-wall completedEdges, confidence and coverage, and a depth-confidence histogram.

#### Disputed or unsure

1. **ARMeshGeometry.normals per face vs per vertex.** Researcher (and the doc abstract, official-docs verifier): per face. Reality verifier: refuted, normals are per vertex; the SDK header says "Normal of each vertex", developer reports find `normals.count == vertices.count`, and working Metal renderers bind the normals buffer beside the vertex buffer for an indexed draw. The official-docs verifier itself flagged the same caveat. Stronger evidence: per vertex (header text plus working code beats a doc abstract). No tie-breaker was needed. **Ruling: per vertex. Compute face normals from vertices.**
2. **Published accuracy figures.** Researcher: RMSE 2.05 cm (iPhone 12 Pro) and 2.06 cm (iPhone 15); "building-scale" iPhone 13 Pro scans with 69 to 83% of points within 5 cm. Both verifiers refuted parts: the 2026 Remote Sensing Letters study compared the iPhone 12 Pro Max and iPhone 15 Pro (the base iPhone 15 has no LiDAR), on small objects (0.8 to 42.5 cm) at 0.01 to 3 m, and found the 15 Pro less accurate at 3 m. The MDPI Geomatics 2023 study was one laboratory room with four apps; best app std about 7 cm, one app 44 cm mean deviation, achievable 10 to 20 cm; the 69 to 83% figure was not found. Confirmed: Luetzenburg 2021 ±1 cm for objects over 10 cm (±10 cm at 130 m cliff scale), and 3.7 cm median agreement of ARKit depth vs Faro (ARKitScenes, rerun.io). The MDPI abstract adds that no app met the U.S. Institute of Building Documentation accuracy levels, and that deviations were concentrated within 5 cm (no percentage given). The 3.7 cm median is a whole-frame figure and is likely inflated by far pixels: other studies show Apple LiDAR error roughly proportional to range, 1 to 2 cm at 1 to 3 m, rising sharply beyond about 4.5 m. Stronger evidence: verifiers (study metadata and dataset record). **Ruling: use corrected figures; room-scale consumer-app error is several cm to decimetres and dominated by tracking. "Reasonable to about 4 m" is optimistic; the formula's distance term handles this.**
3. **Projection formula signs.** Research notes: `u = fx*x/z + cx, v = fy*y/z + cy`. Reality verifier: wrong signs for ARKit camera space. **Ruling: `u = fx*x/(-z) + cx`, `v = fy*(-y)/(-z) + cy`.** The claim that the orientation APIs are fine on Xcode 26.6 and the viewRotationAngle APIs are iOS 27 was confirmed by both verifiers and by re-fetch.
4. **completedEdges meaning.** Researcher: a missing edge means RoomPlan never saw that end. Verifiers: not refuted, but only community evidence (several GitHub projects use `count == 4 && confidence == .high` as "complete"); Apple's Edge overview literally says the set contains one of each case; a WWDC22 lounge report saw it empty in `didUpdate`. **Ruling: soft hint only, never a gate for finishing, computed from the final room, verified on device.**
5. **RoomCaptureSession availability.** Researcher listed the whole API as iOS 16.0. Verifiers: `init(arSession:)` and `stop(pauseARSession:)` are iOS 17.0 (re-fetch agrees). No impact at an iOS 18.0 target.
6. **Depth specifics (60 Hz, 256x192, about 5 m, raw 0/1/2).** Not in the API reference; confirmed by WWDC20 10611 (60 Hz, same aspect ratio), forum reports and community code. Caveat from the reality verifier: the LiDAR emitter samples slower and ARKit fuses to the frame rate, so independent depth updates may be below 60 Hz. **Ruling: likely correct; read sizes and formats at runtime.**
7. **Battery drain "about 1% per minute".** Researcher's working assumption, no source. Verifier: unassessed, and batteryLevel only moves in 5% steps. **Ruling: unverified; measure over long windows.**
8. **RoomPlan dimensional error (±5 cm per wall, +37 cm over a multi-partition space, ±2 to 4 in over 20 ft).** Two independent practitioner sources (it-jim, Scan Manifold), not verified by a second pass. **Ruling: likely; used only to cap displayed confidence.**
9. **Can the app re-run RoomPlan's ARSession with its own configuration?** Research notes: no, re-running breaks RoomPlan with `invalidARConfiguration`, so plan a separate mesh pass. Open-question answer (Apple forum thread 763400, WWDC23 10192): RoomPlan's own `run` strips `.sceneDepth` and scene reconstruction, and the accepted workaround is to re-run the same app-owned session after `didStartWith`. WWDC23 says any custom ARSession with ARWorldTrackingConfiguration is honored, and Apple's docs tie `invalidARConfiguration` to setting the `arSession` property, not to re-running it. Stronger evidence: the open-question answer (developer reports of a working workaround plus Apple's own wording), but no one has confirmed it on iOS 18.3.2. **Ruling: shared session with re-run in `didStartWith` as the plan, separate mesh pass behind a flag, settled by the first-build device test.**
10. **Changing `videoFormat` on the RoomPlan session.** Undocumented. A format set before `run` is likely overwritten, as with sceneDepth. **Ruling: do not depend on a non-default format during RoomPlan; use `captureHighResolutionFrame()` for stills.** Device test: in `didStartWith` re-run with `ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing`, watch `session(_:didFailWithError:)`, log `configuration.videoFormat` and `frame.camera.imageResolution` after 3 s, and confirm a CapturedRoom is still produced.
11. **Mesh anchor cadence and block size.** Apple only says mesh anchors "constantly update" and are not real time. Community figures (0.5 to 1 s, 1 to 2 m blocks) are unverified. **Ruling: throttle hole computation per anchor to at most every 0.5 s so any cadence works.** Device test: log per-anchor update interval and vertex extent over a 2 minute scan.
12. **confidenceMap format on iOS 18.** Expected `kCVPixelFormatType_OneComponent8` (four-character code L008) with values 0 to 2. **Ruling: likely; on first run log the format and a histogram of byte values, map with `ARConfidenceLevel(rawValue:)`, and treat all depth as medium if the format differs.**
13. **Thresholds in the recommended algorithms** (ambientIntensity 300 and 600, 10 cm cells, 3 observations, sigma constants, quality factors). Engineering choices, not facts. **Ruling: keep them in one config struct and tune on device.**

### 3.9 Storage, deployment and concurrency

This section covers Info.plist keys, free Apple ID sideloading limits, the on-disk project layout and serialization, the memory budget, background processing, and the Swift language mode and concurrency settings. All declarations below were checked against Apple documentation JSON on 2026-09-28. "Usable at 18.0" means it compiles and runs with the iOS 18.0 deployment target without an availability check.

#### Verified API

##### Info.plist keys and entitlements

| Key | Introduced | Usable at 18.0 | Notes |
|---|---|---|---|
| `NSCameraUsageDescription` | iOS 7.0 | Yes | Required for any camera API. It is the only thing RoomPlan, ARKit scene reconstruction and Object Capture need. No entitlement exists for them on iOS. |
| `UIRequiredDeviceCapabilities` | iOS 3.0 (`arkit` value iOS 11) | Yes | 29 documented values. There is no `lidar` or `depth` value. Use `arkit` and gate LiDAR at runtime. It only gates installation (researcher and one verifier say it matters only for the App Store); it never proves LiDAR is present. |
| `UIFileSharingEnabled` | iOS 3.2 | Yes | Default NO. With `LSSupportsOpeningDocumentsInPlace` it shows `Documents/` in Files under On My iPhone. |
| `LSSupportsOpeningDocumentsInPlace` | iOS 2.0 (doc listing) | Yes | See above. The "both keys" rule is community-verified; each key's meaning is from Apple docs. |
| `UISupportsDocumentBrowser` | iOS 11.0 | Yes | Alternative single key. Not needed. |
| `UTExportedTypeDeclarations` | iOS 5.0 | Yes | For the `.mapperproj` package type. |
| `CFBundleDocumentTypes` | iOS 2.0 | Yes | Keys: `CFBundleTypeName`, `CFBundleTypeRole`, `LSHandlerRank`, `LSItemContentTypes`, `LSTypeIsPackage`. |
| `UISupportedInterfaceOrientations` | iOS 3.2 | Yes | Portrait only for this app. |
| `UILaunchScreen` | iOS 14.0 | Yes | Empty dictionary is valid, no storyboard. |
| `NSPhotoLibraryAddUsageDescription` | iOS 11.0 | Yes | Only for writing to Photos. Not needed for Documents or share sheets. |
| `UIBackgroundModes` = `processing`, `BGTaskSchedulerPermittedIdentifiers` | iOS 4.0 / iOS 13.0 | Yes | Only if `BGProcessingTask` is used. Not needed for v1. |
| `ITSAppUsesNonExemptEncryption` | n/a (Apple's key page lists only macOS 10.0) | Yes | App Store Connect export-compliance key; harmless in an iOS Info.plist. |

Not needed: `NSMotionUsageDescription` (ARKit IMU use does not prompt), `NSMicrophoneUsageDescription`, location keys, a privacy manifest (enforced only at App Store submission). The current `ios/project.yml` also carries `NSLocalNetworkUsageDescription` for the debug server; keep it.

Every `com.apple.developer.arkit.*` entitlement in Apple's reference is visionOS-only (listed under "Enterprise"). None applies to RoomPlan or Object Capture on iOS.

##### Custom package document type

```xml
<key>UTExportedTypeDeclarations</key>
<array><dict>
  <key>UTTypeIdentifier</key><string>com.shreehub.mapper.project</string>
  <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.content</string></array>
  <key>UTTypeDescription</key><string>Mapper Project</string>
  <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mapperproj</string></array></dict>
</dict></array>
<key>CFBundleDocumentTypes</key>
<array><dict>
  <key>CFBundleTypeName</key><string>Mapper Project</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>LSHandlerRank</key><string>Owner</string>
  <key>LSTypeIsPackage</key><true/>
  <key>LSItemContentTypes</key><array><string>com.shreehub.mapper.project</string></array>
</dict></array>
```

Swift side (UniformTypeIdentifiers, iOS 14.0+): `init(exportedAs identifier: String, conformingTo parentType: UTType? = nil)`, `static var package: UTType { get }`, and the built-in `.usdz`, `.pdf`, `.json`, `.heic`, `.jpeg`, `.png`. Do not redeclare system types such as OBJ (`public.geometry-definition-format`).

##### Runtime capability gates (all usable at 18.0)

```swift
static var isSupported: Bool { get }                    // RoomCaptureSession, iOS 16.0
class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool  // ARWorldTrackingConfiguration, iOS 13.4
@MainActor static var isSupported: Bool { get }         // ObjectCaptureSession, iOS 17.0
static var isSupported: Bool { get }                    // PhotogrammetrySession, iOS 17.0
```

##### Files, backup, protection, free space

```swift
var isExcludedFromBackup: Bool? { get set }                          // URLResourceValues, iOS 8.0
var volumeAvailableCapacityForImportantUsage: Int64? { get }         // URLResourceValues, iOS 11.0
var volumeAvailableCapacityForOpportunisticUsage: Int64? { get }     // URLResourceValues, iOS 11.0
func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask, appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL  // FileManager, iOS 4.0
struct URLFileProtection                                              // iOS 2.0
static let none: URLFileProtection                                    // iOS 9.0; same for complete, completeUnlessOpen, completeUntilFirstUserAuthentication
static let completeWhenUserInactive: URLFileProtection                // iOS 17.0
```

The default data protection class is "complete until first user authentication". Files stay readable while locked after the first unlock. No Info.plist key is needed.

##### Serialization building blocks

| Declaration | Availability | Note |
|---|---|---|
| `struct simd_float4x4` | all | Conforms to BitwiseCopyable, Copyable, CustomDebugStringConvertible, Equatable, Escapable, Sendable. NOT Codable. Same for `simd_float3x3`. Its columns (`SIMD4<Float>`, `SIMD3<Float>`) are Codable. |
| `init(bytes: UnsafeRawPointer, count: Int)` (Data) | iOS 8.0 | Copies. |
| `init(bytesNoCopy bytes: UnsafeMutableRawPointer, count: Int, deallocator: Data.Deallocator)` | iOS 8.0 | Wraps without copying. |
| `func loadUnaligned<T>(fromByteOffset offset: Int = 0, as type: T.Type) -> T` on `UnsafeRawBufferPointer` | Swift 5.7 standard library; Apple's page lists iOS 8.0 (back-deploys) | Safe read of simd types from unaligned offsets. The Swift 6.2 SDK also shows an overload `where T : BitwiseCopyable`; call sites are the same. |
| `class func archivedData(withRootObject object: Any, requiringSecureCoding requiresSecureCoding: Bool) throws -> Data` | iOS 11.0 | For `ARWorldMap` (NSSecureCoding). |
| `@nonobjc static func unarchivedObject<DecodedObjectType>(ofClass cls: DecodedObjectType.Type, from data: Data) throws -> DecodedObjectType? where DecodedObjectType : NSObject, DecodedObjectType : NSCoding` | iOS 11.0 | Restore, then set `var initialWorldMap: ARWorldMap? { get set }` (iOS 12.0). |
| `func getCurrentWorldMap(completionHandler: @escaping @Sendable (ARWorldMap?, (any Error)?) -> Void)` / `func currentWorldMap() async throws -> ARWorldMap` | iOS 12.0 | Completion runs on the session's delegate queue. |
| `struct CapturedRoomData` (Decodable, Encodable, Sendable) | iOS 16.0 | Raw RoomPlan data can be saved as JSON and rebuilt later with `RoomBuilder`. |
| `func writeHEIFRepresentation(of image: CIImage, to url: URL, format: CIFormat, colorSpace: CGColorSpace, options: [CIImageRepresentationOption : Any] = [:]) throws` | iOS 11.0 | Keyframe encoding. Also `writeJPEGRepresentation` (iOS 10), `writePNGRepresentation` (iOS 11), `CIFormat.L16 / .Lh / .Lf`. |

##### Memory and thermal

```swift
extern size_t os_proc_available_memory();                // import os, iOS 13.0; returns 0 when already over the limit
var physicalMemory: UInt64 { get }                       // ProcessInfo
var recommendedMaxWorkingSetSize: UInt64 { get }         // MTLDevice, iOS 16.0
nonisolated class let didReceiveMemoryWarningNotification: NSNotification.Name  // UIApplication
var thermalState: ProcessInfo.ThermalState { get }       // iOS 11.0; cases nominal, fair, serious, critical
class let thermalStateDidChangeNotification: NSNotification.Name  // ProcessInfo, iOS 11.0
var isIdleTimerDisabled: Bool { get set }                // UIApplication, iOS 2.0
```

##### Photogrammetry limits relevant to storage and memory

```swift
static let limits: PhotogrammetrySession.Limits          // iOS 17.0
var maximumNumberOfInputImages: Int { get }              // Limits, iOS 17.0
var maximumInputImageDimension: Int { get }              // Limits, iOS 17.0
@MainActor var maximumNumberOfInputImages: Int { get }   // ObjectCaptureSession, iOS 17.0
var isOverCaptureEnabled: Bool                           // ObjectCaptureSession.Configuration, iOS 17.0
var checkpointDirectory: URL?                            // PhotogrammetrySession.Configuration, iOS 17.0
var checkpointDirectory: URL?                            // ObjectCaptureSession.Configuration, iOS 17.0
@MainActor func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())  // iOS 17.0
```

`PhotogrammetrySession.Request.Detail`: only `.reduced` exists on iOS (iOS 17.0). `.preview`, `.medium`, `.full`, `.raw` are macOS 12 / Mac Catalyst 15 only; `.custom` is macOS 14 / Mac Catalyst 17 only. Apple's tables give `.reduced` as under 50k triangles, about 10 MB file, 2048 x 2048 textures (about 42.7 MB texture memory at runtime), with diffuse, normal and ambient occlusion maps.

`PhotogrammetrySession.limits` holds device-specific hardware limits. Images over either limit are ignored and reported as invalid samples. `ObjectCaptureSession` stops capturing at `maximumNumberOfInputImages` unless `isOverCaptureEnabled` is true; the extra shots are then skipped for on-device reconstruction. `PhotogrammetrySession.Configuration` has no image-count field. `PhotogrammetrySession` can also take your own keyframes (with LiDAR depth and gravity) as `PhotogrammetrySample`s, so a textured room model is possible without `ObjectCaptureSession`. It is still bound by the image cap and `.reduced` output. For memory, prefer the directory-URL input.

##### Background execution

| Declaration | Introduced | Usable at 18.0 |
|---|---|---|
| `nonisolated func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier` | iOS 7.0 | Yes. About 30 s (Apple DTS forum figure, not documented). |
| `nonisolated var backgroundTimeRemaining: TimeInterval { get }` | iOS 4.0 | Yes. Do not build logic on it. |
| `class BGProcessingTask` / `class BGProcessingTaskRequest` (`requiresExternalPower`, `requiresNetworkConnectivity`) | iOS 13.0 | Yes, but idle-only. |
| `func register(forTaskWithIdentifier identifier: String, using queue: dispatch_queue_t?, launchHandler: @escaping (BGTask) -> Void) -> Bool` | iOS 13.0 | Yes. Register once, before launch finishes. |
| `class BGContinuedProcessingTaskRequest`, `init(identifier: String, title: String, subtitle: String)` | iOS 26.0 | No. Needs `#available(iOS 26, *)`. |
| `class BGContinuedProcessingTask` (ProgressReporting) | iOS 26.0 | No. Needs `#available(iOS 26, *)`. The system shows its progress in a Live Activity; the app only reports progress. |
| `class var supportedResources: BGContinuedProcessingTaskRequest.Resources { get }` (BGTaskScheduler) | iOS 26.0 | No. Needs `#available(iOS 26, *)`. |

##### Deprecations in the iOS 26 SDK

| Symbol | Status |
|---|---|
| SceneKit framework, `SCNView`, `SCNScene` | Deprecated at 26.0 on all platforms ("SceneKit is deprecated, use RealityKit instead"). |
| `ARSCNView` | Deprecated at iOS 26.0 ("Use RealityView instead"). |
| Model I/O (`MDLAsset`, `MDLMesh`, `export(to:)`, `canExportFileExtension(_:)`) | Not deprecated. |
| RealityKit `ARView`, `ModelEntity` | Not deprecated. |

##### Threading facts

- `var delegateQueue: dispatch_queue_t? { get set }` (ARSession, iOS 11.0): if nil, delegate methods run on the main queue.
- `ObjectCaptureSession` is a `@MainActor` class; every call and state read must be on the main actor.
- `PhotogrammetrySession` is not main-actor isolated; `outputs` is an AsyncSequence iterated in a Task.
- In the iOS 26 SDK, `ARFrame` is marked Sendable, but `CVPixelBuffer` (a typealias of `CVBuffer`) is not. Sendable does not make retaining frames safe (see Gotcha 3). `ARMeshAnchor` is NSSecureCoding and Sendable.

#### Gotchas

1. Actor-isolation errors fail the build even in Swift 5 mode. Minimal checking only turns missing Sendable conformances and missing global-actor annotations into warnings. Calling a `@MainActor` function synchronously from a nonisolated context, a missing `await`, or cross-actor mutation are hard errors since Swift 5.5.
2. Do not set `SWIFT_VERSION: 6` or `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. ARKit and RoomPlan delegate protocols are nonisolated ObjC protocols. A main-actor default makes their conformances fail ("main actor-isolated instance method cannot satisfy nonisolated requirement"). Do not mark a delegate class `@MainActor` when its `delegateQueue` is a background queue; Swift 6.2 runtime isolation checks can trap.
3. Never retain `ARFrame`s past the delegate callback. ARKit warns above about 10 retained frames and the camera feed freezes at about 15 to 20 (Apple forum figures). Copy pixel buffers, poses and mesh bytes out first.
4. Copy mesh data off the `MTLBuffer` inside the callback. ARKit vertices are packed float3 at stride 12, but Swift `SIMD3<Float>` has size and stride 16. Always read `stride`, `offset` and `format` from `ARGeometrySource` and never assume.
5. `simd_float4x4` and `simd_float3x3` are not Codable. JSON needs a wrapper.
6. On iOS, Object Capture output is fixed at `.reduced`. Naming `.medium` or `.full` in iOS code is a compile error (macOS-only availability).
7. `ObjectCaptureSession.start(imagesDirectory:configuration:)` and checkpoint folders must be empty. Reusing them sends the session to `.failed`. Use one fresh UUID folder per capture, and keep each checkpoint folder paired with exactly one images folder.
8. `isExcludedFromBackup` resets to false after common operations such as an atomic directory replace. Apple says to set it each time you save and not to use it on user documents. Re-apply on `raw/` after every write batch.
9. With file sharing on, every file in `Documents/` is visible and deletable in Files and Finder, including half-written chunks. Write to a temp name in the same folder and rename, or build in-progress scans outside `Documents/` and move them in when done.
10. `Library/Caches` is never backed up and can be purged under storage pressure. Use it only for data you can regenerate.
11. Do not use `.complete` file protection on scan data. A write from an expiring background task while the phone is locked would fail.
12. `BGProcessingTask` is useless for user-facing work: it runs only when the device is idle and is killed when the user picks up the phone. `beginBackgroundTask` gives about 30 s. On iOS 18, heavy processing must happen in the foreground.
13. iOS refuses GPU command submission from the background. Apple DTS says background GPU through `BGContinuedProcessingTask` works only on M3-or-newer iPads, on no iPhone. So Metal and photogrammetry stay foreground on any iOS version on these phones.
14. Registering the same BGTask identifier twice kills the app.
15. Sideloadly rewrites the bundle id to `<bundleId>.<TEAMID>`. Never compare `Bundle.main.bundleIdentifier` to the plain id. App groups and keychain access groups tied to the id break. UTIs and BGTask identifiers are free strings and are unaffected.
16. Free Apple ID limits: 3 sideloaded apps active per device, apps stop launching after 7 days, 10 new App IDs per rolling 7 days. An app extension counts as another App ID; keep Mapper to one target. Reinstalling the same bundle id, or installing it on a second device, does not use a new App ID.
17. Developer Mode must be enabled on each phone (Settings > Privacy & Security, restart, then confirm with passcode). The toggle only appears after pairing or an install attempt.
18. Do not ship an entitlements file with paid-only keys. A mismatch between binary entitlements and the profile can make the install fail.
19. SceneKit and `ARSCNView` compile with deprecation warnings at most. With the iOS 18.0 deployment target the warnings may not fire at all (verifier view, not checked on CI). The CI must not turn on `SWIFT_TREAT_WARNINGS_AS_ERRORS`.
20. ARKit's 256 x 192 depth size and 1920 x 1440 default camera size are not in Apple's doc JSON. Read them at runtime.
21. Keep USD export file names starting with a letter. Before iOS 17.4 a leading digit broke RoomPlan export; not an issue on iOS 18 but cheap to respect.

#### Recommended approach

**project.yml and Info.plist.** Keep the current spec: `SWIFT_VERSION: "5.9"` (Swift 5 mode), `TARGETED_DEVICE_FAMILY: "1"`, iOS 18.0 deployment target, no signing in CI. Add `SWIFT_STRICT_CONCURRENCY: targeted` for useful warnings without new errors. Do not add `SWIFT_DEFAULT_ACTOR_ISOLATION` or `SWIFT_APPROACHABLE_CONCURRENCY`. Info.plist keeps `NSCameraUsageDescription`, `UIRequiredDeviceCapabilities: [arkit]` (optionally add `arm64`, `metal`), `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, portrait only, `UILaunchScreen: {}`, `ITSAppUsesNonExemptEncryption: false`, `NSLocalNetworkUsageDescription` for the debug server. Add the `.mapperproj` `UTExportedTypeDeclarations` and `CFBundleDocumentTypes` blocks above. `NSPhotoLibraryAddUsageDescription` is already present; keep it only if a "Save to Photos" feature ships. No entitlements file. No `UIBackgroundModes` in v1.

**Launch probe.** Log `RoomCaptureSession.isSupported`, `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`, `ObjectCaptureSession.isSupported` (on the main actor), `PhotogrammetrySession.isSupported`, `os_proc_available_memory()`, `ProcessInfo.processInfo.physicalMemory`, `MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize`, `PhotogrammetrySession.limits.maximumNumberOfInputImages` and `.maximumInputImageDimension`. On the first scan, also log `ARCamera.imageResolution` and the depth map width and height.

**Storage layout.** One package folder per project:

```
Documents/Projects/<uuid>.mapperproj/
  project.json                 Codable, with schemaVersion
  raw/                         isExcludedFromBackup = true, re-applied after each write batch
    worldmap.arworldmap        NSKeyedArchiver, secure coding; strip ARMeshAnchors from anchors first
    mesh/<anchorUUID>.mchunk   16-byte header + packed float3 vertices, float3 normals, uint32 faces, uint8 classes
    keyframes/<index>.heic     CIContext.writeHEIFRepresentation, quality 0.8
    depth/<index>.f16          Float16 depth; <index>.conf UInt8 confidence
    poses.json                 [{index, timestamp, transform:[16 Float], intrinsics:[9 Float], imageSize}]
    room.capturedroomdata.json CapturedRoomData (Codable)
    objects/<id>/Images/       ObjectCaptureSession images folder (fresh, empty at start)
    objects/<id>/Snapshots/    checkpoint folder paired with that Images folder
  derived/                     backed up
    textured.usdz, raw_mesh.obj or .usdz, clean.usdz, floorplan.json, floorplan.pdf, measurements.json
```

Build in-progress scans with temp-name-then-rename writes so the Files app never shows half files. Offer "Delete raw data" once derived outputs exist.

**Serialization.** Codable JSON for small records. A wrapper such as `struct Transform4: Codable { var m: [Float] }` (16 values, column-major) with conversions to and from `simd_float4x4`, and a 9-value wrapper for intrinsics. Raw little-endian binary for mesh, depth and confidence, with a small header (magic, version UInt16, count UInt32, stride UInt16) and reads through `loadUnaligned`. No SQLite and no binary plist; the volume is images and blobs, not records.

**Storage budget.** Estimate for a 5-minute room scan at about 1 keyframe per second (300 frames): keyframes HEIC 90 to 150 MB; depth Float16 about 30 MB plus confidence about 15 MB; poses under 1 MB; final mesh 15 to 40 MB; world map 5 to 30 MB; derived outputs about 12 MB. Total about 200 to 350 MB per room, several GB for a 20-room house. Check `volumeAvailableCapacityForImportantUsage` before a scan and refuse to start below about 1 GB free.

**Memory.** Plan for a working set under about 1.5 GB during scanning and about 2.5 GB peak during reconstruction, until the real ceiling is measured. Keep only the latest geometry per mesh anchor id in RAM and flush to disk on a serial IO queue. Throttle keyframes to about 1 fps or on pose change (over 0.3 m or 15 degrees). Stay on the default video format (reported as 1920 x 1440); 4K (iOS 16+, A15+, from WWDC22) quadruples image size. If photogrammetry trips memory warnings, downsample keyframes (for example to 1440 x 1080). Feed `PhotogrammetrySession` a directory URL, not an in-memory sample array. Pause capture on `.serious` or `.critical` thermal state and on memory warnings.

**Concurrency.** ARSession delegate on a dedicated serial queue, in a plain nonisolated `final class` conforming to `ARSessionDelegate`. Inside callbacks, copy out `Data` and simd values, then hop to the main actor with `Task { @MainActor in ... }` carrying only Sendable values. `@MainActor` only on SwiftUI views, observable view models and anything that touches `ObjectCaptureSession`. Store the Task that iterates `PhotogrammetrySession.outputs` so it is not cancelled. Do the world map archiving off the delegate queue.

**Processing.** Run in the foreground with `UIApplication.shared.isIdleTimerDisabled = true` and a progress UI fed by `PhotogrammetrySession.outputs`. Persist a checkpoint directory so a jetsam kill can resume. On the later iOS 26 phone, an optional `#available(iOS 26, *)` path can submit a `BGContinuedProcessingTaskRequest` from a user action, CPU only. Do not request the GPU resource.

**Rendering choice forced by this topic.** Use RealityKit (`ARView`, iOS 13.0; `RealityView`, iOS 18.0, both `@MainActor`) or Metal for display. Use Model I/O only for OBJ and USD export. Do not use SceneKit or `ARSCNView`.

**Deployment.** Keep `com.shreehub.mapper` stable across weekly re-sideloads so the app container and `Documents/Projects` survive. Keep one app target. Document per-device Developer Mode in the runbook. A second phone under the same free Apple ID is fine.

#### Disputed or unsure

**1. "Actor-isolation problems are at most warnings in Swift 5 mode and will not fail CI."**
Researcher: XcodeGen defaults to Swift 5 and minimal checking, so isolation problems are warnings only. Verifiers (both lenses): refuted. Minimal checking only downgrades missing Sendable conformances and missing global-actor annotations (SE-0337). Core isolation rules (SE-0306, Swift 5.5) are errors in every language mode. The verifiers cite the proposals and the swift.org migration guide, which is stronger than the researcher's inference. Also, this repo sets `SWIFT_VERSION: "5.9"`, not XcodeGen's `5.0` default; both are Swift 5 mode. Final ruling: refuted in part. Swift 5 mode is correct and should stay, but code must be written isolation-correct because violations fail the build. The claim that Xcode 26 only changes new templates (not XcodeGen projects) is plausible but no primary source was fetched; treat as unverified.

**2. `.reduced` texture size.**
Researcher: diffuse, AO and normal maps, about 10 MB. One verifier: 2048 x 2048. The other: 1024 x 1024. I fetched the Detail doc JSON: the texture table says `.preview` 1024 x 1024 and `.reduced` 2048 x 2048 (42.7 MB texture memory). Final ruling: 2048 x 2048. The second verifier read the `.preview` row.

**3. `.custom` detail availability.**
Researcher: macOS 14 only. Verifier: also Mac Catalyst 17. Final ruling: Mac Catalyst 17 is also listed, but neither is iOS, so the conclusion stands.

**4. Free Apple ID limits (3 apps, 7 days, 10 App IDs per week).**
Researcher quoted the Sideloadly FAQ. Verifiers could not reach that site but confirmed the numbers from an Apple forum thread and SideStore sources, and confirmed Developer Mode steps from Apple's page. Final ruling: accepted, likely. Per-device limit is undocumented (one source says 3 devices per 7 days); irrelevant for two phones.

**5. Can a free-team profile carry `com.apple.developer.kernel.increased-memory-limit`?**
Researcher: almost certainly not. Verifier: Xcode Personal Team builds keep it and AltStore requests it for free accounts, but SideStore 0.7.0 drops it, and no evidence exists either way for Sideloadly. Apple's free-account capabilities table lists only "Increased Debugging Memory Limit" and "Extended Virtual Addressing", not this entitlement. Apple also says it raises the limit only on some devices. The verifier has more concrete evidence, but nothing specific to Sideloadly. Final ruling: unknown for this toolchain. Do not depend on it. A later experiment can sign with it, inspect the embedded profile, and compare `os_proc_available_memory()`.

**6. Jetsam memory ceiling on the 6 GB iPhone 13 Pro Max.**
Researcher: about 3 to 3.3 GB, extrapolated from 2.2 to 2.3 GB reported on a 4 GB iPhone 13. Verifier: no authoritative figure. That 4 GB report was taken with the increased-memory-limit entitlement, so it is not a default baseline. 4 GB iPhone 12 logs show "ActiveHard 2098 MB". Folklore for 6 GB phones is 2.8 to 3.0 GB. The SideStore 3.3 GB figure is from an unknown, probably larger device. The verifier's data points are more concrete, but none is for this phone. Final ruling: unsure. Budget about 2.5 GB peak and measure on device.

**7. Depth 256 x 192 and camera 1920 x 1440.**
Community and WWDC numbers, not in Apple's doc JSON; no verifier settled them. Final ruling: unsure. Read at runtime, never hardcode.

**8. `PhotogrammetrySession.limits.maximumNumberOfInputImages` on A15.**
The property is verified (iOS 17.0). No reliable number for A15 6 GB devices (one unconfirmed source says about 1000). Final ruling: read and log at runtime.

**9. `beginBackgroundTask` duration.**
About 30 s is from Apple DTS on the forums, not the docs. Final ruling: accepted as a rough figure; design as if it could be shorter.

**10. Size estimates (keyframes 300 to 500 KB HEIC, HEIC encode 20 to 40 ms, world map 5 to 30 MB, 200 to 350 MB per room).**
Computed from verified formats plus community photo sizes. Final ruling: likely; confirm on device.

### 3.10 UX patterns

Scope: how the scan, review, processing and result screens should look and behave for an amateur user, and which Apple UI building blocks provide that. Room and house scanning use RoomPlan, object scanning uses RealityKit Object Capture, raw mesh mode uses ARKit plus RealityKit. Declarations below come from the Apple documentation JSON. Nothing in this topic needs a paid entitlement. Nothing needs iOS 26. The newest APIs here are iOS 18.0, which matches our deployment target, so no `#available` checks are required for anything listed here.

#### Verified API

**RoomPlan scan UI (UIKit, wrap in `UIViewRepresentable`)**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor @objc @preconcurrency class RoomCaptureView` (subclass of `UIView`) | 16.0 | yes |
| `@MainActor @preconcurrency override dynamic init(frame: CGRect)` | 16.0 | yes |
| `@MainActor @preconcurrency init(frame: CGRect, arSession: ARSession)` | 17.0 | yes |
| `@MainActor @preconcurrency var captureSession: RoomCaptureSession! { get }` (read-only, never assign) | 16.0 | yes |
| `@MainActor @preconcurrency weak var delegate: (any RoomCaptureViewDelegate)?` (weak, keep the coordinator alive) | 16.0 | yes |
| `@MainActor @preconcurrency var isModelEnabled: Bool { get set }` (mini 3D model at the bottom) | 16.0 | yes |
| `protocol RoomCaptureViewDelegate : NSCoding` | 16.0 | yes |
| `func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool` | 16.0 | yes |
| `func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?)` | 16.0 | yes |

What the view does by itself: camera feed, animated outlines on detected walls, doors, windows, openings and objects, coaching text, and the mini model. After `captureSession.stop()`, if `shouldPresent` returns `true` (the default), the framework post-processes, calls `didPresent`, and the view shows the final room as a 3D model the user can inspect with touch. The view has no Done, Cancel or Export button. The app supplies them.

**RoomPlan session and guidance**

```swift
// RoomCaptureSession (iOS 16.0 unless noted)
init()
init(arSession: ARSession? = nil)             // iOS 17.0
static var isSupported: Bool { get }
func run(configuration: RoomCaptureSession.Configuration)
func stop()
func stop(pauseARSession: Bool = true)        // iOS 17.0
weak var delegate: (any RoomCaptureSessionDelegate)?
var arSession: ARSession                      // doc JSON shows no setter; treat as read-only
struct Configuration { init(); var isCoachingEnabled: Bool }   // default true

// RoomCaptureSessionDelegate (all methods optional via default implementations)
func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration)
func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?)
```

| Enum | Cases (from doc JSON) | iOS |
|---|---|---|
| `RoomCaptureSession.Instruction` (Equatable, Hashable) | `normal`, `moveCloseToWall`, `moveAwayFromWall`, `turnOnLight`, `slowDown`, `lowTexture` | 16.0 |
| `RoomCaptureSession.CaptureError` (Error, LocalizedError, Equatable, Hashable) | `deviceNotSupported`, `deviceTooHot`, `exceedSceneSizeLimit`, `invalidARConfiguration`, `worldTrackingFailure`, `internalError` | 16.0 |
| `CapturedRoom.Section.Label` | `livingRoom`, `kitchen`, `diningRoom`, `bedroom`, `bathroom`, `unidentified` | 17.0 |

**House mode (multi-room)**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `class StructureBuilder` | 17.0 | yes |
| `init(options: StructureBuilder.ConfigurationOptions)` (`ConfigurationOptions` is a typealias for `RoomBuilder.ConfigurationOptions`; option `static let beautifyObjects`, iOS 16.0) | 17.0 | yes |
| `func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure` | 17.0 | yes |
| `enum BuildError` (nested in `StructureBuilder`; thrown when the merge fails) | 17.0 | yes |
| `CapturedStructure` (Codable; rooms, walls, doors, windows, openings, floors, objects, sections) | 17.0 | yes |

`CapturedRoom` is `Codable` and `Sendable` (iOS 16.0). Export: `func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (iOS 16.0) and `export(to:metadataURL:modelProvider:exportOptions:)` with defaults `nil, nil, .mesh` (iOS 17.0). `USDExportOptions` has exactly `.parametric`, `.mesh`, `.model` (no `.all`). The detailed surface, object and export API belongs to the RoomPlan and export sections; here it matters only that the result screen can offer Clean (`.parametric`) and Mesh (`.mesh`) views.

**Object Capture UI (native SwiftUI)**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor @preconcurrency struct ObjectCaptureView<Overlay> where Overlay : View` | 17.0 | yes |
| `nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView` | 17.0 | yes |
| `nonisolated init(session: ObjectCaptureSession, @ViewBuilder cameraFeedOverlay: () -> Overlay)` | 17.0 | yes |
| `@MainActor @preconcurrency func hideObjectReticle(_ value: Bool = true) -> ObjectCaptureView<Overlay>` | **18.0** | yes |
| `@MainActor struct ObjectCapturePointCloudView` (turntable review), `@MainActor init(session: ObjectCaptureSession)` | 17.0 | yes |
| `@MainActor func showShotLocations(_ value: Bool = true) -> ObjectCapturePointCloudView` | **18.0** | yes |

```swift
@MainActor class ObjectCaptureSession   // iOS 17.0, Observable, Identifiable, Sendable; every member below is @MainActor
init()
static var isSupported: Bool { get }
func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())
func startDetecting() -> Bool
func startCapturing()
@discardableResult func resetDetection() -> Bool
func beginNewScanPass()
func beginNewScanPassAfterFlip()
func requestImageCapture()
func pause(); func resume(); func finish(); func cancel()
var state: ObjectCaptureSession.CaptureState { get }   // initializing, ready, detecting, capturing, finishing, completed, failed(_)
var feedback: Set<ObjectCaptureSession.Feedback> { get }
var cameraTracking: ObjectCaptureSession.Tracking { get }   // Equatable; normal, limited(reason:), notAvailable
var userCompletedScanPass: Bool { get }
var numberOfShotsTaken: Int { get }
var maximumNumberOfInputImages: Int { get }
var canRequestImageCapture: Bool { get }
var isPaused: Bool { get }
var isAutoCaptureEnabled: Bool { get set }       // iOS 18.0
var shouldPlayHaptics: Bool { get set }          // iOS 18.0
// Streams of type ObjectCaptureSession.Updates<T> (all { get }, iOS 17.0): stateUpdates, feedbackUpdates, cameraTrackingUpdates,
// userCompletedScanPassUpdates, numberOfShotsTakenUpdates, isPausedUpdates, canRequestImageCaptureUpdates
struct Configuration { init(); var checkpointDirectory: URL?; var isOverCaptureEnabled: Bool }
```

`ObjectCaptureSession.Feedback` cases: `objectTooFar`, `objectTooClose`, `environmentTooDark`, `environmentLowLight`, `movingTooFast`, `outOfFieldOfView`, `objectNotDetected` (iOS 17.4), `objectNotFlippable`, `overCapturing`. All others are iOS 17.0. The enum is Equatable and Hashable.

On-device reconstruction: `PhotogrammetrySession.Request.Detail` exists on iOS 17.0, but only `.reduced` is available on iOS (under 50k triangles, 2048 x 2048 diffuse, normal and AO maps, about 10 MB). `.preview`, `.medium`, `.full`, `.raw` are macOS 12.0 / Mac Catalyst 15.0 only, and `.custom` is macOS 14.0 / Mac Catalyst 17.0 only. `case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced, geometry: PhotogrammetrySession.Request.Geometry? = nil)` defaults to `.reduced`.

**Raw mesh and tracking UI (ARKit, RealityKit)**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `static let showSceneUnderstanding: ARView.DebugOptions` (depth-colored wireframe) | 13.4 | yes |
| `ARMeshGeometry` `vertices`, `normals`, `faces`, `var classification: ARGeometrySource? { get }` | 13.4 | yes |
| `class ARCoachingOverlayView` (`goal`, `activatesAutomatically`, `setActive(_:animated:)`, delegate incl. `coachingOverlayViewDidRequestSessionReset(_:)`) | 13.0 | yes |
| `func currentWorldMap() async throws -> ARWorldMap` (async form of `getCurrentWorldMap(completionHandler:)`, documented on that page) | 12.0 | yes |
| `var worldMappingStatus: ARFrame.WorldMappingStatus { get }` on `ARFrame` (cases `notAvailable`, `limited`, `extending`, `mapped`; wait for `.mapped` before saving a world map) | 12.0 | yes |

**SwiftUI and UIKit plumbing**

| Declaration | iOS | OK at 18.0 |
|---|---|---|
| `@MainActor @preconcurrency protocol UIViewRepresentable : View where Self.Body == Never` (`makeUIView(context:)`, `updateUIView(_:context:)`, `makeCoordinator()`, `static func dismantleUIView(_ uiView: Self.UIViewType, coordinator: Self.Coordinator)`) | 13.0 | yes |
| `NavigationStack` with `init(path:root:)` (path is `Binding<Data>`, Data a mutable, random-access, range-replaceable collection of Hashable) and `.navigationDestination(for:destination:)` | 16.0 | yes |
| `nonisolated struct ShareLink<Data, PreviewImage, PreviewIcon, Label>` where `Data : RandomAccessCollection`, `Data.Element : Transferable` (inits `item:subject:message:`, `items:subject:message:`, with `preview:` and `label:` variants) | 16.0 | yes |
| `nonisolated func sensoryFeedback<T>(_ feedback: SensoryFeedback, trigger: T) -> some View where T : Equatable` | 17.0 | yes |
| `SensoryFeedback` cases include `.success`, `.warning`, `.error`, `.selection`, `.impact(weight: SensoryFeedback.Weight = .medium, intensity: Double = 1.0)`, `.start`, `.stop`, `.alignment` | 17.0 | yes |
| `convenience init(style: UIImpactFeedbackGenerator.FeedbackStyle, view: UIView)` | **17.5** | yes |
| `init(style: UIImpactFeedbackGenerator.FeedbackStyle)` (doc JSON: deprecated at iOS 27.0) | 10.0 | yes, avoid |
| `var isIdleTimerDisabled: Bool { get set }` on `UIApplication` | 2.0 | yes |
| `nonisolated func persistentSystemOverlays(_ visibility: Visibility) -> some View` | 16.0 | yes |
| `func requestGeometryUpdate(_ geometryPreferences: UIWindowScene.GeometryPreferences, errorHandler: ((any Error) -> Void)? = nil)` | 16.0 | yes |
| `func setNeedsUpdateOfSupportedInterfaceOrientations()` on `UIViewController` | 16.0 | yes |
| `optional func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask` (doc JSON: deprecated at iOS 27.0) | 6.0 | yes |
| `@propertyWrapper struct ScaledMetric<Value> where Value : BinaryFloatingPoint` | 14.0 | yes |
| `DynamicTypeSize`, `func dynamicTypeSize(_ size: DynamicTypeSize) -> some View`, and the range form `func dynamicTypeSize<T>(_ range: T) -> some View where T : RangeExpression, T.Bound == DynamicTypeSize` | 15.0 | yes |
| `var measurementSystem: Locale.MeasurementSystem { get }` on `Locale` | 16.0 | yes |
| `struct MeasurementFormatUnitUsage<UnitType> where UnitType : Dimension` (`.asProvided`, `.general`, `.personHeight`, `.road`, ...) | 15.0 | yes |

#### Gotchas

1. `RoomCaptureViewDelegate` inherits `NSCoding`. The SwiftUI coordinator must be `class Coordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate` with `func encode(with coder: NSCoder) {}` and `required init?(coder: NSCoder)`, plus a normal `init`. Without these the conformance does not compile.
2. `RoomCaptureView.delegate` is `weak`. If nothing else holds the coordinator it disappears. SwiftUI's `context.coordinator` keeps it alive for the view's lifetime, so use that.
3. `captureSession` on `RoomCaptureView` is get-only. To share one ARSession across rooms, pass it via `init(frame:arSession:)` (iOS 17.0).
4. Create `RoomCaptureView` once in `makeUIView`. Recreating it in `updateUIView` restarts the scan. Drive run and stop through the coordinator; call `captureSession.stop()` in `dismantleUIView`.
5. Delegate methods with near-miss labels silently become ordinary methods (defaulted requirement). Copy the labels exactly from the Verified API block.
6. `RoomCaptureView` always draws its own coaching text. You cannot hide it and still receive `didProvide instruction` callbacks (instructions stop when `isCoachingEnabled` is false). If we also show our own banner in room mode we get duplicate prompts. Either trust the built-in coaching or build a custom view on `RoomCaptureSession`.
7. `Instruction`, `Feedback`, `CaptureError` and `Section.Label` are not frozen. Every `switch` needs `@unknown default` (or `default`).
8. RoomPlan objects are category plus bounding box. There is no per-object mesh, so object editing is box based (move, rotate, resize, delete, rename).
9. `StructureBuilder` only merges rooms that share a world space: same ARSession with `stop(pauseARSession: false)`, or relocalization from a saved `ARWorldMap`. Forum threads 743184 and 784052 report `EXC_BAD_ACCESS` crashes and errors on some merges (possibly walls with more than 4 edges). They also say the merge ignores edits made to `CapturedRoom` values. These reports were seen only through search summaries. Catch `StructureBuilder.BuildError`, but note that a crash cannot be caught. Save each `CapturedRoom` as JSON before merging and treat the merged structure as optional.
10. WWDC23 sample code writes `StructureBuilder(option: [.beautifyObjects])`. The documented label is `init(options:)`. Use `options:`.
11. `hideObjectReticle(_:)` is a modifier on `ObjectCaptureView`, not a session method, and is iOS 18.0. Same for `showShotLocations(_:)`, `isAutoCaptureEnabled` and `shouldPlayHaptics`.
12. `ObjectCaptureSession.start(imagesDirectory:configuration:)` may be called once per session. `imagesDirectory` must be empty and writable. A non-empty `checkpointDirectory` sends the session to `.failed`. Use fresh UUID folders per scan. Apple's sample reuses the same checkpoint folder as `PhotogrammetrySession.Configuration.checkpointDirectory` to speed up reconstruction. Auto capture stops at `maximumNumberOfInputImages` unless `isOverCaptureEnabled` is true.
13. Removing `ObjectCaptureView` and recreating it with the same session resumes capture (documented), but a forum report says each appear and disappear cycle can leak about 250 to 500 MB. On a 6 GB A15 phone, avoid tearing it down repeatedly. Prefer blurring it or covering it with a sheet. The `pause()` doc says to call it whenever the capture view is not visible (for example a help screen); call `resume()` when it shows again. The leak report is from 2023 and needs measuring on iOS 18.
14. When `cameraTracking != .normal`, ObjectCaptureView shows ARKit's coaching overlay by itself. Hide our overlay buttons during that time, as Apple's sample does. The sample also hides them while help or the preview is shown and while the session is paused.
15. Only `.reduced` photogrammetry on iOS. `.medium` and above are marked unavailable in the iOS SDK and will not compile for iOS.
16. `showSceneUnderstanding` shows nothing unless the session runs with `sceneReconstruction` set, and its colors are depth only and not customizable. Coverage coloring needs our own mesh from `ARMeshAnchor.geometry`. Mesh faces are re-meshed without stable IDs, so key coverage state spatially (voxel grid), not by face index.
17. `UIImpactFeedbackGenerator.init(style:)` is marked deprecated at iOS 27.0 in the doc JSON; the replacement `init(style:view:)` is iOS 17.5. Prefer SwiftUI `.sensoryFeedback` (iOS 17.0) and the existing `DeviceFeatures` haptics helper.
18. `application(_:supportedInterfaceOrientationsFor:)` is also marked deprecated at iOS 27.0. It still works on iOS 18 and 26; only use it if we add per-screen orientation.
19. SwiftUI has no per-view orientation lock. Forced rotation on iOS 18 can re-render the SwiftUI tree and reset `@State`. Keep scan state in an observable model owned above the view.
20. Foundation formats feet and inches but not fractional inches. The fraction and sq ft strings come from our own `ios/Sources/Units/` module.
21. `NSCameraUsageDescription` must be in Info.plist or the app crashes on first camera use (already set in `ios/project.yml`).
22. Large open areas trigger `CaptureError.exceedSceneSizeLimit`. House mode must be room by room.
23. Competitor details (Polycam, Scaniverse) came from search snippets and a third-party review because their help pages returned 403. Treat exact label names as approximate.
24. `ObjectCaptureSession` needs LiDAR plus an A14 or later chip (forum thread 734086). The A15 test device qualifies. Area mode guidance from Apple's sample: areas larger than 6 feet may lose mesh and texture quality unless processed at a higher detail level on a Mac.

#### Recommended approach

**Screen map.** Home (project grid with thumbnails, one big "New scan" button) then Mode sheet (Room, House, Object, each with icon and one line) then Tips sheet, once per mode, with "Don't show again" then Capture then Review then Processing then Result. Use `NavigationStack(path:)` with a typed route enum for Home to Project to Result. Present capture as `.fullScreenCover`. This matches Apple's RoomPlan sample (Start Scanning, then capture with Cancel and Done, then Export) and what Polycam, Scaniverse and magicplan converge on.

**Unsupported devices.** Check `RoomCaptureSession.isSupported` and `ObjectCaptureSession.isSupported` at launch (the capability probe already does). Hide or disable modes that fail, with a plain "This iPhone has no LiDAR" style screen from `Copy.swift`, as Apple's sample does with its UnsupportedDevice scene.

**Synthesis note.** The RoomPlan section recommends a headless `RoomCaptureSession` with Mapper's own UI, and this section recommends `RoomCaptureView`. The spec requires a live green, yellow, red and gray coverage overlay while scanning, which `RoomCaptureView` cannot host. The ruling (see "Cross-section rulings" at the top) is: headless `RoomCaptureSession` is the target; `RoomCaptureView(frame:arSession:)` is the fallback if the device test shows depth or mesh cannot be kept alive on the headless path. The guidance below still applies whenever `RoomCaptureView` is used.

**Room mode (RoomCaptureView fallback).** Use `RoomCaptureView` in a `UIViewRepresentable`, not a custom session UI. It already gives outlines, coaching and the mini model users expect. App chrome: Cancel top-left, Done top-right. First Done calls `captureSession.stop()`; return `true` from `shouldPresent`, so the view animates the final room. Then show "Keep" and "Rescan". Save `CapturedRoom` as JSON in `didPresent` right away. Do not add a second guidance banner in room mode (see Gotcha 6); only show our own banner for `CaptureError` and thermal warnings. Map errors to `Copy.swift` strings: `deviceTooHot` "Phone is too hot. Let it cool for a minute.", `exceedSceneSizeLimit` "This scan got too large. Finish this room and start the next one.", `worldTrackingFailure` "Lost tracking. Point at the last wall you scanned."

Room tips from WWDC22 (session 10127) for the Tips sheet. One room up to about 30 x 30 ft (9 x 9 m). Light of 50 lux or more, curtains open. Close doors to other rooms. Avoid full-height mirrors and glass, very dark surfaces and very high ceilings. Keep each scan under 5 minutes (battery and heat).

**House mode.** The app creates one `ARSession` and passes it to `RoomCaptureView(frame:arSession:)`. Between rooms call `captureSession.stop(pauseARSession: false)`, then `run(configuration:)` again on the same session object. Loop "Next room" / "Finish house". At the end run `try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)` with a spinner. Catch `StructureBuilder.BuildError` and fall back to the per-room list. A crash cannot be caught, so every room must already be saved as JSON; on the next launch, show the saved rooms and offer the merge again. For rooms scanned at different times, save an `ARWorldMap` (after `worldMappingStatus` reaches `.mapped`) and relocalize with `ARWorldTrackingConfiguration.initialWorldMap` before the next room. Onboarding copy: "Scan one room at a time." "Start each room in the doorway you just came through." "Keep the camera pointed at the walls while you walk between rooms." "Best for one floor, up to about 2,000 sq ft." Use `Section.Label` (six cases) only as a suggested room name; let the user rename.

**Object mode.** Copy Apple's GuidedCapture state machine. Ready: Continue calls `startDetecting()`. Detecting: Reset Box calls `resetDetection()`, Start Capture calls `startCapturing()`. Capturing: shot counter `numberOfShotsTaken`/`maximumNumberOfInputImages`, manual shutter enabled by `canRequestImageCapture`. When `userCompletedScanPass` is true, Next opens a review sheet with `ObjectCapturePointCloudView`, orbit 1/2/3 and flip logic (`beginNewScanPassAfterFlip()` or `beginNewScanPass()`). Finish calls `finish()` and shows a spinner while `.finishing`. Reconstruction then runs at `.reduced`. Build the view as `ZStack { ObjectCaptureView(session:cameraFeedOverlay:).blur(...) ; overlay }` and use sheets for help and review. Area mode (large objects, surfaces) skips `startDetecting()`, calls `startCapturing()` directly, applies `.hideObjectReticle(true)`, and sets `PhotogrammetrySession.Configuration.isObjectMaskingEnabled = false` (iOS 17.0) for reconstruction. Adapt Apple's tested onboarding strings into `Copy.swift` (for example "Keep moving around your object.", "Flip object on its side and capture again.", "All segments complete. Tap Finish to process your object."). Help page: matte, textured, opaque objects scan best; avoid shiny and transparent ones; object larger than 3 in (8 cm).

**Guidance banner rules (object and mesh modes).** One message at a time, imperative verb first, 2 to 6 words. Bold white on a translucent dark pill, top center under the nav bar. At least 2.0 s on screen, replaced not stacked; re-adding the same message resets its timer. Hidden when all is well. Map `Feedback` cases to fixed strings: tooFar "Move closer", tooClose "Move farther away", tooDark and lowLight "More light required", movingTooFast "Move slower", outOfFieldOfView "Aim at your object", objectNotDetected "Can't find your object", objectNotFlippable offers "Flip object anyway" or continue without flipping (as Apple's sample does), overCapturing turns the counter red. The priority order and final wording live in `docs/UX_COPY.md`.

**Raw mesh mode.** Custom `ARView` with `automaticallyConfigureSession = false`, `ARWorldTrackingConfiguration` with `.meshWithClassification`, and `ARCoachingOverlayView` with goal `.tracking`. Use `showSceneUnderstanding` only as a debug toggle. For users, tint our own per-anchor mesh by coverage (fresh translucent red or orange, confirmed green or white), which matches what Scaniverse, magicplan and Canvas users already know. This is also the base for the spec's "Show missing areas".

**Capture screen basics.** Portrait only for v1: set `UISupportedInterfaceOrientations` to portrait in `project.yml` (Apple's Object Capture sample does the same, and RoomCaptureView landscape is untested). Force the HUD dark with `.environment(\.colorScheme, .dark)`; lists and settings follow the system. Set `UIApplication.shared.isIdleTimerDisabled = true` on appear of capture and processing screens and `false` on disappear. `.persistentSystemOverlays(.hidden)` on capture. System text styles everywhere; `@ScaledMetric` for paddings and icon sizes; clamp the AR HUD with `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)`. Every icon-only button gets `.accessibilityLabel`.

**Haptics.** Sparing: `.sensoryFeedback(.success, trigger:)` on scan finished, `.warning` on tracking loss or error, `.selection` on a measurement snap, a light impact when the first wall is detected. Never on every `didUpdate`. Object mode: `ObjectCaptureSession` plays its own haptics (`shouldPlayHaptics`, iOS 18.0), so do not add ours on top during object capture.

**Processing screen.** `ProgressView` with fraction, stage text and estimated remaining time from `PhotogrammetrySession` outputs: `case requestProgress(PhotogrammetrySession.Request, fractionComplete: Double)` and `case requestProgressInfo(PhotogrammetrySession.Request, PhotogrammetrySession.Output.ProgressInfo)` (both iOS 17.0; `ProgressInfo` has `estimatedRemainingTime` and `processingStage`). Also handle the other output cases Apple's sample handles: `inputComplete`, `requestComplete`, `requestError`, `processingComplete`, `processingCancelled`, `invalidSample`, `skippedSample`, `automaticDownsampling` and `stitchingIncomplete`. Keep the screen awake.

**Result screen.** Segmented control Realistic | Clean | Floor plan | Mesh, a measure tool, an object list for box editing, and Share. Show a "check this" badge on items with low `confidence`.

**Measurement tool.** Fixed center reticle plus a big thumb-reachable "+" button (Apple Measure style, no loupe needed). Raycast from the reticle; snap to RoomPlan wall corners within about 24 pt; a second tap closes the segment; long-press to drag a point; live length label at mid-segment; `.selection` haptic on snap.

**Units.** US default: feet and inches rounded to 1/8 in with a 1/16 in option, trade style `12'-6 1/2"` on plans, area in whole sq ft; metric secondary line (cm at 0.5 cm, m² to one decimal). Default system from `Locale.current.measurementSystem`, overridable in settings. All of this goes through `ios/Sources/Units/`, which already has formatting, parsing and a launch self-test.

**Sharing.** Put all sharing behind one `ShareService`. Default to a small `UIViewControllerRepresentable` around `UIActivityViewController` (Apple's sample shares a whole export folder this way). Use `ShareLink` for single files (a `URL` is `Transferable`). If folder sharing misbehaves, zip the folder with `NSFileCoordinator` and the `.forUploading` reading option (no third-party code). Export files must live in Documents or tmp.

#### Disputed or unsure

1. **Only `.reduced` photogrammetry on iOS, even with the iOS 26 SDK.** Researcher: yes, per doc JSON, but asked for a CI compile check. Verifiers (docs and reality lenses): not refuted; `.medium` doc JSON lists only macOS and Mac Catalyst, WWDC23 10191 says reduced only on iOS; one third-party snippet saying "preview" on iOS was a paraphrase error; one 2023 blog saying medium works on iOS has no support. Verifier evidence is stronger (primary docs plus transcript). Ruling: hardcode `.reduced`; higher detail only by exporting images to a Mac. No CI round trip needed. The docs verifier and a direct fetch also cover `.custom`: macOS 14.0 and Mac Catalyst 17.0 only, so also unavailable on iOS.
2. **Availability of `hideObjectReticle`, `showShotLocations`, `isAutoCaptureEnabled`, `shouldPlayHaptics`.** Researcher listed iOS 17.0. Verifier: iOS 18.0 from doc JSON (confirmed by a direct doc fetch). Ruling: iOS 18.0. No `#available` needed at our 18.0 target.
3. **`UIImpactFeedbackGenerator.init(style:)` "deprecated on the iOS 26 SDK".** Researcher said so; not checked by verifiers. A direct fetch of the doc JSON shows deprecation at iOS 27.0 and `init(style:view:)` introduced in iOS 17.5, not 17.0. Ruling: it may not warn on Xcode 26.6, but avoid it anyway and use `.sensoryFeedback` or `init(style:view:)`.
4. **RoomPlan section labels.** Researcher: doc JSON lists three (livingRoom, kitchen, diningRoom), WWDC23 adds bedroom and bathroom. Verifier open-question answer: six cases, `livingRoom`, `kitchen`, `diningRoom`, `bedroom`, `bathroom`, `unidentified`, all iOS 17.0 (confirmed by a direct doc fetch). Ruling: six cases, plus `@unknown default`.
5. **"Mirror the six Instruction cases as the only room guidance."** Researcher: yes. Reality verifier: not refuted, but RoomCaptureView draws its own coaching and cannot hide it while still delivering instructions (forum thread 736482). Ruling: in v1 room mode trust RoomCaptureView's own coaching; our banner is only for errors and thermal state. Mirror the six cases only if we later build a custom session view.
6. **House mode single floor and 2,000 sq ft.** Researcher cited Apple as a limit. Docs verifier: the current structure article says rooms on different floors and with varying floor heights are supported; the 2,000 sq ft, 1 to 4 bedrooms and 50 lux figures are WWDC23 best-results advice. Ruling: present them as recommendations in onboarding, not hard limits.
7. **StructureBuilder "removes duplicate walls".** Docs do not say this; WWDC23 10192 does. Forum reports show crashes and errors on some merges. Ruling: accept the merge behavior, but keep per-room data as the fallback.
8. **`metadataURL` writes a node-name-to-UUID map.** Docs are silent on the format; WWDC23 10192 says it is a String to UUID dictionary. Ruling: likely true, confirm on device before building object picking on it.
9. **`USDExportOptions.all`.** Mentioned only in an old sample comment. Not in the docs. Ruling: does not exist; do not use.
10. **ShareLink with a folder URL.** Verifier answer: unsure; forums report ShareLink failing or renaming files where UIActivityViewController works, and no Apple sample shows ShareLink with a directory. Ruling: UIActivityViewController wrapper for folders, zip fallback, on-device test on AirDrop, Save to Files and Mail.
11. **Per-screen orientation (portrait scan, landscape viewer).** Verifier answer (likely): feasible with an AppDelegate orientation mask, `setNeedsUpdateOfSupportedInterfaceOrientations()` and `requestGeometryUpdate`, with a risk of `@State` resets on iOS 18. Ruling: portrait only for v1; revisit later.
12. **Competitor UI labels and coverage colors.** Researcher confidence "likely"; not independently verified (pages returned 403, facts from snippets and reviews). Ruling: use as design inspiration only, not as specification.
13. **1/8 in default resolution.** Based on trade sources and a stated LiDAR accuracy of about 1 to 2 percent (confidence "likely"). Ruling: keep 1/8 in default with 1/16 option; confirm against the accuracy protocol in `docs/TEST_PLAN.md`.

## 4. Risk register

The top 12 risks to the build, merged across subsystems. Likelihood and impact are High, Medium or Low. Most "likelihood" values are judgments from the research, not measurements.

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | RoomPlan re-runs the shared `ARSession` and drops `sceneDepth` (and possibly the video format or mesh), so raw mesh, coverage and texturing cannot run in the same pass as the room scan. Re-running our configuration could also make RoomPlan stop producing walls or raise `CaptureError.invalidARConfiguration`. | High | High | Re-run an `ARWorldTrackingConfiguration` (`.meshWithClassification`, `.sceneDepth`) with empty options in `captureSession(_:didStartWith:)` for every room. Never pass `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction`. Watchdog on `frame.sceneDepth == nil`. Log `arSession.configuration`, depth rate, mesh anchor count and final wall count in the first device build. Fallbacks: `RoomCaptureView(frame:arSession:)` (documented to preserve session settings), then a separate ARKit mesh pass aligned in the same session. |
| 2 | A coordinate or UV flip error (projection signs, depth-pass projection, Core Image origin, RealityKit, OBJ or USD V origin, y-down versus y-up plan contexts, wall winding) makes textures or plans wrong, and each fix costs a CI round trip. | High | High | Ship the dot-overlay and numbered-atlas self-tests in the first texturing build. Log per-keyframe depth reprojection error (target under 0.5 px). Flip V once at output boundaries. Keep one flip convention in `PlanRenderer`, derive winding from wall connectivity, and verify with an L-shaped room. |
| 3 | Whole-house merge goes wrong: rooms from unrelated frames merge silently into stacked rooms, `StructureBuilder` throws (`invalidRoomLocation`, `exceedSceneSizeLimit`) or crashes with `EXC_BAD_ACCESS`, and room IDs are regenerated. | High | High | One `ARSession` across rooms (`stop(pauseARSession: false)`), or relocalize with an `ARWorldMap` saved after `worldMappingStatus` reaches `.mapped`. Save every `CapturedRoom` as JSON before merging. Catch `StructureBuilder.BuildError`; after a crash, offer the merge again on next launch. Detect overlaps after merge. Offer manual "Arrange rooms". |
| 4 | Thermal throttling during multi-minute scans causes frame drops, tracking drift, mesh errors and a late `deviceTooHot`. | High (estimate, unmeasured) | Medium to High | Thermal ladder on `ProcessInfo.thermalStateDidChangeNotification`: shed the overlay and hole computation at `.serious`, pause at `.critical`. Warn at 4 minutes per room. Encourage room-by-room scans. Log the thermal timeline on device. |
| 5 | Jetsam kill during photogrammetry, texture baking or large mesh work. The real ceiling on this phone is unknown, and `increased-memory-limit` may not survive Sideloadly signing. | Medium | High | Budget about 2.5 GB peak. Log `os_proc_available_memory` at launch and before heavy stages. Stream mesh and keyframes to disk, bake one keyframe at a time, release `ObjectCaptureSession` before `PhotogrammetrySession`, avoid `.modelEntity`, use checkpoints to resume. |
| 6 | Retaining `ARFrame`s or their pixel buffers, or encoding inside the delegate, starves ARKit's frame pool, so tracking and mesh integration degrade. | Medium | High | Deep-copy the Y and CbCr planes, depth and confidence inside the callback, release the frame, and encode only the copy on a bounded serial queue that drops keyframes instead of queueing. Hard ceiling well under 10 retained frames. |
| 7 | RealityKit is too slow or heavy with about 1M triangles in 200 to 400 `LowLevelMesh` chunks on the A15. No public benchmark exists. | Medium | High | Tunable chunk count and material type, frustum-based `isEnabled`, decimated LOD copies, a decimation stage that is a no-op below about 300k faces, and a Metal-compatible vertex layout so an `MTKView` renderer can take over. |
| 8 | CI round trips burned by compile errors: actor-isolation mistakes, iOS 27-only symbols, delegate method near-misses that compile silently as plain methods, undocumented overloads. | High | Medium | Copy declarations verbatim from this document. Nonisolated delegate classes on serial queues, value copies hopped with `Task { @MainActor in }`. Never set Swift 6 or default MainActor isolation. Log the first call of every delegate method in the device smoke test. |
| 9 | Per-vertex color does not render: no fixed-function material (Unlit, PBR, Simple) reads `LowLevelMesh` `.color`, and `ShaderGraphMaterial` or `CustomMaterial` may not on iOS 18. | Medium | Medium | Device spike in the first rendering build with both paths. Fallbacks: per-face material parts or color packed into a UV channel. |
| 10 | The USDZ path is unproven: `MDLUtility.convert(toUSDZ:writeTo:)` has no documented behavior and no known device usage; `SCNScene.write` can write a corrupt file on a second call. | Medium | Medium | Self-test on a synthetic textured cube in the first export build. Check output exists, is larger than a few KB and starts with "PK". Keep the own stored-zip USDZ writer as fallback and SceneKit as a contained last resort. |
| 11 | Displayed measurements are overconfident: uncalibrated error constants, RoomPlan drift on long walls (field reports up to 37 cm on a 6.45 m wall), and room area overstated if the floor polygon is trusted. | Medium | High | Area from the closed wall loop. Error model with 1 cm floor, 3 cm RoomPlan cap growing with length, 4 cm low-confidence cutoff. Optional tape-measured scale correction. Calibrate with the `docs/TEST_PLAN.md` protocol. Never imply survey grade. |
| 12 | Object Capture falls short on the A15: unknown runtime image limit, minutes-long reconstruction, an `ObjectCaptureView` leak of hundreds of MB per appear cycle (2023 report), and users expecting more than `.reduced` quality. | Medium | Medium | Read `maximumNumberOfInputImages` and `PhotogrammetrySession.limits` at runtime and drive the shot counter from them. Keep one `ObjectCaptureView` alive per capture and `pause()` it while hidden. Show progress and ETA, keep the app in the foreground, resume from checkpoints. Set expectations in `Copy.swift` and offer export of the image folder for Mac reconstruction. |

Other risks worth tracking, below the top 12: processing interrupted when the user leaves the app (idle timer off, checkpoints, optional iOS 26 `BGContinuedProcessingTask` for CPU work); storage exhaustion for multi-room houses (pre-flight with `volumeAvailableCapacityForImportantUsage`, raw data excluded from backup, "delete raw data" action); coverage never reaching green on glass, mirrors and dark surfaces (suppress prompts near RoomPlan windows); hand-written GLB, PLY, STL and DXF files rejected by external tools (spec-based unit tests on the macOS runner, NaN sanitizing, UInt32 indices); ShareLink misbehaving with folder URLs (UIActivityViewController wrapper plus zip fallback); free Apple ID limits (7-day expiry, 3 apps, 10 App IDs per week, bundle id rewritten by Sideloadly, so never compare `Bundle.main.bundleIdentifier` to the plain id).

## 5. Do not do

Each item says why. Categories: macOS-only, deprecated, unavailable on iOS 18, needs an entitlement or signing support we cannot rely on, refuted by verifiers, or other (compile error or known failure).

### macOS or Mac Catalyst only

- `PhotogrammetrySession.Request.Detail` `.preview`, `.medium`, `.full`, `.raw` (macOS 12.0 and Mac Catalyst 15.0 only) and `.custom` with `Configuration.customDetailSpecification` (macOS 14.0 and Mac Catalyst 17.0 only). On iOS only `.reduced` exists; referencing the others breaks the build.
- `PhotogrammetrySession.Configuration.meshPrimitive` (macOS 15.0 and Mac Catalyst 18.0 only). No quad meshes on iOS.
- `SCNScene.write(to:)` with a `.dae` URL. Collada export is macOS only.
- RoomPlan capture on Mac Catalyst or in the Simulator. Capture needs a LiDAR iPhone or iPad; Mac Catalyst supports only decoding, encoding and exporting `CapturedRoom` and `CapturedStructure`.
- `ObjectCaptureSession` in the Simulator or where `isSupported` is false. Creating it there is a runtime error.

### Unavailable at iOS 18 or absent from the iOS 26 SDK

- Every `viewRotationAngle` API: `ARCamera.viewMatrix(viewRotationAngle:)`, `projectPoint(_:viewRotationAngle:viewportSize:)`, `projectionMatrix(viewRotationAngle:...)`, `unprojectPoint(_:ontoPlane:viewRotationAngle:...)`, `ARFrame.displayTransform(viewRotationAngle:...)`, `ARSession.viewRotationAngle`, `ARSessionObserver.session(_:didChangeViewRotationAngle:)`. All iOS 27.0; they do not compile on Xcode 26.6.
- `LowLevelMesh.Descriptor.allowsPrimitiveRestart`, `instanceCapacity`, the 6-argument `Descriptor` init, and `LowLevelMesh.Layout.init(bufferIndex:bufferOffset:bufferStride:stepFunction:stepRate:)`. All iOS 27.0.
- `ARSession.captureHighResolutionFrame(using:completion:)`, its async form, `VideoFormat.defaultPhotoSettings` and `defaultColorSpace` without `if #available(iOS 26.0, *)`. The test phone runs iOS 18.3.2. Use `captureHighResolutionFrame(completion:)` (iOS 16.0).
- `BGContinuedProcessingTaskRequest`, `BGContinuedProcessingTask`, `BGTaskScheduler.supportedResources` without `#available(iOS 26.0, *)`.
- `PhotogrammetrySample.orientation` without `#available(iOS 26.0, *)`.
- `Entity.write(to:options:)`, static `write(_:to:options:)` (iOS 27.0) and `Entity.WriteOptions` (iOS 26.0). They also only write `.reality`, never USDZ or OBJ.
- `RealityViewAttachments`, `RealityView` `init(make:update:attachments:)`, `RealityViewContent`, `RealityCoordinateSpaceConverting`. visionOS only.

### Deprecated (compiles, but do not build on it)

- SceneKit for display or new code: `SCNView`, `SCNScene`, `SceneView`, `ARSCNView`, `SCNGeometrySource(buffer:...)`, `SCNScene(url:options:)`, `SCNBoundingVolume.boundingBox`. Deprecated at iOS 26.0 ("SceneKit is deprecated, use RealityKit instead"). The only allowed SceneKit code is the contained last-resort USDZ writer.
- `ARFrame.hitTest(_:types:)` and `ARHitTestResult` (deprecated at iOS 14.0). Use `ARSession.raycast`.
- `ARPlaneAnchor.extent` (deprecated at iOS 16.0). Use `planeExtent`.
- Orientation helpers for texturing math: `ARCamera.viewMatrix(for:)`, `projectPoint(_:orientation:viewportSize:)`, `projectionMatrix(for:viewportSize:zNear:zFar:)`, `ARFrame.displayTransform(for:viewportSize:)`. Marked deprecated at 27.0 in the docs (only Objective-C pages exist). They still compile on Xcode 26.6 and are fine for screen overlays, but texturing uses `camera.transform.inverse` and intrinsics directly.
- `ARView(frame:cameraMode:)` 2-argument init. Use `init(frame:cameraMode:automaticallyConfigureSession:)`.
- `MeshResource.generateAsync`, `replaceAsync`, `TextureResource.generate(from:withName:options:)`, `generateAsync`, `loadAsync` (deprecated at iOS 18.0) and `UnlitMaterial.baseColor`, `tintColor` (deprecated at iOS 15.0). Use `MeshResource.generate(from:)`, `replace(with:)`, `TextureResource(image:withName:options:)` and `UnlitMaterial.color`.
- `UIImpactFeedbackGenerator.init(style:)` (marked deprecated at 27.0). Use SwiftUI `.sensoryFeedback` (iOS 17.0) or `init(style:view:)` (iOS 17.5).
- `fileExporter(isPresented:document:contentType:defaultFilename:onCompletion:)` with `FileDocument`, `MagnificationGesture`, `RotationGesture`, and the `CoordinateSpace`-typed inits of `DragGesture` and `SpatialTapGesture` (marked deprecated at 27.2). Use the Transferable `fileExporter`, `ShareLink`, `MagnifyGesture`, `RotateGesture` and the `some CoordinateSpaceProtocol` inits (iOS 17).
- `recommendedVideoFormatFor4KResolution` and `videoHDRAllowed` for scanning. Not deprecated, but 30 fps with higher power and heat; 16:9 hi-res formats were reported to break the mesh on iPads (community evidence, unchecked on iPhone).

### Entitlements and signing we cannot rely on

- `com.apple.developer.kernel.increased-memory-limit`. Xcode Personal Team and AltStore reportedly keep it, SideStore 0.7.0 drops it, and Sideloadly is unknown. A profile mismatch can fail the install. Do not depend on it.
- `com.apple.developer.background-tasks.continued-processing.gpu`. Background GPU is supported only on M3-or-newer iPads per Apple DTS; no iPhone.
- `SWIFT_VERSION 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY` or `SWIFT_TREAT_WARNINGS_AS_ERRORS` in `project.yml`. They break the nonisolated delegate pattern or turn deprecation warnings into build failures.
- A `lidar` value in `UIRequiredDeviceCapabilities`. It does not exist; gate LiDAR at runtime with `supportsSceneReconstruction` and `isSupported`.

### Refuted by verifiers

- Assuming your `ARWorldTrackingConfiguration` survives `RoomCaptureSession.run(configuration:)`. Refuted; re-apply it in `didStartWith`.
- Assuming RoomPlan owns `arSession.delegate` and needs a multiplexer. Refuted by the tie-breaker; setting the delegate is allowed.
- "Apple said in 2022 you cannot capture `ARMeshAnchor`s while `RoomCaptureSession` runs." Unsourced; the thread has no Apple reply.
- Relying on `ARWorldMap` to store `ARMeshAnchor`s. Mesh anchors are dropped from world maps.
- Relying on `StructureBuilder.capturedStructure(from:)` to throw for rooms in unrelated frames. It merges them silently.
- `CapturedRoom.floors[].polygonCorners` as the room area source. It was a bounding rectangle on real data.
- `$INSUNITS` as the only unit declaration in an R12 DXF. It is an R2000 variable.
- Hard-coding 1000 as the iOS Object Capture image limit. No verifiable source.
- `ObjectCaptureSession.Feedback.outOfRange`. No such case; use `outOfFieldOfView`.
- Reading `ARMeshGeometry.normals` indexed by face. Normals are per vertex in practice (count equals vertex count), despite the doc abstract.
- `LowLevelMesh.replaceIndices(_:)` closure form. Does not exist; use `withUnsafeMutableIndices(_:)`, `replaceUnsafeMutableIndices(_:)` or `replaceIndices(using:)`.
- `CapturedRoom.USDExportOptions.all` and `StructureBuilder(option:)`. Neither exists; the options are `.parametric`, `.mesh`, `.model` and the init is `StructureBuilder(options:)`.
- Codable conformance on `simd_float4x4` or `simd_float3x3`. Not Codable; use a wrapper.
- Claims that `RealityView` on iOS has no project, unproject or hit test, and that `ShaderGraphMaterial` is visionOS only. Both refuted (iOS 18.0).
- Citing "69 to 83 percent of points within 5 cm" or "iPhone 15" LiDAR accuracy. Unconfirmed or misattributed; the study used the iPhone 15 Pro on small objects.
- Treating 2,000 sq ft or a single floor as a hard house-mode limit. It is WWDC advice for best results.

### Other (does not compile or known to fail)

- `RoomCaptureSession.Configuration.beautifyObjects`. Configuration has only `isCoachingEnabled`; `beautifyObjects` belongs to the builder options.
- `CapturedRoom.export(to:metadataURL:exportOptions:)`. No such overload; use `export(to:metadataURL:modelProvider:exportOptions:)`.
- `let provider = CapturedRoom.ModelProvider(); provider.setModelFileURL(...)`. `setModelFileURL(_:for:)` is mutating; declare the provider with `var`.
- `allCases` on `Surface.Category`, `Section.Label` or `Instruction`. They are not `CaseIterable`.
- Mutating or constructing `CapturedRoom` or `CapturedStructure` in code. All properties are get-only and the only init is `init(from:)`.
- Assigning `RoomCaptureView.captureSession` (get-only) or recreating `RoomCaptureView` in `updateUIView` (restarts the scan).
- Relying on RoomPlan USDZ node names, re-importing its USDZ for the plan, or expecting UVs on RoomPlan geometry (no API provides them on any version).
- RoomPlan export file names that start with a digit (fails before iOS 17.4; keep a letter prefix anyway).
- `ARConfiguration.EnvironmentTexturing`. The type is `ARWorldTrackingConfiguration.EnvironmentTexturing`.
- `AVCapturePhotoSettings.isDepthDataDeliveryEnabled` with high-resolution frame capture. It throws; read `frame.sceneDepth`.
- Retaining `ARFrame`, `capturedImage`, `sceneDepth` buffers or `ARMeshGeometry` `MTLBuffer`s beyond the callback, or relying on `ARFrame.copy()` to deep-copy pixels.
- Passing `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction` when re-applying the configuration during RoomPlan.
- Keying coverage by `ARMeshAnchor` face or vertex index, using `ARFrame.rawFeaturePoints` for coverage, or treating `CapturedRoom.Confidence` as dimensional accuracy (it is category certainty).
- Hard-coding the 256 x 192 depth size or pixel formats. Read them at runtime.
- `MDLAsset.export(to:)` for `.usdz`, `.usdc`, `.usda` or `.ply`, or relying on its OBJ `map_Kd` output. Community evidence says usdz is not exportable and USD loses materials; PLY is not in the documented list. Write our own.
- `MDLAsset` import of binary PLY. ModelIO reads only ASCII PLY.
- `AppleArchive` for `.zip` output. It writes Apple Archive only.
- `QLPreviewController` embedded in a `UIViewControllerRepresentable`. Embedded, it shows only a thumbnail and loses AR mode and Share. Use `.quickLookPreview` or present it modally.
- `ARQuickLookPreviewItem(fileAt:)` for sandbox files (reported "Unhandled item type"); return the URL as the preview item.
- `URL.appending(path:)` for a `.usdz` URL passed to `SCNScene.write` (crashed on iOS 17). Use `appendingPathComponent`.
- DXF `DIMENSION` entities, and `LWPOLYLINE` in an R12 file or without the `100/AcDbEntity` and `100/AcDbPolyline` markers in R2000.
- `Measurement.FormatStyle` or `MeasurementFormatter` for feet and fractional inches. Use `ios/Sources/Units`.
- `ImageRenderer` for the PDF plan (Core Animation views become placeholders) and Euler-angle yaw on floor surfaces (gimbal lock).
- `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` into an `MTLTexture` without flipping (bottom-left origin).
- Regenerating `MeshResource` from `MeshDescriptor` per frame, and `ARView.debugOptions` `.showSceneUnderstanding` as the user-facing coverage view.
- Combining orbit, pan and dolly in `realityViewCameraControls`. `CameraControls` allows one mode at a time.
- `PhotogrammetrySession` `.modelEntity` requests on the 6 GB phone, `modelFile(url:)` with a `.obj` file URL (use a directory URL), and reusing an `ObjectCaptureSession` after `.completed` or `.failed`.
- `BGProcessingTask` for user-facing processing (runs only when idle), `URLFileProtection.complete` on scan data (writes fail when locked), and relying on catching a `StructureBuilder` crash.

## 6. Answers to open questions

Only questions that matter for the architecture. Confidence: verified (doc JSON or real data), likely (strong indirect evidence), unsure (needs a device test).

### Capture and sessions

1. **Does RoomPlan keep our scene reconstruction and scene depth on a shared session?** Likely not for a bare `RoomCaptureSession`: `run(configuration:)` replaces the configuration and `sceneDepth` disappears (several forum reports). Re-run our `ARWorldTrackingConfiguration` with empty options in `captureSession(_:didStartWith:)` for every room and read the configuration later, because changes apply asynchronously. The "preserves all of the AR session's settings" sentence is documented only for `RoomCaptureView.init(frame:arSession:)`. Confidence: likely.
2. **Can the app set `arSession.delegate` while RoomPlan uses the session?** Yes, per the tie-breaker. Set it before handing the session over, check identity after `didStartWith`, and multiplex only if it was replaced. Confidence: likely.
3. **Can the video format be changed on RoomPlan's session?** Undocumented. A format set before `run` is likely overwritten. Test once: re-run in `didStartWith` with `recommendedVideoFormatForHighResolutionFrameCapturing`, watch `session(_:didFailWithError:)`, log `imageResolution` and `framesPerSecond` after 3 s. Do not depend on a non-default format during RoomPlan. Confidence: unsure.
4. **Do high-resolution frames carry `sceneDepth`, and are their intrinsics rescaled?** Apple staff say depth is present with `.sceneDepth` and default settings (the regular low-res map). Intrinsic rescaling is unknown; always scale K by pixel-buffer size over `imageResolution`. Hi-res stays off in v1. Confidence: likely for depth, unsure for intrinsics.
5. **Mesh chunk size, update cadence and remove/re-add churn?** Undocumented (community: about 1 m chunks, 0.5 to 1 s updates). Design for any cadence: store by identifier, mark stale on remove, throttle per-anchor work to at most every 0.5 s. Confidence: unsure.
6. **Is `ARWorldMap` relocalization reliable across launches?** Documented as supported for multi-room structures (save map and room, relaunch with `initialWorldMap`, return true from `sessionShouldAttemptRelocalization`, wait for `.normal`). Reliability and map size on iOS 18.3.2 need a device test, so treat it as best effort with a timeout. Confidence: likely supported, unsure on reliability.

### Merging and floor plans

7. **Does merging rooms from separate, unrelocalized sessions throw?** No. It silently stacks rooms. `invalidRoomLocation` targets rooms that are far apart. Confidence: likely.
8. **How are stories and IDs handled after a merge?** Undocumented. Apple's sample house has story 0 for all rooms. Room and floor IDs are regenerated, while wall, door, window, opening and object IDs are kept (forum reports). Keep input rooms and match back by those IDs or by centroids. Confidence: likely.
9. **What are the local axes of RoomPlan surfaces?** Walls, doors and windows: `columns.1` is world up, `columns.0` runs along the wall with an arbitrary sign. Floors: `columns.2` is world up and `polygonCorners` are local (x, y, 0). `dimensions.z` is always 0. Rectangular walls have empty `polygonCorners`. Always use the full 4x4 transform. Confidence: verified for floors and depth, likely for walls.
10. **Can Mapper rely on RoomPlan USDZ node names or the metadata format?** No. Treat USDZ as output only and rebuild from Codable `CapturedRoom`. The metadata file needs an extension; pass `.plist` and sniff the format. Confidence: verified for names, likely for metadata.
11. **Which CAD importers honor `$INSUNITS` in R12?** LibreCAD and ezdxf read it; AutoCAD and QCAD are untested; SketchUp Pro's import has its own unit option. State units in a note and the filename. Confidence: unsure.

### Object Capture

12. **What are the image and size limits on the iPhone 13 Pro Max?** Device-specific and unpublished. Read `ObjectCaptureSession.maximumNumberOfInputImages` and `PhotogrammetrySession.limits` (iOS 17.0) at runtime. Images over the limits are ignored and reported as invalid samples. Capture stops at the limit unless `isOverCaptureEnabled` is true. Confidence: verified API, unknown values.
13. **Which requests work on iOS?** `.modelFile` and `.bounds` are the plan. `.poses` and `.pointCloud` are optional (log `requestError`). Avoid `.modelEntity` for memory. OBJ into a pre-created directory URL is documented and seen working on iOS 26; unconfirmed on iOS 18, so keep the ModelIO import plus own OBJ writer fallback. Confidence: likely.
14. **How long does reconstruction take?** Only qualitative data ("one to a few minutes"). Design for 2 to 10 minutes with progress, ETA, foreground only and checkpoint resume. Confidence: unsure.
15. **Is there a way to get more than `.reduced` on the phone?** No. The higher cases are macOS and Mac Catalyst only in the iOS 26 SDK. Export the image folder for a Mac. Confidence: verified.

### Texturing, rendering and export

16. **What is RealityKit's UV V origin?** Likely bottom-left, so store `v' = 1 - v` for a top-left atlas. OBJ and USD are also bottom-left, so one convention covers display and export. Confirm with the numbered-atlas test. Confidence: likely.
17. **Does ModelIO write USDZ or textured OBJ?** Do not depend on either. Own OBJ plus MTL; own usda plus `MDLUtility.convert(toUSDZ:writeTo:)`; own stored-zip writer as fallback. Log `canExportFileExtension` for usdz, usdc, usda, obj, stl and ply in the capability probe. Confidence: likely.
18. **Does `LowLevelMesh` `.color` reach `ShaderGraphMaterial` or `CustomMaterial` on iOS 18?** Unknown. An Apple engineer said it is exposed to Shader Graph on visionOS. Test both in the first spike, with a per-face fallback. A `ShaderGraphMaterial` with an Occlusion Surface output fails to load on iOS 18, so use the Unlit or PBR surface. Confidence: unsure.
19. **RealityView or ARView for the viewer?** `RealityView` on iOS 18 has project, unproject, ray and hit test, but `CameraControls` allows one mode and there are no attachments on iOS. `ARView` (`.nonAR`, 3-argument init) in a `UIViewRepresentable` is the lowest-risk host. Confidence: verified.
20. **What does `triangleHit.faceIndex` mean with several shapes, and what does `pixelCast` cost?** Undocumented. Use one static-mesh shape per chunk entity, verify by picking a known triangle, keep a CPU ray-triangle fallback, and call `pixelCast` once per tap. Confidence: unsure.
21. **Is `MeshResource.generate(from: [MeshDescriptor])` still in the iOS 26 SDK?** Unverified in the docs (the page 404s; community code only). Prefer `LowLevelMesh`; confirm with one compile if used. Confidence: unsure.
22. **Is the `SCNScene.write` second-write bug still present?** Unknown on iOS 18.3 and 26. It only matters for the last-resort path. Confidence: unsure.

### Quality and measurement

23. **What do `completedEdges` mean at runtime?** Undocumented beyond "edges that outline the surface". Soft coverage hint only, never a finish gate. Confidence: unsure.
24. **What is the confidence map format?** Expect `OneComponent8` with raw values 0, 1, 2. Read the format at runtime and map with `ARConfidenceLevel(rawValue:)`. Confidence: likely.
25. **How accurate is LiDAR depth at room scale?** The 3.7 cm median ARKit versus Faro figure is whole-frame and likely inflated by far pixels. Error grows with range (about 1 to 2 cm at 1 to 3 m, rising past about 4.5 m). Room-scale app error is several cm to decimetres and dominated by tracking. Use a distance-dependent depth term calibrated with the tape protocol. Confidence: likely.
26. **Does Mapper need a user measurement correction?** Yes, as an option: one tape-measured reference length applied as a reversible uniform scale. Confidence: unsure (no Apple accuracy figure).
27. **What is the thermal timeline?** No published numbers. Expect `.fair` within minutes and possibly `.serious` after 10 to 20 minutes of RoomPlan plus mesh plus overlay; `.critical` is unlikely in normal room scans. Log thermal state and battery every 30 s. Confidence: unsure.

### Storage, deployment and UX

28. **What is the jetsam limit?** No authoritative figure for this phone. Budget about 2.5 GB and measure. Confidence: unsure.
29. **Can the free-team profile carry increased-memory-limit?** Unknown for Sideloadly. Test by inspecting `embedded.mobileprovision`, but do not depend on it. Confidence: unsure.
30. **What are the free Apple ID limits?** 3 active sideloaded apps per device, 10 App IDs per 7 days, 7-day expiry. Two phones on one Apple ID is fine. Confidence: likely (Sideloadly FAQ not re-fetched).
31. **Does iOS 26 change background processing or SceneKit?** `BGContinuedProcessingTaskRequest` (iOS 26.0) must be submitted from the foreground on a user action, CPU only on iPhone, with a system-provided Live Activity. SceneKit deprecation is compile-time only; code still runs on iOS 18 and 26, and the warnings may not even fire with an 18.0 deployment target. Confidence: verified for API availability.
32. **Which RoomPlan section labels exist?** Six: `livingRoom`, `kitchen`, `diningRoom`, `bedroom`, `bathroom`, `unidentified` (iOS 17.0). Use `@unknown default` and treat labels as suggested names only. Confidence: verified.
33. **Can the scan screen stay portrait while the viewer rotates?** Yes with UIKit bridging (orientation mask, `setNeedsUpdateOfSupportedInterfaceOrientations()`, `requestGeometryUpdate`), but v1 is portrait only. Confidence: likely.
34. **Does `ShareLink` with a folder URL work as well as `UIActivityViewController`?** Unknown; forums report failures. Use a `UIActivityViewController` wrapper for folders with zip as fallback. Confidence: unsure.

### Still unresolved (device tests for the first builds)

- RoomPlan plus scene depth plus mesh on one session on iOS 18.3.2, including whether walls keep coming and whether the video format is replaced.
- Texture orientation, UV V origin, depth-pass projection signs, and whether hi-res frame intrinsics are rescaled.
- Per-vertex color through `ShaderGraphMaterial` or `CustomMaterial`, and RealityKit frame rate at about 1M triangles.
- `MDLUtility.convert(toUSDZ:writeTo:)` behavior and texture packaging; `canExportFileExtension` results.
- Runtime values: `maximumNumberOfInputImages`, `PhotogrammetrySession.limits`, available memory, depth and image sizes, mesh chunk size and cadence.
- Reconstruction time, thermal timeline and battery drain on the A15.
- `ARWorldMap` size and relocalization success rate; `StructureBuilder` crash rate with 3 to 4 rooms.
- Whether Sideloadly keeps the increased-memory-limit entitlement; `ShareLink` with folders; the `ObjectCaptureView` leak size on iOS 18.

## 7. Sources

Every URL used by the researchers, verifiers, section drafters and checkers, grouped by subsystem. Apple documentation JSON URLs (`https://developer.apple.com/tutorials/data/documentation/<path>.json`) are listed in their human-readable form (`https://developer.apple.com/documentation/<path>`); both forms resolve to the same page.

### ARKit mesh and depth

- https://developer.apple.com/documentation/arkit/aranchor
- https://developer.apple.com/documentation/arkit/arcamera
- https://developer.apple.com/documentation/arkit/arcamera/projectionmatrix(for:viewportsize:znear:zfar
- https://developer.apple.com/documentation/arkit/arcamera/projectionmatrixfororientation:viewportsize:znear:zfar:
- https://developer.apple.com/documentation/arkit/arcamera/unprojectpoint(_:ontoplane:orientation:viewportsize:)
- https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth
- https://developer.apple.com/documentation/arkit/arconfiguration/recommendedvideoformatforhighresolutionframecapturing
- https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class
- https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.class/isrecommendedforhighresolutionframecapturing
- https://developer.apple.com/documentation/arkit/ardepthdata
- https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap
- https://developer.apple.com/documentation/arkit/ardepthdata/depthmap
- https://developer.apple.com/documentation/arkit/arframe
- https://developer.apple.com/documentation/arkit/arframe/capturedimage
- https://developer.apple.com/documentation/arkit/arframe/raycastquery(from:allowing:alignment:)
- https://developer.apple.com/documentation/arkit/arframe/scenedepth
- https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.enum
- https://developer.apple.com/documentation/arkit/armeshanchor
- https://developer.apple.com/documentation/arkit/armeshanchor/geometry
- https://developer.apple.com/documentation/arkit/armeshclassification
- https://developer.apple.com/documentation/arkit/armeshgeometry
- https://developer.apple.com/documentation/arkit/arplaneanchor
- https://developer.apple.com/documentation/arkit/arraycastquery/target-swift.enum/estimatedplane
- https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(completion
- https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(using:completion
- https://developer.apple.com/documentation/arkit/arsession/currentframe
- https://developer.apple.com/documentation/arkit/arsession/delegate
- https://developer.apple.com/documentation/arkit/arsession/delegatequeue
- https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
- https://developer.apple.com/documentation/arkit/arsession/raycast(_:)
- https://developer.apple.com/documentation/arkit/arsession/run(_:options:)
- https://developer.apple.com/documentation/arkit/arsession/runoptions
- https://developer.apple.com/documentation/arkit/arsession/runoptions/resetscenereconstruction
- https://developer.apple.com/documentation/arkit/arsessiondelegate
- https://developer.apple.com/documentation/arkit/arworldmap
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/environmenttexturing-swift.enum
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/supportsscenereconstruction(_
- https://developer.apple.com/documentation/arkit/creating-a-fog-effect-using-scene-depth
- https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth
- https://developer.apple.com/documentation/arkit/saving-and-loading-world-data
- https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
- https://developer.apple.com/documentation/realitykit/arview/automaticallyconfiguresession
- https://developer.apple.com/documentation/roomplan/roomcapturesession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/init(arsession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/stop(pausearsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate/capturesession(_:didstartwith:)
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/forums/thread/130326
- https://developer.apple.com/forums/thread/682585
- https://developer.apple.com/forums/thread/705469
- https://developer.apple.com/forums/thread/710134
- https://developer.apple.com/forums/thread/728601
- https://developer.apple.com/forums/thread/763400
- https://developer.apple.com/forums/thread/805839
- https://developer.apple.com/forums/thread/808834
- https://developer.apple.com/videos/play/wwdc2022/10126/
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://github.com/Shadowru/straylite/blob/b4d8940dd2c770a7bd79fbec25bc5ec3763c42ec/Sources/straylite/Capture/CaptureCoordinator.swift
- https://github.com/WiseLabCMU/wisescan-ios/blob/main/README.md
- https://github.com/YvigUnderscore/ReScan/pull/17
- https://github.com/dotnet/macios/wiki/ARKit-iOS-xcode26.0-b1
- https://github.com/pickettdad/homebinder/blob/main/docs/PHOTO-SETTINGS-RESULT-2026-09-07.md
- https://github.com/pickettdad/homebinder/blob/main/docs/ZONE-SESSION-MEASURED-2026-08-19.md
- https://github.com/xybp888/iOS-SDKs/blob/master/iPhoneOS26.5.sdk/System/Library/Frameworks/ARKit.framework/Headers/ARCamera.h
- https://raw.githubusercontent.com/xybp888/iOS-SDKs/master/iPhoneOS14.0.sdk/System/Library/Frameworks/ARKit.framework/Headers/ARMeshGeometry.h
- https://stackoverflow.com/questions/77620306
- https://stackoverflow.com/questions/79208951

### RoomPlan

- https://developer.apple.com/documentation/arkit/arsession/delegate
- https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
- https://developer.apple.com/documentation/roomplan
- https://developer.apple.com/documentation/roomplan/captured-object-attributes
- https://developer.apple.com/documentation/roomplan/capturedroom
- https://developer.apple.com/documentation/roomplan/capturedroom/export(to:metadataurl:modelprovider:exportoptions:)
- https://developer.apple.com/documentation/roomplan/capturedroom/modelprovider
- https://developer.apple.com/documentation/roomplan/capturedroom/object/attribute(of:)
- https://developer.apple.com/documentation/roomplan/capturedroom/object/category-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/section/label-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/surface
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct/center
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/polygoncorners
- https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions
- https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions/model
- https://developer.apple.com/documentation/roomplan/capturedroomattribute
- https://developer.apple.com/documentation/roomplan/capturedstructure/export(to:metadataurl:modelprovider:exportoptions
- https://developer.apple.com/documentation/roomplan/create-a-3d-model-of-an-interior-room-by-guiding-the-user-through-an-ar-experience
- https://developer.apple.com/documentation/roomplan/roombuilder
- https://developer.apple.com/documentation/roomplan/roombuilder/capturedroom(from:)
- https://developer.apple.com/documentation/roomplan/roomcapturesession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/arsession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror
- https://developer.apple.com/documentation/roomplan/roomcapturesession/configuration
- https://developer.apple.com/documentation/roomplan/roomcapturesession/init(arsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate/capturesession(_:didendwith:error:)
- https://developer.apple.com/documentation/roomplan/roomcaptureview
- https://developer.apple.com/documentation/roomplan/roomcaptureview/init(frame:arsession:)
- https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from
- https://developer.apple.com/forums/thread/710765
- https://developer.apple.com/forums/thread/728601
- https://developer.apple.com/forums/thread/763135
- https://developer.apple.com/forums/thread/763400
- https://developer.apple.com/forums/thread/775853
- https://developer.apple.com/forums/thread/775945
- https://developer.apple.com/forums/thread/808834
- https://developer.apple.com/videos/play/wwdc2022/10127/
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://github.com/XRealityZone/apple-wwdc-ar-demo
- https://machinelearning.apple.com/research/roomplan
- https://raw.githubusercontent.com/facebookresearch/ocean/main/impl/ocean/devices/arkit/roomplan/swift/AKRoomPlanTracker6DOF_Swift.swift

### Object Capture

- https://developer.apple.com/documentation/modelio/mdlasset
- https://developer.apple.com/documentation/modelio/mdlasset/boundingbox
- https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)
- https://developer.apple.com/documentation/modelio/mdlasset/childobjects(of:)
- https://developer.apple.com/documentation/modelio/mdlasset/export(to:)
- https://developer.apple.com/documentation/modelio/mdlasset/init(url:)-1f4ym
- https://developer.apple.com/documentation/realitykit/boundingbox/extents
- https://developer.apple.com/documentation/realitykit/entity/init(contentsof:withname:)
- https://developer.apple.com/documentation/realitykit/hastransform/visualbounds(recursive:relativeto:excludeinactive:)
- https://developer.apple.com/documentation/realitykit/meshresource/bounds
- https://developer.apple.com/documentation/realitykit/objectcapturepointcloudview
- https://developer.apple.com/documentation/realitykit/objectcapturepointcloudview/init(session:)
- https://developer.apple.com/documentation/realitykit/objectcapturepointcloudview/showshotlocations(_:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession
- https://developer.apple.com/documentation/realitykit/objectcapturesession/beginnewscanpass()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/beginnewscanpassafterflip()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/cameratracking
- https://developer.apple.com/documentation/realitykit/objectcapturesession/canrequestimagecapture
- https://developer.apple.com/documentation/realitykit/objectcapturesession/capturestate
- https://developer.apple.com/documentation/realitykit/objectcapturesession/configuration-swift.struct/isovercaptureenabled
- https://developer.apple.com/documentation/realitykit/objectcapturesession/error
- https://developer.apple.com/documentation/realitykit/objectcapturesession/error/insufficientstorage(requiredbytes:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession/feedback-swift.enum
- https://developer.apple.com/documentation/realitykit/objectcapturesession/feedback-swift.property
- https://developer.apple.com/documentation/realitykit/objectcapturesession/isautocaptureenabled
- https://developer.apple.com/documentation/realitykit/objectcapturesession/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/objectcapturesession/numberofshotstaken
- https://developer.apple.com/documentation/realitykit/objectcapturesession/requestimagecapture()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/shouldplayhaptics
- https://developer.apple.com/documentation/realitykit/objectcapturesession/start(imagesdirectory:configuration:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession/startcapturing()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/startdetecting()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/usercompletedscanpass
- https://developer.apple.com/documentation/realitykit/objectcaptureview
- https://developer.apple.com/documentation/realitykit/objectcaptureview/init(session:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysample
- https://developer.apple.com/documentation/realitykit/photogrammetrysample/boundingbox
- https://developer.apple.com/documentation/realitykit/photogrammetrysample/init(contentsof:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysession
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/configuration-swift.struct/checkpointdirectory
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/configuration-swift.struct/ignoreboundingbox
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/configuration-swift.struct/init(checkpointdirectory:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/configuration-swift.struct/isobjectmaskingenabled
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.struct/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.type.property
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output/automaticdownsampling
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output/processingstage
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output/progressinfo
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output/requestprogressinfo(_:_:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/output/stitchingincomplete
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/outputs-swift.property
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail/medium
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail/reduced
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/geometry
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/modelfile(url:detail:geometry:)
- https://developer.apple.com/documentation/realitykit/scanning-objects-using-object-capture
- https://developer.apple.com/forums/thread/742077
- https://developer.apple.com/videos/play/wwdc2023/10191/
- https://developer.apple.com/videos/play/wwdc2024/10107/
- https://docs-assets.developer.apple.com/published/c13a7fb3aa69/ScanningObjectsUsingObjectCapture.zip
- https://github.com/VForev/Lidar4Free/blob/HEAD/LidarFree/Reconstruct/ReconstructionService.swift
- https://github.com/VForev/Lidar4Free/blob/f4d6506626c02a024dec6baf51fb2d68c1bcae40/LidarFree/Reconstruct/ReconstructionService.swift
- https://github.com/tristanheilman/react-native-object-capture/blob/HEAD/ios/Session/RNPhotogrammetrySession.swift
- https://www.it-jim.com/blog/3d-reconstruction-on-ios/

### Texturing pipeline

- https://developer.apple.com/documentation/arkit/arcamera
- https://developer.apple.com/documentation/arkit/arcamera/transform
- https://developer.apple.com/documentation/arkit/arcamera/viewmatrix(viewrotationangle
- https://developer.apple.com/documentation/arkit/arconfiguration/configurablecapturedeviceforprimarycamera
- https://developer.apple.com/documentation/arkit/ardepthdata
- https://developer.apple.com/documentation/arkit/ardepthdata/depthmap
- https://developer.apple.com/documentation/arkit/arframe/capturedimage
- https://developer.apple.com/documentation/arkit/arframe/exifdata
- https://developer.apple.com/documentation/arkit/argeometryelement
- https://developer.apple.com/documentation/arkit/armeshgeometry
- https://developer.apple.com/documentation/arkit/armeshgeometry/classification
- https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(completion
- https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- https://developer.apple.com/documentation/coreimage/cicontext
- https://developer.apple.com/documentation/coreimage/cirenderdestination/isflipped
- https://developer.apple.com/documentation/metalkit/mtktextureloader/newtexture(cgimage:options:)
- https://developer.apple.com/documentation/metalperformanceshaders/mpsimagestatisticsmeanandvariance
- https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_
- https://developer.apple.com/documentation/modelio/mdlutility/convert(tousdz:writeto:)
- https://developer.apple.com/documentation/realitykit/lowlevelmesh
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/attribute
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/part/init(indexoffset:indexcount:topology:materialindex:bounds:)
- https://developer.apple.com/documentation/realitykit/lowleveltexture
- https://developer.apple.com/documentation/realitykit/lowleveltexture/descriptor-swift.struct
- https://developer.apple.com/documentation/realitykit/meshbuffers
- https://developer.apple.com/documentation/realitykit/meshresource/init(from:)
- https://developer.apple.com/documentation/realitykit/modelentity/init(mesh:materials:)
- https://developer.apple.com/documentation/realitykit/textureresource/generate(from:withname:options:)
- https://developer.apple.com/documentation/realitykit/textureresource/init(image:withname:options:)
- https://developer.apple.com/documentation/realitykit/unlitmaterial/init(texture:)
- https://developer.apple.com/documentation/scenekit
- https://developer.apple.com/forums/thread/695404
- https://developer.apple.com/forums/thread/759333
- https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf
- https://developer.apple.com/videos/play/wwdc2022/10126/
- https://developer.apple.com/videos/play/wwdc2025/288/
- https://github.com/CariusLars/ar_flutter_plugin/issues/163
- https://github.com/WiseLabCMU/wisescan-ios/blob/main/docs/design/capture-quality-triage.md
- https://github.com/aabdlwahab/3d-scanner
- https://github.com/emin-grbo/WWDCLounges/blob/c4ecea0fbc126868aa96046fb91b34d7fc5ede06/docs/wwdc22/arkit-realitykit-usdz-lounge.md
- https://github.com/maxxfrazer/RealityGeometries/issues/3
- https://github.com/metal-by-example/metal-spatial-dynamic-mesh
- https://github.com/metal-by-example/sample-code/issues/11
- https://github.com/nianticlabs/map-free-reloc/issues/5
- https://github.com/suzuki-naoto/VisualizingAPointCloudUsingSceneDepth/blob/master/SceneDepthPointCloud/Shaders.metal
- https://openusd.org/release/spec_usdz.html
- https://raw.githubusercontent.com/aabdlwahab/3d-scanner/main/App/Sources/Core/Processing/TextureAtlasBuilder.swift
- https://raw.githubusercontent.com/aabdlwahab/3d-scanner/main/App/Sources/Core/Processing/ViewSelector.swift

### Rendering and viewer

- https://andrewgrant.org/2020/04/using-the-2020-ipads-armeshanchor-with-scenekit/
- https://developer.apple.com/documentation/arkit/armeshgeometry
- https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- https://developer.apple.com/documentation/metal/mtlrendercommandencoder/settrianglefillmode(_:)
- https://developer.apple.com/documentation/metalkit/mtkview
- https://developer.apple.com/documentation/realitykit/anchorentity
- https://developer.apple.com/documentation/realitykit/anchorentity/init(anchor:)
- https://developer.apple.com/documentation/realitykit/arview
- https://developer.apple.com/documentation/realitykit/arview/debugoptions-swift.struct/showsceneunderstanding
- https://developer.apple.com/documentation/realitykit/arview/environment-swift.struct/background-swift.struct
- https://developer.apple.com/documentation/realitykit/arview/environment-swift.struct/background-swift.struct/camerafeed(exposurecompensation:)
- https://developer.apple.com/documentation/realitykit/arview/environment-swift.struct/sceneunderstanding-swift.struct/options-swift.struct
- https://developer.apple.com/documentation/realitykit/arview/hittest(_:query:mask:)
- https://developer.apple.com/documentation/realitykit/arview/init(frame:cameramode:)
- https://developer.apple.com/documentation/realitykit/arview/init(frame:cameramode:automaticallyconfiguresession:)
- https://developer.apple.com/documentation/realitykit/arview/project(_:)
- https://developer.apple.com/documentation/realitykit/arview/ray(through:)
- https://developer.apple.com/documentation/realitykit/arview/snapshot(savetohdr:completion:)-66jzu
- https://developer.apple.com/documentation/realitykit/billboardcomponent
- https://developer.apple.com/documentation/realitykit/cameracontrols
- https://developer.apple.com/documentation/realitykit/collisioncasthit/trianglehit-swift.property
- https://developer.apple.com/documentation/realitykit/collisioncasthit/trianglehit-swift.struct
- https://developer.apple.com/documentation/realitykit/collisioncomponent/init(shapes:mode:filter:)
- https://developer.apple.com/documentation/realitykit/custommaterial
- https://developer.apple.com/documentation/realitykit/custommaterial/init(surfaceshader:geometrymodifier:lightingmodel:)
- https://developer.apple.com/documentation/realitykit/entity/componentset
- https://developer.apple.com/documentation/realitykit/entity/isenabled
- https://developer.apple.com/documentation/realitykit/entitytargetvalue
- https://developer.apple.com/documentation/realitykit/inputtargetcomponent
- https://developer.apple.com/documentation/realitykit/lowlevelmesh
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/descriptor-swift.struct/allowsprimitiverestart
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/descriptor-swift.struct/init(vertexcapacity:vertexattributes:vertexlayouts:indexcapacity:indextype:)
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/init(descriptor:)
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/part/init(indexoffset:indexcount:topology:materialindex:bounds:)
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/replace(bufferindex:using:)
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/vertexsemantic/color
- https://developer.apple.com/documentation/realitykit/lowlevelmesh/withunsafemutablebytes(bufferindex:_:)
- https://developer.apple.com/documentation/realitykit/materialparametertypes/trianglefillmode
- https://developer.apple.com/documentation/realitykit/meshbuffercontainer
- https://developer.apple.com/documentation/realitykit/meshdescriptor
- https://developer.apple.com/documentation/realitykit/meshresource
- https://developer.apple.com/documentation/realitykit/meshresource/generate(from:)
- https://developer.apple.com/documentation/realitykit/meshresource/generatebox(size:cornerradius:)-2ovma
- https://developer.apple.com/documentation/realitykit/meshresource/generatetext(_:extrusiondepth:font:containerframe:alignment:linebreakmode:)
- https://developer.apple.com/documentation/realitykit/meshresource/init(from:)
- https://developer.apple.com/documentation/realitykit/modifying-realitykit-rendering-using-custom-materials
- https://developer.apple.com/documentation/realitykit/perspectivecameracomponent
- https://developer.apple.com/documentation/realitykit/perspectivecameracomponent/init(near:far:fieldofviewindegrees:)
- https://developer.apple.com/documentation/realitykit/physicallybasedmaterial/basecolor-swift.struct
- https://developer.apple.com/documentation/realitykit/physicallybasedmaterial/blending-swift.enum/transparent(opacity:)
- https://developer.apple.com/documentation/realitykit/pixelcasthit
- https://developer.apple.com/documentation/realitykit/realitycoordinatespaceprojecting
- https://developer.apple.com/documentation/realitykit/realitycoordinatespaceprojecting/hittest(point:in:query:mask:)
- https://developer.apple.com/documentation/realitykit/realitycoordinatespaceprojecting/project(point:to:)
- https://developer.apple.com/documentation/realitykit/realitycoordinatespaceprojecting/ray(through:in:to:)
- https://developer.apple.com/documentation/realitykit/realityview
- https://developer.apple.com/documentation/realitykit/realityview/init(make:update:)
- https://developer.apple.com/documentation/realitykit/realityviewcameracontent
- https://developer.apple.com/documentation/realitykit/scene/pixelcast(from:to:)
- https://developer.apple.com/documentation/realitykit/scene/raycast(origin:direction:length:query:mask:relativeto:)
- https://developer.apple.com/documentation/realitykit/shadergraphmaterial
- https://developer.apple.com/documentation/realitykit/shadergraphmaterial/init(materialxlabel:data:)
- https://developer.apple.com/documentation/realitykit/shaperesource/generatestaticmesh(from:)
- https://developer.apple.com/documentation/realitykit/shaperesource/generatestaticmesh(positions:faceindices:)
- https://developer.apple.com/documentation/realitykit/textureresource
- https://developer.apple.com/documentation/realitykit/textureresource/createoptions/init(semantic:mipmapsmode:)
- https://developer.apple.com/documentation/realitykit/textureresource/init(image:withname:options:)
- https://developer.apple.com/documentation/realitykit/unlitmaterial
- https://developer.apple.com/documentation/realitykit/unlitmaterial/color
- https://developer.apple.com/documentation/realitykit/unlitmaterial/faceculling-swift.property
- https://developer.apple.com/documentation/realitykit/unlitmaterial/init(texture:)
- https://developer.apple.com/documentation/realitykit/unlitmaterial/trianglefillmode-swift.property
- https://developer.apple.com/documentation/scenekit
- https://developer.apple.com/documentation/scenekit/scngeometrysource/init(buffer:vertexformat:semantic:vertexcount:dataoffset:datastride:)
- https://developer.apple.com/documentation/swiftui/view/realityviewcameracontrols(_:)
- https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes
- https://developer.apple.com/forums/thread/751764
- https://developer.apple.com/forums/thread/759449
- https://developer.apple.com/forums/thread/763404
- https://developer.apple.com/forums/thread/774411
- https://developer.apple.com/forums/thread/774697
- https://developer.apple.com/metal/Metal-RealityKit-APIs.pdf
- https://developer.apple.com/videos/play/wwdc2025/288/
- https://github.com/ThomasZhang223/Scale/blob/baaf6ef2d451959fe513b737a646e097ad75da24/apps/mobile/modules/object-measure/ios/ObjectMeasureNativeView.swift
- https://github.com/WiseLabCMU/wisescan-ios/blob/main/wisescan-ios/PointCloudManager.swift
- https://github.com/google-ar/arcore-ios-sdk/blob/dc6011fe12b08761241bb1524ca3839c6f6552fd/Examples/GeospatialExample/GeospatialExample/ARViewContainer.swift
- https://github.com/pookjw/MySwiftUI/blob/main/Sources/MyRealityFoundation/MeshResource.swift

### Floor plan and CAD output

- http://www.w3.org/2000/svg
- https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravity
- https://developer.apple.com/documentation/coregraphics/cgcontext/init(consumer:mediabox:_:)
- https://developer.apple.com/documentation/foundation/locale/measurementsystem-swift.property
- https://developer.apple.com/documentation/foundation/measurement/formatstyle
- https://developer.apple.com/documentation/foundation/measurement/formatstyle/init(width:locale:usage:numberformatstyle:)
- https://developer.apple.com/documentation/roomplan/capturedroom
- https://developer.apple.com/documentation/roomplan/capturedroom/floors
- https://developer.apple.com/documentation/roomplan/capturedroom/object/attributes
- https://developer.apple.com/documentation/roomplan/capturedroom/object/category-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/section
- https://developer.apple.com/documentation/roomplan/capturedroom/section/center
- https://developer.apple.com/documentation/roomplan/capturedroom/section/label-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/story
- https://developer.apple.com/documentation/roomplan/capturedroom/surface
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/category-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/category-swift.enum/door(isopen:)
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/completededges
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct/center
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct/endangle
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct/radius
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.struct/startangle
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/dimensions
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/parentidentifier
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/polygoncorners
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/transform
- https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions
- https://developer.apple.com/documentation/roomplan/capturedroomattribute
- https://developer.apple.com/documentation/roomplan/capturedstructure
- https://developer.apple.com/documentation/roomplan/capturedstructure/export(to:metadataurl:modelprovider:exportoptions:)
- https://developer.apple.com/documentation/roomplan/capturedstructure/rooms
- https://developer.apple.com/documentation/roomplan/roomcapturesession/init(arsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesession/stop(pauseARSession:)
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/documentation/roomplan/structurebuilder/builderror
- https://developer.apple.com/documentation/roomplan/structurebuilder/builderror/invalidroomlocation
- https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from:)
- https://developer.apple.com/documentation/roomplan/structurebuilder/init(options:)
- https://developer.apple.com/documentation/swiftui/canvas
- https://developer.apple.com/documentation/swiftui/draggesture/init(minimumdistance:coordinatespace:)
- https://developer.apple.com/documentation/swiftui/graphicscontext
- https://developer.apple.com/documentation/swiftui/graphicscontext/fill(_:with:style:)
- https://developer.apple.com/documentation/swiftui/graphicscontext/stroke(_:with:linewidth:)
- https://developer.apple.com/documentation/swiftui/graphicscontext/withcgcontext(content:)
- https://developer.apple.com/documentation/swiftui/imagerenderer
- https://developer.apple.com/documentation/swiftui/imagerenderer/render(rasterizationscale:renderer:)
- https://developer.apple.com/documentation/swiftui/magnificationgesture
- https://developer.apple.com/documentation/swiftui/magnifygesture
- https://developer.apple.com/documentation/swiftui/magnifygesture/init(minimumscaledelta:)
- https://developer.apple.com/documentation/swiftui/rotategesture
- https://developer.apple.com/documentation/swiftui/rotategesture/init(minimumangledelta:)
- https://developer.apple.com/documentation/swiftui/sharelink
- https://developer.apple.com/documentation/swiftui/spatialtapgesture
- https://developer.apple.com/documentation/swiftui/spatialtapgesture/init(count:coordinatespace:)
- https://developer.apple.com/documentation/swiftui/view/fileexporter(ispresented:document:contenttype:defaultfilename:oncompletion:)
- https://developer.apple.com/documentation/swiftui/view/fileexporter(ispresented:item:contenttypes:defaultfilename:oncompletion:oncancellation:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer/init(bounds:format:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer/writepdf(to:withactions:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderercontext/beginpage()
- https://developer.apple.com/documentation/uikit/uigraphicspdfrendererformat/documentinfo
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(exportedas:conformingto:)
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(filenameextension:conformingto:)
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/pdf
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/svg
- https://developer.apple.com/forums/thread/713409?page=1
- https://developer.apple.com/forums/thread/733945
- https://developer.apple.com/forums/thread/760952
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://ezdxf.readthedocs.io/en/stable/dxfinternals/filestructure.html
- https://github.com/BaidetskyiYurii/RoomPlanDemo/blob/main/RoomPlanDemo/FloorPlan/FloorPlanSurface.swift
- https://github.com/LibreCAD/LibreCAD/blob/master/librecad/src/lib/engine/document/lc_graphicvariables.cpp
- https://github.com/denniswave/RoomPlan-2D
- https://github.com/gromb57/ios-wwdc23__MergingMultipleScansIntoASingleStructure/blob/main/RoomPlanMultiscanMerging/RoomTableViewController.swift
- https://github.com/laanlabs/openPlan3D/blob/main/test-roomplan.json
- https://github.com/mozman/ezdxf/blob/master/src/ezdxf/entities/lwpolyline.py
- https://raw.githubusercontent.com/mozman/ezdxf/master/src/ezdxf/sections/headervars.py
- https://vdci.edu/learn/autocad/draw-doors-floor-plan-tools

### 3D export formats

- https://developer.apple.com/documentation/applearchive
- https://developer.apple.com/documentation/coretransferable/filerepresentation
- https://developer.apple.com/documentation/coretransferable/filerepresentation/init(exportedcontenttype:shouldallowtoopeninplace:exporting:)
- https://developer.apple.com/documentation/coretransferable/senttransferredfile/init(_:allowaccessingoriginalfile:)
- https://developer.apple.com/documentation/foundation/jsonserialization/data(withjsonobject:options:)
- https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:error:byaccessor:)
- https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading
- https://developer.apple.com/documentation/modelio/mdlasset
- https://developer.apple.com/documentation/modelio/mdlasset/add(_:)
- https://developer.apple.com/documentation/modelio/mdlasset/canexportfileextension(_:)
- https://developer.apple.com/documentation/modelio/mdlasset/canimportfileextension(_:)
- https://developer.apple.com/documentation/modelio/mdlasset/childobjects(of:)
- https://developer.apple.com/documentation/modelio/mdlasset/export(to:)
- https://developer.apple.com/documentation/modelio/mdlmaterial/init(name:scatteringfunction:)
- https://developer.apple.com/documentation/modelio/mdlmaterialproperty
- https://developer.apple.com/documentation/modelio/mdlmesh/addnormals(withattributenamed:creasethreshold:)
- https://developer.apple.com/documentation/modelio/mdlmesh/init(vertexbuffer:vertexcount:descriptor:submeshes:)
- https://developer.apple.com/documentation/modelio/mdlmeshbufferdata/init(type:data:)
- https://developer.apple.com/documentation/modelio/mdlsubmesh/init(indexbuffer:indexcount:indextype:geometrytype:material:)
- https://developer.apple.com/documentation/modelio/mdlutility
- https://developer.apple.com/documentation/modelio/mdlutility/convert(tousdz:writeto:)
- https://developer.apple.com/documentation/modelio/mdlvertexattribute/init(name:format:offset:bufferindex:)
- https://developer.apple.com/documentation/modelio/mdlvertexbufferlayout/init(stride:)
- https://developer.apple.com/documentation/quicklook/arquicklookpreviewitem
- https://developer.apple.com/documentation/quicklook/arquicklookpreviewitem/init(fileat:)
- https://developer.apple.com/documentation/quicklook/qlpreviewcontroller
- https://developer.apple.com/documentation/realitykit/entity/write(to:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession/issupported
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/issupported
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail/medium
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/modelfile(url:detail:geometry:)
- https://developer.apple.com/documentation/roomplan/capturedroom/export(to:exportoptions:)
- https://developer.apple.com/documentation/roomplan/capturedroom/export(to:metadataurl:modelprovider:exportoptions:)
- https://developer.apple.com/documentation/roomplan/capturedstructure/export(to:metadataurl:modelprovider:exportoptions:)
- https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from:)
- https://developer.apple.com/documentation/scenekit/scnscene/write(to:options:delegate:progresshandler:)
- https://developer.apple.com/documentation/scenekit/scnsceneexportdelegate/write(_:withscenedocumenturl:originalimageurl:)
- https://developer.apple.com/documentation/scenekit/scnsceneexportdestinationurl
- https://developer.apple.com/documentation/swiftui/sharelink/init(item:subject:message:preview:)
- https://developer.apple.com/documentation/swiftui/view/quicklookpreview(_:)
- https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/init(activityitems:applicationactivities:)
- https://developer.apple.com/documentation/uikit/uidocumentbrowserviewcontroller
- https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:)
- https://developer.apple.com/documentation/uikit/uigraphicsimagerenderer
- https://developer.apple.com/documentation/uikit/uigraphicsimagerenderer/pngdata(actions:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer/init(bounds:format:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderer/writepdf(to:withactions:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrenderercontext/beginpage(withbounds:pageinfo:)
- https://developer.apple.com/documentation/uikit/uigraphicspdfrendererformat/documentinfo
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(filenameextension:conformingto:)
- https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/usdz
- https://developer.apple.com/forums/thread/111061
- https://developer.apple.com/forums/thread/658109
- https://developer.apple.com/forums/thread/701842
- https://developer.apple.com/forums/thread/704590
- https://developer.apple.com/forums/thread/706609
- https://developer.apple.com/forums/thread/737766
- https://developer.apple.com/forums/thread/742077
- https://developer.apple.com/forums/thread/765329
- https://developer.apple.com/forums/thread/774459
- https://ezdxf.readthedocs.io/en/stable/dxfinternals/filestructure.html
- https://help.autodesk.com/cloudhelp/2017/ENU/AutoCAD-DXF/files/GUID-748FC305-F3F2-4F74-825A-61F04D757A50.htm
- https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification

### Scan quality, coverage and measurement confidence

- https://developer.apple.com/documentation/arkit/arcamera/exposureduration
- https://developer.apple.com/documentation/arkit/arcamera/intrinsics
- https://developer.apple.com/documentation/arkit/arcamera/projectpoint(_:viewrotationangle:viewportsize
- https://developer.apple.com/documentation/arkit/arcamera/projectpoint:orientation:viewportsize:
- https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum
- https://developer.apple.com/documentation/arkit/arcamera/unprojectpoint(_:ontoplane:orientation:viewportsize:)
- https://developer.apple.com/documentation/arkit/arcoachingoverlayview
- https://developer.apple.com/documentation/arkit/arconfidencelevel
- https://developer.apple.com/documentation/arkit/arconfiguration/supportedvideoformats
- https://developer.apple.com/documentation/arkit/arconfiguration/videoformat-swift.property
- https://developer.apple.com/documentation/arkit/ardepthdata
- https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap
- https://developer.apple.com/documentation/arkit/arframe/displaytransform(viewrotationangle:viewportsize
- https://developer.apple.com/documentation/arkit/arframe/rawfeaturepoints
- https://developer.apple.com/documentation/arkit/arframe/raycastquery(from:allowing:alignment:)
- https://developer.apple.com/documentation/arkit/arframe/scenedepth
- https://developer.apple.com/documentation/arkit/arframe/worldmappingstatus-swift.property
- https://developer.apple.com/documentation/arkit/arlightestimate/ambientintensity
- https://developer.apple.com/documentation/arkit/armeshanchor
- https://developer.apple.com/documentation/arkit/armeshclassification
- https://developer.apple.com/documentation/arkit/armeshgeometry/classification
- https://developer.apple.com/documentation/arkit/armeshgeometry/normals
- https://developer.apple.com/documentation/arkit/arplaneanchor/planeextent
- https://developer.apple.com/documentation/arkit/arplaneextent
- https://developer.apple.com/documentation/arkit/arraycastquery
- https://developer.apple.com/documentation/arkit/arsession/capturehighresolutionframe(completion:)
- https://developer.apple.com/documentation/arkit/arsession/raycast(_:)
- https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious
- https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property
- https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification
- https://developer.apple.com/documentation/realitykit/objectcapturesession/feedback-swift.enum
- https://developer.apple.com/documentation/realitykit/objectcapturesession/feedback-swift.enum/objectnotdetected
- https://developer.apple.com/documentation/realitykit/objectcapturesession/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/objectcapturesession/usercompletedscanpass
- https://developer.apple.com/documentation/roomplan/capturedroom/confidence
- https://developer.apple.com/documentation/roomplan/capturedroom/floors
- https://developer.apple.com/documentation/roomplan/capturedroom/surface
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/completededges
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/curve-swift.property
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/edge
- https://developer.apple.com/documentation/roomplan/capturedroom/surface/polygoncorners
- https://developer.apple.com/documentation/roomplan/roomcapturesession/configuration/iscoachingenabled
- https://developer.apple.com/documentation/roomplan/roomcapturesession/init(arsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction
- https://developer.apple.com/documentation/roomplan/roomcapturesession/stop(pausearsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate
- https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from:)
- https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
- https://developer.apple.com/documentation/uikit/uidevice/batterylevel
- https://developer.apple.com/forums/thread/732903
- https://developer.apple.com/forums/thread/763400
- https://developer.apple.com/videos/play/wwdc2020/10611/
- https://developer.apple.com/videos/play/wwdc2022/10127/
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://github.com/beatTheSystem42/MetalScanDemo/blob/main/Renderer.swift
- https://github.com/bzellman/MagicCuts/blob/9531ea9fb5e36cfb02ac72b96a48da5113eeabec/MagicCuts/Fieldwork/RoomSession.swift
- https://github.com/cristiangavidia23/structura/blob/97aeb635b201b07ba4c4e45e8bf550fa0532139f/Structura/Models/FloorPlan.swift
- https://github.com/pookjw/MySwiftUI/blob/c8f4de8599ea11426dff8c99f10e81298a9e3822/Sources/_MyRealityKit_MySwiftUI/ObjectCaptureSession.swift
- https://hackernoon.com/what-happens-when-you-max-out-an-iphone-thermal-throttling-in-real-time-ar
- https://machinelearning.apple.com/research/roomplan
- https://rerun.io/blog/arkitscenes-slam
- https://www.it-jim.com/blog/roomplan-framework-by-apple/
- https://www.mdpi.com/2673-7418/3/4/30
- https://www.nature.com/articles/s41598-021-01763-9
- https://www.sciencedirect.com/science/article/pii/S2666165923000510
- https://www.tandfonline.com/doi/full/10.1080/2150704X.2026.2720055

### Storage, deployment and concurrency

- https://developer.apple.com/documentation/arkit/arcamera/imageresolution
- https://developer.apple.com/documentation/arkit/armeshgeometry
- https://developer.apple.com/documentation/arkit/arscnview
- https://developer.apple.com/documentation/arkit/arsession/delegatequeue
- https://developer.apple.com/documentation/arkit/arsession/getcurrentworldmap(completionhandler:)
- https://developer.apple.com/documentation/arkit/arworldmap
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest
- https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/init(identifier:title:subtitle:)
- https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/register(fortaskwithidentifier:using:launchhandler:)
- https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/supportedresources
- https://developer.apple.com/documentation/bundleresources/entitlements
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription
- https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled
- https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen
- https://developer.apple.com/documentation/bundleresources/information-property-list/uirequireddevicecapabilities
- https://developer.apple.com/documentation/bundleresources/information-property-list/uisupportedinterfaceorientations
- https://developer.apple.com/documentation/coreimage/cicontext/writeheifrepresentation(of:to:format:colorspace:options
- https://developer.apple.com/documentation/foundation/data/init(bytesnocopy:count:deallocator
- https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification
- https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup
- https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacityforimportantusage
- https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize
- https://developer.apple.com/documentation/os/os_proc_available_memory
- https://developer.apple.com/documentation/realitykit/objectcapturesession
- https://developer.apple.com/documentation/realitykit/objectcapturesession/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/objectcapturesession/start(imagesdirectory:configuration:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.struct/maximuminputimagedimension
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.struct/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.type.property
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail
- https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions
- https://developer.apple.com/documentation/roomplan/capturedroomdata
- https://developer.apple.com/documentation/roomplan/roomcapturesession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/init(arsession:)
- https://developer.apple.com/documentation/scenekit
- https://developer.apple.com/documentation/simd/simd_float3x3
- https://developer.apple.com/documentation/simd/simd_float4x4
- https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files
- https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)
- https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
- https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app
- https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- https://developer.apple.com/forums/thread/702400
- https://developer.apple.com/forums/thread/797538
- https://developer.apple.com/forums/thread/85066
- https://developer.apple.com/forums/thread/96804
- https://github.com/SideStore/SideStore/issues/1616
- https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md
- https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- https://raw.githubusercontent.com/yonaskolb/XcodeGen/master/SettingPresets/base.yml
- https://sideloadly.io/faq.html
- https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/completechecking

### UX patterns

- https://developer.apple.com/documentation/arkit/arcoachingoverlayview
- https://developer.apple.com/documentation/arkit/arcoachingoverlayview/goal-swift.enum
- https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- https://developer.apple.com/documentation/foundation/locale/measurementsystem-swift.property
- https://developer.apple.com/documentation/foundation/measurementformatunitusage
- https://developer.apple.com/documentation/realitykit/arview/debugoptions-swift.struct/showsceneunderstanding
- https://developer.apple.com/documentation/realitykit/objectcapturepointcloudview/showshotlocations(_:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession
- https://developer.apple.com/documentation/realitykit/objectcapturesession/capturestate
- https://developer.apple.com/documentation/realitykit/objectcapturesession/configuration-swift.struct
- https://developer.apple.com/documentation/realitykit/objectcapturesession/feedback-swift.enum
- https://developer.apple.com/documentation/realitykit/objectcapturesession/isautocaptureenabled
- https://developer.apple.com/documentation/realitykit/objectcapturesession/maximumnumberofinputimages
- https://developer.apple.com/documentation/realitykit/objectcapturesession/pause()
- https://developer.apple.com/documentation/realitykit/objectcapturesession/shouldplayhaptics
- https://developer.apple.com/documentation/realitykit/objectcapturesession/start(imagesdirectory:configuration:)
- https://developer.apple.com/documentation/realitykit/objectcapturesession/startcapturing(
- https://developer.apple.com/documentation/realitykit/objectcapturesession/startdetecting()
- https://developer.apple.com/documentation/realitykit/objectcaptureview
- https://developer.apple.com/documentation/realitykit/objectcaptureview/hideobjectreticle(_:)
- https://developer.apple.com/documentation/realitykit/objectcaptureview/init(session:camerafeedoverlay:)
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail/custom
- https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail/medium
- https://developer.apple.com/documentation/roomplan/capturedroom/section/label-swift.enum
- https://developer.apple.com/documentation/roomplan/capturedroom/surface
- https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions
- https://developer.apple.com/documentation/roomplan/create-a-3d-model-of-an-interior-room-by-guiding-the-user-through-an-ar-experience
- https://developer.apple.com/documentation/roomplan/roomcapturesession
- https://developer.apple.com/documentation/roomplan/roomcapturesession/captureerror
- https://developer.apple.com/documentation/roomplan/roomcapturesession/configuration
- https://developer.apple.com/documentation/roomplan/roomcapturesession/configuration/iscoachingenabled
- https://developer.apple.com/documentation/roomplan/roomcapturesession/instruction
- https://developer.apple.com/documentation/roomplan/roomcapturesession/stop(pausearsession:)
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate
- https://developer.apple.com/documentation/roomplan/roomcapturesessiondelegate/capturesession(_:didprovide:)
- https://developer.apple.com/documentation/roomplan/roomcaptureview
- https://developer.apple.com/documentation/roomplan/roomcaptureview/capturesession
- https://developer.apple.com/documentation/roomplan/roomcaptureview/delegate
- https://developer.apple.com/documentation/roomplan/roomcaptureview/init(frame:arsession:)
- https://developer.apple.com/documentation/roomplan/roomcaptureview/ismodelenabled
- https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/documentation/roomplan/structurebuilder
- https://developer.apple.com/documentation/roomplan/structurebuilder/capturedstructure(from:)
- https://developer.apple.com/documentation/roomplan/structurebuilder/init(options:)
- https://developer.apple.com/documentation/swiftui/dynamictypesize
- https://developer.apple.com/documentation/swiftui/scaledmetric
- https://developer.apple.com/documentation/swiftui/sensoryfeedback
- https://developer.apple.com/documentation/swiftui/sharelink
- https://developer.apple.com/documentation/swiftui/sharelink/init(item:subject:message:preview:label:)
- https://developer.apple.com/documentation/swiftui/uiviewrepresentable
- https://developer.apple.com/documentation/swiftui/view/persistentsystemoverlays(_:)
- https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:)
- https://developer.apple.com/documentation/swiftui/view/sensoryfeedback(_:trigger:condition:)
- https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled
- https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:supportedinterfaceorientationsfor:)
- https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:)
- https://developer.apple.com/documentation/uikit/uiimpactfeedbackgenerator/init(style:view:)
- https://developer.apple.com/documentation/uikit/uiviewcontroller/setneedsupdateofsupportedinterfaceorientations()
- https://developer.apple.com/documentation/uikit/uiwindowscene/requestgeometryupdate(_:errorhandler:)
- https://developer.apple.com/forums/thread/654431
- https://developer.apple.com/forums/thread/708892
- https://developer.apple.com/forums/thread/736482
- https://developer.apple.com/videos/play/wwdc2022/10127/
- https://developer.apple.com/videos/play/wwdc2023/10191/
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://developer.apple.com/videos/play/wwdc2024/10107/
- https://github.com/XRealityZone/apple-wwdc-ar-demo/blob/main/CreateA3DModelOfAnInteriorRoomByGuidingTheUserThroughAnARExperience/RoomPlanExampleApp/RoomCaptureViewController.swift
- https://github.com/sfomuseum/ios-guided-capture/blob/main/GuidedCapture.xcodeproj/project.pbxproj
- https://github.com/sfomuseum/ios-guided-capture/blob/main/GuidedCapture/OnboardingStateMachine.swift
- https://github.com/sfomuseum/ios-guided-capture/blob/main/GuidedCapture/OnboardingTutorialView+LocalizedString.swift
- https://guidecalculator.com/conversion/inches-to-fraction-calculator
- https://help.magicplan.app/auto-scan-your-floor-plan
- https://learn.poly.cam/hc/en-us/articles/48565771018772-Which-Capture-Mode-Should-I-Use
- https://support.apple.com/en-za/102468
- https://support.canvas.io/article/10-tutorial-how-to-scan-a-room-with-canvas
