# Mapper On-Device Test Plan

Version 1, 2026-09-28. Source of truth for scope: `docs/SPEC.txt`.

This plan is for testing Mapper on the real phone as builds arrive. It is written for someone who is not a professional tester. Every test says what to tap, how to move, what you should see, and how to decide pass or fail.

## 0. How to use this plan

### 0.1 Test phone

| Item | Value |
|---|---|
| Phone | iPhone 13 Pro Max (iPhone14,3), has LiDAR |
| iOS | 18.3.2 |
| App | Mapper, bundle `com.shreehub.mapper`, sideloaded with a free Apple ID (signature lasts 7 days) |
| Log file | `Documents/Logs/mapper-YYYY-MM-DD.log` (Files app: On My iPhone > Mapper > Logs) |
| Pull log to PC | `python tools/phone_log.py usb` |
| Live log over Wi-Fi | `python tools/phone_log.py wifi <ip> <token>` |

### 0.2 Things you need

- A metal tape measure (5 m or longer). A laser distance meter is better for 3 m to 6 m if you have one.
- Painter's tape or sticky notes to mark reference points.
- A notebook or the tables in this file.
- A charger and a USB cable.
- A second phone or a friend to call you (for the interruption test).
- A watch or the phone's clock app on another device for timing.

### 0.3 Features not built yet

Build 1 only has the capability probe screen. Most tests below are for later builds. When a feature is missing, mark the test **N/A (not built)**. Do not mark it as a failure.

#### Build 4 (0.4) notes: room MVP

Build 4 scans one room in Room mode and has the result screen, Home, export and Settings > Diagnostics. The lists below come from `docs/MODULES.md` section 2.1 (build 4 acceptance). Test ids are unchanged. A test marked N/A here is **N/A (not built)**, never an S1 or S2 failure. Tests not named here are outside build 4 acceptance; follow the rule above for them.

Run as written:

- MODE-01, MODE-02, MODE-03 (Room only; the other modes show "Coming in a later version"), MODE-04, MODE-05.
- ROOM-01 to ROOM-05.
- TEX-01 (only if the texture step, TextureLowStep, made it into build 4; otherwise N/A), TEX-06.
- QUAL-04.
- REC-01, REC-05.
- FURN-01, FURN-02, FURN-04.
- MEAS-02 to MEAS-06, MEAS-09, MEAS-11.
- CONF-01 to CONF-04.
- PLAN-01 to PLAN-04, PLAN-06.
- EDIT3D-01 (the object card is read-only in build 4), EDIT3D-06.
- PROJ-01, PROJ-05, PROJ-07, PROJ-09.
- OFF-02 to OFF-04.
- EXP-01, EXP-02 (without textures unless TextureLowStep made it into build 4), EXP-03, EXP-04, EXP-06, EXP-07, EXP-10.
- LIVE-01, LIVE-06, LIVE-07, LIVE-08, LIVE-10.

If TextureLowStep did not make it into build 4, REALISTIC shows RoomPlan's simple model or "Color is still being added" instead of photo textures. That is expected, not a failure.

Run with the build 4 variant:

| Test | How to run it on build 4 |
|---|---|
| QUAL-01 | There is no SHOW MISSING AREAS button yet (build 5). Judge everything else. |
| QUAL-02 | Do it as two separate scans: first a scan of the walls only, then a new full scan that includes the ceiling. Compare the two Ceiling scores. |
| ROOM-11 | Cancel asks with Keep Scanning and Discard Scan. Keep Scanning continues the scan, and tapping Done then saves the partial room as a project. Discard leaves no project. |
| TEX-02 | Four modes, not five. PHOTO REALISTIC shows "Photo Realistic comes in a later version" (`Copy.Results.photoRealisticLater`). |
| OFF-01 | Skip plan editing and measuring inside the model (both build 5). Everything else in the workflow must work in Airplane Mode. |
| EXP-05 | The plan has no annotations (text annotations come with plan editing in build 5). Everything else, including the printed scale, is checked as written. |

Performance and reliability (section 4): run sections 4.2 to 4.9 except PERF-03, PERF-10 and PERF-25 (House mode) and PERF-28 (plan edits).

Smoke list (section 5): run all checks except the SHOW MISSING AREAS button in #4, #6 (Quick Measure), #8 (plan edit) and #9 (object scan).

N/A in build 4:

- REC-03 (label correction, build 7).
- EXP-09 (House mode).
- PERF-03, PERF-10, PERF-25 (House mode).
- PERF-28 (plan edits).
- Smoke #6, #8, #9 and the SHOW MISSING AREAS button in smoke #4.

### 0.4 Severity scale

| Severity | Meaning | Example |
|---|---|---|
| S1 Blocker | Crash, data loss, or the main job cannot be done | App crashes when you tap Finish. Scan is gone after relaunch. |
| S2 Major | A feature is wrong or unusable, but there is a workaround | Wall length off by 30 cm. Export file does not open. |
| S3 Minor | Works, but badly or confusingly | Guidance message flickers. Label is wrong but can be fixed. |
| S4 Cosmetic | Looks wrong, no effect on results | Text cut off, wrong icon, spacing. |

### 0.5 Result codes

Use one of these for every test: **PASS**, **FAIL**, **PARTIAL** (some checks passed), **BLOCKED** (could not run because something else broke), **N/A** (feature not built).

### 0.6 Reading the log

Every log line looks like this:

```
14:32:07.412 [category] message
```

The part in square brackets is the category. Build 1 writes these categories: `app` (launch, active, background, capabilities), `session` (a block starting with `===== session start =====` that lists app version, iOS and model) and `debug` (Wi-Fi log server).

Later builds are expected to add categories such as `scan`, `tracking`, `roomplan`, `mesh`, `texture`, `quality`, `measure`, `plan`, `edit`, `project`, `export`, `thermal` and `memory`. The exact names may differ. In this plan, "look for" means search the log for a line in that area with those words. If a test says "look for a tracking state change" and you cannot find anything like it, write that down. Missing log lines are a bug too (S3), because they make other bugs hard to fix.

General things to always check in the log after a test:

- The `===== session start =====` block appears once per scan, with the right app version.
- No lines with `error`, `failed`, `exception`, `fatal`, `assert` or `memory warning` that you cannot explain.
- The last line before a crash. Copy the last 30 lines into the bug report.

### 0.7 Before every test session

1. Charge the phone to at least 80 percent (unless the test says otherwise).
2. Close other apps.
3. Turn on the lights in the room.
4. Note the build number from Settings or the About screen.
5. Note the time you start. This makes it easy to find the right log lines later.

---

## 1. Test environments

Each environment exposes different problems. Use this table to pick where to run each test. The environment codes (like ENV-LR) are used in the test cases.

### 1.1 Spaces

| Code | Environment | What to prepare | Why it matters (failure modes it exposes) |
|---|---|---|---|
| ENV-LR | Home living room | Normal furniture, lights on, curtains open and then closed for a second pass | Baseline room. Sofas and tables block walls and floor (occlusion). TV screen is black glass (reflection, holes). Windows with daylight behind them (glare, missing wall). Soft furniture has low texture. Good for furniture detection and furniture removal. |
| ENV-KIT | Home kitchen | Counters, upper and lower cabinets, fridge, oven, sink | Shiny surfaces: stainless steel, glossy tiles, glass oven door (reflection, noisy depth). Many straight edges (good for snapping). Counters and cabinets test object recognition. Narrow space means you stand close to walls (too-close warnings). |
| ENV-BATH | Bathroom | Mirror uncovered, then covered with a towel for a second pass | Large mirror creates fake "rooms" behind the wall (ghost geometry). Small room, you cannot step back. White tiles have low texture (tracking loss). Toilet, sink, bathtub test fixture detection. Often low light. |
| ENV-HALL | Hallway connecting rooms | Doors open | Long and narrow. Tests drift over distance and door detection. Repetitive plain walls (low texture, tracking loss). The link between rooms in house mode. |
| ENV-HOUSE | Multi-room apartment or house | At least 4 rooms plus a hallway, doors open, stairs if you have them | House mode. Shared walls, alignment between rooms, doorways that connect rooms, multiple floors, long total scan time (heat, battery, memory). |
| ENV-REST | Restaurant dining room | Scan when closed. Tables and chairs in normal layout. Bar counter if present | Large open space (beyond the ~5 m LiDAR range from any one point). Many repeated tables and chairs (recognition, clutter). Mixed lighting and dim areas. Glass doors and windows at the front. Real use case for the user. |
| ENV-OFF | Office | Desks, monitors, office chairs, glass partitions if any | Many monitors (black glass). Desks and cables (clutter). Glass walls (LiDAR passes through glass). Fluorescent lights can flicker. |
| ENV-GAR | Garage | Normal clutter, one car if possible | Low light. Concrete has little texture. High clutter on shelves. Large open floor. The car is shiny and dark (hard for LiDAR). Cold or hot temperatures. |
| ENV-OUT | Outdoors next to a wall | A house or building wall, daytime, then dusk | Sunlight interferes with LiDAR (infrared noise). No ceiling. Open sky returns no depth. Tests that the app handles "outdoor" gracefully and does not invent a ceiling or room. |

### 1.2 Objects

| Code | Object | How to set it up | Why it matters |
|---|---|---|---|
| ITEM-CHAIR | Dining chair | In open floor, 1 m clear on all sides | Thin legs and a gap in the back. Tests fine detail and background separation from the floor. |
| ITEM-TABLE | Table | Clear the top | Flat, large top. Legs under a surface (occlusion). Tests width, depth and height accuracy on a simple box shape. |
| ITEM-FRIDGE | Refrigerator | Against the wall as normal | Cannot walk around it (back is against a wall). Shiny surface. Tests partial object capture and how the app reports missing sides. |
| ITEM-BOX | Cardboard box | About 30 to 60 cm per side, on the floor | Best-case object: matte, simple, easy to measure with a tape. Use it as the accuracy reference for objects. |
| ITEM-VASE | Small sculpture or vase | On a table, 20 to 40 cm tall | Small (near the 10 cm limit where LiDAR detail drops). Curved and maybe glossy. Tests texture capture and photogrammetry detail. |
| ITEM-CARDOOR | Car door | On a parked car, door open | Very shiny and dark paint, window glass. Attached to a larger object. Tests background separation and cropping. |

### 1.3 Surface and light conditions to vary

When a test says "vary conditions", repeat it once in each of these:

| Condition | How to create it | What to watch |
|---|---|---|
| Normal light | All lights on | Baseline |
| Low light | One lamp only, or dusk | "Lighting is poor" message. Textures dark or noisy. Tracking loss. |
| Mirror | Bathroom mirror uncovered | Ghost room behind the mirror. |
| Glass | Window or glass door | Wall hole or geometry of what is outside. |
| Low texture | Plain white wall, filled with the phone's view | "Tracking quality is low". Drift. |
| Clutter | Pile of items on a table or shelf | Noisy mesh, false objects. |
| Large open space | Restaurant or garage | Missing far walls, drift, coverage map. |

---

## 2. Test cases by spec section

Each test uses this format:

- **Env**: environment code from section 1.
- **Pre**: preconditions.
- **Steps**: numbered.
- **Expected**: what should happen.
- **Pass if**: things you can see or measure.
- **Log**: what to look for in the log.
- **Sev**: severity if it fails.

Timing words: "slowly" means about one step per second, and turning the phone about 30 degrees per second. "Sweep" means move the phone smoothly left to right and back, pointing at the surface.

### 2.1 Scanning modes (MODE)

#### MODE-01 Home screen shows NEW SCAN
- **Env**: any
- **Pre**: Fresh install or app with some projects.
- **Steps**:
  1. Open Mapper from the home screen.
  2. Wait until the first screen is fully loaded.
- **Expected**: A large NEW SCAN button is on the home screen.
- **Pass if**: The button is visible without scrolling, takes up a clear area, and can be tapped with a thumb.
- **Log**: `app launched`, then `app active`. No errors.
- **Sev**: S2

#### MODE-02 Scan type choices
- **Env**: any
- **Pre**: MODE-01 passed.
- **Steps**:
  1. Tap NEW SCAN.
  2. Read the options.
- **Expected**: Five options: ROOM, HOUSE / BUILDING, OBJECT, QUICK MEASURE, ADVANCED SCAN.
- **Pass if**: All five are shown, each has a short plain-English description, and none mention LiDAR, mesh, SLAM, point cloud, anchor or photogrammetry on the first screen.
- **Log**: a line that the scan type picker was shown.
- **Sev**: S2 (S3 if only the wording is technical)

#### MODE-03 Each mode starts
- **Env**: ENV-LR
- **Pre**: MODE-02 passed. Camera permission not yet granted (first time) or granted.
- **Steps**:
  1. Tap ROOM. If asked for camera permission, tap Allow.
  2. Wait 5 seconds, then tap Cancel or Back.
  3. Repeat for HOUSE / BUILDING, OBJECT, QUICK MEASURE, ADVANCED SCAN.
- **Expected**: Each mode opens a camera view within 3 seconds and returns cleanly when cancelled.
- **Pass if**: No crash, no black screen longer than 3 seconds, and you return to the picker or home screen every time.
- **Log**: one `session start` block per mode with the mode name. A line that each session ended or was cancelled.
- **Sev**: S1 if any mode crashes, S2 if a mode will not start.

#### MODE-04 Camera permission denied
- **Env**: any
- **Pre**: In iOS Settings > Mapper, turn Camera off.
- **Steps**:
  1. Open Mapper and tap NEW SCAN > ROOM.
- **Expected**: A friendly message says the camera is needed, with a button that opens Settings.
- **Pass if**: No crash, no blank camera view, the button opens the Mapper page in Settings. After turning Camera back on and returning, scanning works.
- **Log**: a line saying camera permission is denied.
- **Sev**: S2

#### MODE-05 Sensible defaults
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan without changing any setting.
  2. Scan the room for 60 seconds.
  3. Finish.
- **Expected**: You get a usable result without having to choose any technical setting.
- **Pass if**: No setting had to be changed. The result shows at least a floor plan and a 3D view.
- **Log**: the session block lists the chosen defaults (for example mesh on, texture capture on, RoomPlan on).
- **Sev**: S3

#### MODE-06 Quick Measure
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Tap NEW SCAN > QUICK MEASURE.
  2. Point at a table edge. Tap to place the first point on one corner.
  3. Move to the other corner of the same edge and tap to place the second point.
  4. Measure the same edge with a tape measure.
- **Expected**: A distance appears within 10 seconds of opening the mode, with no full room scan needed.
- **Pass if**: The distance is shown in both metric and feet/inches (or in the chosen unit with the other available). It is within 2 cm of the tape value for an edge under 2 m.
- **Log**: the two point positions and the result.
- **Sev**: S2

#### MODE-07 Advanced Scan options
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Tap NEW SCAN > ADVANCED SCAN.
  2. Read every option shown.
  3. Change one option, scan for 30 seconds, finish.
- **Expected**: Advanced options are available here and not on the simple path. Each option has a short explanation.
- **Pass if**: The chosen option is reflected in the result (for example, a raw mesh only scan has no RoomPlan walls). The scan saves.
- **Log**: the session block shows the non-default option value.
- **Sev**: S3

### 2.2 Room scanning (ROOM)

#### ROOM-01 Basic room scan end to end
- **Env**: ENV-LR
- **Pre**: Phone charged, lights on.
- **Steps**:
  1. Tap NEW SCAN > ROOM.
  2. Stand in a corner. Point the phone at the wall at chest height.
  3. Walk slowly along the walls, turning the phone to follow each wall. Take about 60 to 90 seconds for a normal room.
  4. Point down at the floor for a sweep, then up at the ceiling for a sweep.
  5. Tap Finish (or Done).
  6. Wait for processing.
- **Expected**: The model forms live while you walk. After Finish, a result screen opens.
- **Pass if**: Processing ends in under 2 minutes for one room. Walls, floor and ceiling appear. The number of walls matches the room.
- **Log**: session start, scan start, scan stop, processing start and end with durations, save.
- **Sev**: S1

#### ROOM-02 Four result views
- **Env**: ENV-LR
- **Pre**: ROOM-01 done.
- **Steps**:
  1. On the result screen, switch to REALISTIC.
  2. Switch to 3D CLEAN.
  3. Switch to FLOOR PLAN.
  4. Switch to RAW MESH.
  5. Switch back to REALISTIC.
- **Expected**: Each view shows the same room in a different form.
- **Pass if**: All four views exist and load in under 3 seconds each. REALISTIC has photo textures. 3D CLEAN has flat walls and simple boxes. FLOOR PLAN is top-down 2D. RAW MESH shows the triangle mesh with holes and noise as captured.
- **Log**: view switch lines. No errors when loading textures.
- **Sev**: S2

#### ROOM-03 Wall, door and window detection
- **Env**: ENV-LR
- **Pre**: The room has at least one door and one window.
- **Steps**:
  1. Scan the room as in ROOM-01. Point at each door and window for 3 seconds.
  2. Finish and open 3D CLEAN.
  3. Count walls, doors and windows in the model and in the real room.
- **Expected**: All walls, doors and windows are found.
- **Pass if**: Wall count matches. Every door and window is present, in the right wall, roughly in the right position (within 20 cm).
- **Log**: detected object counts by category.
- **Sev**: S2

#### ROOM-04 Openings without doors
- **Env**: ENV-HOUSE (an archway or open kitchen)
- **Pre**: A wall opening with no door.
- **Steps**:
  1. Scan the room that has the opening.
  2. Finish and open 3D CLEAN and FLOOR PLAN.
- **Expected**: The opening is shown as an opening, not as a wall and not as a door.
- **Pass if**: The opening is visible in both views with a width within 5 cm of the tape value.
- **Log**: an opening detection line.
- **Sev**: S3

#### ROOM-05 RoomPlan and LiDAR mesh together
- **Env**: ENV-KIT
- **Pre**: None.
- **Steps**:
  1. Scan the kitchen as in ROOM-01. Include counters and appliances.
  2. Finish. Open RAW MESH and 3D CLEAN side by side (or switch between them).
- **Expected**: The raw mesh has detail that RoomPlan does not (tap, handles, items on the counter, curved shapes).
- **Pass if**: RAW MESH shows detail not present in 3D CLEAN. Both line up (walls in the clean model sit on the mesh walls within 3 cm).
- **Log**: both the room capture and the mesh capture are logged as running. Mesh anchor count or face count at the end.
- **Sev**: S2

#### ROOM-06 Mirror room
- **Env**: ENV-BATH, mirror uncovered
- **Pre**: None.
- **Steps**:
  1. Scan the bathroom as in ROOM-01. Look at the mirror for 5 seconds on purpose.
  2. Finish. Look at 3D CLEAN, FLOOR PLAN and RAW MESH.
  3. Repeat with a towel over the mirror.
- **Expected**: The mirror wall stays a wall. There is no fake room behind it.
- **Pass if**: No geometry beyond the mirror wall in the clean model or floor plan. If the raw mesh has ghost geometry, it is not used in the floor plan. Room area with and without the towel differs by less than 5 percent.
- **Log**: any warning about reflective surfaces.
- **Sev**: S2

#### ROOM-07 Glass windows and glass doors
- **Env**: ENV-REST front windows, or ENV-OFF glass partition
- **Pre**: Daylight behind the glass.
- **Steps**:
  1. Scan a wall with a large window or glass door.
  2. Finish and open all views.
- **Expected**: The window is a window. Things outside the glass do not become part of the room.
- **Pass if**: The wall line is continuous in the floor plan. No outdoor geometry in 3D CLEAN.
- **Log**: window detection lines.
- **Sev**: S2

#### ROOM-08 Low light
- **Env**: ENV-LR with one lamp only
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan in dim light.
  2. Scan for 60 seconds.
  3. Finish.
- **Expected**: The app shows "Lighting is poor" (or similar) but still captures geometry. LiDAR works in the dark; texture quality drops.
- **Pass if**: The message appears within 10 seconds. The scan completes. Walls and floor plan are still produced. Texture score in the quality screen is lower than in normal light.
- **Log**: lighting warning with a timestamp. Tracking state lines.
- **Sev**: S3

#### ROOM-09 Low texture walls
- **Env**: ENV-HALL (plain walls)
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan. Hold the phone 30 cm from a plain wall so it fills the view, for 10 seconds.
  2. Then step back and continue normally.
- **Expected**: "Tracking quality is low" appears while close to the plain wall. It clears after stepping back.
- **Pass if**: Message appears and then clears. The final model has no doubled or bent walls.
- **Log**: tracking state changes (for example normal to limited and back) with reasons.
- **Sev**: S3

#### ROOM-10 Large open room
- **Env**: ENV-REST
- **Pre**: Restaurant closed, lights on.
- **Steps**:
  1. Start a ROOM scan. Walk the perimeter slowly (about 3 to 5 minutes).
  2. Then walk once through the middle between tables.
  3. Finish.
- **Expected**: The whole room is captured. The far side is not missing.
- **Pass if**: All walls are present. The start corner and end corner line up (no gap or overlap of more than 10 cm where the loop closes). Overall length and width are within 2 percent of tape or laser values.
- **Log**: scan duration, tracking relocalization events, final wall count.
- **Sev**: S2

#### ROOM-11 Room scan cancelled
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan. Scan for 20 seconds.
  2. Tap Cancel.
- **Expected**: The app asks "Discard this scan?" or similar, with Keep and Discard.
- **Pass if**: Discard returns home with no new project. Keep saves the partial scan as a project.
- **Log**: cancel with the user choice.
- **Sev**: S2 (S1 if data is lost after choosing Keep)

#### ROOM-12 Outdoors next to a wall
- **Env**: ENV-OUT
- **Pre**: Daytime.
- **Steps**:
  1. Start a ROOM scan (or ADVANCED SCAN if the app suggests it) facing an outside wall.
  2. Sweep the wall and the ground in front of it for 60 seconds.
  3. Finish.
- **Expected**: The wall and ground are captured. The app either warns that outdoor scans have limits or produces a partial model without inventing a ceiling or closed room.
- **Pass if**: No crash. No fake ceiling. Wall length within 5 percent of the tape. A clear message if room mode is not suitable.
- **Log**: outdoor or no-ceiling warning, sunlight or depth confidence warnings.
- **Sev**: S3

### 2.3 House / Building mode (HOUSE)

#### HOUSE-01 Create a building project
- **Env**: ENV-HOUSE
- **Pre**: None.
- **Steps**:
  1. Tap NEW SCAN > HOUSE / BUILDING.
  2. Give it a name (for example "Home test").
  3. Scan the first room as in ROOM-01. Name it "Living room".
  4. Finish the room.
- **Expected**: A room list appears with "Living room" marked done, and a button to scan the next room.
- **Pass if**: The list and the next-room button are there. The room is saved inside the building project, not as a separate project.
- **Log**: building project created, room 1 saved.
- **Sev**: S1

#### HOUSE-02 Add connected rooms
- **Env**: ENV-HOUSE
- **Pre**: HOUSE-01 done.
- **Steps**:
  1. Tap the button to scan the next room. Name it "Hallway".
  2. Start the scan standing in the doorway between the living room and the hallway. Point back into the living room for 5 seconds first.
  3. Scan the hallway. Finish.
  4. Repeat for "Kitchen" and "Bathroom", each time starting in the connecting doorway.
- **Expected**: Each new room snaps into place next to the rooms already scanned.
- **Pass if**: Room list shows all four rooms done. The combined plan shows rooms joined at doorways. Shared walls line up within 10 cm and are not doubled more than the real wall thickness.
- **Log**: per room: alignment method (for example shared world map, relocalization, or doorway match) and alignment result or error.
- **Sev**: S1 if rooms are not combined, S2 if misaligned.

#### HOUSE-03 Shared walls
- **Env**: ENV-HOUSE
- **Pre**: HOUSE-02 done.
- **Steps**:
  1. Open the combined FLOOR PLAN.
  2. Find a wall that separates two scanned rooms.
  3. Measure the real wall thickness at a door frame with the tape.
- **Expected**: The wall is drawn once, with a thickness close to the real one.
- **Pass if**: One wall, not two overlapping lines or a gap. Thickness within 3 cm of the tape value, or shown as "estimated".
- **Log**: shared wall matches found.
- **Sev**: S2

#### HOUSE-04 Doorway connections
- **Env**: ENV-HOUSE
- **Pre**: HOUSE-02 done.
- **Steps**:
  1. Open the combined 3D CLEAN view.
  2. Check each door between two rooms.
- **Expected**: Each connecting door appears once and links the two rooms.
- **Pass if**: No duplicate doors on the two sides of the same doorway. Tapping the door (if supported) shows both room names.
- **Log**: doorway links.
- **Sev**: S3

#### HOUSE-05 Progress list and incomplete room
- **Env**: ENV-HOUSE
- **Pre**: A building project with at least two rooms.
- **Steps**:
  1. Scan the hallway for only 10 seconds and finish anyway (FINISH ANYWAY if asked).
  2. Look at the room list.
  3. Tap the hallway entry.
- **Expected**: The hallway is marked "needs additional scan" (or similar). Tapping it offers to continue scanning that room.
- **Pass if**: Status is different from the done rooms. You can return and add to the hallway scan. After adding, the status changes to done.
- **Log**: room status changes.
- **Sev**: S2

#### HOUSE-06 Return to an incomplete room later
- **Env**: ENV-HOUSE
- **Pre**: HOUSE-05 done. Close the app fully (swipe up from the app switcher).
- **Steps**:
  1. Reopen Mapper. Open the building project.
  2. Tap the incomplete hallway and continue scanning. Start in the same spot you stopped.
  3. Finish.
- **Expected**: The new part attaches to the old part of the hallway in the right place.
- **Pass if**: No second copy of the hallway, no offset of more than 10 cm between old and new parts.
- **Log**: relocalization success or failure, time to relocalize.
- **Sev**: S2

#### HOUSE-07 Manual alignment fix
- **Env**: ENV-HOUSE
- **Pre**: A building with at least two rooms. If alignment was perfect, force a bad one: scan one room starting in the middle of the room, not at the doorway.
- **Steps**:
  1. Open the combined plan. Find a misplaced room.
  2. Use the manual alignment tool to move and rotate it so its door lines up with the neighbor's door.
  3. Save. Close and reopen the project.
- **Expected**: You can drag and rotate a room. The fix is saved.
- **Pass if**: The room can be moved and rotated with fingers. After reopening, the fix is still there. The raw scan of the room is unchanged (RAW MESH of that room alone looks the same as before).
- **Log**: manual alignment edit with the offset and angle.
- **Sev**: S2

#### HOUSE-08 Multiple floors
- **Env**: ENV-HOUSE with stairs
- **Pre**: Two floors available.
- **Steps**:
  1. In the building project, scan a room downstairs.
  2. Scan the stairs slowly, going up (hold the handrail, move slowly).
  3. Scan a room upstairs.
  4. Open the plan.
- **Expected**: The app puts upstairs rooms on a second floor level, or clearly says multiple floors are not supported and lets you pick the floor.
- **Pass if**: Upstairs rooms do not overlap downstairs rooms on the same plan. A floor selector (Floor 1, Floor 2) exists, or a clear message explains the limit. Stairs appear if detected.
- **Log**: floor level assignment, stairs detection.
- **Sev**: S3

#### HOUSE-09 Whole restaurant as a building
- **Env**: ENV-REST plus kitchen, restrooms and hallway
- **Pre**: Restaurant closed. At least 40 minutes available.
- **Steps**:
  1. Create a building project "Restaurant test".
  2. Scan dining room, bar, kitchen, restrooms and hallway as separate rooms.
  3. Open the combined plan and 3D CLEAN.
- **Expected**: One building model with all rooms joined.
- **Pass if**: All rooms present and joined. The outer size of the building matches a tape or laser value within 2 percent. No crash across the whole session.
- **Log**: per-room durations, thermal state changes, memory warnings, total project size on disk.
- **Sev**: S1 for crash or data loss, S2 for misalignment.

### 2.4 Object scanning (OBJ)

#### OBJ-01 Guided object scan of a box
- **Env**: ITEM-BOX
- **Pre**: Box in open floor, 1 m clear on all sides. Tape values of width, height and depth written down.
- **Steps**:
  1. Tap NEW SCAN > OBJECT.
  2. Point at the box. Follow the on-screen outline or bounding box step if shown, and confirm the box is selected.
  3. Walk slowly around the box once at chest height (about 30 seconds).
  4. Walk around again holding the phone lower, then once higher looking down at the top.
  5. Follow any instruction the app gives ("Capture the left side", "Capture the top").
  6. Finish and wait for processing.
- **Expected**: The app guides you with messages. The result is only the box, not the floor or room.
- **Pass if**: Guidance messages appear and change as you move. The result has no floor around the box (or only a small trimmed base). Width, height and depth each within 1.5 cm or 3 percent of the tape, whichever is larger.
- **Log**: object capture state changes, number of images captured, processing time, bounding box size.
- **Sev**: S1 if no object is produced, S2 if dimensions are wrong.

#### OBJ-02 Object outputs
- **Env**: ITEM-BOX
- **Pre**: OBJ-01 done.
- **Steps**:
  1. Open the object result.
  2. Look for textured mesh, untextured mesh, bounding box, width, height, depth and volume.
- **Expected**: All are available.
- **Pass if**: You can switch between textured and untextured. The bounding box can be shown. Width, height, depth are labelled. Volume is shown, and for the box it is within 5 percent of width x height x depth from the tape.
- **Log**: the computed dimensions and volume.
- **Sev**: S2

#### OBJ-03 Volume only when valid
- **Env**: ITEM-CHAIR
- **Pre**: None.
- **Steps**:
  1. Scan the chair as in OBJ-01.
  2. Look at the volume field.
- **Expected**: For an open shape like a chair, the app either hides volume, labels it "bounding box volume", or marks it "estimated" with an explanation.
- **Pass if**: The app does not present a chair's bounding-box volume as its true solid volume.
- **Log**: whether the mesh is closed (watertight) and which volume type was used.
- **Sev**: S3

#### OBJ-04 Thin parts and gaps
- **Env**: ITEM-CHAIR
- **Pre**: OBJ-03 done.
- **Steps**:
  1. Look at the legs and the back of the chair in the textured and untextured result.
- **Expected**: Legs are present. Gaps in the chair back are open, not filled in.
- **Pass if**: All legs visible and roughly the right thickness. Gaps are not covered by a solid sheet. If detail is missing, the app said "This section needs more detail" during the scan.
- **Log**: guidance messages during capture.
- **Sev**: S3

#### OBJ-05 Object against a wall
- **Env**: ITEM-FRIDGE
- **Pre**: Fridge against the wall.
- **Steps**:
  1. Start an OBJECT scan of the fridge.
  2. Scan the front, both sides and the top (use a step stool only if safe).
  3. Finish.
- **Expected**: The app tells you it cannot see the back or accepts a partial object. It does not add the wall to the fridge.
- **Pass if**: The wall is not part of the object. Width and height are within 2 cm. Depth is marked estimated or partial if the back was not seen.
- **Log**: a coverage warning about the back side.
- **Sev**: S3

#### OBJ-06 Small object
- **Env**: ITEM-VASE
- **Pre**: Vase on a table with a plain surface.
- **Steps**:
  1. Start an OBJECT scan. Circle the vase at 30 to 50 cm distance, three times at three heights.
  2. Finish.
- **Expected**: A detailed textured model of the vase alone.
- **Pass if**: The shape is recognizable. The table top is removed or can be cropped away. Height within 1 cm. The app says "Move closer" or "Too close" at the right times.
- **Log**: image count, processing detail level, any "object too small" warning.
- **Sev**: S3

#### OBJ-07 Shiny, attached object
- **Env**: ITEM-CARDOOR
- **Pre**: Car parked, door open, daylight or garage light.
- **Steps**:
  1. Start an OBJECT scan of the open door.
  2. Scan both sides and the edge.
  3. Finish.
  4. Use the crop tool to remove the car body.
- **Expected**: A usable door model after cropping. The app may warn about shiny surfaces.
- **Pass if**: The crop tool removes the unwanted body. The door outline is recognizable. Door width within 3 cm of the tape.
- **Log**: reflective surface or low confidence warnings, crop edit.
- **Sev**: S3

#### OBJ-08 Manual crop
- **Env**: ITEM-TABLE
- **Pre**: Table scanned with some floor and a nearby chair in the result.
- **Steps**:
  1. Open the object result. Tap Crop.
  2. Drag the crop box edges to cut away the floor and the chair.
  3. Save. Close and reopen the project.
- **Expected**: Only the table remains in the object model.
- **Pass if**: Crop is kept after reopening. An option to undo or reset the crop exists. The raw scan still contains the removed parts (check RAW MESH).
- **Log**: crop edit saved, raw data untouched.
- **Sev**: S2

#### OBJ-09 Object mode is not room mode
- **Env**: ITEM-TABLE in ENV-LR
- **Pre**: None.
- **Steps**:
  1. Scan the table in OBJECT mode.
  2. Open the result.
- **Expected**: An isolated object. No walls, no floor plan, no room.
- **Pass if**: No walls or room dimensions appear. Width, height, depth of the table within 2 cm.
- **Log**: mode = object.
- **Sev**: S2

### 2.5 Image and texture capture (TEX)

#### TEX-01 Textures are real photos
- **Env**: ENV-LR
- **Pre**: ROOM-01 done.
- **Steps**:
  1. Open REALISTIC. Zoom in on a picture frame, a book shelf and a rug.
- **Expected**: Surfaces show real photo colors and patterns, not gray.
- **Pass if**: You can recognize the picture, the book spines (as shapes and colors) and the rug pattern.
- **Log**: number of texture frames used, texture resolution.
- **Sev**: S1 if everything is gray, S2 if textures are badly blurred.

#### TEX-02 Display modes
- **Env**: any finished scan
- **Pre**: A finished room or object scan.
- **Steps**:
  1. Switch through PHOTO REALISTIC, TEXTURED, SOLID COLOR, WIREFRAME, RAW MESH.
- **Expected**: Five modes, each clearly different.
- **Pass if**: All five exist and switch in under 3 seconds. WIREFRAME shows triangle edges. SOLID COLOR has no photo texture.
- **Log**: mode switches.
- **Sev**: S3

#### TEX-03 Exposure and light changes
- **Env**: ENV-LR with a bright window and a dark corner
- **Pre**: Daylight.
- **Steps**:
  1. Scan the room, including the bright window wall and the dark corner.
  2. Open REALISTIC and look where bright and dark areas meet.
- **Expected**: Brightness blends smoothly between photos.
- **Pass if**: No hard patchwork of bright and dark squares on one flat wall. Some brightness difference is fine; sharp tile edges are a fail.
- **Log**: exposure compensation or blending lines.
- **Sev**: S3

#### TEX-04 Seams and alignment
- **Env**: ENV-KIT
- **Pre**: A finished kitchen scan.
- **Steps**:
  1. In REALISTIC, look at the cabinet edges and tile grout lines.
- **Expected**: Edges and lines continue straight across photo boundaries.
- **Pass if**: Tile lines do not jump by more than about 1 cm at seams. Cabinet handles are not doubled.
- **Log**: none specific.
- **Sev**: S3

#### TEX-05 Photos linked to locations
- **Env**: ENV-LR
- **Pre**: A finished room scan.
- **Steps**:
  1. Find the photo view or camera position markers (if the app has them).
  2. Tap one marker.
- **Expected**: The photo taken at that spot opens, and the view points in the right direction.
- **Pass if**: The photo matches the part of the room at that marker. Original photo quality is kept (zoom in: not blocky).
- **Log**: number of stored frames, total image size.
- **Sev**: S3

#### TEX-06 Texture fails, geometry kept
- **Env**: ENV-GAR in very low light
- **Pre**: Lights off, only light from the door.
- **Steps**:
  1. Scan part of the garage for 60 seconds.
  2. Finish.
- **Expected**: Geometry is kept. Texture is dark or partial, and the app says texture quality is low.
- **Pass if**: The geometry is complete. No crash. Texture score is low in the quality screen. SOLID COLOR mode gives a clear view.
- **Log**: low light warnings, texture step outcome.
- **Sev**: S2 if geometry is lost.

### 2.6 Live scanning experience (LIVE)

#### LIVE-01 Model forms while walking
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan. Walk slowly along one wall.
- **Expected**: Mesh or walls appear on screen as you scan, with less than 1 second delay.
- **Pass if**: New geometry appears where you point within 1 second. The camera view does not freeze or stutter below about 20 frames per second (smooth to the eye).
- **Log**: frame rate or dropped frame lines if logged.
- **Sev**: S2

#### LIVE-02 Coverage colors
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Start a ROOM scan. Point at one wall for 5 seconds. Glance quickly at a second wall. Do not look at a third wall.
  2. Look at the on-screen colors (or the mini map).
- **Expected**: GREEN on the well scanned wall, YELLOW on the quick glance, RED for areas known to be missing, GRAY for areas not scanned.
- **Pass if**: The colors match what you did. A legend explaining the colors is available.
- **Log**: coverage percentages over time.
- **Sev**: S3

#### LIVE-03 Move slower
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. During a scan, swing the phone fast from one wall to another (about half a turn in 1 second). Do it three times.
- **Expected**: "Move slower" appears.
- **Pass if**: The message appears within 2 seconds and goes away within 3 seconds after you slow down.
- **Log**: guidance message shown with the reason.
- **Sev**: S3

#### LIVE-04 Too close and too far
- **Env**: ENV-REST (for too far) and any wall (for too close)
- **Pre**: None.
- **Steps**:
  1. During a scan, hold the phone 10 cm from a wall for 5 seconds.
  2. Then point at a wall more than 6 m away for 5 seconds.
- **Expected**: "Too close" in step 1. "Too far" or "Move closer" in step 2.
- **Pass if**: Both messages appear at the right time.
- **Log**: guidance messages.
- **Sev**: S3

#### LIVE-05 Floor and ceiling prompts
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Scan only the walls at eye level for 60 seconds.
- **Expected**: The app asks "Point toward the floor" and "Scan the ceiling".
- **Pass if**: Both prompts appear before you finish or on the quality screen.
- **Log**: guidance messages.
- **Sev**: S3

#### LIVE-06 Detection messages
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. During a scan, point at a door, a window and a wall in turn.
- **Expected**: "Door detected", "Window detected", "Wall detected" appear (short and not repeated every second).
- **Pass if**: Each shows once per new item, not repeatedly for the same item.
- **Log**: detection events.
- **Sev**: S4

#### LIVE-07 Tracking lost and recovered
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. During a scan, cover the camera and LiDAR with your hand for 5 seconds.
  2. Uncover and point back at the area you scanned last.
- **Expected**: "Tracking quality is low" (or similar) appears. After uncovering, tracking recovers and scanning continues in the right place.
- **Pass if**: Message appears within 2 seconds. After recovery, new geometry lines up with the old geometry (no second copy of the wall).
- **Log**: tracking state change to limited or not available, then back to normal, with time to recover.
- **Sev**: S2

#### LIVE-08 Not overwhelming
- **Env**: ENV-KIT
- **Pre**: None.
- **Steps**:
  1. Scan the kitchen normally for 2 minutes. Count how many messages you see.
- **Expected**: Only important messages. At most one main instruction at a time.
- **Pass if**: Never more than two messages on screen at once. No message flashes on and off more than twice in 5 seconds.
- **Log**: guidance message rate.
- **Sev**: S3

#### LIVE-09 This area needs another pass
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Scan the room, but skip one corner behind a sofa.
  2. Try to finish.
- **Expected**: The app points at the corner and says "Scan this corner" or "This area needs another pass".
- **Pass if**: The prompt points at the right area (arrow or highlight).
- **Log**: missing area positions.
- **Sev**: S3

#### LIVE-10 Haptics
- **Env**: any
- **Pre**: Phone not in silent vibration off mode.
- **Steps**:
  1. Start a scan, trigger a warning (see LIVE-03), and finish.
- **Expected**: Light vibrations for start, finish and important warnings (if haptics are part of the design).
- **Pass if**: Vibrations are short and not constant.
- **Log**: none specific.
- **Sev**: S4

### 2.7 Scan quality system (QUAL)

#### QUAL-01 Quality screen before finish
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Scan the room completely (ROOM-01 style).
  2. Tap Finish.
- **Expected**: A SCAN QUALITY screen with Geometry, Walls, Floor, Ceiling, Textures percentages and a Missing areas count.
- **Pass if**: All six items are shown. Percentages are between 0 and 100. Two buttons: FINISH ANYWAY and SHOW MISSING AREAS.
- **Log**: the same numbers in the log.
- **Sev**: S2

#### QUAL-02 Scores respond to real coverage
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Scan only the walls, never point at the ceiling. Tap Finish. Write down the Ceiling score.
  2. Tap SHOW MISSING AREAS or go back. Scan the ceiling fully. Tap Finish again. Write down the Ceiling score.
- **Expected**: Ceiling score goes up clearly after scanning the ceiling.
- **Pass if**: First ceiling score is under 50 percent. Second is over 80 percent.
- **Log**: both quality snapshots.
- **Sev**: S2

#### QUAL-03 Show missing areas guides you
- **Env**: ENV-LR
- **Pre**: Scan with a skipped corner (see LIVE-09).
- **Steps**:
  1. On the quality screen, tap SHOW MISSING AREAS.
  2. Follow the guide to the first missing area. Scan it.
  3. Repeat for all missing areas.
- **Expected**: An arrow or highlight leads you to each missing spot. The count goes down as you fill them.
- **Pass if**: You reach each area by following the guide only. Count reaches 0 or near 0.
- **Log**: missing area count over time.
- **Sev**: S2

#### QUAL-04 Finish anyway
- **Env**: ENV-LR
- **Pre**: A scan with missing areas.
- **Steps**:
  1. Tap FINISH ANYWAY.
- **Expected**: The scan saves and the result opens. Missing areas are marked in the result.
- **Pass if**: Result opens. Missing parts are shown as unscanned (not filled with invented geometry).
- **Log**: finish with quality numbers.
- **Sev**: S2

#### QUAL-05 Quality is honest in hard rooms
- **Env**: ENV-BATH mirror uncovered, and ENV-GAR low light
- **Pre**: None.
- **Steps**:
  1. Scan each space quickly (30 seconds). Finish.
  2. Compare scores with the living room scores from QUAL-01.
- **Expected**: Lower scores in the hard rooms, especially Textures in the garage.
- **Pass if**: Scores in hard rooms are lower than the living room. The app does not show 100 percent for a 30 second scan.
- **Log**: quality numbers.
- **Sev**: S3

### 2.8 Automatic object recognition (REC)

#### REC-01 Common objects labelled
- **Env**: ENV-LR, ENV-KIT, ENV-BATH
- **Pre**: None.
- **Steps**:
  1. Scan each room.
  2. In 3D CLEAN, tap each object and read its label.
  3. Fill a table: real object, label shown, correct yes or no.
- **Expected**: Most items from the spec list are recognized: table, chair, door, window, sink, toilet, cabinet, counter, refrigerator, oven, bed, sofa, desk, TV, stairs, wall, floor, ceiling.
- **Pass if**: At least 80 percent of visible listed items have the right label. No wall is labelled as furniture.
- **Log**: recognized objects with category and confidence.
- **Sev**: S3

#### REC-02 Correct a label
- **Env**: any finished scan
- **Pre**: At least one object.
- **Steps**:
  1. Tap an object. Choose Change category (or Rename). Pick a different category, for example change "table" to "desk".
  2. Close and reopen the project.
- **Expected**: The new label shows and is saved.
- **Pass if**: Label kept after reopen. Floor plan symbol updates to match.
- **Log**: label edit with old and new value.
- **Sev**: S2

#### REC-03 Labels not baked into raw scan
- **Env**: any
- **Pre**: REC-02 done.
- **Steps**:
  1. Open RAW MESH of the same project.
  2. Look for a "reset labels" or "show original detection" option.
- **Expected**: The raw scan has no labels applied to it. The original detection can be restored.
- **Pass if**: RAW MESH has no object labels drawn into the mesh. Restoring the original detection brings back the first label.
- **Log**: edits stored separately from raw data.
- **Sev**: S2

#### REC-04 Restaurant repeated items
- **Env**: ENV-REST
- **Pre**: None.
- **Steps**:
  1. Scan the dining room.
  2. Count tables and chairs found vs real.
- **Expected**: Most tables and chairs are found once each.
- **Pass if**: At least 80 percent of tables found. No table counted twice. Chairs tucked under tables may be missed; that is acceptable.
- **Log**: object counts per category.
- **Sev**: S3

#### REC-05 Low confidence labels shown as such
- **Env**: ENV-GAR
- **Pre**: None.
- **Steps**:
  1. Scan garage shelves with mixed items.
- **Expected**: Unknown items are "object" or "unknown", not forced into a wrong category.
- **Pass if**: Shelving is not labelled bed, sofa or toilet. Uncertain labels are marked (for example with a question mark) if the app shows confidence.
- **Log**: low confidence detections.
- **Sev**: S3

### 2.9 Furniture removal (FURN)

#### FURN-01 Hide furniture
- **Env**: ENV-LR
- **Pre**: A finished living room scan with a sofa against a wall.
- **Steps**:
  1. Open 3D CLEAN. Tap HIDE FURNITURE.
  2. Tap it again to show furniture.
- **Expected**: Sofa, tables and chairs disappear, then come back. Walls, doors, windows stay.
- **Pass if**: Movable furniture hides. Fixed items (counters, cabinets built in) do not hide, or the app lets you choose.
- **Log**: hide toggle, count of hidden objects.
- **Sev**: S2

#### FURN-02 Occluded areas marked
- **Env**: ENV-LR
- **Pre**: FURN-01 with furniture hidden.
- **Steps**:
  1. Look at the wall and floor behind where the sofa was.
- **Expected**: That area is marked INFERRED, OCCLUDED or UNSCANNED (for example hatched, faded or a different color).
- **Pass if**: The hidden area looks different from measured areas. A legend explains the marking.
- **Log**: occluded region count or area.
- **Sev**: S2

#### FURN-03 No invented detail
- **Env**: ENV-LR
- **Pre**: FURN-02.
- **Steps**:
  1. Place a measurement across the area behind the sofa (floor to wall).
- **Expected**: The measurement is marked estimated, with lower confidence.
- **Pass if**: The app does not show survey-looking precision (like ±0.2 cm) for an occluded area. The value is labelled "estimated" or similar.
- **Log**: measurement confidence source (measured or inferred).
- **Sev**: S2

#### FURN-04 Floor plan without furniture
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Open FLOOR PLAN. Turn the Furniture toggle off.
- **Expected**: Clean plan with only walls, doors, windows and fixtures.
- **Pass if**: Furniture symbols gone. Walls behind furniture are drawn but visibly marked estimated where not seen.
- **Log**: plan layer toggles.
- **Sev**: S3

### 2.10 Measurement system (MEAS)

Use the tape measure procedure in section 3 for numbers. These tests check that each measurement type exists and works.

#### MEAS-01 Point to point
- **Env**: ENV-LR
- **Pre**: A finished room scan and a tape value between two marked points (painter's tape X on two walls).
- **Steps**:
  1. Open the model. Tap Measure.
  2. Tap the first X. Tap the second X.
- **Expected**: A line with a distance appears.
- **Pass if**: Value within the thresholds in section 3.5. Points can be dragged to adjust.
- **Log**: measurement created with both points and value.
- **Sev**: S2

#### MEAS-02 Wall length and height
- **Env**: ENV-LR
- **Pre**: Finished room scan.
- **Steps**:
  1. Tap a wall. Choose Measure.
- **Expected**: Wall length and wall height shown.
- **Pass if**: Length within 2 percent or 5 cm of tape (whichever is larger). Height within 3 cm.
- **Log**: wall dimension values.
- **Sev**: S2

#### MEAS-03 Ceiling height
- **Env**: ENV-LR
- **Pre**: Finished room scan.
- **Steps**:
  1. Find ceiling height in the room info or by tapping the floor and ceiling.
- **Expected**: One ceiling height value (or a range if the ceiling slopes).
- **Pass if**: Within 3 cm of the tape.
- **Log**: ceiling height value.
- **Sev**: S2

#### MEAS-04 Door and window size
- **Env**: ENV-LR
- **Pre**: Finished room scan.
- **Steps**:
  1. Tap a door. Read width and height.
  2. Tap a window. Read width and height.
- **Expected**: Both sizes shown for each.
- **Pass if**: Door width within 2 cm. Door height within 3 cm. Window within 3 cm. Say in your notes whether the app measures the opening or the frame; compare the same thing with the tape.
- **Log**: door and window dimensions.
- **Sev**: S2

#### MEAS-05 Room length, width, area and perimeter
- **Env**: ENV-LR (a rectangular room if you have one)
- **Pre**: Finished room scan.
- **Steps**:
  1. Open room info.
- **Expected**: Room length, width, floor area, perimeter, wall area.
- **Pass if**: Length and width within 2 percent. Floor area within 4 percent of tape length x width. Perimeter within 2 percent.
- **Log**: room dimension values.
- **Sev**: S2

#### MEAS-06 Surface area and wall area
- **Env**: ENV-LR
- **Pre**: Finished room scan.
- **Steps**:
  1. Tap one wall. Read wall area.
  2. Compute tape length x tape height. Subtract door and window areas if the app says it does.
- **Expected**: Wall area close to your calculation.
- **Pass if**: Within 5 percent. The app says whether openings are subtracted.
- **Log**: area values.
- **Sev**: S3

#### MEAS-07 Angle
- **Env**: ENV-LR
- **Pre**: Finished room scan.
- **Steps**:
  1. Use the angle tool on a room corner (two walls).
- **Expected**: About 90 degrees for a normal corner.
- **Pass if**: Between 88 and 92 degrees for a square corner (check with a carpenter's square if you have one).
- **Log**: angle value.
- **Sev**: S3

#### MEAS-08 Snapping
- **Env**: ENV-KIT
- **Pre**: Finished kitchen scan.
- **Steps**:
  1. Start a measurement. Drag the point near a counter corner. Then near a wall edge, floor, ceiling, door edge, window edge and object edge.
- **Expected**: The point jumps to the exact corner or edge when close, with a small haptic or visual signal.
- **Pass if**: Snapping works for at least corner, wall, edge, floor and door. You can turn snapping off or hold to place freely.
- **Log**: snap target type.
- **Sev**: S3

#### MEAS-09 Units
- **Env**: any
- **Pre**: A measurement exists.
- **Steps**:
  1. Read a measurement. Note both metric and feet/inches if both shown.
  2. Change the unit preference in Settings. Go back.
  3. Check a known value: 3.845 m must read 12' 7 3/8" (spec example).
- **Expected**: Both unit systems available. Preference applies everywhere (live, 3D, plan, export).
- **Pass if**: Conversion is right to the nearest 1/8 inch. The preference is kept after restart.
- **Log**: unit preference change.
- **Sev**: S2

#### MEAS-10 Delete and edit measurement
- **Env**: any
- **Pre**: Two measurements exist.
- **Steps**:
  1. Drag one end of a measurement. Delete the other measurement.
  2. Close and reopen the project.
- **Expected**: Changes are saved.
- **Pass if**: Edited value kept. Deleted measurement stays deleted.
- **Log**: measurement edit and delete.
- **Sev**: S3

#### MEAS-11 Object dimensions from room scan
- **Env**: ENV-LR
- **Pre**: A table in the room scan.
- **Steps**:
  1. Tap the table in 3D CLEAN. Choose Measure.
- **Expected**: Width, depth, height.
- **Pass if**: Each within 3 cm of the tape (room scans are less precise than object scans).
- **Log**: object dimensions.
- **Sev**: S3

### 2.11 Measurement confidence (CONF)

#### CONF-01 Confidence shown
- **Env**: ENV-LR
- **Pre**: A finished scan.
- **Steps**:
  1. Tap a wall length.
- **Expected**: The value has an accuracy estimate, for example "Estimated accuracy ±1.5 cm (±5/8")".
- **Pass if**: An estimate is shown for wall lengths, point-to-point and object dimensions.
- **Log**: confidence value and how it was computed (for example depth confidence, distance from camera, number of observations).
- **Sev**: S3

#### CONF-02 Confidence is honest
- **Env**: section 3 protocol
- **Pre**: Section 3 table filled.
- **Steps**:
  1. For each reference distance, check whether the tape value falls inside the app value plus or minus its shown accuracy.
- **Expected**: The true value is inside the range most of the time.
- **Pass if**: At least 8 of 10 reference distances fall inside the shown range. If fewer, the app is overconfident (S2).
- **Log**: none extra.
- **Sev**: S2

#### CONF-03 Low confidence warning
- **Env**: ENV-GAR low light, or a wall scanned from 5 m away only
- **Pre**: None.
- **Steps**:
  1. Scan a wall only from far away with quick sweeps. Finish.
  2. Measure that wall.
- **Expected**: "Low confidence, rescan this section" (or similar) on that measurement.
- **Pass if**: The warning appears for poorly scanned areas and not for well scanned ones.
- **Log**: low confidence flag.
- **Sev**: S2

#### CONF-04 No survey-grade claims
- **Env**: any
- **Pre**: None.
- **Steps**:
  1. Read the whole app (onboarding, measurement screens, export, App info) for accuracy claims.
- **Expected**: No words like "survey-grade", "exact", "millimeter precise", "professional accuracy guaranteed".
- **Pass if**: No such claims. Decimal places match accuracy (for example 3.845 m is fine when shown with ±1 cm; 3.84512 m is not).
- **Log**: none.
- **Sev**: S3

### 2.12 2D floor plan (PLAN)

#### PLAN-01 Plan generated automatically
- **Env**: ENV-LR
- **Pre**: A finished room scan.
- **Steps**:
  1. Open FLOOR PLAN.
- **Expected**: A clean top-down plan appears with no extra steps.
- **Pass if**: Walls are straight lines, corners are closed, the shape matches the room.
- **Log**: plan generation time.
- **Sev**: S1

#### PLAN-02 Plan contents
- **Env**: ENV-KIT and ENV-BATH
- **Pre**: Finished scans.
- **Steps**:
  1. Check the plan for: walls, wall thickness, doors, door swing, windows, openings, room names, room dimensions, overall dimensions, fixtures, stairs, counters, bathroom fixtures, kitchen equipment.
- **Expected**: All that apply are present.
- **Pass if**: Every item that exists in the real space is on the plan or clearly marked unknown (for example door swing unknown).
- **Log**: plan element counts.
- **Sev**: S3 per missing item, S2 if walls, doors or dimensions are missing.

#### PLAN-03 Toggles
- **Env**: any plan
- **Pre**: PLAN-01.
- **Steps**:
  1. Turn each toggle off and on: Furniture, Measurements, Room names, Doors/windows, Fixtures, Grid, Scale.
- **Expected**: Each toggle hides and shows its layer.
- **Pass if**: All seven toggles work and do not affect other layers.
- **Log**: toggle changes.
- **Sev**: S3

#### PLAN-04 Scale is right
- **Env**: any plan
- **Pre**: Scale bar on.
- **Steps**:
  1. Export or screenshot the plan. Measure one wall on screen against the scale bar.
- **Expected**: Scale bar matches the drawn dimensions.
- **Pass if**: A wall measured with the scale bar agrees with the dimension label within 5 percent.
- **Log**: scale value.
- **Sev**: S3

#### PLAN-05 Multi-room plan
- **Env**: ENV-HOUSE
- **Pre**: HOUSE-02 done.
- **Steps**:
  1. Open the building FLOOR PLAN.
- **Expected**: All rooms on one plan with names and dimensions, plus overall dimensions.
- **Pass if**: Overall length and width within 2 percent of a tape or laser measurement of the whole flat.
- **Log**: combined plan generation.
- **Sev**: S2

#### PLAN-06 Plan reflects furniture removal
- **Env**: ENV-LR
- **Pre**: FURN-01.
- **Steps**:
  1. With furniture hidden, check walls behind furniture on the plan.
- **Expected**: Wall drawn but marked estimated where not seen.
- **Pass if**: Different line style for estimated walls, with a legend.
- **Log**: none extra.
- **Sev**: S3

### 2.13 Floor plan editing (PEDIT)

For every test here, after editing, open RAW MESH and check it did not change. This is the "manual edits must not overwrite raw scan data" rule.

#### PEDIT-01 Move a wall
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Tap Edit. Tap a wall. Drag it 30 cm outward.
- **Expected**: The wall moves. Connected walls stretch to stay joined. Room area updates.
- **Pass if**: Corners stay closed. Area changes by about the expected amount. Undo restores it.
- **Log**: wall edit.
- **Sev**: S2

#### PEDIT-02 Adjust wall length by typing
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Tap a wall length label. Type a new value (for example the tape value).
- **Expected**: The wall changes to that length.
- **Pass if**: New label matches the typed value. Accepts both metric and feet/inches input.
- **Log**: wall length edit.
- **Sev**: S3

#### PEDIT-03 Wall thickness
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Tap a wall. Change thickness to 15 cm.
- **Expected**: The wall draws thicker.
- **Pass if**: Thickness changes and the room inside keeps its size (or the app says which side moves).
- **Log**: thickness edit.
- **Sev**: S3

#### PEDIT-04 Add and delete a wall
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Add a wall across the room to split it.
  2. Delete the wall you added.
- **Expected**: Add works with snapping to existing walls. Delete removes it.
- **Pass if**: Both work. Undo works.
- **Log**: add and delete events.
- **Sev**: S3

#### PEDIT-05 Doors: add, move, resize
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Add a door on a wall.
  2. Drag it along the wall.
  3. Resize it to 90 cm wide.
  4. Change swing direction if possible.
- **Expected**: The door stays on the wall while moving. Size updates.
- **Pass if**: Door cannot be dragged off the wall into empty space. Width label shows 90 cm.
- **Log**: door edits.
- **Sev**: S3

#### PEDIT-06 Windows and openings
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Add a window, move it, resize it.
  2. Add an opening.
- **Expected**: Same behavior as doors.
- **Pass if**: All work and show in 3D CLEAN too.
- **Log**: window and opening edits.
- **Sev**: S3

#### PEDIT-07 Rooms: rename, merge, split
- **Env**: ENV-HOUSE plan
- **Pre**: At least two rooms.
- **Steps**:
  1. Rename a room to "Dining".
  2. Merge two neighboring rooms.
  3. Split the merged room back with a line.
- **Expected**: Names and areas update.
- **Pass if**: Merged area equals the sum of the two (within 1 percent). Split areas add up to the merged area.
- **Log**: room edits.
- **Sev**: S3

#### PEDIT-08 Annotations
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Add a measurement. Delete it.
  2. Add a text annotation "Tandoor here".
  3. Add a symbol (for example an electrical outlet).
  4. Add a note.
- **Expected**: All can be added, moved and deleted.
- **Pass if**: All kept after close and reopen. They appear in the PDF or image export.
- **Log**: annotation edits.
- **Sev**: S3

#### PEDIT-09 Undo, redo and raw safety
- **Env**: any plan
- **Pre**: Several edits done.
- **Steps**:
  1. Tap Undo five times. Tap Redo five times.
  2. Find "Reset to scanned plan" (or similar).
  3. Open RAW MESH.
- **Expected**: Undo and redo step through edits. Reset returns to the original generated plan. Raw mesh is unchanged.
- **Pass if**: All three. Raw mesh has no edits.
- **Log**: undo and redo, reset.
- **Sev**: S1 if raw data changed, S2 otherwise.

### 2.14 3D editing (EDIT3D)

#### EDIT3D-01 Tap an object
- **Env**: ENV-LR
- **Pre**: A finished scan with a table.
- **Steps**:
  1. In 3D CLEAN, tap the table.
- **Expected**: A menu: Hide, Delete from clean model, Move, Rotate, Measure, Rename, Change category, Show raw geometry.
- **Pass if**: All eight options appear. The table is highlighted.
- **Log**: object selected.
- **Sev**: S3

#### EDIT3D-02 Move and rotate
- **Env**: ENV-LR
- **Pre**: EDIT3D-01.
- **Steps**:
  1. Choose Move. Drag the table 1 m.
  2. Choose Rotate. Turn it 45 degrees.
  3. Close and reopen.
- **Expected**: Table moves and rotates on the floor, not into the air or through walls.
- **Pass if**: Changes kept after reopen. Table stays on the floor.
- **Log**: move and rotate edits.
- **Sev**: S3

#### EDIT3D-03 Hide vs delete
- **Env**: ENV-LR
- **Pre**: Two objects.
- **Steps**:
  1. Hide one object. Delete the other from the clean model.
  2. Find a way to show hidden objects. Find a way to restore the deleted one.
- **Expected**: Hidden objects can be shown again easily. Deleted ones can be restored through undo or reset.
- **Pass if**: Both reversible. RAW MESH still contains both.
- **Log**: hide and delete events.
- **Sev**: S2

#### EDIT3D-04 Show raw geometry
- **Env**: ENV-LR
- **Pre**: EDIT3D-01.
- **Steps**:
  1. Choose Show raw geometry for the table.
- **Expected**: The original mesh of the table appears over or in place of the simple box.
- **Pass if**: The raw mesh lines up with the box.
- **Log**: none extra.
- **Sev**: S4

#### EDIT3D-05 Wall options
- **Env**: ENV-LR
- **Pre**: None.
- **Steps**:
  1. Tap a wall in 3D CLEAN.
- **Expected**: Measure, Adjust, Add opening, Add door, Add window, Hide, Inspect geometry.
- **Pass if**: All seven options exist. Adding a door in 3D shows it on the floor plan too.
- **Log**: wall edits.
- **Sev**: S3

#### EDIT3D-06 Touch gestures
- **Env**: any 3D view
- **Pre**: None.
- **Steps**:
  1. Pinch to zoom, one finger to orbit, two fingers to pan. Double tap to reset view.
- **Expected**: Smooth control.
- **Pass if**: No jumps, the model never gets lost off screen with no way back.
- **Log**: none.
- **Sev**: S3

### 2.15 Project system (PROJ)

#### PROJ-01 Project list
- **Env**: any
- **Pre**: At least three projects.
- **Steps**:
  1. Open the Projects screen.
- **Expected**: A list with name, date, type (room, building, object) and a thumbnail.
- **Pass if**: All projects listed. Newest first or sortable.
- **Log**: project list load time.
- **Sev**: S2

#### PROJ-02 Rename
- **Env**: any
- **Pre**: A project.
- **Steps**:
  1. Rename a project to "Bombay Bar & Grill".
- **Expected**: Name changes, including the "&" character.
- **Pass if**: Name kept after restart. Special characters and spaces work.
- **Log**: rename.
- **Sev**: S3

#### PROJ-03 Duplicate
- **Env**: any
- **Pre**: A project with edits.
- **Steps**:
  1. Duplicate the project.
  2. Make an edit in the copy.
  3. Open the original.
- **Expected**: The copy is independent.
- **Pass if**: Original unchanged. Copy has the edit.
- **Log**: duplicate with size copied.
- **Sev**: S2

#### PROJ-04 Archive
- **Env**: any
- **Pre**: A project.
- **Steps**:
  1. Archive a project.
  2. Find the archived projects view and unarchive it.
- **Expected**: Archived projects leave the main list but are not deleted.
- **Pass if**: Project comes back complete after unarchive.
- **Log**: archive and unarchive.
- **Sev**: S3

#### PROJ-05 Delete
- **Env**: any
- **Pre**: A test project you do not need.
- **Steps**:
  1. Delete the project.
  2. Check iPhone Storage in iOS Settings > General > iPhone Storage > Mapper before and after.
- **Expected**: A confirmation asks first. After delete, the storage goes down.
- **Pass if**: Confirmation shown. Project gone. App storage size drops by about the project size.
- **Log**: delete with bytes freed.
- **Sev**: S2 (S1 if a different project is deleted)

#### PROJ-06 Backup and restore
- **Env**: any
- **Pre**: A room project with edits and a measurement.
- **Steps**:
  1. Choose Backup on the project. Save the file to Files > On My iPhone.
  2. Delete the project from the app.
  3. Choose Restore (or open the backup file with Mapper).
- **Expected**: The project comes back fully.
- **Pass if**: All views, edits, measurements and raw mesh are back. The backup is a single file you can copy to a PC.
- **Log**: backup size, restore success.
- **Sev**: S1 if restore fails or loses data.

#### PROJ-07 Raw data is kept
- **Env**: any
- **Pre**: A project with many edits.
- **Steps**:
  1. Open RAW MESH. Compare with a screenshot taken right after scanning.
- **Expected**: Identical.
- **Pass if**: No visible difference.
- **Log**: raw data file checksums, if logged.
- **Sev**: S1

#### PROJ-08 Many projects
- **Env**: any
- **Pre**: 20 or more projects (duplicate a few).
- **Steps**:
  1. Scroll the list. Open and close five projects.
- **Expected**: Smooth list, fast opening.
- **Pass if**: List opens in under 2 seconds. A room project opens in under 5 seconds.
- **Log**: load times.
- **Sev**: S3

#### PROJ-09 Project storage visible in Files
- **Env**: any
- **Pre**: None.
- **Steps**:
  1. Open the Files app > On My iPhone > Mapper.
- **Expected**: A projects folder and the Logs folder.
- **Pass if**: You can see project data. Nothing is hidden in a way that makes backup impossible.
- **Log**: none.
- **Sev**: S4

### 2.16 Local-first and offline (OFF)

#### OFF-01 Full workflow in Airplane Mode
- **Env**: ENV-LR
- **Pre**: Turn on Airplane Mode. Turn Wi-Fi and Bluetooth off too.
- **Steps**:
  1. Open Mapper.
  2. Scan a room. Finish. Open all views. Edit the plan. Measure. Export a PDF and a USDZ to Files.
- **Expected**: Everything works exactly as online.
- **Pass if**: No step fails or shows a network error. No sign-in prompt.
- **Log**: no network errors, no attempts to reach a server.
- **Sev**: S1

#### OFF-02 No account
- **Env**: any
- **Pre**: Fresh install.
- **Steps**:
  1. Open the app for the first time. Go through any onboarding.
- **Expected**: No account, email, sign-in or subscription screen.
- **Pass if**: You reach NEW SCAN with no account step and no payment screen.
- **Log**: none.
- **Sev**: S1

#### OFF-03 No outgoing traffic
- **Env**: any
- **Pre**: Settings > Privacy & Security > App Privacy Report turned on for a day.
- **Steps**:
  1. Use the app normally for a day, with Wi-Fi on.
  2. Open App Privacy Report > Mapper.
- **Expected**: No network domains contacted, except the local debug server if you turned it on.
- **Pass if**: No outside domains listed.
- **Log**: debug server lines only if enabled.
- **Sev**: S1

#### OFF-04 Debug server off by default
- **Env**: any
- **Pre**: Fresh install.
- **Steps**:
  1. Check Settings in the app for the Wi-Fi log viewer.
- **Expected**: Off unless turned on. Needs a token when on.
- **Pass if**: Off by default. When on, opening the log page without the token is refused.
- **Log**: `wireless debug listening on port 8765` only after turning it on.
- **Sev**: S2

### 2.17 Exports (EXP)

The spec asks for "exportable professional files" but does not list formats. These tests use the common set. Mark formats the app does not offer as N/A and list them in your notes.

For every export: save to Files > On My iPhone, copy to the PC over USB or AirDrop, open it in the named program.

#### EXP-01 USDZ
- **Env**: room and object projects
- **Pre**: None.
- **Steps**:
  1. Export as USDZ.
  2. Open it in the iOS Files app (Quick Look) and tap AR.
- **Expected**: Textured model opens and can be placed in AR.
- **Pass if**: Opens. Textures present. Real size in AR (a 1 m table looks 1 m).
- **Log**: export format, file size, duration.
- **Sev**: S2

#### EXP-02 OBJ with textures
- **Env**: room and object projects
- **Pre**: None.
- **Steps**:
  1. Export as OBJ. Check you get .obj, .mtl and texture images (often zipped).
  2. Open in Blender or Windows 3D Viewer.
- **Expected**: Model opens with textures, correct size and upright.
- **Pass if**: Opens, textured, units in meters, Y or Z up as documented.
- **Log**: export lines.
- **Sev**: S2

#### EXP-03 PLY or point cloud
- **Env**: room project
- **Pre**: None.
- **Steps**:
  1. Export raw mesh or point cloud (PLY, E57 or LAS if offered).
  2. Open in CloudCompare (free).
- **Expected**: Raw geometry opens.
- **Pass if**: Opens. Distances measured in CloudCompare match the app within 1 cm.
- **Log**: export lines.
- **Sev**: S3

#### EXP-04 glTF or GLB
- **Env**: object project
- **Pre**: None.
- **Steps**:
  1. Export GLB. Drag into a web viewer offline copy or Blender.
- **Expected**: Opens with textures.
- **Pass if**: Opens, textured, correct size.
- **Log**: export lines.
- **Sev**: S3

#### EXP-05 Floor plan PDF
- **Env**: room and building projects
- **Pre**: Plan with dimensions and a text annotation.
- **Steps**:
  1. Export the floor plan as PDF. Print it at 100 percent (no "fit to page").
  2. Measure a wall on paper with a ruler and use the printed scale.
- **Expected**: A clean plan with title, scale, north or orientation arrow (optional), dimensions, room names, annotations.
- **Pass if**: Opens on PC. Scale on paper is correct within 2 percent. All visible toggled layers are included.
- **Log**: export lines.
- **Sev**: S2

#### EXP-06 Floor plan image
- **Env**: any plan
- **Pre**: None.
- **Steps**:
  1. Export PNG or JPG.
- **Expected**: Sharp image.
- **Pass if**: Text readable when zoomed to 100 percent.
- **Log**: export lines.
- **Sev**: S3

#### EXP-07 DXF for CAD
- **Env**: room project
- **Pre**: None.
- **Steps**:
  1. Export DXF. Open in a free CAD viewer (for example LibreCAD or an online-free desktop viewer).
- **Expected**: Walls, doors and windows as lines on separate layers, in real units.
- **Pass if**: Opens. A wall measured in the CAD viewer matches the app within 1 cm. Layers named sensibly.
- **Log**: export lines.
- **Sev**: S3

#### EXP-08 Measurements as CSV or report
- **Env**: room project
- **Pre**: Several measurements.
- **Steps**:
  1. Export measurements (CSV or report PDF).
  2. Open in Excel or Google Sheets offline copy.
- **Expected**: Each measurement with name, value in both units and confidence.
- **Pass if**: Opens, one row per measurement, numbers are numbers not text.
- **Log**: export lines.
- **Sev**: S3

#### EXP-09 Export offline and large
- **Env**: ENV-HOUSE project
- **Pre**: Airplane Mode on.
- **Steps**:
  1. Export the whole building as USDZ and PDF.
  2. Time it.
- **Expected**: Works offline. Shows progress for long exports. Can be cancelled.
- **Pass if**: Finishes in under 3 minutes. Progress shown. Cancel works and leaves no half file.
- **Log**: export duration and size, cancel event.
- **Sev**: S2

#### EXP-10 Share sheet
- **Env**: any
- **Pre**: None.
- **Steps**:
  1. Export and choose the share sheet. Try AirDrop to a Mac or PC (or Save to Files).
- **Expected**: Standard iOS share sheet.
- **Pass if**: File arrives with a sensible name (project name plus date plus format extension).
- **Log**: export lines.
- **Sev**: S4

---

## 3. Measurement accuracy protocol

Run this on every build that changes scanning or measurement code, and at least once per week during development. Use ENV-LR for distances and room values, ENV-HALL for the long distances, and ITEM-BOX and ITEM-TABLE for objects.

### 3.1 Set up reference points

1. Put 11 small pieces of painter's tape with a pen X on walls, floor and furniture. Label them P0 to P10.
2. Measure from P0 to each other point with the tape so that you get these 10 distances. The exact values do not matter; get close to these targets:

| Ref | Target distance | Suggested setup |
|---|---|---|
| D1 | 0.3 m | Two X marks on a table top |
| D2 | 0.5 m | Table top edge to edge |
| D3 | 0.8 m | Across a door frame (door width) |
| D4 | 1.0 m | Two marks on a wall at the same height |
| D5 | 1.5 m | Floor mark to a mark on the wall |
| D6 | 2.0 m | Wall to wall across a narrow space |
| D7 | 2.5 m | Floor to ceiling (ceiling height) |
| D8 | 3.5 m | Along one wall |
| D9 | 4.5 m | Across the living room |
| D10 | 6.0 m | Down the hallway or across the restaurant |

3. Measure each distance three times with the tape. Use the average as the true value. Write it in millimeters.
4. For 3 m and longer, a laser distance meter is more reliable. Keep the tape straight and tight. For D7, hold the tape against the wall, not slanted.

### 3.2 Architectural and object references

Also measure with the tape:

| Ref | What | How |
|---|---|---|
| W1 to W4 | Length of each wall in ENV-LR | Corner to corner at floor level |
| H1 | Ceiling height | Floor to ceiling at room center, and at two corners |
| DR1 | Door width | Inside the frame, at middle height |
| DR2 | Door height | Floor to the top of the opening |
| O1 | Box width, height, depth | Outer size of ITEM-BOX |
| O2 | Table width, height, depth | Top size and floor to top |

### 3.3 Scan and measure in the app

1. Start a ROOM scan in ENV-LR. Scan slowly for 2 minutes with full coverage (quality above 90 percent for walls and floor).
2. Finish. In the 3D view, measure each D distance by tapping the X marks (textures make them visible).
3. Record wall lengths, ceiling height and door size from the app.
4. Scan ITEM-BOX and ITEM-TABLE in OBJECT mode. Record width, height and depth.
5. Also record the accuracy the app shows next to each value.
6. Repeat the whole thing once more (a second independent scan). This tells you repeatability.

### 3.4 Table template

Copy this table for each run. Values in millimeters.

Build: ______  Date: ______  Room: ______  Light: ______  Scan duration: ______

| Ref | Tape (mm) | App run 1 (mm) | App run 2 (mm) | Error 1 (mm) | Error 2 (mm) | Abs error 1 | Abs error 2 | % error 1 | App shown accuracy (± mm) | Inside shown range? |
|---|---|---|---|---|---|---|---|---|---|---|
| D1 0.3 m | | | | | | | | | | |
| D2 0.5 m | | | | | | | | | | |
| D3 0.8 m | | | | | | | | | | |
| D4 1.0 m | | | | | | | | | | |
| D5 1.5 m | | | | | | | | | | |
| D6 2.0 m | | | | | | | | | | |
| D7 2.5 m | | | | | | | | | | |
| D8 3.5 m | | | | | | | | | | |
| D9 4.5 m | | | | | | | | | | |
| D10 6.0 m | | | | | | | | | | |
| W1 | | | | | | | | | | |
| W2 | | | | | | | | | | |
| W3 | | | | | | | | | | |
| W4 | | | | | | | | | | |
| H1 ceiling | | | | | | | | | | |
| DR1 door width | | | | | | | | | | |
| DR2 door height | | | | | | | | | | |
| O1 box W | | | | | | | | | | |
| O1 box H | | | | | | | | | | |
| O1 box D | | | | | | | | | | |
| O2 table W | | | | | | | | | | |
| O2 table H | | | | | | | | | | |
| O2 table D | | | | | | | | | | |

Summary for the 10 D distances:

| Metric | Run 1 | Run 2 |
|---|---|---|
| Mean absolute error (mm) | | |
| Max absolute error (mm) | | |
| Mean percent error | | |
| Count inside shown range (out of 10) | | |
| Difference between run 1 and run 2, largest (mm) | | |

### 3.5 How to compute

For each reference:

- **Error** = App value minus Tape value. It can be negative.
- **Absolute error** = Error without the minus sign.
- **Percent error** = Absolute error divided by Tape value, times 100.

For the 10 D distances:

- **Mean absolute error (MAE)** = add the 10 absolute errors, divide by 10.
- **Max error** = the largest absolute error.
- **Mean percent error** = add the 10 percent errors, divide by 10.

Worked example: tape 3500 mm, app 3522 mm. Error = +22 mm. Absolute error = 22 mm. Percent error = 22 / 3500 x 100 = 0.63 percent.

Also look at the sign of the errors. If almost all errors are positive (or all negative), the app has a scale bias. Report that as a separate finding; it is often fixable.

A spreadsheet makes this easy: put Tape in column B and App in column C. Error `=C2-B2`. Absolute error `=ABS(C2-B2)`. Percent `=ABS(C2-B2)/B2*100`. MAE `=AVERAGE(E2:E11)`. Max `=MAX(E2:E11)`.

### 3.6 What published studies say

| Source | Device | Finding |
|---|---|---|
| Luetzenburg, Kroon and Bjørk (2021), Scientific Reports 11, 22221. https://www.nature.com/articles/s41598-021-01763-9 | iPhone 12 Pro LiDAR | Small objects with a side longer than 10 cm modelled with an absolute accuracy of about ±1 cm. Larger scenes need care because error grows with scan size. |
| Spreafico, Chiabrando, Teppati Losè and Giulio Tonolo (2021), ISPRS Archives XLIII-B1-2021, 63-69. https://isprs-archives.copernicus.org/articles/XLIII-B1-2021/63/2021/ | iPad Pro LiDAR | Point clouds judged suitable for 1:200 scale architectural rapid mapping. Errors of a few centimeters, larger in bigger scenes. |
| "Evaluating the accuracy and quality of an iPad Pro's built-in lidar for 3D indoor mapping" (2023), Developments in the Built Environment. https://www.sciencedirect.com/science/article/pii/S2666165923000510 | iPad Pro LiDAR | Walking (dynamic) scans: 1 to 2 cm for lengths of 1 to 3 m. For features longer than 4 m the error could exceed 25 cm. Static, overlapping scans: 1 to 2 cm even beyond 4 m. |

Key lesson: short distances are good (about 1 to 2 cm). Error grows with distance and with how much you walk, because tracking drifts. Apple's ARKit depth has a range of about 5 m. So thresholds must grow with distance.

### 3.7 Recommended acceptance thresholds

These are for a consumer app on the iPhone 13 Pro Max, in good light, with a full-coverage scan. They are stricter than the worst published cases and looser than the best, which is fair for an app that tells the user how confident it is.

| What | Target (pass) | Hard fail |
|---|---|---|
| Point to point, 0.3 to 1 m | Abs error 15 mm or less | Over 30 mm |
| Point to point, 1 to 3 m | 25 mm or less | Over 50 mm |
| Point to point, 3 to 6 m | 50 mm or less, or 1.5 percent, whichever is larger | Over 100 mm |
| MAE over the 10 D distances | 20 mm or less | Over 40 mm |
| Max error over the 10 D distances | 50 mm or less | Over 100 mm |
| Wall length | 2 percent or 50 mm, whichever is larger | Over 4 percent |
| Ceiling height | 30 mm or less | Over 60 mm |
| Door width | 20 mm or less | Over 40 mm |
| Door height | 30 mm or less | Over 60 mm |
| Object W, H, D (object mode, over 10 cm) | 15 mm or 3 percent, whichever is larger | Over 30 mm or 6 percent |
| Object W, H, D (from a room scan) | 30 mm or less | Over 60 mm |
| Floor area | 4 percent or less | Over 8 percent |
| Repeatability, run 1 vs run 2 | 20 mm or less for any D | Over 50 mm |
| Confidence honesty | At least 8 of 10 D inside the shown ± range | Fewer than 6 of 10 |

If the target is missed but the hard fail is not reached, log it as S3. A hard fail is S2. If wrong values are shown with high confidence, it is S2 even if the error itself is within the target, because the user is misled.

### 3.8 Confidence wording the app should use

Keep it short and honest. Suggested wording:

| Situation | Wording on screen |
|---|---|
| Good data, short distance | `3.845 m  (12' 7 3/8")   ±1 cm` |
| Good data, long distance | `6.02 m  (19' 9")   ±4 cm` |
| Fair data | `4.51 m  (14' 9 1/2")   ±6 cm  Fair` |
| Poor data | `Low confidence. Rescan this section.` (value shown grey, with ±) |
| Hidden or occluded | `Estimated (not directly scanned)` |
| Typed by the user | `Entered manually` |

Rules:

- Always say "Estimated accuracy" or show "±". Never show a value with more decimal places than the accuracy supports (for ±1 cm, show millimeters at most; for ±5 cm, show centimeters).
- Never use "exact", "precise", "survey-grade", "certified" or "guaranteed".
- In the About or Help screen say, in one sentence: "Mapper measurements are estimates from the iPhone sensors. For building permits or legal documents, check critical dimensions with a tape measure."

---

## 4. Performance and reliability checks

### 4.1 How to record

For each check, write: build, start time, end time, battery percent at start and end, phone temperature feel (cool, warm, hot), any on-screen warnings, and the result.

To see battery per app later: Settings > Battery, tap the last 24 hours, find Mapper.

To see the thermal state, the app should log it. Look for a thermal category line with the state name (nominal, fair, serious, critical).

### 4.2 Session length

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-01 | 5 minute scan | ENV-LR. Start ROOM scan. Scan continuously for 5 minutes (walk the room several times). Finish. | No crash. Frame rate stays smooth. Processing finishes. Memory warnings in log: 0. | S1 |
| PERF-02 | 15 minute scan | ENV-REST or ENV-HOUSE (one very large room or ADVANCED mode). Scan continuously 15 minutes. Finish. | No crash. Live view may get slower but still responds. App warns before any limit is reached. Scan saves. | S1 |
| PERF-03 | 30 minute session | ENV-HOUSE in HOUSE mode. Scan rooms one after another for 30 minutes total. | No crash. All rooms saved. If the phone gets hot, the app warns and saves rather than losing data. | S1 |
| PERF-04 | Processing time | After PERF-01, PERF-02, PERF-03, note processing time from Finish to result. | 1 room under 2 minutes. 15 minute scan under 5 minutes. Progress bar shown and moving. | S3 |

### 4.3 Thermal behaviour

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-05 | Warm phone warning | During PERF-03, watch for a heat message. Feel the phone at 10, 20, 30 minutes. | If the log shows thermal state serious, the app shows a message (for example "Phone is getting hot. Save and take a break.") and reduces work (lower frame rate or texture rate). | S2 |
| PERF-06 | Critical heat | Only if it happens naturally, do not force it. If thermal state reaches critical. | The app saves the scan automatically and stops scanning gracefully. No data lost. | S1 |
| PERF-07 | Hot environment | Scan the garage on a hot day, or outdoors in the sun, for 10 minutes. | Same as PERF-05. No crash. | S2 |

Do not put the phone in a hot car or under a blanket to force heat. Stop any test if the phone shows the iOS "Temperature: iPhone needs to cool down" screen.

### 4.4 Memory pressure

Symptoms to watch: the live view freezes for more than 1 second, the app suddenly closes without a crash message (iOS killed it for memory), mesh parts disappear, textures turn gray, or the log shows memory warning lines.

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-08 | Big room memory | PERF-02 scan. After it, check the log for memory warnings. | Zero or few warnings. If warnings appear, the app reduces quality instead of being killed. | S1 if killed |
| PERF-09 | Other apps open | Open Camera, Safari with 10 tabs, Photos and a game. Then open Mapper and scan for 5 minutes. | No crash. Scan saves. | S2 |
| PERF-10 | Open a big project | Open the PERF-03 building project. Switch between all views. | Opens in under 10 seconds. No crash. | S2 |
| PERF-11 | Jetsam check | After any sudden close, on the phone open Settings > Privacy & Security > Analytics & Improvements > Analytics Data. Look for a file starting with `JetsamEvent` at that time. | If found, note it in the bug report. A JetsamEvent during a scan is an S1. | S1 |

### 4.5 Battery drain

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-12 | Drain per 10 minutes of scanning | Charge to 100 percent, unplug, wait 5 minutes. Note battery percent. Scan for exactly 10 minutes. Note battery percent. | 10 percent or less per 10 minutes is acceptable. 15 percent or more is a finding (S3). | S3 |
| PERF-13 | Drain while viewing | Same, but 10 minutes of viewing and editing a finished project. | 4 percent or less per 10 minutes. | S3 |
| PERF-14 | Idle drain | Leave the app open on the Projects list for 10 minutes, screen on. | 2 percent or less. AR camera must not be running (camera indicator dot off). | S3 |
| PERF-15 | Low battery | Start a scan at 10 percent battery. Continue into Low Power Mode. | App warns about low battery. Saves before the phone dies. Scan still opens after charging. | S2 |

### 4.6 Interruptions

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-16 | Background mid-scan | Scan 60 seconds. Swipe up to go home. Wait 30 seconds. Return to Mapper. | The app pauses. On return, it offers to resume or save. Resume relocalizes to the same room (point at what you scanned). No crash, no data loss. Log shows `app background` and `app active`. | S1 if data lost, S2 otherwise |
| PERF-17 | Long background | Same as PERF-16 but wait 10 minutes and open other heavy apps (Camera, a game) meanwhile. | Partial scan still available (auto-saved), even if iOS closed the app. | S1 |
| PERF-18 | Phone call | Scan 60 seconds. Have someone call you. Answer, talk 30 seconds, hang up. Return. | Same as PERF-16. The call audio works during the call. | S1 if data lost |
| PERF-19 | Notification and Control Center | During a scan, pull down Control Center and dismiss it. Pull down Notification Center and dismiss it. | Scan continues or resumes cleanly. | S3 |
| PERF-20 | Screen lock | During a scan, press the side button to lock. Unlock after 20 seconds. | Same as PERF-16. | S2 |
| PERF-21 | Auto-lock during processing | Set Auto-Lock to 30 seconds. Finish a long scan and put the phone down while it processes. | Processing either keeps the screen awake or continues and finishes after unlock. | S2 |

### 4.7 Storage

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-22 | Project size | After each scan type, check the project size in the app or in iPhone Storage. | Room with textures: note size (expect tens to hundreds of MB). App shows size per project. | S4 |
| PERF-23 | Low storage | Fill the phone until less than 1 GB is free (record a long 4K video, delete it after). Start a scan. | App warns before scanning ("Not enough space"). If space runs out during a scan, it stops and saves what it has. No corrupt project. | S1 if corrupt |
| PERF-24 | Storage freed after delete | See PROJ-05. | Space freed. No hidden leftover files growing over time. | S3 |

### 4.8 Offline

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-25 | Airplane Mode | See OFF-01. Also do a full house mode session in Airplane Mode. | Everything works. | S1 |

### 4.9 Crash recovery

| ID | Test | Steps | Pass if | Sev |
|---|---|---|---|---|
| PERF-26 | Force quit during scan | Scan 90 seconds. Open the app switcher and swipe Mapper away. Reopen. | The app offers to recover the scan. The recovered project opens with the raw mesh up to at least the last 30 seconds before the quit. | S1 |
| PERF-27 | Force quit during processing | Finish a scan. While processing, swipe Mapper away. Reopen. | Raw scan is kept. Processing can be restarted from the project. | S1 |
| PERF-28 | Force quit during edit | Make 5 plan edits. Swipe away. Reopen. | Edits saved up to the last one or the last few seconds. Raw data intact. | S2 |
| PERF-29 | Real crash | If any crash happens during testing: reopen the app. | Same as PERF-26. Also the log has the lines before the crash. Collect the crash report: Settings > Privacy & Security > Analytics & Improvements > Analytics Data, file starting with `Mapper`. | S1 |
| PERF-30 | Restart phone | Save a project. Restart the phone. Open Mapper. | All projects present and open. | S1 |
| PERF-31 | Signature expiry | After the 7-day free signature expires, re-sideload the same app version (not delete). | Projects still there after reinstall. Note: deleting the app deletes its data; the free-ID reinstall must be an in-place update. | S1 |

---

## 5. Regression smoke list

Run these 12 checks on every new build. Total time: under 10 minutes. Use the living room. Any FAIL means stop and report before doing longer tests.

| # | Check | How (short) | Pass if | Time |
|---|---|---|---|---|
| 1 | Install and launch | Install the IPA. Tap the icon. | Home screen in under 3 seconds. Log shows `app launched` and the right build number. | 0:30 |
| 2 | Old projects still open | Open the Projects list. Open one old room project. | Opens. All views load. | 0:45 |
| 3 | New room scan | NEW SCAN > ROOM. Scan the room for 60 seconds, including floor and ceiling. | Live mesh appears. Guidance messages show. No crash. | 1:30 |
| 4 | Quality screen | Tap Finish. | Scan quality numbers shown. FINISH ANYWAY and SHOW MISSING AREAS buttons present. | 0:15 |
| 5 | Result views | Finish anyway. Switch REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH. | All four load. Textures visible in REALISTIC. | 1:00 |
| 6 | Quick measure accuracy | Measure the D4 (1.0 m) reference. | Within 15 mm of the tape. | 0:45 |
| 7 | Wall length | Tap one wall (W1). | Within 2 percent or 50 mm of tape. Confidence shown. | 0:30 |
| 8 | Plan edit and raw safety | Move one wall on the plan. Undo. Open RAW MESH. | Move and undo work. Raw mesh unchanged. | 0:45 |
| 9 | Object scan | NEW SCAN > OBJECT on the box. One lap, 30 seconds. | Object produced. Width within 3 percent. | 1:30 |
| 10 | Background resume | Start a scan. Go home for 10 seconds. Return. | Resume or save offered. No crash. | 0:40 |
| 11 | Export | Export the room as USDZ and the plan as PDF to Files. Open both in Files. | Both open. | 1:00 |
| 12 | Log health | Pull the log (`python tools/phone_log.py usb`). Search for error, failed, exception, memory warning. | No unexplained errors. Session start blocks present for each scan. | 0:45 |

Total: about 9 minutes 45 seconds.

For Build 1 (capability probe only), the smoke list is: launch (1), probe screen shows ARKit mesh, scene depth, RoomPlan, Object Capture and photogrammetry as supported (the iPhone 13 Pro Max supports all of these), log has a `capabilities:` line (12), and background and return does not crash (10).

---

## 6. Bug report template

Copy this for every bug. One bug per report. File it as a GitHub issue in the lidar-mapper repo, or in a text file in `docs/bugs/` if you prefer.

```
Title: [AREA] Short description of what went wrong
  (example: [ROOM] Crash when tapping Finish after a 10 minute scan)

Test ID: ROOM-01 (or "found while exploring")
Severity: S1 / S2 / S3 / S4
Build: version (build number), date installed
Phone: iPhone 13 Pro Max, iOS 18.3.2
Date and time it happened: 2026-10-05 14:32 (local time)
Environment: ENV-LR, lights on, 1 mirror, etc.
How often: every time / 3 of 5 tries / once

Steps to reproduce:
1.
2.
3.

What I expected:

What actually happened:

Measurements (if relevant):
  Tape value:
  App value:
  App shown accuracy:

Evidence:
  - Screenshot or screen recording (Control Center > Screen Recording)
  - Log: mapper-YYYY-MM-DD.log, lines from HH:MM to HH:MM
    (paste the last 30 lines before the problem here)
  - Crash report file name if any (Analytics Data > Mapper-...)
  - JetsamEvent file name if any
  - Project backup file if the project is damaged (do not delete it)

Data loss? yes / no. If yes, what was lost:
Workaround found? yes / no. Describe:
Battery at start / end:
Phone felt: cool / warm / hot
Notes:
```

Tips:

- Keep the broken project. Do not delete it. Make a backup (PROJ-06) and attach it if possible.
- For crashes, try once more to see if it happens every time. Do not spend more than 3 tries.
- If the bug is in a measurement, include the tape value, how you measured, and a photo of the tape at the mark.
- Screen recordings are the best evidence for guidance and tracking bugs.

---

## 7. Test case index

| Section | IDs | Count |
|---|---|---|
| Scanning modes | MODE-01 to MODE-07 | 7 |
| Room scanning | ROOM-01 to ROOM-12 | 12 |
| House / building | HOUSE-01 to HOUSE-09 | 9 |
| Object scanning | OBJ-01 to OBJ-09 | 9 |
| Image / texture | TEX-01 to TEX-06 | 6 |
| Live scanning | LIVE-01 to LIVE-10 | 10 |
| Scan quality | QUAL-01 to QUAL-05 | 5 |
| Object recognition | REC-01 to REC-05 | 5 |
| Furniture removal | FURN-01 to FURN-04 | 4 |
| Measurement system | MEAS-01 to MEAS-11 | 11 |
| Measurement confidence | CONF-01 to CONF-04 | 4 |
| 2D floor plan | PLAN-01 to PLAN-06 | 6 |
| Floor plan editing | PEDIT-01 to PEDIT-09 | 9 |
| 3D editing | EDIT3D-01 to EDIT3D-06 | 6 |
| Project system | PROJ-01 to PROJ-09 | 9 |
| Local-first / offline | OFF-01 to OFF-04 | 4 |
| Exports | EXP-01 to EXP-10 | 10 |
| Performance and reliability | PERF-01 to PERF-31 | 31 |
| **Total** | | **157** |

Plus the measurement accuracy protocol (section 3) and the 12-check smoke list (section 5).

## 8. Open questions from the spec

These points are unclear in `docs/SPEC.txt` and affect how some tests are judged. Until they are decided, testers should note what the app does and not mark it as a failure.

1. The spec ends after the local-first section. It never lists export formats. EXP tests assume USDZ, OBJ, PLY, GLB, PDF, PNG, DXF and CSV.
2. QUICK MEASURE and ADVANCED SCAN are named but never described.
3. No accuracy targets are given. Section 3.7 proposes them.
4. "Support multiple floors when technically possible" has no minimum. HOUSE-08 accepts a clear message as a pass.
5. Outdoor structures, warehouses and vehicles are listed as scan targets, but LiDAR range is about 5 m and sunlight hurts depth. There is no expected result for these.
6. "Backup" and "restore" do not say where to (Files, a PC, iCloud Drive). iCloud Drive might conflict with "no cloud service".
7. "Archive" is not defined (hide from list, compress, or move off the phone).
8. Missing areas and the percentages on the quality screen have no definition, and it is not said whether a low score should ever block Finish.
9. "Camera frames where permitted" does not set a storage budget. Raw frames for a house can be many gigabytes.
10. Room mode lists four views (REALISTIC, 3D CLEAN, FLOOR PLAN, RAW MESH) and the texture section lists five display modes (PHOTO REALISTIC, TEXTURED, SOLID COLOR, WIREFRAME, RAW MESH). It is not said how the two sets relate.
