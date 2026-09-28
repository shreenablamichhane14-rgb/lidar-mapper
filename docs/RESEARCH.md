# Mapper research reference

Work in progress. Partial synthesis; sections below have passed declaration and fidelity checks. Executive summary, risk register and remaining sections follow.

## Floor plan and CAD output

Scope: turn RoomPlan output (CapturedRoom, CapturedStructure) into an editable 2D architectural plan with units, dimensions and symbols, then export it as vector PDF, SVG and DXF. Covers single room, multi-room and multi-floor. Everything below works at iOS 17.0 or earlier, so it is usable at our iOS 18.0 target. Nothing here needs iOS 26 or `#available`.

### Verified API

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

### Gotchas

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

### Recommended approach

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

### Disputed or unsure

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

## 3D export formats

Scope: every file the app hands to the user (textured model, raw LiDAR mesh, clean architectural model, object model, 2D plan, CAD files), plus zipping, sharing, Files app visibility and on-device preview. The short version: RoomPlan and SceneKit are the only native USDZ writers on iOS. ModelIO is reliable for import and for OBJ/STL, nothing else. Everything else (OBJ+MTL, PLY, STL, GLB, SVG, DXF) is small enough to write ourselves in pure Foundation.

### Verified API

All declarations below were checked against Apple's documentation JSON (iOS 26 SDK doc set). "Usable at 18.0" means callable with no `#available` check at our iOS 18.0 deployment target. Nothing in this subsystem requires iOS 26, so no `#available(iOS 26, *)` gates are needed.

#### Native USDZ writers

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

#### ModelIO (import, and OBJ/STL export only)

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

#### RealityKit (no general mesh writer)

| Declaration | iOS | Notes |
|---|---|---|
| `@MainActor func write(to url: URL) async throws` (Entity) | 18.0 | Writes a `.reality` file only. Not USDZ, not OBJ. |
| `case modelFile(url: URL, detail: PhotogrammetrySession.Request.Detail = .reduced, geometry: PhotogrammetrySession.Request.Geometry? = nil)` | 17.0 | USDZ if URL ends in `.usdz`; doc says a directory URL gives OBJ plus textures |
| `static var isSupported: Bool { get }` (PhotogrammetrySession) | 17.0 | runtime gate |
| `@MainActor static var isSupported: Bool { get }` (ObjectCaptureSession) | 17.0 (doc lists iOS and iPadOS only) | runtime gate; if false, creating an `ObjectCaptureSession` is a runtime error. The LiDAR + A14 hardware requirement is not stated on this symbol's doc page (our A15 with LiDAR already reported supported on device) |

`PhotogrammetrySession.Request.Detail`: only `.reduced` exists on iOS (17.0+). `.preview`, `.medium`, `.full`, `.raw` are macOS 12 / Catalyst 15 only; `.custom` is macOS 14 / Catalyst 17 only. Referencing them in iOS code will not compile. The newer overloads are not usable at 18.0: `struct WriteOptions` is iOS 26.0+, and `func write(to url: URL, options: Entity.WriteOptions) async throws` and `static func write(_ entities: [Entity], to url: URL, options: Entity.WriteOptions = WriteOptions()) async throws` are iOS 27.0+ (both `nonisolated(nonsending)`). They still write `.reality` and are irrelevant.

#### 2D output (PDF, PNG)

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

#### Hand-written formats (Foundation only)

| Declaration | iOS | Use |
|---|---|---|
| `class func data(withJSONObject obj: Any, options opt: JSONSerialization.WritingOptions = []) throws -> Data` | 5.0 | GLB JSON chunk (pass `.withoutEscapingSlashes` (iOS 13.0), `.sortedKeys` (iOS 11.0)) |
| `mutating func append(_ other: Data)`, `mutating func append<SourceType>(_ buffer: UnsafeBufferPointer<SourceType>)`, `mutating func append(contentsOf elements: some Sequence<UInt8>)` (Data); `func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R` (Array) | 8.0 | binary buffers for GLB, PLY, STL |
| `func pngData() -> Data?`, `func jpegData(compressionQuality: CGFloat) -> Data?` (UIImage) | no iOS version in doc JSON (long-standing, not gated) | embedded textures |

Format facts (glTF 2.0 spec, verified): GLB header is 12 bytes: magic `0x46546C67`, version 2, total length, all uint32 little endian. Chunk 0 is JSON (type `0x4E4F534A`, padded with `0x20`). Chunk 1 is BIN (type `0x004E4942`, padded with `0x00`). Both 4-byte aligned. `buffers[0]` has no `uri`. componentType 5126 float, 5125 uint32, 5123 uint16, 5121 uint8 (`normalized: true` for COLOR_0). POSITION accessors must have `min` and `max`. Images in a bufferView must set `mimeType` (`image/png` or `image/jpeg`). glTF is right-handed, +Y up, same as ARKit and RoomPlan, so no axis swap. UV (0,0) is the top-left of the image.

Binary STL: 80-byte header, uint32 triangle count, then 50 bytes per triangle (normal 3 floats, 3 vertices 9 floats, uint16 attribute), little endian, no colours, no units. PLY: `format binary_little_endian 1.0`, `property float x/y/z`, `nx/ny/nz`, `property uchar red/green/blue`, `property list uchar uint vertex_indices`. OBJ: 1-based `v`, `vn`, `vt`, `f a/b/c`, plus `mtllib`/`usemtl`; MTL: `newmtl`, `Kd`, `map_Kd <relative path>`.

DXF: R12 (`$ACADVER AC1009`) needs only the ENTITIES section and no handles. Use LINE, CIRCLE, ARC, TEXT and POLYLINE + VERTEX + SEQEND; layer is group 8, colour group 62. LWPOLYLINE does not exist in R12. It needs R2000 (AC1015), which then requires HEADER, CLASSES, TABLES, BLOCKS, OBJECTS and unique handles on every record.

#### Zip, sharing, Files app, preview

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

### Gotchas

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

### Recommended approach

1. **Own the mesh writers.** A Foundation-only `Exporters` module that works on our own `Mesh` struct (positions, normals, UVs, colours, uint32 indices, optional texture `Data`): OBJ + MTL (with `map_Kd`), binary little-endian PLY with vertex colours, binary STL in millimetres, and GLB. Pure Swift with no UIKit dependency, so it can be unit-tested on the macOS CI runner.
2. **Architectural model (USDZ):** `CapturedRoom.export(to:metadataURL:modelProvider:exportOptions:)` with `[.parametric, .mesh]` for one room, and `CapturedStructure.export(...)` for a merged house. Name files like `Room-<date>.usdz`, never starting with a digit. Save `CapturedRoom` / `CapturedStructure` with `JSONEncoder` in the project folder so we can re-export later.
3. **Textured and raw-mesh USDZ:** one `SceneKitUSDZWriter` file. Build `SCNGeometry` from our `Mesh`, `SCNMaterial.diffuse.contents = UIImage`, write to a unique temp URL, check the Bool and size (reject files under a few KB), then move into `Exports/`. Evaluate `MDLUtility.convert(toUSDZ:writeTo:)` (iOS 18.0+, not deprecated) on device as a SceneKit-free alternative; switch if it works with our OBJ or usdc.
4. **Object model:** Object Capture writes `.usdz` at `.reduced`. Convert to OBJ, GLB, PLY or STL by `MDLAsset(url:)` + `childObjects(of: MDLMesh.self)` into our `Mesh`, then our own writers.
5. **ModelIO role:** import only (re-open USDZ from RoomPlan, Object Capture or our exports). Log `canExportFileExtension` results in the capability probe, but never depend on ModelIO for export.
6. **2D plan:** one `PlanRenderer.draw(in: CGContext, scale:)` shared by `UIGraphicsPDFRenderer` (vector PDF at 1:50 or 1:100 on A4 or Letter), `UIGraphicsImageRenderer` (PNG) and the on-screen SwiftUI `Canvas`. Separate string emitters for SVG (viewBox in mm) and DXF R12 (HEADER with `$ACADVER AC1009`, `$INSUNITS 4`, `$EXTMIN`/`$EXTMAX`; TABLES/LAYER; ENTITIES with LINE, POLYLINE + VERTEX + SEQEND, TEXT, CIRCLE, ARC). Only move to AC1015 if bulged LWPOLYLINEs are demanded.
7. **Packaging and sharing:** multi-file exports (OBJ + MTL + textures, full project bundle) are staged into `Documents/<project>/Exports/<Name>/` and zipped with `coordinate(readingItemAt:options: [.forUploading], ...)` on a background queue, moving the zip to `Exports/<Name>.zip` inside the block. Single files (USDZ, PDF, PNG, GLB) are shared as plain URLs with `ShareLink(item: url, preview: SharePreview(...))`. Use an `ExportPackage: Transferable` with `FileRepresentation(exportedContentType: .zip, ...)` if lazy export is wanted. Declare GLB and DXF in `UTExportedTypeDeclarations` or use `UTType(filenameExtension:)` with a nil check.
8. **Files app:** `UIFileSharingEnabled: true` and `LSSupportsOpeningDocumentsInPlace: true` are already under `info.properties` in `ios/project.yml`; keep them. Write a first file (for example a README or the projects index) at first launch so the folder appears.
9. **Preview:** `.quickLookPreview($previewURL)` for USDZ, PDF and PNG (presents the system viewer itself, AR mode included). If UIKit is needed, present `QLPreviewController` modally from the top view controller, never as an embedded representable. Our own RealityKit or SceneKit viewer for the other formats.
10. **First export CI build:** add a self-test that runs every writer on a synthetic textured cube, logs `canExportFileExtension` for obj, stl, ply, usdz, usdc, usda, abc, calls `SCNScene.write` twice, tries `MDLUtility.convert(toUSDZ:writeTo:)`, and zips a folder. Read the results through the log viewer so all open device questions close in one round trip.

### Disputed or unsure

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

## Scan quality, coverage and measurement confidence

This section covers the live quality signals Apple gives us, how to turn them into a coverage score and a "Scan quality" summary (SPEC: SCAN QUALITY SYSTEM), how to attach an honest accuracy figure to each measurement (SPEC: MEASUREMENT CONFIDENCE), snapping for manual points, and thermal and battery handling. Apple publishes no accuracy specification for LiDAR, RoomPlan or Measure. Every accuracy number below is from third-party studies or practitioners and must be calibrated on the test device.

### Verified API

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

### Gotchas

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

### Recommended approach

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

### Disputed or unsure

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

## Storage, deployment and concurrency

This section covers Info.plist keys, free Apple ID sideloading limits, the on-disk project layout and serialization, the memory budget, background processing, and the Swift language mode and concurrency settings. All declarations below were checked against Apple documentation JSON on 2026-09-28. "Usable at 18.0" means it compiles and runs with the iOS 18.0 deployment target without an availability check.

### Verified API

#### Info.plist keys and entitlements

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

#### Custom package document type

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

#### Runtime capability gates (all usable at 18.0)

```swift
static var isSupported: Bool { get }                    // RoomCaptureSession, iOS 16.0
class func supportsSceneReconstruction(_ sceneReconstruction: ARConfiguration.SceneReconstruction) -> Bool  // ARWorldTrackingConfiguration, iOS 13.4
@MainActor static var isSupported: Bool { get }         // ObjectCaptureSession, iOS 17.0
static var isSupported: Bool { get }                    // PhotogrammetrySession, iOS 17.0
```

#### Files, backup, protection, free space

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

#### Serialization building blocks

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

#### Memory and thermal

```swift
extern size_t os_proc_available_memory();                // import os, iOS 13.0; returns 0 when already over the limit
var physicalMemory: UInt64 { get }                       // ProcessInfo
var recommendedMaxWorkingSetSize: UInt64 { get }         // MTLDevice, iOS 16.0
nonisolated class let didReceiveMemoryWarningNotification: NSNotification.Name  // UIApplication
var thermalState: ProcessInfo.ThermalState { get }       // iOS 11.0; cases nominal, fair, serious, critical
class let thermalStateDidChangeNotification: NSNotification.Name  // ProcessInfo, iOS 11.0
var isIdleTimerDisabled: Bool { get set }                // UIApplication, iOS 2.0
```

#### Photogrammetry limits relevant to storage and memory

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

#### Background execution

| Declaration | Introduced | Usable at 18.0 |
|---|---|---|
| `nonisolated func beginBackgroundTask(withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil) -> UIBackgroundTaskIdentifier` | iOS 7.0 | Yes. About 30 s (Apple DTS forum figure, not documented). |
| `nonisolated var backgroundTimeRemaining: TimeInterval { get }` | iOS 4.0 | Yes. Do not build logic on it. |
| `class BGProcessingTask` / `class BGProcessingTaskRequest` (`requiresExternalPower`, `requiresNetworkConnectivity`) | iOS 13.0 | Yes, but idle-only. |
| `func register(forTaskWithIdentifier identifier: String, using queue: dispatch_queue_t?, launchHandler: @escaping (BGTask) -> Void) -> Bool` | iOS 13.0 | Yes. Register once, before launch finishes. |
| `class BGContinuedProcessingTaskRequest`, `init(identifier: String, title: String, subtitle: String)` | iOS 26.0 | No. Needs `#available(iOS 26, *)`. |
| `class BGContinuedProcessingTask` (ProgressReporting) | iOS 26.0 | No. Needs `#available(iOS 26, *)`. The system shows its progress in a Live Activity; the app only reports progress. |
| `class var supportedResources: BGContinuedProcessingTaskRequest.Resources { get }` (BGTaskScheduler) | iOS 26.0 | No. Needs `#available(iOS 26, *)`. |

#### Deprecations in the iOS 26 SDK

| Symbol | Status |
|---|---|
| SceneKit framework, `SCNView`, `SCNScene` | Deprecated at 26.0 on all platforms ("SceneKit is deprecated, use RealityKit instead"). |
| `ARSCNView` | Deprecated at iOS 26.0 ("Use RealityView instead"). |
| Model I/O (`MDLAsset`, `MDLMesh`, `export(to:)`, `canExportFileExtension(_:)`) | Not deprecated. |
| RealityKit `ARView`, `ModelEntity` | Not deprecated. |

#### Threading facts

- `var delegateQueue: dispatch_queue_t? { get set }` (ARSession, iOS 11.0): if nil, delegate methods run on the main queue.
- `ObjectCaptureSession` is a `@MainActor` class; every call and state read must be on the main actor.
- `PhotogrammetrySession` is not main-actor isolated; `outputs` is an AsyncSequence iterated in a Task.
- In the iOS 26 SDK, `ARFrame` is marked Sendable, but `CVPixelBuffer` (a typealias of `CVBuffer`) is not. Sendable does not make retaining frames safe (see Gotcha 3). `ARMeshAnchor` is NSSecureCoding and Sendable.

### Gotchas

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

### Recommended approach

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

### Disputed or unsure

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

## UX patterns

Scope: how the scan, review, processing and result screens should look and behave for an amateur user, and which Apple UI building blocks provide that. Room and house scanning use RoomPlan, object scanning uses RealityKit Object Capture, raw mesh mode uses ARKit plus RealityKit. Declarations below come from the Apple documentation JSON. Nothing in this topic needs a paid entitlement. Nothing needs iOS 26. The newest APIs here are iOS 18.0, which matches our deployment target, so no `#available` checks are required for anything listed here.

### Verified API

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

### Gotchas

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

### Recommended approach

**Screen map.** Home (project grid with thumbnails, one big "New scan" button) then Mode sheet (Room, House, Object, each with icon and one line) then Tips sheet, once per mode, with "Don't show again" then Capture then Review then Processing then Result. Use `NavigationStack(path:)` with a typed route enum for Home to Project to Result. Present capture as `.fullScreenCover`. This matches Apple's RoomPlan sample (Start Scanning, then capture with Cancel and Done, then Export) and what Polycam, Scaniverse and magicplan converge on.

**Unsupported devices.** Check `RoomCaptureSession.isSupported` and `ObjectCaptureSession.isSupported` at launch (the capability probe already does). Hide or disable modes that fail, with a plain "This iPhone has no LiDAR" style screen from `Copy.swift`, as Apple's sample does with its UnsupportedDevice scene.

**Room mode (v1).** Use `RoomCaptureView` in a `UIViewRepresentable`, not a custom session UI. It already gives outlines, coaching and the mini model users expect. App chrome: Cancel top-left, Done top-right. First Done calls `captureSession.stop()`; return `true` from `shouldPresent`, so the view animates the final room. Then show "Keep" and "Rescan". Save `CapturedRoom` as JSON in `didPresent` right away. Do not add a second guidance banner in room mode (see Gotcha 6); only show our own banner for `CaptureError` and thermal warnings. Map errors to `Copy.swift` strings: `deviceTooHot` "Phone is too hot. Let it cool for a minute.", `exceedSceneSizeLimit` "This scan got too large. Finish this room and start the next one.", `worldTrackingFailure` "Lost tracking. Point at the last wall you scanned."

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

### Disputed or unsure

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

