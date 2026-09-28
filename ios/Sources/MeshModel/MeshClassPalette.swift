import Foundation
import simd

/// The app's only source of classification colors (Raw Scan, class-colored exports): one
/// opaque RGBA color per ARMeshClassification raw value 0...7 (0 none, 1 wall, 2 floor,
/// 3 ceiling, 4 table, 5 seat, 6 window, 7 door) plus the Inferred color for hole fills.
enum MeshClassPalette {
    /// RGBA 0...1 per ARMeshClassification raw value 0...7, plus `inferred`.
    static let all: [UInt8: SIMD4<Float>] = [
        0: SIMD4<Float>(0.62, 0.62, 0.62, 1),
        1: SIMD4<Float>(0.45, 0.62, 0.85, 1),
        2: SIMD4<Float>(0.55, 0.75, 0.45, 1),
        3: SIMD4<Float>(0.90, 0.85, 0.55, 1),
        4: SIMD4<Float>(0.85, 0.55, 0.35, 1),
        5: SIMD4<Float>(0.75, 0.45, 0.75, 1),
        6: SIMD4<Float>(0.40, 0.85, 0.90, 1),
        7: SIMD4<Float>(0.85, 0.40, 0.40, 1)
    ]

    /// Color of inferred (hole fill) faces: orange.
    static let inferred = SIMD4<Float>(1.00, 0.60, 0.00, 1)

    /// Color of unknown values (above 7): the same gray as class 0 (none).
    static let fallback = SIMD4<Float>(0.62, 0.62, 0.62, 1)

    /// RGBA 0...1 for a classification raw value; values outside 0...7 get `fallback`.
    static func color(for classValue: UInt8) -> SIMD4<Float> {
        all[classValue] ?? fallback
    }

    /// `color(for:)` as bytes (each channel times 255, rounded).
    static func bytes(for classValue: UInt8) -> SIMD4<UInt8> {
        toBytes(color(for: classValue))
    }

    /// `inferred` as bytes.
    static var inferredBytes: SIMD4<UInt8> { toBytes(inferred) }

    /// Converts a 0...1 color to bytes, clamping each channel.
    static func toBytes(_ color: SIMD4<Float>) -> SIMD4<UInt8> {
        let scaled = simd_clamp(color, SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1)) * 255
        let r = scaled.x.rounded()
        let g = scaled.y.rounded()
        let b = scaled.z.rounded()
        let a = scaled.w.rounded()
        return SIMD4<UInt8>(UInt8(r), UInt8(g), UInt8(b), UInt8(a))
    }
}
