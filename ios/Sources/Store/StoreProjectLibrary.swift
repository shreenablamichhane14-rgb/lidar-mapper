import Foundation
import Combine

/// The project list shown on Home. Main actor.
///
/// Folder walks (`reload`) run off main; on main it only touches disk for `create` and
/// `update` (small JSON), plus the renames behind `delete` and `discardRoom` (the folders are
/// renamed into the trash and deleted in the background by `StoreFiles.remove`).
@MainActor final class ProjectLibrary: ObservableObject {
    /// The app-wide library.
    static let shared = ProjectLibrary()

    /// Longest project name kept by `rename`, in characters.
    static let maxNameLength = 120

    /// All readable projects, newest `modifiedAt` first, archived ones included.
    @Published private(set) var projects: [ProjectManifest] = []

    /// Notification subscriptions.
    private var cancellables: Set<AnyCancellable> = []
    /// True while a background listing runs.
    private var isReloading = false
    /// True when another listing must run after the current one.
    private var reloadRequested = false
    /// Increases on every local change, so a listing started before it is not published.
    private var localChanges = 0

    /// Creates a library that reloads on every `.mapperManifestDidChange` and empties the
    /// trash left by an earlier run. Call `reload()` once to fill it.
    init() {
        NotificationCenter.default.publisher(for: .mapperManifestDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            }
            .store(in: &cancellables)
        StoreFiles.emptyTrash()
    }

    /// Lists `Documents/Projects` on a background queue and publishes on main. Also called on
    /// every `.mapperManifestDidChange`. Calls during a listing are coalesced into one more
    /// listing; a listing that overlapped a local change is not published and runs again.
    func reload() {
        guard !isReloading else {
            reloadRequested = true
            return
        }
        isReloading = true
        reloadRequested = false
        let startedAt = localChanges
        Task.detached(priority: .utility) { [weak self] in
            let list = ProjectStore.listProjects()
            await self?.finishReload(list, startedAt: startedAt)
        }
    }

    /// Publishes a finished listing unless a local change happened meanwhile, then runs the
    /// next listing when one was requested.
    private func finishReload(_ list: [ProjectManifest], startedAt: Int) {
        isReloading = false
        if startedAt == localChanges {
            projects = list
        } else {
            reloadRequested = true
        }
        if reloadRequested {
            reload()
        }
    }

    /// Creates the package with `ProjectStore.create(kind:name:now:)` and inserts it.
    func create(kind: ScanMode, name: String) throws -> (ProjectPackage, ProjectManifest) {
        let created: (ProjectPackage, ProjectManifest)
        do {
            created = try ProjectStore.create(kind: kind, name: name, now: Date())
        } catch {
            LogStore.shared.write("create project failed: \(StoreFiles.describe(error))", category: "store")
            throw error
        }
        applyLocal(created.1)
        ManifestWriter.postChange(created.1.id)
        LogStore.shared.write("created project \(created.1.id) kind \(kind.rawValue)", category: "store")
        return created
    }

    /// `ManifestWriter.update` plus an immediate local refresh of that entry. When the
    /// project no longer exists its entry is dropped and the error rethrown.
    @discardableResult
    func update(_ id: UUID, _ mutate: (inout ProjectManifest) throws -> Void) throws -> ProjectManifest {
        let package = try ProjectStore.package(for: id)
        do {
            let written = try ManifestWriter.update(package, mutate)
            applyLocal(written)
            return written
        } catch CoreError.missingFile(let name) {
            removeLocal(id)
            throw CoreError.missingFile(name)
        }
    }

    /// Removes the whole package folder (raw included) after the caller confirmed. Callers
    /// cancel the project's processing job first (HomeUI, 3.28).
    func delete(_ id: UUID) throws {
        let package = try ProjectStore.package(for: id)
        try StorePackageOps.deletePackage(package)
        removeLocal(id)
        ManifestWriter.postChange(id)
    }

    /// The user discarded the scan just captured (quality sheet Discard, lead decision 4):
    /// removes that RoomRecord, its sealed raw room folder and `derived/rooms/<room>/`, and
    /// deletes the whole project when no room is left. Returns true when the project was
    /// deleted. The only raw removal besides `delete` and build 6 Free up space.
    @discardableResult
    func discardRoom(_ roomID: UUID, in projectID: UUID) throws -> Bool {
        let package = try ProjectStore.package(for: projectID)
        if let remaining = try StorePackageOps.discardRoom(roomID, in: package) {
            applyLocal(remaining)
            return false
        }
        removeLocal(projectID)
        ManifestWriter.postChange(projectID)
        return true
    }

    /// Renames (HomeUI and Results from build 4; ProjectOps in build 6). Surrounding spaces
    /// are trimmed and the name is cut to `maxNameLength`; an empty name leaves the project
    /// unchanged.
    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            LogStore.shared.write("rename of \(id) ignored: empty name", category: "store")
            return
        }
        let limited = String(trimmed.prefix(ProjectLibrary.maxNameLength))
        try update(id) { manifest in
            manifest.name = limited
        }
    }

    /// The listed manifest of a project, if loaded.
    func manifest(for id: UUID) -> ProjectManifest? {
        projects.first { $0.id == id }
    }

    /// The package of a project (Core `ProjectStore.package(for:)`).
    func package(for id: UUID) throws -> ProjectPackage {
        try ProjectStore.package(for: id)
    }

    /// Replaces or inserts one entry and keeps the newest-first order.
    private func applyLocal(_ manifest: ProjectManifest) {
        localChanges += 1
        var list = projects
        if let index = list.firstIndex(where: { $0.id == manifest.id }) {
            list[index] = manifest
        } else {
            list.append(manifest)
        }
        list.sort { $0.modifiedAt > $1.modifiedAt }
        projects = list
    }

    /// Drops one entry.
    private func removeLocal(_ id: UUID) {
        localChanges += 1
        projects.removeAll { $0.id == id }
    }
}
