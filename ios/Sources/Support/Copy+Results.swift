import Foundation

extension Copy {
    /// Result screen text that `Copy.Viewer`, `Copy.Processing`, `Copy.Measure` and
    /// `Copy.Errors` do not already hold (Results, docs/MODULES.md 3.26; docs/UX_COPY.md
    /// sections 7 to 9). Status lines have no final period; longer help text does.
    enum Results {
        /// Object card title: an honest guess, since build 4 cannot correct the category yet.
        static func objectGuess(_ category: String) -> String { "Mapper thinks this is a \(category)." }
        /// Legend button and the Show All control of the filtered measurement list.
        static let legend = "Legend", showAll = "Show All"
        /// A processing step with its progress, for example "Adding color and texture 40%".
        static func stepProgress(_ step: String, percent: Int) -> String { "\(step) \(percent)%" }
        /// Realistic while the texture step still runs.
        static let colorPreparing = "Color is still being added"
        /// Realistic fallback: RoomPlan's own model in Quick Look.
        static let simpleModel = "View Simple Model"
        static let simpleModelNote = "A simple model from the room scan, without color."
        /// 3D Clean and Floor Plan when RoomPlan found no walls.
        static let noWalls = "Floor plans need walls. This scan has none."
        /// Title of the measurement list.
        static let dimensionsTitle = "Measurements"
        /// Photo Realistic entry of the Display menu in build 4.
        static let photoRealisticLater = "Photo Realistic comes in a later version"

        /// Realistic when no color was captured (Demo Mode rooms, or no keyframes and no RoomPlan model).
        static let noColor = "No color was captured for this scan"
        /// A tab whose files do not exist yet while nothing is processing.
        static let notReady = "Not ready yet"
        /// Raw Scan when the detailed scan did not record.
        static let noDetailedScan = "The detailed 3D scan didn't record for this room"
        /// Processing view while the job waits in the queue.
        static let waiting = "Waiting to start"
        /// Toolbar count of missing areas, for example "Missing areas: 3".
        static func missingAreasCount(_ count: Int) -> String { "\(Copy.Quality.missingAreas): \(count)" }
        /// Menu of the floor plan layer toggles.
        static let layers = "Layers"
        /// VoiceOver hint of the project title, which opens Rename.
        static let titleHint = "Rename this project"
        /// VoiceOver hint of the Measurements header, which shows or hides the list.
        static let dimensionsHint = "Shows or hides the measurements"
        /// Accessibility hints of the four views (docs/UX_COPY.md section 8, View switcher).
        static let realisticHint = "Photo-like model", cleanHint = "Simple walls, floor and objects"
        static let floorPlanHint = "Top-down drawing", rawHint = "Exactly what the scanner recorded"
        /// One line under the measurement list when a capture stream was missing (D16).
        static let degradedDepth = "Some depth data was missing, so these numbers are rough."
        static let degradedMesh = "The detailed 3D scan didn't record. Walls and the floor plan are fine."
        /// Shown while RoomPlan's model is being prepared for Quick Look.
        static let simpleModelPreparing = "Preparing the simple model..."
    }
}
