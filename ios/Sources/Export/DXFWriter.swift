import Foundation
import simd

/// ASCII DXF for a `Plan2D`, readable by AutoCAD, LibreCAD, DraftSight and SketchUp.
///
/// Version: R12 ($ACADVER AC1009). R12 needs no entity handles, no OBJECTS section and
/// no BLOCK_RECORD table, and it is the one version every CAD reader accepts from a
/// minimal file. Newer versions (AC1015 and later) would allow LWPOLYLINE and
/// $INSUNITS but require handles and owner links on every object, which is where
/// hand-written DXF usually breaks. The cost: R12 has no $INSUNITS, so the drawing is
/// unitless and 1 drawing unit = 1 meter (importers ask for or assume units).
///
/// Structure: HEADER ($ACADVER, $EXTMIN, $EXTMAX), TABLES (LTYPE CONTINUOUS, one LAYER
/// entry per plan layer plus layer "0", STYLE STANDARD), empty BLOCKS, ENTITIES, EOF.
/// Entities: LINE, POLYLINE/VERTEX/SEQEND (flag 1 when closed), ARC (degrees), CIRCLE,
/// TEXT. Dimensions are written as plain LINEs (extensions, dimension line, ticks)
/// plus one centered TEXT, because true DIMENSION entities need anonymous blocks.
/// Layer colors map to the nearest AutoCAD Color Index. Non-ASCII text is written as
/// \U+XXXX, with %%d, %%p and %%c for degree, plus-minus and diameter.
enum DXFWriter {
    /// The DXF file as text (LF line endings, ASCII only).
    static func text(for plan: Plan2D) throws -> String {
        guard !plan.entities.isEmpty else { throw ExportError.emptyPlan }
        var out = DXFStream()
        let layers = plan.resolvedLayers()
        let names = layerNames(for: layers)

        out.pair(0, "SECTION")
        out.pair(2, "HEADER")
        out.pair(9, "$ACADVER")
        out.pair(1, "AC1009")
        if let bounds = plan.bounds() {
            out.pair(9, "$EXTMIN")
            out.point(bounds.min)
            out.pair(9, "$EXTMAX")
            out.point(bounds.max)
        }
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "TABLES")
        out.pair(0, "TABLE")
        out.pair(2, "LTYPE")
        out.pair(70, "1")
        out.pair(0, "LTYPE")
        out.pair(2, "CONTINUOUS")
        out.pair(70, "0")
        out.pair(3, "Solid line")
        out.pair(72, "65")
        out.pair(73, "0")
        out.pair(40, "0.0")
        out.pair(0, "ENDTAB")

        var tableLayers: [(name: String, color: Int)] = []
        if !names.values.contains("0") { tableLayers.append((name: "0", color: 7)) }
        for layer in layers {
            tableLayers.append((name: names[layer.name] ?? "0", color: aciColor(for: layer.color)))
        }
        out.pair(0, "TABLE")
        out.pair(2, "LAYER")
        out.pair(70, "\(tableLayers.count)")
        for layer in tableLayers {
            out.pair(0, "LAYER")
            out.pair(2, layer.name)
            out.pair(70, "0")
            out.pair(62, "\(layer.color)")
            out.pair(6, "CONTINUOUS")
        }
        out.pair(0, "ENDTAB")

        out.pair(0, "TABLE")
        out.pair(2, "STYLE")
        out.pair(70, "1")
        out.pair(0, "STYLE")
        out.pair(2, "STANDARD")
        out.pair(70, "0")
        out.pair(40, "0.0")
        out.pair(41, "1.0")
        out.pair(50, "0.0")
        out.pair(71, "0")
        out.pair(42, "0.2")
        out.pair(3, "txt")
        out.pair(4, "")
        out.pair(0, "ENDTAB")
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "BLOCKS")
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "ENTITIES")
        for entity in plan.entities {
            let layer = names[entity.layer] ?? "0"
            switch entity.geometry {
            case let .line(from, to):
                out.line(from, to, layer: layer)
            case let .polyline(points, closed):
                guard points.count >= 2 else { continue }
                out.pair(0, "POLYLINE")
                out.pair(8, layer)
                out.pair(66, "1")
                out.point(SIMD2<Double>(0, 0))
                out.pair(70, closed ? "1" : "0")
                for p in points {
                    out.pair(0, "VERTEX")
                    out.pair(8, layer)
                    out.point(p)
                }
                out.pair(0, "SEQEND")
                out.pair(8, layer)
            case let .arc(center, radius, startAngle, endAngle):
                out.pair(0, "ARC")
                out.pair(8, layer)
                out.point(center)
                out.pair(40, num(abs(radius)))
                out.pair(50, num(degrees(startAngle)))
                out.pair(51, num(degrees(endAngle)))
            case let .circle(center, radius):
                out.pair(0, "CIRCLE")
                out.pair(8, layer)
                out.point(center)
                out.pair(40, num(abs(radius)))
            case let .text(position, height, string, rotation):
                out.text(string, at: position, height: height, rotation: rotation, centered: false, layer: layer)
            case let .dimension(from, to, offset, label):
                guard let layout = plan.dimensionLayout(from: from, to: to, offset: offset) else { continue }
                for s in [layout.extension1, layout.extension2, layout.dimensionLine] + layout.ticks {
                    out.line(s.a, s.b, layer: layer)
                }
                out.text(label, at: layout.textAnchor, height: layout.textHeight, rotation: layout.textAngle, centered: true, layer: layer)
            }
        }
        out.pair(0, "ENDSEC")
        out.pair(0, "EOF")
        return out.output
    }

    /// The DXF file as bytes.
    static func data(for plan: Plan2D) throws -> Data {
        Data(try text(for: plan).utf8)
    }

    /// R12 layer names: up to 31 of A-Z a-z 0-9 _ - $, unique ignoring case.
    static func layerNames(for layers: [Plan2D.Layer]) -> [String: String] {
        let cleaned = layers.map { layer -> String in
            var name = ""
            for scalar in layer.name.unicodeScalars {
                let v = scalar.value
                let keep = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 95 || v == 45 || v == 36
                name.append(keep ? Character(scalar) : "_")
            }
            if name.isEmpty { name = "LAYER" }
            return String(name.prefix(27))
        }
        var result: [String: String] = [:]
        for (layer, name) in zip(layers, ExportText.uniqued(cleaned)) {
            result[layer.name] = name
        }
        return result
    }

    /// Nearest AutoCAD Color Index among the standard colors 1 to 9. Near-black and
    /// near-white give 7, which AutoCAD shows as black on white and white on black.
    static func aciColor(for rgb: SIMD3<Float>) -> Int {
        let c = simd_clamp(rgb, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        let spread = max(c.x, c.y, c.z) - min(c.x, c.y, c.z)
        if spread < 0.15 && (max(c.x, c.y, c.z) < 0.25 || min(c.x, c.y, c.z) > 0.85) { return 7 }
        let palette: [(Int, SIMD3<Float>)] = [
            (1, SIMD3<Float>(1, 0, 0)), (2, SIMD3<Float>(1, 1, 0)), (3, SIMD3<Float>(0, 1, 0)),
            (4, SIMD3<Float>(0, 1, 1)), (5, SIMD3<Float>(0, 0, 1)), (6, SIMD3<Float>(1, 0, 1)),
            (8, SIMD3<Float>(0.5, 0.5, 0.5)), (9, SIMD3<Float>(0.75, 0.75, 0.75)),
        ]
        var best = 7
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, color) in palette {
            let d = simd_distance_squared(c, color)
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        return best
    }

    /// Single-line DXF text: control characters become spaces, degree, plus-minus and
    /// diameter become %%d, %%p, %%c, other non-ASCII becomes \U+XXXX.
    static func encodeText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xB0: out += "%%d"
            case 0xB1: out += "%%p"
            case 0x2300, 0xD8, 0xF8: out += "%%c"
            case 0..<0x20, 0x7F: out += " "
            case 0x20..<0x7F: out.unicodeScalars.append(scalar)
            case 0x80...0xFFFF: out += String(format: "\\U+%04X", scalar.value)
            default: out += "?"
            }
        }
        return out
    }

    private static func num(_ value: Double) -> String {
        ExportText.number(value, places: 6)
    }

    private static func degrees(_ radians: Double) -> Double {
        var d = (radians * 180 / Double.pi).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Group code / value writer.
    private struct DXFStream {
        var output = ""

        mutating func pair(_ code: Int, _ value: String) {
            let codeText = String(code)
            output += String(repeating: " ", count: max(0, 3 - codeText.count)) + codeText + "\n" + value + "\n"
        }

        mutating func point(_ p: SIMD2<Double>, codeOffset: Int = 0) {
            pair(10 + codeOffset, DXFWriter.num(p.x))
            pair(20 + codeOffset, DXFWriter.num(p.y))
            pair(30 + codeOffset, "0.0")
        }

        mutating func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, layer: String) {
            pair(0, "LINE")
            pair(8, layer)
            point(a)
            point(b, codeOffset: 1)
        }

        mutating func text(_ string: String, at p: SIMD2<Double>, height: Double, rotation: Double, centered: Bool, layer: String) {
            pair(0, "TEXT")
            pair(8, layer)
            point(p)
            pair(40, DXFWriter.num(max(abs(height), 1e-4)))
            pair(1, DXFWriter.encodeText(string))
            pair(50, DXFWriter.num(DXFWriter.degrees(rotation)))
            pair(7, "STANDARD")
            if centered {
                pair(72, "1")
                point(p, codeOffset: 1)
            }
        }
    }
}
