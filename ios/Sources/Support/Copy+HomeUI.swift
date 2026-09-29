import Foundation

extension Copy {
    /// Home screen and mode picker text that `Copy.Home`, `Copy.Modes` and `Copy.Project` do not
    /// already hold (HomeUI, docs/UX_COPY.md sections 1, 2 and 13).
    enum HomeUI {
        /// Shown under a scan mode that cannot start when AppShell passed no reason for it (build 4:
        /// every mode but Room; build 5 shows the passed reason instead when there is one).
        static let comingLater = "Coming in a later version"
        /// Placeholder of the text field in the Rename Project alert.
        static let namePlaceholder = "Project name"
        /// Subtitle of a House project with exactly one room, for example "1 room, Sep 28"
        /// (`Copy.Home.houseSubtitle` reads "{n} rooms, {date}" for every other count).
        static func houseOneRoomSubtitle(_ date: String) -> String { "1 room, \(date)" }
    }
}
