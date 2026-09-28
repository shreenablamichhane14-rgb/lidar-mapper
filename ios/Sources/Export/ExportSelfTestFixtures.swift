import Foundation
import simd
import UIKit

/// Fixtures and small binary readers used by `ExportSelfTest`.
extension ExportSelfTest {
    /// One file read back from a ZIP archive.
    struct ZipEntry {
        /// Entry name from the central directory.
        var name: String
        /// Stored bytes.
        var data: Data
        /// Offset of the first data byte in the archive.
        var dataOffset: Int
    }

    /// A tiny JPEG (8 x 8 px) drawn with UIGraphicsImageRenderer.
    static func tinyJPEG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    /// Unit cube centered at `center`: 24 vertices (4 per face, so normals and UVs are
    /// per face), 12 counter-clockwise triangles, normals, UVs and colors.
    static func cubeMesh(name: String = "Cube", center: SIMD3<Float> = .zero, materialIndex: Int? = 0) -> ExportMesh {
        let faceNormals: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
                                           SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var colors: [SIMD4<UInt8>] = []
        var indices: [UInt32] = []
        let corners: [SIMD2<Float>] = [SIMD2(-0.5, -0.5), SIMD2(0.5, -0.5), SIMD2(0.5, 0.5), SIMD2(-0.5, 0.5)]
        for (face, n) in faceNormals.enumerated() {
            let u: SIMD3<Float> = abs(n.y) > 0.5 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let v = simd_cross(n, u)
            let base = UInt32(positions.count)
            for corner in corners {
                let inPlane: SIMD3<Float> = u * corner.x + v * corner.y
                positions.append(center + n * 0.5 + inPlane)
                normals.append(n)
                texcoords.append(corner + SIMD2<Float>(0.5, 0.5))
                colors.append(SIMD4<UInt8>(UInt8(40 * face), 128, 255, 255))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        return ExportMesh(name: name, positions: positions, normals: normals, texcoords: texcoords,
                          colors: colors, indices: indices, materialIndex: materialIndex)
    }

    /// Scene with one textured cube and one material whose texture is "cube.jpg".
    static func cubeScene(jpeg: Data) -> ExportScene {
        let material = ExportMaterial(name: "Cube material", baseColor: SIMD4<Float>(1, 1, 1, 1), textureJPEG: jpeg, textureName: "cube.jpg")
        return ExportScene(meshes: [cubeMesh()], materials: [material], metadata: ["project": "Self test"])
    }

    /// Two rooms side by side (4 x 3 m and 3 x 3 m) with a door arc, a column, two
    /// room names and two dimensions: 9 entities on 4 layers.
    static func twoRoomPlan() -> Plan2D {
        let layers = [
            Plan2D.Layer(name: "Walls", color: SIMD3<Float>(0, 0, 0)),
            Plan2D.Layer(name: "Doors", color: SIMD3<Float>(1, 0, 0)),
            Plan2D.Layer(name: "Room names", color: SIMD3<Float>(0, 0, 1)),
            Plan2D.Layer(name: "Dimensions", color: SIMD3<Float>(0, 0.6, 0)),
        ]
        let entities = [
            Plan2D.Entity(layer: "Walls", geometry: .polyline(points: [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 3), SIMD2(0, 3)], closed: true)),
            Plan2D.Entity(layer: "Walls", geometry: .polyline(points: [SIMD2(4, 0), SIMD2(7, 0), SIMD2(7, 3), SIMD2(4, 3)], closed: true)),
            Plan2D.Entity(layer: "Walls", geometry: .line(from: SIMD2(4, 1), to: SIMD2(4, 2))),
            Plan2D.Entity(layer: "Doors", geometry: .arc(center: SIMD2(4, 1), radius: 0.8, startAngle: 0, endAngle: Double.pi / 2)),
            Plan2D.Entity(layer: "Walls", geometry: .circle(center: SIMD2(6.5, 2.5), radius: 0.15)),
            Plan2D.Entity(layer: "Room names", geometry: .text(position: SIMD2(1, 1.5), height: 0.25, string: "Kitchen & <Dining>", rotation: 0)),
            Plan2D.Entity(layer: "Room names", geometry: .text(position: SIMD2(5, 1.5), height: 0.25, string: "Bath 90\u{00B0}", rotation: Double.pi / 2)),
            Plan2D.Entity(layer: "Dimensions", geometry: .dimension(from: SIMD2(0, 0), to: SIMD2(4, 0), offset: -0.5, label: "13' 1 1/2\"")),
            Plan2D.Entity(layer: "Dimensions", geometry: .dimension(from: SIMD2(7, 0), to: SIMD2(7, 3), offset: -0.5, label: "3.000 m")),
        ]
        return Plan2D(name: "Two rooms", layers: layers, entities: entities)
    }

    /// Little-endian UInt16 at `offset`, or nil when out of range.
    static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    /// Little-endian UInt32 at `offset`, or nil when out of range.
    static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for k in 0..<4 {
            value |= UInt32(bytes[offset + k]) << UInt32(8 * k)
        }
        return value
    }

    /// Little-endian Float32 at `offset`, or nil when out of range.
    static func readFloat32(_ bytes: [UInt8], _ offset: Int) -> Float? {
        readUInt32(bytes, offset).map { Float(bitPattern: $0) }
    }

    /// Parses a stored ZIP through its end record and central directory, checking
    /// every local header and CRC. Problems are appended to `problems`.
    static func readZip(_ archive: Data, problems: inout [String]) -> [ZipEntry] {
        let bytes = [UInt8](archive)
        var eocd = -1
        var i = bytes.count - 22
        while i >= 0 {
            if readUInt32(bytes, i) == 0x0605_4B50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0, let count = readUInt16(bytes, eocd + 10), let directoryOffset = readUInt32(bytes, eocd + 16) else {
            problems.append("zip: no end of central directory record")
            return []
        }
        var entries: [ZipEntry] = []
        var cursor = Int(directoryOffset)
        for _ in 0..<count {
            guard readUInt32(bytes, cursor) == 0x0201_4B50,
                  let crc = readUInt32(bytes, cursor + 16), let size = readUInt32(bytes, cursor + 24),
                  let nameLength = readUInt16(bytes, cursor + 28), let extraLength = readUInt16(bytes, cursor + 30),
                  let commentLength = readUInt16(bytes, cursor + 32), let localOffset = readUInt32(bytes, cursor + 42),
                  cursor + 46 + nameLength <= bytes.count else {
                problems.append("zip: bad central directory entry at \(cursor)")
                return entries
            }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            let local = Int(localOffset)
            guard readUInt32(bytes, local) == 0x0403_4B50, readUInt16(bytes, local + 8) == 0,
                  let localNameLength = readUInt16(bytes, local + 26), let localExtra = readUInt16(bytes, local + 28),
                  readUInt32(bytes, local + 14) == crc else {
                problems.append("zip: bad local header for \(name)")
                return entries
            }
            let localName = String(decoding: bytes[min(local + 30, bytes.count)..<min(local + 30 + localNameLength, bytes.count)], as: UTF8.self)
            if localName != name { problems.append("zip: local name \(localName) differs from \(name)") }
            let start = local + 30 + localNameLength + localExtra
            guard start + Int(size) <= bytes.count else {
                problems.append("zip: data of \(name) runs past the end")
                return entries
            }
            let data = Data(bytes[start..<(start + Int(size))])
            if CRC32.checksum(data) != crc { problems.append("zip: CRC mismatch for \(name)") }
            entries.append(ZipEntry(name: name, data: data, dataOffset: start))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Splits a GLB into its JSON object and BIN chunk, or nil when malformed.
    static func readGLB(_ glb: Data) -> (header: [UInt32], json: [String: Any], bin: [UInt8], jsonLength: Int)? {
        let bytes = [UInt8](glb)
        guard let magic = readUInt32(bytes, 0), let version = readUInt32(bytes, 4), let length = readUInt32(bytes, 8),
              let jsonLength = readUInt32(bytes, 12), readUInt32(bytes, 16) == GLBWriter.jsonChunkType else { return nil }
        let jsonEnd = 20 + Int(jsonLength)
        guard jsonEnd + 8 <= bytes.count, let binLength = readUInt32(bytes, jsonEnd),
              readUInt32(bytes, jsonEnd + 4) == GLBWriter.binChunkType, jsonEnd + 8 + Int(binLength) <= bytes.count,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes[20..<jsonEnd])),
              let json = object as? [String: Any] else { return nil }
        let bin = Array(bytes[(jsonEnd + 8)..<(jsonEnd + 8 + Int(binLength))])
        return ([magic, version, length], json, bin, Int(jsonLength))
    }

    /// Counts non-overlapping occurrences of `needle` in `text`.
    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
