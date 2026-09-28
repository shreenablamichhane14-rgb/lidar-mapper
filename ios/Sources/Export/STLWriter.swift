import Foundation
import simd

/// STL for 3D printing, binary (default) or ASCII.
///
/// Binary layout: 80-byte header (never starting with "solid", so readers do not
/// mistake it for ASCII), UInt32 triangle count, then 50 bytes per triangle: facet
/// normal (3 x Float32, computed from the triangle's winding), three vertices
/// (9 x Float32) and a UInt16 attribute byte count of 0. STL has no units, colors or
/// materials; all meshes are merged.
enum STLWriter {
    /// Coordinate conversions for slicers.
    struct Options {
        /// Rotate +Y up (ARKit) to +Z up (slicers) by +90 degrees about X: (x, y, z) -> (x, -z, y).
        var zUp: Bool
        /// Multiply by 1000 so that one unit is one millimeter, which slicers assume.
        var millimeters: Bool

        /// Z up, millimeters: what 3D printing software expects.
        static let printing = Options(zUp: true, millimeters: true)
        /// Coordinates unchanged: meters, Y up.
        static let raw = Options(zUp: false, millimeters: false)
    }

    /// Binary STL. Size is always 84 + 50 * triangles.
    static func binary(for scene: ExportScene, options: Options = .printing) throws -> Data {
        try scene.validate()
        let tris = triangles(for: scene, options: options)
        guard tris.count <= Int(UInt32.max) else {
            throw ExportError.tooLarge(format: "STL", detail: "more than 4 billion triangles")
        }
        var out = ByteWriter(capacity: 84 + 50 * tris.count)
        let units = options.millimeters ? "mm" : "m"
        out.appendFixedString("Mapper binary STL, units \(units), \(options.zUp ? "Z" : "Y") up", length: 80, padding: 0x20)
        out.appendUInt32(UInt32(tris.count))
        for tri in tris {
            for v in [tri.normal, tri.a, tri.b, tri.c] {
                out.appendFloat32(v.x)
                out.appendFloat32(v.y)
                out.appendFloat32(v.z)
            }
            out.appendUInt16(0)
        }
        return out.data
    }

    /// ASCII STL ("solid name" ... "endsolid name").
    static func ascii(for scene: ExportScene, options: Options = .printing, solidName: String = "mapper") throws -> Data {
        try scene.validate()
        let name = ExportText.identifier(solidName, fallback: "mapper")
        var out = "solid \(name)\n"
        for tri in triangles(for: scene, options: options) {
            out += "  facet normal \(vec(tri.normal))\n    outer loop\n"
            out += "      vertex \(vec(tri.a))\n      vertex \(vec(tri.b))\n      vertex \(vec(tri.c))\n"
            out += "    endloop\n  endfacet\n"
        }
        out += "endsolid \(name)\n"
        return Data(out.utf8)
    }

    /// Unit normal of triangle a, b, c from its counter-clockwise winding; zero when degenerate.
    static func facetNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = simd_cross(b - a, c - a)
        let length = simd_length(n)
        guard length > 1e-12, length.isFinite else { return SIMD3<Float>(0, 0, 0) }
        return n / length
    }

    private struct Triangle {
        var normal: SIMD3<Float>
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>
    }

    private static func triangles(for scene: ExportScene, options: Options) -> [Triangle] {
        let scale: Float = options.millimeters ? 1000 : 1
        func convert(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = options.zUp ? SIMD3<Float>(p.x, -p.z, p.y) : p
            return q * scale
        }
        var result: [Triangle] = []
        result.reserveCapacity(scene.exportableMeshes.reduce(0) { $0 + $1.triangleCount })
        for mesh in scene.exportableMeshes {
            var t = 0
            while t + 2 < mesh.indices.count {
                let a = convert(mesh.positions[Int(mesh.indices[t])])
                let b = convert(mesh.positions[Int(mesh.indices[t + 1])])
                let c = convert(mesh.positions[Int(mesh.indices[t + 2])])
                result.append(Triangle(normal: facetNormal(a, b, c), a: a, b: b, c: c))
                t += 3
            }
        }
        return result
    }

    private static func vec(_ v: SIMD3<Float>) -> String {
        "\(ExportText.number(v.x)) \(ExportText.number(v.y)) \(ExportText.number(v.z))"
    }
}
