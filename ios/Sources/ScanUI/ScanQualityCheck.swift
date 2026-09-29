import Foundation

// The parts of the quality check at Done that run off the main thread (docs/MODULES.md 3.24,
// ARCHITECTURE 4.2 step 3): the real check of a sealed room, the Demo Mode room, and the
// honest fallback evaluation when the check cannot run. ScanFlowModel+Room.swift starts them
// in detached tasks and hands the outcomes back to the main actor.

/// The off-main parts of the quality check at Done. Stateless, any thread.
enum ScanQualityCheck {
    /// Result of the real check.
    enum Outcome: Sendable {
        /// The evaluation (also saved as quality.json).
        case evaluated(QualityEvaluation)
        /// The check could not run; diagnostic text.
        case failed(String)
    }

    /// Result of the demo room.
    enum DemoOutcome: Sendable {
        /// The demo room's record and evaluation.
        case made(RoomRecord, QualityEvaluation)
        /// The demo room could not be written; diagnostic text.
        case failed(String)
    }

    /// `QualityEvaluator.evaluateSealedRoom`, then `QualityStore.save` (a failed save is logged;
    /// the pipeline's QualityStep writes the file again).
    static func evaluate(package: ProjectPackage, record: RoomRecord, now: Date) -> Outcome {
        do {
            let result = try QualityEvaluator.evaluateSealedRoom(package: package, record: record, now: now)
            do {
                try QualityStore.save(result, package: package)
            } catch {
                LogStore.shared.write("quality.json of room \(record.id) not saved: \(StoreFiles.describe(error))",
                                      category: ScanPreflight.logCategory)
            }
            return .evaluated(result)
        } catch {
            return .failed(StoreFiles.describe(error))
        }
    }

    /// `DemoProjectFactory.makeDemoRoom`.
    static func demo(package: ProjectPackage, sessionID: UUID, roomID: UUID, now: Date) -> DemoOutcome {
        do {
            let made = try DemoProjectFactory.makeDemoRoom(package: package, sessionID: sessionID, roomID: roomID, now: now)
            return .made(made.0, made.1)
        } catch {
            return .failed(StoreFiles.describe(error))
        }
    }

    /// An honest evaluation when the check could not run: every score 0, nothing missing
    /// listed, so the sheet says the scan has gaps and offers Finish Anyway.
    static func fallback(roomID: UUID, now: Date) -> QualityEvaluation {
        let summary = QualitySummary(shape: 0, walls: 0, floor: 0, ceiling: 0, texture: 0, missingAreas: 0)
        return QualityEvaluation(roomID: roomID, summary: summary, missingAreas: [], degraded: .allGood,
                                 evidence: RoomEvidence.unknown, darkKeyframeFraction: 0, inputHash: "-",
                                 evaluatedAt: now)
    }
}
