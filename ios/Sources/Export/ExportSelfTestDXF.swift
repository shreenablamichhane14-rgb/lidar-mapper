import Foundation
import simd

/// Checks for the millimeter DXF entry points with a units note (MODULES 3.18a, D23),
/// run from `ExportSelfTest.run()`. Kept in its own file so ExportSelfTest.swift stays
/// under the file size limit. Expected strings were derived from the writer's rules
/// (group code right-aligned in three columns, numbers with at most 6 decimals).
extension ExportSelfTest {
    /// Units note used by these checks (the export screen passes its own Copy text).
    static let dxfTestNote = "Units: millimeters"

    /// The meter DXF of `dxfLinePlan(withNotesLayer: false)` as written before the
    /// millimeter revision, as alternating group codes and values. `data(for:)` must
    /// keep producing exactly this.
    static let dxfLineGolden: [String] = [
        "0", "SECTION", "2", "HEADER", "9", "$ACADVER", "1", "AC1009", "9", "$EXTMIN", "10", "0",
        "20", "0", "30", "0.0", "9", "$EXTMAX", "10", "4", "20", "0", "30", "0.0",
        "0", "ENDSEC", "0", "SECTION", "2", "TABLES", "0", "TABLE", "2", "LTYPE", "70", "1",
        "0", "LTYPE", "2", "CONTINUOUS", "70", "0", "3", "Solid line", "72", "65", "73", "0",
        "40", "0.0", "0", "ENDTAB", "0", "TABLE", "2", "LAYER", "70", "2", "0", "LAYER",
        "2", "0", "70", "0", "62", "7", "6", "CONTINUOUS", "0", "LAYER", "2", "A-WALL",
        "70", "0", "62", "7", "6", "CONTINUOUS", "0", "ENDTAB", "0", "TABLE", "2", "STYLE",
        "70", "1", "0", "STYLE", "2", "STANDARD", "70", "0", "40", "0.0", "41", "1.0",
        "50", "0.0", "71", "0", "42", "0.2", "3", "txt", "4", "", "0", "ENDTAB",
        "0", "ENDSEC", "0", "SECTION", "2", "BLOCKS", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES",
        "0", "LINE", "8", "A-WALL", "10", "0", "20", "0", "30", "0.0", "11", "4",
        "21", "0", "31", "0.0", "0", "ENDSEC", "0", "EOF",
    ]

    /// Runs every millimeter DXF check: a 4 m wall line (placement, extents, note layer,
    /// meter output unchanged) and the two-room `plan` (radii, text heights, dimension
    /// offsets, entity counts, extents).
    static func checkDXFMillimeters(_ c: inout Checker, plan: Plan2D) {
        checkDXFMillimeterLine(&c)
        checkDXFMetersUnchanged(&c, plan: plan)
        checkDXFMillimeterPlan(&c, plan: plan)
        checkDXFMillimeterHelpers(&c, plan: plan)
    }

    /// One 4 m line from (0, 0) to (4, 0) on "A-WALL"; `withNotesLayer` also declares
    /// the "A-ANNO-NOTE" layer.
    static func dxfLinePlan(withNotesLayer: Bool) -> Plan2D {
        var layers = [Plan2D.Layer(name: "A-WALL", color: SIMD3<Float>(0, 0, 0))]
        if withNotesLayer {
            layers.append(Plan2D.Layer(name: DXFWriter.notesLayerName, color: SIMD3<Float>(0, 0, 1)))
        }
        let wall = Plan2D.Entity(layer: "A-WALL", geometry: .line(from: SIMD2<Double>(0, 0), to: SIMD2<Double>(4, 0)))
        return Plan2D(name: "Line", layers: layers, entities: [wall])
    }

    /// DXF text for alternating group codes and values, formatted like `DXFWriter`
    /// (code right-aligned in three columns, one line each, LF line endings).
    static func dxfPairs(_ flat: [String]) -> String {
        var text = ""
        var index = 0
        while index + 1 < flat.count {
            let code = flat[index]
            text += String(repeating: " ", count: max(0, 3 - code.count)) + code + "\n" + flat[index + 1] + "\n"
            index += 2
        }
        return text
    }

    /// The part of a DXF file after the ENTITIES section marker.
    static func dxfEntities(_ dxf: String) -> String {
        dxf.components(separatedBy: "  2\nENTITIES\n").last ?? ""
    }

    /// The first 400 characters of DXF text on one line ("|" for line breaks), for
    /// failure details.
    static func dxfSnippet(_ text: String) -> String {
        String(text.prefix(400)).replacingOccurrences(of: "\n", with: "|")
    }

    /// Value of group `code` that follows the header variable `variable` (for example
    /// code 20 of "$EXTMIN"), or nil when missing or not a number.
    static func dxfHeaderValue(_ dxf: String, variable: String, code: Int) -> Double? {
        let lines = dxf.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: variable) else { return nil }
        var index = start + 1
        while index + 1 < lines.count {
            guard let found = Int(lines[index].trimmingCharacters(in: .whitespaces)) else { return nil }
            if found == code { return Double(lines[index + 1]) }
            if found == 0 || found == 9 { return nil }
            index += 2
        }
        return nil
    }

    /// Millimeter output of the 4 m line: coordinates, note text, placement and layer,
    /// extents with and without the note, R12 without `$INSUNITS`, blank note, and the
    /// note in meter output.
    private static func checkDXFMillimeterLine(_ c: inout Checker) {
        let note = dxfTestNote
        let line = dxfLinePlan(withNotesLayer: false)
        do {
            let mm = try DXFWriter.text(for: line, millimeters: true, unitsNote: note)
            let entities = dxfEntities(mm)
            let wall = dxfPairs(["10", "0", "20", "0", "30", "0.0", "11", "4000", "21", "0", "31", "0.0"])
            c.check("dxfmm.line4000", entities.contains(wall), dxfSnippet(entities))
            let noteCount = occurrences(of: dxfPairs(["1", note]), in: mm)
            let textCount = occurrences(of: "  0\nTEXT\n", in: entities)
            c.check("dxfmm.noteOnce", noteCount == 1 && textCount == 1, "note \(noteCount), TEXT \(textCount)")
            let noteEntity = dxfPairs(["0", "TEXT", "8", "0", "10", "0", "20", "-240", "30", "0.0", "40", "120",
                                       "1", note, "50", "0", "7", "STANDARD"])
            c.check("dxfmm.notePlacement", entities.contains(noteEntity), dxfSnippet(entities))
            let extents = dxfPairs(["9", "$EXTMIN", "10", "0", "20", "-276", "30", "0.0",
                                    "9", "$EXTMAX", "10", "4000", "20", "0", "30", "0.0"])
            c.check("dxfmm.extentsWithNote", mm.contains(extents))
            let header = dxfPairs(["0", "SECTION", "2", "HEADER", "9", "$ACADVER", "1", "AC1009"])
            let isR12 = mm.hasPrefix(header) && mm.hasSuffix(dxfPairs(["0", "EOF"]))
            let noUnitsVariable = !mm.contains("$INSUNITS") && !mm.contains("  0\nDIMENSION\n")
            let lineCount = mm.split(separator: "\n", omittingEmptySubsequences: false).count
            c.check("dxfmm.r12NoInsunits", isR12 && noUnitsVariable && lineCount % 2 == 1)

            let bare = try DXFWriter.text(for: line, millimeters: true, unitsNote: nil)
            let bareExtents = dxfPairs(["9", "$EXTMIN", "10", "0", "20", "0", "30", "0.0",
                                        "9", "$EXTMAX", "10", "4000", "20", "0", "30", "0.0"])
            c.check("dxfmm.extentsNoNote", bare.contains(bareExtents) && !bare.contains("  0\nTEXT\n"))
            let blank = try DXFWriter.text(for: line, millimeters: true, unitsNote: " \n")
            c.check("dxfmm.blankNoteSkipped", blank == bare)

            let named = try DXFWriter.text(for: dxfLinePlan(withNotesLayer: true), millimeters: true, unitsNote: note)
            let onNotesLayer = named.contains(dxfPairs(["0", "TEXT", "8", DXFWriter.notesLayerName]))
            let layerEntries = occurrences(of: "  0\nLAYER\n", in: named)
            c.check("dxfmm.notesLayer", onNotesLayer && layerEntries == 3, "layers \(layerEntries)")

            let meters = try DXFWriter.text(for: line, millimeters: false, unitsNote: note)
            let metersWall = meters.contains(dxfPairs(["11", "4", "21", "0"]))
            let metersNote = meters.contains(dxfPairs(["20", "-0.24", "30", "0.0", "40", "0.12", "1", note]))
            c.check("dxfmm.metersWithNote", metersWall && metersNote)
        } catch {
            c.fail("dxfmm.line", error)
        }
    }

    /// `data(for:)` still writes meters without a note, byte for byte, and the new entry
    /// point with `millimeters: false, unitsNote: nil` writes the same bytes.
    private static func checkDXFMetersUnchanged(_ c: inout Checker, plan: Plan2D) {
        do {
            let golden = Data(dxfPairs(dxfLineGolden).utf8)
            let meters = try DXFWriter.data(for: dxfLinePlan(withNotesLayer: false))
            c.check("dxfmm.metersGolden", meters == golden, "\(meters.count) bytes, expected \(golden.count)")
            let old = try DXFWriter.data(for: plan)
            let same = try DXFWriter.data(for: plan, millimeters: false, unitsNote: nil)
            c.check("dxfmm.metersSameAsBefore", old == same, "\(old.count) vs \(same.count) bytes")
        } catch {
            c.fail("dxfmm.meters", error)
        }
    }

    /// Millimeter output of the two-room plan: entity counts (one more TEXT), text
    /// heights, radii with unchanged angles, dimension offset, layer table, scaled extents
    /// and the note below the drawing.
    private static func checkDXFMillimeterPlan(_ c: inout Checker, plan: Plan2D) {
        do {
            let meters = try DXFWriter.text(for: plan)
            let mm = try DXFWriter.text(for: plan, millimeters: true, unitsNote: dxfTestNote)
            let bare = try DXFWriter.text(for: plan, millimeters: true, unitsNote: nil)
            let entities = dxfEntities(mm)
            let expected: [String: Int] = ["POLYLINE": 2, "VERTEX": 8, "SEQEND": 2, "ARC": 1, "CIRCLE": 1, "TEXT": 5, "LINE": 11]
            let kinds = expected.keys.sorted()
            let counts = kinds.map { occurrences(of: "  0\n\($0)\n", in: entities) }
            let wanted = kinds.map { expected[$0] ?? -1 }
            c.check("dxfmm.entityCounts", counts == wanted, "\(kinds) \(counts)")
            // Heights are read from the output without the note, which is also 120 mm tall.
            let bareEntities = dxfEntities(bare)
            let roomNameHeight = bareEntities.contains(dxfPairs(["40", "250"]))
            let dimensionHeight = bareEntities.contains(dxfPairs(["40", "120"]))
            c.check("dxfmm.textHeights", roomNameHeight && dimensionHeight)
            let arc = dxfPairs(["10", "4000", "20", "1000", "30", "0.0", "40", "800", "50", "0", "51", "90"])
            let circle = dxfPairs(["10", "6500", "20", "2500", "30", "0.0", "40", "150"])
            c.check("dxfmm.radii", entities.contains(arc) && entities.contains(circle))
            let dimensionLine = dxfPairs(["10", "0", "20", "-500", "30", "0.0", "11", "4000", "21", "-500", "31", "0.0"])
            c.check("dxfmm.dimensionOffset", entities.contains(dimensionLine))
            let mmLayers = occurrences(of: "  0\nLAYER\n", in: mm)
            let meterLayers = occurrences(of: "  0\nLAYER\n", in: meters)
            c.check("dxfmm.noNewLayers", mmLayers == meterLayers, "\(mmLayers) vs \(meterLayers)")

            var scaled = true
            for variable in ["$EXTMIN", "$EXTMAX"] {
                for code in [10, 20] {
                    if let m = dxfHeaderValue(meters, variable: variable, code: code),
                       let millimeters = dxfHeaderValue(bare, variable: variable, code: code) {
                        let difference = abs(millimeters - m * 1000)
                        scaled = scaled && difference < 0.01
                    } else {
                        scaled = false
                    }
                }
            }
            c.check("dxfmm.extentsScaled", scaled)
            let drawingBottom = dxfHeaderValue(bare, variable: "$EXTMIN", code: 20) ?? 0
            let withNoteBottom = dxfHeaderValue(mm, variable: "$EXTMIN", code: 20) ?? 0
            c.check("dxfmm.noteBelowDrawing", withNoteBottom < drawingBottom - 100, "\(withNoteBottom) vs \(drawingBottom)")
        } catch {
            c.fail("dxfmm.plan", error)
        }
    }

    /// `scaledPlan` scales bounds and dimension text height, `notesLayer` finds the notes
    /// layer ignoring case and falls back to "0", and an empty plan still throws.
    private static func checkDXFMillimeterHelpers(_ c: inout Checker, plan: Plan2D) {
        let scaled = DXFWriter.scaledPlan(plan, by: 1000)
        if let original = plan.bounds(), let bigger = scaled.bounds() {
            let low = simd_length(bigger.min - original.min * 1000)
            let high = simd_length(bigger.max - original.max * 1000)
            let height = abs(scaled.dimensionTextHeight - plan.dimensionTextHeight * 1000)
            c.check("dxfmm.scaledBounds", low < 1e-6 && high < 1e-6 && height < 1e-9, "\(low) \(high) \(height)")
        } else {
            c.check("dxfmm.scaledBounds", false, "no bounds")
        }
        let wall = Plan2D.Entity(layer: "A-WALL", geometry: .line(from: SIMD2<Double>(0, 0), to: SIMD2<Double>(1, 0)))
        let lowerCase = Plan2D(name: "x", layers: [Plan2D.Layer(name: "a-anno-note", color: SIMD3<Float>(0, 0, 0))], entities: [wall])
        let found = DXFWriter.notesLayer(in: lowerCase)
        let fallback = DXFWriter.notesLayer(in: dxfLinePlan(withNotesLayer: false))
        c.check("dxfmm.notesLayerLookup", found == "a-anno-note" && fallback == "0", "\(found) \(fallback)")
        c.expectError("dxfmm.emptyPlan", {
            _ = try DXFWriter.text(for: Plan2D(name: "x", layers: [], entities: []), millimeters: true, unitsNote: dxfTestNote)
        }) {
            if case .emptyPlan = $0 { return true }
            return false
        }
    }
}
