import Foundation
import simd

/// Adapts the untextured object mesh (mesh.mchk) to the Export writers' input (OBJ, STL, PLY,
/// GLB, USDZ in ExportUI). Pure and nonisolated.
enum ObjectExportAdapter {
    /// Name of the material inside exported files.
    static let materialName = "object"
    /// Neutral gray of the untextured model (linear RGBA 0...1).
    static let neutralGray = SIMD4<Float>(0.7, 0.7, 0.7, 1)

    /// The untextured mesh as one `ExportMesh` with normals and a neutral gray material. Faces
    /// with an out-of-range index or a non-finite corner are left out and unused vertices
    /// dropped (MeshModel `MeshExportAdapter.exportMesh`), so `ExportScene.validate()` passes for
    /// any mesh with at least one valid triangle. Metadata records the triangle count.
    static func scene(_ mesh: MeshWithAttributes, name: String) -> ExportScene {
        var plain = mesh
        plain.faceClass = nil
        plain.vertexColor = nil
        plain.isInferred = nil
        var exportMesh = MeshExportAdapter.exportMesh(plain, name: name, colorByClass: false)
        exportMesh.materialIndex = 0
        let material = ExportMaterial(name: materialName, baseColor: neutralGray)
        let metadata: [String: String] = ["objectTriangles": String(exportMesh.triangleCount)]
        return ExportScene(meshes: [exportMesh], materials: [material], metadata: metadata)
    }
}
