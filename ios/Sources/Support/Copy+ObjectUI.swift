import Foundation

/// Strings of the ObjectUI module (docs/MODULES.md 3.42).
extension Copy {
    /// Object flow and object result text that `Copy.Viewer`, `Copy.Processing`, `Copy.Measure`
    /// and `Copy.Errors` do not already hold: the size chooser, the reconstruction stages, the
    /// time left, the size panel and the reconstruction notes. Status lines have no final period;
    /// longer help text does.
    enum ObjectUI {
        /// Size chooser heading.
        static let sizeTitle = "How big is it?"
        /// Small or medium choice (Object Capture) and its detail line.
        static let smallMedium = "Small or Medium"
        static let smallMediumDetail = "Fits on a table or a chair. You walk all the way around it."
        /// Large choice (the LiDAR mesh driver) and its detail line.
        static let large = "Large"
        static let largeDetail = "An appliance, a vehicle or equipment."

        /// Reconstruction stages shown on the processing view (meshGeneration and textureMapping
        /// use `Copy.Processing.stepShape` and `stepTextures`).
        static let stagePreparing = "Getting your photos ready"
        static let stageAligning = "Lining up your photos"
        static let stageDetail = "Adding detail"
        static let stageFinishing = "Finishing up"
        /// The measuring step after the model is built.
        static let stageMeasuring = "Measuring your object"

        /// The processing view while the job waits in the queue.
        static let waiting = "Waiting to start"

        /// Preflight alert when the phone is too hot to start an object scan.
        static let tooHotToStart = (title: "Your iPhone is too hot", body: "Let it cool down for a few minutes, then try again.")

        /// Time left of a reconstruction, minutes rounded up: "About 3 min left".
        static func remainingMinutes(_ minutes: Int) -> String { "About \(minutes) min left" }
        /// Time left under a minute.
        static let remainingSoon = "Less than a minute left"

        /// Heading of the size panel (width, height, depth, surface area, volume).
        static let sizeSection = "Size"

        /// Note when the reconstruction shrank the photos to fit in memory.
        static let downsampledNote = "Your photos were made smaller to fit in memory, so the model may show less detail."
        /// Note when a flipped side did not join the rest of the model.
        static let stitchingNote = "Some sides didn't join up, so parts of the model may be missing."

        /// Volume row when the model is closed but encloses no measurable volume (the open
        /// model case uses `Copy.Viewer.volumeUnavailable`).
        static let volumeTooThin = "Volume unavailable: the object is too thin to measure"
        /// Result screen of a project that holds no object.
        static let noObject = (title: "No object in this project", body: "This project has no saved object scan.")
    }
}
