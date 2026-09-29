import Foundation

extension Copy {
    /// Measuring inside the finished model (MeasureTool, docs/MODULES.md 3.35): tool names, the
    /// hint for the next tap, the list's rename and delete texts and the VoiceOver names of the
    /// draggable points. Guidance hints are sentences without a final period (UX_COPY voice rules).
    enum MeasureTool {
        /// Picker title of the Area tool.
        static let area = "Area"

        /// Distance and Height tools: first and second tap.
        static let tapFirst = "Tap where the measurement starts", tapSecond = "Now tap where it ends"

        /// Wall tool: the tap, and a tap that did not land on a wall.
        static let tapWall = "Tap a wall", noWall = "That isn't a wall. Tap a wall"

        /// Area tool: first corner, following corners, and closing the area.
        static let areaFirst = "Tap the first corner of the area", areaNext = "Tap the next corner"
        static let areaClose = "Tap the first point again, or tap Finish Area"

        /// Button that closes the area being placed.
        static let finishArea = "Finish Area"

        /// Angle tool: first side, corner, second side.
        static let angleFirst = "Tap a point on the first side", angleCorner = "Tap the corner"
        static let angleSecond = "Tap a point on the second side"

        /// A tap that missed the model.
        static let noSurface = "Tap on the model"

        /// A measurement without a user name: its kind title numbered per kind ("Distance 2").
        static func numbered(_ title: String, _ n: Int) -> String { "\(title) \(n)" }

        /// Rename alert.
        static let renameTitle = "Rename Measurement", namePlaceholder = "Measurement name"

        /// Delete All button and its confirmation.
        static let deleteAll = "Delete All", deleteAllTitle = "Delete all measurements?"
        static let deleteAllBody = "Only the measurements you made in this model are removed. Your scan is not affected."

        /// VoiceOver name and hint of a draggable measurement point, counted from 1.
        static func pointLabel(_ n: Int) -> String { "Point \(n)" }
        static let pointHint = "Drag to move this point"
    }
}
