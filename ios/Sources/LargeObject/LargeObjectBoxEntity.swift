import Foundation
import RealityKit
import UIKit
import simd

// The white wireframe outline of the chosen object on the live camera (docs/MODULES.md 3.39,
// RESEARCH 3.5 "Object boxes"): one `ModelEntity` with `MeshResource.generateBox(size:cornerRadius:)`
// and an `UnlitMaterial` drawn as lines (`triangleFillMode = .lines`, iOS 18.0) with
// `faceCulling = .none`, under an `AnchorEntity(world:)` at the origin, placed with
// `Transform(matrix:)` from the box axes and center. The mesh is regenerated only when a side
// changes by more than 2 cm. Main actor, like every RealityKit entity.

/// Wireframe box on the ARView (`MeshResource.generateBox(size:cornerRadius:)` with an UnlitMaterial,
/// `triangleFillMode = .lines`, `faceCulling = .none`, white), placed with `Transform(matrix:)` from the
/// box axes and center; the mesh is regenerated only when a size changes by more than 2 cm.
@MainActor final class LargeObjectBoxEntity {
    /// World-origin anchor that holds the outline.
    private let anchor: AnchorEntity
    /// The outline, created with the first box.
    private var outline: ModelEntity?
    /// Size of the current mesh.
    private var meshSize: SIMD3<Float>?
    /// The view the anchor is added to.
    private weak var arView: ARView?
    /// The last box drawn (nil hides the outline).
    private(set) var shownBox: OrientedBox?

    /// An outline not yet attached to a view.
    init() {
        anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
    }

    /// Adds the anchor to `arView`'s scene (moving it from an earlier view).
    func attach(to arView: ARView) {
        if self.arView === arView { return }
        detach()
        arView.scene.addAnchor(anchor)
        self.arView = arView
        LargeObjectLog.write("box outline attached to the live view")
    }

    /// Shows `box` (nil hides the outline). The mesh is rebuilt only when a side changed by more
    /// than `regenerateThreshold`; otherwise only the transform moves.
    func update(_ box: OrientedBox?) {
        guard shownBox != box else { return }
        shownBox = box
        guard let box, LargeObjectBoxGeometry.isDrawable(box) else {
            outline?.isEnabled = false
            return
        }
        let size = LargeObjectBoxGeometry.drawnSize(box)
        let entity = outlineEntity(size: size)
        entity.transform = Transform(matrix: LargeObjectBoxGeometry.matrix(box))
        entity.isEnabled = true
    }

    /// Removes the anchor from its view (the entity is kept for a later attach).
    func detach() {
        guard let view = arView else { return }
        view.scene.removeAnchor(anchor)
        arView = nil
    }

    /// The outline entity with a mesh of about `size`, created or regenerated as needed.
    private func outlineEntity(size: SIMD3<Float>) -> ModelEntity {
        if let existing = outline, let current = meshSize,
           !LargeObjectBoxGeometry.needsNewMesh(current: current, wanted: size) {
            return existing
        }
        let mesh = MeshResource.generateBox(size: size, cornerRadius: 0)
        meshSize = size
        if let existing = outline {
            existing.model?.mesh = mesh
            return existing
        }
        let entity = ModelEntity(mesh: mesh, materials: [LargeObjectBoxEntity.material()])
        anchor.addChild(entity)
        outline = entity
        return entity
    }

    /// White unlit lines, both faces drawn.
    static func material() -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor.white)
        material.triangleFillMode = .lines
        material.faceCulling = .none
        return material
    }
}

/// Pure math of the outline (not actor-isolated, so the self-test can call it off main).
enum LargeObjectBoxGeometry {
    /// A side change larger than this regenerates the mesh, meters.
    static let regenerateThreshold: Float = 0.02
    /// Smallest side drawn, meters (a flat box still shows as an outline).
    static let minimumSide: Float = 0.01

    /// The full box size, at least `minimumSide` on every axis.
    static func drawnSize(_ box: OrientedBox) -> SIMD3<Float> {
        simd_max(box.halfExtents * 2, SIMD3<Float>(repeating: minimumSide))
    }

    /// True when a side differs by more than `regenerateThreshold`.
    static func needsNewMesh(current: SIMD3<Float>, wanted: SIMD3<Float>) -> Bool {
        let difference = simd_abs(wanted - current)
        return difference.max() > regenerateThreshold
    }

    /// Box to world: the box axes as rotation columns and the center as translation.
    static func matrix(_ box: OrientedBox) -> simd_float4x4 {
        let axes = box.axes
        return simd_float4x4(columns: (SIMD4<Float>(axes.columns.0, 0), SIMD4<Float>(axes.columns.1, 0),
                                       SIMD4<Float>(axes.columns.2, 0), SIMD4<Float>(box.center, 1)))
    }

    /// True when every value of the box is finite.
    static func isDrawable(_ box: OrientedBox) -> Bool {
        let values: [Float] = [box.center.x, box.center.y, box.center.z,
                               box.halfExtents.x, box.halfExtents.y, box.halfExtents.z]
        return values.allSatisfy { $0.isFinite }
    }
}
