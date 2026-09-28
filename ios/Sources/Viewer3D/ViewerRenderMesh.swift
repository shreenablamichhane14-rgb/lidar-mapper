import Foundation
import Metal
import RealityKit
import UIKit
import simd

/// A `ViewerPart` packed for upload: interleaved vertex bytes, indices and bounds. Built off
/// the main actor by `ViewerRenderMesh.packedPart`; only the memory copy into the
/// `LowLevelMesh` happens on main.
struct ViewerPackedPart: Sendable {
    /// `ViewerPart.id`.
    var id: String
    /// Visibility group.
    var layer: ViewerLayer
    /// How the part is drawn.
    var material: ViewerMaterial
    /// `vertexCount * ViewerRenderMesh.vertexStride` bytes (position, normal, uv0).
    var vertexData: Data
    /// Triangle indices.
    var indices: [UInt32]
    /// Number of vertices.
    var vertexCount: Int
    /// Lower corner of the part bounds.
    var boundsMin: SIMD3<Float>
    /// Upper corner of the part bounds.
    var boundsMax: SIMD3<Float>
}

/// Turns parts into RealityKit entities: one `ModelEntity` per part with its own `LowLevelMesh`
/// and exactly one `LowLevelMesh.Part` (index offset 0).
///
/// Vertex layout (interleaved, one buffer): position `.float3` at 0, normal `.float3` at 12,
/// uv0 `.float2` at 24, stride 32; `UInt32` indices. Every material sets `faceCulling = .none`.
/// The pure members (`pack`, `packedPart`, `isRenderable`, `resolvedNormals`) run on any
/// queue; the RealityKit members are main actor only.
enum ViewerRenderMesh {
    /// Bytes per vertex.
    static let vertexStride = 32
    /// Byte offset of the position.
    static let positionOffset = 0
    /// Byte offset of the normal.
    static let normalOffset = 12
    /// Byte offset of the first texture coordinate.
    static let uvOffset = 24
    /// Floats per vertex (stride / 4).
    static let floatsPerVertex = 8
    /// Color used when a texture page cannot be loaded.
    static let missingTextureColor = SIMD4<Float>(0.7, 0.7, 0.7, 1)

    /// True when the part can be drawn: at least one whole triangle, a multiple of 3 indices
    /// and every index in range. Empty and broken parts are skipped by the viewer.
    static func isRenderable(_ part: ViewerPart) -> Bool {
        let count = part.indices.count
        guard !part.positions.isEmpty, count >= 3, count % 3 == 0 else { return false }
        let limit = UInt32(clamping: part.positions.count)
        return part.indices.allSatisfy { $0 < limit }
    }

    /// Interleaved vertex bytes of `part`: 32 bytes per vertex, position at 0, normal at 12,
    /// uv at 24 (little-endian Float). Normals come from `resolvedNormals`; uvs are zero unless
    /// there is exactly one per vertex. An empty part gives empty data.
    static func pack(_ part: ViewerPart) -> Data {
        let vertexCount = part.positions.count
        guard vertexCount > 0 else { return Data() }
        let normals = resolvedNormals(part)
        let hasUVs = part.uvs.count == vertexCount
        var floats = [Float](repeating: 0, count: vertexCount * floatsPerVertex)
        for i in 0..<vertexCount {
            let base = i * floatsPerVertex
            let p = part.positions[i]
            floats[base] = p.x
            floats[base + 1] = p.y
            floats[base + 2] = p.z
            let n = normals[i]
            floats[base + 3] = n.x
            floats[base + 4] = n.y
            floats[base + 5] = n.z
            if hasUVs {
                let uv = part.uvs[i]
                floats[base + 6] = uv.x
                floats[base + 7] = uv.y
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// One unit normal per vertex. Given normals are used (normalized) when there is exactly
    /// one per vertex; zero or non-finite entries, and all entries when the count differs,
    /// are replaced by area-weighted normals computed from the part's triangles.
    static func resolvedNormals(_ part: ViewerPart) -> [SIMD3<Float>] {
        let count = part.positions.count
        guard part.normals.count == count else { return computedNormals(part) }
        var result = part.normals
        var missing = false
        for i in 0..<count {
            let n = result[i]
            let length = simd_length(n)
            if length > 1e-12 && length.isFinite {
                result[i] = n / length
            } else {
                result[i] = SIMD3<Float>(0, 0, 0)
                missing = true
            }
        }
        guard missing else { return result }
        let computed = computedNormals(part)
        for i in 0..<count where result[i] == SIMD3<Float>(0, 0, 0) {
            result[i] = computed[i]
        }
        return result
    }

    /// Area-weighted vertex normals of the part's triangles (out-of-range triangles skipped).
    static func computedNormals(_ part: ViewerPart) -> [SIMD3<Float>] {
        TriangleMesh(positions: part.positions, indices: part.indices).vertexNormals
    }

    /// The packed form of `part`, or nil when it is not renderable.
    static func packedPart(_ part: ViewerPart) -> ViewerPackedPart? {
        guard isRenderable(part) else { return nil }
        var box = AABB3.empty
        for p in part.positions where p.x.isFinite && p.y.isFinite && p.z.isFinite {
            box.expand(p)
        }
        if box.isEmpty {
            box = AABB3(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(0, 0, 0))
        }
        return ViewerPackedPart(id: part.id, layer: part.layer, material: part.material, vertexData: pack(part),
                                indices: part.indices, vertexCount: part.positions.count,
                                boundsMin: box.min, boundsMax: box.max)
    }

    /// Creates the entity for a packed part: a `LowLevelMesh` with the interleaved layout, the
    /// bytes copied in, one part, then `try await MeshResource(from:)`. Main actor.
    @MainActor
    static func makeEntity(_ packed: ViewerPackedPart, material: any RealityKit.Material) async throws -> ModelEntity {
        let attributes: [LowLevelMesh.Attribute] = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, layoutIndex: 0, offset: positionOffset),
            LowLevelMesh.Attribute(semantic: .normal, format: .float3, layoutIndex: 0, offset: normalOffset),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, layoutIndex: 0, offset: uvOffset),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            LowLevelMesh.Layout(bufferIndex: 0, bufferOffset: 0, bufferStride: vertexStride),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: packed.vertexCount,
                                                 vertexAttributes: attributes,
                                                 vertexLayouts: layouts,
                                                 indexCapacity: packed.indices.count,
                                                 indexType: .uint32)
        let lowLevelMesh = try LowLevelMesh(descriptor: descriptor)
        let vertexData = packed.vertexData
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { destination in
            vertexData.withUnsafeBytes { source in
                ViewerRenderMesh.copyRaw(from: source, to: destination)
            }
        }
        let indices = packed.indices
        lowLevelMesh.withUnsafeMutableIndices { destination in
            indices.withUnsafeBytes { source in
                ViewerRenderMesh.copyRaw(from: source, to: destination)
            }
        }
        let bounds = BoundingBox(min: packed.boundsMin, max: packed.boundsMax)
        let part = LowLevelMesh.Part(indexOffset: 0, indexCount: packed.indices.count, topology: .triangle,
                                     materialIndex: 0, bounds: bounds)
        lowLevelMesh.parts.replaceAll([part])
        let resource = try await MeshResource(from: lowLevelMesh)
        let entity = ModelEntity(mesh: resource, materials: [material])
        entity.name = packed.id
        return entity
    }

    /// The RealityKit material for `material`, always with `faceCulling = .none`. Texture
    /// materials use `textures[url]`; a missing texture falls back to a gray lit material.
    @MainActor
    static func makeMaterial(_ material: ViewerMaterial, textures: [URL: TextureResource]) -> any RealityKit.Material {
        switch material {
        case .unlit(let c):
            var m = UnlitMaterial(color: uiColor(c))
            m.faceCulling = .none
            if c.w < 0.999 {
                m.blending = .transparent(opacity: .init(floatLiteral: Swift.max(c.w, 0)))
            }
            return m
        case .lit(let c):
            var m = SimpleMaterial(color: uiColor(c), roughness: 0.85, isMetallic: false)
            m.faceCulling = .none
            return m
        case .wireframe(let c):
            var m = UnlitMaterial(color: uiColor(c))
            m.triangleFillMode = .lines
            m.faceCulling = .none
            return m
        case .translucent(let c):
            var m = UnlitMaterial(color: uiColor(c))
            m.blending = .transparent(opacity: .init(floatLiteral: Swift.min(Swift.max(c.w, 0), 1)))
            m.faceCulling = .none
            return m
        case .texture(let url):
            if let texture = textures[url] {
                var m = UnlitMaterial(texture: texture)
                m.faceCulling = .none
                return m
            }
            var m = SimpleMaterial(color: uiColor(missingTextureColor), roughness: 0.85, isMetallic: false)
            m.faceCulling = .none
            return m
        }
    }

    /// Loads a JPEG atlas page: ImageIO decode off the main actor, then
    /// `TextureResource(image:withName:options:)` with semantic `.color` on main. Nil (logged)
    /// when the file is missing or unreadable.
    @MainActor
    static func loadTexture(_ url: URL) async -> TextureResource? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> ViewerCGImage? in
            ViewerImages.decodedImage(at: url)
        }.value
        guard let image = decoded?.image else {
            LogStore.shared.write("texture unreadable: \(url.lastPathComponent)", category: "viewer")
            return nil
        }
        do {
            let options = TextureResource.CreateOptions(semantic: .color)
            return try await TextureResource(image: image, withName: url.lastPathComponent, options: options)
        } catch {
            LogStore.shared.write("texture failed: \(url.lastPathComponent): \(error)", category: "viewer")
            return nil
        }
    }

    /// Opaque `UIColor` from the RGB of a 0...1 color (alpha is handled by blending).
    static func uiColor(_ c: SIMD4<Float>) -> UIColor {
        UIColor(red: CGFloat(clamp01(c.x)), green: CGFloat(clamp01(c.y)), blue: CGFloat(clamp01(c.z)), alpha: 1)
    }

    /// `value` clamped to 0...1 (0 when not finite).
    private static func clamp01(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    /// Copies as many bytes as both buffers hold from `source` to `destination`.
    static func copyRaw(from source: UnsafeRawBufferPointer, to destination: UnsafeMutableRawBufferPointer) {
        let count = Swift.min(source.count, destination.count)
        guard count > 0, let from = source.baseAddress, let to = destination.baseAddress else { return }
        to.copyMemory(from: from, byteCount: count)
    }
}
