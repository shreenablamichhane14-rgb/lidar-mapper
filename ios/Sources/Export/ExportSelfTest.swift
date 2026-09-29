import Foundation
import simd

/// Plain-Swift checks for the export writers (no XCTest), meant to run at launch in
/// debug builds. `run()` returns one line per failing check; empty means all passed.
/// Fixtures: a textured unit cube (24 vertices, 12 triangles, 8 x 8 JPEG) and a
/// two-room plan (see ExportSelfTestFixtures.swift).
enum ExportSelfTest {
    /// Collects results.
    struct Checker {
        /// Failure lines.
        var failures: [String] = []
        /// Number of checks run.
        var count = 0

        /// Records a check; `detail` is only evaluated on failure.
        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition {
                let text = detail()
                failures.append(text.isEmpty ? name : "\(name): \(text)")
            }
        }

        /// Records a check that failed because `error` was thrown.
        mutating func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): threw \(error.localizedDescription)")
        }

        /// Runs `body` and expects an `ExportError` accepted by `matches`.
        mutating func expectError(_ name: String, _ body: () throws -> Void, _ matches: (ExportError) -> Bool) {
            do {
                try body()
                check(name, false, "did not throw")
            } catch let error as ExportError {
                check(name, matches(error), "threw \(error)")
            } catch {
                check(name, false, "unexpected error \(error)")
            }
        }
    }

    /// Runs every check; returns failure lines (empty = pass).
    static func run() -> [String] {
        var c = Checker()
        let jpeg = tinyJPEG()
        let scene = cubeScene(jpeg: jpeg)
        let plan = twoRoomPlan()
        checkBasics(&c)
        checkValidation(&c, scene: scene)
        checkZip(&c)
        checkOBJ(&c, scene: scene, jpeg: jpeg)
        checkPLYAndSTL(&c, scene: scene)
        checkGLB(&c, scene: scene, jpeg: jpeg)
        checkUSDZ(&c, scene: scene, jpeg: jpeg)
        checkPlan(&c, plan: plan)
        checkDXF(&c, plan: plan)
        checkDXFMillimeters(&c, plan: plan)
        checkSVGAndPDF(&c, plan: plan)
        if c.count < 50 { c.failures.append("only \(c.count) checks ran") }
        return c.failures
    }

    private static func checkBasics(_ c: inout Checker) {
        var w = ByteWriter()
        w.appendUInt32(0x0102_0304)
        w.appendUInt16(0x0A0B)
        w.appendFloat32(1)
        w.appendUInt8(7)
        c.check("bytes.littleEndian", [UInt8](w.data) == [4, 3, 2, 1, 0x0B, 0x0A, 0, 0, 0x80, 0x3F, 7], "\([UInt8](w.data))")
        w.align(to: 4)
        c.check("bytes.align", w.count == 12, "\(w.count)")
        var h = ByteWriter()
        h.appendFixedString("abc", length: 5, padding: 0x20)
        c.check("bytes.fixedString", [UInt8](h.data) == [97, 98, 99, 32, 32])
        c.check("text.numberTrim", ExportText.number(1.5) == "1.5", ExportText.number(1.5))
        c.check("text.numberInteger", ExportText.number(2.0) == "2")
        c.check("text.numberNegativeZero", ExportText.number(-0.0000001) == "0", ExportText.number(-0.0000001))
        c.check("text.numberPlaces", ExportText.number(0.1234567, places: 3) == "0.123")
        c.check("text.fileName", ExportText.fileName("My Room.JPG", fallback: "t", ext: "jpg") == "My_Room.jpg")
        let unique = ExportText.uniqued(["a.jpg", "A.jpg", "a.jpg"])
        c.check("text.uniqued", unique == ["a.jpg", "A_2.jpg", "a_3.jpg"], "\(unique)")
        c.check("text.identifier", ExportText.identifier("3 walls", fallback: "x") == "_3_walls")
        let textured = ExportMaterial(name: "A", textureJPEG: Data([1]), textureName: "cube.jpg")
        let names = ExportText.textureFileNames(for: [textured, ExportMaterial(name: "B"), textured])
        c.check("text.textureNames", names == ["cube.jpg", nil, "cube_2.jpg"], "\(names)")
    }

    private static func checkValidation(_ c: inout Checker, scene: ExportScene) {
        do {
            try scene.validate()
            c.check("validate.cubePasses", true)
        } catch {
            c.fail("validate.cubePasses", error)
        }
        var bad = cubeMesh()
        bad.indices[5] = 99
        c.expectError("validate.indexOutOfRange", { try bad.validate() }) {
            if case .indexOutOfRange(_, 99, 24) = $0 { return true }
            return false
        }
        var fewNormals = cubeMesh()
        fewNormals.normals?.removeLast()
        c.expectError("validate.normalCount", { try fewNormals.validate() }) {
            if case .attributeCountMismatch(_, "normals", 24, 23) = $0 { return true }
            return false
        }
        var fewColors = cubeMesh()
        fewColors.colors?.append(SIMD4<UInt8>(0, 0, 0, 0))
        c.expectError("validate.colorCount", { try fewColors.validate() }) {
            if case .attributeCountMismatch(_, "colors", 24, 25) = $0 { return true }
            return false
        }
        var partial = cubeMesh()
        partial.indices.removeLast()
        c.expectError("validate.notTriangles", { try partial.validate() }) {
            if case .indexCountNotMultipleOfThree = $0 { return true }
            return false
        }
        var nan = cubeMesh()
        nan.positions[3].y = .nan
        c.expectError("validate.nan", { try nan.validate() }) {
            if case .nonFiniteValue = $0 { return true }
            return false
        }
        let wrongMaterial = ExportScene(meshes: [cubeMesh(materialIndex: 5)])
        c.expectError("validate.materialIndex", { try wrongMaterial.validate() }) {
            if case .invalidMaterialIndex = $0 { return true }
            return false
        }
        c.expectError("validate.emptyScene", { try ExportScene(meshes: []).validate() }) {
            if case .emptyScene = $0 { return true }
            return false
        }
        c.check("validate.message", (ExportError.emptyScene.errorDescription ?? "").isEmpty == false)
    }

    private static func checkZip(_ c: inout Checker) {
        c.check("crc.check", CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        c.check("crc.empty", CRC32.checksum(Data()) == 0)
        let fox = Data("The quick brown fox jumps over the lazy dog".utf8)
        c.check("crc.fox", CRC32.checksum(fox) == 0x414F_A339)
        c.check("crc.running", CRC32.checksum(fox.suffix(from: 10), previous: CRC32.checksum(fox.prefix(10))) == 0x414F_A339)

        let input: [(name: String, data: Data)] = [
            ("hello.txt", Data("Hello".utf8)),
            ("dir/\u{00E9}t\u{00E9}.bin", Data((0..<200).map { UInt8($0) })),
            ("empty", Data()),
        ]
        for alignment in [1, 64] {
            do {
                let archive = try ZipWriter.archive(input, alignment: alignment)
                var problems: [String] = []
                let entries = readZip(archive, problems: &problems)
                c.check("zip.parse.\(alignment)", problems.isEmpty, problems.joined(separator: "; "))
                c.check("zip.names.\(alignment)", entries.map { $0.name } == input.map { $0.name }, "\(entries.map { $0.name })")
                c.check("zip.bytes.\(alignment)", entries.map { $0.data } == input.map { $0.data })
                if alignment > 1 {
                    c.check("zip.aligned", entries.allSatisfy { $0.dataOffset % alignment == 0 }, "\(entries.map { $0.dataOffset })")
                }
            } catch {
                c.fail("zip.roundTrip.\(alignment)", error)
            }
        }
        c.expectError("zip.duplicate", {
            var writer = ZipWriter()
            try writer.add(name: "a", data: Data())
            try writer.add(name: "a", data: Data())
        }) {
            if case .invalidArchiveEntry = $0 { return true }
            return false
        }
        c.expectError("zip.absolute", { _ = try ZipWriter.archive([(name: "/etc/x", data: Data())]) }) {
            if case .invalidArchiveEntry = $0 { return true }
            return false
        }
    }

    private static func checkOBJ(_ c: inout Checker, scene: ExportScene, jpeg: Data) {
        do {
            let files = try OBJWriter.files(for: scene)
            c.check("obj.fileNames", files.map { $0.name } == ["model.obj", "model.mtl", "cube.jpg"], "\(files.map { $0.name })")
            let obj = String(decoding: files[0].data, as: UTF8.self)
            let mtl = String(decoding: files[1].data, as: UTF8.self)
            let lines = obj.split(separator: "\n").map(String.init)
            let faces = lines.filter { $0.hasPrefix("f ") }
            c.check("obj.faceCount", faces.count == 12, "\(faces.count)")
            c.check("obj.firstFace", faces.first == "f 1/1/1 2/2/2 3/3/3", faces.first ?? "none")
            let faceIndices = faces.flatMap { $0.split(separator: " ").dropFirst().flatMap { $0.split(separator: "/") } }.compactMap { Int($0) }
            c.check("obj.oneBased", faceIndices.count == 108 && faceIndices.allSatisfy { $0 >= 1 && $0 <= 24 }, "\(faceIndices.count)")
            let vertices = lines.filter { $0.hasPrefix("v ") }
            c.check("obj.vertexColors", vertices.count == 24 && vertices.allSatisfy { $0.split(separator: " ").count == 7 })
            c.check("obj.vtVn", lines.filter { $0.hasPrefix("vt ") }.count == 24 && lines.filter { $0.hasPrefix("vn ") }.count == 24)
            c.check("obj.headers", obj.contains("mtllib model.mtl\n") && obj.contains("o Cube\n") && obj.contains("usemtl Cube_material\n"))
            c.check("obj.mtl", mtl.contains("newmtl Cube_material\n") && mtl.contains("map_Kd cube.jpg\n") && mtl.contains("Kd 1 1 1\n"))
            c.check("obj.texture", files[2].data == jpeg)

            var plain = cubeMesh(name: "Second", center: SIMD3<Float>(2, 0, 0), materialIndex: nil)
            plain.texcoords = nil
            plain.normals = nil
            plain.colors = nil
            var two = scene
            two.meshes.append(plain)
            let twoText = OBJWriter.objText(for: two, mtlFileName: "m.mtl")
            c.check("obj.secondMeshOffset", twoText.contains("o Second\n") && twoText.contains("\nf 25 26 27\n"))
            c.check("obj.faceForms", OBJWriter.faceVertex(v: 1, vt: nil, vn: nil) == "1" && OBJWriter.faceVertex(v: 1, vt: 2, vn: nil) == "1/2"
                    && OBJWriter.faceVertex(v: 1, vt: nil, vn: 3) == "1//3" && OBJWriter.faceVertex(v: 1, vt: 2, vn: 3) == "1/2/3")

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-selftest-\(UUID().uuidString)")
            let urls = try OBJWriter.write(scene, to: folder, baseName: "room")
            c.check("obj.writeFolder", urls.map { $0.lastPathComponent } == ["room.obj", "room.mtl", "cube.jpg"]
                    && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            try? FileManager.default.removeItem(at: folder)

            var problems: [String] = []
            let bundle = readZip(try OBJWriter.zipBundle(for: scene), problems: &problems)
            c.check("obj.zipBundle", problems.isEmpty && bundle.map { $0.name } == ["model.obj", "model.mtl", "cube.jpg"])
        } catch {
            c.fail("obj", error)
        }
    }

    private static func checkPLYAndSTL(_ c: inout Checker, scene: ExportScene) {
        let expectedHeader = "ply\nformat binary_little_endian 1.0\ncomment Mapper export, units meters, Y up\nelement vertex 24\n"
            + "property float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\n"
            + "property uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar alpha\n"
            + "element face 12\nproperty list uchar uint vertex_indices\nend_header\n"
        do {
            let ply = try PLYWriter.data(for: scene)
            let bytes = [UInt8](ply)
            c.check("ply.header", ply.prefix(349) == Data(expectedHeader.utf8), String(decoding: ply.prefix(349), as: UTF8.self))
            c.check("ply.size", ply.count == 349 + 24 * 28 + 12 * 13, "\(ply.count)")
            c.check("ply.firstVertex", readFloat32(bytes, 349) == scene.meshes[0].positions[0].x)
            let face = 349 + 24 * 28
            c.check("ply.firstFace", bytes[face] == 3 && readUInt32(bytes, face + 1) == 0 && readUInt32(bytes, face + 5) == 1 && readUInt32(bytes, face + 9) == 2)

            let ascii = String(decoding: try PLYWriter.data(for: scene, encoding: .ascii), as: UTF8.self)
            let lines = ascii.split(separator: "\n")
            c.check("ply.ascii", ascii.hasPrefix("ply\nformat ascii 1.0\n") && lines.count == 17 + 24 + 12 && lines.last == "3 20 22 23", "\(lines.count) \(lines.last ?? "")")

            var two = scene
            two.meshes.append(cubeMesh(name: "B", center: SIMD3<Float>(3, 0, 0)))
            let merged = [UInt8](try PLYWriter.data(for: two))
            c.check("ply.mergedCounts", String(decoding: merged.prefix(349), as: UTF8.self).contains("element vertex 48\n"))
            c.check("ply.mergedOffset", readUInt32(merged, 349 + 48 * 28 + 12 * 13 + 1) == 24)
            var mixed = two
            mixed.meshes[1].normals = nil
            c.check("ply.dropsPartialNormals", PLYWriter.layout(for: mixed).normals == false && PLYWriter.layout(for: mixed).colors == true)
        } catch {
            c.fail("ply", error)
        }

        do {
            let stl = [UInt8](try STLWriter.binary(for: scene, options: .raw))
            c.check("stl.size", stl.count == 84 + 50 * 12, "\(stl.count)")
            c.check("stl.headerNotSolid", String(decoding: stl.prefix(5), as: UTF8.self) != "solid")
            c.check("stl.count", readUInt32(stl, 80) == 12)
            c.check("stl.normalRaw", readFloat32(stl, 84) == 1 && readFloat32(stl, 88) == 0 && readFloat32(stl, 92) == 0)
            c.check("stl.attribute", readUInt16(stl, 84 + 48) == 0)
            let printing = [UInt8](try STLWriter.binary(for: scene))
            // Triangle 4 is the first +Y face; Z up turns its normal into +Z, in millimeters.
            c.check("stl.zUpNormal", readFloat32(printing, 84 + 4 * 50 + 8) == 1)
            c.check("stl.millimeters", readFloat32(printing, 84 + 12) == 500, "\(readFloat32(printing, 84 + 12) ?? 0)")
            let ascii = String(decoding: try STLWriter.ascii(for: scene), as: UTF8.self)
            c.check("stl.ascii", ascii.hasPrefix("solid mapper\n") && ascii.hasSuffix("endsolid mapper\n") && occurrences(of: "facet normal", in: ascii) == 12)
        } catch {
            c.fail("stl", error)
        }
    }

    private static func checkGLB(_ c: inout Checker, scene: ExportScene, jpeg: Data) {
        let glb: Data
        do {
            glb = try GLBWriter.data(for: scene)
        } catch {
            c.fail("glb", error)
            return
        }
        guard let parsed = readGLB(glb) else {
            c.check("glb.parse", false, "could not split chunks or parse JSON")
            return
        }
        c.check("glb.header", parsed.header == [GLBWriter.magic, 2, UInt32(glb.count)], "\(parsed.header)")
        c.check("glb.jsonPadded", parsed.jsonLength % 4 == 0 && parsed.bin.count % 4 == 0)
        let json = parsed.json
        let asset = json["asset"] as? [String: Any]
        c.check("glb.asset", asset?["version"] as? String == "2.0" && asset?["generator"] as? String == "Mapper")
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        c.check("glb.accessorCount", accessors.count == 5, "\(accessors.count)")
        c.check("glb.viewCount", views.count == 6, "\(views.count)")
        c.check("glb.viewsAligned", views.allSatisfy { (($0["byteOffset"] as? Int) ?? 1) % 4 == 0 })
        c.check("glb.viewsInside", views.allSatisfy { (($0["byteOffset"] as? Int) ?? 0) + (($0["byteLength"] as? Int) ?? parsed.bin.count + 1) <= parsed.bin.count })
        let buffers = json["buffers"] as? [[String: Any]] ?? []
        c.check("glb.bufferLength", buffers.count == 1 && buffers.first?["byteLength"] as? Int == parsed.bin.count)

        let primitive = ((json["meshes"] as? [[String: Any]])?.first?["primitives"] as? [[String: Any]])?.first
        let attributes = primitive?["attributes"] as? [String: Int] ?? [:]
        c.check("glb.attributes", Set(attributes.keys) == ["POSITION", "NORMAL", "TEXCOORD_0", "COLOR_0"], "\(attributes.keys.sorted())")
        if let p = attributes["POSITION"], p < accessors.count {
            let accessor = accessors[p]
            let minValues = accessor["min"] as? [Double] ?? []
            let maxValues = accessor["max"] as? [Double] ?? []
            c.check("glb.positionMinMax", minValues == [-0.5, -0.5, -0.5] && maxValues == [0.5, 0.5, 0.5], "\(minValues) \(maxValues)")
            c.check("glb.positionType", accessor["componentType"] as? Int == 5126 && accessor["type"] as? String == "VEC3" && accessor["count"] as? Int == 24)
            if let viewIndex = accessor["bufferView"] as? Int, viewIndex < views.count, let offset = views[viewIndex]["byteOffset"] as? Int {
                var lo = Float.greatestFiniteMagnitude
                var hi = -Float.greatestFiniteMagnitude
                for i in 0..<72 {
                    let value = readFloat32(parsed.bin, offset + 4 * i) ?? .nan
                    lo = min(lo, value)
                    hi = max(hi, value)
                }
                c.check("glb.minMaxMatchData", Double(lo) == minValues.min() && Double(hi) == maxValues.max())
            }
        } else {
            c.check("glb.position", false, "no POSITION accessor")
        }
        if let color = attributes["COLOR_0"], color < accessors.count {
            let accessor = accessors[color]
            c.check("glb.color", accessor["componentType"] as? Int == 5121 && accessor["normalized"] as? Bool == true && accessor["type"] as? String == "VEC4")
        }
        if let uv = attributes["TEXCOORD_0"], uv < accessors.count, let viewIndex = accessors[uv]["bufferView"] as? Int,
           viewIndex < views.count, let offset = views[viewIndex]["byteOffset"] as? Int {
            c.check("glb.uvFlipped", readFloat32(parsed.bin, offset + 4) == 1 - (scene.meshes[0].texcoords?.first?.y ?? 0))
        }
        if let indices = primitive?["indices"] as? Int, indices < accessors.count {
            c.check("glb.indices", accessors[indices]["componentType"] as? Int == 5125 && accessors[indices]["count"] as? Int == 36)
        }
        let images = json["images"] as? [[String: Any]] ?? []
        c.check("glb.image", images.count == 1 && images.first?["mimeType"] as? String == "image/jpeg")
        if let viewIndex = images.first?["bufferView"] as? Int, viewIndex < views.count,
           let offset = views[viewIndex]["byteOffset"] as? Int, let length = views[viewIndex]["byteLength"] as? Int,
           offset >= 0, length >= 0, offset + length <= parsed.bin.count {
            c.check("glb.imageBytes", Data(parsed.bin[offset..<(offset + length)]) == jpeg)
        }
        let material = (json["materials"] as? [[String: Any]])?.first?["pbrMetallicRoughness"] as? [String: Any]
        c.check("glb.material", (material?["baseColorTexture"] as? [String: Any])?["index"] as? Int == 0 && material?["baseColorFactor"] as? [Double] == [1, 1, 1, 1])
        c.check("glb.sampler", (json["samplers"] as? [[String: Any]])?.count == 1 && (json["nodes"] as? [[String: Any]])?.count == 1 && json["scene"] as? Int == 0)
    }

    private static func checkUSDZ(_ c: inout Checker, scene: ExportScene, jpeg: Data) {
        do {
            let usdz = try USDZWriter.data(for: scene)
            var problems: [String] = []
            let entries = readZip(usdz, problems: &problems)
            c.check("usdz.parse", problems.isEmpty && entries.count == 2, problems.joined(separator: "; "))
            c.check("usdz.firstIsLayer", entries.first?.name == "model.usda")
            c.check("usdz.texture", entries.count == 2 && entries[1].name == "textures/cube.jpg" && entries[1].data == jpeg)
            c.check("usdz.aligned64", entries.allSatisfy { $0.dataOffset % 64 == 0 }, "\(entries.map { $0.dataOffset })")
            let usda = entries.first.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
            c.check("usda.header", usda.hasPrefix("#usda 1.0\n") && usda.contains("metersPerUnit = 1\n") && usda.contains("upAxis = \"Y\"\n") && usda.contains("defaultPrim = \"Root\""))
            c.check("usda.shaders", usda.contains("\"UsdPreviewSurface\"") && usda.contains("\"UsdUVTexture\"") && usda.contains("\"UsdPrimvarReader_float2\""))
            c.check("usda.textureAsset", usda.contains("asset inputs:file = @textures/cube.jpg@"))
            let counts = "int[] faceVertexCounts = [" + Array(repeating: "3", count: 12).joined(separator: ", ") + "]"
            c.check("usda.faces", usda.contains(counts) && usda.contains("int[] faceVertexIndices = [0, 1, 2, 0, 2, 3, "))
            c.check("usda.primvars", usda.contains("texCoord2f[] primvars:st = [") && usda.contains("color3f[] primvars:displayColor = [") && usda.contains("normal3f[] normals = ["))
            c.check("usda.binding", usda.contains("rel material:binding = </Root/Materials/Cube_material>") && usda.contains("prepend apiSchemas = [\"MaterialBindingAPI\"]"))
            c.check("usda.balanced", occurrences(of: "{", in: usda) == occurrences(of: "}", in: usda) && occurrences(of: "[", in: usda) == occurrences(of: "]", in: usda))
            c.check("usda.metadata", usda.contains("string project = \"Self test\""))
        } catch {
            c.fail("usdz", error)
        }
    }

    private static func checkPlan(_ c: inout Checker, plan: Plan2D) {
        let horizontal = plan.dimensionLayout(from: SIMD2(0, 0), to: SIMD2(4, 0), offset: -0.5)
        c.check("plan.dimensionLine", horizontal?.dimensionLine.a == SIMD2<Double>(0, -0.5) && horizontal?.dimensionLine.b == SIMD2<Double>(4, -0.5))
        c.check("plan.dimensionTextOutside", (horizontal?.textAnchor.y ?? 0) < -0.5 && horizontal?.textAngle == 0)
        let vertical = plan.dimensionLayout(from: SIMD2(7, 0), to: SIMD2(7, 3), offset: -0.5)
        c.check("plan.dimensionVertical", abs((vertical?.dimensionLine.a.x ?? 0) - 7.5) < 1e-9)
        c.check("plan.dimensionDegenerate", plan.dimensionLayout(from: SIMD2(1, 1), to: SIMD2(1, 1), offset: 1) == nil)
        let bounds = plan.bounds()
        c.check("plan.bounds", (bounds?.min.x ?? 1) <= 0 && (bounds?.max.x ?? 0) >= 7.5 && (bounds?.min.y ?? 0) < -0.5)
        c.check("plan.sweep", Plan2D.sweep(start: 0, end: Double.pi / 2) == Double.pi / 2 && Plan2D.sweep(start: 1, end: 1) == 2 * Double.pi)
        var extra = plan
        extra.entities.append(Plan2D.Entity(layer: "Extra", geometry: .line(from: SIMD2(0, 0), to: SIMD2(1, 1))))
        c.check("plan.undeclaredLayer", extra.resolvedLayers().count == 5 && extra.resolvedLayers().last?.name == "Extra")
    }

    private static func checkDXF(_ c: inout Checker, plan: Plan2D) {
        do {
            let dxf = try DXFWriter.text(for: plan)
            c.check("dxf.startsWithHeader", dxf.hasPrefix("  0\nSECTION\n  2\nHEADER\n  9\n$ACADVER\n  1\nAC1009\n"))
            c.check("dxf.endsWithEOF", dxf.hasSuffix("  0\nEOF\n"))
            c.check("dxf.pairs", dxf.split(separator: "\n", omittingEmptySubsequences: false).count % 2 == 1)
            c.check("dxf.layerEntries", occurrences(of: "  0\nLAYER\n", in: dxf) == 5, "\(occurrences(of: "  0\nLAYER\n", in: dxf))")
            c.check("dxf.layerNames", ["Walls", "Doors", "Room_names", "Dimensions"].allSatisfy { dxf.contains("  0\nLAYER\n  2\n\($0)\n") })
            let entities = dxf.components(separatedBy: "  2\nENTITIES\n").last ?? ""
            let expected = ["POLYLINE": 2, "VERTEX": 8, "SEQEND": 2, "ARC": 1, "CIRCLE": 1, "TEXT": 4, "LINE": 11]
            for (kind, count) in expected.sorted(by: { $0.key < $1.key }) {
                let found = occurrences(of: "  0\n\(kind)\n", in: entities)
                c.check("dxf.entity.\(kind)", found == count, "expected \(count), got \(found)")
            }
            c.check("dxf.arcDegrees", entities.contains(" 50\n0\n 51\n90\n"))
            c.check("dxf.textEncoding", entities.contains("Bath 90%%d") && DXFWriter.encodeText("\u{00E9}") == "\\U+00E9")
            c.check("dxf.aci", DXFWriter.aciColor(for: SIMD3(1, 0, 0)) == 1 && DXFWriter.aciColor(for: SIMD3(0, 0, 0)) == 7
                    && DXFWriter.aciColor(for: SIMD3(1, 1, 1)) == 7 && DXFWriter.aciColor(for: SIMD3(0, 0.6, 0)) == 3)
        } catch {
            c.fail("dxf", error)
        }
        c.expectError("dxf.emptyPlan", { _ = try DXFWriter.text(for: Plan2D(name: "x", layers: [], entities: [])) }) {
            if case .emptyPlan = $0 { return true }
            return false
        }
    }

    private static func checkSVGAndPDF(_ c: inout Checker, plan: Plan2D) {
        do {
            let svg = try SVGWriter.text(for: plan)
            c.check("svg.parses", XMLParser(data: Data(svg.utf8)).parse())
            c.check("svg.escaped", svg.contains("Kitchen &amp; &lt;Dining&gt;"))
            c.check("svg.layers", occurrences(of: "<g data-layer=", in: svg) == 4)
            c.check("svg.shapes", occurrences(of: "<polygon", in: svg) == 2 && occurrences(of: "<path ", in: svg) == 1
                    && occurrences(of: "<circle", in: svg) == 1 && occurrences(of: "<text ", in: svg) == 4)
            c.check("svg.groupsBalanced", occurrences(of: "<g", in: svg) == occurrences(of: "</g>", in: svg))
            if let bounds = plan.bounds() {
                let width = ExportText.number((bounds.max.x - bounds.min.x) * 100 + 40, places: 3)
                c.check("svg.viewBox", svg.contains("viewBox=\"0 0 \(width) "), width)
            }
            c.check("svg.colors", SVGWriter.hex(SIMD3(1, 0, 0.5)) == "#ff0080" && svg.contains("stroke=\"#ff0000\""))
            c.check("svg.escape", SVGWriter.escape("a\"b'") == "a&quot;b&apos;")
        } catch {
            c.fail("svg", error)
        }
        do {
            let letter = try PDFPlanWriter.data(for: plan)
            c.check("pdf.magic", letter.prefix(4) == Data("%PDF".utf8) && letter.count > 500)
            let a4 = try PDFPlanWriter.data(for: plan, options: PDFPlanWriter.Options(paper: .a4))
            c.check("pdf.a4", a4.prefix(4) == Data("%PDF".utf8))
        } catch {
            c.fail("pdf", error)
        }
        let area = PDFPlanWriter.drawingArea(for: .usLetter).size
        c.check("pdf.scaleQuarter", PDFPlanWriter.chooseScale(extent: SIMD2(7, 3), area: area, paper: .usLetter) == .quarterInch)
        c.check("pdf.scaleEighth", PDFPlanWriter.chooseScale(extent: SIMD2(20, 10), area: area, paper: .usLetter) == .eighthInch)
        let a4Area = PDFPlanWriter.drawingArea(for: .a4).size
        c.check("pdf.scaleMetric", PDFPlanWriter.chooseScale(extent: SIMD2(7, 3), area: a4Area, paper: .a4) == .oneToFifty)
        let fallback = PDFPlanWriter.chooseScale(extent: SIMD2(40, 20), area: area, paper: .usLetter)
        c.check("pdf.scaleFallback", fallback.ratio == 200 && fallback.label == "1:200", fallback.label)
        // Units, not paper, pick the scale when given (metric on Letter, feet on A4, large plans).
        let small = SIMD2<Double>(7, 3), large = SIMD2<Double>(40, 20)
        c.check("pdf.metricOnLetter", PDFPlanWriter.chooseScale(extent: small, area: area, paper: .usLetter, metric: true) == .oneToFifty)
        c.check("pdf.feetOnA4", PDFPlanWriter.chooseScale(extent: small, area: a4Area, paper: .a4, metric: false) == .quarterInch)
        c.check("pdf.feetLargePlan", PDFPlanWriter.chooseScale(extent: large, area: area, paper: .usLetter, metric: false) == .sixteenthInch)
        let hugeMetric = PDFPlanWriter.chooseScale(extent: large, area: area, paper: .usLetter, metric: true)
        c.check("pdf.metricFallback", !hugeMetric.imperial && hugeMetric.ratio == 200, hugeMetric.label)
        let quarterBar = PDFPlanWriter.scaleBarSegmentMeters(.quarterInch), metricBar = PDFPlanWriter.scaleBarSegmentMeters(.oneToFifty)
        c.check("pdf.scaleBars", abs(quarterBar - 2 * LengthFormat.metersPerFoot) < 1e-9 && metricBar == 1, "\(quarterBar) / \(metricBar)")
    }
}
