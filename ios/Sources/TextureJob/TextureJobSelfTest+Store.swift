import CoreGraphics
import Foundation
import simd

/// TextureJob self-test cases for `TextureStore` files: save then load in a temporary
/// package, page release and stale page cleanup, and the failures that must throw or degrade.
extension TextureJobSelfTest {
    // MARK: - Save and load

    /// Save then load round trip with a tiny synthetic TXResult (2 x 2 atlas CGImages), then a
    /// rebake with one page that releases the pages and removes the stale second page.
    static func storeCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("store")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: 1)
            let room = fixedID(2)
            let mesh = storeMesh()
            let u = TexturedMesh.untexturedPage
            r.check("store.absentExists", !TextureStore.exists(package, room: room))
            let absent = try TextureStore.load(package, room: room)
            r.check("store.absentLoad", absent == nil)
            guard let result = storeResult(pageCount: 2) else {
                return r.check("store.fixture", false, "no atlas images")
            }
            try TextureStore.save(mesh: mesh, result: result, package: package, room: room)
            r.check("store.exists", TextureStore.exists(package, room: room))
            let folder = TextureStore.folder(package, room: room)
            r.check("store.folder", folder.path.hasSuffix("derived/rooms/\(room.uuidString)/texture")
                    || folder.path.hasSuffix("derived/rooms/\(room.uuidString)/texture/"), folder.path)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            r.check("store.files", names == ["page_0.jpg", "page_1.jpg", "textured.mchk", "textured.tuv"], "\(names)")
            let page0 = try Data(contentsOf: TextureStore.pageURL(package, room: room, page: 0))
            r.check("store.jpeg", page0.count > 2 && page0[0] == 0xFF && page0[1] == 0xD8)
            let size = imageSize(at: TextureStore.pageURL(package, room: room, page: 1))
            r.check("store.pageSize", size?.width == 2 && size?.height == 2)

            guard let loaded = try TextureStore.load(package, room: room) else {
                return r.check("store.load", false, "nil after save")
            }
            r.check("store.positions", loaded.positions == mesh.mesh.positions)
            r.check("store.indices", loaded.indices == mesh.mesh.indices)
            r.check("store.pages", loaded.faceAtlas == [0, 1, u], "\(loaded.faceAtlas)")
            r.check("store.texcoords", Array(loaded.texcoords.prefix(6)) == Array(result.texcoords.prefix(6)))
            let zero = SIMD2<Float>(0, 0)
            r.check("store.untexturedZero", loaded.texcoords.count == 9
                    && loaded.texcoords[6] == zero && loaded.texcoords[7] == zero && loaded.texcoords[8] == zero)
            r.check("store.pageURLs", loaded.pageURLs.map { $0.lastPathComponent } == ["page_0.jpg", "page_1.jpg"])
            r.near("store.coverage", loaded.coverage, 2.0 / 3.0, 1e-5)
            r.check("store.parts", loaded.pageParts().count == 2)
            let chunk = try MeshChunkFile.decode(try Data(contentsOf: TextureStore.meshURL(package, room: room)))
            r.check("store.meshRecord", chunk.anchorID == room && Transform4(chunk.transform) == Transform4.identity
                    && chunk.classes == [1, 1, 2])

            guard var single = storeResult(pageCount: 1) else {
                return r.check("store.fixtureSingle", false, "no atlas images")
            }
            try TextureStore.saveReleasingPages(mesh: mesh, result: &single, package: package, room: room)
            r.check("store.pagesReleased", single.atlases.isEmpty)
            let stale = TextureStore.pageURL(package, room: room, page: 1)
            r.check("store.stalePageRemoved", !FileManager.default.fileExists(atPath: stale.path))
            let reloaded = try TextureStore.load(package, room: room)
            r.check("store.reloadPages", reloaded?.pageURLs.count == 1 && reloaded?.faceAtlas == [0, 0, u],
                    "\(String(describing: reloaded?.faceAtlas))")
        } catch {
            r.fail("store", error)
        }
    }

    // MARK: - Failures

    /// Invalid results throw before touching the files; corrupt or mismatched files throw on
    /// load; a missing page degrades to untextured faces; `remove` deletes the folder; a save
    /// into a deleted package throws without recreating it (CR-6).
    static func storeFailureCases(_ r: Recorder) {
        do {
            let base = try makeTemporaryFolder("failures")
            defer { try? FileManager.default.removeItem(at: base) }
            let package = try makePackage(in: base, id: 3)
            let room = fixedID(4)
            let mesh = storeMesh()
            guard let result = storeResult(pageCount: 2) else {
                return r.check("fail.fixture", false, "no atlas images")
            }
            try TextureStore.save(mesh: mesh, result: result, package: package, room: room)

            var short = result
            short.faceAtlas = [0, 1]
            r.throwsError("fail.faceCountMismatch") {
                try TextureStore.save(mesh: mesh, result: short, package: package, room: room)
            }
            r.check("fail.previousKept", TextureStore.exists(package, room: room))
            var fewCoords = result
            fewCoords.texcoords.removeLast()
            r.throwsError("fail.texcoordMismatch") {
                try TextureStore.save(mesh: mesh, result: fewCoords, package: package, room: room)
            }
            var broken = mesh
            broken.mesh.indices[4] = 42
            r.throwsError("fail.indexOutOfRange") {
                try TextureStore.save(mesh: broken, result: result, package: package, room: room)
            }
            let empty = MeshWithAttributes(mesh: TriangleMesh())
            r.throwsError("fail.emptyMesh") {
                try TextureStore.save(mesh: empty, result: result, package: package, room: room)
            }

            try FileManager.default.removeItem(at: TextureStore.pageURL(package, room: room, page: 1))
            let degraded = try TextureStore.load(package, room: room)
            let u = TexturedMesh.untexturedPage
            r.check("fail.missingPageDegrades", degraded?.faceAtlas == [0, u, u] && degraded?.pageParts().count == 1,
                    "\(String(describing: degraded?.faceAtlas))")

            let uv = TextureStore.uvURL(package, room: room)
            let oneFace = TextureStore.encodeUV(texcoords: [SIMD2<Float>](repeating: SIMD2<Float>(0.5, 0.5), count: 3),
                                                faceAtlas: [0], pageCount: 2)
            try oneFace.write(to: uv)
            r.throwsError("fail.faceCountFile") { _ = try TextureStore.load(package, room: room) }
            try Data("not a texture".utf8).write(to: uv)
            r.throwsError("fail.corruptUV") { _ = try TextureStore.load(package, room: room) }
            try Data("MCHK".utf8).write(to: TextureStore.meshURL(package, room: room))
            try TextureStore.encodeUV(texcoords: result.texcoords, faceAtlas: [0, 1, u], pageCount: 2).write(to: uv)
            r.throwsError("fail.corruptMesh") { _ = try TextureStore.load(package, room: room) }

            TextureStore.remove(package, room: room)
            r.check("fail.removed", !TextureStore.exists(package, room: room)
                    && !FileManager.default.fileExists(atPath: TextureStore.folder(package, room: room).path))
            let afterRemove = try TextureStore.load(package, room: room)
            r.check("fail.loadAfterRemove", afterRemove == nil)

            let gone = try makePackage(in: base, id: 5, create: false)
            r.throwsError("fail.deletedPackage") {
                try TextureStore.save(mesh: mesh, result: result, package: gone, room: room)
            }
            r.check("fail.packageNotRecreated", !FileManager.default.fileExists(atPath: gone.root.path))
        } catch {
            r.fail("fail", error)
        }
    }
}
