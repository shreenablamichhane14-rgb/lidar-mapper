import Foundation
import simd

/// Fixtures for `ResultsSelfTest`: a 4 x 5 x 2.5 m room (walls 1 to 4 counter-clockwise seen
/// from above, an occluded span on wall 1), a door on wall 2, a window on wall 3, a sofa near
/// wall 1 (furniture) and a toilet (fixture). Fixed identifiers, so every run is identical.
enum ResultsSelfTestFixtures {
    /// Wall and ceiling height, meters.
    static let height: Float = 2.5

    /// A fixed identifier whose last UUID byte is `n`.
    static func id(_ n: UInt8) -> ElementID {
        ElementID(uuid: uuid(n))
    }

    /// A fixed UUID whose last byte is `n`.
    static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x52, n))
    }

    /// Room corners in world meters (plan x = world x, plan y = -world z).
    static let corners: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, 0), SIMD3<Float>(4, 0, 0), SIMD3<Float>(4, 0, -5), SIMD3<Float>(0, 0, -5),
    ]

    /// Inward wall normals in loop order.
    static let normals: [SIMD3<Float>] = [
        SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0),
    ]

    /// The four walls, ids 1 to 4; wall 1 has an occluded span from 1 m to 2.5 m.
    static func walls() -> [CleanWall] {
        var result: [CleanWall] = []
        for i in 0..<4 {
            let spans: [ClosedRange<Float>] = i == 0 ? [1.0...2.5] : []
            result.append(CleanWall(id: id(UInt8(i + 1)), start: Vec3(corners[i]), end: Vec3(corners[(i + 1) % 4]),
                                    height: height, normal: Vec3(normals[i]), thickness: 0.1, thicknessSource: .estimated,
                                    arc: nil, confidence: .high, completedEdges: 4, occludedSpans: spans,
                                    provenance: .measured))
        }
        return result
    }

    /// A box object at `center` with `size`, identity rotation.
    static func object(_ n: UInt8, _ category: ObjectCategory, center: SIMD3<Float>, size: SIMD3<Float>) -> DetectedObject {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        return DetectedObject(id: id(n), category: category, label: "", transform: Transform4(t), dimensions: Vec3(size),
                              confidence: .high, isHidden: false, provenance: .measured)
    }

    /// The room (id 30) with a door (11), a window (12), a sofa (20) and a toilet (21).
    static func room() -> CleanRoom {
        let openings = [
            CleanOpening(id: id(11), wallID: id(2), kind: .door, offsetAlongWall: 1, width: 0.9, sillHeight: 0,
                         headHeight: 2, swing: nil, provenance: .measured),
            CleanOpening(id: id(12), wallID: id(3), kind: .window, offsetAlongWall: 1, width: 1.2, sillHeight: 0.9,
                         headHeight: 2.1, swing: nil, provenance: .measured),
        ]
        let objects = [
            object(20, .sofa, center: SIMD3<Float>(2, 0.4, -0.55), size: SIMD3<Float>(2, 0.8, 0.9)),
            object(21, .toilet, center: SIMD3<Float>(0.5, 0.4, -4.5), size: SIMD3<Float>(0.4, 0.8, 0.7)),
        ]
        let outline = corners.map { PlanAxes.toPlan(Vec3($0)) }
        let metrics = RoomMetrics(floorArea: 20, perimeter: 18, ceilingHeight: height, ceilingProvenance: .measured,
                                  wallArea: 40, length: 5, width: 4, volume: 50, volumeProvenance: .measured)
        return CleanRoom(id: id(30), recordID: uuid(31), name: "", sectionLabel: nil, floorIndex: 0, walls: walls(),
                         openings: openings,
                         floor: CleanFloor(outline: outline, elevation: 0, occludedArea: 1.8, provenance: .measured),
                         ceiling: CleanCeiling(height: height, provenance: .measured), objects: objects, metrics: metrics)
    }

    /// A missing area record facing `normal` at `centroid` with `area`.
    static func missing(_ n: Int, centroid: SIMD3<Float>, normal: SIMD3<Float>, area: Float) -> MissingAreaRecord {
        MissingAreaRecord(id: n, centroid: Vec3(centroid), normal: Vec3(normal), area: area, surface: 1,
                          suggestedViewpoint: Vec3(centroid + normal))
    }
}

extension ResultsSelfTest {
    // MARK: - Content

    /// Missing area squares, 3D Clean layers and pick tags, highlight copies, textured parts.
    static func contentChecks(_ f: inout [String]) {
        missingAreaChecks(&f)
        let model = CleanModel(rooms: [ResultsSelfTestFixtures.room()], sourceIsStructure: false, stamp: nil)
        let parts = ResultContentBuilder.cleanParts(model)
        let occluded = parts.filter { $0.layer == .cleanOccluded }
        check(&f, "clean.occludedLayer", occluded.count >= 4, "\(occluded.count) occluded parts")
        check(&f, "clean.occludedNotPickable", occluded.allSatisfy { $0.pickTag == nil }, "occluded part pickable")
        let occludedFills = occluded.filter { $0.material == .translucent(ResultContentBuilder.occludedColor) }
        check(&f, "clean.occludedHatched", !occludedFills.isEmpty && occludedFills.count * 2 == occluded.count,
              "\(occludedFills.count) fills of \(occluded.count)")
        let wallIDs = (1...4).map { ResultsSelfTestFixtures.id(UInt8($0)) }
        let walls = parts.filter { part in wallIDs.contains { part.pickTag == .element($0) } }
        check(&f, "clean.wallsPickable", walls.count == 4 && walls.allSatisfy { $0.layer == .cleanStructure },
              "\(walls.count) wall parts")
        let sofa = ResultsSelfTestFixtures.id(20)
        let sofaParts = parts.filter { $0.layer == .cleanFurniture }
        check(&f, "clean.furnitureLayer", sofaParts.count == 2 && sofaParts.filter { $0.pickTag == .element(sofa) }.count == 1,
              "\(sofaParts.count) furniture parts")
        let fixtures = parts.filter { $0.layer == .cleanFixtures }
        check(&f, "clean.fixtureLayer", fixtures.count == 2, "\(fixtures.count) fixture parts")
        let door = ResultsSelfTestFixtures.id(11)
        let doors = parts.filter { $0.pickTag == .element(door) }
        check(&f, "clean.doorPickable", doors.count == 1 && doors.first?.layer == .cleanOpenings, "\(doors.count) door parts")
        let floors = parts.filter { $0.layer == .cleanStructure && $0.pickTag == nil }
        check(&f, "clean.floorNotPickable", floors.count == 1, "\(floors.count) floor parts")

        let highlight = ResultContentBuilder.highlightParts(for: ResultsSelfTestFixtures.id(1), in: parts)
        check(&f, "highlight.wall", highlight.count == 4 && highlight.allSatisfy { $0.layer == .overlay && $0.pickTag == nil },
              "\(highlight.count) highlight parts")
        check(&f, "highlight.unknown", ResultContentBuilder.highlightParts(for: ResultsSelfTestFixtures.id(99), in: parts).isEmpty,
              "highlight for an unknown element")

        check(&f, "lookup.object", ResultContentBuilder.object(sofa, in: model)?.category == .sofa, "sofa not found")
        check(&f, "lookup.opening", ResultContentBuilder.isWallOrOpening(door, in: model)
              && !ResultContentBuilder.isWallOrOpening(sofa, in: model), "wall or opening lookup")
        texturedChecks(&f)
    }

    /// Three records give three 2-triangle red squares of side sqrt(area), 2 cm off the surface.
    private static func missingAreaChecks(_ f: inout [String]) {
        let records = [
            ResultsSelfTestFixtures.missing(0, centroid: SIMD3<Float>(0, 1, 0), normal: SIMD3<Float>(0, 0, 1), area: 4),
            ResultsSelfTestFixtures.missing(1, centroid: SIMD3<Float>(2, 0, -2), normal: SIMD3<Float>(0, 1, 0), area: 0.25),
            ResultsSelfTestFixtures.missing(2, centroid: SIMD3<Float>(2, 2.5, -2), normal: SIMD3<Float>(0, -1, 0), area: 1),
        ]
        let parts = ResultContentBuilder.missingAreaParts(records)
        check(&f, "missing.count", parts.count == 3, "\(parts.count) parts")
        let shapes = parts.allSatisfy { $0.indices.count == 6 && $0.positions.count == 4 && $0.triangleCount == 2 }
        check(&f, "missing.twoTriangles", shapes, "wrong square shape")
        let styled = parts.allSatisfy {
            $0.layer == .overlay && $0.pickTag == nil && $0.material == .translucent(ResultContentBuilder.missingColor)
        }
        check(&f, "missing.overlayRed", styled, "wrong layer or material")
        if let first = parts.first, first.positions.count == 4 {
            let side = simd_distance(first.positions[0], first.positions[1])
            let offsets = first.positions.map { $0.z }
            check(&f, "missing.side", abs(side - 2) < 1e-4, "side \(side)")
            check(&f, "missing.offset", offsets.allSatisfy { abs($0 - 0.02) < 1e-5 }, "\(offsets)")
        }
        let invalid = [
            ResultsSelfTestFixtures.missing(3, centroid: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(0, 1, 0), area: 0),
            ResultsSelfTestFixtures.missing(4, centroid: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(0, 1, 0), area: Float.nan),
        ]
        check(&f, "missing.invalidSkipped", ResultContentBuilder.missingAreaParts(invalid).isEmpty, "invalid record drawn")
    }

    /// A 2-face textured mesh with one untextured face: one page part with uvs unchanged plus
    /// one gray part.
    private static func texturedChecks(_ f: inout [String]) {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("page_0.jpg", isDirectory: false)
        let uvs: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1),
                                   SIMD2<Float>(0.5, 0.5), SIMD2<Float>(0.6, 0.5), SIMD2<Float>(0.5, 0.6)]
        let mesh = TexturedMesh(positions: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0)],
                                indices: [0, 1, 2, 1, 3, 2], texcoords: uvs, faceAtlas: [0, TexturedMesh.untexturedPage],
                                pageURLs: [page], coverage: 0.5)
        let parts = ResultContentBuilder.texturedParts(mesh, idPrefix: "test")
        let textured = parts.filter { $0.material == .texture(page) }
        check(&f, "textured.page", textured.count == 1 && textured.first?.positions.count == 3, "\(textured.count) page parts")
        let firstUVs = textured.first?.uvs ?? []
        check(&f, "textured.uvsUnchanged", firstUVs == Array(uvs.prefix(3)), "\(firstUVs)")
        let gray = parts.filter { $0.material == .lit(ResultContentBuilder.untexturedColor) }
        check(&f, "textured.untexturedGray", gray.count == 1 && gray.first?.triangleCount == 1, "\(gray.count) gray parts")
        check(&f, "textured.layer", parts.allSatisfy { $0.layer == .realistic && $0.pickTag == nil }, "wrong layer")
    }

    // MARK: - Files

    /// Demo-room rule and file stamps on a temporary folder, removed afterwards.
    static func fileChecks(_ f: inout [String]) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("ResultsSelfTest", isDirectory: true)
        try? fm.removeItem(at: folder)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            check(&f, "files.tempFolder", false, "\(error)")
            return
        }
        let raw = RawScanFolder(url: folder)
        check(&f, "files.demoEmpty", ResultLoader.isDemoRoom(raw), "empty folder is not a demo room")
        check(&f, "files.stampMissing", ResultLoader.stamp([raw.capturedRoomURL]) == "none", ResultLoader.stamp([raw.capturedRoomURL]))
        do {
            try Data("{}".utf8).write(to: raw.keyframesLogURL)
            check(&f, "files.keyframesNotDemo", !ResultLoader.isDemoRoom(raw), "room with keyframes is a demo room")
            try fm.removeItem(at: raw.keyframesLogURL)
            try Data("{}".utf8).write(to: raw.capturedRoomURL)
            check(&f, "files.roomPlanNotDemo", !ResultLoader.isDemoRoom(raw), "room with RoomPlan data is a demo room")
            let stamp = ResultLoader.stamp([raw.capturedRoomURL])
            check(&f, "files.stampWritten", stamp.hasPrefix("2@"), stamp)
        } catch {
            check(&f, "files.write", false, "\(error)")
        }
    }
}
