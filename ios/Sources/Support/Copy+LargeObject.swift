import Foundation

extension Copy {
    /// Text of the large-object capture screen (docs/MODULES.md 3.39): the seed hints shown before
    /// the object is chosen, the sides progress, the box size line and the Choose Again button.
    /// Guidance while capturing comes from `GuidanceKind.message` (Copy.Guidance).
    enum LargeObject {
        /// Hint while waiting for the user to choose the object.
        static let tapToSelect = "Tap the object you want to scan"
        /// Hint while the tapped point is turned into an object outline.
        static let locating = "Finding the object..."
        /// Hint when no object was found at the tapped point.
        static let noObjectFound = "Couldn't find an object there. Tap the middle of it."
        /// Hint when the tapped point lies on a wall.
        static let tappedWall = "That looks like a wall. Tap the object instead."
        /// Button that drops the chosen object and asks for a new tap.
        static let chooseAgain = "Choose Again"
        /// Sides progress while capturing, for example "3 of 9 sides captured".
        static func sidesProgress(_ covered: Int, of total: Int) -> String { "\(covered) of \(total) sides captured" }
        /// Approximate size of the outline; each value is already formatted by Units.
        static func boxSize(width: String, depth: String, height: String) -> String {
            "About \(width) by \(depth) by \(height)"
        }
        /// VoiceOver label of the outline size line.
        static let a11yBox = "Outline of the selected object"
    }
}
