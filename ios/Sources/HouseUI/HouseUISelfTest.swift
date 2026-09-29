import Foundation

/// HouseUI self-test (docs/MODULES.md 3.41): the phase reducer (new house, relocalization,
/// discard, cancel, failures), the manifest rules, room statuses and rows, progress, the memory
/// and missing-areas rules, preflight errors, name suggestions, alerts, the relocalization decision
/// and map choice, the demo house and the manual alignment edit. Plain Swift, deterministic, no
/// ARKit, RoomPlan, camera or network; files only under `FileManager.default.temporaryDirectory`,
/// removed afterwards. The file-based checks are in HouseUISelfTest+Files.swift.
enum HouseUISelfTest {
    /// Collects failures and counts checks.
    struct Checker {
        /// Failure lines so far.
        private(set) var failures: [String] = []
        /// Number of checks run.
        private(set) var count = 0

        /// Records a failure when `condition` is false.
        mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            count += 1
            guard !condition else { return }
            let text = detail()
            failures.append(text.isEmpty ? name : "\(name): \(text)")
        }
    }

    /// Runs every check; returns one "name: detail" line per failure, empty when all pass.
    static func run() -> [String] {
        var c = Checker()
        reducerChecks(&c)
        manifestRuleChecks(&c)
        statusChecks(&c)
        rowChecks(&c)
        presentationChecks(&c)
        relocalizationChecks(&c)
        alignChecks(&c)
        sourceMapChecks(&c)
        demoChecks(&c)
        return c.failures
    }

    // MARK: - Fixtures

    /// A fixed identifier from a small number.
    static func uuid(_ n: Int) -> UUID {
        let hi = UInt8(truncatingIfNeeded: n >> 8)
        let lo = UInt8(truncatingIfNeeded: n)
        return UUID(uuid: (0x48, 0x4F, 0x55, 0x53, 0x45, 0x55, 0x49, 0x54, 0x80, 0, 0, 0, 0, 0, hi, lo))
    }

    /// A fixed date `seconds` after 2001.
    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// A room record.
    static func room(_ id: UUID, session: UUID, floor: Int = 0, status: RoomStatus = .captured, name: String = "",
                     link: FrameLink? = nil, capturedAt: Double = 0, supersededBy: UUID? = nil) -> RoomRecord {
        RoomRecord(id: id, name: name, sessionID: session, floorIndex: floor, status: status, capturedRoomID: nil,
                   quality: nil, hasMeshPass: false, keyframeCount: 0, capturedAt: date(capturedAt),
                   frameLink: link ?? .projectFrame(sessionID: session), supersededBy: supersededBy)
    }

    /// A House manifest with fixed identity and dates.
    static func manifest(rooms: [RoomRecord], sessions: [CaptureSessionRef],
                         floors: [FloorRecord] = [FloorRecord(id: 0, name: "", elevation: 0)]) -> ProjectManifest {
        ProjectManifest(schemaVersion: ProjectManifest.currentSchema, id: uuid(900), name: "Test", kind: .house,
                        createdAt: date(0), modifiedAt: date(0), isArchived: false,
                        pipelineVersion: ProjectManifest.currentPipelineVersion, sessions: sessions, rooms: rooms,
                        objects: [], floors: floors, status: .capturing, reconstructionPending: false,
                        settings: ScanSettings.room)
    }

    /// A session reference.
    static func session(_ id: UUID, link: FrameLink? = nil) -> CaptureSessionRef {
        HouseManifestRules.session(id: id, startedAt: date(0), link: link ?? .projectFrame(sessionID: id))
    }

    /// An evaluation whose scores are all `score` and with `missing` missing areas.
    static func evaluation(_ score: Double, missing: Int = 0, room: UUID = uuid(1)) -> QualityEvaluation {
        let summary = QualitySummary(shape: score, walls: score, floor: score, ceiling: score, texture: score,
                                     missingAreas: missing)
        return QualityEvaluation(roomID: room, summary: summary, missingAreas: [], degraded: .allGood,
                                 evidence: RoomEvidence.unknown, darkKeyframeFraction: 0, inputHash: "-",
                                 evaluatedAt: date(0))
    }

    // MARK: - Reducer

    /// `nextPhase` along the new-house path, the relocalizing path, discard, cancel and failures.
    static func reducerChecks(_ c: inout Checker) {
        let p = HouseFlowModel.nextPhase
        let project = uuid(99)
        c.check("reducer.preflightToTips", p(.preflight, .preflightPassed(showTips: true, relocalize: false)) == .tips)
        c.check("reducer.tipsToCapturing", p(.tips, .tipsDone(relocalize: false)) == .capturing)
        c.check("reducer.doneToStopping", p(.capturing, .doneTapped) == .stopping)
        c.check("reducer.stoppingToChecking", p(.stopping, .roomFinished) == .checking)
        c.check("reducer.checkingToQuality", p(.checking, .evaluated) == .quality)
        c.check("reducer.qualityToNaming", p(.quality, .finishTapped) == .naming)
        c.check("reducer.namingToRoomList", p(.naming, .named) == .roomList)
        c.check("reducer.nextRoomSameSession", p(.roomList, .nextRoom(relocalize: false)) == .capturing)
        c.check("reducer.finishBuilding", p(.roomList, .finishBuilding) == .finishing)
        c.check("reducer.finished", p(.finishing, .finished(project)) == .done(project))
        c.check("reducer.preflightToRelocalizing", p(.preflight, .preflightPassed(showTips: false, relocalize: true)) == .relocalizing)
        c.check("reducer.tipsToRelocalizing", p(.tips, .tipsDone(relocalize: true)) == .relocalizing)
        c.check("reducer.permissionToCapturing", p(.permission, .permissionGranted(showTips: false, relocalize: false)) == .capturing)
        c.check("reducer.relocalized", p(.relocalizing, .relocalized) == .capturing)
        c.check("reducer.startedFresh", p(.relocalizing, .startedFresh) == .capturing)
        c.check("reducer.startedFreshAfterLost", p(.quality, .startedFresh) == .capturing)
        c.check("reducer.nextRoomRelocalizes", p(.roomList, .nextRoom(relocalize: true)) == .relocalizing)
        c.check("reducer.discardWithRooms", p(.quality, .roomDiscarded(hasRooms: true)) == .roomList)
        c.check("reducer.discardWithoutRooms", p(.quality, .roomDiscarded(hasRooms: false)) == .cancelled)
        c.check("reducer.cancelWithRooms", p(.capturing, .cancelConfirmed(hasRooms: true)) == .roomList)
        c.check("reducer.cancelWithoutRooms", p(.capturing, .cancelConfirmed(hasRooms: false)) == .cancelled)
        c.check("reducer.engineStopping", p(.capturing, .engineStopping) == .stopping)
        c.check("reducer.failure", p(.capturing, .failed("error.ioFailed")) == .failed("error.ioFailed"))
        c.check("reducer.failureAfterSaveIsAlertOnly", p(.quality, .failed("error.deviceTooHot")) == .quality)
        c.check("reducer.terminalStays", p(.done(project), .nextRoom(relocalize: false)) == .done(project))
        c.check("reducer.relocalizedOnlyWhileRelocalizing", p(.capturing, .relocalized) == .capturing)
    }

    // MARK: - Manifest rules

    /// `status(after:)`, `roomRecord`, `append`, `supersede`, `addFloor`, `setWorldMap`.
    static func manifestRuleChecks(_ c: inout Checker) {
        c.check("rules.poorNeedsRescan", HouseManifestRules.status(after: evaluation(0.3)) == .needsRescan)
        c.check("rules.goodCaptured", HouseManifestRules.status(after: evaluation(0.95)) == .captured)
        c.check("rules.okayCaptured", HouseManifestRules.status(after: evaluation(0.8)) == .captured)

        let s0 = uuid(10), s1 = uuid(11), r = uuid(20)
        let folder = RawScanFolder(url: URL(fileURLWithPath: "/tmp/p.mapperproj/raw/sessions/\(s1.uuidString)/rooms/\(r.uuidString)"))
        let log = RoomCaptureLog(seconds: 30, instructionSeconds: [:], error: nil, relocalizations: 0,
                                 limitedTrackingFraction: 0, degraded: .allGood)
        let result = RoomScanResult(roomID: r, sealedFolder: folder, capturedRoomID: uuid(21), log: log, keyframeCount: 7,
                                    photoCount: 1, frameLink: .projectFrame(sessionID: s1), capturedAt: date(5),
                                    stoppedBySystem: false)
        let link = FrameLink.relocalized(sessionID: s1, from: s0)
        let made = HouseManifestRules.roomRecord(result, sessionLink: link, floorIndex: 2)
        c.check("rules.roomRecordSessionLink", made.frameLink == link, "\(made.frameLink)")
        c.check("rules.roomRecordFields", made.sessionID == s1 && made.status == .captured && made.name.isEmpty
                    && made.floorIndex == 2 && made.keyframeCount == 7 && made.capturedRoomID == uuid(21))
        c.check("rules.sessionFromFolder", HouseManifestRules.sessionID(fromRoomFolder: folder.url) == s1)

        var m = manifest(rooms: [room(uuid(30), session: s0, floor: 1, name: "Hallway")], sessions: [session(s0)])
        HouseManifestRules.append(made, to: &m)
        HouseManifestRules.append(made, to: &m)
        c.check("rules.appendNeedsProcessing", m.status == .needsProcessing && m.rooms.count == 2, "\(m.status) \(m.rooms.count)")

        HouseManifestRules.supersede(uuid(30), by: r, in: &m)
        let old = m.rooms.first { $0.id == uuid(30) }
        let new = m.rooms.first { $0.id == r }
        c.check("rules.supersedeSetsSupersededBy", old?.supersededBy == r && old != nil)
        c.check("rules.supersedeCopiesNameAndFloor", new?.name == "Hallway" && new?.floorIndex == 1,
                "\(String(describing: new?.name)) \(String(describing: new?.floorIndex))")

        m.floors = [FloorRecord(id: 0, name: "", elevation: 0), FloorRecord(id: 2, name: "", elevation: 3)]
        let added = HouseManifestRules.addFloor(to: &m)
        c.check("rules.addFloorMaxPlusOne", added == 3 && m.floors.last?.id == 3 && m.floors.count == 3, "\(added)")

        m.sessions = [session(s1, link: link)]
        HouseManifestRules.setWorldMap(session: s1, room: r, in: &m)
        c.check("rules.setWorldMap", m.sessions.first?.worldMapFile == HouseRelocalization.worldMapPath(room: r))
    }

    // MARK: - Statuses and rows

    /// `status(for:placement:userAligned:)` for done, needs scan, needs lining up, lined up by the
    /// user, and capturing.
    static func statusChecks(_ c: inout Checker) {
        let s = uuid(10)
        let parked = RoomPlacementReport(roomID: uuid(1), method: .parked, matches: 0, rms: nil, stackedWith: nil,
                                         needsManualAlignment: true)
        let status = HousePresentation.status
        c.check("status.done", status(room(uuid(1), session: s), nil, false) == .done)
        c.check("status.needsScan", status(room(uuid(1), session: s, status: .needsRescan), nil, false) == .needsScan)
        c.check("status.failedNeedsScan", status(room(uuid(1), session: s, status: .failed), nil, false) == .needsScan)
        c.check("status.needsLineUp", status(room(uuid(1), session: s), parked, false) == .needsLineUp)
        c.check("status.linedUpByUser", status(room(uuid(1), session: s), parked, true) == .done)
        c.check("status.capturing", status(room(uuid(1), session: s, status: .capturing), nil, false) == .notProcessed)
    }

    /// Rows hide a superseded room, go floor then capture order with `Copy.House.floorLabel`, and
    /// `progressText` counts the done rows.
    static func rowChecks(_ c: inout Checker) {
        let s = uuid(10)
        let a = room(uuid(1), session: s, floor: 1, status: .needsRescan, capturedAt: 1)
        let b = room(uuid(2), session: s, floor: 0, status: .needsRescan, capturedAt: 2, supersededBy: uuid(3))
        let kitchen = room(uuid(3), session: s, floor: 0, name: "Kitchen", capturedAt: 3)
        let d = room(uuid(4), session: s, floor: 0, capturedAt: 4)
        let floors = [FloorRecord(id: 0, name: "", elevation: 0), FloorRecord(id: 1, name: "", elevation: 3)]
        let m = manifest(rooms: [a, b, kitchen, d], sessions: [session(s)], floors: floors)
        let rows = HousePresentation.rows(manifest: m, report: StructureReport.empty, userAligned: [])
        c.check("rows.hideSuperseded", rows.count == 3 && !rows.contains { $0.id == uuid(2) }, "\(rows.map { $0.title })")
        c.check("rows.floorThenCaptureOrder", rows.map { $0.id } == [uuid(3), uuid(4), uuid(1)], "\(rows.map { $0.title })")
        c.check("rows.floorLabel", rows.first?.floorTitle == Copy.House.floorLabel(1) && rows.last?.floorTitle == Copy.House.floorLabel(2))
        c.check("rows.statusText", rows.first?.statusText == Copy.House.roomDone("Kitchen"))
        c.check("rows.defaultTitle", rows.count > 1 && rows[1].title == Copy.FloorPlan.defaultRoomTitle(3), "\(rows.map { $0.title })")
        c.check("rows.needsScanText", rows.last?.statusText == Copy.House.roomNeedsScan(Copy.FloorPlan.defaultRoomTitle(1))
                    && rows.last?.accessibility == Copy.A11y.roomNeedsScan(Copy.FloorPlan.defaultRoomTitle(1)))
        c.check("rows.progressCountsDone", HousePresentation.progressText(rows) == Copy.House.progressSummary(done: 2, total: 3),
                HousePresentation.progressText(rows))
        c.check("rows.floorSections", HousePresentation.floorSections(rows).map { $0.id } == [0, 1])
    }

    // MARK: - Presentation rules

    /// Memory, missing areas, preflight errors, suggestions and alerts.
    static func presentationChecks(_ c: inout Checker) {
        c.check("memory.799MB", HousePresentation.suggestsFinishFloor(availableMemory: 799_000_000))
        c.check("memory.801MB", !HousePresentation.suggestsFinishFloor(availableMemory: 801_000_000))

        let offer = HousePresentation.canOfferMissingAreas
        c.check("missing.demo", !offer(true, .finished, false, 3))
        c.check("missing.systemStop", !offer(false, .finished, true, 3))
        c.check("missing.noAreas", !offer(false, .finished, false, 0))
        c.check("missing.notFinished", !offer(false, .scanning, false, 3) && !offer(false, nil, false, 3))
        c.check("missing.offered", offer(false, .finished, false, 3))

        c.check("preflight.cameraDenied", HousePresentation.preflightError(.cameraDenied) == .cameraDenied)
        c.check("preflight.noLidar", HousePresentation.preflightError(.noLidar) == .unsupportedDevice)
        c.check("preflight.lowStorage", HousePresentation.preflightError(.lowStorage(free: 5)) == .lowStorage(freeBytes: 5))
        c.check("preflight.undetermined", HousePresentation.preflightError(.cameraUndetermined) == nil)

        let names = HousePresentation.suggestedNames(sectionLabel: "kitchen")
        let lowered = names.map { $0.lowercased() }
        c.check("names.sectionFirst", names.first == "Kitchen", "\(names)")
        c.check("names.noDuplicates", Set(lowered).count == lowered.count, "\(names)")
        c.check("names.withoutLabel", HousePresentation.suggestedNames(sectionLabel: nil) == Copy.House.roomSuggestions)

        let scan = ScanErrorCopy.alert(for: MapperError.cameraDenied)
        let house = HouseAlert.from(scan)
        c.check("alert.fromKeepsText", house.id == scan.id && house.title == scan.title && house.body == scan.body)
        c.check("alert.fromMapsActions", house.actions == [.openSettings, .ok], "\(house.actions)")
    }

    // MARK: - Relocalization

    /// `decide` and `worldMapPath`.
    static func relocalizationChecks(_ c: inout Checker) {
        let decide = HouseRelocalization.decide
        c.check("decide.normalHeld", decide(3, .normal, 2) == .relocalized)
        c.check("decide.relocalizingAt29", decide(29, .relocalizing, nil) == .keepWaiting)
        c.check("decide.timeoutAt30", decide(30, .relocalizing, nil) == .timedOut)
        c.check("decide.normalHalfSecond", decide(2.5, .normal, 2) == .keepWaiting)

        let s = uuid(10), r = uuid(20)
        let package = ProjectPackage(root: URL(fileURLWithPath: "/tmp/houseui-selftest.mapperproj", isDirectory: true))
        let resolved = RawScanFolder(url: package.sessionURL(s)).resolve(HouseRelocalization.worldMapPath(room: r))
        let expected = RawScanFolder(url: package.rawRoomURL(session: s, room: r)).worldMapURL
        c.check("worldMapPath.resolvesInSession", resolved?.standardizedFileURL.path == expected.standardizedFileURL.path,
                "\(String(describing: resolved?.path)) vs \(expected.path)")
    }

    // MARK: - Manual alignment

    /// One edit per move: a single room gives `.setRoomAlignment`, a group gives one `.batch`.
    static func alignChecks(_ c: inout Checker) {
        let a = uuid(1), b = uuid(2)
        let delta = RoomAlignmentRecord(roomID: a, yaw: 0, translation: Vec3(x: 1, y: 0, z: 0), source: .user)
        let base = [b: RoomAlignmentRecord(roomID: b, yaw: 0, translation: Vec3(x: 2, y: 0, z: 0), source: .measured)]
        if case .setRoomAlignment(let record)? = AlignRoomsModel.alignmentOperation(delta: delta, group: [a], base: base) {
            c.check("align.single", record.roomID == a && record.source == .user && abs(record.translation.x - 1) < 1e-5)
        } else {
            c.check("align.single", false, "not a setRoomAlignment")
        }
        if case .batch(let operations)? = AlignRoomsModel.alignmentOperation(delta: delta, group: [a, b], base: base) {
            let ids = operations.compactMap { op -> UUID? in
                if case .setRoomAlignment(let record) = op { return record.roomID }
                return nil
            }
            var composed: Float = -1
            if case .setRoomAlignment(let second)? = operations.last { composed = second.translation.x }
            c.check("align.groupIsOneBatch", ids == [a, b], "\(ids)")
            c.check("align.composedOnBase", abs(composed - 3) < 1e-5, "\(composed)")
        } else {
            c.check("align.groupIsOneBatch", false, "not a batch")
        }
        c.check("align.snapText", AlignRoomsModel.snapText(for: .doorway) == Copy.HouseUI.snappedDoorway
                    && AlignRoomsModel.snapText(for: .wallGap) == Copy.HouseUI.snappedWall
                    && AlignRoomsModel.snapText(for: .none) == nil)
    }
}
