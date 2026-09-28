import CoreGraphics
import Foundation
import ImageIO
import simd

/// Files of a room's texture under `derived/rooms/<r>/texture/` (docs/MODULES.md 3.1, 3.23):
/// `page_<n>.jpg` atlas pages (JPEG quality 0.85), `textured.mchk` (the exact mesh that was
/// baked, identity transform, room id as anchor id) and `textured.tuv` (per-face page and
/// per-corner texture coordinates, format `TUV1`). Stateless and safe on any thread.
///
/// Write order makes a half-written texture invisible: `textured.tuv` is removed first and
/// written last, and `exists` needs it, so a crash or a deleted project in the middle of a
/// save never leaves a texture that `load` would mix with an older one. Folders are created
/// with `ProjectStore.ensureDirectory(_:inside:)` and files written with
/// `ProjectStore.writeData(_:to:protection:createParents: false)` (CR-6), so a save that
/// finishes after the project was deleted throws instead of recreating the package.
enum TextureStore {
    /// Mesh file name.
    static let meshFileName = "textured.mchk"
    /// Texture coordinate file name.
    static let uvFileName = "textured.tuv"
    /// Page file name prefix (`page_0.jpg`, `page_1.jpg`, ...).
    static let pagePrefix = "page_"
    /// Page file extension.
    static let pageExtension = "jpg"
    /// JPEG quality of the pages.
    static let jpegQuality: Double = 0.85
    /// Magic of the texture coordinate file.
    static let uvMagic = "TUV1"
    /// Texture coordinate format version written and accepted.
    static let uvVersion: UInt16 = 1
    /// Header bytes: magic 4, version 2, faceCount 4, pageCount 2.
    static let uvHeaderBytes = 12
    /// Bytes per face: page UInt16 plus 3 x (Float32, Float32).
    static let uvFaceBytes = 26
    /// Most pages a texture may have (the build 6 maximum is 8; this is a sanity cap).
    static let maxPages = 64
    /// `textured.tuv` larger than this is refused (about 5M faces).
    static let maxUVBytes: Int64 = 128 * 1024 * 1024
    /// `textured.mchk` larger than this is refused (same cap as MeshModel's derived meshes).
    static let maxMeshBytes: Int64 = 512 * 1024 * 1024
    /// Log category.
    static let logCategory = "texture"

    // MARK: - Paths

    /// `derived/rooms/<r>/texture/`.
    static func folder(_ package: ProjectPackage, room: UUID) -> URL {
        package.derivedRoomURL(room).appendingPathComponent(TextureDensity.textured.folderName, isDirectory: true)
    }

    /// `derived/rooms/<r>/texture/textured.mchk`.
    static func meshURL(_ package: ProjectPackage, room: UUID) -> URL {
        folder(package, room: room).appendingPathComponent(meshFileName, isDirectory: false)
    }

    /// `derived/rooms/<r>/texture/textured.tuv`.
    static func uvURL(_ package: ProjectPackage, room: UUID) -> URL {
        folder(package, room: room).appendingPathComponent(uvFileName, isDirectory: false)
    }

    /// `derived/rooms/<r>/texture/page_<n>.jpg`.
    static func pageURL(_ package: ProjectPackage, room: UUID, page: Int) -> URL {
        folder(package, room: room).appendingPathComponent(pageFileName(page), isDirectory: false)
    }

    /// `page_<n>.jpg` (n not padded).
    static func pageFileName(_ page: Int) -> String {
        pagePrefix + String(Swift.max(0, page)) + "." + pageExtension
    }

    /// The page number of a file named exactly `page_<n>.jpg` (digits only), else nil.
    static func pageNumber(fromFileName name: String) -> Int? {
        let suffix = "." + pageExtension
        guard name.hasPrefix(pagePrefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(pagePrefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: - Save

    /// Writes the pages of `result` as JPEG, then `textured.mchk` (`mesh`, which must be the
    /// exact mesh that was baked) and `textured.tuv`, and removes pages of an earlier bake
    /// beyond the new page count. Faces with `faceSource` -1, a page out of range or
    /// non-finite texture coordinates are stored as untextured. Throws
    /// `TextureJobError.invalidResult` when the result does not match the mesh, and a file
    /// error when a write fails (for example the project was deleted).
    ///
    /// The caller's `result` keeps its atlases alive until it goes away; the pipeline step uses
    /// `saveReleasingPages` so each page is released right after it is written.
    static func save(mesh: MeshWithAttributes, result: TXResult, package: ProjectPackage, room: UUID) throws {
        var copy = result
        try saveReleasingPages(mesh: mesh, result: &copy, package: package, room: room)
    }

    /// `save`, taking the atlases out of `result` one at a time: each page is encoded,
    /// written and released before the next, so no finished atlas CGImage is held after it
    /// is on disk (when the caller holds no other reference). `result.atlases` is empty
    /// afterwards, also when a write throws part way.
    static func saveReleasingPages(mesh: MeshWithAttributes, result: inout TXResult, package: ProjectPackage,
                                   room: UUID) throws {
        let faces = mesh.triangleCount
        guard faces > 0 else { throw TextureJobError.invalidResult("the mesh has no faces") }
        guard result.faceAtlas.count == faces, result.texcoords.count == 3 * faces else {
            throw TextureJobError.invalidResult("\(result.faceAtlas.count) face pages and \(result.texcoords.count) texcoords for \(faces) faces")
        }
        let vertexCount = mesh.mesh.positions.count
        if let bad = mesh.mesh.indices.prefix(3 * faces).first(where: { Int($0) >= vertexCount }) {
            throw TextureJobError.invalidResult("index \(bad) out of range (\(vertexCount) vertices)")
        }
        let pageCount = result.atlases.count
        guard pageCount <= maxPages else {
            result.atlases = []
            throw TextureJobError.invalidResult("\(pageCount) pages, at most \(maxPages)")
        }
        let pages = pageIndices(for: result, faceCount: faces)
        var texcoords = result.texcoords
        for f in 0..<faces where pages[f] == TexturedMesh.untexturedPage {
            for k in 0..<3 { texcoords[3 * f + k] = SIMD2<Float>(0, 0) }
        }

        let folderURL = folder(package, room: room)
        let uv = uvURL(package, room: room)
        do {
            try ProjectStore.ensureDirectory(folderURL, inside: package.root)
            try removeIfPresent(uv)
        } catch {
            result.atlases = []
            throw error
        }

        var page = 0
        while !result.atlases.isEmpty {
            let pageNumber = page
            let jpeg: Data? = autoreleasepool { () -> Data? in
                let image: CGImage = result.atlases.removeFirst()
                return jpegData(image, quality: jpegQuality)
            }
            guard let data = jpeg else {
                result.atlases = []
                throw TextureJobError.encodingFailed("page \(pageNumber)")
            }
            do {
                try ProjectStore.writeData(data, to: pageURL(package, room: room, page: pageNumber), createParents: false)
            } catch {
                result.atlases = []
                throw error
            }
            page += 1
        }

        let chunk = MeshModelStore.chunk(from: mesh, id: room)
        guard chunk.faceCount == faces else {
            throw TextureJobError.invalidResult("mesh record has \(chunk.faceCount) faces, expected \(faces)")
        }
        try ProjectStore.writeData(MeshChunkFile.encode(chunk), to: meshURL(package, room: room), createParents: false)
        let uvData = encodeUV(texcoords: texcoords, faceAtlas: pages, pageCount: pageCount)
        try ProjectStore.writeData(uvData, to: uv, createParents: false)
        removeStalePages(in: folderURL, keeping: pageCount)
    }

    /// The stored page of every face: `result.faceAtlas[f]` when the face has a keyframe
    /// (`faceSource` >= 0, or no faceSource array of the right length), its page is below
    /// `result.atlases.count` and its 3 texture coordinates are finite; otherwise
    /// `TexturedMesh.untexturedPage`.
    static func pageIndices(for result: TXResult, faceCount: Int) -> [UInt16] {
        let pageCount = result.atlases.count
        let hasSources = result.faceSource.count == faceCount
        var out = [UInt16](repeating: TexturedMesh.untexturedPage, count: Swift.max(0, faceCount))
        for f in 0..<Swift.max(0, faceCount) where f < result.faceAtlas.count {
            if hasSources && result.faceSource[f] < 0 { continue }
            let atlas = result.faceAtlas[f]
            guard Int(atlas) < pageCount, 3 * f + 2 < result.texcoords.count else { continue }
            let a = result.texcoords[3 * f], b = result.texcoords[3 * f + 1], c = result.texcoords[3 * f + 2]
            let finite = a.x.isFinite && a.y.isFinite && b.x.isFinite && b.y.isFinite
            guard finite, c.x.isFinite, c.y.isFinite else { continue }
            out[f] = atlas
        }
        return out
    }

    // MARK: - Load

    /// The room's texture, nil when `exists` is false. Throws `CoreError.corruptFile` when a
    /// file is malformed or the texture coordinates do not match the mesh, and
    /// `CoreError.fileTooLarge` above the size caps. A missing page file is logged and its
    /// faces load as untextured, so the rest of the texture still shows.
    static func load(_ package: ProjectPackage, room: UUID) throws -> TexturedMesh? {
        guard exists(package, room: room) else { return nil }
        let decoded = try decodeUV(try readCapped(uvURL(package, room: room), maxBytes: maxUVBytes))
        let chunk = try MeshChunkFile.decode(try readCapped(meshURL(package, room: room), maxBytes: maxMeshBytes))
        let world = MeshModelStore.mesh(from: chunk)
        let faces = world.triangleCount
        guard faces == decoded.faceAtlas.count, decoded.texcoords.count == 3 * faces else {
            throw CoreError.corruptFile("\(uvFileName): \(decoded.faceAtlas.count) faces, \(meshFileName) has \(faces)")
        }
        var faceAtlas = decoded.faceAtlas
        var pageURLs: [URL] = []
        var missing = Set<UInt16>()
        let fm = FileManager.default
        for p in 0..<decoded.pageCount {
            let url = pageURL(package, room: room, page: p)
            pageURLs.append(url)
            if !fm.fileExists(atPath: url.path) { missing.insert(UInt16(truncatingIfNeeded: p)) }
        }
        if !missing.isEmpty {
            var lost = 0
            for f in 0..<faces where missing.contains(faceAtlas[f]) {
                faceAtlas[f] = TexturedMesh.untexturedPage
                lost += 1
            }
            LogStore.shared.write("texture room \(room.uuidString): \(missing.count) page file(s) missing, \(lost) faces shown untextured",
                                  category: logCategory)
        }
        let coverage = TexturedMesh.areaCoverage(positions: world.mesh.positions, indices: world.mesh.indices,
                                             faceAtlas: faceAtlas, pageCount: pageURLs.count)
        return TexturedMesh(positions: world.mesh.positions, indices: world.mesh.indices, texcoords: decoded.texcoords,
                            faceAtlas: faceAtlas, pageURLs: pageURLs, coverage: coverage)
    }

    /// True when `textured.tuv` and `textured.mchk` exist (a finished save). Cheap: two
    /// file checks, no decoding.
    static func exists(_ package: ProjectPackage, room: UUID) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: uvURL(package, room: room).path)
            && fm.fileExists(atPath: meshURL(package, room: room).path)
    }

    /// Deletes the room's texture folder (used when a new run produces no texture, so an
    /// outdated one is not shown). Failures are logged.
    static func remove(_ package: ProjectPackage, room: UUID) {
        let url = folder(package, room: room)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            LogStore.shared.write("texture room \(room.uuidString): could not remove old texture (\(error))",
                                  category: logCategory)
        }
    }

    // MARK: - TUV1 format

    /// "TUV1" format: magic, version UInt16 1, faceCount UInt32, pageCount UInt16, then per
    /// face atlas UInt16 and 3 x (Float32, Float32); little endian. One face per `faceAtlas`
    /// entry; missing texture coordinates are written as (0, 0); `pageCount` is clamped to
    /// 0...65535.
    static func encodeUV(texcoords: [SIMD2<Float>], faceAtlas: [UInt16], pageCount: Int) -> Data {
        let faces = faceAtlas.count
        var w = ByteWriter(capacity: uvHeaderBytes + faces * uvFaceBytes)
        w.appendString(uvMagic)
        w.appendUInt16(uvVersion)
        w.appendUInt32(UInt32(truncatingIfNeeded: faces))
        w.appendUInt16(UInt16(clamping: pageCount))
        let zero = SIMD2<Float>(0, 0)
        for f in 0..<faces {
            w.appendUInt16(faceAtlas[f])
            for k in 0..<3 {
                let corner = 3 * f + k
                let uv: SIMD2<Float> = corner < texcoords.count ? texcoords[corner] : zero
                w.appendFloat32(uv.x)
                w.appendFloat32(uv.y)
            }
        }
        return w.data
    }

    /// Parses a "TUV1" file. Throws `CoreError.corruptFile` on a bad magic or version, a size
    /// that does not match the face count exactly (truncated or trailing bytes), more than
    /// `maxPages` pages, a page that is neither below the page count nor
    /// `TexturedMesh.untexturedPage`, or a non-finite texture coordinate.
    static func decodeUV(_ data: Data) throws -> (texcoords: [SIMD2<Float>], faceAtlas: [UInt16], pageCount: Int) {
        var r = CoreByteReader(data, fileKind: "tuv")
        try r.expectMagic(uvMagic)
        let version = try r.readUInt16()
        guard version == uvVersion else { throw CoreError.corruptFile("tuv: version \(version)") }
        let faces = Int(try r.readUInt32())
        let pageCount = Int(try r.readUInt16())
        guard pageCount <= maxPages else { throw CoreError.corruptFile("tuv: \(pageCount) pages") }
        let expected = faces * uvFaceBytes
        guard r.remaining == expected else {
            throw CoreError.corruptFile("tuv: \(r.remaining) bytes for \(faces) faces, expected \(expected)")
        }
        var faceAtlas = [UInt16]()
        faceAtlas.reserveCapacity(faces)
        var texcoords = [SIMD2<Float>]()
        texcoords.reserveCapacity(3 * faces)
        for f in 0..<faces {
            let atlas = try r.readUInt16()
            guard Int(atlas) < pageCount || atlas == TexturedMesh.untexturedPage else {
                throw CoreError.corruptFile("tuv: face \(f) page \(atlas) of \(pageCount)")
            }
            faceAtlas.append(atlas)
            for _ in 0..<3 {
                let u = try r.readFloat32()
                let v = try r.readFloat32()
                guard u.isFinite, v.isFinite else { throw CoreError.corruptFile("tuv: face \(f) texcoord not finite") }
                texcoords.append(SIMD2<Float>(u, v))
            }
        }
        return (texcoords: texcoords, faceAtlas: faceAtlas, pageCount: pageCount)
    }

    // MARK: - Helpers

    /// JPEG bytes of `image` at `quality` (0...1) with ImageIO (`CGImageDestinationCreateWithData`
    /// with the "public.jpeg" type literal); nil when encoding fails.
    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        let type = "public.jpeg" as CFString
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        let clamped = Swift.min(Swift.max(quality, 0), 1)
        let options = [kCGImageDestinationLossyCompressionQuality as String: clamped] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Data(referencing: data)
    }

    /// Reads a file of at most `maxBytes` (memory mapped when safe); throws
    /// `CoreError.fileTooLarge` above the cap.
    private static func readCapped(_ url: URL, maxBytes: Int64) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maxBytes else { throw CoreError.fileTooLarge(name: url.lastPathComponent, bytes: size) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Removes `url` when it exists; throws when it exists and cannot be removed.
    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes `page_<n>.jpg` files with n >= `count` left by an earlier bake (logged).
    private static func removeStalePages(in folder: URL, keeping count: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var removed = 0
        for name in names {
            guard let number = pageNumber(fromFileName: name), number >= count else { continue }
            do {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
                removed += 1
            } catch {
                LogStore.shared.write("texture: could not remove stale \(name) (\(error))", category: logCategory)
            }
        }
        if removed > 0 {
            LogStore.shared.write("texture: removed \(removed) stale page file(s)", category: logCategory)
        }
    }
}
