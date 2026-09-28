import Foundation
import simd

/// ASCII DXF for a `Plan2D`, readable by AutoCAD, LibreCAD, DraftSight and SketchUp.
///
/// Version: R12 ($ACADVER AC1009). R12 needs no entity handles, no OBJECTS section and
/// no BLOCK_RECORD table, and it is the one version every CAD reader accepts from a
/// minimal file. Newer versions (AC1015 and later) would allow LWPOLYLINE and
/// $INSUNITS but require handles and owner links on every object, which is where
/// hand-written DXF usually breaks. The cost: R12 has no $INSUNITS, so the drawing is
/// unitless. `text(for:)` and `data(for:)` write 1 drawing unit = 1 meter (importers ask
/// for or assume units); `text(for:millimeters:unitsNote:)` and
/// `data(for:millimeters:unitsNote:)` write 1 drawing unit = 1 millimeter and state the
/// unit in a TEXT note below the drawing (D23), which is what the export screen uses.
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

/// Millimeter output with a units note (MODULES 3.18a, D23). The plan is scaled and the
/// note is added as an ordinary text entity before the unchanged R12 writer above runs,
/// so extents, dimension layout and text heights all follow the same code path as the
/// meter output.
extension DXFWriter {
    /// Layer that receives the units note when the plan declares or uses it.
    static let notesLayerName = "A-ANNO-NOTE"
    /// Layer used for the units note when the plan has no notes layer.
    static let fallbackNotesLayerName = "0"
    /// Drawing units per meter in the millimeter output.
    static let millimetersPerMeter: Double = 1000
    /// Text height of the units note in meters, used when the plan's dimension text
    /// height is not a positive finite number.
    static let defaultNoteHeightMeters: Double = 0.12

    /// The DXF file as text. When `millimeters` is true every coordinate, radius, text
    /// height, dimension offset and the dimension text height are multiplied by 1000 (1
    /// drawing unit = 1 mm), so `$EXTMIN` and `$EXTMAX` scale too; when false the
    /// geometry is written in meters exactly like `text(for:)`. When `unitsNote` is not
    /// nil and not blank, one TEXT entity with that string is appended on the notes
    /// layer ("A-ANNO-NOTE" when the plan has it, else "0"), left-aligned with the
    /// lower-left corner of `plan.bounds()` and one note height below the drawing. Still
    /// R12, still no `$INSUNITS`, no DIMENSION entities and no new layers.
    static func text(for plan: Plan2D, millimeters: Bool, unitsNote: String?) throws -> String {
        guard !plan.entities.isEmpty else { throw ExportError.emptyPlan }
        let factor: Double = millimeters ? millimetersPerMeter : 1
        var output = millimeters ? scaledPlan(plan, by: factor) : plan
        if let note = unitsNote, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output.entities.append(unitsNoteEntity(note, for: output, unitsPerMeter: factor))
        }
        return try text(for: output)
    }

    /// The DXF file as bytes; see `text(for:millimeters:unitsNote:)`.
    static func data(for plan: Plan2D, millimeters: Bool, unitsNote: String?) throws -> Data {
        Data(try text(for: plan, millimeters: millimeters, unitsNote: unitsNote).utf8)
    }

    /// A copy of `plan` with every length multiplied by `factor`: points, radii, text
    /// heights, dimension offsets and `dimensionTextHeight`. Angles, labels, layer names
    /// and colors are unchanged. Layout code in `Plan2D` is linear in these values, so
    /// the scaled plan's bounds and dimension layouts are the original ones times `factor`.
    static func scaledPlan(_ plan: Plan2D, by factor: Double) -> Plan2D {
        var result = plan
        result.dimensionTextHeight = plan.dimensionTextHeight * factor
        result.entities = plan.entities.map { entity in
            Plan2D.Entity(layer: entity.layer, geometry: scaledGeometry(entity.geometry, by: factor))
        }
        return result
    }

    /// One entity's geometry with every length multiplied by `factor`.
    static func scaledGeometry(_ geometry: Plan2D.Geometry, by factor: Double) -> Plan2D.Geometry {
        switch geometry {
        case let .line(from, to):
            return .line(from: from * factor, to: to * factor)
        case let .polyline(points, closed):
            let scaled: [SIMD2<Double>] = points.map { point in point * factor }
            return .polyline(points: scaled, closed: closed)
        case let .arc(center, radius, startAngle, endAngle):
            return .arc(center: center * factor, radius: radius * factor, startAngle: startAngle, endAngle: endAngle)
        case let .circle(center, radius):
            return .circle(center: center * factor, radius: radius * factor)
        case let .text(position, height, string, rotation):
            return .text(position: position * factor, height: height * factor, string: string, rotation: rotation)
        case let .dimension(from, to, offset, label):
            return .dimension(from: from * factor, to: to * factor, offset: offset * factor, label: label)
        }
    }

    /// Name of the plan layer the units note goes on: `notesLayerName` when the plan
    /// declares or uses it (exact match first, then ignoring case), else
    /// `fallbackNotesLayerName`.
    static func notesLayer(in plan: Plan2D) -> String {
        let layers = plan.resolvedLayers()
        if layers.contains(where: { $0.name == notesLayerName }) { return notesLayerName }
        if let match = layers.first(where: { $0.name.caseInsensitiveCompare(notesLayerName) == .orderedSame }) {
            return match.name
        }
        return fallbackNotesLayerName
    }

    /// The units note as a horizontal text entity below the drawing. `plan` is already in
    /// output units; `unitsPerMeter` is 1000 for millimeters and 1 for meters. The note
    /// uses the plan's dimension text height, its baseline starts at the left edge of the
    /// bounds and sits two note heights below their bottom, so its top clears the
    /// drawing by one note height. A plan without finite bounds gets the note at the origin.
    static func unitsNoteEntity(_ note: String, for plan: Plan2D, unitsPerMeter: Double) -> Plan2D.Entity {
        let planHeight = plan.dimensionTextHeight
        let height: Double = planHeight.isFinite && planHeight > 0 ? planHeight : defaultNoteHeightMeters * unitsPerMeter
        var position = SIMD2<Double>(0, 0)
        if let bounds = plan.bounds() {
            position = SIMD2<Double>(bounds.min.x, bounds.min.y - 2 * height)
        }
        let geometry = Plan2D.Geometry.text(position: position, height: height, string: note, rotation: 0)
        return Plan2D.Entity(layer: notesLayer(in: plan), geometry: geometry)
    }
}
