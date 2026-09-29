import Foundation

extension Copy {
    /// House / Building flow text that UX_COPY.md section 5 does not already have (docs/MODULES.md
    /// 3.41): relocalization on a later visit, Start Fresh Here, the room list extras, the
    /// "Join Rooms Again" offer after a failed merge and the manual alignment screen.
    enum HouseUI {
        /// Title of the relocalization screen (Continue Scanning, Rescan, next room after a stop).
        static let relocalizeTitle = "Go back to a room you already scanned"
        /// Body of the relocalization screen.
        static let relocalizeBody = "Point your iPhone at its walls and move slowly. Mapper will find its place."
        /// Small status line while Mapper looks for a saved room.
        static let relocalizeHint = "Looking for rooms you already scanned"
        /// Button: give up looking and start an unaligned session here.
        static let startFresh = "Start Fresh Here"
        /// Button: look for the saved rooms 30 more seconds.
        static let keepLooking = "Keep Looking"
        /// Shown with Start Fresh Here after 30 seconds without a match.
        static let startFreshBody = "Mapper couldn't find where you are. New rooms will need lining up by hand."
        /// Title when the house has no saved room map to look for.
        static let noMapTitle = "Nothing to line up with"
        /// Body when the house has no saved room map to look for.
        static let noMapBody = "This house has no saved room to find. New rooms will need lining up by hand."
        /// RoomPlan gave up right after relocalizing (scene too large): start fresh.
        static let relocalizeLost = (title: "Mapper lost its place",
                                     body: "Start fresh here and line up the new rooms by hand later.")
        /// Room list status of a room parked beside the building until it is lined up.
        static func roomNeedsLineUp(_ room: String) -> String { "\(room) needs lining up" }
        /// Room title with its floor on the scan screen, for example "Kitchen, Floor 1".
        static func roomChip(_ room: String, floor: String) -> String { "\(room), \(floor)" }
        /// Hint at the start of each next room.
        static let nextRoomHint = "Start at the doorway you walked in through"
        /// Room list banner when available memory is low after a room (D17).
        static let lowMemoryHint = "Your iPhone is low on memory. Finish Building now and scan the rest later."
        /// Button: run the automatic merge again after it crashed.
        static let joinRoomsAgain = "Join Rooms Again"
        /// Alert title after a crashed merge.
        static let mergeFailedTitle = "Rooms weren't joined automatically"
        /// Alert body after a crashed merge.
        static let mergeFailedBody = "Your rooms are saved. Try joining them again, or line them up by hand."
        /// Title of the manual alignment screen.
        static let lineUpTitle = "Line Up Rooms"
        /// Hint on the manual alignment screen.
        static let lineUpHint = "Drag the room into place. Turn it with two fingers."
        /// Button: turn the room 90 degrees counter-clockwise.
        static let turnLeft = "Turn Left"
        /// Button: turn the room 90 degrees clockwise.
        static let turnRight = "Turn Right"
        /// Snap note: the room's doorway lines up with a neighbor's doorway.
        static let snappedDoorway = "Lined up with the doorway"
        /// Snap note: the room's wall lines up with a neighbor's wall.
        static let snappedWall = "Lined up with the wall"
        /// The House clean model does not hold the room yet.
        static let alignNotReady = "The rooms are still being built. Try again in a moment."
        /// VoiceOver hint of the alignment canvas.
        static let a11yMoveRoomHint = "Drag with one finger to move the room, two fingers to turn it"
    }
}
