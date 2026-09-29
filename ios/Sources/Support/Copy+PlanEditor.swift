import Foundation

extension Copy {
    /// Floor plan editor strings added by the PlanEditor module (docs/MODULES.md 3.37). The
    /// action names, split and merge hints, reset dialog and placeholders are in
    /// `Copy.FloorPlan` (Copy.swift); these are the editor's own hints, refusals, symbols and the
    /// one-line descriptions of edit operations.
    enum PlanEditor {
        /// Hints shown above the inspector for the active tool.
        static let selectHint = "Tap a wall, door, window, room or label to change it"
        static let wallStartHint = "Tap where the wall starts", wallEndHint = "Tap where the wall ends"
        static let openingHint = "Tap a wall to place it", tapWall = "Tap on a wall"
        static let dimensionStartHint = "Tap the first point", dimensionEndHint = "Tap the second point"
        static let annotationHint = "Tap where it goes", splitEndHint = "Now tap the other side of the room"

        /// Commands, the measurement item name, the snapping toggle and the VoiceOver item menu.
        static let turn = "Turn", editText = "Edit Text", resizeOpening = "Resize Opening"
        static let measurementItem = "Measurement", snapping = "Snap to walls and grid", elements = "Plan Items"

        /// VoiceOver hint of the editing canvas.
        static let canvasHint = "Drag to move, pinch to zoom. Drag a selected item to change it"

        /// A typed length that could not be read.
        static let invalidLength = "Type a length, for example 12' 6\" or 3.8 m."
        /// A wall would end shorter than the minimum length (formatted with Units).
        static func tooShort(_ length: String) -> String { "Walls must be at least \(length) long." }
        /// A typed value outside its range (both ends formatted with Units).
        static func outOfRange(_ low: String, _ high: String) -> String { "Use a value from \(low) to \(high)." }

        /// Refusals of edits that cannot be made.
        static let curvedWall = "Curved walls can't be moved or resized."
        static let lockedWall = "The floor plan is being updated. Try again in a moment."
        static let splitMisses = "Draw the line all the way across the room."
        static let nothingToMerge = "Tap at least one more room to join."
        static let notOnLevel = "Rooms on different floors can't be joined."
        static let notFound = "That part of the plan changed. Try again."

        /// Add Symbol choices (stored in the annotation and drawn as text on the plan).
        static let symbolOutlet = "Outlet", symbolSwitch = "Switch", symbolLight = "Light"
        static let symbolSmokeAlarm = "Smoke Alarm", symbolWater = "Water", symbolGas = "Gas"
        static let symbolVent = "Vent", symbolThermostat = "Thermostat"

        /// What snapping did to the last drawn or dragged point (the snap line).
        static let snappedEnd = "Snapped to a wall end", snappedWall = "Snapped to a wall"
        static let snappedAngle = "Lined up with the walls", snappedGrid = "Snapped to the grid"

        /// One line per edit operation kind (Results' list of edits that no longer fit the scan).
        static let editRoomRenamed = "Room renamed", editObjectRenamed = "Object renamed"
        static let editCategoryChanged = "Category changed", editHidden = "Hidden or shown", editDeleted = "Deleted"
        static let editObjectMoved = "Furniture moved", editWallMoved = "Wall moved", editWallAdded = "Wall added"
        static let editOpeningAdded = "Door or window added", editSwingChanged = "Door swing changed"
        static let editThicknessChanged = "Wall thickness changed", editLabelAdded = "Label added"
        static let editMeasurementAdded = "Measurement added", editScaleCorrected = "Size corrected"
        static let editRoomLinedUp = "Room lined up", editObjectCropped = "Object cropped"
        static let editOpeningMoved = "Door or window moved", editOpeningResized = "Door or window resized"
        static let editRoomsMerged = "Rooms merged", editRoomSplit = "Room split"
        /// An edit group with nothing in it (never written by the editor).
        static let editEmpty = "Plan edited"
    }
}
