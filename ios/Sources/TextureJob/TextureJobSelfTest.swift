import CoreGraphics
import Foundation
import ImageIO
import simd

/// Plain-Swift checks for the TextureJob module (no XCTest), run from Settings > Diagnostics.
/// `run()` returns one line per failing check ("name: detail"); empty means all passed. No
/// ARKit, camera or network; files only under `FileManager.default.temporaryDirectory`,
/// removed afterwards; fixed ids, fixed dates and synthetic images, so the result is
/// deterministic. The largest bake is one quad seen by one 160 x 120 keyframe, so a run
/// stays well under 2 s on an A15. This file covers the types and `TextureStore` (the parts
/// that never slip); `TextureJobSelfTest+Step.swift` covers `KeyframeLoader` and
/// `TextureLowStep`.
enum TextureJobSelfTest {
    /// Fewer checks than this means a section stopped early without reporting (about 139
    /// checks run when everything passes).
    private static let minimumChecks = 120

    /// Collects failing checks and counts every check.
    final class Recorder {
        /// Failure lines, "name: detail".
        var failures: [String] = []
        /// Number of checks run so far.
        var count = 0

        /// Records a failure when `condition` is false.
        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            if !condition { failures.append("\(name): failed \(detail())") }
        }

        /// Records a failure when `actual` is farther than `tolerance` from `expected`.
        func near(_ name: String, _ actual: Float, _ expected: Float, _ tolerance: Float) {
            count += 1
            if !(abs(actual - expected) <= tolerance) {
                failures.append("\(name): expected \(expected), got \(actual)")
            }
        }

        /// Records a check that must throw: a failure when `body` returns normally.
        func throwsError(_ name: String, _ body: () throws -> Void) {
            count += 1
            do {
                try body()
                failures.append("\(name): did not throw")
            } catch {
                return
            }
        }

        /// Records a thrown error as a failure of check `name`.
        func fail(_ name: String, _ error: Error) {
            count += 1
            failures.append("\(name): threw \(error)")
        }
    }

    /// Failing checks as "name: detail"; empty when all pass.
    static func run() -> [String] {
        let r = Recorder()
        uvCases(r)
        pagePartCases(r)
        pageIndexCases(r)
        densityCases(r)
        coverageCases(r)
        storeCases(r)
        storeFailureCases(r)
        inputCases(r)
        loaderFileCases(r)
        stepRuleCases(r)
        stepRunCases(r)
        if r.failures.isEmpty && r.count < minimumChecks {
            r.failures.append("selfTest: only \(r.count) checks ran")
        }
        return r.failures
    }

    /// One log line: "texture job self-test: all passed" or the failures joined.
    static func summary() -> String {
        let failures = run()
        if failures.isEmpty { return "texture job self-test: all passed" }
        return "texture job self-test: \(failures.count) failed: " + failures.joined(separator: "; ")
    }

    // MARK: - TUV1

    /// `encodeUV` / `decodeUV` round trip, header layout, and every corruption that must throw.
    static func uvCases(_ r: Recorder) {
        let untextured = TexturedMesh.untexturedPage
        let texcoords: [SIMD2<Float>] = [SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.3, 0.4), SIMD2<Float>(0.5, 0.6),
                                         SIMD2<Float>(0, 0), SIMD2<Float>(0, 0), SIMD2<Float>(0, 0),
                                         SIMD2<Float>(0.7, 0.8), SIMD2<Float>(0.9, 1), SIMD2<Float>(0.25, 0.75)]
        let pages: [UInt16] = [0, untextured, 1]
        let data = TextureStore.encodeUV(texcoords: texcoords, faceAtlas: pages, pageCount: 2)
        r.check("uv.size", data.count == 12 + 3 * 26, "\(data.count) bytes")
        r.check("uv.magic", Array(data.prefix(4)) == Array("TUV1".utf8))
        do {
            let decoded = try TextureStore.decodeUV(data)
            r.check("uv.roundTripTexcoords", decoded.texcoords == texcoords)
            r.check("uv.roundTripPages", decoded.faceAtlas == pages, "\(decoded.faceAtlas)")
            r.check("uv.roundTripPageCount", decoded.pageCount == 2)
        } catch {
            r.fail("uv.roundTrip", error)
        }
        do {
            let empty = try TextureStore.decodeUV(TextureStore.encodeUV(texcoords: [], faceAtlas: [], pageCount: 0))
            r.check("uv.empty", empty.faceAtlas.isEmpty && empty.texcoords.isEmpty && empty.pageCount == 0)
        } catch {
            r.fail("uv.empty", error)
        }
        var badMagic = data
        badMagic[0] = UInt8(ascii: "X")
        r.throwsError("uv.badMagic") { _ = try TextureStore.decodeUV(badMagic) }
        var badVersion = data
        badVersion[4] = 2
        r.throwsError("uv.badVersion") { _ = try TextureStore.decodeUV(badVersion) }
        r.throwsError("uv.truncated") { _ = try TextureStore.decodeUV(data.prefix(data.count - 1)) }
        var trailing = data
        trailing.append(0)
        r.throwsError("uv.trailing") { _ = try TextureStore.decodeUV(trailing) }
        r.throwsError("uv.shortHeader") { _ = try TextureStore.decodeUV(data.prefix(7)) }
        let outOfRange = TextureStore.encodeUV(texcoords: texcoords, faceAtlas: [0, 2, 1], pageCount: 2)
        r.throwsError("uv.pageOutOfRange") { _ = try TextureStore.decodeUV(outOfRange) }
        var withNaN = texcoords
        withNaN[4] = SIMD2<Float>(Float.nan, 0.5)
        let nanData = TextureStore.encodeUV(texcoords: withNaN, faceAtlas: pages, pageCount: 2)
        r.throwsError("uv.nonFinite") { _ = try TextureStore.decodeUV(nanData) }
        let tooMany = TextureStore.encodeUV(texcoords: [], faceAtlas: [], pageCount: TextureStore.maxPages + 1)
        r.throwsError("uv.tooManyPages") { _ = try TextureStore.decodeUV(tooMany) }
        r.check("uv.pageName", TextureStore.pageFileName(3) == "page_3.jpg")
        r.check("uv.pageParse", TextureStore.pageNumber(fromFileName: "page_12.jpg") == 12)
        let rejected = ["page_.jpg", "page_1.jpg.tmp", "xpage_1.jpg", "page_-1.jpg", "page_1a.jpg"]
        r.check("uv.pageParseRejects", rejected.allSatisfy { TextureStore.pageNumber(fromFileName: $0) == nil })
    }

    // MARK: - pageParts

    /// A 5-vertex mesh with 4 faces: faces 0 and 2 on page 0, face 1 on page 1, face 3
    /// untextured; texcoords are distinct per corner.
    static func partsFixture() -> TexturedMesh {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0),
                                         SIMD3<Float>(0, 1, 0), SIMD3<Float>(2, 0, 0)]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 1, 4, 2, 3, 2, 4]
        var texcoords: [SIMD2<Float>] = []
        for corner in 0..<12 { texcoords.append(SIMD2<Float>(Float(corner) * 0.05, 1 - Float(corner) * 0.05)) }
        let pages = [URL(fileURLWithPath: "/tmp/page_0.jpg"), URL(fileURLWithPath: "/tmp/page_1.jpg")]
        return TexturedMesh(positions: positions, indices: indices, texcoords: texcoords,
                            faceAtlas: [0, 1, 0, TexturedMesh.untexturedPage], pageURLs: pages, coverage: 0.75)
    }

    /// `pageParts`: 3 faces on 2 pages give 2 parts with 6 and 3 vertices in corner order;
    /// untextured faces, pages beyond `pageURLs` and bad indices are skipped.
    static func pagePartCases(_ r: Recorder) {
        let mesh = partsFixture()
        let parts = mesh.pageParts()
        r.check("parts.count", parts.count == 2, "\(parts.count) parts")
        guard parts.count == 2 else { return }
        r.check("parts.pages", parts[0].page == 0 && parts[1].page == 1)
        r.check("parts.vertexCounts", parts[0].positions.count == 6 && parts[1].positions.count == 3,
                "\(parts[0].positions.count) and \(parts[1].positions.count)")
        let t = mesh.texcoords
        r.check("parts.texcoordsPage0", parts[0].texcoords == [t[0], t[1], t[2], t[6], t[7], t[8]])
        r.check("parts.texcoordsPage1", parts[1].texcoords == [t[3], t[4], t[5]])
        let p = mesh.positions
        r.check("parts.positionsPage0", parts[0].positions == [p[0], p[1], p[2], p[1], p[4], p[2]])
        r.check("parts.positionsPage1", parts[1].positions == [p[0], p[2], p[3]])
        r.check("parts.indices", parts[0].indices == [0, 1, 2, 3, 4, 5] && parts[1].indices == [0, 1, 2])
        let drawnVertices = parts.reduce(0, { $0 + $1.positions.count })
        r.check("parts.untexturedSkipped", drawnVertices == 9, "\(drawnVertices) vertices")
        r.check("parts.texturedFaceCount", mesh.texturedFaceCount == 3, "\(mesh.texturedFaceCount)")

        var beyond = mesh
        beyond.faceAtlas = [0, 5, 0, 1]
        let beyondParts = beyond.pageParts()
        r.check("parts.pageBeyondURLsSkipped", beyondParts.count == 2 && beyondParts[0].positions.count == 6
                && beyondParts[1].positions.count == 3)
        var badIndex = mesh
        badIndex.indices[3] = 99
        let badParts = badIndex.pageParts()
        r.check("parts.badIndexSkipped", badParts.count == 1 && badParts[0].page == 0)
        var noPages = mesh
        noPages.pageURLs = []
        r.check("parts.noPages", noPages.pageParts().isEmpty)
    }

    /// `TextureStore.pageIndices`: faceSource -1, a page beyond the atlases and a non-finite
    /// texcoord all become untextured.
    static func pageIndexCases(_ r: Recorder) {
        var coords = [SIMD2<Float>](repeating: SIMD2<Float>(0.5, 0.5), count: 12)
        coords[10] = SIMD2<Float>(Float.infinity, 0)
        let result = TXResult(texcoords: coords, faceAtlas: [0, 0, 1, 1], atlases: [],
                              faceSource: [0, -1, 2, 3], coverage: 0.5)
        let none = TextureStore.pageIndices(for: result, faceCount: 4)
        let u = TexturedMesh.untexturedPage
        r.check("pageIndex.noAtlases", none == [u, u, u, u], "\(none)")
        guard let image = solidImage(width: 2, height: 2, rgb: SIMD3<UInt8>(10, 20, 30)) else {
            return r.check("pageIndex.image", false, "no CGImage")
        }
        var twoPages = result
        twoPages.atlases = [image, image]
        let pages = TextureStore.pageIndices(for: twoPages, faceCount: 4)
        r.check("pageIndex.sourceMinusOne", pages == [0, u, 1, u], "\(pages)")
        var onePage = twoPages
        onePage.atlases = [image]
        r.check("pageIndex.beyondAtlases", TextureStore.pageIndices(for: onePage, faceCount: 4) == [0, u, u, u])
        var noSources = twoPages
        noSources.faceSource = []
        r.check("pageIndex.noSources", TextureStore.pageIndices(for: noSources, faceCount: 4) == [0, 0, 1, u])
    }

    // MARK: - Density and coverage

    /// `TextureDensity` options, reduced options, step ids, folders and raw values.
    static func densityCases(_ r: Recorder) {
        let textured = TextureDensity.textured.options
        r.check("density.texturedAtlas", textured.atlasSize == 2048, "\(textured.atlasSize)")
        r.near("density.texturedTexels", textured.texelsPerMeter, 100, 0)
        r.check("density.texturedPages", textured.maxAtlases == 4)
        r.check("density.texturedExposure", !textured.normalizeExposure)
        let photo = TextureDensity.photoRealistic.options
        r.check("density.photoAtlas", photo.atlasSize == 4096 && photo.maxAtlases == 8 && photo.normalizeExposure)
        r.near("density.photoStandard", photo.texelsPerMeter, 250, 0)
        r.near("density.photoHigh", TextureDensity.photoRealistic.detailedOptions(.high).texelsPerMeter, 375, 0)
        r.near("density.photoMaximum", TextureDensity.photoRealistic.detailedOptions(.maximum).texelsPerMeter, 500, 0)
        r.near("density.texturedIgnoresDetail", TextureDensity.textured.detailedOptions(.maximum).texelsPerMeter, 100, 0)
        let reduced = TextureDensity.textured.reducedOptions
        r.check("density.reducedAtlas", reduced.atlasSize == 1024 && reduced.maxAtlases == 4 && !reduced.normalizeExposure)
        r.check("density.photoReducedAtlas", TextureDensity.photoRealistic.reducedOptions.atlasSize == 2048)
        r.check("density.steps", TextureDensity.textured.stepID == .textureLow
                && TextureDensity.photoRealistic.stepID == .textureHigh)
        r.check("density.folders", TextureDensity.textured.folderName == "texture"
                && TextureDensity.photoRealistic.folderName == "texture-high")
        r.check("density.rawValues", TextureDensity.allCases.map({ $0.rawValue }) == ["textured", "photoRealistic"])
    }

    /// `TexturedMesh.coverage` is area weighted and ignores pages beyond the page count.
    static func coverageCases(_ r: Recorder) {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
                                         SIMD3<Float>(0, 0, 1), SIMD3<Float>(3, 0, 1), SIMD3<Float>(0, 1, 1)]
        let indices: [UInt32] = [0, 1, 2, 3, 4, 5]
        let u = TexturedMesh.untexturedPage
        r.near("coverage.areaWeighted", TexturedMesh.areaCoverage(positions: positions, indices: indices,
                                                              faceAtlas: [0, u], pageCount: 1), 0.25, 1e-5)
        r.near("coverage.big", TexturedMesh.areaCoverage(positions: positions, indices: indices,
                                                     faceAtlas: [u, 0], pageCount: 1), 0.75, 1e-5)
        r.near("coverage.pageBeyond", TexturedMesh.areaCoverage(positions: positions, indices: indices,
                                                            faceAtlas: [0, 1], pageCount: 1), 0.25, 1e-5)
        r.near("coverage.empty", TexturedMesh.areaCoverage(positions: [], indices: [], faceAtlas: [], pageCount: 1), 0, 0)
    }

    // MARK: - Fixtures

    /// A fixed UUID ending in `n`.
    static func fixedID(_ n: Int) -> UUID {
        let low = UInt8(truncatingIfNeeded: n)
        let high = UInt8(truncatingIfNeeded: n >> 8)
        return UUID(uuid: (0x7E, 0x70, 0x0B, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, high, low))
    }

    /// A fixed date (seconds after 2026-01-01).
    static func fixedDate(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_767_225_600 + seconds)
    }

    /// A fresh, empty folder `TextureJobSelfTest-<name>` in the temporary directory.
    static func makeTemporaryFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TextureJobSelfTest-" + name,
                                                                               isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A package folder `<id>.mapperproj` inside `base` (created with `derived/` when `create`).
    static func makePackage(in base: URL, id: Int, create: Bool = true) throws -> ProjectPackage {
        let root = base.appendingPathComponent(fixedID(id).uuidString + "." + ProjectPackage.fileExtension,
                                               isDirectory: true)
        let package = ProjectPackage(root: root)
        if create { try FileManager.default.createDirectory(at: package.derivedURL, withIntermediateDirectories: true) }
        return package
    }

    /// An opaque RGB image of one color, or nil when no context can be made.
    static func solidImage(width: Int, height: Int, rgb: SIMD3<UInt8>) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let red = CGFloat(rgb.x) / 255, green = CGFloat(rgb.y) / 255, blue = CGFloat(rgb.z) / 255
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Width and height of the image file at `url` read with ImageIO, or nil.
    static func imageSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    /// A 5-vertex, 3-face world mesh (a unit quad at z = -1.5 plus one triangle).
    static func storeMesh() -> MeshWithAttributes {
        let positions: [SIMD3<Float>] = [SIMD3<Float>(-0.5, -0.5, -1.5), SIMD3<Float>(0.5, -0.5, -1.5),
                                         SIMD3<Float>(0.5, 0.5, -1.5), SIMD3<Float>(-0.5, 0.5, -1.5),
                                         SIMD3<Float>(1.5, -0.5, -1.5)]
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3, 1, 4, 2]
        return MeshWithAttributes(mesh: TriangleMesh(positions: positions, indices: indices), faceClass: [1, 1, 2])
    }

    /// A synthetic bake result for `storeMesh()`: face 0 on page 0, face 1 on page 1, face 2
    /// untextured (`faceSource` -1), with `pageCount` 2 x 2 single-color atlases.
    static func storeResult(pageCount: Int) -> TXResult? {
        var atlases: [CGImage] = []
        let colors: [SIMD3<UInt8>] = [SIMD3<UInt8>(200, 30, 30), SIMD3<UInt8>(30, 30, 200)]
        for p in 0..<pageCount {
            guard let image = solidImage(width: 2, height: 2, rgb: colors[p % colors.count]) else { return nil }
            atlases.append(image)
        }
        var texcoords: [SIMD2<Float>] = []
        for corner in 0..<9 { texcoords.append(SIMD2<Float>(Float(corner) * 0.1, Float(corner % 3) * 0.3)) }
        let secondPage: UInt16 = pageCount > 1 ? 1 : 0
        return TXResult(texcoords: texcoords, faceAtlas: [0, secondPage, 0], atlases: atlases,
                        faceSource: [0, 1, -1], coverage: 0.5)
    }
}
