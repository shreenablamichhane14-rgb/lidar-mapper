import Foundation
import RealityKit
import simd

/// `ObjectModelEntityLoader.swift`, the only file importing RealityKit. Whether ModelIO reads Object
/// Capture's USDZ on iOS 18.3.2 is an open device question (MODULES 2.2), and the small and medium
/// plan has no other way to measure the object, so a ModelIO failure must not fail the required step.
extension ObjectModelLoader {
    /// Fallback when `canReadUSDZ` is false or `mesh(fromUSDZ:)` throws `.cannotImport`:
    /// `try await Entity(contentsOf: url)`, then for every descendant with a `ModelComponent`, its
    /// `mesh.contents` instances (`contents.models[instance.model]`, each part's `positions` and
    /// `triangleIndices`) through `instance.transform` and the entity's `transformMatrix(relativeTo: nil)`,
    /// welded like the ModelIO path. Main actor by API (a 50k-triangle model takes milliseconds);
    /// returns a value, keeps no entity; throws `ObjectModelError.noTriangles` when nothing is found
    /// and `.cannotImport` when the file is missing or RealityKit cannot load it.
    @MainActor static func meshFromEntity(at url: URL) async throws -> MeshWithAttributes {
        let started = ProcessInfo.processInfo.systemUptime
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ObjectModelError.cannotImport("file missing: \(name)")
        }
        let root: Entity
        do {
            root = try await Entity(contentsOf: url)
        } catch {
            throw ObjectModelError.cannotImport("RealityKit could not load \(name): \(error)")
        }
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var modelEntities = 0
        var partsRead = 0
        var notes: [String] = []
        var pending: [Entity] = [root]
        while let entity = pending.popLast() {
            if let component = entity.components[ModelComponent.self] {
                modelEntities += 1
                let world: simd_float4x4 = entity.transformMatrix(relativeTo: nil)
                let contents = component.mesh.contents
                for instance in contents.instances {
                    guard let model = contents.models[instance.model] else {
                        notes.append("an instance names a missing model")
                        continue
                    }
                    let matrix: simd_float4x4 = simd_mul(world, instance.transform)
                    for part in model.parts {
                        let partPositions = vectors(part.positions)
                        let partIndices = corners(part.triangleIndices)
                        let added = appendPart(partPositions, partIndices, matrix: matrix,
                                               positions: &positions, indices: &indices)
                        if added {
                            partsRead += 1
                        } else {
                            notes.append("a part without usable triangles")
                        }
                    }
                }
            }
            pending.append(contentsOf: entity.children)
        }
        for note in notes.prefix(20) {
            LogStore.shared.write("RealityKit \(name): skipped \(note)", category: logCategory)
        }
        let rawTriangles = indices.count / 3
        guard rawTriangles > 0 else { throw ObjectModelError.noTriangles }
        let result = weldedModelMesh(TriangleMesh(positions: positions, indices: indices))
        guard result.triangleCount > 0 else { throw ObjectModelError.noTriangles }

        let seconds = ProcessInfo.processInfo.systemUptime - started
        let fields: [String] = [
            "\(modelEntities) model entities",
            "\(partsRead) parts",
            "\(notes.count) skipped",
            "\(rawTriangles) triangles read",
            "\(result.triangleCount) welded, \(result.mesh.positions.count) vertices",
            "mesh bounds " + boundsText(result.mesh.boundingBox),
            String(format: "%.2f s", seconds)
        ]
        LogStore.shared.write("RealityKit read \(name): " + fields.joined(separator: ", "), category: logCategory)
        return result
    }

    /// Appends one mesh part moved by `matrix`: triangles whose three indices are inside the
    /// part, in order, with the winding flipped when `matrix` mirrors. Returns false (and adds
    /// nothing) when the part has no positions or no whole triangle.
    private static func appendPart(_ partPositions: [SIMD3<Float>], _ partIndices: [UInt32], matrix: simd_float4x4,
                                   positions: inout [SIMD3<Float>], indices: inout [UInt32]) -> Bool {
        let count = partPositions.count
        guard count > 0, partIndices.count >= 3 else { return false }
        let base = positions.count
        guard base + count < Int(UInt32.max) else { return false }
        let offset = UInt32(base)
        let limit = UInt32(count)
        let mirrored = simd_determinant(matrix) < 0
        var triangles: [UInt32] = []
        triangles.reserveCapacity(partIndices.count - partIndices.count % 3)
        for t in 0..<(partIndices.count / 3) {
            let a = partIndices[3 * t], b = partIndices[3 * t + 1], c = partIndices[3 * t + 2]
            guard a < limit, b < limit, c < limit else { continue }
            if mirrored {
                triangles.append(contentsOf: [a + offset, c + offset, b + offset])
            } else {
                triangles.append(contentsOf: [a + offset, b + offset, c + offset])
            }
        }
        guard !triangles.isEmpty else { return false }
        positions.reserveCapacity(base + count)
        for p in partPositions {
            positions.append(transformed(p, by: matrix))
        }
        indices.append(contentsOf: triangles)
        return true
    }

    /// The elements of a position buffer (empty for none). Taking an optional lets the call
    /// compile whether the SDK declares the buffer optional or not. Main actor like its only
    /// caller, so a main-actor RealityKit accessor is never reached from nonisolated code.
    @MainActor private static func vectors(_ buffer: MeshBuffer<SIMD3<Float>>?) -> [SIMD3<Float>] {
        buffer?.elements ?? []
    }

    /// The elements of a triangle index buffer (empty for none; parts without triangles have
    /// none). Main actor like its only caller.
    @MainActor private static func corners(_ buffer: MeshBuffer<UInt32>?) -> [UInt32] {
        buffer?.elements ?? []
    }
}
