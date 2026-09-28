import Foundation

/// Pure job queue of `ProcessingRunner` (self-tested): one entry per project waits, at most
/// one entry runs, and nothing starts while suspended. Generic over the entry so the
/// self-test can use plain values.
struct PipelineJobQueue<Entry> {
    /// One waiting or running job.
    struct Item {
        /// The project the job processes.
        let projectID: UUID
        /// The runner's payload (job and completion).
        var entry: Entry
    }

    /// Jobs waiting to run, in order.
    private(set) var waiting: [Item] = []
    /// The job running now.
    private(set) var running: Item? = nil
    /// True between `suspend` and `resume`.
    private(set) var isSuspended = false

    /// An empty queue.
    init() {}

    /// True when nothing runs and nothing waits.
    var isEmpty: Bool { waiting.isEmpty && running == nil }

    /// Project ids of the waiting jobs, in order.
    var waitingProjectIDs: [UUID] { waiting.map { $0.projectID } }

    /// True when a job for the project waits.
    func hasWaiting(_ projectID: UUID) -> Bool {
        waiting.contains { $0.projectID == projectID }
    }

    /// Adds a job. A waiting job for the same project is replaced (returned so its completion
    /// can be reported); `atFront` puts the job before the waiting ones. A running job for
    /// the project is not touched: the new job runs after it and its stamped steps skip.
    @discardableResult
    mutating func enqueue(_ entry: Entry, projectID: UUID, atFront: Bool) -> Entry? {
        var replaced: Entry? = nil
        if let index = waiting.firstIndex(where: { $0.projectID == projectID }) {
            replaced = waiting.remove(at: index).entry
        }
        let item = Item(projectID: projectID, entry: entry)
        if atFront {
            waiting.insert(item, at: 0)
        } else {
            waiting.append(item)
        }
        return replaced
    }

    /// Removes the waiting job of a project and returns it.
    mutating func removeWaiting(projectID: UUID) -> Entry? {
        guard let index = waiting.firstIndex(where: { $0.projectID == projectID }) else { return nil }
        return waiting.remove(at: index).entry
    }

    /// Moves the first waiting job to running and returns it; nil while suspended, while a
    /// job runs, or when nothing waits.
    mutating func startNext() -> Item? {
        guard !isSuspended, running == nil, !waiting.isEmpty else { return nil }
        let item = waiting.removeFirst()
        running = item
        return item
    }

    /// Ends the running job. With `requeue` (the job was interrupted by `suspend`) it goes back
    /// to the front, keeping its place, unless a newer job for the same project waits. Returns
    /// the entry when it was not requeued, so the caller reports its outcome.
    mutating func finishRunning(requeue: Bool) -> Entry? {
        guard let item = running else { return nil }
        running = nil
        if requeue && !hasWaiting(item.projectID) {
            waiting.insert(item, at: 0)
            return nil
        }
        return item.entry
    }

    /// Stops new jobs from starting.
    mutating func suspend() {
        isSuspended = true
    }

    /// Lets jobs start again.
    mutating func resume() {
        isSuspended = false
    }
}
