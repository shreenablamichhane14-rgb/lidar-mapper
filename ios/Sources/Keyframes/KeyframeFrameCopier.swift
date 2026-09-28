import CoreVideo
import Foundation

/// 4 preallocated bi-planar buffers the size and pixel format of the first capturedImage (D7),
/// created once with CVPixelBufferCreate and handed out from a lock-protected free list.
/// Thread-safe: `copy` runs on the hub queue, `release` on the io queue.
///
/// The copier never keeps a reference to the source buffer: `copy` reads ARKit's pixels while
/// the frame callback is still running and returns one of its own buffers, which travels to
/// the io queue for JPEG encoding and comes back through `release`. When every buffer is in
/// use, `copy` returns nil and the caller skips the keyframe (RESEARCH 3.4: drop, never queue
/// unbounded work). The buffers are IOSurface backed so Core Image can read them directly.
final class FrameCopier {
    /// Width in pixels of every buffer (the first capturedImage's width).
    let width: Int
    /// Height in pixels of every buffer.
    let height: Int
    /// Pixel format of every buffer ('420f' for ARKit, read at runtime, RESEARCH 3.4 gotcha 6).
    let pixelFormat: OSType
    /// Buffers actually created: the requested count unless CVPixelBufferCreate failed.
    let count: Int

    /// Guards `free`.
    private let lock = NSLock()
    /// Every buffer this copier owns, in creation order.
    private let buffers: [CVPixelBuffer]
    /// Buffers not handed out. Guarded by `lock`.
    private var free: [CVPixelBuffer]

    /// Creates `count` buffers of the given size and pixel format with CVPixelBufferCreate
    /// (IOSurface backed). A failed creation is logged and leaves fewer buffers.
    init(width: Int, height: Int, pixelFormat: OSType, count: Int = 4) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        var made: [CVPixelBuffer] = []
        if width > 0, height > 0 {
            let surfaceProperties: [String: Any] = [:]
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: surfaceProperties]
            for _ in 0..<max(0, count) {
                var created: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                                 attributes as CFDictionary, &created)
                if status == kCVReturnSuccess, let buffer = created {
                    made.append(buffer)
                } else {
                    KeyframesLog.write("frame copier: CVPixelBufferCreate \(width)x\(height) failed (\(status))")
                }
            }
        }
        buffers = made
        free = made
        self.count = made.count
    }

    /// Buffers currently handed out (0...count).
    var inUse: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count - free.count
    }

    /// Buffers currently free (count - inUse).
    var available: Int {
        lock.lock()
        defer { lock.unlock() }
        return free.count
    }

    /// True when `image` has this copier's width, height and pixel format.
    func matches(_ image: CVPixelBuffer) -> Bool {
        CVPixelBufferGetWidth(image) == width && CVPixelBufferGetHeight(image) == height
            && CVPixelBufferGetPixelFormatType(image) == pixelFormat
    }

    /// Copies both planes row by row (honoring each plane's bytes per row); nil when all buffers
    /// are in use (the keyframe is skipped and counted). Also nil, with the buffer returned to
    /// the free list, when `image` has another size or format or cannot be locked. The copy
    /// carries the source's propagatable attachments (color matrix), never the source itself.
    func copy(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        guard matches(image) else {
            KeyframesLog.once("copier.mismatch", "frame copier: source \(CVPixelBufferGetWidth(image))x"
                              + "\(CVPixelBufferGetHeight(image)) differs from \(width)x\(height); copy skipped")
            return nil
        }
        guard let target = take() else { return nil }
        guard FrameCopier.copyPixels(from: image, to: target) else {
            putBack(target)
            KeyframesLog.once("copier.copy", "frame copier: could not copy the image planes")
            return nil
        }
        CVBufferRemoveAllAttachments(target)
        CVBufferPropagateAttachments(image, target)
        return target
    }

    /// Returns a buffer to the free list after its JPEG is written. A buffer this copier does
    /// not own, or one already free, is ignored (logged once).
    func release(_ buffer: CVPixelBuffer) {
        lock.lock()
        let owned = buffers.contains { $0 === buffer }
        let alreadyFree = free.contains { $0 === buffer }
        if owned && !alreadyFree { free.append(buffer) }
        lock.unlock()
        if !owned || alreadyFree {
            KeyframesLog.once("copier.release", "frame copier: release of a foreign or free buffer ignored")
        }
    }

    // MARK: - Free list

    /// Pops a free buffer, or nil when every buffer is in use.
    private func take() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return free.popLast()
    }

    /// Puts back a buffer that was taken but not handed out.
    private func putBack(_ buffer: CVPixelBuffer) {
        lock.lock()
        if !free.contains(where: { $0 === buffer }) { free.append(buffer) }
        lock.unlock()
    }

    // MARK: - Pixel copy

    /// Copies every plane of `source` into `target` (same plane count and plane heights), or
    /// the whole buffer when it is not planar. Rows are copied one by one when the bytes per
    /// row differ, else each plane in one block. False when a lock or a size check fails.
    static func copyPixels(from source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
        let planes = CVPixelBufferGetPlaneCount(source)
        guard planes == CVPixelBufferGetPlaneCount(target) else { return false }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let writeFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(target, writeFlags) == kCVReturnSuccess else { return false }
        defer { _ = CVPixelBufferUnlockBaseAddress(target, writeFlags) }
        if planes == 0 {
            let rows = CVPixelBufferGetHeight(source)
            guard rows == CVPixelBufferGetHeight(target) else { return false }
            return copyRows(from: CVPixelBufferGetBaseAddress(source),
                            sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                            to: CVPixelBufferGetBaseAddress(target),
                            targetBytesPerRow: CVPixelBufferGetBytesPerRow(target), rows: rows)
        }
        for plane in 0..<planes {
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            guard rows == CVPixelBufferGetHeightOfPlane(target, plane),
                  CVPixelBufferGetWidthOfPlane(source, plane) == CVPixelBufferGetWidthOfPlane(target, plane) else {
                return false
            }
            let copied = copyRows(from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                                  sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                                  to: CVPixelBufferGetBaseAddressOfPlane(target, plane),
                                  targetBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(target, plane), rows: rows)
            guard copied else { return false }
        }
        return true
    }

    /// Copies `rows` rows between two locked planes: one memcpy when the bytes per row match,
    /// else the shorter row length per row (every pixel byte fits in both rows).
    private static func copyRows(from source: UnsafeMutableRawPointer?, sourceBytesPerRow: Int,
                                 to target: UnsafeMutableRawPointer?, targetBytesPerRow: Int, rows: Int) -> Bool {
        guard let source, let target, rows >= 0, sourceBytesPerRow > 0, targetBytesPerRow > 0 else { return false }
        if sourceBytesPerRow == targetBytesPerRow {
            memcpy(target, source, sourceBytesPerRow * rows)
            return true
        }
        let rowBytes = min(sourceBytesPerRow, targetBytesPerRow)
        for row in 0..<rows {
            memcpy(target + row * targetBytesPerRow, source + row * sourceBytesPerRow, rowBytes)
        }
        return true
    }
}
