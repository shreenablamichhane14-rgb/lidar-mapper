# Research digest

Condensed per-topic digest of docs/research/raw and docs/research/verify (verify wins on disagreement), written for the architecture synthesis. docs/RESEARCH.md, when merged, is the reference of record.

## arkit-mesh-depth

Sources: `docs/research/raw/arkit-mesh-depth.json` (researcher facts, plus a docs verdict and a reality verdict for each claim) and `docs/research/verify/arkit-mesh-depth.json` (tie-breaker). Everything below works with an iOS 18.0 deployment target, Swift 5.9 mode and the iOS 26 SDK (Xcode 26.6) unless it is flagged. None of the mesh, depth, raycast, world-map or session APIs listed here were removed or deprecated at iOS 26. The highest floor any of them needs is iOS 17, for `RoomCaptureSession(arSession:)`.

### 1. Verified APIs (safe on iOS 18.0)

**Scene reconstruction (iOS 13.4+)**
- `var sceneReconstruction: ARConfiguration.SceneReconstruction { get set }` on `ARWorldTrackingConfiguration`
- `struct ARConfiguration.SceneReconstruction` (OptionSet) has `.mesh` and `.meshWithClassification`, plus `init(rawValue: UInt)`.
- `class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool` returns true only on LiDAR devices. `class var isSupported: Bool` exists since iOS 11.

**Scene depth (iOS 14.0+)**
- `var frameSemantics: ARConfiguration.FrameSemantics { get set }` has been available since iOS 13. The `.sceneDepth` and `.smoothedSceneDepth` values need iOS 14.
- `class func supportsFrameSemantics(_:) -> Bool`
- `ARFrame`: `var sceneDepth: ARDepthData? { get }` and `var smoothedSceneDepth: ARDepthData? { get }`. Both are nil unless the matching semantic is enabled.
- `class ARDepthData`:
  - `unowned(unsafe) var depthMap: CVPixelBuffer { get }` uses `kCVPixelFormatType_DepthFloat32` ('fdep'). Values are Float32 metres from the camera plane. In Metal use `.r32Float`.
  - `unowned(unsafe) var confidenceMap: CVPixelBuffer? { get }` uses `kCVPixelFormatType_OneComponent8` ('L008'). In Metal use `.r8Uint` or `.r8Unorm`.
- `enum ARConfidenceLevel: Int { case low, medium, high }` has raw values 0, 1 and 2 and is Comparable.

**Mesh (iOS 13.4+; subscripts iOS 14.0+)**
- `class ARMeshAnchor : ARAnchor` with `var geometry: ARMeshGeometry { get }`. It inherits `transform` and `identifier: UUID`, which stays stable across updates. It does not conform to ARTrackable.
- `class ARMeshGeometry` has these members:
  - `var vertices: ARGeometrySource`
  - `var normals: ARGeometrySource`
  - `var faces: ARGeometryElement`
  - `var classification: ARGeometrySource?`
- `class ARGeometrySource`:
  - Members: `buffer: any MTLBuffer` (shared storage, readable by CPU and GPU), `count`, `format: MTLVertexFormat`, `componentsPerVector`, `offset`, `stride`.
  - Subscripts: `@nonobjc subscript(index: Int32) -> (Float, Float, Float)` and `-> CUnsignedChar`.
- `class ARGeometryElement`:
  - Members: `buffer`, `count` (the number of faces), `bytesPerIndex` (4, meaning UInt32), `indexCountPerPrimitive` (3), `primitiveType: ARGeometryPrimitiveType` (`.line`, `.triangle`).
  - Subscript: `@nonobjc subscript(index: Int) -> [Int32]`.
- `enum ARMeshClassification: Int` has raw values none=0, wall=1, floor=2, ceiling=3, table=4, seat=5, window=6, door=7.

**Delegate and session (iOS 11+)**
- `ARSessionDelegate` callbacks:
  - `session(_:didUpdate frame: ARFrame)`
  - `session(_:didAdd anchors:)`, `session(_:didUpdate anchors:)`, `session(_:didRemove anchors:)`
  - `session(_:cameraDidChangeTrackingState:)`
  - `sessionWasInterrupted(_:)` and `sessionInterruptionEnded(_:)`
  - `sessionShouldAttemptRelocalization(_:) -> Bool` (iOS 11.3)
  - `session(_:didFailWithError:)`
- `ARSession` members:
  - `weak var delegate: (any ARSessionDelegate)?`
  - `var delegateQueue: dispatch_queue_t?`
  - `@NSCopying var currentFrame: ARFrame?`
  - `@NSCopying var configuration: ARConfiguration?`
  - `var identifier: UUID` (iOS 13)
  - `setWorldOrigin(relativeTransform:)`
- `func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])` and `pause()`
- `ARSession.RunOptions`: `.resetTracking`, `.removeExistingAnchors`, `.stopTrackedRaycasts`, `.resetSceneReconstruction`

**Camera and frame (iOS 11+)**
- `ARCamera` members:
  - `transform` (camera to world)
  - `intrinsics: simd_float3x3` (column-major: `[0][0]`=fx, `[1][1]`=fy, `[2][0]`=ox, `[2][1]`=oy, all in capturedImage pixels)
  - `imageResolution: CGSize`
  - `projectionMatrix`
  - `trackingState: ARCamera.TrackingState` (`.notAvailable`, `.limited(Reason)`, `.normal`; the reasons are `.initializing`, `.excessiveMotion`, `.insufficientFeatures`, `.relocalizing`)
  - `exposureDuration` and `exposureOffset` (iOS 13)
- `ARFrame.capturedImage` is a CVPixelBuffer in '420f' format (plane 0 is Y as `.r8Unorm`, plane 1 is CbCr as `.rg8Unorm`) in landscape sensor orientation. It also has `timestamp` and `exifData` (iOS 16).
- `ARFrame.worldMappingStatus` (iOS 12) takes `.notAvailable`, `.limited`, `.extending` or `.mapped`.
- Orientation helpers should be called with these Swift spellings:
  - `projectionMatrix(for:viewportSize:zNear:zFar:)`
  - `viewMatrix(for:)`
  - `projectPoint(_:orientation:viewportSize:)`
  - `@nonobjc unprojectPoint(_:ontoPlane:orientation:viewportSize:) -> simd_float3?` (iOS 12)
  - `ARFrame.displayTransform(for:viewportSize:)`

  They are not deprecated in the iOS 26.5 SDK headers, so Xcode 26.6 gives no warning. Deprecation arrives only with the iOS 27 SDK. The projection is aspect-fill, and `zFar == 0` returns an infinite projection.

**World map (iOS 12+)**
- `class ARWorldMap` (NSSecureCoding) has `anchors`, `center`, `extent` and `rawFeaturePoints`.
- `ARSession` provides `getCurrentWorldMap(completionHandler: @escaping @Sendable (ARWorldMap?, (any Error)?) -> Void)`. The async form `currentWorldMap() async throws` is not in the doc topics but is auto-imported and compiles in shipped code.
- `ARWorldTrackingConfiguration` has `var initialWorldMap: ARWorldMap?`.
- To archive, call `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)`. To restore, call `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)`, then run with `[.resetTracking, .removeExistingAnchors]`.

**Raycast (iOS 13.0+; mesh hits need 13.4 scene reconstruction)**
- `ARRaycastQuery(origin:direction:allowing:alignment:)`
- `ARRaycastQuery.Target` has `.existingPlaneGeometry`, `.existingPlaneInfinite` and `.estimatedPlane`. `ARRaycastQuery.TargetAlignment` has `.horizontal`, `.vertical` and `.any`.
- `ARFrame.raycastQuery(from:allowing:alignment:) -> ARRaycastQuery` is non-optional. Its point is **normalized 0..1 with a top-left origin**, not view points.
- `ARSession.raycast(_:) -> [ARRaycastResult]` returns results nearest first. `trackedRaycast(_:updateHandler:) -> ARTrackedRaycast?` is also available.
- `ARRaycastResult` has `worldTransform`, `anchor?`, `target` and `targetAlignment`.
- RealityKit: `ARView.raycast(from:allowing:alignment:)` is `@MainActor` and takes view points.
- Only `.estimatedPlane` with `.any` hits the LiDAR mesh.

**Hi-res stills (iOS 16.0+)**
- `func captureHighResolutionFrame(completion: @escaping @Sendable (ARFrame?, (any Error)?) -> Void)` and `func captureHighResolutionFrame() async throws -> ARFrame`
- `class var recommendedVideoFormatForHighResolutionFrameCapturing: ARConfiguration.VideoFormat?` and `VideoFormat.isRecommendedForHighResolutionFrameCapturing`
- Error codes: `ARError.Code.highResolutionFrameCaptureInProgress` and `.highResolutionFrameCaptureFailed`

**Video format, planes and light**
- Video format: `supportedVideoFormats` and `videoFormat` (iOS 11.3); `VideoFormat.imageResolution` and `framesPerSecond`; `captureDeviceType` (iOS 14.5); `recommendedVideoFormatFor4KResolution`, `videoHDRAllowed` and `isVideoHDRSupported` (iOS 16).
- Planes:
  - `planeDetection = [.horizontal, .vertical]`
  - `ARPlaneAnchor` has `classification` (iOS 12), `geometry: ARPlaneGeometry` (iOS 11.3) and `planeExtent: ARPlaneExtent` (`width`, `height`, `rotationOnYAxis`; iOS 16).
- Light: `isLightEstimationEnabled` and `lightEstimate.ambientIntensity/ambientColorTemperature`. The enum is `ARWorldTrackingConfiguration.EnvironmentTexturing`. `ARConfiguration.EnvironmentTexturing` does not exist.
- Thermal: `ProcessInfo.processInfo.thermalState` and `ProcessInfo.thermalStateDidChangeNotification`.

**RoomPlan interop**
- `RoomCaptureSession` (iOS 16):
  - `init(arSession: ARSession? = nil)` (iOS 17)
  - `var arSession: ARSession` is set at init and throws if you assign it later.
  - `func stop(pauseARSession: Bool = true)` (iOS 17). The default is **true**.
  - `weak var delegate`
  - `captureSession(_:didStartWith configuration: RoomCaptureSession.Configuration)` (iOS 16)
- `RoomCaptureView` has `@MainActor init(frame: CGRect, arSession: ARSession)` (iOS 17).

### 2. Disputed or refuted claims and tie-breaker verdicts

**REFUTED: "your ARWorldTrackingConfiguration stays in effect after `RoomCaptureSession.run(configuration:)`".**
- In practice RoomPlan re-runs the shared session with its own configuration, and **`sceneDepth` disappears**. `videoFormat` and other frame semantics may also be replaced. Evidence: Apple forum threads 763400 (accepted answer), 808834 and 710134.
- The doc sentence "RoomPlan preserves all of the AR session's settings" is a parameter note on `RoomCaptureView.init(frame:arSession:)` only. It does not cover the headless `RoomCaptureSession`.
- **Required fix:** inside `captureSession(_:didStartWith:)`, call `arSession.run(myConfig)` again with **no options** (`[]`). Never pass `.resetTracking` or `.removeExistingAnchors` there, because that loses the shared world origin.
  - One community repo passed `.resetSceneReconstruction` at this step. The tie-breaker says no options.
  - Repeat the re-apply after every `run(configuration:)`, which means once per room.
  - Configuration changes are not immediate, so check a few frames later.
  - Add a watchdog that re-applies the configuration if `frame.sceneDepth == nil`.

**DISPUTED, resolved: "RoomPlan takes the single `ARSession.delegate` slot; do not set it".**
- This came from the raw reality verdict. The tie-breaker rejected it.
- The app MAY and SHOULD set `arSession.delegate = self` before `run()`.
- Supporting evidence: Apple's article "Scanning the rooms of a single structure" implements ARSessionObserver callbacks, the author of forum 763400 reads sceneDepth through the delegate, and facebookresearch/ocean does the same.
- Polling `currentFrame` is only a fallback.

**Multi-room continuity.**
- `stop(pauseARSession: false)` followed by `run(configuration:)` on the **same** `RoomCaptureSession` is Apple's documented path. ARWorldMap relocalization is the fallback.
- StackOverflow 79208951 reports tracking loss, but it concerns creating a new `RoomCaptureView` for each room. Do not do that.

**Hi-res frame and sceneDepth.**
- The raw research said depth is probably nil on the hi-res frame. The tie-breaker (Apple staff, forum 805839, Nov 2025) says `sceneDepth.depthMap` **is** delivered on hi-res frames when `.sceneDepth` is enabled. Confidence is "likely".
- Expect the regular low-resolution depth map, not photo-sized depth. Scale the intrinsics accordingly; this point is unverified.
- `capturedDepthData` exists only with ARFaceTrackingConfiguration.
- Passing `AVCapturePhotoSettings` with `isDepthDataDeliveryEnabled = true` throws.

**Minor corrections**
- ARMeshAnchor does conform to NSSecureCoding, inherited from ARAnchor. It is excluded from ARWorldMap by the framework (DTS, forum 705469), not because it lacks the conformance.
- Normals are per vertex. The iOS 18 header says "Normal of each vertex". The web doc's "each face" wording is stale.

### 3. APIs that must not be used unguarded

**iOS 27 only.** These are absent from the iOS 26.5 SDK and fail to compile on Xcode 26.6:
- `projectionMatrix(viewRotationAngle:viewportSize:zNear:zFar:)`
- `viewMatrix(viewRotationAngle:)`
- `projectPoint(_:viewRotationAngle:viewportSize:)`
- `unprojectPoint(_:ontoPlane:viewRotationAngle:viewportSize:)`
- `ARFrame.displayTransform(viewRotationAngle:viewportSize:)`
- `ARSession.viewRotationAngle`
- `session(_:didChangeViewRotationAngle:)`

**iOS 26 only.** Use these only inside `#available(iOS 26, *)`:
- `captureHighResolutionFrame(using: AVCapturePhotoSettings?, completion:)` and its async form
- `ARConfiguration.VideoFormat.defaultPhotoSettings`
- `VideoFormat.defaultColorSpace`

**Deprecated, do not use:**
- `ARFrame.hitTest(_:types:)` and `ARHitTestResult` (deprecated in iOS 14)
- `ARPlaneAnchor.extent` (use `planeExtent`)
- SceneKit as a whole (deprecated in iOS 26), including the `SCNGeometrySource(buffer:...)` bridge. It still compiles but gives warnings. Prefer ModelIO or RealityKit for export.

**Not SDK API:** `classificationOf(faceWithIndex:)`, `centerOf(faceWithIndex:)`, `vertex(at:)` and `vertexIndicesOf(faceWithIndex:)` are extensions from Apple's sample code. Write them yourself.

There are no macOS-only APIs in this topic. All ARKit here is iOS and iPadOS only.

### 4. Gotchas with numbers

**Depth map**
- The depth map is **256x192**, in landscape, with the same field of view and aspect ratio as the 1920x1440 `capturedImage`. This size is hard-coded in Apple's sample but not documented, so read `CVPixelBufferGetWidth/Height` at runtime.
- Depth arrives at 60 Hz with 1920x1440@60. It drops to **30 Hz** with the 4K 3840x2160@30 format.
- Useful range is about **0.5 to 5 m**. That is guidance, not an API limit.
- Unprojecting a depth pixel:
  - Scale fx, ox by 256/1920 and fy, oy by 192/1440.
  - Compute `x=(u-cx)d/fx`, `y=(v-cy)d/fy`.
  - ARKit camera space looks down **-z**, so world = `camera.transform * float4(x, -y, -d, 1)`.
  - Check against a known floor point on the first device run.

**Mesh geometry and buffers**
- Mesh vertices are **anchor-local**. Multiply by `anchor.transform`, or every chunk lands at the origin.
- `stride` can be greater than 12, so never assume it.
- Classification is **1 UInt8 per face** and is nil with `.mesh`. Normals are per vertex.
- ARMeshGeometry buffers are reused or reallocated on the next update. **Copy the bytes inside the callback**, and never wrap the MTLBuffer by reference.

**Mesh chunks**
- Chunk size is undocumented. Community figures say about 1 m square chunks, denser up close.
- A room is on the order of tens of anchors and around 10^5 triangles. This figure is unsure and needs a device measurement.
- Mesh anchors can be **removed and re-added 5 to 30 s later** (iPad Pro report). Do not delete cached chunks on `didRemove`.

**Plane detection and people occlusion**
- Enabling `planeDetection` flattens the mesh where planes are detected.
- The people-occlusion semantics remove mesh where people overlap it.

**World map**
- ARWorldMap does not store ARMeshAnchors. Only planes and custom ARAnchors are persisted.
- Size is unmeasured (community estimate: single-digit to tens of MB per room).
- Relocalization stays `.limited(.relocalizing)` **indefinitely** if the place does not match.
- Save only when `worldMappingStatus` is `.extending` or `.mapped`.

**Hi-res stills**
- Only one capture can be in flight at a time (`.highResolutionFrameCaptureInProgress`), so serialize requests.
- 12 MP (4032x3024) is available **only** with a format where `isRecommendedForHighResolutionFrameCapturing == true`. Measured time elsewhere was 61 to 68 ms with the mesh running.
- 16:9 hiRes formats reportedly give **zero mesh** on iPads. 4:3 formats (1920x1440 [hiRes]) are mesh-safe.
- One unconfirmed report says the recommended hi-res format plus `.sceneDepth` throws at `run`.
- The hi-res frame's field of view can differ from the stream (seen on an iPhone 12 mini). Always use the hi-res frame's own `intrinsics` and `imageResolution`.
- `.quality` photo prioritization is refused (ARError 107).

**Threading and frames**
- Delegate callbacks run on the main queue by default. Set `delegateQueue` to a serial background queue, and touch UI and RealityKit only on main.
- Retaining ARFrames starves capture and tracking goes limited. Copy the pixel buffer and drop the frame.
- `trackedRaycast` handlers run on the delegate queue.

**Configuration changes**
- Changing `videoFormat`, `frameSemantics` or `sceneReconstruction` requires `run(config)` again.
- Default options keep tracking and anchors, but a format change can briefly stall frames.
- To change settings, mutate a copy of `session.configuration`.

**Thermal and raycast**
- A multi-minute LiDAR scan will reach `.serious`. Throttling lowers the frame rate, which causes mesh drift.
- `.estimatedPlane` hits give only `worldTransform`. There is no face index or classification, and `anchor` is nil unless the ray also hits a plane.

### 5. Recommendations

1. **One app-owned `ARSession`.**
   - Configuration: `sceneReconstruction = .meshWithClassification`, `frameSemantics = [.sceneDepth]` (add `.smoothedSceneDepth` only for display), `planeDetection = [.horizontal, .vertical]`, `environmentTexturing = .none`.
   - `videoFormat` is chosen explicitly from `supportedVideoFormats`: 4:3, `isRecommendedForHighResolutionFrameCapturing`. Fall back to `[0]`.
   - Guard with `supportsSceneReconstruction` and `supportsFrameSemantics`.
   - If an ARView is used, set `automaticallyConfigureSession = false`.
2. **RoomPlan pattern:**
   - Set `delegate` before running.
   - Run your own configuration.
   - Create `RoomCaptureSession(arSession:)` and call `run(configuration:)`.
   - Re-apply your configuration with `[]` in `didStartWith`, and keep the depth-nil watchdog.
   - Between rooms, call `stop(pauseARSession: false)` and reuse the same `RoomCaptureSession`.
   - Use ARWorldMap as the fallback. Resuming a scan should be best-effort, with a "start fresh" option that begins a new, separately aligned segment.
3. **Mesh store:**
   - Key it by `ARMeshAnchor.identifier`.
   - Store world-space Float32 positions and normals, UInt32 indices and UInt8 face classes.
   - Replace an entry wholesale on `didUpdate`, and mark it stale (do not delete it) on `didRemove`.
   - Serialize it yourself as binary blobs plus a JSON manifest. This is the raw scan and is never modified.
   - Optionally add a plain `ARAnchor` for each chunk to the world map.
4. **Textures:**
   - Take hi-res keyframes only when `trackingState == .normal`, about every 0.5 m or 20 degrees of camera motion.
   - For each keyframe, store the JPEG plus `transform`, `intrinsics` and `imageResolution`.
   - Do not texture per frame from the 60 fps stream.
5. **Depth:** use `sceneDepth` (not smoothed) with confidence of at least `.medium` for any fusion. The mesh is the primary surface.
6. **Picking:** use `session.raycast` with `.estimatedPlane` and `.any` for quick taps. For snapping, normals and classification, use a CPU Moller-Trumbore ray-triangle test over the cached mesh, with a BVH or bounding box per chunk.
7. **Thermal policy:**
   - At `.serious`: drop smoothed depth and hi-res captures, and lower `preferredFramesPerSecond` to 30.
   - At `.critical`: pause the session and tell the user.
   - During scans set `isIdleTimerDisabled = true`.
8. **Log these on the first device build:**
   - `arSession.configuration` (videoFormat, frameSemantics, sceneReconstruction, planeDetection) before RoomPlan starts, after `didStartWith`, and after the re-apply, for every room.
   - The rate of frames where `sceneDepth != nil`.
   - `depthMap` size and format, including on hi-res frames.
   - The `supportedVideoFormats` list.
   - Per-anchor vertex and face counts and update intervals.
   - Anchor remove and re-add churn.
   - Archived world-map size and relocalization time.

## roomplan

Sources: `docs/research/raw/roomplan.json` (21 facts, 16 two-lens verdicts) and `docs/research/verify/roomplan.json` (1 tie-breaker, 6 open-question answers). Where the two disagree, verify/ wins.

### 1. Verified APIs (safe on iOS 18.0, Swift 5.9 mode)

A crawl of Apple's doc JSON found 276 RoomPlan pages. Their iOS introduction versions are 152 at 16.0, 122 at 17.0, and none at 18.x or 26.x. Nothing is deprecated, unavailable or beta on the iOS 26 SDK. The iOS 17, 18 and 26 release notes never mention RoomPlan. With a deployment target of 18.0, no `#available` guards are needed anywhere in RoomPlan. Framework platforms are iOS, iPadOS and Mac Catalyst 16.0+. There is no native macOS and no visionOS.

**RoomCaptureSession** (class, iOS 16.0)
```swift
init()                                         // 16.0
init(arSession: ARSession? = nil)              // 17.0
static var isSupported: Bool { get }           // 16.0, true iff LiDAR
func run(configuration: RoomCaptureSession.Configuration)
func stop()                                    // 16.0
func stop(pauseARSession: Bool = true)         // 17.0
weak var delegate: (any RoomCaptureSessionDelegate)?
var arSession: ARSession                       // read-only; setting it throws
struct Configuration { init(); var isCoachingEnabled: Bool /* default true */ }
enum Instruction: Equatable, Hashable { case normal, moveCloseToWall, moveAwayFromWall, turnOnLight, slowDown, lowTexture }   // NOT CaseIterable
enum CaptureError: Error, LocalizedError, Hashable { case deviceNotSupported, deviceTooHot, exceedSceneSizeLimit, invalidARConfiguration, worldTrackingFailure, internalError }
```

**RoomCaptureSessionDelegate** (all methods have default empty implementations, so copy these signatures exactly)
```swift
func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration)
func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom)   // full snapshot
func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?)
```

**RoomCaptureView** (iOS 16.0): `@MainActor @objc @preconcurrency class RoomCaptureView: UIView`
- Initializers: `init(frame:)`, `init(frame: CGRect, arSession: ARSession)` (17.0).
- Properties: `var captureSession: RoomCaptureSession!`, `var delegate`, `var isModelEnabled: Bool`.
- `RoomCaptureViewDelegate: NSCoding` has two methods:
  - `captureView(shouldPresent: CapturedRoomData, error:) -> Bool` (default true)
  - `captureView(didPresent: CapturedRoom, error:)`

**Builders**
```swift
class RoomBuilder { init(options: RoomBuilder.ConfigurationOptions)
  func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom
  enum BuildError { case insufficientInput, invalidInput, exceedSceneSizeLimit, internalError, deviceNotSupported } }
struct RoomBuilder.ConfigurationOptions: OptionSet { static let beautifyObjects }   // the only option
class StructureBuilder { init(options: StructureBuilder.ConfigurationOptions)          // 17.0, typealias of RoomBuilder's
  func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure
  enum BuildError { case deviceNotSupported, exceedSceneSizeLimit, insufficientInput, internalError, invalidInput, invalidRoomLocation } }
```

**Data model.** Every type below is `Codable` and `Sendable`, and every property is get-only. There is no public memberwise init.
- `CapturedRoomData` (16.0) is opaque.
- `CapturedRoom` members:
  - `identifier: UUID`, `walls`, `doors`, `windows`, `openings: [Surface]`, `objects: [Object]` (all 16.0)
  - `story: Int`, `version: Int`, `floors: [Surface]`, `sections: [Section]` (all 17.0)
  - `enum Confidence { high, medium, low }`
  - `enum Error { deviceNotSupported, urlInvalidFileExtension, urlInvalidFilePath, urlInvalidScheme, urlMissingFileExtension }`
- `CapturedRoom.Surface` members:
  - `identifier`, `category`, `confidence`, `transform: simd_float4x4`, `dimensions: simd_float3`, `completedEdges: Set<Edge>`, `curve: Curve?`
  - `parentIdentifier: UUID?`, `story`, `polygonCorners: [simd_float3]` (all 17.0, polygon corners are in local plane coordinates)
  - `enum Category { floor, door(isOpen: Bool), opening, wall, window }` is Hashable but not CaseIterable.
  - `Edge { top, bottom, left, right }` is CaseIterable.
  - `Curve` has `startAngle`, `endAngle: Measurement<UnitAngle>`, `radius: Float`, `center: simd_float2`.
- `CapturedRoom.Object` members:
  - `identifier`, `category`, `confidence`, `transform`, `dimensions` (a bounding box)
  - `parentIdentifier`, `story`, `attributes: [any CapturedRoomAttribute]`, `attribute<T>(of:) -> T?` (all 17.0)
  - `Category` is CaseIterable with 16 cases: bathtub, bed, chair, dishwasher, fireplace, oven, refrigerator, sink, sofa, stairs, storage, stove, table, television, toilet, washerDryer.
- Attributes (17.0), only for chair, sofa, storage and table: `ChairType`, `ChairArmType`, `ChairLegType`, `ChairBackType`, `SofaType`, `StorageType`, `TableType`, `TableShapeType`, plus `CapturedRoom.AttributesCodableRepresentation`.
- `CapturedRoom.Section` (17.0) has `label`, `story`, `center: simd_float3`.
  - `Section.Label: String` has cases livingRoom, kitchen, diningRoom, bedroom, bathroom, unidentified.
  - CaseIterable is not listed in its conformances.
- `CapturedStructure` (17.0) has `identifier`, `version`, `rooms: [CapturedRoom]`, `walls`, `doors`, `windows`, `openings`, `floors`, `objects`, `sections`. Surface, Object, Section, USDExportOptions and Error are typealiases of the `CapturedRoom` types.

**Export**
```swift
func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws        // CapturedRoom only, 16.0
func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil,
            exportOptions: CapturedRoom.USDExportOptions = .mesh) throws                     // 17.0; CapturedStructure has ONLY this form
struct CapturedRoom.USDExportOptions: OptionSet { init(rawValue: Int32); static let parametric, mesh, model }
```
- The shorter selector `export(to:metadataURL:exportOptions:)` does not exist.
- `CapturedRoom.ModelProvider` (17.0) provides `setModelFileURL(_:for:)` by category or attribute set, and the `modelFileURL(for:)` variants. Model files must be .usdc (preferred), .abc, .obj, .ply or .stl.

### 2. Disputed or refuted claims and verdicts

| Claim | Verdict |
|---|---|
| RoomPlan installs its own `ARSessionDelegate`, and replacing `arSession.delegate` blacks out the preview or breaks SLAM, so you must multiplex or use `ARSCNViewDelegate`. | **REFUTED (tie-breaker).** Apple documents no RoomPlan-internal delegate. `ARSession.delegate` is `weak var delegate: (any ARSessionDelegate)? { get set }`, one weak slot. Meta's ocean sets `arSession.delegate = self` after `run()` and still gets every room callback. The only counter-evidence is two anecdotal repos. The tie-breaker also rejected the verifier's overstatement: Apple's multi-room article does not require the app to be the ARSession delegate, because `ARSCNViewDelegate: ARSessionObserver` also receives those callbacks. **Rule:** set your own delegate on your own ARSession before `RoomCaptureSession(arSession:)`, retain it strongly, and treat a multiplexer as an optional guard. |
| `sceneDepth` and `ARMeshAnchors` survive on a custom session. | **Not refuted, but likely NO for a bare `RoomCaptureSession`.** `run(configuration:)` appears to replace the ARSession configuration (forum threads 763400, 808834, 728601). Forum 728601 says the `RoomCaptureView` path behaves differently. The fix is to re-run your configuration inside `didStartWith` (see section 5). "Apple said in 2022 you cannot capture ARMeshAnchors during RoomPlan" is **unsourced**. |
| `.model` export option is iOS 17.0+. | **Correction:** the doc metadata says `.model` is 16.0. Only `ModelProvider` and the 4-argument export are 17.0. This does not matter at an 18.0 target. |
| `exceedSceneSizeLimit` after relocalization. | Confirmed (forum 775853, iPhone 15 Pro, no workaround). It arrives as `RoomCaptureSession.CaptureError.exceedSceneSizeLimit` through `didEndWith`, which is a different type from `StructureBuilder.BuildError.exceedSceneSizeLimit`. Handle both. |
| USDZ node names (`Mesh_grp/Arch_grp/Wall_N_grp`, `Object_grp/<Category>_grp`). | Community evidence only. Apple documents no naming scheme. |
| Metadata file is a String-to-UUID plist. | The String-to-UUID dictionary is confirmed (WWDC23). Its encoding (plist or JSON) is **undocumented**. An extension is required (`urlMissingFileExtension`). |
| iOS 18 improves wall boundaries and fixes the file-name bug. | Comes from an it-jim blog and was not fetched. Treat it as unverified behaviour, not an API fact. |
| Forum thread 707803 ("RoomPlan owns the ARSession"). | Now returns 403, so it cannot be checked. That advice concerned rendering, not delegate ownership. |

### 3. Platform scope: macOS-only and iOS 26-only APIs

- **No RoomPlan API is macOS-only or iOS 26-only.** Nothing needs an availability guard at an 18.0 target.
- **Mac Catalyst** can decode and export only. RoomPlan silently ignores capture-session calls there. This does not affect Mapper.
- **Simulator and non-LiDAR devices** cannot scan. Gate on `RoomCaptureSession.isSupported`.
- **RealityKit `ARView`** has no `ARSCNViewDelegate` renderer callbacks. Use `arView.session.currentFrame` or `scene.subscribe(to: SceneEvents.Update.self)`.

### 4. Key gotchas with numbers

**Limits** (Apple's recommendations, enforced by hard errors)
- One room: 30 x 30 ft (about 9 x 9 m) per WWDC22. The pipeline tolerates 15 x 15 m and ceilings up to 3.6 m.
- Multi-room: 2,000 sq ft (about 186 m2) in total, single floor, 1 to 4 bedrooms plus living, kitchen and dining. No room-count limit is documented.
- Scan length: keep each scan under 5 minutes (battery and thermal). Light: at least 50 lux.
- The hard errors are `deviceTooHot` and `exceedSceneSizeLimit`.

**Accuracy**
- Apple's ML paper gives detection rates, not centimetre accuracy:
  - walls and windows about 95% precision and recall, doors about 90%
  - objects 91% precision and 90% recall at 30% 3D-IoU, chairs worst at 83% / 87%
- Field reports range from 1 to 5 cm per wall up to 37 cm drift on a 6.45 m wall.
- Mirrors, glass, direct sun, dark surfaces and very high ceilings degrade results. Open doors let the scan leak into the next room.

**Final result and output**
- `stop()` can re-optimize the room. The last `didUpdate` snapshot is not final. The truth is the `didEndWith` data after `RoomBuilder`.
- Floors are rectangles while scanning and become polygons at the end.
- USDZ walls and floors have **no UV coordinates**, and Apple DTS says no API provides them (forum 763135). Objects are plain boxes.
- Before iOS 17.4, the USD file name must not start with a digit.
- The file extension picks the format, `.usdz` or `.usd`. The `.usd` form imports into more CAD tools.

**Delegates and sessions**
- `RoomCaptureSession.delegate` and `ARSession.delegate` are both **weak**. Keep strong references.
- `didEndWith` fires after every stop, including `stop(pauseARSession: false)`.
- `stop()` pauses the ARSession by default. Multi-room scanning needs `stop(pauseARSession: false)` on the same session. Going to the background breaks the shared coordinate space, and only `ARWorldMap` relocalization can recover it.
- `invalidARConfiguration` is raised when a custom session runs anything other than `ARWorldTrackingConfiguration`.

**Compile and CI round trips**
- A near-miss delegate signature silently falls back to the empty default implementation. Xcode warns "nearly matches defaulted requirement".
- `beautifyObjects` does not exist on `RoomCaptureSession.Configuration`, so setting it there fails to compile.
- A class conforming to `RoomCaptureViewDelegate` must implement `NSCoding`.
- Switching on `Surface.Category` needs `case .door(let isOpen)`.
- Neither `Instruction` nor `Section.Label` is CaseIterable. Do not use `allCases` on them.

**Threading**
- The delegate callback queue is undocumented.
- `RoomCaptureView` is `@MainActor`.
- `RoomBuilder` and `StructureBuilder` are `async`. Hop to the main actor before touching UI.
- One community project reports a watchdog crash caused by work on RoomPlan's delegate queue. Keep callbacks cheap.

**Coordinates and persistence**
- Transforms appear to be in ARSession world space, y-up, in meters ("likely", not verified). Project floor plans using `floors[].transform`. Do not assume y == 0.
- The Codable JSON schema is Apple-private and versioned through the `version` property. Do not treat it as an interchange format.
- `Instruction.normal` arrives continuously. Debounce the coaching text.
- A free Apple ID is enough. No entitlements are needed beyond `NSCameraUsageDescription`.

### 5. Recommendations

1. **Use `RoomCaptureSession` directly with your own `ARSession`**, and draw the UI in your own `ARView` or `ARSCNView` bound to that session.
   - Set `arSession.delegate` (and optionally `delegateQueue`) before calling `RoomCaptureSession(arSession:)`, then call `run(configuration:)`.
   - After `didStartWith`, log whether `session.arSession.delegate === mapperDelegate`. Install a forwarding multiplexer only if a device log shows RoomPlan replaced it.
2. **Opportunistic depth and mesh during a RoomPlan scan:**
   - Check `supportsSceneReconstruction(.meshWithClassification)` and `supportsFrameSemantics(.sceneDepth)`.
   - Configure `ARWorldTrackingConfiguration` with `sceneReconstruction = .meshWithClassification` and `frameSemantics = [.sceneDepth]`.
   - Inside `captureSession(_:didStartWith:)`, call `arSession.run(config)` with **no options**: no `.resetTracking` and no `.removeExistingAnchors`. Repeat for every room.
   - Add a watchdog that re-applies the configuration whenever `frame.sceneDepth == nil`.
   - **Do not depend on this.** Keep a separate ARKit mesh pass (not RoomPlan) for the raw LiDAR mesh deliverable.
3. **Save these for each room. Scan files are never modified after capture:**
   - `CapturedRoomData` encoded with JSONEncoder (raw and re-processable).
   - `CapturedRoom` encoded as JSON (the parametric truth).
   - The `ARWorldMap` from `getCurrentWorldMap` (for relocalization).
   - The floor plan, measurements and clean architectural model are built by Mapper's own code from `surfaces` and `objects` (`transform`, `dimensions`, `polygonCorners`, `parentIdentifier`). Never parse the USDZ to get them.
4. **Processing and merging:**
   - Process each room with `RoomBuilder(options: [.beautifyObjects])`.
   - When the user taps finish, merge with `StructureBuilder(options: [.beautifyObjects]).capturedStructure(from:)`.
   - On `invalidRoomLocation` or either `exceedSceneSizeLimit`, keep the rooms separate and still exportable, and offer "start a fresh session".
5. **Resume across app launches:**
   - Run with `initialWorldMap` and return true from `sessionShouldAttemptRelocalization`.
   - Wait until tracking goes from `.limited(.relocalizing)` to `.normal`, showing a "return to last room" prompt.
   - Then create a new `RoomCaptureSession(arSession:)`.
6. **Export only when the user asks:**
   - Call `export(to:metadataURL:modelProvider:exportOptions:)` with a `.plist` metadata URL and `[.mesh]`, or `[.parametric]` for CAD.
   - The file name must start with a letter.
   - Any metadata reader should sniff the format: `PropertyListSerialization` first, falling back to `JSONSerialization`.
7. **UX guards:**
   - Warn at 4 minutes and stop at 5.
   - Watch `deviceTooHot` together with `ProcessInfo.thermalState`.
   - Show coaching only for non-`.normal` instructions.
   - Before scanning, tell users to close doors, avoid mirrors and direct sun, and make sure the room is lit (at least 50 lux).
8. **Accuracy correction:**
   - Offer an optional reference length, one tape-measured value per room, which applies a reversible uniform scale to derived dimensions only.
   - Store the scale in the project file.
   - Show tolerance using the Units module.
9. **Device tests needed on the iPhone 13 Pro Max (iOS 18.3.2):**
   - Once per second, log whether `configuration.frameSemantics.contains(.sceneDepth)`, whether `sceneDepth != nil`, the `ARMeshAnchor` count, the count of `session(_:didUpdate:)` frames and the count of room `didUpdate` callbacks. Capture these before and after the re-apply, and with the delegate set before and after `run`.
   - Export with a `.plist` and a `.json` metadata extension and log the first bytes of each file.
   - Scan room A, kill the app, relaunch, relocalize, scan room B, and check that `StructureBuilder` merges them.
   - Compare wall dimensions with a tape measure for walls under 3 m and over 6 m, following `docs/TEST_PLAN.md`.

## object-capture

Sources: `docs/research/raw/object-capture.json`, which has 22 facts and 16 verdicts with 0 refuted, and `docs/research/verify/object-capture.json`, which has 2 verdicts with 0 refuted plus 6 answers to open questions. Where the two files disagree, verify/ wins. Target: iPhone 13 Pro Max (A15 + LiDAR, supported), iOS 18.3.2, deployment target 18.0, Swift 5.9, iOS 26 SDK. Nothing in this area is deprecated in the iOS 26 SDK.

### 1. Verified APIs (safe on iOS 18.0)

**Gating.** Check both flags, because constructing a session when the flag is false is a runtime error. Requirements are LiDAR plus A14 or later, back camera only, no Simulator.
```swift
@MainActor static var isSupported: Bool { get }   // ObjectCaptureSession, iOS 17
static var isSupported: Bool { get }              // PhotogrammetrySession, iOS 17
```

**ObjectCaptureSession** is iOS/iPadOS 17.0+ only. It also compiles for Mac Catalyst but has no native macOS support. It conforms to `Identifiable, Observable, Sendable`.
```swift
@MainActor class ObjectCaptureSession
@MainActor init()
@MainActor func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())  // not throwing; errors -> state .failed
struct ObjectCaptureSession.Configuration { init(); var checkpointDirectory: URL?; var isOverCaptureEnabled: Bool }
@MainActor var configuration: ObjectCaptureSession.Configuration { get }   // read-only after start
enum CaptureState { case initializing, ready, detecting, capturing, finishing, completed; case failed(any Error) }  // Equatable, Sendable
@MainActor var state: CaptureState { get }
@MainActor var stateUpdates: ObjectCaptureSession.Updates<CaptureState> { get }  // struct Updates<Element> where Element: Sendable; for await
@MainActor func startDetecting() -> Bool
@discardableResult @MainActor func resetDetection() -> Bool
@MainActor func startCapturing()
@MainActor func finish()
@MainActor func cancel()
@MainActor func pause(); @MainActor func resume()
@MainActor var isPaused: Bool { get }; var isPausedUpdates: Updates<Bool> { get }
@MainActor func beginNewScanPass(); @MainActor func beginNewScanPassAfterFlip()
@MainActor var userCompletedScanPass: Bool { get }  (+ userCompletedScanPassUpdates)
@MainActor func requestImageCapture(); var canRequestImageCapture: Bool { get } (+ Updates)
@MainActor var isAutoCaptureEnabled: Bool { get set }      // iOS 18.0
@MainActor var numberOfShotsTaken: Int { get } (+ Updates)
@MainActor var maximumNumberOfInputImages: Int { get }
@MainActor var shouldPlayHaptics: Bool { get set }
@MainActor var feedback: Set<ObjectCaptureSession.Feedback> { get } (+ feedbackUpdates)
enum Feedback { environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected, objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing }
@MainActor var cameraTracking: ObjectCaptureSession.Tracking { get } (+ cameraTrackingUpdates)
enum Tracking { case normal, notAvailable, limited(reason: Reason) }  // Reason: excessiveMotion, initializing, insufficientFeatures, relocalizing
enum ObjectCaptureSession.Error { cancelled, directoryNotEmpty(URL), insufficientStorage(requiredBytes: Int64), sensorFailed, trackingFailed }
```
State transitions:
- `startDetecting()` works only from `.ready`.
- `startCapturing()` moves `.ready` or `.detecting` to `.capturing`.
- `finish()` moves `.capturing` to `.finishing` and then `.completed`.
- `cancel()` ends in `.failed(.cancelled)`.

**SwiftUI views** (iOS 17):
```swift
@MainActor @preconcurrency struct ObjectCaptureView<Overlay> where Overlay : View
nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView
nonisolated init(session: ObjectCaptureSession, @ViewBuilder cameraFeedOverlay: () -> Overlay)
@MainActor @preconcurrency func hideObjectReticle(_ value: Bool = true) -> ObjectCaptureView<Overlay>   // iOS 18.0
@MainActor struct ObjectCapturePointCloudView { init(session: ObjectCaptureSession)
  func showShotLocations(_ value: Bool = true) -> ObjectCapturePointCloudView }  // showShotLocations iOS 18.0
```

**PhotogrammetrySession** (iOS 17.0 and macOS 12.0; `limits` and `Error` are iOS 17 and macOS 14):
```swift
class PhotogrammetrySession
convenience init(input: URL, configuration: Configuration = Configuration()) throws
convenience init<S>(input: S, configuration: Configuration = Configuration()) throws where S: Sequence, S.Element == PhotogrammetrySample  // iterated once
var isProcessing: Bool { get }; var activeRequests: [Request] { get }; var outputs: Outputs { get }
func process(requests: [PhotogrammetrySession.Request]) throws
func cancel()
static let limits: PhotogrammetrySession.Limits   // { maximumInputImageDimension: Int; maximumNumberOfInputImages: Int }
enum Error { insufficientStorage(requiredBytes: Int64), invalidImages(URL), invalidOutput(URL) }
struct Configuration { init(); init(checkpointDirectory: URL)
  var isObjectMaskingEnabled: Bool   // default true
  var sampleOrdering: SampleOrdering // .unordered / .sequential
  var featureSensitivity: FeatureSensitivity // .normal / .high
  var checkpointDirectory: URL?
  var ignoreBoundingBox: Bool }      // iOS 18.0
enum Request {
  case modelFile(url: URL, detail: Request.Detail = .reduced, geometry: Request.Geometry? = nil)
  case modelEntity(detail: Request.Detail = .reduced, geometry: Request.Geometry? = nil)
  case bounds; case pointCloud; case poses; init(modelFile: URL) }
struct Request.Geometry { init(bounds: BoundingBox = .empty, transform: Transform = .identity)
  init(orientedBounds: OrientedBoundingBox, transform: Transform = .identity) }
enum Result { modelFile(URL), modelEntity(ModelEntity), bounds(BoundingBox), pointCloud(PointCloud), poses(Poses) }
enum Output: Sendable { inputComplete, requestProgress(Request, fractionComplete: Double),
  requestProgressInfo(Request, ProgressInfo), requestComplete(Request, Result), requestError(Request, any Error),
  processingComplete, processingCancelled, invalidSample(id: Int, reason: String), skippedSample(id: Int),
  automaticDownsampling, stitchingIncomplete }
struct ProgressInfo { let estimatedRemainingTime: TimeInterval?; let processingStage: ProcessingStage? }
enum ProcessingStage { preProcessing, imageAlignment, pointCloudGeneration, meshGeneration, textureMapping, optimization }
```

**PhotogrammetrySample** (iOS 17). It has `init(id: Int, image: CVPixelBuffer)` and the async `init(contentsOf url: URL) async throws`, which is **iOS 18.0**. Its fields are `depthDataMap`, `depthConfidenceMap`, `gravity: CMAcceleration?`, `objectMask` (must be `kCVPixelFormatType_OneComponent8` at the image size), `camera`, `scanPassID`, `sessionID` and `boundingBox: simd_float4x4?` (**iOS 18.0**). `id` must be in the range 0 to 2147483647.

**Measuring the USDZ:**
- `MDLAsset(url:)` (iOS 9) gives `boundingBox: MDLAxisAlignedBoundingBox`, `childObjects(of:)`, `canExportFileExtension(_:)` and `export(to:) throws`.
- `Entity(contentsOf:withName:) async throws` is iOS 18.
- `visualBounds(recursive: Bool = true, relativeTo: Entity?, excludeInactive: Bool = false) -> BoundingBox` is available from iOS 13. It is declared on `HasTransform` and must be called on the main actor. This was resolved in verify/.

### 2. Disputed or refuted claims and verdicts

No claim was refuted. The points below were sharpened or had to be settled:

- **OBJ output on iOS.** Verify/ upholds this as "likely".
  - Apple's docs say: "If url refers to a directory, the request saves an OBJ object and every texture map there". There is no platform caveat and the API is iOS 17.0+.
  - Correction: forum thread 742077 never names a platform, so it is not an iOS field report.
  - Better evidence is Lidar4Free on iOS 26. It pre-creates the directory, then writes `baked_mesh.obj` + `.mtl` + textures + USDA.
  - There is no report for iOS 18.
  - A URL ending in `.obj` is undefined in the docs, and on macOS it gives `.invalidOutput`.
- **Is using `.medium/.full/.raw/.preview/.custom` on iOS a compile error or a runtime error?** Two docs-lens verdicts cite per-case platform metadata (macOS 12 and Catalyst 15 only; `.custom` macOS 14) and community `@available(iOS, unavailable)` reports, which means a **compile error**. One reality-lens verdict claims they compile and fail at runtime.
  - **Tie-break:** the per-case metadata wins, so treat them as unavailable at compile time.
  - Either way the rule is the same: use only `.reduced` and put anything else behind `#if os(macOS)`.
- **`.bounds`, `.poses`, `.pointCloud`, `.modelEntity` on iOS.** All are documented for iOS 17+ with no "unsupported" error case.
  - `.bounds` is confirmed working on iPhone (react-native-object-capture, iOS 26).
  - `.poses` and `.pointCloud` have no device evidence either way, so treat them as unverified.
  - `.modelEntity` should be avoided because it keeps the mesh in memory on a 6 GB device.
  - Apple's sample comment "Not supported yet" describes only its own switch statement.
- **`ObjectCaptureView(session:)`.** The claimed inference problem is not real. The initializer is constrained `where Overlay == EmptyView`.
- **Automatic pause when the view is removed.** Only the sample comment says this, but the doc agrees that a new `ObjectCaptureView` built from the same session resumes it.
- **Checkpoint folder name.** It is arbitrary. The WWDC23 sample and its forks use `Snapshots/`, the current sample uses `Checkpoint/`.
- **The "1000 images on iOS" limit.** There is no verifiable source. Apple's only number is 2000 images, and that is for Macs. Confidence is "unsure", so it needs a device log.
- **Area mode on iOS 17.** Calling `startCapturing()` from `.ready` is plain freeform capture there. The dedicated area-mode experience is iOS 18 (WWDC24), which is fine for this target.

### 3. APIs that must not be used unguarded

| API | Platform | Rule |
|---|---|---|
| `Request.Detail.preview/.medium/.full/.raw` | macOS 12 / Catalyst 15 only | Never in iOS code; `#if os(macOS)` |
| `Request.Detail.custom`, `Configuration.customDetailSpecification` | macOS 14 / Catalyst 17 only | Same |
| `Configuration.meshPrimitive`, `MeshPrimitive` (quads) | macOS 15 / Catalyst 18 only | Same |
| Textures larger than 2048, 2000-image processing | Mac only (WWDC24) | Out of scope on device |
| `SCNScene(url:options:)`, `SCNBoundingVolume.boundingBox` | Deprecated in the iOS 26 SDK (they still compile) | Prefer ModelIO or RealityKit |
| `.processError` (cv3dapi codes 4011/4012) | Undocumented internal error | Handle through `localizedDescription` only |

None of the iOS 18-only members needs a guard at deployment target 18.0: `isAutoCaptureEnabled`, `hideObjectReticle`, `showShotLocations`, `ignoreBoundingBox`, `PhotogrammetrySample(contentsOf:)`, `PhotogrammetrySample.boundingBox` and `Entity(contentsOf:)`. None of this area is iOS 26-only.

### 4. Gotchas with numbers

- **`.reduced` output:** fewer than 50k triangles, about 10 MB, 2048x2048 diffuse + normal + AO maps (42.7 MB of texture memory once loaded). There are no roughness or displacement maps.
- **Images:** ObjectCaptureSession HEICs are 3024x4032 with an embedded 192x256 8-bit depth map plus calibration and point cloud metadata. Each is about 2 to 4 MB, so 300 to 1000 shots come to roughly 1 to 4 GB before checkpoint and model.
- **Scale:** the depth data makes the model **metric**, so the bounding box extents are metres. No framework computes volume; compute it yourself from the `MDLMesh` vertex and index buffers with a signed tetrahedron sum.
- **`start` is single-use:** call it once per instance. `imagesDirectory` must be empty and writable, and the checkpoint directory must be empty or absent. Otherwise the state becomes `.failed(directoryNotEmpty)`.
- **`.failed` is terminal:** tear the session down and create a new one. `CaptureState ==` treats every `.failed` as equal whatever the payload, so pattern-match to get the error.
- **Silent no-ops:**
  - `finish()` is ignored outside `.capturing`.
  - `startDetecting()` returns false when there is no horizontal plane under the centre ray. Show that to the user.
  - `beginNewScanPass()` is documented to "throw" outside `.capturing` even though its signature does not throw.
  - Both multi-pass calls are invalid in area mode.
- **Sheets:** the session keeps capturing under a sheet or blur. Call `pause()`/`resume()` manually.
- **Object size:** objects must be at least 3 in (8 cm) in every dimension to be detected. For area mode, WWDC24 says quality drops for areas larger than 6 ft.
- **Image limits:** above `maximumNumberOfInputImages` the session stops capturing unless `isOverCaptureEnabled` is set. Extra images show up as `.overCapturing` in capture and `.invalidSample` in reconstruction.
- **Outputs never end:** `outputs` is an infinite AsyncSequence. Stop after `.processingComplete` or `.processingCancelled` (Apple's `UntilProcessingCompleteFilter`), or the Task leaks.
- **Batching:** `process()` throws while `isProcessing` is true. `cancel()` is asynchronous, so wait for `.processingCancelled` before creating a new session.
- **First `process()` call:** it ingests all input and emits `.inputComplete` before any progress. Also handle `.automaticDownsampling` (images shrunk to save memory) and `.stitchingIncomplete` (a flipped side did not stitch).
- **Memory and crashes:** set `objectCaptureSession = nil` before creating `PhotogrammetrySession` to free GPU memory. Running both at once is the pattern behind the EXC_BAD_ACCESS reports in corephotogrammetry.
- **Masking:** `isObjectMaskingEnabled` defaults to true, which masks out scene backgrounds.
- **Threading:** the capture API is `@MainActor`, and so are `Entity` loads and `visualBounds`. `MDLAsset` can run off the main actor.
- **Timing:** there is no number for the A15, only "a few minutes" (roughly M1 class). Plan the UI for 2 to 10 minutes.
- **Apple UI is fixed:** the reticle, box handles, capture dial and coaching overlay cannot be restyled, only overlaid. The coaching overlay appears automatically when `cameraTracking != .normal`, so hide your own overlay then.
- **Sideloading:** a free Apple ID sideload works. No entitlements are needed, only `NSCameraUsageDescription`.

### 5. Recommendations

1. Base the object pipeline closely on Apple's sample "Scanning objects using Object Capture" (iOS 18.0):
   - a `@MainActor @Observable` model that owns an optional `ObjectCaptureSession` and an optional `PhotogrammetrySession`;
   - a folder manager that creates a fresh `Documents/<ISO8601>/{Images,Checkpoint,Models}` per scan;
   - `for await` over `stateUpdates` and `feedbackUpdates`;
   - an until-complete filter over `outputs`.

   Since raw scan data is never modified, keep `Images/` and write outputs only to `Models/`.
2. Gate the feature on both `isSupported` flags. Keep the idle timer disabled and the app in the foreground during capture and reconstruction.
3. Request `[.modelFile(url: Models/model-mobile.usdz), .bounds]` with the default `.reduced` detail. For OBJ, test a second request using a pre-created directory URL with `hasDirectoryPath == true`, and find the `.obj` by extension. Keep `MDLAsset(url:)` + `export(to:)` as the fallback.
4. Log `maximumNumberOfInputImages`, `PhotogrammetrySession.limits`, reconstruction wall time, `estimatedRemainingTime`, `processingStage` and `thermalState` on the first device run. Never hard-code 1000.
5. Before capture, check free space with `volumeAvailableCapacityForImportantUsage`. Refuse below about 2 to 4 GB (the size of one HEIC times the runtime maximum image count, plus checkpoint and model). Show `requiredBytes` from any `insufficientStorage` error.
6. Implement area mode as an app-level mode:
   - skip `startDetecting()` and call `startCapturing()` from `.ready`;
   - apply `.hideObjectReticle(true)`;
   - set `isObjectMaskingEnabled = false` and `ignoreBoundingBox = true`.

   Use it only for small textured scenes. RoomPlan and the ARKit mesh remain the room-scale path.
7. Delete `Checkpoint/` after success and the whole capture folder on cancel. Use `checkpointDirectory` to resume an interrupted reconstruction.
8. Add `@unknown default` to every switch over `CaptureState`, `Feedback`, `Output` and `Request`. Treat `.failed(ObjectCaptureSession.Error.cancelled)` as a normal restart.
9. Measure with `MDLAsset(url:).boundingBox`, or `visualBounds(relativeTo: nil).extents` on the main actor. Avoid `.modelEntity` and SceneKit.
10. Test on device (iOS 18.3.2): the OBJ directory output, `.poses`/`.pointCloud`, the image limits and the reconstruction time.

## export-formats

Sources: `docs/research/raw/export-formats.json` (20 facts, 16 adversarial verdicts) and `docs/research/verify/export-formats.json` (QuickLook re-check plus answers to 5 open questions). Neither lens refuted any claim. The notes below include the corrections and caveats the verifiers added. Where the two files disagree, verify/ wins.

### 1. Verified APIs (safe on iOS 18.0, Swift 5.9)

**ModelIO (iOS 9.0+, not deprecated in the iOS 26 SDK)**
- `func export(to URL: URL) throws`: the format comes from `pathExtension`, and the URL must be a `file:` URL.
- `class func canExportFileExtension(_ extension: String) -> Bool`: only `.obj` and `.stl` are documented ("Additional formats may be supported").
- `class func canImportFileExtension(_ extension: String) -> Bool`: imports .abc, .usd, .usda, .usdc, .usdz, .ply (ASCII only), .obj and .stl.
- Mesh construction: `MDLMeshBufferData(type:data:)`, `MDLVertexDescriptor` (`attributes` and `layouts` are `NSMutableArray`, so use `desc.attributes[0] = MDLVertexAttribute(name:format:offset:bufferIndex:)` and `desc.layouts[0] = MDLVertexBufferLayout(stride:)`), `MDLSubmesh(indexBuffer:indexCount:indexType:geometryType:material:)` and `MDLMesh(vertexBuffer:vertexCount:descriptor:submeshes:)`. Attribute names are `MDLVertexAttributePosition`, `...Normal`, `...TextureCoordinate` and `...Color`. Use `.uInt32` indices.
- Materials: `MDLMaterial(name:scatteringFunction:)` (`scatteringFunction` is get-only), `setProperty(_:)`, `MDLMaterialProperty(name:semantic:url:)` and `MDLURLTexture(url:name:)`.
- Import: `MDLAsset(url:)`, `childObjects(of: MDLMesh.self)`, `boundingBox`.

**SceneKit (iOS 8.0+, deprecated 26.0: compiles with warnings and still runs)**
- `func write(to url: URL, options: [String : Any]? = nil, delegate: (any SCNSceneExportDelegate)?, progressHandler: SCNSceneExportProgressHandler? = nil) -> Bool`
- `typealias SCNSceneExportProgressHandler = (Float, (any Error)?, UnsafeMutablePointer<ObjCBool>) -> Void`
- Delegate method: `optional func write(_ image: UIImage, withSceneDocumentURL documentURL: URL, originalImageURL: URL?) -> URL?`. The raw file omitted `optional`. The call-site label is unchanged.
- `SCNScene(mdlAsset:)` requires `import SceneKit.ModelIO`.
- Apple documents only `.scn` (iOS 10+). USDZ output from a `.usdz` extension is undocumented, but community testing shows it working on iOS 17 and 18 (65+ GitHub files, including LiDAR apps in 2024 to 2026). WWDC19 602 names this as the intended USDZ path.

**RoomPlan (not deprecated)**
- `func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (iOS 16.0)
- `func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (iOS 17.0)
- `CapturedRoom.USDExportOptions` is an OptionSet (rawValue Int32) with `.parametric`, `.mesh` and `.model`, so `[.parametric, .mesh]` is valid.
- `struct CapturedStructure` (iOS 17.0, Codable and Sendable) has `var rooms: [CapturedRoom]` and the same `export(to:metadataURL:modelProvider:exportOptions:)`. `StructureBuilder(options:)` with `capturedStructure(from:)` is also iOS 17.0.
- `CapturedRoom` is Codable, so `JSONEncoder` can write the project file.

**RealityKit / Object Capture (iOS 17.0+)**
- `PhotogrammetrySession`, `static var isSupported: Bool`, `case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced, geometry: PhotogrammetrySession.Request.Geometry? = nil)`
- `@MainActor class ObjectCaptureSession`: `start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())`, `startDetecting() -> Bool`, `startCapturing()`, `finish()`, `cancel()`, `pause()`, `resume()`, `beginNewScanPass()`
- `@MainActor func write(to url: URL) async throws` on `Entity` (iOS 18.0) writes a `.reality` file only.

**2D output (iOS 10.0+)**
- `UIGraphicsPDFRenderer(bounds:format:)`, `writePDF(to:withActions:) throws`, `pdfData(actions:)`, `UIGraphicsPDFRendererContext.beginPage()` / `beginPage(withBounds:pageInfo:)`, `cgContext`, `UIGraphicsPDFRendererFormat.documentInfo` (`kCGPDFContextTitle` and related keys)
- `UIGraphicsImageRenderer(size:format:)`, `pngData(actions:)`, `jpegData(withCompressionQuality:actions:)`

**Sharing, preview and files**
- ShareLink and Transferable (iOS 16.0):
  - `ShareLink(item:subject:message:preview:)`
  - `FileRepresentation(exportedContentType: UTType, shouldAllowToOpenInPlace:, exporting: @Sendable (Item) async throws -> SentTransferredFile)`
  - `SentTransferredFile(_ file: URL, allowAccessingOriginalFile:)`
  - Pass every argument explicitly, because the default values come from headers.
- `UIActivityViewController(activityItems:applicationActivities:)` (iOS 6) and `UIDocumentPickerViewController(forExporting:asCopy:)` (iOS 14).
- UTType constants (iOS 14): `.usdz`, `.usd`, `.threeDContent`, `.realityFile`, `.sceneKitScene`, `.pdf`, `.png`, `.jpeg`, `.svg`, `.zip`, `.json`. There are no constants for obj, ply, stl, gltf, glb or dxf. Use `UTType(filenameExtension:)` with a nil check, or `UTExportedTypeDeclarations`.
- ZIP via NSFileCoordinator:
  - `static var forUploading: NSFileCoordinator.ReadingOptions` (iOS 8.0)
  - `func coordinate(readingItemAt url: URL, options: NSFileCoordinator.ReadingOptions = [], error outError: NSErrorPointer, byAccessor reader: (URL) -> Void)` (iOS 5.0, synchronous)
  - Async form: `NSFileAccessIntent.readingIntent(with:options:)` plus `coordinate(with: [NSFileAccessIntent], queue: OperationQueue, byAccessor: @escaping (Error?) -> Void)`.
- QuickLook (verify/ result):
  - `QLPreviewController` (iOS 4.0) lists "3D models in the USDZ format with both standalone and AR views".
  - `nonisolated func quickLookPreview(_ item: Binding<URL?>) -> some View` (iOS 14.0), plus `quickLookPreview(_:in:)`.
  - `class ARQuickLookPreviewItem : NSObject, QLPreviewItem` lives in **QuickLook, not ARKit** (iOS 13.0): `init(fileAt:)`, `allowsContentScaling` (default true), `canonicalWebPageURL`.
- Info.plist keys (not entitlements, so they work with a free Apple ID): `UIFileSharingEnabled` (iOS 3.2), `LSSupportsOpeningDocumentsInPlace` (iOS 2.0), `UISupportsDocumentBrowser` (iOS 11.0). `URL.documentsDirectory` is iOS 16.0.

**Hand-written formats (Foundation only)**
- GLB is verified against the glTF 2.0 spec:
  - Header: magic `0x46546C67`, version 2, total length, all uint32 little-endian.
  - JSON chunk type `0x4E4F534A`, padded with 0x20. BIN chunk type `0x004E4942`, padded with 0x00.
  - `buffers[0]` has no `uri`.
  - componentType values: 5126 float, 5125 uint32, 5123 uint16, 5121 uint8 (normalized for `COLOR_0`).
  - The POSITION accessor MUST have `min`/`max`. Images stored in a bufferView MUST set `mimeType`.
- OBJ/MTL, binary PLY, binary STL, SVG and DXF R12 are plain string or byte building.

### 2. Disputed or refuted claims and verdicts

No claim was refuted. The verifiers made these corrections:
- **ARQuickLookPreviewItem module**: raw said ARKit and the declaration was "likely". Verdict: QuickLook module, iOS 13.0, verified.
- **QLPreviewController inside a representable**: raw recommended `UIViewControllerRepresentable`. Verdict: when it is hosted as the representable's own view, embedded or in `.sheet`, the AR/Object toggle and Share button go missing (forums 701842 and 692364, still reported in 2025). Apple also says an embedded controller shows only a thumbnail. Either present it modally with `present(_:animated:)` from the top UIViewController, or use `.quickLookPreview($url)`. Whether the modifier keeps the AR controls on iOS 18.3.2 still needs a device test.
- **ARQuickLookPreviewItem(fileAt:) vs `url as QLPreviewItem`**: the "Unhandled item type 13" failure for sandbox files is real (forum 689586). Verdict: return `url as QLPreviewItem`.
- **RoomPlan metadata file**: raw called it a JSON room description. Verdict: it is only a String-to-UUID map from USDZ node names to CapturedRoom element IDs. The encoding is undocumented and community code uses `.plist`. Full room data comes from `JSONEncoder(CapturedRoom)`.
- **"Leading digit in filename fails before iOS 17.4"**: the 17.4 fix is unverified. Verdict: always start USD filenames with a letter, because USD prim names cannot start with a digit.
- **`.model` export option**: the docs say iOS 16.0, but the symbol only exists at runtime from iOS 17. This does not matter with an iOS 18 target.
- **PhotogrammetrySession Detail**: `.custom` is also macOS-only (raw left it out). Referencing it in iOS code will **not compile**.
- **KHR_materials_unlit**: it needs both the root `extensionsUsed:["KHR_materials_unlit"]` and a per-material `"extensions":{"KHR_materials_unlit":{}}`.
- **glTF uint16 indices**: the index value 65535 is reserved, so switch to uint32 when the vertex count is **>= 65535**, not only when it is above 65535.
- **UV flip**: glTF (0,0) is top-left, and so are ARKit/Metal camera images. UVs projected into the captured `CVPixelBuffer` normally need no flip. Only OpenGL-convention sources need `v = 1 - v`.
- **CFBundleVersion bump to refresh the Files app**: the DTS suggestion did not fix the reporter's case, so treat it as best effort. Fresh Xcode 26 projects were not affected.
- **SCNScene.write .usdz URL crash** (forum 731248, iOS 17): building the URL with `URL.appending(path:)` crashed with `NSPathStore2 stringByAppendingPathExtension: nil argument`. Use `FileManager.default.temporaryDirectory.appendingPathComponent("<UUID>.usdz")`.
- **MDLAsset.export(.usdz)**: `canExportFileExtension("usdz") == false` and export produces nothing silently. `usdc`/`usda` export loses materials (threads 737766, 745233 and 764030, 2023 to 2024). This stands as "likely", with no contrary evidence.

Open-question answers (verify/):
- Does ModelIO's OBJ exporter write `map_Kd`? No evidence either way. Do not depend on it.
- Does `canExportFileExtension("ply")` work on iOS 18? Not guaranteed. Treat it as unavailable.
- Is the SCNScene second-write bug fixed? Needs a device test, no fix found (confidence "unsure").
- PhotogrammetrySession OBJ output to a directory: the docs allow it. A forum report says the URL must be built with `appendingPathComponent("Models/", isDirectory: true)` and the folder must exist first. It is unconfirmed on iOS, and the fallback is USDZ then `MDLAsset(url:)`.

### 3. APIs not to use unguarded

- **macOS only**:
  - `SCNScene.write` to `.dae`.
  - `PhotogrammetrySession.Request.Detail` values `.preview`, `.medium`, `.full`, `.raw` and `.custom` (compile errors on iOS).
  - `Configuration.CustomDetailSpecification` (macOS 14) and `Configuration.MeshPrimitive` (macOS 15).
- **iOS 26 / 27 only**: `Entity.WriteOptions` (26.0), and `Entity.write(to:options:)`, `static write(_:to:options:)`, `preferFastExport` and `preferSmallTextureFiles` (27.0). All of these still write only `.reality`.
- **Deprecated in iOS 26.0** (usable, with warnings): all of SceneKit, meaning `SCNScene`, `write(to:options:delegate:progressHandler:)`, `SCNSceneExportDelegate`, `SCNSceneExportDestinationURL` and `SCNScene(mdlAsset:)`. WWDC25 288 calls this a soft deprecation with no plan to hard-deprecate.
- **iOS 18.0+ and undocumented**: `MDLUtility.convert(toUSDZ inputURL: URL, writeTo outputURL: URL)` (class func, no throws, no return value). It could replace SceneKit for USDZ, but is untested and must not be relied on without a device test.
- **No such API**: RealityKit has no USDZ or OBJ writer for `Entity`, `ModelEntity` or `MeshResource`. Apple Archive writes only `.aar` and cannot write ZIP. There is no native glTF importer or previewer on iOS, and QuickLook cannot open OBJ, PLY, STL or GLB.

### 4. Gotchas with numbers

- **SCNScene second write**: a second `write(to:)` in the same process can produce a **1.5 to 2 KB** corrupt USDZ. Some reports say the scene must have been rendered once first. Colours can come back lighter.
  - Mitigation: write to a unique temp file, check that the size is above a few KB, retry or fall back, then `moveItem`.
  - Large scenes cost a lot of memory and time (one report: an 18 MB usdz became a 483 MB scn), so cap vertex counts or export in chunks.
  - SceneKit writes `.usdc` first and then zips it. `UIImage` diffuse textures are embedded.
- **MDLAsset** cannot read **binary PLY** (thread 742244), only ASCII.
- **ModelIO OBJ export** writes the `.mtl` only if **every** `MDLSubmesh` has a non-nil material.
- **ZIP via .forUploading**:
  - The temp zip is **unlinked when the block returns**, so move or copy it inside the block.
  - The call is synchronous, so keep it off the main thread.
  - The archive root is always the folder name, and there is no control over compression or entry names (forums 681770 and 688165).
  - Signal, Pocket Casts and Home Assistant use this pattern on iOS 18 in 2026.
- **Files app**: the Documents folder must contain **at least one file**, or it is hidden.
- **ShareLink**: the exporting closure runs lazily, and the file must stay on disk until the sheet closes. Do not put exports in an eagerly purged temp directory.
- **Units**:
  - PDF: 72 pt = 1 in. A4 is 595.276 x 841.89 pt and US Letter is 612 x 792 pt. At 1:50, 1 m = 20 mm = 56.69 pt.
  - The UIKit PDF context is y-down, so a +Y-north plan needs `translateBy` plus `scaleBy(x: k, y: -k)`.
  - STL has no units and CAD assumes mm, so multiply by 1000.
  - DXF needs `$INSUNITS` (6 = m, 4 = mm).
  - glTF, ARKit and RoomPlan are all right-handed and +Y up, so no axis swap is needed.
- **Binary STL layout**: an 80-byte header, then a uint32 triangle count, then **50 bytes per triangle**. STL has no colour.
- **GLB alignment**: every chunk and every vertex-attribute offset must be **4-byte aligned**. Use one bufferView per attribute, because a shared view would need `byteStride`.
- **JSON encoding**: `JSONSerialization` and `JSONEncoder` **throw on NaN/Inf**, so sanitize positions, normals and min/max first. Pass `.withoutEscapingSlashes`.
- **DXF**: R12 (AC1009) has no `LWPOLYLINE`, so use `POLYLINE`/`VERTEX`/`SEQEND`. AC1015 needs HEADER, CLASSES, TABLES, BLOCKS and OBJECTS sections plus unique handles (group 5) and 100 subclass markers. In an LWPOLYLINE, group 90 must come first after `AcDbPolyline`.
- **Object Capture**: needs **LiDAR + A14 or later** (the iPhone 13 Pro Max qualifies). Only `.reduced` detail is available on iOS. `ObjectCaptureSession` is `@MainActor`, and creating it when `isSupported` is false is a runtime error.
- **RoomPlan**: the USDZ is **untextured**. For StructureBuilder merges, stop sessions with `stop(pauseARSession: false)` or relocalize with an ARWorldMap. It works best up to about **2,000 sq ft** on a single floor.

### 5. Recommendations

1. **Own every mesh writer** (OBJ+MTL with explicit `mtllib`/`usemtl`/`newmtl`/`Kd`/`map_Kd <relative jpg>`, binary little-endian PLY with `property uchar red/green/blue`, binary STL in mm, and GLB), all built on our own Mesh struct. The existing `ios/Sources/Export/` writers (OBJWriter, PLYWriter, STLWriter, GLBWriter, DXFWriter, SVGWriter, PDFPlanWriter, ZipWriter, USDZWriter) already follow this. Check them against the gotchas above: uint32 indices at >= 65535 vertices, NaN sanitizing, 4-byte padding, the two-part KHR_materials_unlit, and $INSUNITS.
2. **USDZ**:
   - Architectural model: `CapturedRoom`/`CapturedStructure.export(to:metadataURL:modelProvider:exportOptions: [.parametric, .mesh])`, with filenames starting with a letter.
   - Textured model: `SCNScene.write` to `temporaryDirectory.appendingPathComponent("<UUID>.usdz")`, verify the size, then move. Keep this isolated in one SceneKit file behind a protocol.
   - Evaluate `MDLUtility.convert(toUSDZ:writeTo:)` on device as the non-deprecated alternative.
3. **ModelIO** only for import (`MDLAsset(url:)`), for example to re-read the Object Capture USDZ before converting it to OBJ or GLB. `canExportFileExtension` is at most an optional, runtime-gated extra.
4. **ZIP**: stage exports into `Documents/<project>/Exports/<Name>/` with the exact wanted layout. Use `.forUploading` on a background queue, or the in-repo `ZipWriter` when entry names matter.
5. **Share and preview**:
   - Single files: `ShareLink(item: url, preview: SharePreview(...))`.
   - Bundles: a `Transferable` with `FileRepresentation(exportedContentType: .zip, ...)`.
   - Preview USDZ, PDF and PNG with `.quickLookPreview($url)` or a modal `present(_:animated:)` of a `QLPreviewController` returning `url as QLPreviewItem`. Never embed it as a representable's own view.
   - Formats QuickLook cannot open need our own viewer. GLB can only be checked in an external viewer.
6. **2D**: one `draw(in: CGContext, scale:)` shared by the PDF renderer, the PNG renderer and the SwiftUI Canvas. SVG and DXF (R12 with HEADER and TABLES/LAYER) get their own emitters.
7. **Info.plist**: set `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` under `info.properties` in project.yml. Write one file into Documents early. Keep projects in a package-like folder and write atomically, because other apps can edit files in place.
8. **First device build**: run a self-test that logs:
   - `canExportFileExtension` for obj, stl, ply, usda, usdc, usdz and abc;
   - SCNScene USDZ written twice, with each file's Bool result and size;
   - `MDLUtility.convert(toUSDZ:)` output;
   - the `.forUploading` zip;
   - the .mtl contents after a ModelIO OBJ export, to check for `map_Kd`;
   - whether `.quickLookPreview` shows AR mode.

    That settles every open item in one CI round trip.

## texturing

Sources: `docs/research/raw/texturing.json` (18 facts, 15 verifier verdicts covering facts 0 to 7) and `docs/research/verify/texturing.json` (tie-breaker rulings plus answers to the open questions). Where the two disagree, verify/ wins. Facts 8 to 17 in raw/ had no verifier pass, so their stated confidence is shown next to them.

### 1. VERIFIED APIs (safe on iOS 18.0, Swift 5.9)

**Projection convention (verified by both lenses, iOS 11.0+)**
- `ARCamera.transform: simd_float4x4`, `ARCamera.intrinsics: simd_float3x3`, `ARCamera.imageResolution: CGSize`, `ARFrame.capturedImage: CVPixelBuffer`.
- World to pixel: `cam = camera.transform.inverse * float4(p,1)`, then `z = -cam.z` (must be > 0), `u = fx*cam.x/z + ox`, `v = -fy*cam.y/z + oy`. Note the minus sign on y.
- Camera axes: +X right, +Y up, looking down -Z, in the native landscape sensor frame (UIInterfaceOrientation `.landscapeRight`, rotation 0).
- `(u,v)` is in pixels with the origin at the top-left of `capturedImage`: u runs along the 1920 axis and v along the 1440 axis. Row 0 of the buffer is the image top, so a Metal texture made from it is sampled with `(u/W, v/H)` and no flip.
- The inverse (Apple point-cloud sample) is `localPoint = intrinsics.inverse * float3(u,v,1) * depth`, then `world = camera.transform * flipYZ * float4(localPoint,1)` with `flipYZ = diag(1,-1,-1,1)`.

**Captured image (verified, iOS 11.0+)**
- The format is full-range bi-planar YCbCr (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`, ITU-R 601), in landscape sensor orientation. On the 13 Pro Max it is 1920x1440 by default.
- Shader YCbCr to RGB matrix (from Apple's docs): `float4x4(float4(1,1,1,0), float4(0,-0.3441,1.7720,0), float4(1.4020,-0.7141,0,0), float4(-0.7010,0.5291,-0.8860,1))`.
- Zero-copy path: use `CVMetalTextureCacheCreate` and `CVMetalTextureCacheCreateTextureFromImage(...)`, with plane 0 as `.r8Unorm` (W,H) and plane 1 as `.rg8Unorm` (W/2,H/2). Keep the `CVMetalTexture` alive until the command buffer completes.
- Persistence (raw fact 9, verified declarations):
  - `CIImage(cvPixelBuffer:)`
  - `CIContext.jpegRepresentation(of:colorSpace:options:)` (iOS 10+)
  - `heifRepresentation(of:format:colorSpace:options:)` (iOS 11+)
  - `writeJPEGRepresentation(of:to:colorSpace:options:) throws`
  - `MTKTextureLoader.newTexture(cgImage:options:)` does not flip when `.origin` is omitted.
  - `CIRenderDestination(mtlTexture:commandBuffer:)` with `isFlipped` (iOS 11+).

**Scene depth (verified, iOS 14.0+, LiDAR only)**
- `ARFrame.sceneDepth: ARDepthData?` and `smoothedSceneDepth`.
- `ARDepthData`: `unowned(unsafe) var depthMap: CVPixelBuffer` and `unowned(unsafe) var confidenceMap: CVPixelBuffer?`.
- Add `.sceneDepth` to `frameSemantics` after checking `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`.
- `depthMap` holds planar depth in meters (`DepthFloat32`), so compare it directly with `-cam.z`. Confidence is `OneComponent8` with values 0, 1 or 2.
- It covers the same field of view as `capturedImage`, so the same normalized texCoord applies. The pixel scale factor is 256/1920 = 0.1333.
- 256x192 is community-confirmed only. Read the width, height and `CVPixelBufferGetPixelFormatType` at runtime and assert on them.

**Mesh anchors (verified, iOS 13.4+)**
- `ARMeshAnchor.geometry: ARMeshGeometry` has `vertices`, `normals`, `faces: ARGeometryElement` and `classification: ARGeometrySource?` (one UInt8 per face).
- `ARGeometrySource` exposes `buffer: any MTLBuffer`, `count`, `format` (`.float3`), `componentsPerVector`, `offset` and `stride`. Read a vertex at `offset + i*stride`.
- `ARGeometryElement` exposes `bytesPerIndex` (4 in practice), `indexCountPerPrimitive` (3) and `primitiveType`.
- Data is in anchor-local space: world = `anchor.transform * float4(v,1)`. Rotate normals by the 3x3 part (the transform is rigid).

**Frame retention (verified with "likely" confidence)**
- `ARSessionDelegate.session(_:didUpdate:)`, `ARSession.delegateQueue` (nil means the main queue), `currentFrame`.

**Metal limits (verified from the Feature Set Tables PDF, May 2026)**
- A15 is `MTLGPUFamily.apple8`. The maximum 2D texture is 16,384 px (Apple3 to Apple9; Apple10 allows 32,768).
- Default `storageMode` on iOS is `.shared`. Depth-format textures must be `.private`, but they can still be sampled in compute through `depth2d<float>`.

**RealityKit display (tie-breaker, corrected declarations)**
- `LowLevelMesh` (iOS 18.0) with `LowLevelMesh.Descriptor { vertexCapacity, indexCapacity, vertexAttributes, vertexLayouts, indexType }`. UV attribute: semantic `.uv0`, format `.float2`.
- CPU writers:
  - `@MainActor func withUnsafeMutableBytes(bufferIndex: Int, _ callback: (UnsafeMutableRawBufferPointer) -> Void)`
  - `replaceUnsafeMutableBytes(bufferIndex:_:)`
  - `@MainActor func withUnsafeMutableIndices(_ callback: (UnsafeMutableRawBufferPointer) -> Void)`
  - `@MainActor func replaceUnsafeMutableIndices(_ callback: ...)`
- GPU writers: `replace(bufferIndex:using:) -> any MTLBuffer` and `replaceIndices(using commandBuffer: any MTLCommandBuffer) -> any MTLBuffer`.
- `MeshResource(from: LowLevelMesh)` (iOS 18.0, MainActor). Both a sync and an async overload exist. Write `try MeshResource(from: mesh)` in a sync `@MainActor` function and `try await MeshResource(from: mesh)` in an async function. Leaving out `await` in an async context is a compile error.
- `LowLevelTexture` (iOS 18.0) with `replace(using: any MTLCommandBuffer) -> any MTLTexture`, and `TextureResource(from: LowLevelTexture)` (iOS 18.0).
- `TextureResource.init(image cgImage: CGImage, withName resourceName: String? = nil, options: TextureResource.CreateOptions)` is iOS 18.0. The same sync/async rule applies. Use `CreateOptions.semantic = .color` for albedo.
- `MeshDescriptor(name:)` (iOS 15.0) with `positions`, `normals` and `textureCoordinates = MeshBuffers.TextureCoordinates([SIMD2<Float>])`, then `MeshResource.generate(from: [MeshDescriptor])`.
- Materials: `UnlitMaterial` or `PhysicallyBasedMaterial`.

**ModelIO USDZ packager (tie-breaker, verified in the docs, untested on any device)**
- `class MDLUtility : NSObject` with `class func convert(toUSDZ inputURL: URL, writeTo outputURL: URL)` (iOS 18.0, not deprecated). It wraps Pixar `UsdUtilsCreateNewARKitUsdzPackage`.
- `MDLAsset.canExportFileExtension(_:)` (iOS 9.0) is documented for `.obj` and `.stl` only.

**Not re-verified (raw facts 10 to 14, declarations taken from the doc JSON)**
- iOS 16.0+: `ARSession.captureHighResolutionFrame(completion:)` and `captureHighResolutionFrame() async throws -> ARFrame`, `recommendedVideoFormatForHighResolutionFrameCapturing`, `VideoFormat.isRecommendedForHighResolutionFrameCapturing`, `ARConfiguration.configurableCaptureDeviceForPrimaryCamera: AVCaptureDevice?`, `ARFrame.exifData`.
- iOS 13.0+: `ARCamera.exposureDuration`, `exposureOffset`.
- iOS 12.0+: `AVCaptureDevice.activeMaxExposureDuration`.
- `MPSImageLaplacian` (iOS 10), `MPSImageStatisticsMeanAndVariance` (iOS 11; mean at (0,0), variance at (1,0)).

### 2. DISPUTED or REFUTED claims and the verdicts

| Claim | Verdict |
|---|---|
| Raw fact 6: `LowLevelMesh.replaceIndices(_ closure:)` exists | **Refuted.** It does not exist. Use `withUnsafeMutableIndices`, `replaceUnsafeMutableIndices`, or `replaceIndices(using:)` on the GPU. |
| `MeshResource(from:)` must be awaited (official-docs verifier) | **Overruled.** DocC shows only the async form, but Apple's own sample and more than 65 compiling repos call it synchronously. Both overloads exist; follow the sync/async rule above. |
| `TextureResource(image:withName:options:)` is iOS 13+ | **Refuted.** It is iOS 18.0. `TextureResource.generate(from:withName:options:)` is iOS 15.0 and deprecated in 18.0 (warns), so avoid it. |
| SceneKit is deprecated in 26.0 | **Upheld.** The whole framework, `SCNGeometrySource`, `SCNGeometryElement` and `SCNScene.write(to:options:delegate:progressHandler:)` are deprecated in 26.0. This is a soft deprecation (maintenance mode); the code still compiles and runs. |
| ModelIO cannot produce USDZ | **Refuted.** `MDLUtility.convert(toUSDZ:writeTo:)` exists on iOS 18.0. Its input must be a USD layer (usda/usdc) or a SceneKit-written scene. OBJ and `.reality` are not accepted (Apple staff, forum 759333). |
| `canExportFileExtension("usdz") == false`, usdc/usda true | Community evidence only, and the usdz false result was never tested in forum 111061 (which dates from 2018, not 2023). **Needs a device log.** |
| "USD export drops materials entirely" | **Overstated.** Scalar `UsdPreviewSurface` inputs survive; URL-valued texture properties are dropped. |
| "OBJ export writes Kd" | **Contradicted.** `MDLAsset` drops Kd or writes it as 1 1 1, and `map_Kd` is undocumented. Write your own OBJ+MTL. |
| The projection formula, capturedImage format, sceneDepth, ARMeshAnchor layout, frame retention and Metal limits | **Not refuted** by either lens. |

### 3. APIs that must NOT be used unguarded

- **iOS 26.0+ only:** `captureHighResolutionFrame(using: AVCapturePhotoSettings?, completion:)`.
- **iOS 27.0+ only:** `ARCamera.viewMatrix(viewRotationAngle:)`, `projectPoint(_:viewRotationAngle:viewportSize:)` and `ARFrame.displayTransform(viewRotationAngle:viewportSize:)`. Any use needs `#available`.
- **Deprecated in iOS 27 (still compile on Xcode 26.6, may warn):** `viewMatrix(for:)`, `projectPoint(_:orientation:viewportSize:)`, `projectionMatrix(for:viewportSize:zNear:zFar:)`, `unprojectPoint(_:ontoPlane:orientation:viewportSize:)` and `displayTransform(for:viewportSize:)`. Do not use them for texturing; use `transform` and `intrinsics` directly.
- **Deprecated in iOS 26.0:** all of SceneKit, including `SCNScene.write` (whose documented formats are only `.scn` on iOS and `.dae` on macOS; usdz output rests only on WWDC19 statements). Do not use it for new code or as the primary USDZ path.
- **Deprecated in iOS 18.0:** `TextureResource.generate(from:withName:options:)`.
- No macOS-only texturing API was found to be needed. LowLevelMesh and LowLevelTexture work on iOS (SDL, VRMKit), although Apple's only LowLevelMesh sample app is visionOS-only.

### 4. Key gotchas, with numbers

- **Frame retention.** More than 10 retained `ARFrame`s triggers the "ARSessionDelegate is retaining N ARFrames" warning. Camera frames start dropping at about 15 to 20 because the pixel-buffer pool runs out. Copy the pixels out or encode them and let the frame go; never queue ARFrames. `sceneDepth` buffers are pooled too.
- **Intrinsics change every frame** (autofocus and OIS). fx and fy drift about 36 px, cx and cy about 2 px. Store K with every keyframe.
- **Orientation.** `capturedImage` is always in landscape sensor orientation. Never apply a portrait or display transform in the texturing math.
- **Memory.**
  - One decoded 1920x1440 RGBA frame is about 11 MB, so 300 of them is 3.3 GB. A raw YCbCr copy is about 4.1 MB, so 300 is 1.2 GB.
  - A JPEG keyframe at q 0.85 to 0.9 is about 0.7 MB, so about 200 MB per room on disk.
  - Depth copy 196 KB, confidence copy 49 KB per keyframe.
  - One 4096² RGBA8 page is 64 MiB (16.8 Mtexels, about 3 to 6 MB as JPEG). A 16384² page would be 1 GiB.
  - Target peak memory: under 500 MB (about 4 pages, a 60 MB mesh, 2 decoded frames and 60 MB of depth copies).
- **Atlas sizing** (likely).
  - A room has 100 to 200 m² of surface. At 3 mm per texel that is 1 to 2 pages of 4096²; at 2 mm per texel, 2 to 3 pages.
  - Fixed per-triangle cells are 2 to 15 times more wasteful than charts.
  - Splitting seams inflates the vertex count 2 to 3 times.
  - Use one submesh or material per page.
- **V origin.**
  - CoreGraphics, Metal, CVPixelBuffer and SceneKit use a top-left origin.
  - RealityKit, OBJ `vt` and USD `st` use bottom-left (RealityKit per community evidence, RealityGeometries #3). Flip once with `v' = 1 - v`.
  - Core Image renders bottom-left, so `CIContext.render(_:to: MTLTexture...)` flips the image. Use `CIRenderDestination` with `isFlipped = true`, or go JPEG, then ImageIO, then `MTKTextureLoader`.
- **Depth textures** must be `.private`. For CPU readback, write linear depth to an `.r32Float` color attachment.
- **Hi-res frames.**
  - `captureHighResolutionFrame` gives 12 MP (4032x3024). Only one request can be in flight, and calling it right after `run()` fails.
  - It needs a format with `isRecommendedForHighResolutionFrameCapturing` (on the 13 Pro that format is still 1920x1440@60).
  - Its `sceneDepth` is reported misaligned.
  - Photo settings with `isDepthDataDeliveryEnabled` crash (forum 805839).
  - Whether K is rescaled is undocumented. Always scale fx, fy, ox and oy by the ratio of pixel-buffer size to `imageResolution`.
- **4K format** is 3840x2160@30, 16:9, which crops the LiDAR's 4:3 field of view. Stay on 1920x1440@60.
- **Mesh anchors** update throughout the scan. Freeze a world-space snapshot at Done, and weld vertices (about 1 mm) across anchor borders before building charts.
- **Mesh size.** Triangle edges are 3 to 8 cm; a room is roughly 100k to 500k triangles (community figure, measure on device).
- **Time budget** (likely), for 500k faces and 300 keyframes on an A15:
  - GPU view selection: under 1 s.
  - 300 depth passes: 0.5 to 1 s.
  - JPEG decode: 300 × about 20 ms = about 6 s (the dominant cost).
  - Chart building and packing: 1 to 3 s.
  - Gain solve: about 1 s.
  - Page encode: 1 to 2 s.
  - Total: 15 to 30 s. ScanSpace reports 10 to 60 s on an iPhone 15 Pro.
- **Occlusion.**
  - LiDAR depth texels are about 7.5 px wide in the color image and bleed at edges.
  - The rendered-mesh depth test needs epsilon ≈ 1 to 2 cm + 1% of depth.
  - ScanSpace's LiDAR tolerance is 0.03 + 0.03·d (strict) or 0.10 + 0.08·d (relaxed).
- **Colour correction.** Seam gain solving needs overlap: each triangle should be seen by at least 3 keyframes.
- **Exposure lock.** Locking exposure for a whole room blows out windows or crushes shadows.
- **`MDLUtility.convert(toUSDZ:writeTo:)`** returns Void and never throws. Check that the output exists, is non-empty and starts with "PK". No third party was found calling it on a device.

### 5. Recommendations

1. **Projector.** Use `camera.transform.inverse` plus per-keyframe `intrinsics` only. For the depth pass, build an off-axis projection from K:
   `P = [2fx/W,0,1-2ox/W,0; 0,2fy/H,2oy/H-1,0; 0,0,-f/(f-n),-fn/(f-n); 0,0,-1,0]`
   The signs in the third column were not verified; unit-test them on device.
2. **First build: two self-tests.**
   - (a) Project mesh vertices as dots over the live landscape `capturedImage`.
   - (b) Show a numbered 2x2 test atlas on a RealityKit quad; tile "1" must appear top-left.
   - Also log the round-trip reprojection error of LiDAR samples at runtime (assert under 0.5 px).
   - Also log `canExportFileExtension` for usdz, usdc, usda, obj and stl.
   - Also time JPEG encode and decode (mean and p95 over 50 frames, plus thermal state).
   - Also log the hi-res frame `imageResolution`, buffer size and K.
3. **Capture.**
   - `ARWorldTrackingConfiguration` with `.meshWithClassification` and `[.sceneDepth]`, default 1920x1440@60 format.
   - Keyframes gated on motion: tracking `.normal`, and either more than 15 cm or more than 10° since the last keyframe; `exposureDuration` under 1/60 s; optional Laplacian variance. This gives about 1 to 2 per second, 200 to 400 per room.
   - Encode JPEG (q 0.85 to 0.9) on a bounded serial utility queue that drops rather than queues, and copy depth and confidence at the same time.
   - Store K, transform, timestamp, exposure and a subset of the EXIF data with each keyframe.
4. **Exposure.** Keep auto exposure and cap `activeMaxExposureDuration` at about 1/120 s through `configurableCaptureDeviceForPrimaryCamera`. Then run a seam-based per-keyframe, per-channel log-gain solve (Jacobi with Huber weighting, mean gain fixed at 1). No Poisson blending in v1.
5. **Bake.**
   - Selection: best view per face on the GPU, with score = projectedArea × cos × sharpness × exposureWeight. Reject faces where the dot product is under 0.2, that are too near or far (0.08 to 5.5 m), or that fail the occlusion tests (rendered-mesh depth first, LiDAR high-confidence depth second).
   - Then: neighbour smoothing, charts, shelf packing into 4096² RGBA8 pages, and 2 to 4 px padding and dilation.
   - Bake one keyframe at a time on the GPU: decode, blit its charts, release.
   - Make decimation a pipeline stage that does nothing below about 300k faces, with a hard cap of 500k. ModelIO has no decimator.
6. **Display.** RealityKit `LowLevelMesh` or `MeshDescriptor` with `UnlitMaterial(texture:)` and `TextureResource(image:options:)`, respecting the MainActor and sync/async rules. No new SceneKit code.
7. **Exports.**
   - OBJ+MTL: your own writer (`Kd 1 1 1`, `map_Kd atlas_0.jpg`, flipped v).
   - USDZ: your own usda (`UsdPreviewSurface` + `UsdUVTexture` with a relative path to the atlas), then `MDLUtility.convert(toUSDZ:writeTo:)` and the PK check.
   - Fallback: your own 64-byte-aligned stored-zip writer (first entry is the root layer, CRC32 per entry), which can be tested off-device.
8. **Hi-res.** Leave `captureHighResolutionFrame` off in v1. Consider it later for object mode only.
9. **Shaders.** Use one Metal library (ycbcrToRGB, depthPass, viewSelect, chartCopy, dilate), all at Metal 2 level with no Metal 3 or 4 features.

## rendering-viewer

Sources: `docs/research/raw/rendering-viewer.json` (research plus official-docs and reality verdicts) and `docs/research/verify/rendering-viewer.json` (tie-breaker, which wins where they disagree). "Verified" means Apple doc JSON was checked on the iOS 26 SDK. "Researcher-only" means no verifier checked it.

### 1. Verified APIs, safe on iOS 18.0 in Swift 5.9 mode

**ARView (UIKit host).** Not deprecated.
- `@MainActor @objc @preconcurrency class ARView`, iOS 13.0.
- Init to use: `init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)`, iOS 13.0, not deprecated. Example: `ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)`.
- `enum CameraMode { case ar; case nonAR }` exists on iOS and Catalyst only.
- Properties: `scene`, `dynamic var session: ARSession { get set }`, `automaticallyConfigureSession`, `var cameraTransform: Transform { get }` (read-only), `debugOptions`, `environment.background`.
- Background cases: `.color(UIColor)`, `.cameraFeed(exposureCompensation: Float = 0)`, `.skybox(_:)`.
- Coordinate helpers, all iOS 13.0: `project(_:) -> CGPoint?`, `unproject(_:viewport:) -> SIMD3<Float>?` (there are also `ontoPlane:` overloads), `ray(through:) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?`.
- Picking, all iOS 13.0: `hitTest(_ point: CGPoint, query: CollisionCastQueryType = .all, mask: CollisionGroup = .all) -> [CollisionCastHit]`, `entity(at:)`, `entities(at:)`.
- ARKit raycast, iOS only: `raycast(from:allowing:alignment:) -> [ARRaycastResult]`.
- Snapshot: `snapshot(saveToHDR:completion:)` has an iOS 13.0 overload (the doc page with suffix -66jzu).

**RealityView (SwiftUI host).** iOS 18.0, not deprecated.
- iOS init: `init(make: @escaping @MainActor @Sendable (inout RealityViewCameraContent) async -> Void, update: (@MainActor (inout RealityViewCameraContent) -> Void)? = nil)`, plus `init(make:update:placeholder:)`.
- `RealityViewCameraContent` (iOS 18.0) has `camera`, `cameraTarget`, `entities`, `environment`, `audioListener`, `renderingEffects`, `animate`, `subscribe`. `add(_:)` and `remove(_:)` come from `RealityViewContentProtocol`.
- `RealityViewCamera.virtual`.
- `.realityViewCameraControls(_ controls: CameraControls)`. `CameraControls` offers `.none`, `.orbit`, `.pan`, `.tilt`, `.dolly`. It is a plain struct conforming to Equatable, Hashable and Sendable, not an OptionSet, so only one mode can be active at a time.
- `RealityViewCameraContent` conforms to `RealityCoordinateSpaceProjecting` (iOS 18.0), which provides:
  - `project(point: SIMD3<Float>, to space: some CoordinateSpaceProtocol) -> CGPoint?`
  - `unproject(_ point: CGPoint, from:, to:, ontoPlane: float4x4) -> SIMD3<Float>?`
  - `ray(through:in:to:) -> (origin:, direction:)?`
  - `hitTest(point:in:query:mask:) -> [CollisionCastHit]`
  - `entity(at:in:)` and `entities(at:in:)`
- These helpers only work through the `content` value captured in make or update. Hit tests only find entities that have a `CollisionComponent`.
- Gestures, all iOS 18.0: `targetedToAnyEntity()`, `EntityTargetValue` (also `RealityCoordinateSpaceProjecting`) and `InputTargetComponent`. Researcher-only.

**LowLevelMesh.** `@MainActor class LowLevelMesh`, iOS 18.0.
- `init(descriptor:) throws`.
- Use the 5-argument `Descriptor.init(vertexCapacity: Int = 0, vertexAttributes: [Attribute] = [], vertexLayouts: [Layout] = [], indexCapacity: Int = 0, indexType: MTLIndexType = .uint32)`.
- `Attribute.init(semantic:format:layoutIndex: Int = 0, offset:)`
- `Layout.init(bufferIndex:bufferOffset: Int = 0, bufferStride:)`
- `Part.init(indexOffset: = 0, indexCount: = 0, topology: MTLPrimitiveType = .triangle, materialIndex: = 0, bounds: BoundingBox)`. Topology `.line` is valid.
- `VertexSemantic` cases: position, normal, tangent, bitangent, color, uv0 to uv7, unspecified.
- `var parts: PartsCollection { get set }` with `replaceAll`, `append`, `append(contentsOf:)` and `removeAll()`.
- Buffer access, all `@MainActor`: `withUnsafeMutableBytes(bufferIndex:_:)`, `withUnsafeMutableIndices(_:)`, `withUnsafeBytes`, `withUnsafeIndices`, `replaceUnsafeMutableBytes`, `replaceUnsafeMutableIndices`, `read(bufferIndex:using:)`, `readIndices(using:)`.
- GPU writes: `replace(bufferIndex:using: any MTLCommandBuffer) -> any MTLBuffer` and `replaceIndices(using:)`.
- Wrapping: `MeshResource(from: LowLevelMesh) async throws` is iOS 18.0. A reality verifier also found a sync `throws` overload, so both `try await` and sync `try` inside `@MainActor` compile. `MeshResource.lowLevelMesh: LowLevelMesh?`.
- The MeshResource keeps a reference to the LowLevelMesh, so later edits show up without regenerating the resource.

**Picking.**
- `CollisionCastHit.triangleHit: TriangleHit? { get }` and `struct TriangleHit { faceIndex: Int; uv: SIMD2<Float> }` are iOS 18.0. `shapeIndex: Int` is iOS 18.0.
- `nonisolated static func generateStaticMesh(positions: [SIMD3<Float>], faceIndices: [UInt16]) async throws -> ShapeResource`, iOS 18.0.
- `@MainActor static func generateStaticMesh(from mesh: MeshResource) async throws -> ShapeResource`, iOS 18.0. It only works with CollisionComponent mode `.default` and PhysicsBody `.static`.
- `Scene.raycast(origin:direction:length: = 100, query:mask:relativeTo:)` and `raycast(from:to:...)`, iOS 13.0. `CollisionCastQueryType` cases: `.nearest`, `.all`, `.any`.
- `CollisionComponent.init(shapes:mode: = .default, filter: = .default)` is iOS 13.0. `init(shapes:isStatic:filter:)` is iOS 18.0.
- `Scene.pixelCast(from:to:)` and `pixelCast(origin:direction:length: = 100)`: `@MainActor async throws -> PixelCastHit?`, iOS 18.0. `PixelCastHit` has `entity`, `position`, `normal`, `primitive: UInt32`, `meshPart: UInt64`, `instance: UInt32`, `barycentric: SIMD3<Float>?`. It needs no CollisionComponent and skips entities without a valid `ModelComponent` mesh.

**Materials.**
- `triangleFillMode` (`MaterialParameterTypes.TriangleFillMode { case fill; case lines }`) exists on `UnlitMaterial`, `PhysicallyBasedMaterial`, `SimpleMaterial`, `CustomMaterial` and `ShaderGraphMaterial`, all iOS 18.0. `OcclusionMaterial` does not have it.
- `CustomMaterial`, iOS 15.0 (not on visionOS): `init(surfaceShader: CustomMaterial.SurfaceShader, geometryModifier: CustomMaterial.GeometryModifier? = nil, lightingModel: CustomMaterial.LightingModel) throws`. `lightingModel` has **no default**. `LightingModel` cases: `.lit`, `.clearcoat`, `.unlit`. `SurfaceShader(named:in: any MTLLibrary)`.
- On the Metal side, `params.geometry().color()` returns the fragment's interpolated vertex color.
- `struct ShaderGraphMaterial` is iOS 18.0. `init(materialXLabel: String, data: Data) async throws` and `init(named:from:in:) async throws` are both iOS 18.0. The Geometry Color node is iOS 17.0.
- `MeshDescriptor.Materials { case allFaces(UInt32); case perFace([UInt32]) }`, iOS 15.0. `MeshBuffers` has no color semantic.

**SceneKit.** It is only verified as deprecated (see section 3).

**Researcher-only, plausible but not checked by a verifier:**
- Textures: `TextureResource(image:withName:options:) async throws` (iOS 18) and `UnlitMaterial(texture:)` (iOS 18).
- Material properties: `faceCulling` (iOS 15) and `readsDepth`/`writesDepth`.
- Scene helpers: `BillboardComponent` (iOS 18), `PerspectiveCamera` and `PerspectiveCameraComponent(near:far:fieldOfViewInDegrees:)` (pass all three), `Entity.isEnabled`, `AnchorEntity(world:)` and `AnchorEntity(anchor:)`.
- Built-in meshes: `MeshResource.generateBox(size:cornerRadius:)` and `generateText`.
- ARKit mesh input: `ARMeshAnchor.geometry` with `vertices`, `normals`, `faces` and `classification?`, and `sceneReconstruction = .meshWithClassification` (iOS 13.4).
- Metal: `MTKView` and `setTriangleFillMode(.lines)`.

### 2. Disputed or refuted claims and the tie-breaker verdicts

1. **"ARView `init(frame:cameraMode:)` is deprecated."** The reality verifier said it is not deprecated because the doc JSON has no deprecatedAt. **The tie-breaker ruled that it IS deprecated.** DocC shows `deprecated=true` without a version and `renamed` pointing to the 3-argument init. Calling it only produces a warning. Use the 3-argument init.
2. **"RealityView on iOS has no project, unproject, ray or hitTest."** **Refuted, and upheld by the tie-breaker.** `RealityViewCameraContent` conforms to `RealityCoordinateSpaceProjecting` on iOS 18.0, and `Scene.pixelCast` also works. What RealityView still lacks on iOS:
   - attachments
   - `RealityCoordinateSpaceConverting`
   - ARKit `raycast(from:allowing:alignment:)`
   - direct ARSession access
   - `debugOptions`
   - `snapshot`
   - UIKit touch control

   So choosing between ARView and RealityView is about gestures, the session, snapshots and UIKit, not about missing picking math.
3. **"ShaderGraphMaterial is visionOS-only, so vertex colors need CustomMaterial."** **Refuted, and upheld by the tie-breaker.** ShaderGraphMaterial is iOS 18.0. There are two paths to vertex colors:
   - (a) `CustomMaterial` with a surface shader that writes `set_emissive_color(params.geometry().color().rgb)` under `.unlit`.
   - (b) `ShaderGraphMaterial(materialXLabel:data:)` built from an inline MaterialX string (geomcolor node feeding a RealityKit unlit surface). This needs no .metal file.

   The rest of the claim holds: Unlit and PBR materials render a LowLevelMesh `.color` attribute as white (Apple engineer, forum 759449), and per-face colors need no shader. Forum 763404 reports that the ShaderGraph Occlusion Surface output fails with `LoadError.invalidTypeFound`, while PBR Surface loads.
4. **`CustomMaterial` init signature.** The researcher wrote `lightingModel: = .lit`. That default does not exist, so pass the lighting model explicitly.
5. **Minor corrections from verifiers:**
   - SwiftUI `SceneView` is iOS 14.0, not 8.0.
   - The ARSCNView deprecation note reads "Use RealityView instead".
   - "Every built-in material has triangleFillMode" is slightly overstated (OcclusionMaterial does not).
   - `PixelCastHit.primitive` is documented only as a "per-primitive identifier". Reading it as a triangle index is an inference.

### 3. APIs that must not be used unguarded

- **iOS 27.0 only, so they do not compile on the Xcode 26.6 / iOS 26 SDK:** `LowLevelMesh.Descriptor.allowsPrimitiveRestart`, `Descriptor.instanceCapacity`, and the 6-argument `Descriptor.init(...indexType:instanceCapacity:)`.
- **visionOS only:** `RealityView.init(make:update:attachments:)`, `RealityViewAttachments`, `RealityViewContent` (the non-camera type), and `RealityCoordinateSpaceConverting` (`convert(point:from:to:)`).
- **macOS only:** the snapshot overload on the unsuffixed page (use the iOS overload). The note about flipped hitTest coordinates in an NSViewRepresentable does not apply on iOS.
- **Not on macOS:** `RealityViewCamera.spatialTracking` exists on iOS and Catalyst only.
- **Deprecated in the iOS 26 SDK (compile with warnings):**
  - All of SceneKit (`SCNView`, `SCNGeometry*`, `SCNHitTestResult`, `SCNProgram`, `SCNTechnique`, `SCNFillMode`, `SceneView`) and `ARSCNView`. This is a soft deprecation in maintenance mode, with no plan to hard-deprecate. It still runs on iOS 18.
  - `ARView(frame:cameraMode:)` (2-argument).
  - `MeshResource.generateAsync` and `replaceAsync`.
  - `TextureResource.generate(from:withName:options:)`, `generateAsync` and `loadAsync`.
  - `UnlitMaterial.baseColor` and `tintColor` (use `.color`).
  - `ModelDebugOptionsComponent .baseColorTexture`.
- **iOS 26 SDK additions to ignore:** tvOS 26 platform entries and the MTL4 members on `MTKView`.
- **Not deprecated on the iOS 26 SDK:** `CustomMaterial`, `ShaderGraphMaterial` and `triangleFillMode`. Whether they behave the same on the iOS 26 phone needs a device test.

### 4. Key gotchas, with numbers

- **Main actor:** every LowLevelMesh read and write path is `@MainActor`. Build the arrays off the main thread and copy them in on main. GPU writes go through `replace(bufferIndex:using:)`.
- **Fixed capacities:** vertex and index capacities are set at creation. Allocate about 1.5x the current need and recreate the mesh only when it overflows.
- **UInt16 limit:** `generateStaticMesh(positions:faceIndices:)` takes `[UInt16]` indices, so a chunk must stay at or below 65,535 vertices. The `from: MeshResource` overload has no such limit.
- **Slow collision builds:** Apple says `generateStaticMesh(from:)` "can take a while". Run it in `Task(priority: .low)` after the mesh is on screen.
- **Raycast length:** `Scene.raycast` only hits a primitive the ray fully crosses, so use a slightly longer `length`.
- **faceIndex:** it is relative to the shape that was hit. Its meaning when one component holds several shapes is undocumented.
- **pixelCast:** it is async and uses the GPU, so call it once per tap, never per frame. No real-world iOS code calling it was found.
- **Winding:** LiDAR triangles have inconsistent winding. Set `faceCulling = .none` on every scan material or about half the mesh disappears.
- **Unlit shaders:** under CustomMaterial `.unlit`, only `set_emissive_color()` is honoured. A surface shader must call at least one `set_*()` function or nothing renders. A .metal file plus `makeDefaultLibrary()` is required.
- **ARMeshAnchor buffers:** ARKit owns them and they are invalidated on the next update. Copy them synchronously inside the delegate callback. Classification is 1 byte per face and faces are Int32 triples. (Researcher-only.)
- **Live overlay:**
  - Coalesce dirty anchors and flush every 0.25 to 0.5 s.
  - Skip anchors outside the frustum.
  - `.showSceneUnderstanding` uses fixed colours and is for debugging only.
  - With `.occlusion` enabled, an overlay that coincides with Apple's mesh z-fights. Scale the overlay about 1.002x or disable occlusion while scanning.
- **CustomMaterial with AR video:** one GitHub project (wisescan-ios) reports that CustomMaterial crashes when composited with the AR camera video. Prefer UnlitMaterial for the live overlay.
- **Materials are structs:** declare them with `var` before setting `triangleFillMode`. Wireframe lines are 1 px and the width cannot be changed; use thin boxes for thick edges.
- **Performance:**
  - Apple gives no triangle budget (DTS: measure and iterate).
  - SceneKit becomes unresponsive at 750 to 2,000 nodes (iPad 10).
  - For RealityKit, keep chunk entities in the low hundreds and toggle them with `isEnabled`.
  - The A15 GPU handles 1M triangles easily. The risk is on the CPU side (draw calls and uploads).
  - Frame rate for about 1M triangles across 200 to 400 entities has no benchmark and needs a device test.
- **MeshDescriptor:** `MeshResource.generate(from: [MeshDescriptor])` is likely present (undocumented slug -6l1q2). It runs Apple's mesh optimizer every time, so use it at load time only.

### 5. Recommendations

1. **Viewer host.** Use `ARView(frame:cameraMode: .nonAR, automaticallyConfigureSession: false)` in a `UIViewRepresentable`.
   - Add a `PerspectiveCamera` under `AnchorEntity(world: .zero)` and drive it from custom UIKit orbit, pan and pinch gestures (yaw, pitch and distance around a target point).
   - Set `environment.background = .color(...)`.
   - RealityView is a viable SwiftUI alternative with the same picking math, but combined gestures must be custom there too.
2. **Chunk data model.** One Entity per chunk, each holding a LowLevelMesh.
   - Interleaved vertex: position float3, normal float3, uv0 float2, color `uchar4Normalized_bgra`. Indices are uint32.
   - The same layout can later feed an MTKView renderer, which is the escape hatch.
3. **View modes, all with `faceCulling = .none`:**
   - textured: `UnlitMaterial(texture:)`
   - solid: `UnlitMaterial(color:)`
   - wireframe: the same material with `triangleFillMode = .lines`
   - classification and coverage: parts split by class, with one UnlitMaterial per `materialIndex`
   - vertex color: try `ShaderGraphMaterial(materialXLabel:data:)` first, and keep `CustomMaterial(.unlit)` as the fallback. The final fallbacks are packing colour into uv1 or using per-face parts.
4. **Picking and measuring.**
   - Primary path: `ray(through:)`, then `scene.raycast(origin:direction:length:query: .nearest)` against `generateStaticMesh(from:)` shapes, with one shape per chunk entity. Read `hit.position` and `triangleHit?.faceIndex`.
   - While collision shapes are still building, use `pixelCast` as an optional fallback.
   - Keep a CPU ray-triangle fallback for measurement snapping.
   - Place labels with `project(_:)`.
5. **Live scan.** Use ARView in `.ar` mode with your own `ARWorldTrackingConfiguration` (`.meshWithClassification`, after checking `supportsSceneReconstruction`). Give each anchor an `AnchorEntity(anchor:)` holding a LowLevelMesh with four coverage parts, drawn with semi-transparent UnlitMaterials.
6. **Do not build on SceneKit or ARSCNView.**
7. **First CI and device spike.** Check that each of these compiles and logs:
   - ARView `.nonAR` with a PerspectiveCamera
   - a LowLevelMesh with a `.color` attribute rendered through both CustomMaterial and ShaderGraphMaterial (does colour or white appear?)
   - `triangleFillMode = .lines`
   - `generateStaticMesh(from:)` plus raycast, logging `faceIndex` and `shapeIndex` for known triangles
   - `pixelCast` latency and the `primitive` to part mapping
   - frame time and thermal state for about 1M triangles across 200 to 400 entities per material type

   Repeat on the iOS 26 phone. Make the material type and the chunk count swappable.

## floorplan-cad

Sources: `docs/research/raw/floorplan-cad.json` and `docs/research/verify/floorplan-cad.json`. Where they disagree, verify/ wins. Real-data checks used one encoded CapturedRoom, `laanlabs/openPlan3D test-roomplan.json`: version 2, 20 walls, 4 doors, 4 windows, L-shaped. Apple's reference docs never state units, but all RoomPlan lengths are meters (the ARKit convention).

### 1. VERIFIED APIs (safe on iOS 18.0, Swift 5.9 mode)

Nothing in this topic needs iOS 18 or iOS 26. The real floor is iOS 17. None of these members is deprecated in the iOS 26 SDK doc JSON.

**RoomPlan data (all Codable and Sendable)**
```swift
struct CapturedRoom                                   // iOS 16
  var identifier: UUID                                // iOS 17
  var story: Int { get }                              // iOS 17
  var floors: [CapturedRoom.Surface] { get }          // iOS 17
  var walls, doors, windows, openings: [CapturedRoom.Surface]
  var objects: [CapturedRoom.Object]
  var sections: [CapturedRoom.Section]                // iOS 17
  var version: Int
  func export(to: URL, exportOptions: CapturedRoom.USDExportOptions) throws
  func export(to: URL, metadataURL: URL?, modelProvider: CapturedRoom.ModelProvider?, exportOptions:) throws

struct CapturedRoom.Surface
  var identifier: UUID { get }
  var parentIdentifier: UUID? { get }                 // iOS 17, optional: handle nil
  var category: CapturedRoom.Surface.Category { get } // .floor, .door(isOpen: Bool), .opening, .wall, .window
  var confidence: CapturedRoom.Confidence { get }     // .high, .medium, .low
  var transform: simd_float4x4 { get }
  var dimensions: simd_float3 { get }                 // "bounding box that contains the surface"
  var story: Int { get }                              // iOS 17
  var completedEdges: Set<CapturedRoom.Surface.Edge> { get }  // .top .bottom .left .right
  var curve: CapturedRoom.Surface.Curve? { get }      // startAngle/endAngle: Measurement<UnitAngle>, radius: Float, center: simd_float2 (iOS 17)
  var polygonCorners: [simd_float3] { get }           // iOS 17, "in local plane coordinates"

struct CapturedRoom.Section { var label: Label; var center: simd_float3; var story: Int }  // iOS 17
  // Label: .livingRoom .kitchen .diningRoom .bedroom .bathroom .unidentified
struct CapturedRoom.Object { identifier, parentIdentifier (17), category, confidence, transform, dimensions, story (17),
  attributes: [any CapturedRoomAttribute] (17), func attribute<T>(of: T.Type) -> T? }
  // Category includes .stairs, .toilet, .sink, .bathtub, .bed, .sofa, .table, ... (16 cases)
struct CapturedRoom.USDExportOptions { static let parametric, mesh, model }   // .model + ModelProvider: iOS 17
```
- `Surface` has no `attributes` member. `CapturedRoomAttribute` adopters are all furniture types (Chair*, SofaType, StorageType, Table*).

**Multi-room (iOS 17)**
```swift
class StructureBuilder { init(options: StructureBuilder.ConfigurationOptions) // [.beautifyObjects] or []
  func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure }
enum StructureBuilder.BuildError { deviceNotSupported, exceedSceneSizeLimit, insufficientInput,
  internalError, invalidInput, invalidRoomLocation }
struct CapturedStructure { identifier, rooms, walls, doors, windows, openings, floors, objects, sections, version,
  func export(to:metadataURL:modelProvider:exportOptions:) }
RoomCaptureSession.init(arSession: ARSession? = nil)        // iOS 17
RoomCaptureSession.stop(pauseARSession: Bool = true)        // iOS 17
```

**Formatting (Foundation)**: `Measurement.FormatStyle(width:locale:usage:numberFormatStyle:)` (iOS 15), `MeasurementFormatter` (iOS 10) and `Locale.current.measurementSystem` (iOS 16: `.metric`, `.us`, `.uk`).

**Rendering**
- SwiftUI `Canvas` / `GraphicsContext` (iOS 15): `stroke`, `fill`, `draw(_:at:anchor:)`, `resolve(_:)`, `drawLayer`, `clip(to:style:options:)`, `withCGContext(content:)` and `transform`.
- Gestures: `DragGesture`, `SpatialTapGesture` (iOS 16), and `MagnifyGesture` / `RotateGesture` (iOS 17). Only the labels and types are verified. The default parameter values are not.

**PDF and sharing**
- `UIGraphicsPDFRenderer(bounds:format:)` with `pdfData(actions:)`, `writePDF(to:withActions:)`, `beginPage()` and `cgContext` (iOS 10). `UIGraphicsPDFRendererFormat.documentInfo` takes `kCGPDFContextTitle` and related keys.
- `CGContext(consumer:mediaBox:_:)` with `beginPDFPage` / `endPDFPage` / `closePDF`.
- `ImageRenderer` (iOS 16).
- `UTType.pdf`, `.svg`, `.usdz`. For DXF, use `UTType(filenameExtension: "dxf")`.
- `ShareLink` (iOS 16), and `fileExporter(isPresented:item:contentTypes:defaultFilename:onCompletion:onCancellation:)` with `Transferable` (iOS 17).

### 2. DISPUTED or REFUTED claims and verdicts

| Claim | Verdict |
|---|---|
| `floors[].polygonCorners` is the correct source for room area and perimeter | **REFUTED (reality).** In a real L-shaped, multi-section scan there is one floor per CapturedRoom and its polygon is a 4-corner bounding rectangle (6.43 x 7.43 m, 47.7 m2). That overstates the area by about 13% (about 6.4 m2). **Compute area and perimeter from the closed wall loop.** Use the floor polygon only as a fallback or cross-check, and flag a mismatch. The local-coordinate and full-matrix parts of the claim are correct. |
| StructureBuilder "throws otherwise" when rooms do not share a frame | **REFUTED.** Rooms from separate unrelocalized sessions merge **silently, stacked on top of each other** (forum 733945). `invalidRoomLocation` only catches rooms that are far apart. The app must make sure the rooms share a frame itself. Merging also moves rooms: "first room will be transformed" (760952). Room and floor IDs are regenerated. Wall, door, window, opening and object IDs are kept (739599). |
| DXF R12 with `$INSUNITS` | **REFUTED in part.** `$INSUNITS` is an R2000+ variable (ezdxf `mindxf=DXF2000`), so R12 has no reliable unit declaration. ezdxf and LibreCAD (libdxfrw) do read it from an AC1009 file. AutoCAD was not tested. |
| R2000 `LWPOLYLINE` needs handles (group 5) | **REFUTED in part.** Only the subclass markers `100/AcDbEntity` and `100/AcDbPolyline` are required by ezdxf. A file with no handles loads with 0 audit errors. libdxfrw is even more lenient. Whether AutoCAD accepts a file without handles is untested. |
| Wall transform column semantics (`columns.3` center, `columns.0` along the wall, `columns.1` up, `columns.2` normal; `dimensions.x` width, `.y` height, `.z` = 0) | Not in Apple docs. **Confirmed on real data** for all walls, doors and windows: endpoints chain within about 1 cm and `dimensions.z` is exactly 0. Two exceptions below. |
| Foundation cannot format fractional feet-inches | **Upheld.** The option list is slightly wider than claimed (`numberFormatStyle`, legacy `LengthFormatter.isForPersonHeightUse`), but no API outputs 3/8 fractions. |
| `ImageRenderer` "rasterizes some content" | **Corrected.** PDF output keeps text, lines, shapes and fills as vectors. Core Animation-backed views are replaced by a placeholder, not rasterized. |
| No hinge, swing or door type in the API; no wall thickness | **Upheld** by docs and real data. |

**Answered open questions**
- **Floor `polygonCorners`** are local (x, y, 0), equal to (±dims.x/2, ±dims.y/2). The floor's `columns.2` is world up.
- **Rectangular walls** have `polygonCorners == []`.
- **Apple's MergingMultipleScans sample** has no alignment logic. It only decodes JSON, runs `StructureBuilder`, then exports.
- **`story`** is 0 for all 10 rooms in Apple's MyHome sample, so treat it as advisory.

### 3. Platform-restricted APIs

- **iOS 26-only:** none relevant. The iOS 26 SDK adds no Surface members (no door or thickness data).
- **macOS-only:** none relevant.
- **Deprecated at 27.2 in the doc JSON but still compiling on the iOS 26 SDK:** `FileDocument`, `fileExporter(isPresented:document:contentType:...)`, `MagnificationGesture` and `RotationGesture`. Use `ShareLink`, the `Transferable` `fileExporter`, `MagnifyGesture` and `RotateGesture` instead.
- **iOS 17 minimum (fine at 18.0, but no `#available` needed):** `floors`, `polygonCorners`, `parentIdentifier`, `sections`, `story`, `StructureBuilder` and `CapturedStructure`. Only decode iOS 16-era JSON if old data exists; for such data, handle an empty `floors` array and a nil `parentIdentifier`.

### 4. Key gotchas with numbers

**Geometry frames and axes**
- **Plan axes:** world is right-handed and Y-up. Plan coordinates are world (x, z). One axis must be mirrored depending on the target: SwiftUI Canvas and UIKit PDF are y-down, while SpriteKit and a raw `CGContext(consumer:)` PDF are y-up. Verify on device with an L-shaped room.
- **Floor frame differs:** `columns.2` is up and `dimensions` = (width, depth, 0). Euler extraction hits gimbal lock (x = -pi/2), so yaw looks like 0. **Always use the full 4x4 multiply, never Euler angles.**
- **The sign of `columns.0` varies from wall to wall.** Derive wall winding and normal side from connectivity, not from column signs.
- **Guard for non-vertical walls:** if `abs(columns.1.y) < 0.99`, log it and project `columns.0` onto the horizontal plane.
- **Curved walls** (`curve != nil`) must be drawn as arcs. `curve.center` is local xz.
- **Wall endpoints overshoot or undershoot at corners.** Intersect adjacent infinite lines when the angle is not near 0 or 180 degrees.

**Openings, heights and thickness**
- **Doors and windows** sit slightly off the parent wall. Project their endpoints onto the wall and clamp to [0, wallLength]. Sill = `center.y - dims.y/2`, measured **relative to floor y** (for example -1.486), not relative to 0.
- **Wall thickness:** there is none in the data (dims.z = 0). RoomPlan splits walls thicker than about 50 cm into two faces. The USDZ parametric export's slabs of about 16 cm are added at export time. Real data also contains 0.30 m and 0.45 m wall stubs.
- **Ceiling height:** a wall's `dimensions.y` may be less than the real ceiling if the scan missed the top. Use the max, or the median over walls with `.high` confidence.

**Multi-room**
- **Size limit:** `exceedSceneSizeLimit` has no published value. WWDC23 recommends single-floor homes of about 186 m2 and 1 to 4 bedrooms.
- **World-map relocalization:** wait for tracking to go from relocalizing to normal before starting the next room.

**Rendering and export**
- **PDF scale:** 1/4" = 1' is 1:48, which is 59.055 pt/m. Paper sizes in points: Letter 612x792, Tabloid 792x1224, A4 595x842, A3 842x1191.
- **Canvas:** no per-element hit testing, so hit-test in model space (segment distance < 12 pt / scale). `GraphicsContext` is a value type, so copy it before clip or transform. Text scales with the transform, so draw labels in screen space. `Path.addArc(clockwise:)` is visually inverted in y-down space.
- **DXF numbers:** always use a '.' decimal separator (`Locale(identifier: "en_US_POSIX")`, `%.4f`). `DIMENSION` entities need DIMSTYLE and anonymous blocks, so draw dimensions as LINE + TEXT.

### 5. Recommendations

1. **Plan model.** Build a pure-Swift value-type `PlanModel` in meters, with plan XY = world (x, z), derived from CapturedRoom or CapturedStructure JSON.
   - Never mutate RoomPlan types. Store the original JSON and re-derive when needed (raw data stays unmodified).
   - Keep user overrides keyed by surface or object `identifier`: thickness, door hinge and swing, stair direction, room names, and a per-room 2D alignment (translation + yaw).
   - Undo is a value-type history stack.
2. **Room outline.**
   - Outline = closed wall loop built from `transform * (±dims.x/2, 0, 0, 1)` with corner intersection.
   - The floor polygon (full-matrix transformed, Y dropped) is only a cross-check. Warn if the two areas differ by more than a few percent.
   - Area uses the shoelace formula. Wall area subtracts child door and window areas, matched by `parentIdentifier`.
3. **Door defaults** (all editable):
   - Hinge goes at the end nearer the closest wall corner.
   - The door swings into the room whose outline contains `doorCenter + normal*0.3 m`.
   - Until the user confirms, draw the plan in a "sketch" style or with the default flagged.
4. **Wall thickness.**
   - Default 115 mm interior and 150 mm exterior, marked estimated.
   - In a structure, antiparallel walls (dot of normals < -0.95) that overlap and are 0.05 to 0.5 m apart give a measured thickness.
   - Offset thickness outward from the room face so room areas stay exact.
5. **Multi-room capture.**
   - Use one ARSession with `stop(pauseARSession: false)`, then a new `RoomCaptureSession(arSession:)` on the same session. Save an `ARWorldMap` so a scan can resume.
   - Before each room, check `worldMappingStatus` and the tracking state. Refuse to merge rooms captured in different frames.
   - After merging, match output back to input through the kept surface IDs, since output transforms can differ from input.
   - If the merge throws, or the rooms were scanned in separate sessions, use the manual "Arrange rooms" mode: drag and rotate with snapping for parallel faces and shared doors.
6. **Multi-floor.** There is no API for levels. Cluster rooms by floor world Y (gap about 1.2 m), with `story` only as a hint. Render one plan page per level. Draw stairs from `.stairs` footprints with a direction the user sets.
7. **Rendering.**
   - One Core Graphics routine renders the plan. The screen uses it through `Canvas` + `withCGContext`, and PDF export uses it through `UIGraphicsPDFRenderer`.
   - SVG and DXF are separate string writers over the same model.
   - The PDF sheet and scale are picked automatically. Each sheet gets a title block, scale bar, north arrow and room schedule.
8. **Units.** Units are already handled in `ios/Sources/Units/` and match the research: fractional imperial is custom code, metric uses `Measurement`, and the default comes from `measurementSystem`.
9. **DXF.**
   - The existing `ios/Sources/Export/DXFWriter.swift` is R12 (AC1009) with TABLES and "1 unit = 1 meter" without units, which matches the verdict.
   - Also state the units in a TEXT note and in the filename.
   - An optional R2000 variant would need the `100/AcDbEntity` + `100/AcDbPolyline` subclass markers. It should include handles anyway, because AutoCAD has not been tested without them.
   - Suggested layers: A-WALL, A-DOOR, A-GLAZ, A-FLOR-IDEN and A-ANNO-DIMS.
10. **Testing without a device.**
    - Add a real CapturedRoom JSON fixture (the openPlan3D sample, or one encoded on the test device) to the self-tests, to catch axis, mirroring and area bugs in CI.
    - Validate DXF output with a Python `ezdxf` audit step in CI.
    - On the first device run, log one floor's and one non-rectangular wall's `polygonCorners`.

## quality-coverage-measure

Sources: `docs/research/raw/quality-coverage-measure.json` and `docs/research/verify/quality-coverage-measure.json`. Where the two disagree, verify/ wins.

### 1. Verified APIs that are safe on iOS 18.0 in Swift 5.9 mode

**RoomPlan: live coaching and session** (verified by both the official-docs and the reality lens)
- `enum RoomCaptureSession.Instruction` (iOS 16.0) has exactly 6 cases: `.normal`, `.moveCloseToWall`, `.moveAwayFromWall`, `.turnOnLight`, `.slowDown`, `.lowTexture`. It arrives through `func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)`. Every delegate method has a blank default implementation. Apple publishes no numeric thresholds. Its ML guidance models are about 90% accurate across the lighting, speed and distance tasks.
- `class RoomCaptureSession` (iOS 16.0) has `var arSession: ARSession`, `var delegate`, `init()`, `static var isSupported`, `func run(configuration:)` and `func stop()`. `init(arSession: ARSession? = nil)` and `func stop(pauseARSession: Bool = true)` arrived in **iOS 17.0**, not 16.
- Delegate methods: `captureSession(_:didStartWith:)`, `didAdd:`, `didChange:`, `didUpdate:`, `didRemove:` (each takes a `CapturedRoom`), `didProvide:`, and `captureSession(_:didEndWith: CapturedRoomData, error: (any Error)?)`.
- `enum RoomCaptureSession.CaptureError` cases: `deviceNotSupported`, `deviceTooHot`, `exceedSceneSizeLimit`, `internalError`, `invalidARConfiguration`, `worldTrackingFailure`.
- `struct RoomCaptureSession.Configuration { init(); var isCoachingEnabled: Bool }`.
- `var completedEdges: Set<CapturedRoom.Surface.Edge> { get }` and `enum Edge { top, bottom, left, right }` are **iOS 16.0**. `Edge` is CaseIterable, Codable, Hashable and Sendable.
- `var polygonCorners: [simd_float3] { get }` (iOS 17.0) is in local plane coordinates. `CapturedRoom.Section` is also iOS 17.0.
- `enum CapturedRoom.Confidence { high, medium, low }` exists per `Surface` and per `Object`. It measures certainty of the **category**, not dimensional accuracy.
- `CapturedRoom.Surface` fields: `identifier`, `parentIdentifier: UUID?`, `category` (`.floor`, `.door(isOpen:)`, `.opening`, `.wall`, `.window`), `transform: simd_float4x4`, `dimensions: simd_float3` (x = width, y = height, z = thickness), `story`, `curve`. `CapturedRoom.floors` and `sections` are iOS 17.
- `StructureBuilder(options:)` with `capturedStructure(from: [CapturedRoom]) async throws -> CapturedStructure` is iOS 17.0.

**ARKit: tracking, depth and mesh**
- `ARCamera.trackingState` is `.notAvailable`, `.limited(Reason)` or `.normal`. `Reason` is `.initializing`, `.relocalizing`, `.excessiveMotion` or `.insufficientFeatures`. Changes also arrive through `session(_:cameraDidChangeTrackingState:)`. `ARFrame.worldMappingStatus` (iOS 12) is `.notAvailable`, `.limited`, `.extending` or `.mapped`.
- `ARFrame.sceneDepth` and `smoothedSceneDepth` return `ARDepthData?` (iOS 14.0). Its members are `unowned(unsafe) var depthMap: CVPixelBuffer` (metres) and `unowned(unsafe) var confidenceMap: CVPixelBuffer?`. `enum ARConfidenceLevel: Int, Comparable { low, medium, high }` has raw values 0, 1, 2.
- To enable depth, add `.sceneDepth` to `frameSemantics` after checking `ARWorldTrackingConfiguration.supportsFrameSemantics(_:)`. Call the check on the subclass, not on `ARConfiguration`.
- `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification` (iOS 13.4) must be guarded by `supportsSceneReconstruction(_:)`.
- `ARMeshAnchor.geometry: ARMeshGeometry` exposes `vertices`, `normals`, `faces` (triangles, `ARGeometryElement`, `bytesPerIndex` 4) and `classification: ARGeometrySource?`. Classification is one `UInt8` per face, read with `assumingMemoryBound(to: UInt8.self)`, where 0 is `.none`.
- `enum ARMeshClassification: Int { none, wall, floor, ceiling, table, seat, window, door }`.
- `ARSession.RunOptions.resetSceneReconstruction` removes all mesh anchors. When plane detection is on, ARKit smooths the mesh on detected planes.
- Other APIs from raw/ (Apple docs, not individually re-checked by verify/): `ARFrame.lightEstimate?.ambientIntensity` (1000 = neutral) and `ambientColorTemperature`; `ARCamera.exposureDuration` and `exposureOffset` (iOS 13); `ARFrame.raycastQuery(from:allowing:alignment:)`, `ARSession.raycast(_:)` and `trackedRaycast(_:updateHandler:)` (iOS 13); `ARPlaneAnchor.planeExtent: ARPlaneExtent` (iOS 16) with `boundaryVertices`; `ARConfiguration.supportedVideoFormats` and `videoFormat` (iOS 11.3); `recommendedVideoFormatForHighResolutionFrameCapturing` and `captureHighResolutionFrame() async throws -> ARFrame` (iOS 16); `ARCoachingOverlayView` (iOS 13); `ARFrame.rawFeaturePoints`.

**Projection** (verified; see section 3 for the iOS 27 trap)
- These are usable with no deprecation warning on the iOS 26 SDK: `ARCamera.projectPoint(_:orientation:viewportSize:)`, `unprojectPoint(_:ontoPlane:orientation:viewportSize:)`, `projectionMatrix(for:viewportSize:zNear:zFar:)` and `ARFrame.displayTransform(for:viewportSize:)`. Apple marks them deprecated only at iOS 27.0.
- The Swift spellings come from Apple samples. The live doc pages now show only the Objective-C form.

**RealityKit Object Capture** (iOS 17.0, `@MainActor`)
- `enum ObjectCaptureSession.Feedback` has 9 cases: `environmentLowLight`, `environmentTooDark`, `movingTooFast`, `objectNotDetected` (**iOS 17.4**), `objectNotFlippable`, `objectTooClose`, `objectTooFar`, `outOfFieldOfView`, `overCapturing`.
- Session members: `feedback`, `feedbackUpdates`, `cameraTracking`, `cameraTrackingUpdates`, `state`, `stateUpdates`, `numberOfShotsTaken`, `numberOfShotsTakenUpdates`, `maximumNumberOfInputImages`, `userCompletedScanPass`, `userCompletedScanPassUpdates`, `isPausedUpdates`, `canRequestImageCaptureUpdates`.
- `struct Updates<Element>: AsyncSequence` where `Element: Sendable`.
- `Tracking` is `.normal`, `.limited(reason:)` or `.notAvailable`. `CaptureState` is `initializing`, `ready`, `detecting`, `capturing`, `finishing`, `completed` or `failed(_:)`. `Configuration` has `checkpointDirectory` and `isOverCaptureEnabled`.

**Thermal, battery and idle timer** (verified by both lenses)
- `ProcessInfo.processInfo.thermalState` (`nominal`, `fair`, `serious`, `critical`; iOS 11) with `ProcessInfo.thermalStateDidChangeNotification`, plus `isLowPowerModeEnabled` (iOS 9).
- `UIDevice.current.isBatteryMonitoringEnabled` and `batteryLevel: Float`, which returns -1.0 while monitoring is off.
- `UIApplication.shared.isIdleTimerDisabled`. Apple's docs name mapping apps as an appropriate use.
- Apple's guidance for `.serious`: reduce CPU and GPU work, drop from 60 to 30 fps, lower detail. For `.critical`: stop using the camera if possible.

### 2. Disputed or refuted claims and the verdicts

| Claim | Verdict |
|---|---|
| `ARMeshGeometry.normals` is per face (Apple's doc abstract) | **REFUTED (reality).** In practice `normals.count == vertices.count`, so there is one normal per vertex. Size reads from `normals.count`. Compute face normals by cross product, or by averaging the 3 vertex normals. Reading normals by face index reads past the end of the buffer. |
| Projection formula in raw notes: `u = fx*x/z + cx`, `v = fy*y/z + cy` | **Sign error.** The correct mapping is `u = fx*x/(-z) + cx`, `v = fy*(-y)/(-z) + cy`, because visible points have negative z. The 256/1920 depth scale holds only because both images are 4:3. |
| LiDAR accuracy literature | **REFUTED in part.** Remote Sensing Letters 2026 compared the **iPhone 12 Pro Max and iPhone 15 Pro**. The base iPhone 15 has no LiDAR. The RMSE of 2.05 / 2.06 cm is for small objects (0.8 to 42.5 cm) at 0.01 to 3 m, not rooms, and the 15 Pro loses accuracy by 3 m. MDPI Geomatics 2023 scanned **one lab room**, not a building. It reports PolyCam std about 7 cm, Scaniverse mean deviation 44 cm, and achievable accuracy of about 10 to 20 cm. The "69-83% within 5 cm" figure is **unverified; do not cite it**. Confirmed: Luetzenburg 2021 (±1 cm for objects over 10 cm, ±10 cm at 130 m cliff scale) and ARKit vs Faro agreement of 3.7 cm median. "Reasonable to about 4 m" is optimistic. |
| `RoomCaptureSession` is iOS 16+ throughout | Minor correction: `init(arSession:)` and `stop(pauseARSession:)` are **iOS 17.0**. This does not matter for an iOS 18 target. |
| `completedEdges` semantics ("missing edge = never observed") | **Not refuted, but only community evidence.** Apple's `Edge` overview literally says the set "contains one of each case". Runtime reports show the set can be empty or partial during `didUpdate`. Treat it as a soft hint only (see open answer). |
| Depth details: 256x192, 60 Hz, ~5 m range, raw values 0/1/2 | Not in the API docs. Supported by WWDC20 10611 and forum posts. Effective independent LiDAR updates may be below 60 Hz because ARKit fuses depth with camera frames. Read size and pixel format at runtime. |
| Plan for about 1% battery per minute, measured with `batteryLevel` deltas | Caveat: on iOS 17 and later, `batteryLevel` is rounded to **5% steps**, so each measurable step needs a window of about 5 minutes. |

Open-question answers from verify/:
- **RoomPlan's ARSession has no mesh or depth by default** (likely). Its `frameSemantics` lacks `.sceneDepth`, and `run` overrides a `sceneReconstruction` set beforehand. The workaround: create your own `ARSession`, pass it to `RoomCaptureSession(arSession:)`, then in `captureSession(_:didStartWith:)` re-run it with an `ARWorldTrackingConfiguration` that has `.meshWithClassification` and `[.sceneDepth]`. Config changes apply asynchronously, so read the configuration later, for example in `didUpdate`. Keep a two-pass fallback (a separate mesh session) behind a flag.
- **`videoFormat` under RoomPlan:** unsure. A value set before `run` is probably overwritten. Do not depend on a non-default format during RoomPlan; use `captureHighResolutionFrame()` for texture stills.
- **`confidenceMap` format:** likely `kCVPixelFormatType_OneComponent8` (L008) with values 0 to 2. Map bytes through `ARConfidenceLevel(rawValue:)` and treat everything as medium if the format differs.
- **Mesh update cadence and anchor block size:** undocumented. Community figures of 0.5 to 1 s and 1 to 2 m blocks are unverified. Throttle per-anchor work to at most once every 0.5 s.
- **Thermal timeline:** unsure. Expect `.fair` within a few minutes and `.serious` after roughly 10 to 20 minutes of mesh plus RoomPlan plus overlay. No published numbers exist.

### 3. APIs that must not be used unguarded

- **iOS 27.0 only; these do not exist in the iOS 26 SDK and will fail on Xcode 26.6:** `ARCamera.projectPoint(_:viewRotationAngle:viewportSize:)`, `projectionMatrix(viewRotationAngle:viewportSize:zNear:zFar:)`, `unprojectPoint(_:ontoPlane:viewRotationAngle:viewportSize:)`, `viewMatrix(viewRotationAngle:)`, `ARFrame.displayTransform(viewRotationAngle:viewportSize:)` and `ARSession.viewRotationAngle`.
- **No macOS-only APIs appear in this topic.** Everything listed is iOS, iPadOS or Mac Catalyst.
- **Names that do not exist:** `ObjectCaptureSession.Feedback.outOfRange` (the real case is `.outOfFieldOfView`).
- **Version floors below the target** (fine, no guard needed): `objectNotDetected` needs iOS 17.4, and `init(arSession:)` and `stop(pauseARSession:)` need iOS 17.0.
- **Use `ARPlaneAnchor.planeExtent`, not `extent`.** On iOS 16 and later with a deployment target of 16 or higher, the anchor transform is no longer rotated automatically.

### 4. Key gotchas with numbers

- **Unretained depth buffers:** `ARDepthData.depthMap` and `confidenceMap` are `unowned(unsafe)`. Keep the `ARFrame` alive while you read them, then copy what you need and drop the frame. ARKit stops delivering frames if too many frames are held.
- **Unstable face indices:** mesh face indices change across updates because anchors re-mesh. Key coverage by a quantized world-space voxel, not by face index.
- **Enum switches:** `Feedback` (and other resilient-framework enums) need `@unknown default`.
- **MainActor members:** `ObjectCaptureSession` members are `@MainActor`.
- **Object Capture owns the camera:** it cannot run at the same time as your `ARSession` or `RoomCaptureSession`.
- **Pausing between rooms:** `stop()` pauses the ARSession by default. Use `stop(pauseARSession: false)` to keep the session between rooms and reuse the same `RoomCaptureSession` for multi-room scans. Live `CapturedRoom` geometry is provisional; walls are only tidied up at the end of the scan.
- **RoomPlan operating limits:** room up to 9 x 9 m (30 x 30 ft), height up to 3.6 m, light of at least 50 lux, scans under 5 minutes, multi-room up to 186 m² (2,000 sq ft). The wall detector uses 3 cm voxels, so do not claim wall lengths better than about ±3 cm.
- **RoomPlan in the field:** per-wall error up to ±5 cm, and errors accumulate around a room loop (one report: 6.821 m measured against 6.45 m true). Wall thickness defaults to about 16 cm. Walls thicker than about 50 cm come out as two walls. Mirrors cause gaps.
- **Thermal throttling is silent:** the frame rate drops and tracking drifts, with no error. RoomPlan reports it only as `deviceTooHot` in `didEndWith`.
- **Changing `videoFormat` needs a re-`run`:** that restarts the camera and can drop tracking.
- **Low confidence on some surfaces:** LiDAR confidence collapses on glass, mirrors, glossy black and back-lit windows. Stop nagging the user about those regions.
- **Voxel memory:** a 10 cm voxel hash for a 9 x 9 x 3 m room has at most 243k entries, typically 20k to 40k.

### 5. Recommendations

1. **One shared ARSession.** The app creates its own `ARSession`, passes it to `RoomCaptureSession(arSession:)`, and re-runs it in `didStartWith` with mesh and depth. On the first device build, log the configuration, `sceneDepth != nil` and the mesh anchor count, and confirm that RoomPlan still produces walls.
2. **Live coverage.** Run on a background queue at 3 Hz using a `[UInt64: UInt8]` hash of 10 cm voxels. Sample every 4th face. Accept a face when:
   - it is 0.3 m < depth < 4.0 m away,
   - it faces the camera within 60 degrees (dot product > 0.5), using face normals computed by cross product,
   - its confidence is at least `.medium`.

   Colours: 0 observations red, 1 to 2 yellow, 3 or more green. Drop to 1 Hz and hide the overlay at `.serious`.
3. **Per-wall coverage.** Expected area comes from `polygonCorners` (fallback `dimensions.x * dimensions.y`), minus the doors, windows and openings whose `parentIdentifier` is that wall. Observed area counts only `.wall` faces within 10 cm of the wall plane. Weight the result by `confidence` and by `completedEdges.count`, as a hint only and never as a gate.
4. **Holes.** Compute per updated anchor, never per frame. Boundary edges are edges used by exactly one face; ignore those within 2 cm of the anchor's bounding box, because anchor seams are not holes. Skip this work at `.serious`.
5. **Measurement accuracy.** Combine these terms:
   - depth error `(0.005 + 0.004*d) * k_c`, with k = 1 for high, 1.5 for medium, 3 for low confidence;
   - pose error 0.5%, 1.5% or 3% of the length, depending on the tracking history;
   - pick error 3 mm for a RoomPlan corner, 1 cm for a plane raycast, 2 cm for a raw mesh vertex.

   Display ±2σ with a floor of 1 cm. Show "Low confidence" instead of a number when σ > 4 cm. Never show a RoomPlan wall length as better than ±2.5 cm. Keep the parameters in one config struct and calibrate them with the tape-measure protocol in `TEST_PLAN.md`.
6. **Snapping priority:** RoomPlan corners and wall-wall-floor intersections first, then `ARPlaneAnchor.boundaryVertices`, then a `.existingPlaneGeometry` raycast, then `.estimatedPlane`. Snap radius is 10 cm in the world or 24 pt on screen, whichever is smaller.
7. **Thermal ladder:**
   - at `.serious`, switch to a 30 fps, low-resolution format at the next pause, hide the overlay and stop computing holes;
   - at `.critical`, pause and save.
   
   Set `isIdleTimerDisabled = true` while scanning, warn after 4 minutes of RoomPlan, warn below 20% battery, and log `batteryLevel` every 30 s, keeping the 5% step size in mind.
8. **Coaching.** Use RoomPlan's `Instruction` as the primary coaching text, all through `Copy.swift`. Add only what RoomPlan lacks: coverage percent, walls with missing edges, thermal warnings and the timer.
9. **Per-scan quality log**, saved next to the `CapturedRoomData`: tracking-limited fraction, relocalizations, time spent under each instruction, light level, thermal timeline, any `CaptureError`, per-wall coverage, and a histogram of depth confidence.
10. **Honest labels.** Label plan dimensions as "interior face to face" and "estimated ±1 in per 10 ft". Present `CapturedRoom.Confidence` as classification certainty, never as accuracy.

## storage-deploy

Sources: `docs/research/raw/storage-deploy.json` (27 facts) and `docs/research/verify/storage-deploy.json` (two independent lenses, official-docs and reality, run on 8 critical claims, plus 6 open-question answers). Where they disagree, verify/ wins. The only claim refuted, and only in part, is the Swift 5 concurrency claim (see section 2).

### 1. Verified APIs safe on iOS 18.0 / Swift 5.9

**Info.plist (XcodeGen `info.properties`)**
- `NSCameraUsageDescription` (iOS 7+). This is the only key RoomPlan, ARKit scene reconstruction and Object Capture need. There is **no entitlement** for any of them on iOS: every `com.apple.developer.arkit.*` entitlement is visionOS-only. If the key is missing, the app crashes on first camera access (TCC).
- `UIRequiredDeviceCapabilities`: `[arkit, arm64, metal]`. **No LiDAR value exists** among the 29 documented values. Gate at runtime instead. The key has no effect on sideloaded installs.
- `UIFileSharingEnabled` = true plus `LSSupportsOpeningDocumentsInPlace` = true, which shows Documents/ under "On My iPhone" in Files. (The need for both keys is community-verified.)
- `UISupportedInterfaceOrientations`: `[UIInterfaceOrientationPortrait]`. `UILaunchScreen`: `{}` (iOS 14+). `ITSAppUsesNonExemptEncryption`: false (harmless).
- Package document type: `UTExportedTypeDeclarations`, with `UTTypeIdentifier` `com.shreehub.mapper.project`, `UTTypeConformsTo` `[com.apple.package, public.content]` and extension `mapperproj`, plus `CFBundleDocumentTypes` (`CFBundleTypeRole` Editor, `LSHandlerRank` Owner, `LSTypeIsPackage` true, `LSItemContentTypes`). Swift side: `UTType(exportedAs:conformingTo:)` (iOS 14+).
- Not needed: `NSMotionUsageDescription`, `NSMicrophoneUsageDescription`, location keys, `UIBackgroundModes` (v1), and any entitlements file. `NSPhotoLibraryAddUsageDescription` is needed only for a "save to Photos" feature; `ShareLink` and `UIActivityViewController` do not need it. `PrivacyInfo.xcprivacy` is enforced only by the App Store.

**Runtime gates**
- `RoomCaptureSession.isSupported: Bool` (static, iOS 16). It is true if the device has a LiDAR Scanner.
- `ARWorldTrackingConfiguration.supportsSceneReconstruction(_: ARConfiguration.SceneReconstruction) -> Bool` (iOS 13.4), used with `.mesh` / `.meshWithClassification`.
- `@MainActor static var ObjectCaptureSession.isSupported` and `PhotogrammetrySession.isSupported` (iOS 17). Both need A14+ and LiDAR; the 13 Pro Max (A15) qualifies.

**Photogrammetry / Object Capture (iOS 17+)**
- `PhotogrammetrySession.Request.modelFile(url: URL, detail: Detail = .reduced, geometry: Geometry? = nil)`. **`.reduced` is the only detail level on iOS.**
- `convenience init(input: URL, configuration:) throws`. Prefer this directory form over `init<S: Sequence>(input: S, ...)` where the elements are `PhotogrammetrySample`.
- `Configuration`: `checkpointDirectory: URL?`, `isObjectMaskingEnabled`, `sampleOrdering`, `featureSensitivity`. It has no image-count field.
- `static let limits: PhotogrammetrySession.Limits` provides `maximumNumberOfInputImages: Int` and `maximumInputImageDimension: Int`. These are device-specific. Images over either limit are ignored and the session reports an `.invalidSample`-style output.
- `@MainActor class ObjectCaptureSession`: `start(imagesDirectory: URL, configuration: Configuration = Configuration())`, `startDetecting() -> Bool`, `startCapturing()`, `finish()`, and `@MainActor var maximumNumberOfInputImages: Int`. `Configuration` has `checkpointDirectory` and `isOverCaptureEnabled`.
- `PhotogrammetrySample(id:image:)` with `depthDataMap`, `objectMask`, `gravity: CMAcceleration?` and `metadata`.

**RoomPlan**
- `RoomCaptureSession(arSession:)` (iOS 17) shares one `ARSession`. Also `run(configuration:)`, `stop(pauseARSession:)` (iOS 17), and delegate methods `captureSession(_:didUpdate:)` and `captureSession(_:didEndWith:error:)`.
- `RoomBuilder.capturedRoom(from:) async throws`, and `StructureBuilder.capturedStructure(from: [CapturedRoom]) async throws` (iOS 17).
- `CapturedRoomData: Codable, Sendable`, so raw room data can be persisted as JSON.
- `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` (iOS 17). `USDExportOptions` is `.parametric`, `.mesh` or `.model`.

**ARKit capture data**
- `ARMeshAnchor.geometry: ARMeshGeometry` exposes `vertices`, `normals` and `classification?` (each an `ARGeometrySource` with `buffer`, `count`, `format`, `stride`, `offset`, `componentsPerVector`) and `faces` (`ARGeometryElement` with `bytesPerIndex`, `indexCountPerPrimitive`).
- `ARFrame.sceneDepth` / `smoothedSceneDepth: ARDepthData?` (iOS 14). `ARDepthData.depthMap` is Float32 'fdep' and `confidenceMap` is 8-bit 'L008'; both are `unowned(unsafe)`.
- `ARCamera.transform: simd_float4x4`, `intrinsics: simd_float3x3`, `imageResolution: CGSize`.
- `ARSession.delegateQueue: dispatch_queue_t?`. If nil, callbacks arrive on the main queue.
- `ARWorldMap` (iOS 12, NSSecureCoding): `NSKeyedArchiver.archivedData(withRootObject:requiringSecureCoding: true)`, `NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from:)`, `getCurrentWorldMap(completionHandler:)` or `currentWorldMap() async throws`, and `initialWorldMap`.

**Storage / encoding**
- `URLResourceValues.isExcludedFromBackup: Bool?` and `.isExcludedFromBackupKey`.
- `volumeAvailableCapacityForImportantUsage: Int64?` (iOS 11).
- `FileManager.url(for:in:appropriateFor:create:)` and `replaceItemAt`.
- `URLFileProtection`: leave the default, `.completeUntilFirstUserAuthentication`.
- `CIContext.writeHEIFRepresentation(of:to:format:colorSpace:options:)` (iOS 11), `writePNGRepresentation` (iOS 11), `writeJPEGRepresentation` (iOS 10). `CIFormat.L16/.Lh/.Lf`. `kCGImageDestinationLossyCompressionQuality`.
- `UnsafeRawBufferPointer.loadUnaligned(fromByteOffset:as:)` (Swift 5.7+).
- Model I/O is **not deprecated**: `MDLAsset.export(to:)`, `MDLAsset.canExportFileExtension(_:)`, `MDLMesh`. Neither are RealityKit `ARView` and `ModelEntity`.

**Memory / thermal / lifecycle**
- `os_proc_available_memory()` (iOS 13, `import os`).
- `ProcessInfo.processInfo.physicalMemory`, `thermalState` (`.nominal/.fair/.serious/.critical`), `isLowPowerModeEnabled`.
- `MTLDevice.recommendedMaxWorkingSetSize` (iOS 16) and `currentAllocatedSize`.
- `UIApplication.didReceiveMemoryWarningNotification`, `UIApplication.shared.isIdleTimerDisabled`.
- `beginBackgroundTask(withName:expirationHandler:)` and `backgroundTimeRemaining`.

### 2. Disputed or refuted claims

| Claim | Verdict |
|---|---|
| "Swift 5 mode: Sendable/actor-isolation problems are at most warnings and will not fail CI" | **REFUTED by both lenses.** Minimal checking downgrades only missing `Sendable` conformances and missing global-actor annotations to warnings. Core isolation rules have been hard errors in every language mode since Swift 5.5 (SE-0306). Examples: a synchronous call from nonisolated code into a `@MainActor` function or property, a missing `await`, a cross-actor property mutation, "actor-isolated property can only be referenced on self". These **fail the CI build in 5.9 mode**, so code must be written isolation-correct. XcodeGen's `base.yml` really does default to `SWIFT_VERSION: '5.0'`, and this repo overrides it to `"5.9"`, which is still Swift 5 mode. The claim that Xcode 26 changes only the defaults of new templates (so XcodeGen projects have `SWIFT_DEFAULT_ACTOR_ISOLATION` and `SWIFT_APPROACHABLE_CONCURRENCY` unset) is plausible but was not checked against a primary source. |
| `.reduced` texture size | Unresolved. One verifier read 2048x2048 in the doc table, the other read 1024x1024. Both agree on <50k triangles, about 10 MB, and diffuse + normal + AO maps. Read the texture size from the output, don't assume it. |
| `.custom` detail is "macOS 14+ only" | Minor correction: it is also on Mac Catalyst 17+. It is still **not on iOS**. |
| Raw: "the free-team profile almost certainly cannot carry `com.apple.developer.kernel.increased-memory-limit`" | Verify says **likely available** to free teams: an Xcode Personal Team build keeps it, and AltStore 2.2+ requests it. SideStore 0.7.0 drops it (bug #1616). Sideloadly's behavior is unknown. Test it on the device and don't depend on it (see section 5). |
| Free-account device limit ("3 UDIDs per 7 days", Corellium) | Unsure and undocumented by Apple. Two phones on one Apple ID are routine. The binding, confirmed limits are 3 active sideloaded apps per device, 10 App IDs per rolling 7 days, and a 7-day expiry. |
| Sideloadly FAQ quotes | Could not be re-fetched (blocked by the proxy). The numbers match Apple forum thread 675347, SideStore #68 and 2026 guides. Accepted. |
| Depth 256x192 and video 1920x1440 | Community/WWDC figures, not in the doc JSON. **Do not hardcode them.** Read `CVPixelBufferGetWidth/Height(depthMap)` and `ARCamera.imageResolution`, and derive the intrinsics scale from the ratio. |
| ~30 s from `beginBackgroundTask` | This is Apple DTS forum guidance ("about 30 seconds"), not the docs. Don't build logic on `backgroundTimeRemaining`. |

All the other critical claims were confirmed by both lenses: no LiDAR device capability, no entitlements, `.reduced` only, SceneKit deprecation, `simd_float4x4` not Codable, no background processing on iOS 18, and the sideload limits.

### 3. APIs to avoid, or to use only behind a guard

- **macOS / Mac Catalyst only:** `PhotogrammetrySession.Request.Detail` cases `.preview`, `.medium`, `.full`, `.raw`, `.custom` (and `CustomDetailSpecification`). An iOS build fails with an availability error if it uses them.
- **iOS 26.0+ only:** `BGContinuedProcessingTask` and `BGContinuedProcessingTaskRequest` (they conform to `ProgressReporting`, and the system shows the Live Activity itself). They need `if #available(iOS 26, *)`, must be submitted from the foreground in response to a user action, and are **CPU-only on any iPhone**. The `.gpu` resource and the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement work only on M3-or-newer iPads (Apple DTS thread 797538), and a free team probably can't sign that entitlement. Check `BGTaskScheduler.supportedResources`.
- **Deprecated in the iOS 26 SDK** (still compiles, with warnings): the SceneKit framework, `SCNView`, `SCNScene` and ARKit `ARSCNView` ("Use RealityView instead"). Don't use them in new code. Never set `SWIFT_TREAT_WARNINGS_AS_ERRORS`.
- **visionOS only:** every `com.apple.developer.arkit.*` entitlement.
- **Do not set:** `SWIFT_VERSION: 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, an entitlements file (a mismatch between the binary's entitlements and the provisioning profile fails the install), or `UIBackgroundModes` for v1.
- `BGProcessingTask` (iOS 13) is legal but useless for this app. It runs only when the device is idle and "the system terminates any background processing tasks running when the user starts using the device". It also needs `UIBackgroundModes` = processing and `BGTaskSchedulerPermittedIdentifiers`, registration before launch finishes, and exactly one registration per identifier (the app is killed on a second one).

### 4. Gotchas with numbers

- **Memory:** the 13 Pro Max has 6 GB of RAM. The jetsam limit is undocumented. Data points: a 4 GB iPhone 13 had about 2.2 to 2.3 GB available, and 4 GB iPhone 12 logs show "ActiveHard 2098 MB". Folklore for 6 GB phones is about 2.8 to 3.0 GB (unconfirmed). **Budget: about 2.5 GB hard ceiling, and a target working set under about 1.5 GB.** Log `os_proc_available_memory()` on the device; it returns 0 when already over the limit.
- **GPU in background:** iOS refuses GPU command submission from the background ("Insufficient Permission (to submit GPU work from background)"). All Metal and photogrammetry work must run in the foreground on every iOS version on this phone.
- **ARFrame retention:** ARKit warns once the delegate retains more than about 10 frames, and the camera freezes at about 15 to 20 (forum 695404). Copy the data out inside the callback. `depthMap` is `unowned(unsafe)`.
- **ARSession threading:** with `delegateQueue` nil, callbacks run on main. For extraction, use a serial background queue with a plain nonisolated `NSObject` delegate (not `@MainActor`, which risks runtime isolation traps in Swift 6.2). Hop to the main actor with value copies only, via `Task { @MainActor in }`. `getCurrentWorldMap` calls its completion on the `delegateQueue`, so archive on another queue.
- **Layouts:** ARKit vertices are packed float3 with **stride 12**, while Swift `SIMD3<Float>` has **stride 16**. Faces are uint32 x 3 and classification is uint8 per face. Always read `.format` and `.stride`, and use `MemoryLayout<T>.stride`. `simd_float4x4` is 64 B, and `loadUnaligned` avoids alignment traps after a header.
- **Codable:** `simd_float4x4` and `simd_float3x3` are **not Codable**; their conformances are BitwiseCopyable, Copyable, CustomDebugStringConvertible, Equatable, Escapable, Sendable. Use a wrapper (16 or 9 column-major Floats, or encode the `SIMD4<Float>` columns, which are Codable). Keep the wrapper in-module.
- **Object Capture directories:** `imagesDirectory` and `checkpointDirectory` must be **empty**, or the session fails. Use one unique checkpoint directory per images folder; reusing the same one lets reconstruction resume after a kill. Capture stops at `maximumNumberOfInputImages` unless `isOverCaptureEnabled` is set. For A15 there is only an unconfirmed secondary figure of about 1000 images, so read the limit at runtime. Keep the `Task` that iterates `outputs` alive.
- **Backup:** `isExcludedFromBackup` silently resets after common file operations (for example an atomic replace), so re-apply it after every write batch. Excluding a directory excludes its contents. Library/Caches can be purged by the system.
- **Files visibility:** with the file-sharing keys on, all of Documents/ is visible and user-deletable, including half-written chunks. Write to a temp file and rename, or stage the scan under Application Support and move the finished package in.
- **Sizes (5-min room, 1 keyframe/s):**
  - HEIC keyframes: about 300 to 500 KB each, 90 to 150 MB total.
  - Depth as Float16: 98 KB/frame, 30 to 45 MB total.
  - Confidence: 49 KB/frame, 15 MB total.
  - Poses: under 1 MB.
  - Mesh: 15 to 40 MB.
  - ARWorldMap: 5 to 30 MB (strip `ARMeshAnchor`s from `map.anchors`).
  - `.reduced` USDZ: about 10 MB.
  - Total: **about 200 to 350 MB per room**, several GB for 20 rooms. Refuse to start below about 1 GB free.
  - HEIC encode of a 1920x1440 frame takes about 20 to 40 ms on A15 (community figure).
- **Video format:** A15 on iOS 16+ also offers 4K (`supportedVideoFormats`), which quadruples memory use. Stay on the default.
- **Sideload:** Sideloadly rewrites the bundle id to `<bundleId>.<TEAMID>`. Never compare against `Bundle.main.bundleIdentifier` or build app-group or keychain names from it. Other limits:
  - 3 apps at once per device.
  - 10 App IDs per 7 days; an extension counts as an extra App ID, so keep a single target.
  - Apps expire after 7 days.
  - Keep the bundle id stable so Documents survives reinstalls.
  - Developer Mode must be enabled on each device (Privacy & Security > Security). The toggle is hidden until pairing, and enabling it needs a restart and a passcode.

### 5. Recommendations

1. **project.yml:** keep `SWIFT_VERSION "5.9"`, optionally set `SWIFT_STRICT_CONCURRENCY: targeted`, set `TARGETED_DEVICE_FAMILY "1"` (XcodeGen's iOS preset defaults to '1,2'), `IPHONEOS_DEPLOYMENT_TARGET 18.0` and `CODE_SIGNING_ALLOWED NO`. Put the Info.plist keys from section 1 in `info.properties`. No entitlements, no background modes.
2. **Write isolation-correct code:** mark SwiftUI views and models `@MainActor`, and keep all `ObjectCaptureSession` calls on the main actor. Use nonisolated AR and RoomPlan delegates that forward Sendable value copies.
3. **Rendering:** use RealityKit (`ARView` with `.showSceneUnderstanding`, or `RealityView`) or Metal. Use Model I/O only for OBJ and USD export. No SceneKit.
4. **Storage layout:** `Documents/Projects/<uuid>.mapperproj/` containing:
   - `project.json` (Codable, with a schema version).
   - `raw/` (immutable after capture, and `isExcludedFromBackup`):
     - `worldmap.arworldmap`
     - `mesh/<anchorUUID>.mchunk`, each with a 16-byte header {magic `MCHK`, version UInt16, count UInt32, stride UInt16} followed by raw little-endian arrays.
     - `keyframes/<i>.heic` (q 0.8)
     - `depth/<i>.f16` and `<i>.conf`
     - `poses.json` (Transform4/Intrinsics3 wrappers)
     - `room.capturedroomdata.json`
     - `objects/<id>/Images` and `Snapshots`
   - `derived/` (backed up): the USDZ, OBJ, PDF and JSON outputs.

   Skip SQLite and binary plists. Offer "delete raw data" only as an explicit user action after derived outputs exist.
5. **Memory:**
   - Keep only the latest geometry per anchor UUID.
   - Flush to disk on a serial IO queue.
   - Throttle keyframes to about 1 fps, or trigger on a pose delta over 0.3 m or 15 degrees.
   - Feed `PhotogrammetrySession` from a directory URL.
   - Downsample to 1440x1080 on memory warnings.
   - Pause capture at thermal `.serious` or `.critical`.
6. **Processing runs in the foreground:** set `isIdleTimerDisabled = true`, show progress from `outputs` (`.processingProgress`), and use a persistent checkpoint directory so work can resume after a jetsam kill. Add the iOS 26 `BGContinuedProcessingTaskRequest` path later, CPU-only.
7. **On-device logging for the next build:** `os_proc_available_memory()`, `physicalMemory`, `recommendedMaxWorkingSetSize`, `PhotogrammetrySession.limits`, depth map and image resolutions, and whether the increased-memory-limit entitlement survives signing (check `embedded.mobileprovision` and compare available memory with and without it). Treat any gain from that entitlement as a bonus, never a requirement.

## ui-ux-patterns

Sources: `docs/research/raw/ui-ux-patterns.json` (32 facts) and `docs/research/verify/ui-ux-patterns.json` (16 verdicts: every critical claim checked through an official-docs lens and a reality lens, plus 4 open-question answers). **No claim was refuted.** Where verify corrects raw on an availability or signature, verify wins. Those corrections are marked [V].

### 1. Verified APIs that are safe on iOS 18.0 in Swift 5.9 mode

**RoomPlan: capture view (iOS 16.0+)**
- `@MainActor @objc @preconcurrency class RoomCaptureView : UIView`. `init(frame: CGRect)`. `init(frame: CGRect, arSession: ARSession)` is iOS 17.0.
- `var captureSession: RoomCaptureSession! { get }` is **get-only**, so never assign it [V]. `weak var delegate: (any RoomCaptureViewDelegate)?` [V]. `var isModelEnabled: Bool { get set }` toggles the mini model at the bottom of the view.
- `protocol RoomCaptureViewDelegate : NSCoding` has two methods:
  - `func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool`. The default implementation returns true. Returning true makes the framework post-process the scan and show the final 3D review.
  - `func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?)`
- `protocol RoomCaptureSessionDelegate : AnyObject`. Every method has a default implementation. The methods are `didStartWith configuration`, `didAdd`, `didRemove`, `didChange`, `didUpdate capturedRoom`, `didProvide instruction: RoomCaptureSession.Instruction` and `didEndWith capturedData: CapturedRoomData, error:`.
- `enum RoomCaptureSession.Instruction : Equatable, Hashable` has exactly six cases: `normal`, `moveCloseToWall`, `moveAwayFromWall`, `turnOnLight`, `slowDown`, `lowTexture`. It is delivered only while `Configuration.isCoachingEnabled == true` (the default).
- `RoomCaptureSession` provides `init()`, `static var isSupported`, `run(configuration:)`, `stop()`, `var arSession: ARSession { get }` and `struct Configuration { var isCoachingEnabled: Bool }`. `init(arSession: ARSession?)` and `func stop(pauseARSession: Bool = true)` are iOS 17.0.
- `enum RoomCaptureSession.CaptureError : LocalizedError` has the cases `deviceNotSupported`, `deviceTooHot`, `exceedSceneSizeLimit`, `invalidARConfiguration`, `worldTrackingFailure` and `internalError`.

**RoomPlan: results**
- `struct CapturedRoom : Codable, Sendable` (iOS 16.0). `floors`, `story`, `version`, `sections` are iOS 17.0 [V].
- `func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws` (iOS 16.0). The default is `.mesh`.
- `func export(to: URL, metadataURL: URL?, modelProvider: CapturedRoom.ModelProvider?, exportOptions:) throws` (iOS 17.0). The defaults are nil, nil and `.mesh`.
- `USDExportOptions : OptionSet` has exactly three members:
  - `.parametric` gives unit-cube primitives that can be resized and moved.
  - `.mesh` gives polygonal walls with openings cut out.
  - `.model` gives the mesh plus `ModelProvider` models.
  - There is **no `.all`** [V].
- The `metadataURL` file is a String to UUID dictionary that links USDZ node names to `CapturedRoom` element identifiers. WWDC23 confirms this. The reference docs do not describe the format, so check it on device.
- `CapturedRoom.Surface` has `polygonCorners`, `curve` and `parentIdentifier` (all 17.0). `CapturedRoom.Object` is a bounding box: `transform` plus `dimensions: simd_float3`, 16 categories and `attributes` (17.0).
- `CapturedRoom.Section.Label` (iOS 17.0) has **six** cases: `livingRoom`, `kitchen`, `diningRoom`, `bedroom`, `bathroom`, `unidentified` [V].
- `class StructureBuilder` (iOS 17.0): `init(options: StructureBuilder.ConfigurationOptions)` with `.beautifyObjects`, and `func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure`. `CapturedStructure` is `Codable, Sendable` and has its own `export(to:metadataURL:modelProvider:exportOptions:)`.

**RealityKit Object Capture (iOS 17.0+ unless noted)**
- `@MainActor @preconcurrency struct ObjectCaptureView<Overlay: View>`: `init(session:)` and `init(session:, @ViewBuilder cameraFeedOverlay: () -> Overlay)`.
- `func hideObjectReticle(_ value: Bool = true) -> ObjectCaptureView<Overlay>` is **iOS 18.0** [V].
- `@MainActor struct ObjectCapturePointCloudView`: `init(session:)`. `func showShotLocations(_ value: Bool = true)` is **iOS 18.0** [V].
- `@MainActor class ObjectCaptureSession : Observable, Identifiable`:
  - Methods: `start(imagesDirectory:configuration:)`, `startDetecting() -> Bool`, `startCapturing()`, `resetDetection() -> Bool`, `beginNewScanPass()`, `beginNewScanPassAfterFlip()`, `requestImageCapture()`, `pause()`, `resume()`, `finish()`, `cancel()`.
  - Properties: `state`, `feedback: Set<Feedback>`, `cameraTracking`, `userCompletedScanPass`, `numberOfShotsTaken`, `maximumNumberOfInputImages` and `canRequestImageCapture`. Each has a matching `*Updates` AsyncSequence.
  - `isAutoCaptureEnabled` and `shouldPlayHaptics` are **iOS 18.0** [V].
- `CaptureState` has the cases `initializing`, `ready`, `detecting`, `capturing`, `finishing`, `completed`, `failed(any Error)`. `Configuration` has `checkpointDirectory: URL?` and `isOverCaptureEnabled`.
- `ObjectCaptureSession.Feedback` has the cases `objectTooFar`, `objectTooClose`, `environmentTooDark`, `environmentLowLight`, `movingTooFast`, `outOfFieldOfView`, `objectNotDetected`, `objectNotFlippable`, `overCapturing`.
- `startCapturing()` from `.ready` is the documented freeform or area mode.
- `PhotogrammetrySession` (iOS 17.0): `case modelFile(url: URL, detail: Detail = .reduced, geometry: Geometry? = nil)`, `process(requests:)`, `outputs`, `cancel()`, and `Configuration.isObjectMaskingEnabled` / `checkpointDirectory`.

**ARKit / RealityKit**
- `ARView.DebugOptions.showSceneUnderstanding` (13.4) draws a depth-colored wireframe. It needs `sceneReconstruction = .meshWithClassification`.
- `ARWorldTrackingConfiguration.supportsSceneReconstruction(_:)` (13.4).
- `ARMeshGeometry { vertices, normals, faces, classification: ARGeometrySource? }` (13.4).
- `ARCoachingOverlayView` (13.0): `goal`, `activatesAutomatically` and `setActive(_:animated:)`. Delegate callbacks are `coachingOverlayViewWillActivate`, `coachingOverlayViewDidDeactivate` and `coachingOverlayViewDidRequestSessionReset`.
- `ARSession.currentWorldMap() async throws -> ARWorldMap`.

**SwiftUI / UIKit**
- `UIViewRepresentable` with `makeUIView`, `updateUIView`, `makeCoordinator` and `static dismantleUIView(_:coordinator:)`.
- `NavigationStack(path:)` with `.navigationDestination(for:)` (16.0).
- `ShareLink(item:subject:message:preview:)` (16.0).
- `.sensoryFeedback(_:trigger:)` (17.0).
- `UIApplication.shared.isIdleTimerDisabled`.
- `.persistentSystemOverlays(.hidden)` (16.0).
- `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))` (16.0) and `UIViewController.setNeedsUpdateOfSupportedInterfaceOrientations()` (16.0).
- `@ScaledMetric`, `.dynamicTypeSize(_:)`.
- `Measurement.FormatStyle` with `.asProvided` / `.personHeight` (15.0).

### 2. Disputed or corrected claims and verdicts

| Claim (raw) | Verdict |
|---|---|
| Critical claims (RoomCaptureView UX, the 6-case Instruction enum, house mode, CapturedRoom export, Object Capture views, area mode, iOS reduced-only photogrammetry, mesh visualization) | Each was checked by official docs and by reality, and all of them **hold**. |
| `hideObjectReticle` / `showShotLocations` are iOS 17 | **Corrected: iOS 18.0.** No guard is needed at an 18.0 target. |
| `isAutoCaptureEnabled`, `shouldPlayHaptics` are 17.0 | **Corrected: iOS 18.0.** |
| `floors`/`story`/`version` iOS 16; `.model` iOS 17 | **Corrected:** floors, story and version are 17.0, and the `.model` constant is 16.0 but only usable through the 17.0 overload. Both points are moot at 18.0. |
| `StructureBuilder(option:)` (WWDC23 code) | **Use `init(options:)`**, the spelling in the docs. |
| `export(... exportOptions: .all)` (sample comment) | **Refuted: `.all` does not exist.** |
| Section labels are only livingRoom, kitchen and diningRoom | **Refuted:** there are six labels, all iOS 17.0. |
| House mode is "single floor" only | **Softened:** current docs support different floor heights and floors. Single floor is a best-results recommendation. |
| "Duplicate walls removed" | The reference docs do not say this. WWDC23 10192 presents StructureBuilder as the merge that fixes duplicates. |
| metadataURL writes a node-name to UUID map | Confirmed by WWDC23 only. The reference docs do not describe the format. |
| A 2023 blog says `.medium` works on iOS | **Refuted.** `.medium`, `.full`, `.raw` and `.preview` have no iOS platform entry. |
| ShareLink with a folder URL works like UIActivityViewController | **Unsure.** Only an on-device test can settle it (see section 5). |
| Per-view orientation lock in SwiftUI | **Likely feasible.** It needs the AppDelegate bridge described in section 4. |
| Competitor UI labels (Polycam, Scaniverse) | Only "likely". The pages returned 403 and the details came from search snippets, so treat the labels as approximate. |

### 3. APIs that must not be used unguarded (macOS-only or not on iOS)

- `PhotogrammetrySession.Request.Detail.preview`, `.medium`, `.full` and `.raw` are **macOS 12 / Mac Catalyst 15 only**. They fail to compile on iOS as "unavailable", and `#available` does not help.
- `.custom` and `Configuration.customDetailSpecification` are macOS 14 / Catalyst 17 only.
- `Configuration.meshPrimitive` is macOS only.
- Hardcode `.reduced` on the phone.
- No iOS 26-only API is needed for this topic.
- `UIImpactFeedbackGenerator.init(style:)` is **deprecated in the iOS 26 SDK**. This gives a warning, not an error. Prefer `.sensoryFeedback`. `init(style:view:)` is the replacement, but its availability was not checked in this research, so check it before use at an 18.0 target.
- Nothing here requires iOS 18 except `hideObjectReticle`, `showShotLocations`, `isAutoCaptureEnabled` and `shouldPlayHaptics`. All four are satisfied by the 18.0 target.

### 4. Key gotchas with numbers

- **NSCoding conformance:** `RoomCaptureViewDelegate` inherits NSCoding. The Coordinator must be declared as `class Coordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate` and must include `func encode(with coder: NSCoder) {}`, `required init?(coder: NSCoder) { fatalError() }` and a plain `init`. Without these the conformance fails to compile.
- **Delegate signatures:** a near-miss signature on a defaulted delegate method silently becomes a non-delegate method, with only the warning "nearly matches defaulted requirement". Copy the labels exactly.
- **View lifetime:** create `RoomCaptureView` once, in `makeUIView`, and never in `updateUIView`, or the scan restarts. Call `stop()` in `dismantleUIView`.
- **Duplicate coaching:** `RoomCaptureView` always draws its own coaching, and there is no way to suppress it while still receiving `didProvide instruction` (forum 736482). Showing your own banner on top of it duplicates the prompts.
- **Non-frozen enums:** `Instruction`, `Section.Label`, `Feedback` and `CaptureError` are not `@frozen`. Use `@unknown default` or `default` in every switch.
- **StructureBuilder crashes:** forums 743184 and 784052 report EXC_BAD_ACCESS and errors on some merges, possibly on walls with more than 4 edges. `capturedStructure(from:)` also **ignores edits** made to CapturedRoom attributes. Catch `StructureBuilder.BuildError` and keep each room's `CapturedRoom` JSON as a fallback. Merge only when rooms share world space, either through the same ARSession with `stop(pauseARSession: false)` or by relocalizing with a saved `ARWorldMap` after checking `worldMappingStatus == .mapped`.
- **House mode limits (WWDC23):** 1 to 4 bedrooms plus living, kitchen and dining. At most **2,000 sq ft (186 m2)**, and **50 lux or more** of light.
- **Single room limits (WWDC22):** up to **30 x 30 ft (9 x 9 m)**. Keep scans **under 5 minutes** because of heat and battery. `exceedSceneSizeLimit` fires on large open spaces.
- **ObjectCaptureSession start rules:** `start()` may be called **once per session**. `imagesDirectory` must be empty and writable. A non-empty `checkpointDirectory` sends the session to `.failed`. Use fresh UUID folders for each scan.
- **ObjectCaptureView memory leak:** forum 743232 reports a leak of **roughly 250 to 500 MB** each time the view appears and disappears. On the 6 GB A15 test device, minimise tear-down and recreate cycles, and pair view removal with `pause()` and `resume()`.
- **Object Capture requirements:** LiDAR and A14 or later. The object must be larger than **3 in (8 cm)**. Capture stops at `maximumNumberOfInputImages` unless `isOverCaptureEnabled` is on.
- **Area mode:** areas larger than **6 ft** lose quality. The Apple sample also sets `isObjectMaskingEnabled = false` for area-mode reconstruction.
- **On-device photogrammetry (`.reduced`):** under **50k triangles**, **2048x2048** diffuse, normal and AO maps, about **10 MB**.
- **Raw mesh display:** the colors of `showSceneUnderstanding` are debug-only and cannot be styled. For coverage coloring, build your own `MeshResource` (MeshDescriptor or LowLevelMesh) from `ARMeshAnchor.geometry`. ARMeshAnchors are re-meshed and faces have no stable IDs, so key coverage by position (a voxel grid), not by face index.
- **Guidance timing:** Apple's feedback messages stay on screen for at least **2.0 s** and are deduplicated. The pill in Apple's sample uses `.font(.headline).fontWeight(.bold)`, white text and a forced dark color scheme.
- **Portrait lock:** Apple's Object Capture sample locks portrait and sets `UIRequiresFullScreen = YES`. RoomCaptureView behaviour in landscape is untested.
- **Forced rotation on iOS 18:** this reportedly re-renders the SwiftUI view and **resets `@State`**. Keep scan state in an observable model owned above the view.
- **Info.plist:** a missing `NSCameraUsageDescription` crashes the app on first camera use. A free Apple ID needs no special entitlement for these APIs.
- **File naming:** before iOS 17.4 a USD file name must not start with a digit. This does not affect the 18.3.2 test device.
- **Formatting:** Foundation has no fraction formatter. Use the existing `ios/Sources/Units/` code.

### 5. Recommendations

1. **Room mode for v1:** use `RoomCaptureView`, wrapped in `UIViewRepresentable`, and accept its built-in coaching. Build a custom `RoomCaptureSession` UI only if live raw-mesh coverage coloring has to be shown during the same scan.
2. **House mode:**
   - The app owns a single `ARSession` and passes it through `RoomCaptureView(frame:arSession:)`.
   - Call `stop(pauseARSession: false)` after each room, then `run(configuration:)` on the same session.
   - Encode every `CapturedRoom` to JSON as soon as the room finishes.
   - At the end, run `StructureBuilder(options: [.beautifyObjects])` inside do/catch, with a fallback to separate rooms.
3. **Object mode:**
   - Copy the GuidedCapture state machine: `ready`, then Continue calls `startDetecting()`, then Start Capture calls `startCapturing()`.
   - Up to 3 orbits, calling `beginNewScanPass()` or `beginNewScanPassAfterFlip()`, then `finish()`.
   - Reconstruct with `.reduced`.
   - Hide your own overlay while `cameraTracking != .normal`, because ARKit's coaching overlay appears automatically.
   - Area mode skips `startDetecting()` and uses `.hideObjectReticle(true)`.
4. **Guidance banner:**
   - Show one message at a time, imperative, 2 to 6 words, top-center, for at least 2 s. Replace it rather than stacking, and hide it on `.normal`.
   - Map every `Instruction`, `Feedback` and `CaptureError` case to a `Copy.swift` string.
   - Map all six `Section.Label` cases to `Copy.swift` as well, as rename suggestions only.
5. **Screen flow:**
   - Home: a project grid and a large New Scan button.
   - Then a mode sheet (Room, House, Object), then a tips sheet shown once per mode.
   - Capture screen: portrait, forced-dark HUD, Cancel and Done.
   - Review: Keep or Rescan, plus Next room in house mode.
   - Processing: a `ProgressView` with the stage and remaining time.
   - Result: Realistic | Clean | Floor plan | Mesh, a measure tool, and share.
6. **Measure tool:** a center reticle and a thumb-reachable "+" button. Snap to wall `polygonCorners` within about **24 pt**, show a live length label, and play haptic `.selection` on a snap.
7. **Units display:** ft-in rounded to **1/8 in** by default, with a 1/16 option. Metric goes on a secondary line. Show sq ft as whole numbers and m2 to one decimal.
8. **Screen and haptics:** set `isIdleTimerDisabled` only on the capture and processing screens, and reset it when they close. Play `.sensoryFeedback(.success)` at the end of a scan and `.warning` on tracking loss, never on every `didUpdate`.
9. **Sharing:** route all sharing through one ShareService with a `UIActivityViewController` representable, which is what Apple's sample uses to share folders. As a fallback, zip the folder with `NSFileCoordinator` and the `.forUploading` option. Test ShareLink against a folder URL on device before relying on it.
10. **Orientation:** portrait-only for v1. If the viewer later needs landscape, use `@UIApplicationDelegateAdaptor` returning a static mask from `application(_:supportedInterfaceOrientationsFor:)`. Present the scan screen as a portrait-only `fullScreenCover`, and never force a rotation while a session is running.
11. **Accessibility:** support Dynamic Type, cap the AR HUD at `.xxxLarge`, and give every icon-only button an `.accessibilityLabel`.