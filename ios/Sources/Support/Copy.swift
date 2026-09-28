import Foundation

/// Every user-facing string in Mapper. Mirrors docs/UX_COPY.md; change both together.
/// Views read from here and never hardcode text. Strings are Title Case; any ALL CAPS look
/// is applied with `.textCase(.uppercase)`.
enum Copy {

    /// Projects list (home screen).
    enum Home {
        static let title = "Projects", newScan = "New Scan", searchPrompt = "Search projects"
        static let sortRecent = "Most Recent", sortName = "Name", showArchived = "Show Archived"
        static let archivedTitle = "Archived", settings = "Settings", needsWorkBadge = "Needs another scan"
        static let processingBadge = "Building model..."
        static let privacyFooter = "Your scans stay on this iPhone. No account needed."
        static func roomSubtitle(_ date: String) -> String { "Room, \(date)" }
        static func houseSubtitle(rooms: Int, date: String) -> String { "\(rooms) rooms, \(date)" }
        static func objectSubtitle(_ date: String) -> String { "Object, \(date)" }
        static func measureSubtitle(_ date: String) -> String { "Quick Measure, \(date)" }
        static func defaultRoomName(_ date: String) -> String { "Room \(date)" }
        static func defaultHouseName(_ date: String) -> String { "House \(date)" }
        static func defaultObjectName(_ date: String) -> String { "Object \(date)" }
        static func defaultMeasureName(_ date: String) -> String { "Measurement \(date)" }
    }

    /// Mode picker shown after New Scan, plus Advanced Scan options.
    enum Modes {
        static let title = "What do you want to scan?", cancel = "Cancel", room = "Room"
        static let roomDetail = "One room. Get a 3D model, floor plan and measurements."
        static let house = "House / Building", object = "Object"
        static let houseDetail = "Several rooms, one at a time, joined into one model."
        static let objectDetail = "Furniture, appliances or anything you can walk around."
        static let quickMeasure = "Quick Measure"
        static let quickMeasureDetail = "Measure a distance or a wall right now. Nothing to scan."
        static let advanced = "Advanced Scan"
        static let advancedDetail = "Choose detail level and what to keep. For experienced users."

        /// Advanced Scan options screen.
        enum Advanced {
            static let title = "Advanced Scan", scanType = "What are you scanning?", scanTypeSpace = "A space"
            static let scanTypeObject = "An object", detail = "Detail", detailStandard = "Standard"
            static let detailHigh = "High", detailMaximum = "Maximum"
            static let detailFooter = "More detail makes bigger files and takes longer to build."
            static let keepPhotos = "Keep all photos"
            static let keepPhotosFooter = "Photos make the model look real. They use more storage."
            static let detectRooms = "Find walls, doors and windows"
            static let detectObjects = "Find furniture and appliances", range = "Scanning distance"
            static let rangeNear = "Close up", rangeNormal = "Normal", rangeFar = "Far", start = "Start Scan"
        }
    }

    /// Tips shown before the first scan of each mode.
    enum Onboarding {
        static let start = "Start Scan", dontShowAgain = "Don't show again", skip = "Skip"
        static let room = [
            "Turn on the lights and open the curtains.",
            "Start in a corner, facing the middle of the room.",
            "Walk slowly along the walls, keeping the phone at chest height.",
            "Point at the floor, then the ceiling, as you go.",
            "End back where you started.",
        ]
        static let house = [
            "Scan one room at a time. You can take breaks between rooms.",
            "Start each room at the doorway you walked in through.",
            "Scan every doorway from both sides so rooms join up correctly.",
            "Keep doors open while you scan.",
            "Name each room when you finish it.",
        ]
        static let object = [
            "Put the object in open space with room to walk around it.",
            "Plain floors and even light work best. Avoid shiny or see-through objects.",
            "Start in front of it, about an arm's length away.",
            "Walk all the way around slowly, then capture the top.",
            "Don't move the object while scanning.",
        ]
        static let quickMeasure = [
            "Point at where you want to start and tap Add Point.",
            "Move to the end point and tap again.",
            "Hold steady near corners and edges to snap to them.",
        ]
        static let advanced = [
            "Same moves as a normal scan, just slower.",
            "Higher detail needs good light and a steady hand.",
            "Watch the colors: fill in every red and gray area.",
        ]
    }

    /// Live scanning controls, coverage legend and guidance messages.
    enum Scanning {
        static let done = "Done", pause = "Pause", resume = "Resume", cancel = "Cancel"
        static let cancelConfirmTitle = "Stop this scan?"
        static let cancelConfirmBody = "What you scanned so far will be lost."
        static let cancelConfirmDiscard = "Discard Scan", cancelConfirmKeep = "Keep Scanning"
        static let paused = "Paused. Go back to where you stopped, then tap Resume."
        static let startingUp = "Getting ready. Move your phone slowly.", legendTitle = "Colors"
        static let legendGreen = "Green: scanned well", legendYellow = "Yellow: partly scanned"
        static let legendRed = "Red: missing detail", legendGray = "Gray: not scanned yet"
        static let addPhoto = "Take Photo", photoSaved = "Photo saved to this spot"
    }

    /// Guidance message table. Every `GuidanceKind` has exactly one entry.
    enum Guidance {
        static let all: [GuidanceKind: GuidanceMessage] = [
            // Tier 1: safety and tracking
            .trackingLost: .init(text: "Tracking lost. Go back to where you just were", tier: 1, minimumSeconds: 3.0, haptic: true),
            .trackingLow: .init(text: "Tracking quality is low", tier: 1, minimumSeconds: 3.0, haptic: true),
            .lightingPoor: .init(text: "Lighting is poor", tier: 1, minimumSeconds: 3.0, haptic: true),
            .moveSlower: .init(text: "Move slower", tier: 1, minimumSeconds: 3.0, haptic: true),
            .tooClose: .init(text: "Too close", tier: 1, minimumSeconds: 3.0, haptic: true),
            .tooFar: .init(text: "Too far", tier: 1, minimumSeconds: 3.0, haptic: true),
            .deviceHot: .init(text: "Your iPhone is hot. Take a short break", tier: 1, minimumSeconds: 3.0, haptic: true),
            .objectMoved: .init(text: "Keep the object still", tier: 1, minimumSeconds: 3.0, haptic: true),
            // Tier 2: coverage
            .moveCloser: .init(text: "Move closer", tier: 2, minimumSeconds: 2.5, haptic: false),
            .scanCorner: .init(text: "Scan this corner", tier: 2, minimumSeconds: 2.5, haptic: false),
            .pointAtFloor: .init(text: "Point toward the floor", tier: 2, minimumSeconds: 2.5, haptic: false),
            .scanCeiling: .init(text: "Scan the ceiling", tier: 2, minimumSeconds: 2.5, haptic: false),
            .scanDoorwayBothSides: .init(text: "Scan this doorway from both sides", tier: 2, minimumSeconds: 2.5, haptic: false),
            .needsAnotherPass: .init(text: "This area needs another pass", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectMoveAround: .init(text: "Move around the object slowly", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectCaptureLeft: .init(text: "Capture the left side", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectCaptureRight: .init(text: "Capture the right side", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectCaptureBack: .init(text: "Capture the back", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectCaptureTop: .init(text: "Capture the top", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectKeepInView: .init(text: "Keep the object in view", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectMoveCloserToArea: .init(text: "Move closer to this area", tier: 2, minimumSeconds: 2.5, haptic: false),
            .objectNeedsDetail: .init(text: "This section needs more detail", tier: 2, minimumSeconds: 2.5, haptic: false),
            // Tier 3: informational
            .windowDetected: .init(text: "Window detected", tier: 3, minimumSeconds: 1.5, haptic: false),
            .doorDetected: .init(text: "Door detected", tier: 3, minimumSeconds: 1.5, haptic: false),
            .wallDetected: .init(text: "Wall detected", tier: 3, minimumSeconds: 1.5, haptic: false),
            .openingDetected: .init(text: "Opening detected", tier: 3, minimumSeconds: 1.5, haptic: false),
            .stairsDetected: .init(text: "Stairs detected", tier: 3, minimumSeconds: 1.5, haptic: false),
            .roomLooksComplete: .init(text: "Looks good. Tap Done when you're ready", tier: 3, minimumSeconds: 1.5, haptic: false),
            .objectLooksComplete: .init(text: "All sides captured. Tap Done when you're ready", tier: 3, minimumSeconds: 1.5, haptic: false),
        ]
    }

    /// House / Building room progress.
    enum House {
        static let title = "Rooms", addRoom = "Scan Next Room", rescanRoom = "Rescan"
        static let continueRoom = "Continue Scanning", nameRoomTitle = "Name this room"
        static let nameRoomPlaceholder = "Room name"
        static let roomSuggestions = ["Living Room", "Kitchen", "Dining Room", "Bedroom", "Bathroom",
                                      "Hallway", "Office", "Garage", "Laundry", "Closet"]
        static let addFloor = "Add Floor", finishBuilding = "Finish Building"
        static let aligning = "Joining rooms together...", alignFailedTitle = "These rooms didn't line up"
        static let alignFailedBody = "Drag the room into place, or scan the doorway between them again."
        static let alignManual = "Line Up by Hand", alignRescanDoorway = "Scan Doorway Again"
        static let alignDone = "Rooms joined"
        static func roomDone(_ room: String) -> String { "\(room) done" }
        static func roomNeedsScan(_ room: String) -> String { "\(room) needs additional scan" }
        static func roomNotScanned(_ room: String) -> String { "\(room) not scanned yet" }
        static func floorLabel(_ number: Int) -> String { "Floor \(number)" }
        static func progressSummary(done: Int, total: Int) -> String { "\(done) of \(total) rooms done" }
    }

    /// Scan quality screen shown before finishing.
    enum Quality {
        static let title = "Scan Quality", geometry = "Shape", walls = "Walls", floor = "Floor"
        static let ceiling = "Ceiling", textures = "Color and texture", objectSides = "Sides captured"
        static let missingAreas = "Missing areas", summaryGood = "Great scan. You're ready to finish."
        static let summaryOkay = "Good scan. A few spots could use another pass."
        static let summaryPoor = "Some areas are missing. Your model will have gaps there."
        static let finishAnyway = "Finish Anyway", finish = "Finish", showMissingAreas = "Show Missing Areas"
        static let missingAreaHint = "Walk toward the arrow and scan the red area."
        static let missingAreaDone = "That area is filled in", nextMissingArea = "Next Area"
        static let allAreasDone = "No more missing areas"
        static func percent(_ value: Int) -> String { "\(value)%" }
        static func missingAreaStep(_ index: Int, of total: Int) -> String { "Missing area \(index) of \(total)" }
    }

    /// Processing screen after a scan.
    enum Processing {
        static let title = "Building your model", stepShape = "Building the shape"
        static let stepTextures = "Adding color and texture", stepClean = "Finding walls, doors and furniture"
        static let stepFloorPlan = "Drawing the floor plan", stepSaving = "Saving"
        static let keepOpen = "Keep Mapper open. This can take a few minutes."
        static let canLeave = "You can use other apps. We'll keep going while Mapper is open in the background."
        static let done = "Your model is ready"
    }

    /// Post-scan viewer: view switcher, display styles, toolbar, object summary.
    enum Viewer {
        static let realistic = "Realistic", clean = "3D Clean", floorPlan = "Floor Plan", raw = "Raw Scan"
        static let displayTitle = "Display", photoRealistic = "Photo Realistic", textured = "Textured"
        static let solidColor = "Solid Color", wireframe = "Wireframe", measure = "Measure"
        static let hideFurniture = "Hide Furniture", showFurniture = "Show Furniture", photos = "Photos"
        static let export = "Export", edit = "Edit", crop = "Crop"
        static let cropHint = "Drag the box edges to cut away the floor and anything that isn't your object."
        static let cropApply = "Apply Crop", cropReset = "Reset", resetView = "Reset View", width = "Width"
        static let height = "Height", depth = "Depth", volume = "Estimated volume"
        static let volumeUnavailable = "Volume unavailable: part of the object wasn't scanned"
        static let boundingBox = "Show Box"
    }

    /// Measurement tool, snapping, confidence and measured-vs-estimated labels.
    enum Measure {
        static let title = "Measure", addPoint = "Add Point", undoPoint = "Undo", clearAll = "Clear All"
        static let save = "Save", distance = "Distance", wallLength = "Wall length"
        static let wallHeight = "Wall height", ceilingHeight = "Ceiling height", doorWidth = "Door width"
        static let doorHeight = "Door height", windowSize = "Window size", roomLength = "Room length"
        static let roomWidth = "Room width", roomArea = "Room area", floorArea = "Floor area"
        static let wallArea = "Wall area", surfaceArea = "Surface area", perimeter = "Perimeter"
        static let angle = "Angle", volume = "Estimated volume", aimHint = "Aim the dot at the start point"
        static let nextHint = "Now aim at the end point", snapToggle = "Snap to corners and edges"
        static let snapTargets = ["corner", "wall", "edge", "floor", "ceiling", "door", "window", "object edge"]
        static func snapped(to target: String) -> String { "Snapped to \(target)" }

        static let lowConfidence = "Low confidence, rescan this section", rescan = "Rescan This Section"
        static let notMeasured = "Estimated, not measured"
        static let disclaimer = "Measurements are estimates from your iPhone's sensors. Check critical dimensions with a tape measure."
        static func accuracy(_ value: String) -> String { "Estimated accuracy \u{00B1}\(value)" }
        static func accuracySpoken(_ value: String) -> String { "Estimated accuracy plus or minus \(value)" }

        static let legendTitle = "What's real and what's estimated", measured = "Measured"
        static let measuredDetail = "Scanned directly.", estimated = "Estimated"
        static let estimatedDetail = "Filled in from nearby surfaces. Not measured.", inferred = "Inferred"
        static let inferredDetail = "Hidden behind something. Shape guessed from what's around it."
        static let occluded = "Occluded", occludedDetail = "Blocked by furniture. Nothing was seen here."
        static let unscanned = "Unscanned", unscannedDetail = "You didn't point the phone here."
    }

    /// Menu shown when tapping a detected object.
    enum ObjectMenu {
        static let hide = "Hide", unhide = "Show", deleteFromClean = "Delete from Clean Model", move = "Move"
        static let rotate = "Rotate", measure = "Measure", rename = "Rename"
        static let changeCategory = "Change Category", showRawGeometry = "Show Raw Geometry"
        static let deleteNote = "This removes it from the clean model only. Your original scan is kept."
        static func guessedLabel(_ category: String) -> String { "Mapper thinks this is a \(category). Tap to correct it." }
        static let categories = ["Table", "Chair", "Door", "Window", "Sink", "Toilet", "Bathtub", "Cabinet",
                                 "Counter", "Refrigerator", "Oven", "Stove", "Dishwasher", "Washer", "Dryer",
                                 "Fireplace", "Bed", "Sofa", "Desk", "TV", "Appliance", "Stairs", "Column",
                                 "Wall", "Floor", "Ceiling", "Other"]
    }

    /// Menu shown when tapping a wall.
    enum WallMenu {
        static let title = "Wall", measure = "Measure", adjust = "Adjust", addOpening = "Add Opening"
        static let addDoor = "Add Door", addWindow = "Add Window", hide = "Hide", inspect = "Inspect Scan"
        static let inspectFooter = "Shows exactly what was scanned for this wall."
    }

    /// Floor plan editor actions and layer toggles.
    enum FloorPlan {
        static let moveWall = "Move Wall", wallLength = "Wall Length", wallThickness = "Wall Thickness"
        static let addWall = "Add Wall", deleteWall = "Delete Wall", addDoor = "Add Door"
        static let moveDoor = "Move Door", resizeDoor = "Resize Door", flipDoorSwing = "Flip Door Swing"
        static let addWindow = "Add Window", moveWindow = "Move Window", resizeWindow = "Resize Window"
        static let addOpening = "Add Opening", renameRoom = "Rename Room", mergeRooms = "Merge Rooms"
        static let splitRoom = "Split Room", addMeasurement = "Add Measurement"
        static let deleteMeasurement = "Delete Measurement", addText = "Add Text", addSymbol = "Add Symbol"
        static let addNote = "Add Note", undo = "Undo", redo = "Redo", doneEditing = "Done Editing"
        static let resetToScan = "Reset to Scan"
        static let splitHint = "Draw a line across the room where you want to split it."
        static let mergeHint = "Tap the rooms you want to join.", resetTitle = "Reset to the original scan?"
        static let resetBody = "All floor plan edits will be removed. Your scan is not affected."
        static let resetConfirm = "Reset", editsSafe = "Edits never change your original scan."
        static let notePlaceholder = "Add a note", textPlaceholder = "Label", toggleFurniture = "Furniture"
        static let toggleMeasurements = "Measurements", toggleRoomNames = "Room Names"
        static let toggleDoorsWindows = "Doors and Windows", toggleFixtures = "Fixtures", toggleGrid = "Grid"
        static let toggleScale = "Scale"
    }

    /// Project actions: rename, duplicate, archive, delete, export, backup, restore.
    enum Project {
        static let rename = "Rename", renameTitle = "Rename Project", duplicate = "Duplicate"
        static let archive = "Archive", unarchive = "Unarchive", delete = "Delete"
        static let deleteBody = "The scan, models, photos and measurements will be permanently deleted from this iPhone. This can't be undone."
        static let deleteConfirm = "Delete Project", export = "Export", backup = "Back Up"
        static let backupDone = "Backup saved"
        static let backupHint = "Saves the whole project, including the original scan, as one file you can keep in Files or on a computer."
        static let restore = "Restore from Backup", restoreDone = "Project restored"
        static let restoreExists = "A project with this name already exists. Restore as a copy?"
        static let restoreAsCopy = "Restore as Copy", cancel = "Cancel"
        static func duplicateName(_ name: String) -> String { "\(name) copy" }
        static func deleteTitle(_ name: String) -> String { "Delete \"\(name)\"?" }
    }

    /// Export sheet: formats with plain explanations, options.
    enum Export {
        static let title = "Export", subtitle = "Choose a file type", button = "Export"
        static let preparing = "Preparing file...", ready = "Ready to share"
        static let includeTextures = "Include textures", includeHidden = "Include hidden objects"
        static let includeMeasurements = "Include measurements", units = "Units"
        static let noFloorPlan = "Not available: this scan has no floor plan"
        static let noColor = "Not available: color wasn't captured"
        /// (label, explanation) per format, in display order.
        static let formats: [(label: String, detail: String)] = [
            ("USDZ", "3D model for iPhone, iPad and Mac. Opens in Quick Look and AR."),
            ("OBJ", "3D model that almost every 3D program can open."),
            ("PLY", "The raw scan with color, for 3D and research software."),
            ("STL", "Shape only, no color. For 3D printing."),
            ("glTF", "3D model for websites, games and Blender."),
            ("PDF Floor Plan", "Printable floor plan with measurements."),
            ("SVG", "Floor plan drawing you can edit in design apps."),
            ("DXF", "Floor plan for AutoCAD and other CAD programs."),
            ("JSON", "Room sizes and measurements as data, for developers."),
            ("Images", "Pictures of the model and floor plan, saved as PNG."),
        ]
    }

    /// Settings screen.
    enum Settings {
        static let title = "Settings", units = "Units", unitsImperial = "Feet and inches"
        static let unitsMetric = "Metric", fractionPrecision = "Inch fractions", fractionEighth = "1/8\""
        static let fractionSixteenth = "1/16\"", scanningSection = "Scanning"
        static let showTips = "Show tips before scanning", haptics = "Vibrate for warnings"
        static let savePhotos = "Keep scan photos", storageSection = "Storage", aboutSection = "About"
        static let privacy = "Your scans never leave this iPhone unless you export them. No account, no cloud."
        static let troubleshootingSection = "Troubleshooting", wirelessDebug = "Wireless Debug Log"
        static let wirelessDebugFooter = "Lets a computer on your Wi-Fi read Mapper's troubleshooting log. Turn off when you're done."
        static let shareLog = "Share Log", resetTips = "Show All Tips Again"
        static func storageUsed(_ size: String) -> String { "\(size) used by Mapper" }
        static func version(_ version: String) -> String { "Version \(version)" }
    }

    /// Pre-permission and permission-denied screens.
    enum Permissions {
        static let cameraTitle = "Mapper needs your camera"
        static let cameraBody = "The camera and depth sensor build your 3D model. Everything stays on this iPhone."
        static let cameraContinue = "Continue", cameraDeniedTitle = "Camera access is off"
        static let cameraDeniedBody = "Turn on Camera for Mapper in Settings to start scanning."
        static let openSettings = "Open Settings"
        static let photosDenied = "To save images to Photos, turn on Photos access for Mapper in Settings."
        static let localNetworkDenied = "Wireless debug needs Local Network access. Turn it on in Settings."
    }

    /// Alert title and body for each error.
    enum Errors {
        static let ok = "OK", tryAgain = "Try Again", keepScanning = "Keep Scanning"
        static let noLidar = (title: "This iPhone can't scan in 3D", body: "Mapper needs an iPhone or iPad with a LiDAR scanner (Pro models from iPhone 12 Pro on).")
        static let objectUnsupported = (title: "Object scanning isn't available", body: "This iPhone doesn't support object scanning. Try Room mode instead.")
        static let trackingFailed = (title: "Scan stopped", body: "Mapper lost track of where you are. Your scan up to this point was saved.")
        static let interrupted = (title: "Scan paused", body: "The scan paused when Mapper left the screen. Go back to where you stopped, then resume.")
        static let tooHot = (title: "Your iPhone is too hot", body: "Scanning paused to let it cool down. Your progress is saved.")
        static let lowBattery = (title: "Battery is low", body: "Plug in your iPhone so the scan isn't cut short.")
        static let processingFailed = (title: "Couldn't build the model", body: "Your original scan is safe. Try again, or try with less detail.")
        static let textureFailed = (title: "Color couldn't be added", body: "Your model is saved without color. The shape and measurements are fine.")
        static let exportFailed = (title: "Export didn't work", body: "Try again, or pick a different file type.")
        static let restoreFailed = (title: "Can't restore this file", body: "This isn't a Mapper backup, or the file is damaged.")
        static let saveFailed = (title: "Couldn't save", body: "Something went wrong saving your project. Try again.")
        static let generic = (title: "Something went wrong", body: "Try again. If it keeps happening, share the log from Settings.")
        static let storageFullTitle = "Not enough storage"
        static func storageFullBody(_ size: String) -> String { "Free up space on your iPhone, then try again. This scan needs about \(size)." }
    }

    /// Empty states (title, body).
    enum Empty {
        static let noProjects = (title: "No scans yet", body: "Tap New Scan to scan your first room or object.")
        static let noArchived = (title: "Nothing archived", body: "Archived projects show up here.")
        static let noSearchResults = (title: "No matches", body: "Try a different name.")
        static let noMeasurements = (title: "No measurements yet", body: "Tap Measure, then tap two points.")
        static let noObjects = (title: "No objects found", body: "You can still add and label objects yourself.")
        static let noPhotos = (title: "No photos", body: "Photos you take while scanning show up here.")
        static let noRooms = (title: "No rooms yet", body: "Scan your first room to start this building.")
        static let noFloorPlan = (title: "No floor plan", body: "Floor plans are made from room scans, not object scans.")
    }

    /// VoiceOver labels and hints.
    enum A11y {
        static let newScanHint = "Starts a new room, house or object scan"
        static let openProjectHint = "Opens the project", scanView = "Live scan view"
        static let doneScanning = "Done scanning", doneScanningHint = "Checks scan quality"
        static let pauseScan = "Pause scan"
        static let coverageLegend = "Green is scanned well, yellow is partly scanned, red is missing detail, gray is not scanned"
        static let crosshair = "Measurement point", crosshairHint = "Double tap to add a point"
        static let modelViewer = "3D model", modelViewerHint = "Drag with one finger to turn, pinch to zoom"
        static let floorPlan = "Floor plan", floorPlanHint = "Drag to move, pinch to zoom"
        static let viewSwitcher = "View", viewSwitcherHint = "Realistic, 3D Clean, Floor Plan or Raw Scan"
        static let rescanRoomHint = "Double tap to scan again", close = "Close", more = "More actions"
        static func projectRow(name: String, type: String, date: String) -> String { "\(name), \(type), \(date)" }
        static func projectNeedsWork(_ name: String) -> String { "\(name), needs another scan" }
        static func metric(_ name: String, percent: Int) -> String { "\(name), \(percent) percent" }
        static func measurement(_ name: String, value: String) -> String { "\(name), \(value)" }
        static func roomDone(_ room: String) -> String { "\(room), done" }
        static func roomNeedsScan(_ room: String) -> String { "\(room), needs additional scan" }
    }
}

/// Every live guidance message the scanner can show. Raw values are stable for logs.
enum GuidanceKind: String, CaseIterable, Codable {
    // Tier 1
    case trackingLost, trackingLow, lightingPoor, moveSlower, tooClose, tooFar, deviceHot, objectMoved
    // Tier 2
    case moveCloser, scanCorner, pointAtFloor, scanCeiling, scanDoorwayBothSides, needsAnotherPass
    case objectMoveAround, objectCaptureLeft, objectCaptureRight, objectCaptureBack, objectCaptureTop
    case objectKeepInView, objectMoveCloserToArea, objectNeedsDetail
    // Tier 3
    case windowDetected, doorDetected, wallDetected, openingDetected, stairsDetected
    case roomLooksComplete, objectLooksComplete

    /// The message for this kind from `Copy.Guidance.all`.
    var message: GuidanceMessage {
        Copy.Guidance.all[self] ?? GuidanceMessage(text: rawValue, tier: 3, minimumSeconds: 1.5, haptic: false)
    }
}

/// One guidance message: text plus how the scanner shows it.
/// `tier`: 1 = safety/tracking, 2 = coverage, 3 = informational. Lower number wins.
struct GuidanceMessage: Equatable, Sendable {
    let text: String
    let tier: Int
    let minimumSeconds: Double
    let haptic: Bool
}

/// Display rules for live guidance. See docs/UX_COPY.md section 4.
enum GuidancePolicy {
    /// Never more than one message on screen.
    static let maxVisibleMessages = 1
    /// Quiet time after a message hides before the next shows. Tier 1 ignores it.
    static let minimumGapSeconds = 3.0
    /// Minimum on-screen time per tier.
    static let tier1MinimumSeconds = 3.0
    static let tier2MinimumSeconds = 2.5
    static let tier3MinimumSeconds = 1.5
    /// A condition must hold this long before its message appears.
    static let conditionHoldSeconds = 0.75
    /// The same message is not shown again within this window.
    static let repeatCooldownSeconds = 10.0
    /// Tier 3 messages are dropped for this long after any tier 1 message.
    static let tier3QuietAfterTier1Seconds = 5.0
    /// Cap on tier 3 messages per rolling minute.
    static let maxTier3PerMinute = 4
    /// At most one haptic in this window.
    static let hapticCooldownSeconds = 5.0
    /// Tiers that ignore `minimumGapSeconds`.
    static let gapExemptTiers: Set<Int> = [1]

    /// Whether an incoming message may replace the one on screen.
    /// Tier 1 interrupts 2 and 3 at once; tier 2 interrupts tier 3 after its minimum time;
    /// tier 3 and equal tiers never interrupt.
    static func canInterrupt(incomingTier: Int, currentTier: Int, currentShownSeconds: Double) -> Bool {
        guard incomingTier < currentTier else { return false }
        if incomingTier == 1 { return true }
        return currentShownSeconds >= minimumSeconds(forTier: currentTier)
    }

    /// Minimum on-screen seconds for a tier.
    static func minimumSeconds(forTier tier: Int) -> Double {
        switch tier {
        case 1: return tier1MinimumSeconds
        case 2: return tier2MinimumSeconds
        default: return tier3MinimumSeconds
        }
    }
}
