import Foundation

/// What one off-main load of `MeasureToolModel` reads.
struct MeasureToolLoadRequest: Sendable {
    /// The project's package.
    var package: ProjectPackage
    /// The stamp the current context was built from; nil forces a rebuild.
    var previousStamp: MeasureToolFileStamp?
    /// Hide Furniture flag the context is built with.
    var excludeMovable: Bool
    /// Read `edits/measurements.json`.
    var records: Bool
    /// Read the unit preferences.
    var prefs: Bool
}

/// What one load produced; nil fields were not read (or did not need rebuilding).
struct MeasureToolLoadResult: @unchecked Sendable {
    /// The new context, when it was rebuilt.
    var context: MeasureToolContext?
    /// The stamp of the files the context was built from.
    var stamp: MeasureToolFileStamp
    /// The Hide Furniture flag the context was built with.
    var excludeMovable: Bool
    /// Saved measurements, when read.
    var records: [MeasurementRecord]?
    /// Unit preferences, when read.
    var prefs: UnitPreferences?
}

/// File work of `MeasureToolModel`, off main (docs/MODULES.md 3.35 `load()`). Reads only; never
/// writes anything.
enum MeasureToolLoader {
    /// Reads what the request asks for. The context is rebuilt when there is no previous stamp or
    /// clean.json or the edit log changed since it: `CleanModelStore.loadEdited` (a failure leaves
    /// an empty model, so points snap to the scan only; logged), the quality evidence of every room
    /// of the model and of the manifest, then `MeasureToolSnaps.context`.
    static func load(_ request: MeasureToolLoadRequest) -> MeasureToolLoadResult {
        let package = request.package
        let stamp = MeasureToolFileStamp.current(package)
        var result = MeasureToolLoadResult(context: nil, stamp: stamp, excludeMovable: request.excludeMovable,
                                           records: nil, prefs: nil)
        if request.previousStamp != stamp {
            let started = ProcessInfo.processInfo.systemUptime
            let model = editedModel(package)
            let evidence = roomEvidence(package, model: model)
            let context = MeasureToolSnaps.context(model: model, evidence: evidence, excludeMovable: request.excludeMovable)
            result.context = context
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            LogStore.shared.write("context: \(model.rooms.count) rooms, \(evidence.count) with evidence, "
                                  + "\(context.snaps.corners.count) corners, \(context.snaps.planes.count) planes "
                                  + "in \(milliseconds) ms", category: MeasureToolModel.logCategory)
        }
        if request.records {
            result.records = EditStore.loadMeasurements(package)
        }
        if request.prefs {
            result.prefs = UnitPreferences.load()
        }
        return result
    }

    /// The edited clean model, or an empty model when it cannot be loaded (logged).
    static func editedModel(_ package: ProjectPackage) -> CleanModel {
        do {
            let loaded = try CleanModelStore.loadEdited(package)
            if !loaded.orphaned.isEmpty {
                LogStore.shared.write("\(loaded.orphaned.count) edits target missing elements",
                                      category: MeasureToolModel.logCategory)
            }
            return loaded.model
        } catch {
            LogStore.shared.write("clean model unavailable (\(error)); points snap to the scan only",
                                  category: MeasureToolModel.logCategory)
            return .empty
        }
    }

    /// `QualityEvaluation.evidence` of every distinct `CleanRoom.recordID` and of every room listed
    /// in the manifest (a room merged into another is gone from the model but its walls are not).
    static func roomEvidence(_ package: ProjectPackage, model: CleanModel) -> [UUID: RoomEvidence] {
        var ids: [UUID] = []
        var seen: Set<UUID> = []
        for room in model.rooms where seen.insert(room.recordID).inserted {
            ids.append(room.recordID)
        }
        if let manifest = try? ProjectStore.readManifest(package) {
            for room in manifest.rooms where seen.insert(room.id).inserted {
                ids.append(room.id)
            }
        }
        var evidence: [UUID: RoomEvidence] = [:]
        for id in ids {
            if let evaluation = QualityStore.load(package, room: id) {
                evidence[id] = evaluation.evidence
            }
        }
        return evidence
    }
}
