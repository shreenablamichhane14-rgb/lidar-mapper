# Mapper UX Copy Catalog

Every piece of on-screen text in Mapper, organized by screen. Derived from `docs/SPEC.txt`.
The Swift mirror of this file is `ios/Sources/Support/Copy.swift`. Implementers use `Copy.*`
constants and never hardcode user-facing text. When copy changes, change both files.

## Voice rules

- Plain American English. Short. Talk to a first-time user standing in a room holding a phone.
- Never say to the user: mesh, polygon, SLAM, anchor, point cloud, photogrammetry, LiDAR data,
  vertices, normals, pose. Say: model, scan, detail, tracking, shape, surface.
- No em-dashes, no emojis. Use a period, a comma, or two sentences instead.
- Buttons are verbs or short nouns in Title Case ("New Scan", "Finish Anyway"). The spec writes
  them in ALL CAPS; uppercase is a styling choice (`.textCase(.uppercase)`), not part of the string.
- Guidance messages are sentences without a final period ("Move slower"). Longer help text and
  alerts use full sentences with periods.
- Numbers: feet and inches as `12' 7 3/8"`, metric as `3.845 m`. Accuracy uses the plus-minus
  sign on screen (`±0.6"`) and "plus or minus" in VoiceOver.
- Never promise survey-grade accuracy. Say "estimated" whenever a number is not directly measured.

---

## 1. Home

| Key | Text |
|---|---|
| title | Projects |
| newScan | New Scan |
| searchPrompt | Search projects |
| sortRecent | Most Recent |
| sortName | Name |
| showArchived | Show Archived |
| archivedTitle | Archived |
| settings | Settings |
| projectSubtitle (room) | Room, {date} |
| projectSubtitle (house) | {n} rooms, {date} |
| projectSubtitle (object) | Object, {date} |
| projectSubtitle (measure) | Quick Measure, {date} |
| needsWork badge | Needs another scan |
| processing badge | Building model... |
| privacyFooter | Your scans stay on this iPhone. No account needed. |

Default project names (editable right after the scan): "Room {date}", "House {date}",
"Object {date}", "Measurement {date}". Date format: "Sep 28".

## 2. Mode picker (after New Scan)

Sheet title: **What do you want to scan?**

| Mode | Label | One-line description |
|---|---|---|
| room | Room | One room. Get a 3D model, floor plan and measurements. |
| house | House / Building | Several rooms, one at a time, joined into one model. |
| object | Object | Furniture, appliances or anything you can walk around. |
| quickMeasure | Quick Measure | Measure a distance or a wall right now. Nothing to scan. |
| advanced | Advanced Scan | Choose detail level and what to keep. For experienced users. |

Cancel button: **Cancel**.

### Advanced Scan options

| Key | Text |
|---|---|
| title | Advanced Scan |
| scanType | What are you scanning? |
| scanTypeSpace | A space |
| scanTypeObject | An object |
| detail | Detail |
| detailStandard | Standard |
| detailHigh | High |
| detailMaximum | Maximum |
| detailFooter | More detail makes bigger files and takes longer to build. |
| keepPhotos | Keep all photos |
| keepPhotosFooter | Photos make the model look real. They use more storage. |
| detectRooms | Find walls, doors and windows |
| detectObjects | Find furniture and appliances |
| range | Scanning distance |
| rangeNear | Close up |
| rangeNormal | Normal |
| rangeFar | Far |
| start | Start Scan |

## 3. Onboarding tips (shown before the first scan of each mode)

Buttons: **Start Scan**, **Don't show again** (toggle), **Skip**.

**Room**
1. Turn on the lights and open the curtains.
2. Start in a corner, facing the middle of the room.
3. Walk slowly along the walls, keeping the phone at chest height.
4. Point at the floor, then the ceiling, as you go.
5. End back where you started.

**House / Building**
1. Scan one room at a time. You can take breaks between rooms.
2. Start each room at the doorway you walked in through.
3. Scan every doorway from both sides so rooms join up correctly.
4. Keep doors open while you scan.
5. Name each room when you finish it.

**Object**
1. Put the object in open space with room to walk around it.
2. Plain floors and even light work best. Avoid shiny or see-through objects.
3. Start in front of it, about an arm's length away.
4. Walk all the way around slowly, then capture the top.
5. Don't move the object while scanning.

**Quick Measure**
1. Point at where you want to start and tap Add Point.
2. Move to the end point and tap again.
3. Hold steady near corners and edges to snap to them.

**Advanced Scan**
1. Same moves as a normal scan, just slower.
2. Higher detail needs good light and a steady hand.
3. Watch the colors: fill in every red and gray area.

## 4. Live scanning

### Controls and chrome

| Key | Text |
|---|---|
| done | Done |
| pause | Pause |
| resume | Resume |
| cancel | Cancel |
| cancelConfirmTitle | Stop this scan? |
| cancelConfirmBody | What you scanned so far will be lost. |
| cancelConfirmDiscard | Discard Scan |
| cancelConfirmKeep | Keep Scanning |
| paused | Paused. Go back to where you stopped, then tap Resume. |
| startingUp | Getting ready. Move your phone slowly. |
| elapsed | {m}:{ss} |
| legendTitle | Colors |
| legendGreen | Green: scanned well |
| legendYellow | Yellow: partly scanned |
| legendRed | Red: missing detail |
| legendGray | Gray: not scanned yet |
| addPhoto | Take Photo |
| photoSaved | Photo saved to this spot |

### Guidance messages

Tiers: **1** = safety and tracking (the scan is failing or the user is at risk), **2** = coverage
(what to scan next), **3** = informational (something was found, or things are going well).

| Kind | Text | Tier | Min seconds | Haptic | Modes |
|---|---|---|---|---|---|
| trackingLost | Tracking lost. Go back to where you just were | 1 | 3.0 | yes | all |
| trackingLow | Tracking quality is low | 1 | 3.0 | yes | all |
| lightingPoor | Lighting is poor | 1 | 3.0 | yes | all |
| moveSlower | Move slower | 1 | 3.0 | yes | all |
| tooClose | Too close | 1 | 3.0 | yes | all |
| tooFar | Too far | 1 | 3.0 | yes | all |
| deviceHot | Your iPhone is hot. Take a short break | 1 | 3.0 | yes | all |
| objectMoved | Keep the object still | 1 | 3.0 | yes | object |
| moveCloser | Move closer | 2 | 2.5 | no | room, house |
| scanCorner | Scan this corner | 2 | 2.5 | no | room, house |
| pointAtFloor | Point toward the floor | 2 | 2.5 | no | room, house |
| scanCeiling | Scan the ceiling | 2 | 2.5 | no | room, house |
| scanDoorwayBothSides | Scan this doorway from both sides | 2 | 2.5 | no | house |
| needsAnotherPass | This area needs another pass | 2 | 2.5 | no | room, house |
| objectMoveAround | Move around the object slowly | 2 | 2.5 | no | object |
| objectCaptureLeft | Capture the left side | 2 | 2.5 | no | object |
| objectCaptureRight | Capture the right side | 2 | 2.5 | no | object |
| objectCaptureBack | Capture the back | 2 | 2.5 | no | object |
| objectCaptureTop | Capture the top | 2 | 2.5 | no | object |
| objectKeepInView | Keep the object in view | 2 | 2.5 | no | object |
| objectMoveCloserToArea | Move closer to this area | 2 | 2.5 | no | object |
| objectNeedsDetail | This section needs more detail | 2 | 2.5 | no | object |
| windowDetected | Window detected | 3 | 1.5 | no | room, house |
| doorDetected | Door detected | 3 | 1.5 | no | room, house |
| wallDetected | Wall detected | 3 | 1.5 | no | room, house |
| openingDetected | Opening detected | 3 | 1.5 | no | room, house |
| stairsDetected | Stairs detected | 3 | 1.5 | no | room, house |
| roomLooksComplete | Looks good. Tap Done when you're ready | 3 | 1.5 | no | room, house |
| objectLooksComplete | All sides captured. Tap Done when you're ready | 3 | 1.5 | no | object |

"Too close" and "Too far" are tier 1 because the scanner records nothing outside its range, so
the scan is silently failing. "Move closer" (tier 2) is the gentler coverage nudge for areas
that are in range but thin on detail.

### Display rules

1. **One message at a time.** Never stack or queue more than one visible message.
2. **Minimum time on screen:** tier 1 = 3.0 s, tier 2 = 2.5 s, tier 3 = 1.5 s. A message stays
   at least this long unless a higher tier interrupts it.
3. **Minimum gap between messages:** 3.0 s of no message after one hides, before the next shows.
   Tier 1 ignores the gap.
4. **Interrupting:** tier 1 interrupts tiers 2 and 3 immediately. Tier 2 interrupts tier 3 once
   the tier 3 message has had its minimum time. Tier 3 never interrupts anything. Equal tiers
   never interrupt each other.
5. **Hold before showing:** a condition must be true for 0.75 s before its message appears
   (no flicker from one bad frame).
6. **Hold while true:** a tier 1 message stays up while its condition is still true, then leaves
   after its minimum time.
7. **No repeats:** the same message does not show again within 10 s.
8. **Quiet after trouble:** tier 3 messages are dropped (not queued) for 5 s after any tier 1
   message, and there are at most 4 tier 3 messages per minute.
9. **Priority:** when several conditions are true, show the lowest tier number; within a tier,
   the order in the table above wins.
10. **Haptics:** tier 1 only, a warning haptic when it first appears, at most once every 5 s.
    Obeys the Haptics setting.
11. **VoiceOver:** every message is announced. Tier 1 uses a high-priority announcement.

## 5. House / Building progress

| Key | Text |
|---|---|
| title | Rooms |
| addRoom | Scan Next Room |
| roomDone | {room} done |
| roomNeedsScan | {room} needs additional scan |
| roomNotScanned | {room} not scanned yet |
| rescanRoom | Rescan |
| continueRoom | Continue Scanning |
| nameRoomTitle | Name this room |
| nameRoomPlaceholder | Room name |
| roomSuggestions | Living Room, Kitchen, Dining Room, Bedroom, Bathroom, Hallway, Office, Garage, Laundry, Closet |
| floorLabel | Floor {n} |
| addFloor | Add Floor |
| progressSummary | {done} of {total} rooms done |
| finishBuilding | Finish Building |
| aligning | Joining rooms together... |
| alignFailedTitle | These rooms didn't line up |
| alignFailedBody | Drag the room into place, or scan the doorway between them again. |
| alignManual | Line Up by Hand |
| alignRescanDoorway | Scan Doorway Again |
| alignDone | Rooms joined |

Row accessory is a checkmark symbol for done rooms and a warning symbol for rooms needing a scan.
Example list: "Dining Room done", "Kitchen done", "Hallway needs additional scan".

## 6. Scan quality screen

| Key | Text |
|---|---|
| title | Scan Quality |
| geometry | Shape |
| walls | Walls |
| floor | Floor |
| ceiling | Ceiling |
| textures | Color and texture |
| objectSides | Sides captured |
| missingAreas | Missing areas |
| percent | {n}% |
| summaryGood | Great scan. You're ready to finish. |
| summaryOkay | Good scan. A few spots could use another pass. |
| summaryPoor | Some areas are missing. Your model will have gaps there. |
| finishAnyway | Finish Anyway |
| finish | Finish |
| showMissingAreas | Show Missing Areas |
| missingAreaStep | Missing area {i} of {n} |
| missingAreaHint | Walk toward the arrow and scan the red area. |
| missingAreaDone | That area is filled in |
| nextMissingArea | Next Area |
| allAreasDone | No more missing areas |

"Geometry" from the spec is shown as "Shape" (plain word). "Finish" replaces "Finish Anyway" when
nothing is missing.

## 7. Processing

| Key | Text |
|---|---|
| title | Building your model |
| stepShape | Building the shape |
| stepTextures | Adding color and texture |
| stepClean | Finding walls, doors and furniture |
| stepFloorPlan | Drawing the floor plan |
| stepSaving | Saving |
| keepOpen | Keep Mapper open. This can take a few minutes. |
| canLeave | You can use other apps. We'll keep going while Mapper is open in the background. |
| done | Your model is ready |

## 8. Post-scan viewer

### View switcher

| Key | Label | Accessibility hint |
|---|---|---|
| realistic | Realistic | Photo-like model |
| clean | 3D Clean | Simple walls, floor and objects |
| floorPlan | Floor Plan | Top-down drawing |
| raw | Raw Scan | Exactly what the scanner recorded |

The spec label "RAW MESH" becomes "Raw Scan" to follow the no-jargon rule.

### Display style

| Key | Label |
|---|---|
| title | Display |
| photoRealistic | Photo Realistic |
| textured | Textured |
| solidColor | Solid Color |
| wireframe | Wireframe |
| raw | Raw Scan |

### Viewer toolbar

| Key | Text |
|---|---|
| measure | Measure |
| hideFurniture | Hide Furniture |
| showFurniture | Show Furniture |
| photos | Photos |
| share | Export |
| edit | Edit |
| crop | Crop |
| cropHint | Drag the box edges to cut away the floor and anything that isn't your object. |
| cropApply | Apply Crop |
| cropReset | Reset |
| resetView | Reset View |

### Object summary (object mode)

| Key | Text |
|---|---|
| width | Width |
| height | Height |
| depth | Depth |
| volume | Estimated volume |
| volumeUnavailable | Volume unavailable: part of the object wasn't scanned |
| boundingBox | Show Box |

## 9. Measurements

### Tools

| Key | Text |
|---|---|
| title | Measure |
| addPoint | Add Point |
| undoPoint | Undo |
| clearAll | Clear All |
| save | Save |
| distance | Distance |
| wallLength | Wall length |
| wallHeight | Wall height |
| ceilingHeight | Ceiling height |
| doorWidth | Door width |
| doorHeight | Door height |
| windowSize | Window size |
| objectWidth | Width |
| objectHeight | Height |
| objectDepth | Depth |
| roomLength | Room length |
| roomWidth | Room width |
| roomArea | Room area |
| floorArea | Floor area |
| wallArea | Wall area |
| surfaceArea | Surface area |
| perimeter | Perimeter |
| angle | Angle |
| volume | Estimated volume |
| aimHint | Aim the dot at the start point |
| nextHint | Now aim at the end point |

### Snapping

Shown in a small tag while aiming: "Snapped to {target}". Targets: corner, wall, edge, floor,
ceiling, door, window, object edge. Snapping toggle: **Snap to corners and edges**.

### Confidence

| Key | Text |
|---|---|
| accuracy | Estimated accuracy ±{value} |
| accuracyA11y | Estimated accuracy plus or minus {value} |
| lowConfidence | Low confidence, rescan this section |
| rescan | Rescan This Section |
| notMeasured | Estimated, not measured |
| disclaimer | Measurements are estimates from your iPhone's sensors. Check critical dimensions with a tape measure. |

The spec writes this with a dash; Mapper uses a comma instead.

### Measured vs estimated geometry

| Key | Label | Explanation (shown in the legend and on tap) |
|---|---|---|
| measured | Measured | Scanned directly. |
| estimated | Estimated | Filled in from nearby surfaces. Not measured. |
| inferred | Inferred | Hidden behind something. Shape guessed from what's around it. |
| occluded | Occluded | Blocked by furniture. Nothing was seen here. |
| unscanned | Unscanned | You didn't point the phone here. |

Legend title: **What's real and what's estimated**. Estimated areas are drawn with a hatch pattern
as well as a color so they read without color vision.

## 10. Object edit menu (tap an object)

Menu title is the object's name, e.g. **Table**.

| Key | Text |
|---|---|
| hide | Hide |
| unhide | Show |
| deleteFromClean | Delete from Clean Model |
| move | Move |
| rotate | Rotate |
| measure | Measure |
| rename | Rename |
| changeCategory | Change Category |
| showRawGeometry | Show Raw Geometry |
| deleteNote | This removes it from the clean model only. Your original scan is kept. |
| guessedLabel | Mapper thinks this is a {category}. Tap to correct it. |

Categories: Table, Chair, Door, Window, Sink, Toilet, Bathtub, Cabinet, Counter, Refrigerator,
Oven, Stove, Dishwasher, Washer, Dryer, Fireplace, Bed, Sofa, Desk, TV, Appliance, Stairs,
Column, Wall, Floor, Ceiling, Other.

## 11. Wall menu (tap a wall)

| Key | Text |
|---|---|
| title | Wall |
| measure | Measure |
| adjust | Adjust |
| addOpening | Add Opening |
| addDoor | Add Door |
| addWindow | Add Window |
| hide | Hide |
| inspect | Inspect Scan |
| inspectFooter | Shows exactly what was scanned for this wall. |

## 12. Floor plan editor

### Actions

Move Wall, Wall Length, Wall Thickness, Add Wall, Delete Wall, Add Door, Move Door, Resize Door,
Flip Door Swing, Add Window, Move Window, Resize Window, Add Opening, Rename Room, Merge Rooms,
Split Room, Add Measurement, Delete Measurement, Add Text, Add Symbol, Add Note, Undo, Redo,
Done Editing, Reset to Scan.

| Key | Text |
|---|---|
| splitHint | Draw a line across the room where you want to split it. |
| mergeHint | Tap the rooms you want to join. |
| resetTitle | Reset to the original scan? |
| resetBody | All floor plan edits will be removed. Your scan is not affected. |
| resetConfirm | Reset |
| editsSafe | Edits never change your original scan. |
| notePlaceholder | Add a note |
| textPlaceholder | Label |

### Toggles

Furniture, Measurements, Room Names, Doors and Windows, Fixtures, Grid, Scale.

## 13. Project actions

| Key | Text |
|---|---|
| rename | Rename |
| renameTitle | Rename Project |
| duplicate | Duplicate |
| duplicateName | {name} copy |
| archive | Archive |
| unarchive | Unarchive |
| delete | Delete |
| deleteTitle | Delete "{name}"? |
| deleteBody | The scan, models, photos and measurements will be permanently deleted from this iPhone. This can't be undone. |
| deleteConfirm | Delete Project |
| export | Export |
| backup | Back Up |
| backupDone | Backup saved |
| backupHint | Saves the whole project, including the original scan, as one file you can keep in Files or on a computer. |
| restore | Restore from Backup |
| restoreDone | Project restored |
| restoreExists | A project with this name already exists. Restore as a copy? |
| restoreAsCopy | Restore as Copy |
| cancel | Cancel |

## 14. Export sheet

Title: **Export**. Subtitle: **Choose a file type**. Button: **Export**. In progress:
**Preparing file...**. Done: **Ready to share**.

| Format | Label | One-line explanation |
|---|---|---|
| usdz | USDZ | 3D model for iPhone, iPad and Mac. Opens in Quick Look and AR. |
| obj | OBJ | 3D model that almost every 3D program can open. |
| ply | PLY | The raw scan with color, for 3D and research software. |
| stl | STL | Shape only, no color. For 3D printing. |
| gltf | glTF | 3D model for websites, games and Blender. |
| pdf | PDF Floor Plan | Printable floor plan with measurements. |
| svg | SVG | Floor plan drawing you can edit in design apps. |
| dxf | DXF | Floor plan for AutoCAD and other CAD programs. |
| json | JSON | Room sizes and measurements as data, for developers. |
| images | Images | Pictures of the model and floor plan, saved as PNG. |

Options: **Include textures**, **Include hidden objects**, **Include measurements**,
**Units: Feet and inches / Metric**. Not available for this scan: **Not available: this scan has
no floor plan** (object scans), **Not available: color wasn't captured**.

## 15. Settings

| Key | Text |
|---|---|
| title | Settings |
| units | Units |
| unitsImperial | Feet and inches |
| unitsMetric | Metric |
| fractionPrecision | Inch fractions |
| fractionEighth | 1/8" |
| fractionSixteenth | 1/16" |
| scanningSection | Scanning |
| showTips | Show tips before scanning |
| haptics | Vibrate for warnings |
| savePhotos | Keep scan photos |
| storageSection | Storage |
| storageUsed | {size} used by Mapper |
| aboutSection | About |
| privacy | Your scans never leave this iPhone unless you export them. No account, no cloud. |
| version | Version {v} |
| troubleshootingSection | Troubleshooting |
| wirelessDebug | Wireless Debug Log |
| wirelessDebugFooter | Lets a computer on your Wi-Fi read Mapper's troubleshooting log. Turn off when you're done. |
| shareLog | Share Log |
| resetTips | Show All Tips Again |

## 16. Permissions

System prompt strings live in `ios/project.yml` (Info.plist). Pre-permission screen shown before
the camera prompt:

| Key | Text |
|---|---|
| cameraTitle | Mapper needs your camera |
| cameraBody | The camera and depth sensor build your 3D model. Everything stays on this iPhone. |
| cameraContinue | Continue |
| cameraDeniedTitle | Camera access is off |
| cameraDeniedBody | Turn on Camera for Mapper in Settings to start scanning. |
| openSettings | Open Settings |
| photosDenied | To save images to Photos, turn on Photos access for Mapper in Settings. |
| localNetworkDenied | Wireless debug needs Local Network access. Turn it on in Settings. |

## 17. Errors

| Key | Title | Body | Buttons |
|---|---|---|---|
| noLidar | This iPhone can't scan in 3D | Mapper needs an iPhone or iPad with a LiDAR scanner (Pro models from iPhone 12 Pro on). | OK |
| objectUnsupported | Object scanning isn't available | This iPhone doesn't support object scanning. Try Room mode instead. | OK |
| trackingFailed | Scan stopped | Mapper lost track of where you are. Your scan up to this point was saved. | Resume, Finish |
| interrupted | Scan paused | The scan paused when Mapper left the screen. Go back to where you stopped, then resume. | Resume, Finish |
| tooHot | Your iPhone is too hot | Scanning paused to let it cool down. Your progress is saved. | OK |
| lowBattery | Battery is low | Plug in your iPhone so the scan isn't cut short. | Keep Scanning |
| storageFull | Not enough storage | Free up space on your iPhone, then try again. This scan needs about {size}. | OK |
| processingFailed | Couldn't build the model | Your original scan is safe. Try again, or try with less detail. | Try Again, Cancel |
| textureFailed | Color couldn't be added | Your model is saved without color. The shape and measurements are fine. | OK |
| exportFailed | Export didn't work | Try again, or pick a different file type. | Try Again |
| restoreFailed | Can't restore this file | This isn't a Mapper backup, or the file is damaged. | OK |
| saveFailed | Couldn't save | Something went wrong saving your project. Try again. | Try Again |
| generic | Something went wrong | Try again. If it keeps happening, share the log from Settings. | OK |

## 18. Empty states

| Key | Title | Body | Button |
|---|---|---|---|
| noProjects | No scans yet | Tap New Scan to scan your first room or object. | New Scan |
| noArchived | Nothing archived | Archived projects show up here. | |
| noSearchResults | No matches | Try a different name. | |
| noMeasurements | No measurements yet | Tap Measure, then tap two points. | Measure |
| noObjects | No objects found | You can still add and label objects yourself. | |
| noPhotos | No photos | Photos you take while scanning show up here. | |
| noRooms | No rooms yet | Scan your first room to start this building. | Scan Room |
| noFloorPlan | No floor plan | Floor plans are made from room scans, not object scans. | |

## 19. Accessibility labels

| Element | Label | Hint |
|---|---|---|
| New Scan button | New Scan | Starts a new room, house or object scan |
| Project row | {name}, {type}, {date} | Opens the project |
| Project row with issue | {name}, needs another scan | |
| Scan view | Live scan view | |
| Done button (scanning) | Done scanning | Checks scan quality |
| Pause button | Pause scan | |
| Coverage legend | Green is scanned well, yellow is partly scanned, red is missing detail, gray is not scanned | |
| Guidance message | {message} | |
| Quality metric | {metric}, {n} percent | |
| Measurement label | {name}, {value} | |
| Accuracy | Estimated accuracy plus or minus {value} | |
| Measure crosshair | Measurement point | Double tap to add a point |
| Model viewer | 3D model | Drag with one finger to turn, pinch to zoom |
| Floor plan | Floor plan | Drag to move, pinch to zoom |
| View switcher | View | Realistic, 3D Clean, Floor Plan or Raw Scan |
| Room done row | {room}, done | |
| Room needs scan row | {room}, needs additional scan | Double tap to scan again |
| Close button | Close | |
| More button | More actions | |

Units in VoiceOver are spoken in full: `12' 7 3/8"` reads "12 feet 7 and 3 eighths inches",
`3.845 m` reads "3.845 meters", `±0.6"` reads "plus or minus 0.6 inches".
