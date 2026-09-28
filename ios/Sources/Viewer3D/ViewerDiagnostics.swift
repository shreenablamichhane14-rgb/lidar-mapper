import Foundation
import CoreGraphics
import simd

/// On-device diagnostics for the viewer (D22, ARCHITECTURE 15 question 10).
enum ViewerDiagnostics {
    /// File name of the checkerboard texture in the temporary folder.
    static let checkerFileName = "mapper-uv-checker.jpg"
    /// Part id of the checkerboard quad.
    static let checkerPartID = "uv-checker"
    /// Cells per side of the checkerboard.
    static let checkerCells = 8
    /// Pixels per side of the checkerboard texture.
    static let checkerPixels = 1024

    /// Numbered 8 x 8 checkerboard quad (texture written to a temporary JPEG) to confirm the UV V origin on device.
    ///
    /// The quad is 1 m wide and 1 m tall, standing on the floor at z = 0 and facing +Z, with
    /// uv (0, 0) at its lower-left corner and (1, 1) at its upper right. In the texture, cell 1
    /// (red) is the bottom-left cell and the numbers grow to the right and then upward, so cell
    /// 8 is green (bottom right), cell 57 blue (top left) and cell 64 yellow (top right). With
    /// the bottom-left V origin that Texturing, Export and the viewer assume, cell 1 appears at
    /// the quad's lower left; if cell 57 appears there instead, V is flipped.
    static func uvCheckerContent() throws -> ViewerContent {
        try uvCheckerContent(directory: FileManager.default.temporaryDirectory)
    }

    /// `uvCheckerContent()` writing the texture into `directory` (the self-test uses its own
    /// temporary subfolder).
    static func uvCheckerContent(directory: URL) throws -> ViewerContent {
        guard let image = uvCheckerImage(pixels: checkerPixels) else { throw ViewerError.imageCreationFailed }
        guard let jpeg = ViewerImages.jpegData(image, quality: 0.92) else { throw ViewerError.jpegEncodingFailed }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(checkerFileName)
        try jpeg.write(to: url, options: .atomic)
        LogStore.shared.write("uv checker written: cell 1 (red) belongs at the quad's lower left, cell 64 (yellow) at its upper right",
                              category: "viewer")
        return ViewerContent(parts: [uvCheckerPart(textureURL: url)])
    }

    /// The checkerboard quad with `textureURL` as its texture.
    static func uvCheckerPart(textureURL: URL) -> ViewerPart {
        let positions: [SIMD3<Float>] = [
            SIMD3<Float>(-0.5, 0, 0), SIMD3<Float>(0.5, 0, 0), SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(-0.5, 1, 0),
        ]
        let uvs: [SIMD2<Float>] = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)]
        let normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 1), count: 4)
        return ViewerPart(id: checkerPartID, positions: positions, normals: normals, uvs: uvs,
                          indices: [0, 1, 2, 0, 2, 3], material: .texture(textureURL), layer: .realistic)
    }

    /// The numbered checkerboard image, `pixels` wide and tall (rounded down to whole cells).
    /// Row 0 of cells is the bottom of the image. Nil when a context cannot be made.
    static func uvCheckerImage(pixels: Int) -> CGImage? {
        let cells = checkerCells
        let cell = pixels / cells
        guard cell > 0, let context = ViewerImages.rgbContext(width: cell * cells, height: cell * cells) else { return nil }
        for row in 0..<cells {
            for column in 0..<cells {
                // CoreGraphics bitmap contexts have their origin at the bottom left.
                let rect = CGRect(x: column * cell, y: row * cell, width: cell, height: cell)
                let style = cellStyle(row: row, column: column, cells: cells)
                context.setFillColor(red: style.red, green: style.green, blue: style.blue, alpha: 1)
                context.fill(rect)
                context.setFillColor(red: style.ink, green: style.ink, blue: style.ink, alpha: 1)
                drawNumber(row * cells + column + 1, in: rect, context: context)
            }
        }
        return context.makeImage()
    }

    /// Colors of one checkerboard cell (0...1).
    struct CellStyle: Equatable {
        /// Fill red.
        var red: CGFloat
        /// Fill green.
        var green: CGFloat
        /// Fill blue.
        var blue: CGFloat
        /// Gray level of the number.
        var ink: CGFloat
    }

    /// Fill color and ink gray of a cell: red, green, blue and yellow corners (bottom left,
    /// bottom right, top left, top right), light and dark gray elsewhere.
    static func cellStyle(row: Int, column: Int, cells: Int) -> CellStyle {
        let last = cells - 1
        if row == 0 && column == 0 { return CellStyle(red: 0.90, green: 0.10, blue: 0.10, ink: 1) }
        if row == 0 && column == last { return CellStyle(red: 0.10, green: 0.75, blue: 0.20, ink: 0) }
        if row == last && column == 0 { return CellStyle(red: 0.15, green: 0.30, blue: 0.95, ink: 1) }
        if row == last && column == last { return CellStyle(red: 0.95, green: 0.85, blue: 0.10, ink: 0) }
        if (row + column) % 2 == 0 { return CellStyle(red: 0.92, green: 0.92, blue: 0.92, ink: 0) }
        return CellStyle(red: 0.30, green: 0.30, blue: 0.30, ink: 1)
    }

    /// Seven-segment patterns (a top, b upper right, c lower right, d bottom, e lower left,
    /// f upper left, g middle) for 0...9.
    private static let segmentPatterns: [[Bool]] = [
        [true, true, true, true, true, true, false],
        [false, true, true, false, false, false, false],
        [true, true, false, true, true, false, true],
        [true, true, true, true, false, false, true],
        [false, true, true, false, false, true, true],
        [true, false, true, true, false, true, true],
        [true, false, true, true, true, true, true],
        [true, true, true, false, false, false, false],
        [true, true, true, true, true, true, true],
        [true, true, true, true, false, true, true],
    ]

    /// Draws `number` (0...99) centered in `rect` as seven-segment digits with the current fill
    /// color. No fonts or text APIs, so the image is identical on every device.
    static func drawNumber(_ number: Int, in rect: CGRect, context: CGContext) {
        let value = Swift.min(Swift.max(number, 0), 99)
        let digits = value >= 10 ? [value / 10, value % 10] : [value]
        let width = rect.width * 0.22
        let height = rect.height * 0.44
        let gap = rect.width * 0.08
        let count = CGFloat(digits.count)
        let total = width * count + gap * (count - 1)
        var x = rect.midX - total / 2
        let y = rect.midY - height / 2
        for digit in digits {
            drawDigit(digit, origin: CGPoint(x: x, y: y), width: width, height: height, context: context)
            x += width + gap
        }
    }

    /// Draws one digit with its lower-left corner at `origin` (CoreGraphics coordinates).
    private static func drawDigit(_ digit: Int, origin: CGPoint, width: CGFloat, height: CGFloat, context: CGContext) {
        guard digit >= 0, digit < segmentPatterns.count else { return }
        let t = width * 0.22
        let half = height / 2
        let x = origin.x
        let y = origin.y
        let rects: [CGRect] = [
            CGRect(x: x, y: y + height - t, width: width, height: t),
            CGRect(x: x + width - t, y: y + half, width: t, height: half),
            CGRect(x: x + width - t, y: y, width: t, height: half),
            CGRect(x: x, y: y, width: width, height: t),
            CGRect(x: x, y: y, width: t, height: half),
            CGRect(x: x, y: y + half, width: t, height: half),
            CGRect(x: x, y: y + half - t / 2, width: width, height: t),
        ]
        let pattern = segmentPatterns[digit]
        for (segment, on) in pattern.enumerated() where on {
            context.fill(rects[segment])
        }
    }
}
