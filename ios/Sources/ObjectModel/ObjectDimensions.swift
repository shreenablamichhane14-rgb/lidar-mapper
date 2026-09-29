import Foundation
import simd

/// Why an object has no volume. Raw values are persisted in dims.json.
enum ObjectVolumeReason: String, Codable, CaseIterable, Sendable {
    /// Open edges (the base was not seen, or thin parts left holes).
    case notWatertight
    /// Closed but encloses no measurable volume.
    case degenerate
}

/// `derived/objects/<id>/dims.json`: the measurements of one scanned object (Representation E).
struct ObjectDimensionsRecord: Codable, Equatable, Sendable {
    /// The object (`ObjectRecord.id`).
    var objectID: UUID
    /// Which path measured it: Object Capture (small and medium) or the LiDAR mesh (large).
    var source: ObjectSize
    /// Box sides, meters: width is the longer horizontal side (box axis 0), height is vertical
    /// (axis 1, world up), depth the shorter horizontal side (axis 2).
    var width: Float
    /// Vertical side of the box, meters.
    var height: Float
    /// Shorter horizontal side of the box, meters.
    var depth: Float
    /// Square meters.
    var surfaceArea: Float
    /// Cubic meters, only when the mesh is watertight.
    var volume: Float?
    /// Nil exactly when `volume` is set.
    var volumeUnavailableReason: ObjectVolumeReason?
    /// The gravity-aligned box, in the frame of the saved mesh.
    var box: OrientedBoxRecord
    /// True when every edge of the welded mesh is shared by exactly two triangles.
    var isWatertight: Bool
    /// Triangles of the measured mesh.
    var triangleCount: Int
    /// 1 unless the unit check rescaled the model (logged).
    var scaleCorrection: Float
    /// `.measured`; `.estimated` for a large object whose isolated mesh is open (a side was
    /// not seen, TEST_PLAN OBJ-05).
    var provenance: Provenance
    /// Input hash of the step run that wrote the record (for the log and diagnostics).
    var inputHash: String
    /// When the record was made.
    var measuredAt: Date
}

/// The record's numbers as MeasureCore values (MeasureDisplay formats them).
struct ObjectMeasuredValues: Equatable, Sendable {
    /// Width (longer horizontal side), meters.
    var width: MeasuredValue
    /// Height, meters.
    var height: MeasuredValue
    /// Depth (shorter horizontal side), meters.
    var depth: MeasuredValue
    /// Surface area, square meters.
    var surfaceArea: MeasuredValue
    /// Volume, cubic meters; nil when the record has none.
    var volume: MeasuredValue?
}

/// Object measurements (SPEC "OBJECT SCANNING" and "MEASUREMENT CONFIDENCE"): the gravity box,
/// sides, surface area and a volume only for a closed mesh, the unit check against the
/// photogrammetry bounds, and the confidence rule per size class. Pure and nonisolated.
enum ObjectDimensions {
    /// Confidence rule for objects (1 sigma = max(floor, relative x length)); 2 sigma then
    /// matches TEST_PLAN OBJ-01's "1.5 cm or 3 percent" for Object Capture and "2 cm or 4
    /// percent" for the LiDAR mesh of large objects. Tuned with the tape protocol.
    static let smallMediumSigmaFloor: Float = 0.0075
    /// Relative part of the small and medium length sigma.
    static let smallMediumSigmaRelative: Float = 0.015
    /// Absolute floor of the large-object length sigma, meters.
    static let largeSigmaFloor: Float = 0.01
    /// Relative part of the large-object length sigma.
    static let largeSigmaRelative: Float = 0.02
    /// A reported extent ratio outside 0.8...1.25 is a unit mismatch.
    static let scaleTolerance: ClosedRange<Float> = 0.8...1.25
    /// Power-of-ten corrections tried when the ratio is outside `scaleTolerance`.
    static let scaleCandidates: [Float] = [0.01, 0.1, 10, 100]
    /// Open edges of an isolated large object that lie at most this far (meters) above the
    /// removed support plane are where the object rested on it, not a side that was missed,
    /// so they do not make the dimensions estimated.
    static let supportContactBand: Float = 0.05

    // MARK: - Measuring

    /// Small and medium: `ObjectIsolation.measure(_:support: nil)` on the welded mesh (box, sides,
    /// surface area, volume when watertight); nil when the mesh is empty. The winding is made
    /// consistent first (`MeshCleanup.fixingWinding`, topology unchanged), so a model part with a
    /// flipped winding cannot cancel out part of the enclosed volume. Provenance `.measured`.
    static func measure(_ mesh: MeshWithAttributes, objectID: UUID, source: ObjectSize,
                        scaleCorrection: Float, inputHash: String, now: Date) -> ObjectDimensionsRecord? {
        guard mesh.triangleCount > 0 else { return nil }
        let oriented = MeshCleanup.fixingWinding(mesh)
        guard let found = ObjectIsolation.measure(oriented, support: nil) else { return nil }
        return record(found, objectID: objectID, source: source, scaleCorrection: scaleCorrection,
                      provenance: .measured, inputHash: inputHash, now: now)
    }

    /// Large: `ObjectIsolation.isolate(_:box:options:)` of the consolidated mesh with the crop box
    /// (support plane removed); the isolated mesh is returned for mesh.mchk. Provenance
    /// `.estimated` when the isolated mesh is open (`hasOpenSide`: open edges away from the
    /// support contact, so a side was not seen), else `.measured`. Nil when nothing is left.
    static func isolate(_ roomMesh: MeshWithAttributes, box: OrientedBox, objectID: UUID,
                        inputHash: String, now: Date) -> (record: ObjectDimensionsRecord, mesh: MeshWithAttributes)? {
        guard let found = ObjectIsolation.isolate(roomMesh, box: box) else { return nil }
        let open = hasOpenSide(found.mesh.mesh, support: found.supportPlane)
        let made = record(found, objectID: objectID, source: .large, scaleCorrection: 1,
                          provenance: open ? .estimated : .measured, inputHash: inputHash, now: now)
        return (record: made, mesh: found.mesh)
    }

    /// True when `mesh` has an open edge that is not part of the contact with `support`: any
    /// boundary edge with an end more than `supportContactBand` above the plane, any boundary
    /// edge at all when there is no support plane, and any edge with an out-of-range index.
    /// A closed mesh has no open side.
    static func hasOpenSide(_ mesh: TriangleMesh, support: Plane?) -> Bool {
        let edges = mesh.boundaryEdges
        guard !edges.isEmpty else { return false }
        guard let plane = support else { return true }
        let count = mesh.positions.count
        for edge in edges {
            let a = Int(edge.0), b = Int(edge.1)
            guard a < count, b < count else { return true }
            let heightA: Float = plane.signedDistance(to: mesh.positions[a])
            let heightB: Float = plane.signedDistance(to: mesh.positions[b])
            if heightA > supportContactBand || heightB > supportContactBand { return true }
        }
        return false
    }

    /// Maps MeshProcessing's reason one to one to the persisted reason.
    static func volumeReason(_ reason: ObjectIsolation.VolumeUnavailableReason?) -> ObjectVolumeReason? {
        guard let reason = reason else { return nil }
        switch reason {
        case .notWatertight:
            return .notWatertight
        case .degenerate:
            return .degenerate
        }
    }

    /// The record for a measured or isolated object.
    private static func record(_ found: ObjectIsolation.IsolatedObject, objectID: UUID, source: ObjectSize,
                               scaleCorrection: Float, provenance: Provenance, inputHash: String,
                               now: Date) -> ObjectDimensionsRecord {
        let reason = volumeReason(found.volumeUnavailableReason)
        return ObjectDimensionsRecord(objectID: objectID, source: source, width: found.width, height: found.height,
                                      depth: found.depth, surfaceArea: found.surfaceArea, volume: found.volume,
                                      volumeUnavailableReason: reason, box: OrientedBoxRecord(found.box),
                                      isWatertight: reason != .notWatertight, triangleCount: found.mesh.triangleCount,
                                      scaleCorrection: scaleCorrection, provenance: provenance,
                                      inputHash: inputHash, measuredAt: now)
    }

    // MARK: - Unit check

    /// 1 when `reported` is nil or the ratio of the largest extents is inside `scaleTolerance`;
    /// otherwise the nearest power of ten that brings it inside (0.01, 0.1, 10, 100), else 1.
    /// The ratio is reported over mesh, so multiplying the mesh positions by the result brings
    /// the mesh to the reported size. Non-finite or non-positive extents give 1.
    static func scaleCorrection(meshExtents: SIMD3<Float>, reportedExtents: SIMD3<Float>?) -> Float {
        guard let reported = reportedExtents else { return 1 }
        let meshLargest: Float = meshExtents.max()
        let reportedLargest: Float = reported.max()
        guard meshLargest.isFinite, reportedLargest.isFinite, meshLargest > 0, reportedLargest > 0 else { return 1 }
        let ratio: Float = reportedLargest / meshLargest
        guard ratio.isFinite else { return 1 }
        if scaleTolerance.contains(ratio) { return 1 }
        var best: Float = 1
        var bestError = Float.infinity
        for candidate in scaleCandidates {
            let corrected: Float = ratio / candidate
            guard scaleTolerance.contains(corrected) else { continue }
            let error: Float = abs(log10(corrected))
            if error < bestError {
                best = candidate
                bestError = error
            }
        }
        return best
    }

    // MARK: - Confidence

    /// Sigma floor (meters) and relative sigma of a size class.
    static func sigmaParameters(_ source: ObjectSize) -> (floor: Float, relative: Float) {
        switch source {
        case .smallMedium:
            return (floor: smallMediumSigmaFloor, relative: smallMediumSigmaRelative)
        case .large:
            return (floor: largeSigmaFloor, relative: largeSigmaRelative)
        }
    }

    /// One sigma of a measured length, meters: max(floor, relative x length) of the size class.
    static func sigma(length: Float, source: ObjectSize) -> Double {
        let parameters = sigmaParameters(source)
        let relative: Double = Double(parameters.relative) * Double(abs(length))
        return Swift.max(Double(parameters.floor), relative)
    }

    /// Lengths with `sigma(length:source:)`; surface area and volume with a relative sigma of
    /// 2 x the size's relative length sigma (area and volume grow with two and three sides);
    /// provenance from the record.
    static func measuredValues(_ record: ObjectDimensionsRecord) -> ObjectMeasuredValues {
        let source = record.source
        let provenance = record.provenance
        let relative: Double = 2 * Double(sigmaParameters(source).relative)
        /// A length value with the size class's sigma and the record's provenance.
        func length(_ value: Float) -> MeasuredValue {
            MeasuredValue(value: Double(value), sigma: sigma(length: value, source: source), provenance: provenance)
        }
        let area = Double(record.surfaceArea)
        let surface = MeasuredValue(value: area, sigma: relative * abs(area), provenance: provenance)
        let volume = record.volume.map { (value: Float) -> MeasuredValue in
            let cubic = Double(value)
            return MeasuredValue(value: cubic, sigma: relative * abs(cubic), provenance: provenance)
        }
        return ObjectMeasuredValues(width: length(record.width), height: length(record.height), depth: length(record.depth),
                                    surfaceArea: surface, volume: volume)
    }
}
