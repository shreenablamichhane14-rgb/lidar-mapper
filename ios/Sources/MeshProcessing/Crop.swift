import Foundation
import simd

/// A region of space used to crop meshes.
enum CropRegion {
    /// Inside an oriented box (`OrientedBox.contains`, with its default tolerance).
    case orientedBox(OrientedBox)
    /// Inside an axis-aligned box, boundary included.
    case box(AABB3)
    /// On the normal side of a plane: inside when `signedDistance >= 0`.
    case halfSpace(Plane)
}

/// Keeps or removes the faces inside a user-drawn region (manual cropping). Pure functions
/// returning new meshes; inputs are never mutated.
enum MeshCrop {
    /// Which faces survive a crop.
    enum Mode {
        /// Keep the faces inside the region.
        case keepInside
        /// Remove the faces inside the region.
        case removeInside
    }

    /// How a face is judged inside.
    enum FaceTest {
        /// The face centroid is inside.
        case centroid
        /// All three corners are inside.
        case allCorners
        /// At least one corner is inside.
        case anyCorner
    }

    /// True when `p` is inside `region`.
    static func contains(_ region: CropRegion, _ p: SIMD3<Float>) -> Bool {
        switch region {
        case .orientedBox(let box):
            return box.contains(p)
        case .box(let box):
            return box.contains(p)
        case .halfSpace(let plane):
            return plane.signedDistance(to: p) >= 0
        }
    }

    /// Per face: true when the face is inside `region` by `test`. Faces with an
    /// out-of-range index are never inside.
    static func insideMask(_ mesh: TriangleMesh, region: CropRegion, test: FaceTest = .centroid) -> [Bool] {
        var mask = [Bool](repeating: false, count: mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            guard let corners = mesh.triangle(t) else { continue }
            switch test {
            case .centroid:
                mask[t] = contains(region, (corners.0 + corners.1 + corners.2) / 3)
            case .allCorners:
                mask[t] = contains(region, corners.0) && contains(region, corners.1) && contains(region, corners.2)
            case .anyCorner:
                mask[t] = contains(region, corners.0) || contains(region, corners.1) || contains(region, corners.2)
            }
        }
        return mask
    }

    /// The mesh with the faces inside `region` kept (`.keepInside`) or removed
    /// (`.removeInside`), unused vertices dropped and attributes following.
    static func crop(_ input: MeshWithAttributes, region: CropRegion, mode: Mode, test: FaceTest = .centroid) -> MeshWithAttributes {
        let mask = insideMask(input.mesh, region: region, test: test)
        let keep: [Bool]
        switch mode {
        case .keepInside:
            keep = mask
        case .removeInside:
            keep = mask.map { !$0 }
        }
        return input.keepingFaces(keep)
    }
}
