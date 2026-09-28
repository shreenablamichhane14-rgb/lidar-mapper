import Foundation

extension Copy {
    /// Alerts for how a room scan ended (docs/MODULES.md 3.21). The room engine reports these
    /// as `MapperError` values after the room was saved; ScanUI's `ScanErrorCopy` shows them.
    enum RoomCapture {
        /// `MapperError.sceneTooLarge` (RoomPlan's scene size limit; the partial room is kept).
        static let sceneTooLarge = (title: "This room is too big for one scan",
                                    body: "Your scan so far is saved. Finish here and scan the rest as a new project.")
        /// `MapperError.roomPlanFailed` (no walls, doors or windows; the 3D scan is kept).
        static let roomPlanFailed = (title: "Walls couldn't be found",
                                     body: "Your scan is saved. The 3D scan still works, but there is no floor plan or room measurements.")
        /// `MapperError.deviceTooHot` after the engine finished the room itself (used instead of
        /// `Copy.Errors.tooHot`, whose body says "paused").
        static let tooHotFinished = (title: "Your iPhone is too hot",
                                     body: "Scanning stopped to let it cool down. Your scan is saved.")
        /// `MapperError.lowMemory` after the engine finished the room itself.
        static let lowMemory = (title: "Mapper needed to stop the scan",
                                body: "Your iPhone was running low on memory. Your scan is saved.")
    }
}
