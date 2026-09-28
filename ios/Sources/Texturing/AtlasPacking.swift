import Foundation
import simd

/// Packs chart rectangles into square texture atlases with a skyline bottom-left packer.
///
/// Coordinates follow the rest of the module: texel row 0 is at the top of an atlas, so a
/// "skyline" here is the lowest filled row per column span, growing downward. Rectangles are
/// placed in order of decreasing height, which keeps the skyline flat and the waste low. Each
/// rectangle goes into the first open atlas that can hold it, at the position with the smallest
/// top edge (ties broken by the smallest left edge); a new atlas is opened only when no open
/// atlas has room.
enum TXAtlasPacker {
    /// Largest number of density reductions `packCharts` tries before giving up.
    static let maxPackAttempts: Int = 12

    /// Texel density multiplier applied between two `packCharts` attempts.
    static let shrinkFactor: Float = 0.8

    /// Skyline bottom-left packer; rectangles placed in order of decreasing height (ties by width, then index),
    /// placements returned in INPUT order. Opens a new atlas when a rectangle fits nowhere. Returns nil if more
    /// than maxAtlases atlases would be needed or any rectangle is larger than atlasSize.
    /// usedHeights[a] = max(y + height) of rectangles in atlas a.
    ///
    /// Rectangles with a zero or negative side are treated as 1 texel on that side, so every
    /// input still gets a distinct placement. An empty input returns an empty packing with no atlases.
    static func pack(sizes: [SIMD2<Int>], atlasSize: Int, maxAtlases: Int) -> TXPacking? {
        if sizes.isEmpty {
            return TXPacking(placements: [], atlasCount: 0, usedHeights: [])
        }
        guard atlasSize > 0, maxAtlases > 0 else { return nil }

        // Normalize sizes and reject anything that can never fit.
        var clamped: [SIMD2<Int>] = []
        clamped.reserveCapacity(sizes.count)
        for size in sizes {
            let w: Int = max(1, size.x)
            let h: Int = max(1, size.y)
            if w > atlasSize || h > atlasSize { return nil }
            clamped.append(SIMD2<Int>(w, h))
        }

        // Decreasing height, then decreasing width, then increasing input index.
        var order: [Int] = Array(0..<clamped.count)
        order.sort { (a: Int, b: Int) -> Bool in
            let sa: SIMD2<Int> = clamped[a]
            let sb: SIMD2<Int> = clamped[b]
            if sa.y != sb.y { return sa.y > sb.y }
            if sa.x != sb.x { return sa.x > sb.x }
            return a < b
        }

        var skylines: [TXSkyline] = []
        var usedHeights: [Int] = []
        var placements: [TXPlacement] = [TXPlacement](repeating: TXPlacement(atlas: 0, x: 0, y: 0),
                                                      count: clamped.count)

        for index in order {
            let w: Int = clamped[index].x
            let h: Int = clamped[index].y
            var placed: Bool = false
            var atlas: Int = 0
            while atlas < skylines.count {
                if let spot = skylines[atlas].bestPosition(width: w, height: h) {
                    skylines[atlas].insert(segmentIndex: spot.segmentIndex, x: spot.x, y: spot.y,
                                           width: w, height: h)
                    placements[index] = TXPlacement(atlas: atlas, x: spot.x, y: spot.y)
                    usedHeights[atlas] = max(usedHeights[atlas], spot.y + h)
                    placed = true
                    break
                }
                atlas += 1
            }
            if placed { continue }

            // Open a new atlas.
            if skylines.count >= maxAtlases { return nil }
            var fresh: TXSkyline = TXSkyline(size: atlasSize)
            guard let spot = fresh.bestPosition(width: w, height: h) else { return nil }
            fresh.insert(segmentIndex: spot.segmentIndex, x: spot.x, y: spot.y, width: w, height: h)
            skylines.append(fresh)
            usedHeights.append(spot.y + h)
            placements[index] = TXPlacement(atlas: skylines.count - 1, x: spot.x, y: spot.y)
        }

        return TXPacking(placements: placements, atlasCount: skylines.count, usedHeights: usedHeights)
    }

    /// Packs charts, multiplying texel density by 0.8 (via TXChartBuilder.rescaled) until they fit,
    /// at most 12 attempts; returns the (possibly rescaled) charts and packing, or nil.
    ///
    /// The first attempt uses the charts unchanged. Attempt k (0-based) rescales the ORIGINAL charts
    /// by 0.8^k, so rounding never accumulates across attempts.
    static func packCharts(_ charts: [TXChart], atlasSize: Int,
                           maxAtlases: Int) -> (charts: [TXChart], packing: TXPacking)? {
        if charts.isEmpty {
            let empty: TXPacking = TXPacking(placements: [], atlasCount: 0, usedHeights: [])
            return (charts: charts, packing: empty)
        }
        guard atlasSize > 0, maxAtlases > 0 else { return nil }

        var factor: Float = 1
        var attempt: Int = 0
        while attempt < maxPackAttempts {
            let current: [TXChart]
            if attempt == 0 {
                current = charts
            } else {
                current = TXChartBuilder.rescaled(charts, factor: factor)
            }
            var sizes: [SIMD2<Int>] = []
            sizes.reserveCapacity(current.count)
            for chart in current {
                sizes.append(SIMD2<Int>(chart.width, chart.height))
            }
            if let packing = pack(sizes: sizes, atlasSize: atlasSize, maxAtlases: maxAtlases) {
                return (charts: current, packing: packing)
            }
            factor *= shrinkFactor
            attempt += 1
        }
        return nil
    }

    /// Smallest power of two >= used height, clamped to atlasSize (atlas trimming).
    ///
    /// A used height of 0 or less gives 1 (never an empty image). Returns 1 when atlasSize is not positive.
    static func atlasHeight(usedHeight: Int, atlasSize: Int) -> Int {
        guard atlasSize > 0 else { return 1 }
        let target: Int = max(1, min(usedHeight, atlasSize))
        var height: Int = 1
        while height < target {
            height *= 2
        }
        return min(height, atlasSize)
    }
}

/// One horizontal run of the skyline: columns x..<(x + width) are filled down to row y - 1,
/// so the next rectangle over this run can start at row y.
struct TXSkylineSegment {
    /// Left edge in texels.
    var x: Int
    /// First free row below the filled area (row 0 at the top).
    var y: Int
    /// Width of the run in texels.
    var width: Int
}

/// Candidate position for a rectangle on a skyline.
struct TXSkylineSpot {
    /// Index of the segment where the rectangle's left edge starts.
    var segmentIndex: Int
    /// Left edge in texels.
    var x: Int
    /// Top edge in texels.
    var y: Int
}

/// Skyline of one square atlas: segments sorted by x, contiguous, covering 0..<size.
struct TXSkyline {
    /// Atlas side length in texels.
    let size: Int
    /// Segments sorted by x; together they cover the full width with no gaps.
    var segments: [TXSkylineSegment]

    /// Empty atlas of the given side length: one segment spanning the full width at row 0.
    init(size: Int) {
        self.size = size
        self.segments = [TXSkylineSegment(x: 0, y: 0, width: size)]
    }

    /// Top edge a rectangle of `width` would get with its left edge at segment `index`,
    /// or nil if it would cross the right edge of the atlas.
    func fitTop(segmentIndex index: Int, width: Int) -> Int? {
        let x: Int = segments[index].x
        if x + width > size { return nil }
        var remaining: Int = width
        var top: Int = 0
        var i: Int = index
        while remaining > 0 && i < segments.count {
            top = max(top, segments[i].y)
            remaining -= segments[i].width
            i += 1
        }
        if remaining > 0 { return nil }
        return top
    }

    /// Position with the smallest top edge, ties broken by the smallest left edge, where a
    /// rectangle of `width` x `height` fits entirely inside the atlas; nil when there is none.
    func bestPosition(width: Int, height: Int) -> TXSkylineSpot? {
        var best: TXSkylineSpot? = nil
        for i in 0..<segments.count {
            guard let top = fitTop(segmentIndex: i, width: width) else { continue }
            if top + height > size { continue }
            let x: Int = segments[i].x
            if let current = best {
                if top < current.y || (top == current.y && x < current.x) {
                    best = TXSkylineSpot(segmentIndex: i, x: x, y: top)
                }
            } else {
                best = TXSkylineSpot(segmentIndex: i, x: x, y: top)
            }
        }
        return best
    }

    /// Records a rectangle placed at (`x`, `y`) with its left edge on segment `segmentIndex`:
    /// the covered span becomes one segment at row `y + height`, partly covered segments are
    /// trimmed, and neighbouring segments at the same row are merged.
    mutating func insert(segmentIndex: Int, x: Int, y: Int, width: Int, height: Int) {
        let newSegment: TXSkylineSegment = TXSkylineSegment(x: x, y: y + height, width: width)
        segments.insert(newSegment, at: segmentIndex)
        let right: Int = x + width

        // Remove or trim the segments now under the new one.
        let i: Int = segmentIndex + 1
        while i < segments.count {
            let seg: TXSkylineSegment = segments[i]
            if seg.x >= right { break }
            let segRight: Int = seg.x + seg.width
            if segRight <= right {
                segments.remove(at: i)
            } else {
                segments[i].x = right
                segments[i].width = segRight - right
                break
            }
        }

        // Merge neighbours at the same row.
        var j: Int = 0
        while j + 1 < segments.count {
            if segments[j].y == segments[j + 1].y {
                segments[j].width += segments[j + 1].width
                segments.remove(at: j + 1)
            } else {
                j += 1
            }
        }
    }
}
