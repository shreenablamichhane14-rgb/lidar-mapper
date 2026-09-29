import CoreGraphics
import Foundation
import simd

// Plain-Swift checks of the coverage overlay (docs/MODULES.md 3.38): grouping, packing, parts,
// capacity, visibility, schedule, style, minimap layout and the freeze rule. Pure values only:
// no ARKit, RealityKit, camera, network or files; deterministic and well under 2 s.
//
// CHECK COUNT (37): grouping 5, packing 9, parts 3, capacity 3, visibility 5, schedule 3,
// style 2, minimap layout 5, legend 1, freeze rule 1.

/// CoverageOverlay self-test. `run()` returns one line per failing check; empty means all passed.
enum CoverageOverlaySelfTest {
    /// Failing checks as "name: detail".
    static func run() -> [String] {
        var c = CoverageOverlayChecker()
        checkGrouping(&c)
        checkPacking(&c)
        checkPartsAndCapacity(&c)
        checkVisibility(&c)
        checkStyleAndLayout(&c)
        if c.failures.isEmpty && c.count < 16 {
            c.failures.append("selfTest: only \(c.count) checks ran")
        }
        return c.failures
    }

    // MARK: Grouping

    /// Checks 1, 2 and the grouping edge cases.
    static func checkGrouping(_ c: inout CoverageOverlayChecker) {
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
        let states: [CoverageState] = [.gray, .green, .yellow, .green, .red]
        let g = CoverageOverlayPacking.grouped(indices: indices, states: states)
        let expected: [UInt32] = [3, 4, 5, 9, 10, 11, 6, 7, 8, 12, 13, 14, 0, 1, 2]
        c.check(g.indices == expected, "grouped.order", "\(g.indices)")
        c.check(g.counts == [6, 3, 3, 3], "grouped.counts", "\(g.counts)")
        c.check(tripleCounts(g.indices) == tripleCounts(indices), "grouped.triples", "triples changed")
        let short = CoverageOverlayPacking.grouped(indices: [0, 1, 2, 3, 4, 5, 6], states: [.green])
        let shortCounts: [Int] = [3, 0, 0, 3]
        let shortIndices: [UInt32] = [0, 1, 2, 3, 4, 5]
        let shortOK: Bool = short.counts == shortCounts && short.indices == shortIndices
        c.check(shortOK, "grouped.missingStates", "\(short.counts) \(short.indices)")
        var ordered = true
        for (i, state) in CoverageOverlayPacking.stateOrder.enumerated()
        where CoverageOverlayPacking.slot(of: state) != i {
            ordered = false
        }
        c.check(ordered && CoverageOverlayPacking.stateOrder.count == 4, "grouped.slots", "slot(of:) disagrees with stateOrder")
    }

    /// Multiset of index triples.
    static func tripleCounts(_ indices: [UInt32]) -> [SIMD3<UInt32>: Int] {
        var out: [SIMD3<UInt32>: Int] = [:]
        let triangles = indices.count / 3
        for t in 0..<triangles {
            let triple = SIMD3<UInt32>(indices[3 * t], indices[3 * t + 1], indices[3 * t + 2])
            out[triple, default: 0] += 1
        }
        return out
    }

    // MARK: Packing

    /// Checks 4 to 7 plus the index range, grouping and non-finite cases.
    static func checkPacking(_ c: inout CoverageOverlayChecker) {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 2, -3), SIMD3<Float>(-1, 0.5, 4),
                                         SIMD3<Float>(2, -1, 1)]
        let normals: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 0, 0),
                                       SIMD3<Float>(0, -1, 0)]
        let base = anchor(positions: positions, normals: normals, indices: [0, 1, 2, 1, 3, 2], states: [.red, .green])
        guard let packed = CoverageOverlayPacking.pack(base) else {
            c.check(false, "pack.valid", "returned nil")
            return
        }
        let floats = floatsOf(packed.vertexData)
        c.check(packed.vertexData.count == 32 * 4 && packed.vertexCount == 4, "pack.stride",
                "\(packed.vertexData.count) bytes for \(packed.vertexCount) vertices")
        let up = SIMD3<Float>(0, 1, 0)
        let positionOK: Bool = vector(floats, at: 8) == SIMD3<Float>(1, 2, -3)
        let normalOK: Bool = vector(floats, at: 11) == SIMD3<Float>(1, 0, 0)
        let uvOK: Bool = floats.count >= 16 && floats[14] == 0 && floats[15] == 0
        c.check(positionOK && normalOK && uvOK, "pack.layout", "vertex 1 floats \(Array(floats.prefix(16)))")
        let missingOK: Bool = vector(floats, at: 19) == up
        let bare = anchor(positions: positions, normals: [], indices: [0, 1, 2], states: [.gray])
        let bareFloats = CoverageOverlayPacking.pack(bare).map { floatsOf($0.vertexData) } ?? []
        let bareOK: Bool = vector(bareFloats, at: 3) == up
        c.check(missingOK && bareOK, "pack.unknownNormal", "zero normal \(missingOK), no normals \(bareOK)")
        let mismatch = anchor(positions: positions, normals: normals, indices: [0, 1, 2, 1, 3, 2], states: [.red])
        c.check(CoverageOverlayPacking.pack(mismatch) == nil, "pack.statesMismatch", "not nil")
        let outOfRange = anchor(positions: positions, normals: normals, indices: [0, 1, 7], states: [.red])
        c.check(CoverageOverlayPacking.pack(outOfRange) == nil, "pack.indexRange", "not nil")
        let lowOK = packed.boundsMin == SIMD3<Float>(-1, -1, -3)
        let highOK = packed.boundsMax == SIMD3<Float>(2, 2, 4)
        c.check(lowOK && highOK, "pack.bounds", "\(packed.boundsMin) \(packed.boundsMax)")
        let groupedIndices: [UInt32] = [1, 3, 2, 0, 1, 2]
        let groupedCounts: [Int] = [3, 0, 3, 0]
        let groupedOK: Bool = packed.indices == groupedIndices && packed.groupCounts == groupedCounts
        c.check(groupedOK, "pack.grouped", "\(packed.indices) \(packed.groupCounts)")
        let sameID: Bool = packed.anchorID == base.anchorID && packed.revision == base.revision
        let sameTranslation: Bool = packed.transform.columns.3 == base.transform.columns.3
        let sameAxis: Bool = packed.transform.columns.0 == base.transform.columns.0
        let sameTransform: Bool = sameTranslation && sameAxis
        c.check(sameID && sameTransform, "pack.identity", "id, revision or transform changed")
        var broken = positions
        broken[3] = SIMD3<Float>(Float.nan, 0, 0)
        let nonFinite = anchor(positions: broken, normals: normals, indices: [0, 1, 2, 1, 3, 2], states: [.red, .green])
        let kept = CoverageOverlayPacking.pack(nonFinite)
        let keptIndices: [UInt32] = kept?.indices ?? []
        let keptCounts: [Int] = kept?.groupCounts ?? []
        let keptHigh: SIMD3<Float> = kept?.boundsMax ?? SIMD3<Float>(repeating: Float.nan)
        let expectedKept: [UInt32] = [0, 1, 2]
        let expectedKeptCounts: [Int] = [0, 0, 3, 0]
        let keptOK: Bool = keptIndices == expectedKept && keptCounts == expectedKeptCounts
        c.check(keptOK && keptHigh == SIMD3<Float>(1, 2, 4), "pack.nonFinite", "\(keptIndices) \(keptCounts) \(keptHigh)")
    }

    /// An anchor of the given geometry at a fixed id, transform and revision.
    static func anchor(positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32],
                       states: [CoverageState]) -> CoverageAnchorFaces {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(0.5, 0, -2, 1)
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1") ?? UUID()
        return CoverageAnchorFaces(anchorID: id, updateCount: 1, transform: transform, localPositions: positions,
                                   localNormals: normals, indices: indices, faces: [], states: states,
                                   boundsMin: .zero, boundsMax: .zero, revision: 7)
    }

    /// Three floats starting at `index`, or NaN when out of range (never equal to anything).
    static func vector(_ floats: [Float], at index: Int) -> SIMD3<Float> {
        guard index >= 0, index + 2 < floats.count else { return SIMD3<Float>(repeating: Float.nan) }
        return SIMD3<Float>(floats[index], floats[index + 1], floats[index + 2])
    }

    /// True when two point values differ by less than 1e-4.
    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool {
        let difference: CGFloat = a - b
        return difference.magnitude < 0.0001
    }

    /// The floats of little-endian packed data.
    static func floatsOf(_ data: Data) -> [Float] {
        let count = data.count / 4
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            var floats: [Float] = []
            floats.reserveCapacity(count)
            for i in 0..<count { floats.append(raw.load(fromByteOffset: i * 4, as: Float.self)) }
            return floats
        }
    }

    // MARK: Parts and capacity

    /// Check 3, the parts of a packed anchor, and check 8.
    static func checkPartsAndCapacity(_ c: inout CoverageOverlayChecker) {
        let parts = CoverageOverlayPacking.parts(groupCounts: [6, 0, 3, 3])
        let offsets = parts.map { $0.byteOffset }
        let counts = parts.map { $0.indexCount }
        let materials = parts.map { $0.materialIndex }
        let expectedOffsets: [Int] = [0, 24, 36]
        let expectedCounts: [Int] = [6, 3, 3]
        let expectedMaterials: [Int] = [0, 2, 3]
        c.check(parts.count == 3 && offsets == expectedOffsets, "parts.offsets", "\(offsets)")
        let countsOK: Bool = counts == expectedCounts && materials == expectedMaterials
        c.check(countsOK, "parts.counts", "\(counts) \(materials)")
        let none = CoverageOverlayPacking.parts(groupCounts: [0, 0, 0, 0])
        let odd = CoverageOverlayPacking.parts(groupCounts: [0, -3, 3, 0, 9])
        let firstOdd = odd.first ?? CoverageOverlayPart(byteOffset: -1, indexCount: 0, materialIndex: -1)
        let oddOK = odd.count == 1 && firstOdd.byteOffset == 0 && firstOdd.materialIndex == 2
        c.check(none.isEmpty && oddOK, "parts.edges", "\(none.count) \(odd)")
        let cap = CoverageOverlayPacking.self
        c.check(cap.capacity(needed: 100, current: 0) == 150, "capacity.grow", "\(cap.capacity(needed: 100, current: 0))")
        c.check(cap.capacity(needed: 100, current: 120) == 120, "capacity.keep", "\(cap.capacity(needed: 100, current: 120))")
        c.check(cap.capacity(needed: 130, current: 120) == 195, "capacity.regrow", "\(cap.capacity(needed: 130, current: 120))")
    }

    // MARK: Visibility and schedule

    /// Checks 9 and 10.
    static func checkVisibility(_ c: inout CoverageOverlayChecker) {
        let camera = matrix_identity_float4x4
        let half = SIMD3<Float>(0.5, 0.5, 0.5)
        let ahead = SIMD3<Float>(0, 0, -2)
        c.check(visible(ahead - half, ahead + half, camera), "visible.ahead", "false")
        let behind = SIMD3<Float>(0, 0, 2)
        c.check(!visible(behind - half, behind + half, camera), "visible.behind", "true")
        let far = SIMD3<Float>(0, 0, -10)
        c.check(!visible(far - half, far + half, camera), "visible.far", "true")
        c.check(visible(SIMD3<Float>(-1, -1, -1), SIMD3<Float>(1, 1, 1), camera), "visible.inside", "false")
        var turned = matrix_identity_float4x4
        turned.columns.0 = SIMD4<Float>(0, 0, -1, 0)
        turned.columns.2 = SIMD4<Float>(1, 0, 0, 0)
        let left = SIMD3<Float>(-2, 0, 0)
        c.check(visible(left - half, left + half, turned) && !visible(ahead - half, ahead + half, turned),
                "visible.turned", "the cone does not follow the camera's -Z column")

        var pending: [UUID: CoverageAnchorFaces] = [:]
        let closest = boxAnchor(1, center: SIMD3<Float>(0, 0, -2))
        let middle = boxAnchor(2, center: SIMD3<Float>(0.5, 0, -3))
        let farther = boxAnchor(3, center: SIMD3<Float>(-0.5, 0, -4))
        let back = boxAnchor(4, center: SIMD3<Float>(0, 0, 3))
        for a in [farther, back, closest, middle] { pending[a.anchorID] = a }
        let two = CoverageOverlayPacking.schedule(pending, cameraToWorld: camera, halfAngleDegrees: 60,
                                                  maxDistance: 6, limit: 2)
        c.check(two == [closest.anchorID, middle.anchorID], "schedule.nearest", "\(two)")
        let all = CoverageOverlayPacking.schedule(pending, cameraToWorld: camera, halfAngleDegrees: 60,
                                                  maxDistance: 6, limit: 10)
        let allOK = all == [closest.anchorID, middle.anchorID, farther.anchorID]
        c.check(allOK && !all.contains(back.anchorID), "schedule.visibleOnly", "\(all)")
        let zero = CoverageOverlayPacking.schedule(pending, cameraToWorld: camera, halfAngleDegrees: 60,
                                                   maxDistance: 6, limit: 0)
        c.check(zero.isEmpty, "schedule.limitZero", "\(zero)")
    }

    /// `isVisible` with the overlay's default cone (60 degrees, 6 m).
    static func visible(_ low: SIMD3<Float>, _ high: SIMD3<Float>, _ camera: simd_float4x4) -> Bool {
        CoverageOverlayPacking.isVisible(boundsMin: low, boundsMax: high, cameraToWorld: camera,
                                         halfAngleDegrees: 60, maxDistance: 6)
    }

    /// A 0.4 m cube anchor at `center` with a fixed id from `n`.
    static func boxAnchor(_ n: Int, center: SIMD3<Float>) -> CoverageAnchorFaces {
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)") ?? UUID()
        let half = SIMD3<Float>(0.2, 0.2, 0.2)
        return CoverageAnchorFaces(anchorID: id, updateCount: 1, transform: matrix_identity_float4x4,
                                   localPositions: [], localNormals: [], indices: [], faces: [], states: [],
                                   boundsMin: center - half, boundsMax: center + half, revision: UInt64(n))
    }

    // MARK: Style, minimap layout, legend and freeze rule

    /// Checks 11 to 16 plus the plan point mapping and the legend texts.
    static func checkStyleAndLayout(_ c: inout CoverageOverlayChecker) {
        var distinct = true
        var alphas = true
        for style in [CoverageOverlayStyle.standard, CoverageOverlayStyle(opacity: 0.7)] {
            let colors = CoverageOverlayPacking.stateOrder.map { style.color(for: $0) }
            for i in 0..<colors.count {
                if colors[i].w != style.opacity { alphas = false }
                for j in (i + 1)..<colors.count where colors[i] == colors[j] { distinct = false }
            }
        }
        c.check(distinct && alphas && CoverageOverlayStyle.standard.opacity == 0.45, "style.colors",
                "distinct \(distinct), alphas \(alphas)")
        let green = CoverageOverlayStyle.standard.color(for: .green)
        c.check(green == SIMD4<Float>(0.15, 0.80, 0.35, 0.45), "style.green", "\(green)")

        let fit = CoverageMinimapLayout.fit(width: 10, height: 20, in: CGSize(width: 120, height: 120))
        let scaleOK = near(fit.scale, 6)
        let centeredOK = near(fit.offset.x, 30) && near(fit.offset.y, 0)
        c.check(scaleOK && centeredOK, "minimap.fit", "scale \(fit.scale), offset \(fit.offset)")
        let bottom = CoverageMinimapLayout.cellRect(x: 0, y: 0, height: 20, scale: 6, offset: CGPoint(x: 30, y: 0))
        let top = CoverageMinimapLayout.cellRect(x: 9, y: 19, height: 20, scale: 6, offset: CGPoint(x: 30, y: 0))
        let bottomOK = near(bottom.maxY, 120) && near(bottom.minX, 30)
        let topOK = near(top.minY, 0) && near(top.maxX, 90)
        c.check(bottomOK && topOK, "minimap.cellRect", "row 0 \(bottom), row 19 \(top)")
        let origin = Vec2(x: -1, y: 2)
        let corner = CoverageMinimapLayout.point(Vec2(x: 1.5, y: 7), origin: origin, cellSize: 0.25, height: 20,
                                                 scale: 6, offset: CGPoint(x: 30, y: 0))
        let start = CoverageMinimapLayout.point(origin, origin: origin, cellSize: 0.25, height: 20,
                                                scale: 6, offset: CGPoint(x: 30, y: 0))
        let cornerOK = near(corner.x, 90) && near(corner.y, 0)
        let startOK = near(start.x, 30) && near(start.y, 120)
        c.check(cornerOK && startOK, "minimap.point", "\(corner) \(start)")
        let style = CoverageOverlayStyle.standard
        let emptyColor: SIMD4<Float>? = CoverageMinimapLayout.color(for: .empty, style: style)
        let coveredColor: SIMD4<Float>? = CoverageMinimapLayout.color(for: .covered, style: style)
        let partialColor: SIMD4<Float>? = CoverageMinimapLayout.color(for: .partial, style: style)
        let missingColor: SIMD4<Float>? = CoverageMinimapLayout.color(for: .missing, style: style)
        let greenOK: Bool = coveredColor == style.color(for: .green)
        let yellowOK: Bool = partialColor == style.color(for: .yellow)
        let redOK: Bool = missingColor == style.color(for: .red)
        c.check(emptyColor == nil && greenOK && yellowOK && redOK, "minimap.color", "cell colors differ from the style")
        let percents = [CoverageMinimapLayout.percent(0.943), CoverageMinimapLayout.percent(1.2),
                        CoverageMinimapLayout.percent(-0.1), CoverageMinimapLayout.percent(Float.nan)]
        let expectedPercents: [Int] = [94, 100, 0, 0]
        c.check(percents == expectedPercents, "minimap.percent", "\(percents)")

        let texts = CoverageOverlayPacking.stateOrder.map { CoverageLegendContent.text(for: $0) }
        let textsOK = Set(texts).count == 4 && texts.first == Copy.Scanning.legendGreen
        c.check(textsOK && texts.last == Copy.Scanning.legendGray, "legend.texts", "\(texts)")

        let serious = CoverageOverlayRenderer.shouldFreeze(policy: ThermalPolicy.forLevel(.serious))
        let critical = CoverageOverlayRenderer.shouldFreeze(policy: ThermalPolicy.forLevel(.critical))
        let nominal = CoverageOverlayRenderer.shouldFreeze(policy: ThermalPolicy.forLevel(.nominal))
        let fair = CoverageOverlayRenderer.shouldFreeze(policy: ThermalPolicy.forLevel(.fair))
        c.check(serious && critical && !nominal && !fair, "renderer.shouldFreeze",
                "serious \(serious), critical \(critical), nominal \(nominal), fair \(fair)")
    }
}

/// Collects failures and counts checks for `CoverageOverlaySelfTest`.
struct CoverageOverlayChecker {
    /// Failing checks as "name: detail".
    var failures: [String] = []
    /// Checks run.
    var count = 0

    /// Records one check; the detail is built only when it fails.
    mutating func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String) {
        count += 1
        if !ok { failures.append("\(name): \(detail())") }
    }
}
