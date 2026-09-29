import Foundation

/// Export sheet strings added by the ExportUI module (docs/MODULES.md 3.27). `Copy.Export`
/// itself is declared in `Copy.swift`; this file adds the new `Copy.ExportUI` enum only.
extension Copy {
    /// Export sheet text that `Copy.Export` does not already hold (ExportUI, docs/MODULES.md 3.27,
    /// docs/UX_COPY.md section 14): section titles, option labels, availability reasons and the
    /// notes written into exported files.
    enum ExportUI {
        /// Section titles of the export sheet, one per representation.
        static let realisticSection = "3D Model with Color", cleanSection = "3D Clean Model", rawSection = "Raw Scan"
        static let planSection = "Floor Plan", dataSection = "Data"

        /// Shown under raw OBJ and USDZ when the scan is too big for them at full detail.
        static let simplifiedNote = "Simplified to keep the file a manageable size."

        /// Caption before the drawing scale in the PDF title block ("Scale 1/4\" = 1'-0\"").
        static let scaleCaption = "Scale"

        /// Paper size option of the PDF floor plan.
        static let paper = "Paper Size", letter = "US Letter", a4 = "A4"

        /// Text note written into every DXF floor plan (D23: the file has no units header).
        static let dxfUnitsNote = "Units: millimeters"

        /// Explanation of DXF on the sheet: the drawing is always in millimeters.
        static let dxfDetail = "Floor plan for AutoCAD and other CAD programs. Drawn in millimeters."

        /// Units option of DXF: it changes only the text labels, not the drawing units.
        static let labelUnits = "Label units"

        /// Explanation of PLY in build 4 (class colors, not photo color).
        static let plyDetail = "The raw scan shape for 3D and research software."

        /// Reason shown while color is still being added.
        static let colorNotReady = "Not available yet: color is still being added"

        /// Reason shown when processing ended without color although color was captured
        /// (Results offers Try Again).
        static let colorMissing = "Not available: color couldn't be added. Try again from the result screen."

        /// Units option: follow the app's unit setting.
        static let unitsApp = "Same as the app"

        /// Heading of the options section.
        static let optionsSection = "Options"

        /// Button that closes the export sheet.
        static let done = "Done"

        /// Reason shown for 3D Clean and Data when the scan found no walls.
        static let noWalls = "Not available: this scan has no walls"

        /// Reason shown for Raw Scan when the scan shape was not built.
        static let noRawScan = "Not available: the raw scan isn't ready"

        /// First word of an exported file name when the project name does not start with a
        /// letter (RoomPlan and some programs reject names that start with a digit).
        static let fileNamePrefix = "Mapper"
    }
}

/// Build 5 export strings (docs/MODULES.md 3.43d): object exports, multi-floor plan files.
extension Copy.ExportUI {
    /// Reason shown for an object's model and data until reconstruction and measuring finish.
    static let objectNotReady = "Not available yet: the model is still being built"

    /// Explanation of the object USDZ on the sheet.
    static let objectDetail = "The scanned object as a 3D model for iPhone, iPad and Mac."

    /// File name part of one floor of a multi-floor plan ("Floor2"), before the extension.
    static func levelSuffix(_ n: Int) -> String { "Floor\(n)" }

    /// Title of one floor's drawing in a multi-floor plan: the project name, then the floor
    /// ("Maple Street, Floor 2").
    static func levelPlanName(_ project: String, level: String) -> String {
        project.isEmpty ? level : "\(project), \(level)"
    }
}
