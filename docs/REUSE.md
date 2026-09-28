# Reuse notes: Apple's own proven flows

Phase 0 of `docs/tasks/lead.md`: give module agents Apple's documented flows so they write less from scratch and make fewer API mistakes.

## How this was produced, and what may be copied

- Apple's sample code downloads (`docs-assets.developer.apple.com`) are blocked from the build sandbox (the proxy answers 403 on CONNECT, checked on 2026-09-28 for all three zips). No sample file was read or copied.
- Everything below comes from Apple's documentation JSON (`https://developer.apple.com/tutorials/data/documentation/<path>.json`), the WWDC session pages (transcript and code tab), and `docs/RESEARCH.md` (branch `origin/docs/research-md`). Declarations are copied from the documentation JSON, not from memory.
- Code listings here are short excerpts from Apple's documentation and WWDC pages, each marked with its source URL. They show the call pattern. Mapper code must be written fresh in Mapper's style (Swift 5.9, no force unwraps, text from `Copy.swift`, doc comments). Do not paste long blocks.
- Nothing from a sample project is included in the repository, so `THIRD_PARTY_NOTICES.md` lists these pages as references only. If anyone later copies a file from an Apple sample zip, follow the procedure in that file.
- Several Apple snippets do not compile as written. Each one is flagged in the Gotchas of its section.

Legend for declarations: the iOS version is the introduction version from the doc JSON. Everything cited is available at the iOS 18.0 deployment target without `#available`, unless marked.

## Quick map: which module takes what

| Module (MODULES.md / design record) | From the RoomPlan sample flow | From the Object Capture sample flow | From the ARKit reconstructed-scene sample |
|---|---|---|---|
| CaptureCore (M10, `ARSessionHub`) | App-owned `ARSession` handed to `RoomCaptureView(frame:arSession:)`; relocalization callbacks from "Scanning the rooms of a single structure" | Nothing (ObjectCaptureSession owns its own camera session; stop the hub first) | Scan configuration: `sceneReconstruction = .meshWithClassification`, `.sceneDepth`, support checks, `automaticallyConfigureSession = false` |
| RoomCapture (M15) | The whole RoomCaptureView flow: view, both delegates, run, stop, RoomBuilder, per-room persistence, multi-room continuation | Nothing | Nothing |
| ObjectCapture (M16, build 5) | Nothing | The whole GuidedCapture flow: state machine, `ObjectCaptureView` with overlay, scan passes, point cloud review, `PhotogrammetrySession` reconstruction | Nothing |
| MeshRecord (M11) | Nothing | Nothing | Buffer access for vertices, face indices and per-face classification (rewritten to honor offset and stride) |
| LiveMeshView (M18) | Nothing | Nothing | `ARView(.ar)` bound to the hub session, `.showSceneUnderstanding` wireframe, tap raycast with `.estimatedPlane` and `.any` |
| Viewer3D (M31) | Nothing directly (Mapper renders its own clean model) | Load the reconstructed `model.usdz` | Classification colors, nearest-face classification lookup, label placement and distance scaling ideas |
| ExportUI (M37) | `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)`, the export options table, Codable JSON next to the USDZ, `CapturedStructure` export for houses | `.modelFile` output as USDZ, or OBJ into a directory | Nothing |
| Also | GuidanceUI: `Instruction` mapping; Structure/HouseUI (build 5): `StructureBuilder` | GuidanceUI: `Feedback` mapping | MeasureTool and LiveMeasure: `ARView.raycast(from:allowing:alignment:)` |

---

## 1. RoomPlan sample: "Create a 3D model of an interior room by guiding the user through an AR experience"

Pages used:
- Sample page: https://developer.apple.com/documentation/roomplan/create-a-3d-model-of-an-interior-room-by-guiding-the-user-through-an-ar-experience (iOS 16.0, Xcode 26.0; associated with WWDC22 session 10127). The page itself has only an overview; the flow is in the symbol pages and the session below.
- Symbol pages: `roomplan/roomcaptureview`, `roomcaptureview/init(frame:arsession:)`, `roomcaptureview/init(frame:)`, `roomcaptureview/capturesession`, `roomcaptureview/delegate`, `roomcaptureview/ismodelenabled`, `roomplan/roomcaptureviewdelegate` and both methods, `roomplan/roomcapturesession`, `roomcapturesession/init(arsession:)`, `run(configuration:)`, `stop()`, `stop(pausearsession:)`, `arsession`, `issupported`, `roomplan/roomcapturesessiondelegate` and all seven methods, `roomplan/roombuilder`, `roombuilder/init(options:)`, `roombuilder/capturedroom(from:)`, `roomplan/capturedroomdata`, `capturedroom/export(to:exportoptions:)`, `capturedroom/export(to:metadataurl:modelprovider:exportoptions:)`, `capturedroom/usdexportoptions`, `roomplan/structurebuilder`, `structurebuilder/capturedstructure(from:)`, `capturedstructure/export(to:metadataurl:modelprovider:exportoptions:)`. All under https://developer.apple.com/documentation/.
- Article: https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure (multi-room flow with RoomCaptureView).
- Sample page: https://developer.apple.com/documentation/roomplan/merging-multiple-scans-into-a-single-structure (iOS 17.0; WWDC23 10192).
- WWDC22 10127 "Create parametric 3D room scans with RoomPlan": https://developer.apple.com/videos/play/wwdc2022/10127/ (transcript and code tab read).
- WWDC23 10192 "Explore enhancements to RoomPlan": https://developer.apple.com/videos/play/wwdc2023/10192/ (transcript and code tab read).

### 1.1 The flow, in order (RoomCaptureView path)

1. Check support: `RoomCaptureSession.isSupported` ("true if the device contains a LiDAR Scanner").
2. Create the view. Either `RoomCaptureView(frame:)` (RoomPlan creates its own `ARSession`, reachable as `captureSession.arSession`) or, iOS 17, `RoomCaptureView(frame:arSession:)` with a world-tracking session the app "creates and runs with an ARWorldTrackingConfiguration before calling this function". Doc: "If you pass an ARSession instance, RoomPlan preserves all of the AR session's settings."
3. Set both delegates: `roomCaptureView.captureSession.delegate` (a `RoomCaptureSessionDelegate`) and `roomCaptureView.delegate` (a `RoomCaptureViewDelegate`). The multi-room article confirms an app using `RoomCaptureView` receives `captureSession(_:didEndWith:error:)` through the view's `captureSession`.
4. Make a `RoomCaptureSession.Configuration()`. Its only option is `isCoachingEnabled` (default `true`).
5. Start: `roomCaptureView.captureSession.run(configuration:)`. The session delegate gets `captureSession(_:didStartWith:)`.
6. While scanning, the view draws the camera feed, animated outlines of walls, doors, windows, openings and objects, the live mini model at the bottom (`isModelEnabled`), and coaching text. The session delegate receives `didAdd`, `didChange`, `didRemove`, `didUpdate` (full snapshot) and `didProvide` (instruction).
7. The user taps Done. The app calls `captureSession.stop()` (pauses the ARSession) or `stop(pauseARSession: false)` (iOS 17, keeps it running).
8. The session delegate gets `captureSession(_:didEndWith:error:)` with the raw `CapturedRoomData`. The view delegate gets `captureView(shouldPresent:error:)` with the same raw data:
   - return `true` (the default): the framework processes the data, shows a 3D rendition the user can pan and pinch, and then calls `captureView(didPresent:error:)` with the processed `CapturedRoom`;
   - return `false`: no processing and no preview. Process the data yourself with `RoomBuilder`, or encode it for later.
9. Use the result: inspect `CapturedRoom`, encode it (Codable), or `export(to:...)` a USD or USDZ file.

The sample app wires steps 2 to 9 in one view controller (WWDC22 code tab below).

### 1.2 Exact declarations

```swift
import RoomPlan

// RoomCaptureView (UIView subclass)
@MainActor @objc @preconcurrency class RoomCaptureView                              // iOS 16.0
@MainActor @preconcurrency override dynamic init(frame: CGRect)                     // iOS 16.0
@MainActor @preconcurrency init(frame: CGRect, arSession: ARSession)                // iOS 17.0
@MainActor @preconcurrency required dynamic init?(coder: NSCoder)                   // iOS 16.0
@MainActor @preconcurrency var captureSession: RoomCaptureSession! { get }          // iOS 16.0
@MainActor @preconcurrency weak var delegate: (any RoomCaptureViewDelegate)?        // iOS 16.0
@MainActor @preconcurrency var isModelEnabled: Bool { get set }                     // iOS 16.0

// View delegate (both methods have default implementations; shouldPresent defaults to true)
protocol RoomCaptureViewDelegate : NSCoding                                          // iOS 16.0
func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool
func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?)

// Session
class RoomCaptureSession                                                             // iOS 16.0
init()                                                                               // iOS 16.0
init(arSession: ARSession? = nil)                                                    // iOS 17.0
static var isSupported: Bool { get }                                                 // iOS 16.0
func run(configuration: RoomCaptureSession.Configuration)                           // iOS 16.0
func stop()                                                                          // iOS 16.0
func stop(pauseARSession: Bool = true)                                               // iOS 17.0
weak var delegate: (any RoomCaptureSessionDelegate)?                                 // iOS 16.0
var arSession: ARSession                                                             // iOS 16.0; set at init, "throws an error if your app attempts to set a value"
struct Configuration { init(); var isCoachingEnabled: Bool }                         // iOS 16.0

// Session delegate (all methods have default empty implementations)
protocol RoomCaptureSessionDelegate : AnyObject                                      // iOS 16.0
func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration)
func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom)
func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction)
func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?)

// Post-processing
struct CapturedRoomData                         // iOS 16.0, opaque, Decodable, Encodable, Sendable
class RoomBuilder                               // iOS 16.0
init(options: RoomBuilder.ConfigurationOptions) // pass [.beautifyObjects], or [] to omit post-processing
func capturedRoom(from capturedRoomData: CapturedRoomData) async throws -> CapturedRoom

// Export (CapturedRoom is Decodable, Encodable, Sendable)
func export(to url: URL, exportOptions: CapturedRoom.USDExportOptions = .mesh) throws                        // iOS 16.0
func export(to url: URL, metadataURL: URL? = nil, modelProvider: CapturedRoom.ModelProvider? = nil,
            exportOptions: CapturedRoom.USDExportOptions = .mesh) throws                                      // iOS 17.0

// Multi-room
class StructureBuilder                                                               // iOS 17.0
init(options: StructureBuilder.ConfigurationOptions)                                 // iOS 17.0
func capturedStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure // iOS 17.0
// CapturedStructure.export(to:metadataURL:modelProvider:exportOptions:), same shape as CapturedRoom's, iOS 17.0
```

Enum cases (`Instruction`, `CaptureError`, `BuildError`, `Surface.Category`, `Object.Category`) and the full result model are in `docs/RESEARCH.md` section 3.2, "Verified API".

Export options, from Apple's `USDExportOptions` table (https://developer.apple.com/documentation/roomplan/capturedroom/usdexportoptions):

| Feature | `.parametric` | `.mesh` | `.model` |
|---|---|---|---|
| Change size or position of objects, windows, doors | yes | | |
| Boolean operations | yes | | |
| Section positions and labels | yes | yes | yes |
| Polygonal walls | | yes | yes |
| Windows, doors and openings cut out of wall geometry | | yes | yes |
| Recessed areas of a sink or fireplace | | yes | yes |
| ModelProvider models | | | yes |

### 1.3 Code listings (short, as published)

RoomCaptureView scan and stop. Source: WWDC22 10127 code tab, 4:36, https://developer.apple.com/videos/play/wwdc2022/10127/

```swift
class RoomCaptureViewController: UIViewController {
    var roomCaptureView: RoomCaptureView
    var captureSessionConfig: RoomCaptureSession.Configuration
    private func startSession() {
        roomCaptureView?.captureSession.run(configuration: captureSessionConfig)
    }
    private func stopSession() {
        roomCaptureView?.captureSession.stop()
    }
}
```

View delegate and export. Source: WWDC22 10127 code tab, 5:00.

```swift
func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    // Optionally opt out of post processed scan results.
    return false
}
func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    // Handle final, post processed results and optional error.
    try processedResult.export(to: destinationURL)
}
```

Headless data API with RoomBuilder. Source: WWDC22 10127 code tab, 6:50, 7:40, 9:12, 9:30 (condensed).

```swift
lazy var captureSession: RoomCaptureSession = {
    let captureSession = RoomCaptureSession()
    arView.session = captureSession.arSession
    return captureSession
}()
var roomBuilder = RoomBuilder(options: [.beautifyObjects])

func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
    if let error = error { print("Error: \(error)") }
    Task {
        let finalRoom = try! await roomBuilder.capturedRoom(from: data)
        previewVisualizer.update(model: finalRoom)
    }
}
```

Continuous ARSession across rooms. Source: WWDC23 10192 code tab, 5:50, https://developer.apple.com/videos/play/wwdc2023/10192/

```swift
roomCaptureSession.run(configuration: captureSessionConfig)   // start 1st scan
roomCaptureSession.stop(pauseARSession: false)                 // stop 1st scan, keep ARSession
roomCaptureSession.run(configuration: captureSessionConfig)   // start 2nd scan
roomCaptureSession.stop()                                      // stop 2nd scan (pauses by default)
```

RoomCaptureView on an existing session, and stopping it for the next room. Source: https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure

```swift
var roomCaptureView = RoomCaptureView(frame: myFrame, arSession: existingARSession)
roomCaptureView.captureSession.stop(pauseARSession: false)
func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { return true }
var roomCaptureSession = RoomCaptureSession(arSession: relocalizedARSession)
```

Merge and export. Source: WWDC23 10192 code tab, 9:40 (argument label corrected, see Gotchas).

```swift
let structureBuilder = StructureBuilder(options: [.beautifyObjects])
let capturedStructure = try await structureBuilder.capturedStructure(from: capturedRoomArray)
try capturedStructure.export(to: destinationURL)
```

### 1.4 Multi-room flow (article "Scanning the rooms of a single structure")

1. One `RoomCaptureSession` (with RoomCaptureView: the view's `captureSession`) for the whole structure; pass an existing `ARSession` with `RoomCaptureView(frame:arSession:)` if the app runs its own AR.
2. Per room: `run(configuration:)`, show guidance (the view does this itself), then on "Finish Room" call `stop(pauseARSession: false)`.
3. Each stop calls `captureSession(_:didEndWith:error:)`. Build a `CapturedRoom` with `RoomBuilder(options: [.beautifyObjects])` and append it to an array.
4. For the next room call `run(configuration:)` again on the same session object.
5. If the app went to the background or tracking failed, relocalize: implement `sessionShouldAttemptRelocalization(_:)` returning `true`, watch `session(_:cameraDidChangeTrackingState:)` for `.limited(.relocalizing)`, ask the person to return to the most recently scanned room, and continue when tracking is `.normal`. After relaunch, load the saved `ARWorldMap` into `ARWorldTrackingConfiguration.initialWorldMap` and create a new `RoomCaptureSession(arSession:)` on the relocalized session.
6. On "Finish Structure": `StructureBuilder(options:)` then `capturedStructure(from:)`, which "succeeds when all of the captured rooms share compatible world space; otherwise, the function fails with an error".

### 1.5 Gotchas stated by Apple, plus snippet errors

Stated by Apple:
1. `RoomCaptureView(frame:arSession:)`: the session must already be running an `ARWorldTrackingConfiguration` when the view is created.
2. `RoomCaptureViewDelegate` inherits `NSCoding`. A plain `NSObject` delegate must implement `encode(with:)` and `init?(coder:)` (a `UIViewController` already conforms).
3. `stop(pauseARSession:)` defaults to `true`. Pass `false` explicitly to keep the session for the next room, the quality sheet, or a patch pass.
4. `RoomCaptureSession.arSession` is set at init; setting it throws.
5. `captureView(shouldPresent:error:)` defaults to `true`, which shows Apple's own result preview. Return `false` when Mapper shows its own result.
6. Export file names: before iOS 17.4 the first letter of the USD file name must not be a digit. Irrelevant at 18.0, but name files with a letter first anyway.
7. Best practices (WWDC22): single room up to about 30 x 30 ft (9 x 9 m); at least 50 lux; full-height mirrors, glass, very high ceilings and very dark surfaces are hard; open curtains, close doors; avoid scans over 5 minutes (battery and thermal).
8. Multi-room works best for single-floor homes with 1 to 4 bedrooms plus living, kitchen and dining, up to 2,000 sq ft (about 186 m2), with 50 lux or more (WWDC23).
9. The `capturedStructure(from:)` page says to "pause the ARSession by calling stop(pauseARSession:) with an argument of false". The wording is contradictory; the meaning is: keep it running by passing `false`.
10. RoomCaptureView speaks scanning guidance with VoiceOver (iOS 17, WWDC23). Mapper's own banner must not fight it for the same announcements.

Apple snippets that do not compile or mislead as written:
1. WWDC22 7:40 uses `didProvide instruction: Instruction`. Outside the type, write `RoomCaptureSession.Instruction`. A near-miss signature compiles as an unrelated method and the default empty implementation runs instead (RESEARCH.md 3.2 gotcha 2).
2. WWDC22 9:30 uses `try! await`. Mapper forbids `try!`; use `do`/`catch` and report `RoomBuilder.BuildError`.
3. The WWDC22 transcript calls the builder method `roomModel(from:)`. The real method is `capturedRoom(from:)`.
4. WWDC23 9:40 writes `StructureBuilder(option: ...)`. The label is `options:`.
5. WWDC23 7:30 contains `roomCaptureSession.init()`, which is not meaningful code. The documented relocalization path is: run a new `ARWorldTrackingConfiguration` with `initialWorldMap` on an `ARSession`, wait for `.normal`, then `RoomCaptureSession(arSession:)`.
6. The multi-room article's `didEndWith` listing is missing a `)`, uses `try? await ... else { return }` (not valid Swift) and awaits inside a synchronous delegate method. Wrap the work in a `Task`. Its merge listing omits `try await`.
7. The article's tracking listing force-unwraps `session.currentFrame!`. Pass `camera.trackingState` instead.
8. The WWDC22 headless listing assigns `arView.session = captureSession.arSession`. For Mapper the hub creates the session and hands it to RoomPlan, not the other way round.

### 1.6 Which Mapper module uses which part

- **RoomCapture (M15)**: steps 1 to 9 of 1.1 using the RoomCaptureView path with an app-owned session (section 4 recipe); `captureView(shouldPresent:error:)` returns `false`; RoomBuilder in `didEndWith`; per-room persistence; the multi-room loop of 1.4 (build 5 House mode reuses the same view and session).
- **CaptureCore (M10)**: creates and runs the session before the view exists; relocalization handling from 1.4 step 5.
- **GuidanceUI**: `captureSession(_:didProvide:)` feeds the "RoomPlan is coaching" state that suppresses Mapper's tier 2 and 3 banner (design record D15).
- **ExportUI (M37)**: `export(to:metadataURL:modelProvider:exportOptions:)` with the options table; `[.mesh]` by default, `.parametric` for CAD users (RESEARCH.md 3.2 step 9); JSON of `CapturedRoom` next to it; `CapturedStructure` export for houses.
- **Structure and HouseUI (build 5)**: `StructureBuilder` merge with the error handling in RESEARCH.md 3.2 step 6.
- Not reused: Apple's built-in result preview (`shouldPresent` returning `true`), the WWDC23 ModelProvider catalog (it needs furniture model assets that Mapper does not have; revisit later with properly licensed models).

---

## 2. Object Capture sample: "Scanning objects using Object Capture"

Pages used:
- Sample page: https://developer.apple.com/documentation/realitykit/scanning-objects-using-object-capture (iOS 18.0, Xcode 16.0; needs LiDAR and an A14 or later; does not compile for the Simulator; associated with WWDC24 10107 and WWDC23 10191). The page itself has only an overview.
- Symbol pages under https://developer.apple.com/documentation/realitykit/: `objectcapturesession` and all its members (`init()`, `issupported`, `start(imagesdirectory:configuration:)`, `startdetecting()`, `resetdetection()`, `startcapturing()`, `finish()`, `cancel()`, `pause()`, `resume()`, `beginnewscanpass()`, `beginnewscanpassafterflip()`, `requestimagecapture()`, `state`, `stateupdates`, `feedback-swift.property`, `feedbackupdates`, `cameratracking`, `usercompletedscanpass`, `numberofshotstaken`, `maximumnumberofinputimages`, `isautocaptureenabled`, `shouldplayhaptics`, `capturestate`, `feedback-swift.enum`, `tracking`, `error`, `configuration-swift.struct`, `updates`), `objectcaptureview` (`init(session:)`, `init(session:camerafeedoverlay:)`, `hideobjectreticle(_:)`), `objectcapturepointcloudview` (`init(session:)`, `showshotlocations(_:)`), `photogrammetrysession` (`init(input:configuration:)`, `issupported`, `process(requests:)`, `outputs-swift.property`, `cancel()`, `request`, `request/detail`, `output`, `result`, `error`, `configuration-swift.struct`, `configuration-swift.struct/checkpointdirectory`, `limits-swift.struct`).
- WWDC23 10191 "Meet Object Capture for iOS": https://developer.apple.com/videos/play/wwdc2023/10191/ (transcript and code tab read).
- WWDC24 10107 "Discover area mode for Object Capture": https://developer.apple.com/videos/play/wwdc2024/10107/ (transcript and code tab read).

### 2.1 The flow, in order (GuidedCapture)

State machine: `.initializing -> .ready -> .detecting -> .capturing -> .finishing -> .completed`, or `.failed(Error)` from anywhere.

1. Gate: `ObjectCaptureSession.isSupported` ("If false, attempting to create an ObjectCaptureSession will result in a runtime error") and `PhotogrammetrySession.isSupported`.
2. Create `ObjectCaptureSession()` and keep it in a long-lived model object (WWDC23: "store the session inside a ground truth data model as persistent state until it is completed").
3. `start(imagesDirectory:configuration:)` with an empty, writable images folder and a `Configuration` whose `checkpointDirectory` points at another empty folder. Valid once per session. State becomes `.ready`.
4. Show `ObjectCaptureView(session:)` (or `init(session:cameraFeedOverlay:)` for an overlay under the point cloud). The view renders whatever the current state needs and has no text or buttons of its own; the app stacks its own controls in a `ZStack`.
5. `.ready`: the view shows a reticle. The app's Continue button calls `startDetecting()` (returns `false` and stays `.ready` when no horizontal plane is under the screen-centre ray). State becomes `.detecting`.
6. `.detecting`: the view shows an adjustable bounding box. A reset button can call `resetDetection()` (back to `.ready`). The Start Capture button calls `startCapturing()`. State becomes `.capturing`.
7. `.capturing`: auto-capture runs while the user circles the object; the view draws the point cloud and the capture dial. Observe `feedback` for problems and `cameraTracking` for ARKit tracking. `requestImageCapture()` takes a manual shot when `canRequestImageCapture` is true.
8. When the dial is full, `userCompletedScanPass` becomes `true`. The app offers: another pass at a different height (`beginNewScanPass()`, stays `.capturing`, same box), a flip (`beginNewScanPassAfterFlip()`, back to `.ready` for a new box), a review in `ObjectCapturePointCloudView(session:)` (pauses capture), or Finish. Apple recommends three passes.
9. Finish: `finish()` (ignored unless `.capturing`), state `.finishing`, then `.completed`. Tear the capture session down.
10. Reconstruct on device: `PhotogrammetrySession(input: imagesFolder, configuration:)` with the same checkpoint folder, `process(requests: [.modelFile(url: modelURL)])`, then iterate `outputs` until `.processingComplete`. Only `.reduced` detail exists on iOS (diffuse, ambient occlusion and normal maps, under 50k triangles).

Area mode (WWDC24, iOS 18): there is no new call or configuration. Skip `startDetecting()` and call `startCapturing()` directly from `.ready`; hide the reticle with `.hideObjectReticle()`. The reticle then works as a brush. Reconstruction settings for area captures are in RESEARCH.md 3.3 (`isObjectMaskingEnabled = false`, `ignoreBoundingBox = true`).

### 2.2 Exact declarations

```swift
import RealityKit
import SwiftUI

@MainActor class ObjectCaptureSession                          // iOS 17.0; Identifiable, Observable, Sendable
@MainActor init()
@MainActor static var isSupported: Bool { get }
@MainActor func start(imagesDirectory: URL, configuration: ObjectCaptureSession.Configuration = Configuration())
@MainActor func startDetecting() -> Bool
@discardableResult @MainActor func resetDetection() -> Bool
@MainActor func startCapturing()
@MainActor func finish()
@MainActor func cancel()
@MainActor func pause()
@MainActor func resume()
@MainActor func beginNewScanPass()
@MainActor func beginNewScanPassAfterFlip()
@MainActor func requestImageCapture()
@MainActor var state: ObjectCaptureSession.CaptureState { get }
@MainActor var stateUpdates: ObjectCaptureSession.Updates<ObjectCaptureSession.CaptureState> { get }
@MainActor var feedback: Set<ObjectCaptureSession.Feedback> { get }
@MainActor var feedbackUpdates: ObjectCaptureSession.Updates<Set<ObjectCaptureSession.Feedback>> { get }
@MainActor var cameraTracking: ObjectCaptureSession.Tracking { get }
@MainActor var cameraTrackingUpdates: ObjectCaptureSession.Updates<ObjectCaptureSession.Tracking> { get }
@MainActor var userCompletedScanPass: Bool { get }
@MainActor var userCompletedScanPassUpdates: ObjectCaptureSession.Updates<Bool> { get }
@MainActor var isPaused: Bool { get }
@MainActor var canRequestImageCapture: Bool { get }
@MainActor var numberOfShotsTaken: Int { get }
@MainActor var maximumNumberOfInputImages: Int { get }
@MainActor var isAutoCaptureEnabled: Bool { get set }          // iOS 18.0
@MainActor var shouldPlayHaptics: Bool { get set }              // iOS 18.0
struct ObjectCaptureSession.Updates<Element> where Element : Sendable   // AsyncSequence, Sendable

struct ObjectCaptureSession.Configuration { init(); var checkpointDirectory: URL?; var isOverCaptureEnabled: Bool }
enum ObjectCaptureSession.CaptureState { case initializing, ready, detecting, capturing, finishing, completed; case failed(any Error) }
enum ObjectCaptureSession.Feedback {   // iOS 17.0 unless noted
    case environmentLowLight, environmentTooDark, movingTooFast, objectNotDetected /* 17.4 */,
         objectNotFlippable, objectTooClose, objectTooFar, outOfFieldOfView, overCapturing }
enum ObjectCaptureSession.Tracking { case normal; case notAvailable; case limited(reason: ObjectCaptureSession.Tracking.Reason) }
enum ObjectCaptureSession.Error { case cancelled; case directoryNotEmpty(URL); case insufficientStorage(requiredBytes: Int64); case sensorFailed; case trackingFailed }

@MainActor @preconcurrency struct ObjectCaptureView<Overlay> where Overlay : View              // iOS 17.0
nonisolated init(session: ObjectCaptureSession) where Overlay == EmptyView
nonisolated init(session: ObjectCaptureSession, @ViewBuilder cameraFeedOverlay: () -> Overlay)
@MainActor @preconcurrency func hideObjectReticle(_ value: Bool = true) -> ObjectCaptureView<Overlay>   // iOS 18.0
@MainActor struct ObjectCapturePointCloudView                                                   // iOS 17.0
@MainActor init(session: ObjectCaptureSession)
@MainActor func showShotLocations(_ value: Bool = true) -> ObjectCapturePointCloudView        // iOS 18.0

class PhotogrammetrySession                                                  // iOS 17.0
static var isSupported: Bool { get }
convenience init(input: URL, configuration: PhotogrammetrySession.Configuration = Configuration()) throws
convenience init<S>(input: S, configuration: PhotogrammetrySession.Configuration = Configuration()) throws
    where S : Sequence, S.Element == PhotogrammetrySample
func process(requests: [PhotogrammetrySession.Request]) throws
var outputs: PhotogrammetrySession.Outputs { get }                          // AsyncSequence
func cancel()
// Request: case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced,
//                         geometry: PhotogrammetrySession.Request.Geometry? = nil), plus bounds, pointCloud, poses, modelEntity
// Output: inputComplete, requestProgress(_, fractionComplete:), requestProgressInfo(_, _), requestComplete(_, _),
//         requestError(_, _), processingComplete, processingCancelled, invalidSample(id:reason:), skippedSample(id:),
//         automaticDownsampling, stitchingIncomplete
```

The full `PhotogrammetrySession.Configuration`, `Result`, `Limits`, `ProgressInfo` and `PhotogrammetrySample` declarations are in `docs/RESEARCH.md` section 3.3.

### 2.3 Code listings (short, as published)

All from the WWDC23 10191 code tab, https://developer.apple.com/videos/play/wwdc2023/10191/ (10:03 to 15:50), condensed.

```swift
var session = ObjectCaptureSession()

var configuration = ObjectCaptureSession.Configuration()
configuration.checkpointDirectory = getDocumentsDir().appendingPathComponent("Snapshots/")
session.start(imagesDirectory: getDocumentsDir().appendingPathComponent("Images/"),
              configuration: configuration)
```

```swift
var body: some View {
    if session.userCompletedScanPass {
        VStack {
            ObjectCapturePointCloudView(session: session)
            CreateButton(label: "Finish") { session.finish() }
        }
    } else {
        ZStack {
            ObjectCaptureView(session: session)
            if case .ready = session.state {
                CreateButton(label: "Continue") { session.startDetecting() }
            } else if case .detecting = session.state {
                CreateButton(label: "Start Capture") { session.startCapturing() }
            }
        }
    }
}
```

```swift
var configuration = PhotogrammetrySession.Configuration()
configuration.checkpointDirectory = getDocumentsDir().appendingPathComponent("Snapshots/")
let session = try PhotogrammetrySession(
    input: getDocumentsDir().appendingPathComponent("Images/"),
    configuration: configuration)
try session.process(requests: [
    .modelFile(url: getDocumentsDir().appendingPathComponent("model.usdz"))
])
for try await output in session.outputs {
    switch output {
    case .processingComplete:
        handleComplete()
        // Handle other Output messages here.
    }
}
```

Area mode. Source: WWDC24 10107 transcript, https://developer.apple.com/videos/play/wwdc2024/10107/ ("Simply skip the call to startDetecting and proceed directly to startCapturing"; "add the new hideObjectReticle modifier"). Pattern:

```swift
ObjectCaptureView(session: session).hideObjectReticle()
// Start button in .ready calls session.startCapturing() directly.
```

Lazy custom samples (masks). Source: WWDC24 10107 code tab, 8:19 and 9:15.

```swift
let inputSequence = images.lazy.compactMap { file in loadSampleAndMask(file: file) }
return PhotogrammetrySession(input: inputSequence)
```

### 2.4 Gotchas stated by Apple, plus snippet errors

Stated by Apple:
1. Check `isSupported` before `init()`; a failed check means a runtime error on creation.
2. `start(imagesDirectory:configuration:)` is valid only once on a new session; the images folder (and the checkpoint folder if it exists) must be empty; otherwise the session goes to `.failed`.
3. `.failed` is terminal: create a new session. `cancel()` "eventually transitions the session to .failed(Error)"; the error is `.cancelled`.
4. `finish()` is ignored unless the state is `.capturing`.
5. `startDetecting()` returns `false` outside `.ready` or when no horizontal plane is found under the screen centre. Tell the user.
6. `beginNewScanPass()` and `beginNewScanPassAfterFlip()` are only valid in object-centric scanning (not area mode). The doc says `beginNewScanPass()` "will throw" outside `.capturing`, but the declaration is not `throws`: guard on state.
7. When `cameraTracking` is not `.normal`, ARKit's coaching overlay appears automatically; hide Mapper's own overlay so it stays visible.
8. Call `pause()` when the capture view is not visible (help screens, sheets) and `resume()` when it first appears or comes back. Re-creating an `ObjectCaptureView` from the same session resumes the capture.
9. `maximumNumberOfInputImages` is the on-device reconstruction limit; capture stops there unless `isOverCaptureEnabled` (meant for Mac reconstruction; Mapper has no Mac path, so leave it off).
10. Only `.reduced` detail on iOS. Never reference `.preview`, `.medium`, `.full`, `.raw` or `.custom` in iOS code.
11. `checkpointDirectory`: pass the same folder the capture session used to speed up reconstruction and to resume an interrupted one; each checkpoint folder must be unique to its images folder.
12. `process(requests:)` throws while another batch is processing; all input is ingested and `.inputComplete` arrives before any progress.
13. `PhotogrammetrySession(input: URL)` throws if the URL is not a file URL.
14. Object choice (WWDC23): avoid reflective, transparent and very thin objects; flip only rigid, textured objects without symmetric or repeating texture; otherwise capture three heights; place textureless objects on a textured background; use diffuse light; move slowly.
15. Area mode (WWDC24): areas larger than about 6 ft may lose mesh and texture quality at the iOS detail level; capture in rows at several heights with overlap.
16. Supported devices (WWDC24): iPhone 12 Pro, iPad Pro 2021 and later. The sample page adds LiDAR and iOS 18.

Apple snippets that do not compile as written:
1. WWDC23 15:50: the `switch output` has only `.processingComplete`; `Output` needs a `default` (and Mapper's rule adds `@unknown default`). `outputs` never finishes by itself; stop iterating after `.processingComplete` or `.processingCancelled`.
2. WWDC23 18:40 (pose output): `.poses .modelFile(url:)` is missing a comma, and `case .poses(let poses)` is not an `Output` case. Poses arrive as `.requestComplete(_, .poses(let poses))`.
3. WWDC24 9:15 calls `PhotogrammetrySession(input:)` without `try`; the initializer throws.
4. WWDC23 listings call `session.startDetecting()` and ignore the `Bool` result; handle it.

Details of Apple's sample source that the research pass recorded (RESEARCH.md 3.3, not re-verified here because the zip is blocked): a folder manager creates per-scan `Images/`, `Checkpoint/` and `Models/`; the model observes the `...Updates` sequences with `for await`; the overlay is shown only when `cameraTracking == .normal && !isPaused`; `ObjectCaptureView` gets `.id(session.id)`; the capture session is set to nil before reconstruction "to free GPU and memory resources"; outputs are wrapped in a filter that stops after completion; fewer than 10 images are refused; results are shown with `QLPreviewController`.

### 2.5 Which Mapper module uses which part

- **ObjectCapture (M16, build 5 per design record D25)**: the whole 2.1 flow. A `@MainActor final class ObjectScanModel: ObservableObject` (design rule D26: no `@Observable` macro) owns `ObjectCaptureSession?` and mirrors `stateUpdates`, `feedbackUpdates`, `cameraTrackingUpdates` and `userCompletedScanPassUpdates` into `@Published` values with `for await` Tasks. `ObjectScanScreen` is a `ZStack` of `ObjectCaptureView(session:)` and Mapper's buttons (text from `Copy.swift`). `PhotogrammetryJob` runs the reconstruction after the capture session is released. The object size chooser (D4) sends only small and medium objects here.
- **GuidanceUI**: maps each `Feedback` case and `Tracking.Reason` to a Copy string.
- **Viewer3D (M31)**: loads `Models/model.usdz` (RESEARCH.md 3.3 step 10).
- **ExportUI (M37)**: offers the USDZ as produced; OBJ through a second `.modelFile` request with a pre-created directory URL, or the ModelIO fallback (RESEARCH.md 3.3 step 8).
- **CaptureCore (M10)**: not involved. `ObjectCaptureSession` runs its own camera and ARKit session and exposes no `ARSession`. Pause the hub's session before starting an object capture (expected to be required because both use the camera; confirm on device).
- Not reused: Mac over-capture, pose and point cloud requests (diagnostic only), `.modelEntity` (memory).

---

## 3. ARKit sample: "Visualizing and interacting with a reconstructed scene"

Pages used:
- Sample page: https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene (iOS 13.4, Xcode 16.0). This article contains the full walkthrough with code listings.
- Symbol pages under https://developer.apple.com/documentation/: `arkit/armeshanchor`, `arkit/armeshgeometry` (`vertices`, `normals`, `faces`, `classification`), `arkit/armeshclassification`, `arkit/argeometrysource`, `arkit/argeometryelement`, `arkit/arsession` (`delegate`, `delegatequeue`, `configuration`, `run(_:options:)`), `arkit/arsessiondelegate` (all methods), `arkit/arsessionobserver/sessionshouldattemptrelocalization(_:)`, `arkit/arworldtrackingconfiguration/scenereconstruction`, `arkit/arworldtrackingconfiguration/supportsscenereconstruction(_:)`, `arkit/arconfiguration/supportsframesemantics(_:)`, `arkit/arconfiguration/framesemantics-swift.struct/scenedepth`, `realitykit/arview/session`, `realitykit/arview/automaticallyconfiguresession`, `realitykit/arview/init(frame:cameramode:automaticallyconfiguresession:)`, `realitykit/arview/raycast(from:allowing:alignment:)`, `realitykit/arview/debugoptions-swift.struct/showsceneunderstanding`, `realitykit/arview/environment-swift.struct/sceneunderstanding-swift.struct/options-swift.struct`.
- WWDC20 10611 "Explore ARKit 4" (scene depth API): https://developer.apple.com/videos/play/wwdc2020/10611/ (transcript and code tab read).

### 3.1 The flow, in order

1. Take control of the session: `arView.automaticallyConfigureSession = false`.
2. Configure: `ARWorldTrackingConfiguration()` with `sceneReconstruction = .meshWithClassification` (check `ARWorldTrackingConfiguration.supportsSceneReconstruction(_:)` first). With automatic configuration RealityKit disables classification, which is why the sample turns it off.
3. Optional debug wireframe: `arView.debugOptions.insert(.showSceneUnderstanding)` ("Display the depth-colored wireframe for scene-understanding meshes"). Apple: normally only for debugging.
4. Run: `arView.session.run(configuration)` in `viewDidLoad`.
5. Optional plane detection: toggling `planeDetection` between `[]` and `[.horizontal, .vertical]` and re-running flattens the mesh where planes are found.
6. Tap to locate: `arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .any)` returns results nearest first; `.estimatedPlane` with `.any` is required to hit meshed, non-planar surfaces.
7. Tap to classify: search the mesh anchors (off the main thread) for a face whose centre is within 5 cm of the hit point, read that face's classification, show a label.
8. Label placement: offset the label 10 cm back toward the camera along the ray so the mesh does not occlude it; scale it by the camera distance so it keeps a constant screen size; orient it to face the camera.
9. Optional: `arView.environment.sceneUnderstanding.options.insert(.occlusion)` and `.physics`.

Scene depth (WWDC20 10611): add `.sceneDepth` to `frameSemantics` after `supportsFrameSemantics(.sceneDepth)`; read `frame.sceneDepth` (an `ARDepthData` with `depthMap` in meters and `confidenceMap`) in `session(_:didUpdate:)`; depth arrives with every ARFrame (60 Hz on the default format) and is smaller than the color image with the same aspect ratio.

### 3.2 Exact declarations

```swift
// ARKit
class ARMeshAnchor                                             // iOS 13.4 (ARAnchor subclass); var geometry: ARMeshGeometry
class ARMeshGeometry                                           // iOS 13.4
var vertices: ARGeometrySource { get }
var normals: ARGeometrySource { get }
var faces: ARGeometryElement { get }
var classification: ARGeometrySource? { get }
enum ARMeshClassification                                      // iOS 13.4; raw values in RESEARCH.md 3.1
var sceneReconstruction: ARConfiguration.SceneReconstruction { get set }                          // ARWorldTrackingConfiguration, 13.4
class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool   // 13.4
class func supportsFrameSemantics(_ frameSemantics: ARConfiguration.FrameSemantics) -> Bool       // 13.0; call on the subclass
static var sceneDepth: ARConfiguration.FrameSemantics { get }                                     // 14.0
weak var delegate: (any ARSessionDelegate)? { get set }                                           // ARSession, 11.0
var delegateQueue: dispatch_queue_t? { get set }                                                  // ARSession, 11.0; nil means main
@NSCopying var configuration: ARConfiguration? { get }                                            // ARSession, 11.0
func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = [])                    // ARSession, 11.0
protocol ARSessionDelegate : ARSessionObserver
optional func session(_ session: ARSession, didUpdate frame: ARFrame)
optional func session(_ session: ARSession, didAdd anchors: [ARAnchor])
optional func session(_ session: ARSession, didUpdate anchors: [ARAnchor])
optional func session(_ session: ARSession, didRemove anchors: [ARAnchor])
optional func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool                    // ARSessionObserver, 11.3

// RealityKit ARView
@MainActor @preconcurrency init(frame frameRect: CGRect, cameraMode: ARView.CameraMode, automaticallyConfigureSession: Bool)
@MainActor @preconcurrency dynamic var session: ARSession { get set }      // setting it replaces the default session; you must run it
@MainActor @preconcurrency var automaticallyConfigureSession: Bool { get set }   // default true
static let showSceneUnderstanding: ARView.DebugOptions                     // 13.4
@MainActor @preconcurrency func raycast(from point: CGPoint, allowing target: ARRaycastQuery.Target,
                                        alignment: ARRaycastQuery.TargetAlignment) -> [ARRaycastResult]   // view points, nearest first
```

### 3.3 Code listings (short, as published)

Configuration and debug wireframe. Source: https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene

```swift
arView.automaticallyConfigureSession = false
let configuration = ARWorldTrackingConfiguration()
configuration.sceneReconstruction = .meshWithClassification
arView.debugOptions.insert(.showSceneUnderstanding)
arView.session.run(configuration)
```

Tap raycast. Same source.

```swift
if let result = arView.raycast(from: tapLocation, allowing: .estimatedPlane, alignment: .any).first {
    // ...
```

Label offset and scale. Same source.

```swift
let rayDirection = normalize(result.worldTransform.position - self.arView.cameraTransform.translation)
let textPositionInWorldCoordinates = result.worldTransform.position - (rayDirection * 0.1)
let raycastDistance = distance(result.worldTransform.position, self.arView.cameraTransform.translation)
textEntity.scale = .one * raycastDistance
```

Per-face classification. Source: https://developer.apple.com/documentation/arkit/armeshgeometry/classification

```swift
extension ARMeshGeometry {
    func classificationOf(faceWithIndex index: Int) -> ARMeshClassification {
        guard let classification = classification else { return .none }
        let classificationAddress = classification.buffer.contents().advanced(by: index)
        let classificationValue = Int(classificationAddress.assumingMemoryBound(to: UInt8.self).pointee)
        return ARMeshClassification(rawValue: classificationValue) ?? .none
    }
}
```

Vertex by index. Source: https://developer.apple.com/documentation/arkit/armeshgeometry/vertices

```swift
let vertexPointer = vertices.buffer.contents().advanced(by: vertices.offset + (vertices.stride * Int(index)))
let vertex = vertexPointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
```

Face indices. Source: https://developer.apple.com/documentation/arkit/armeshgeometry/faces

```swift
let vertexIndexAddress = facesPointer.advanced(by: (index * indicesPerFace + offset) * MemoryLayout<UInt32>.size)
vertexIndices.append(Int(vertexIndexAddress.assumingMemoryBound(to: UInt32.self).pointee))
```

Scene depth. Source: WWDC20 10611 code tab, 20:32, https://developer.apple.com/videos/play/wwdc2020/10611/

```swift
if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
    configuration.frameSemantics = .sceneDepth
}
session.run(configuration)
func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard let depthData = frame.sceneDepth else { return }
}
```

### 3.4 Gotchas stated by Apple, plus things not to copy

Stated by Apple:
1. `supportsFrameSemantics(_:)` must be called on the configuration subclass, never on `ARConfiguration` itself (doc warning).
2. Enabling plane detection flattens the mesh on detected planes; people occlusion semantics remove mesh around people (`sceneReconstruction` doc). Mapper keeps plane detection off for Room and House (design record D14).
3. `delegateQueue` nil means the main queue. Set a serial queue before running.
4. Replacing `ARView.session` means you must run it yourself; with `automaticallyConfigureSession` true, RealityKit reconfigures the session based on camera mode and anchors, and turns classification off.
5. Mesh anchors update continually; the doc says mesh changes are "not intended to reflect in real time".
6. Classification is one value per face; `0` (`.none`) means unclassified. `classification` is nil with `.mesh`.
7. The mesh-visualization debug option is meant for debugging only.

Do not copy from the sample:
1. `classificationOf(faceWithIndex:)` as published ignores the source's `offset` and `stride`. Mapper's copy must read `classification.offset + classification.stride * index` (RESEARCH.md 3.1 gotcha 2). The face listing assumes 4-byte indices; check `faces.bytesPerIndex == 4`.
2. `centerOf(faceWithIndex:)`, `vertex(at:)` (as a sample helper), `sphere(radius:color:)`, `model(for:)`, `addAnchor(_:removeAfter:)` and the `.position` and `.color` helpers are sample code, not SDK API. Write Mapper's own.
3. The sample reads ARKit-owned mesh buffers later on `DispatchQueue.global()`. Mapper copies the bytes inside the delegate callback on the hub queue (RESEARCH.md 3.1 gotcha 2) and searches its own copy.
4. The plane-detection toggle that re-runs the session, the physics demo (falling text) and occlusion are not needed for scanning.
5. The sample lets `ARView` own the session. Mapper's views are bound to the hub's session instead (`arView.session = hub.session`, `automaticallyConfigureSession = false`).

### 3.5 Which Mapper module uses which part

- **CaptureCore (M10)**: configuration from 3.1 steps 1 and 2 plus the WWDC20 depth listing (guarded by the support checks), delegate and serial `delegateQueue`, `sessionShouldAttemptRelocalization(_:)`.
- **MeshRecord (M11)**: the three buffer listings as the pattern for copying each `ARMeshAnchor` in the callback, honoring offset and stride, with per-face classification.
- **LiveMeshView (M18)**: `ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)`, then `arView.session = hub.session` (never let it run its own configuration), `debugOptions.insert(.showSceneUnderstanding)` as the build 4 wireframe (design record: replaced by `CoverageOverlay` in build 5), tap raycast for the patch pass arrow.
- **Viewer3D (M31)**: classification colors, "nearest classified face within 5 cm" as a fallback for tap-to-classify (the primary is CPU picking on `MeshBVH`), label offset toward the camera and distance scaling for measurement labels.
- **MeasureTool (M32) and LiveMeasure (M17)**: `ARView.raycast(from:allowing: .estimatedPlane, alignment: .any)` for quick live taps; snapping uses the cached mesh (RESEARCH.md 3.1 step 7).

---

## 4. RoomCaptureView on an app-owned ARSession (build 4 recipe)

Why this path: the lead brief's MVP shortcut and design record D15 put builds 3 to 5 Room mode on `RoomCaptureView` with coaching on, and layer Mapper's mesh capture, viewer, plan, measurements and exports on top. RESEARCH.md prefers a headless `RoomCaptureSession` because the live coverage overlay cannot be hosted inside RoomCaptureView, and names `RoomCaptureView(frame:arSession:)` as the fallback; D15 overrides that for builds 3 to 5, and RESEARCH.md's UX guidance for the view applies. Mapper's minimap and banner sit on top of the view as SwiftUI siblings.

Roles (names from the ship-first proposal and design record):
- `ARSessionHub` (CaptureCore): a plain `NSObject` that owns the one `ARSession`, is its only delegate, and fans out to MeshRecord, Keyframes, CoverageLive and TrackingMonitor on its serial queue.
- `RoomCaptureController` (RoomCapture): a plain `NSObject` that is both the `RoomCaptureSessionDelegate` and the `RoomCaptureViewDelegate`. Never `@MainActor` (D26); it hops to main with `DispatchQueue.main.async` carrying only value types.
- `RoomCaptureContainer` (RoomCapture): a `UIViewRepresentable` holding one `RoomCaptureView` for the whole visit (House mode reuses it for every room).

### 4.1 Steps

1. **Create the session.** `let session = ARSession()`, owned by the hub for the whole scan flow.
2. **Set the delegate first.** `session.delegate = hub` and `session.delegateQueue = hub.queue`, where `hub.queue` is a serial `DispatchQueue` (the `DispatchQueue(label:)` default is serial). Do this before any `run`. Both `ARSession.delegate` and `RoomCaptureSession.delegate` are weak: the scan screen's model keeps strong references to the hub and the controller.
3. **Run Mapper's configuration.** Build it once and keep it immutable:
   - `ARWorldTrackingConfiguration()`;
   - `sceneReconstruction = .meshWithClassification` if `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`, else `.mesh` if supported;
   - `frameSemantics.insert(.sceneDepth)` if `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`;
   - `planeDetection = []` (D14), `environmentTexturing = .none`, default video format.
   Then `session.run(configuration)` (empty options). RoomCaptureView's doc requires the session to be running a world-tracking configuration before the view is created.
4. **Create the view on the main actor.** `RoomCaptureView(frame: .zero, arSession: session)`. Keep `isModelEnabled` at its default unless the mini model collides with Mapper's minimap.
5. **Set both delegates.** `if let captureSession = view.captureSession { captureSession.delegate = controller }` (the property is an implicitly unwrapped optional; binding it avoids an implicit force unwrap) and `view.delegate = controller`.
6. **Start RoomPlan.** `captureSession.run(configuration: RoomCaptureSession.Configuration())` (coaching stays on, `isCoachingEnabled` defaults to `true`).
7. **`captureSession(_:didStartWith:)`.** Log the effective configuration (`session.configuration`: class name, `frameSemantics.contains(.sceneDepth)`, `sceneReconstruction`, `videoFormat.imageResolution` and `framesPerSecond`), log `Thread.isMainThread`, run the delegate identity check (4.3), then re-apply Mapper's configuration if it was replaced (4.2).
8. **During the scan.**
   - `captureSession(_:didUpdate:)`: full live snapshot; update wall, door, window, opening and object counts for `LiveScanSnapshot` (at most 4 times a second to main).
   - `captureSession(_:didAdd:)`: detection messages (`doorDetected` and so on) for GuidanceUI.
   - `captureSession(_:didProvide:)`: record the latest instruction and how long it lasted (`RoomCaptureLog.instructionSeconds`); while it is not `.normal`, GuidanceUI suppresses tiers 2 and 3 (D15).
   - Hub callbacks on `hub.queue`: `session(_:didUpdate:)` for keyframes, coverage and the depth watchdog; `session(_:didAdd:)`, `session(_:didUpdate:)` and `session(_:didRemove:)` with `[ARAnchor]` for mesh chunks (copy inside the callback; never retain an `ARFrame`).
9. **Done.** `captureSession.stop(pauseARSession: false)` so the session keeps running for the quality sheet and a possible patch pass (D19). Always pass `false` explicitly; the default pauses.
10. **`captureView(shouldPresent:error:)`.** Return `false`: Mapper shows its own result and runs `RoomBuilder` itself. Log the error if one is passed.
11. **`captureView(didPresent:error:)`.** Not expected after returning `false`. Implement it anyway: log that it was called, ignore the result.
12. **`captureSession(_:didEndWith:error:)`.** Fires after every stop. If `error` is not nil, map it (`RoomCaptureSession.CaptureError`: `deviceTooHot`, `exceedSceneSizeLimit`, `worldTrackingFailure`, `invalidARConfiguration`, and so on) to Copy strings and keep what was captured when possible. Then:
    1. JSON-encode the `CapturedRoomData` to the room's raw folder first (re-processable later);
    2. in a `Task`, `let builder = RoomBuilder(options: [.beautifyObjects])` and `try await builder.capturedRoom(from: data)` with `do`/`catch` (`RoomBuilder.BuildError`);
    3. JSON-encode the `CapturedRoom` (the final result, not the last `didUpdate`, is the truth);
    4. hand a Sendable summary to main.
    With RoomCaptureView both `didEndWith` and `shouldPresent` deliver the same raw data; process it once, in `didEndWith`, and do not depend on which arrives first.
13. **Finish.** Save the world map when `worldMappingStatus` is `.extending` or `.mapped` (the ARWorldMap does not store mesh anchors; Mapper persists its own mesh), then `session.pause()` when the user leaves the scan flow.
14. **Export (ExportUI, on user request).** `try room.export(to: usdzURL, metadataURL: metadataURL, modelProvider: nil, exportOptions: [.mesh])` (or `.parametric`), with file names that start with a letter and a `.plist` metadata URL (RESEARCH.md 3.2 step 9). `export` is synchronous, `throws`, and not main-actor isolated: run it off the main thread, write into a temporary folder, then move the files into place.
15. **Next room (House mode, build 5).** Same view, same session, same controller: `captureSession.run(configuration:)` again; step 7 repeats for every room.

### 4.2 The configuration being replaced (what RESEARCH.md says)

- RESEARCH.md (executive summary and 3.1 disputed item 1): "RoomPlan replaces the session configuration when it runs. In practice sceneDepth disappears." Final ruling for the bare `RoomCaptureSession`: share one session, re-apply Mapper's configuration with empty run options in `captureSession(_:didStartWith:)` after every room start, plus a sceneDepth watchdog. Evidence: Apple forum threads 763400 (symptom and accepted fix), 808834 and 710134. WWDC23 only says a custom ARSession "will be honored", which means RoomPlan uses your session object, not that it keeps your settings.
- The RoomCaptureView case is the exception in the docs: `RoomCaptureView.init(frame:arSession:)` says "RoomPlan preserves all of the AR session's settings". RESEARCH.md scopes that line to the view initializer, and thread 728601 reports different behavior for RoomCaptureView and a bare RoomCaptureSession. So on the build 4 path the configuration may well survive; the re-apply is a safety net.
- Never re-apply with `.resetTracking`, `.removeExistingAnchors` or `.resetSceneReconstruction`: the first two break the shared world frame, the last discards the mesh (one community repo does this; do not copy it).
- Only ever run `ARWorldTrackingConfiguration` on a session handed to RoomPlan (`CaptureError.invalidARConfiguration` otherwise).
- One community report says that with an injected session RoomPlan reports nothing unless the configuration enables `sceneReconstruction` (community only). Mapper enables it anyway.

Build 4 policy:
1. In `didStartWith`, compare `session.configuration` against Mapper's: it must be an `ARWorldTrackingConfiguration` whose `frameSemantics` contains `.sceneDepth` (when supported) and whose `sceneReconstruction` matches. If either is missing, call `session.run(mapperConfiguration, options: [])` and log a `config` capture event saying it was replaced. If both are present, log that it was preserved. Where RoomPlan calls `didStartWith` is undocumented; perform the `run` on the main queue, as Apple's samples do.
2. Watchdog on the hub queue: if `frame.sceneDepth == nil` for about 2 s while depth is supported, re-apply once and log; if still missing, set `DegradedMode.depthStripped`. If no `ARMeshAnchor` arrives after about 8 s of `.normal` tracking, re-apply once; if still none, set `.meshStripped` (the room then uses the same-session mesh pass fallback from the ship-first proposal 3.2).
3. Log once per second on the first device build: `frameSemantics` contains `.sceneDepth`, `frame.sceneDepth != nil`, mesh anchor count, RoomPlan `didUpdate` count, thermal state. This answers RESEARCH.md's open device questions in one run.

### 4.3 The delegate identity check

- RESEARCH.md 3.2 disputed item 1 and cross-section ruling: setting `arSession.delegate` yourself is allowed (tie-breaker ruling); Apple documents no internal RoomPlan delegate, and shipped code sets it and still gets all room callbacks. The one reported blackout came from overriding the delegate after `run()` with RoomCaptureView, which is why step 2 sets it before anything runs.
- Check: after `captureSession(_:didStartWith:)` (and once per second from the hub), log whether `session.delegate === hub`. `ARSessionDelegate` is class-bound, so the identity comparison compiles.
- Only if it is false: log it, keep a strong reference to the replacing delegate, and install a forwarding relay (`ARDelegateRelay` in the ship-first proposal) that forwards every callback to the previous delegate and then to the hub. This is not expected to trigger; do not build the relay before a device log shows the need.
- Binding an `ARView` to the same session (LiveMeshView) must not change the delegate either; run the same check after binding.

### 4.4 Skeleton (Mapper's own code, not Apple's)

A starting point for CaptureCore and RoomCapture agents. It follows the declarations above; compile it through CI before relying on it.

```swift
import ARKit
import RoomPlan

/// Owns the single ARSession of a capture visit and is its only delegate.
final class ARSessionHub: NSObject, ARSessionDelegate {
    /// The shared session handed to RoomPlan and every live view.
    let session = ARSession()
    /// Serial queue for every ARKit callback.
    let queue = DispatchQueue(label: "mapper.ar.delegate", qos: .userInitiated)
    /// Mapper's scan configuration, built once and never mutated.
    let configuration: ARWorldTrackingConfiguration = ARSessionHub.makeScanConfiguration()

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    /// Mesh with classification and scene depth when the device supports them.
    static func makeScanConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = []
        config.environmentTexturing = .none
        return config
    }

    /// Starts the session. Must run before RoomCaptureView(frame:arSession:) is created.
    func start() { session.run(configuration) }

    /// True when the running configuration still has Mapper's depth and mesh settings.
    func configurationIsIntact() -> Bool {
        guard let running = session.configuration as? ARWorldTrackingConfiguration else { return false }
        let depthOK = !configuration.frameSemantics.contains(.sceneDepth) || running.frameSemantics.contains(.sceneDepth)
        return depthOK && running.sceneReconstruction == configuration.sceneReconstruction
    }

    /// Re-runs Mapper's configuration without reset options (keeps tracking, anchors and mesh).
    func reapplyConfiguration() { session.run(configuration, options: []) }

    /// Whether RoomPlan (or a view) replaced the session delegate.
    var isDelegateIntact: Bool { session.delegate === self }

    func session(_ session: ARSession, didUpdate frame: ARFrame) { /* keyframes, coverage, depth watchdog */ }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { /* copy ARMeshAnchor bytes */ }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { /* copy ARMeshAnchor bytes */ }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { /* mark stale, do not delete */ }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}

/// RoomPlan session and view delegate. Plain NSObject, never @MainActor.
final class RoomCaptureController: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate {
    private let hub: ARSessionHub

    init(hub: ARSessionHub) {
        self.hub = hub
        super.init()
    }

    /// NSCoding stub required by RoomCaptureViewDelegate; this object is never archived.
    required init?(coder: NSCoder) { return nil }
    /// NSCoding stub required by RoomCaptureViewDelegate.
    func encode(with coder: NSCoder) {}

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        let hub = self.hub
        DispatchQueue.main.async {
            // log hub.session.configuration, Thread.isMainThread, hub.isDelegateIntact
            if !hub.configurationIsIntact() { hub.reapplyConfiguration() }
        }
    }
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) { /* counts to main */ }
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) { /* GuidanceUI */ }
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        // 1. encode `data` to the raw folder; 2. RoomBuilder in a Task with do/catch; 3. encode the CapturedRoom
    }
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool { false }
    func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) { /* log only */ }
}

/// Builds the one RoomCaptureView of a visit. The hub must already be running.
@MainActor
func makeRoomCaptureView(hub: ARSessionHub, controller: RoomCaptureController) -> RoomCaptureView {
    let view = RoomCaptureView(frame: .zero, arSession: hub.session)
    if let captureSession = view.captureSession {
        captureSession.delegate = controller
    }
    view.delegate = controller
    return view
}
```

Then, on the main actor: `hub.start()`, create the view, `view.captureSession?.run(configuration: RoomCaptureSession.Configuration())`; on Done, `view.captureSession?.stop(pauseARSession: false)`.

Compile risks to check in review: `ARConfiguration.SceneReconstruction` equality (it is an `OptionSet`, so `==` exists); `required init?(coder:)` returning `nil` in a class with a `let` property (allowed for failable initializers); `(any Error)?` in delegate signatures (valid in Swift 5.9); calling `RoomCaptureView` APIs only from `@MainActor` contexts.

### 4.5 First device run checklist for this recipe

Log, per room: `RoomCaptureSession.isSupported`; configuration before RoomPlan, after `didStartWith`, and after any re-apply; whether a re-apply happened; delegate identity; `sceneDepth` presence rate and mesh anchor count per second with RoomPlan running; `didUpdate` count; the thread of each RoomPlan callback; `didEndWith` error; RoomBuilder duration; whether RoomCaptureView still draws its outlines with Mapper's session delegate set (it should, per the multi-room article). These close RESEARCH.md section 6 "Still unresolved" items for the RoomCaptureView path.

---

## 5. Sources

Apple documentation (read through the documentation JSON on 2026-09-28):
- https://developer.apple.com/documentation/roomplan/create-a-3d-model-of-an-interior-room-by-guiding-the-user-through-an-ar-experience
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/documentation/roomplan/merging-multiple-scans-into-a-single-structure
- https://developer.apple.com/documentation/roomplan/roomcaptureview and members listed in section 1
- https://developer.apple.com/documentation/roomplan/roomcapturesession and members listed in section 1
- https://developer.apple.com/documentation/roomplan/roombuilder, https://developer.apple.com/documentation/roomplan/structurebuilder, https://developer.apple.com/documentation/roomplan/capturedroom
- https://developer.apple.com/documentation/realitykit/scanning-objects-using-object-capture
- https://developer.apple.com/documentation/realitykit/objectcapturesession, https://developer.apple.com/documentation/realitykit/objectcaptureview, https://developer.apple.com/documentation/realitykit/objectcapturepointcloudview, https://developer.apple.com/documentation/realitykit/photogrammetrysession and members listed in section 2
- https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene
- https://developer.apple.com/documentation/arkit/armeshgeometry and members, https://developer.apple.com/documentation/arkit/arsession and members, https://developer.apple.com/documentation/realitykit/arview and members listed in section 3

WWDC sessions (page transcript and code tab):
- https://developer.apple.com/videos/play/wwdc2022/10127/ Create parametric 3D room scans with RoomPlan
- https://developer.apple.com/videos/play/wwdc2023/10192/ Explore enhancements to RoomPlan
- https://developer.apple.com/videos/play/wwdc2023/10191/ Meet Object Capture for iOS
- https://developer.apple.com/videos/play/wwdc2024/10107/ Discover area mode for Object Capture
- https://developer.apple.com/videos/play/wwdc2020/10611/ Explore ARKit 4

Project documents: `docs/RESEARCH.md` (branch `origin/docs/research-md`, sections 1, 3.1, 3.2, 3.3), `docs/design/synthesis-decisions.md` and `docs/design/proposal-ship-first.md` (branch `origin/design/architecture`).
