import Foundation

extension Copy {
    /// Room dimension list: group names, element names and row labels (MeasureCore), plus the
    /// words VoiceOver uses to read measurements with their units spoken in full
    /// (docs/UX_COPY.md, VoiceOver section).
    enum MeasureCore {
        /// Group headings of the dimension list.
        static let roomGroup = "Room", wallsGroup = "Walls", doorsGroup = "Doors", windowsGroup = "Windows"
        /// Group heading for object sizes.
        static let objectsGroup = "Objects"

        /// Name of the n-th wall in loop order, counted from 1.
        static func wallTitle(_ n: Int) -> String { "Wall \(n)" }
        /// Name of the n-th door, counted from 1.
        static func doorTitle(_ n: Int) -> String { "Door \(n)" }
        /// Name of the n-th window, counted from 1.
        static func windowTitle(_ n: Int) -> String { "Window \(n)" }
        /// Name of the n-th open passage (an opening without a door), counted from 1.
        static func openingTitle(_ n: Int) -> String { "Opening \(n)" }
        /// Name of a detected object that has no user label.
        static let objectTitle = "Object"

        /// Row labels for windows and open passages.
        static let windowWidth = "Window width", windowHeight = "Window height"
        static let openingWidth = "Opening width", openingHeight = "Opening height"

        /// Note shown with the Walls group.
        static let wallAreaNote = "Doors and windows are not counted in wall area."

        /// Row name read as one phrase: "Wall 1, Wall length".
        static func rowName(element: String, measure: String) -> String { "\(element), \(measure)" }
        /// A spoken measurement followed by its spoken accuracy.
        static func spokenWithAccuracy(_ measurement: String, accuracy: String) -> String { "\(measurement), \(accuracy)" }

        /// Unit words for VoiceOver: `12' 7 3/8"` reads "12 feet 7 and 3 eighths inches".
        enum Spoken {
            /// Length units.
            static let foot = "foot", feet = "feet", inch = "inch", inches = "inches"
            static let meters = "meters", millimeters = "millimeters"
            /// Area and volume units.
            static let squareFeet = "square feet", squareMeters = "square meters"
            static let cubicFeet = "cubic feet", cubicMeters = "cubic meters"
            /// Angle unit.
            static let degrees = "degrees"
            /// Joins whole inches and a fraction: "7 and 3 eighths inches".
            static let and = "and"
            /// Follows a fraction with no whole inches: "3 eighths of an inch".
            static let ofAnInch = "of an inch"
            /// Leading word for a negative number.
            static let minus = "minus"

            /// "1 half", "3 quarters", "3 eighths", "5 sixteenths"; other denominators stay "a/b".
            static func fraction(_ numerator: Int, _ denominator: Int) -> String {
                let one = numerator == 1
                switch denominator {
                case 2: return "\(numerator) " + (one ? "half" : "halves")
                case 4: return "\(numerator) " + (one ? "quarter" : "quarters")
                case 8: return "\(numerator) " + (one ? "eighth" : "eighths")
                case 16: return "\(numerator) " + (one ? "sixteenth" : "sixteenths")
                default: return "\(numerator)/\(denominator)"
                }
            }
        }
    }
}
