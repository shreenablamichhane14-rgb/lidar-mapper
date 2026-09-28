import SwiftUI

/// Dialogs, lifecycle and user actions of `HomeScreen` (split from HomeScreen.swift to keep both
/// files short; the state they touch is internal for that reason). Everything runs on the main
/// actor; disk work goes to detached tasks.
@MainActor
extension HomeScreen {
    // MARK: - Dialogs and lifecycle

    /// Adds the mode picker sheet, the rename alert, the delete confirmation and the error alert.
    func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $showModePicker, onDismiss: { startPickedMode() }) {
                ModePickerSheet(availableModes: availableModes, onPick: { mode in
                    pickedMode = mode
                    showModePicker = false
                }, onCancel: {
                    pickedMode = nil
                    showModePicker = false
                })
                .presentationDetents([.medium, .large])
            }
            .alert(Copy.Project.renameTitle, isPresented: $isRenameAlertShown, presenting: renameTarget) { target in
                TextField(Copy.HomeUI.namePlaceholder, text: $renameText)
                    .textInputAutocapitalization(.words)
                Button(Copy.Errors.ok) { commitRename(target) }
                Button(Copy.Project.cancel, role: .cancel) {}
            }
            .confirmationDialog(deleteDialogTitle, isPresented: $isDeleteDialogShown, titleVisibility: .visible,
                                presenting: deleteTarget) { target in
                Button(Copy.Project.deleteConfirm, role: .destructive) { requestDelete(target) }
                Button(Copy.Project.cancel, role: .cancel) {}
            } message: { _ in
                Text(Copy.Project.deleteBody)
            }
            .alert(errorAlert?.title ?? "", isPresented: $isErrorShown, presenting: errorAlert) { _ in
                Button(Copy.Errors.ok, role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }

    /// Adds appearance, list-change and runner-change handling.
    func withLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear { handleAppear() }
            .onChange(of: library.projects) { handleProjectsChange() }
            .onChange(of: runner.states) { finishPendingDeletes() }
            .task { await allowEmptyStateAfterFirstListing() }
    }

    /// `Delete "{name}"?` for the project awaiting confirmation.
    private var deleteDialogTitle: String {
        guard let target = deleteTarget else { return "" }
        let dateText = HomePresentation.dateText(target.createdAt, now: Date())
        return Copy.Project.deleteTitle(HomePresentation.displayName(for: target, dateText: dateText))
    }

    // MARK: - Rows

    /// Opens a project; never a `.capturing` one or one being deleted.
    func openProject(_ manifest: ProjectManifest) {
        guard HomePresentation.canOpen(manifest), !pendingDeletes.contains(manifest.id) else { return }
        onOpen(manifest.id)
    }

    /// Shows the rename alert filled with the current name.
    func beginRename(_ manifest: ProjectManifest) {
        guard !pendingDeletes.contains(manifest.id) else { return }
        renameText = manifest.name
        renameTarget = manifest
        isRenameAlertShown = true
    }

    /// Shows the delete confirmation.
    func confirmDelete(_ manifest: ProjectManifest) {
        guard !pendingDeletes.contains(manifest.id) else { return }
        deleteTarget = manifest
        isDeleteDialogShown = true
    }

    /// Stores the new name through `ProjectLibrary.rename` (it trims and caps the length). A
    /// blank or unchanged name does nothing; a failure shows `Copy.Errors.saveFailed`.
    private func commitRename(_ target: ProjectManifest) {
        guard let name = HomePresentation.proposedName(renameText), name != target.name else { return }
        do {
            try library.rename(target.id, to: name)
            log("renamed project \(short(target.id))")
        } catch {
            log("rename of \(short(target.id)) failed: \(StoreFiles.describe(error))")
            showError(HomeErrorAlert(title: Copy.Errors.saveFailed.title, message: Copy.Errors.saveFailed.body))
        }
    }

    // MARK: - Delete

    /// After the confirmation: marks the row as deleting, cancels the project's processing job
    /// (a waiting job ends at once, a running one at its next cancellation check) and deletes as
    /// soon as no job runs for it.
    private func requestDelete(_ target: ProjectManifest) {
        let id = target.id
        guard !pendingDeletes.contains(id) else { return }
        pendingDeletes.insert(id)
        let state = runner.state(for: id)
        // Always cancel first (MODULES.md 3.28); without a job this does nothing.
        runner.cancel(projectID: id)
        if state.isRunning || state.isQueued {
            log("delete of \(short(id)) cancels its processing job first")
        }
        finishPendingDeletes()
    }

    /// Starts the removal of every pending delete whose job has ended. Called after a request and
    /// on every runner state change. A job queued again meanwhile is cancelled too.
    private func finishPendingDeletes() {
        for id in pendingDeletes where !deletesInFlight.contains(id) {
            if runner.state(for: id).isQueued {
                runner.cancel(projectID: id)
            }
            let state = runner.state(for: id)
            if HomePresentation.mustWaitBeforeDelete(state) || state.isQueued { continue }
            deletesInFlight.insert(id)
            Task { await performDelete(id) }
        }
    }

    /// Measures the package off main (for the log), checks the runner once more, then deletes
    /// with `ProjectLibrary.delete` (a rename into the trash; the files go in the background).
    /// When a job started meanwhile the delete waits for the next runner change.
    private func performDelete(_ id: UUID) async {
        let bytes = await Task.detached(priority: .utility) { () -> Int64 in
            guard let package = try? ProjectStore.package(for: id) else { return 0 }
            return StorageUsage.usage(of: package).total
        }.value
        let state = runner.state(for: id)
        if state.isRunning || state.isQueued {
            runner.cancel(projectID: id)
            deletesInFlight.remove(id)
            log("delete of \(short(id)) waits: a processing job started again")
            return
        }
        do {
            try library.delete(id)
            log("deleted project \(short(id)), bytes freed \(bytes)")
        } catch {
            log("delete of \(short(id)) failed: \(StoreFiles.describe(error))")
            showError(HomeErrorAlert(title: Copy.Errors.generic.title, message: Copy.Errors.generic.body))
        }
        pendingDeletes.remove(id)
        deletesInFlight.remove(id)
    }

    // MARK: - New scan

    /// After the mode picker closed: reports the picked mode, if any, to `onNewScan`. Waiting
    /// for the dismissal lets AppShell present the scan cover without a presentation conflict.
    private func startPickedMode() {
        guard let mode = pickedMode else { return }
        pickedMode = nil
        guard availableModes.contains(mode) else {
            log("new scan ignored: \(mode.rawValue) is not available")
            return
        }
        log("new scan requested: \(mode.rawValue)")
        onNewScan(mode)
    }

    // MARK: - Lifecycle

    /// Records the first appearance, asks the library for a fresh listing (off main, coalesced)
    /// and logs the list when it is already there.
    private func handleAppear() {
        if appearedAt == nil {
            appearedAt = ProcessInfo.processInfo.systemUptime
        }
        library.reload()
        logListIfNeeded()
    }

    /// A listing arrived or a project changed: the empty state may show from now on, and the
    /// first listing is logged. Pending deletes of projects that vanished elsewhere are dropped.
    private func handleProjectsChange() {
        emptyStateAllowed = true
        logListIfNeeded()
        let listed = Set(library.projects.map { $0.id })
        for id in pendingDeletes where !listed.contains(id) && !deletesInFlight.contains(id) {
            pendingDeletes.remove(id)
        }
    }

    /// Lets "No scans yet" show after a short moment even when the first listing is empty (an
    /// empty listing publishes no change).
    private func allowEmptyStateAfterFirstListing() async {
        guard !emptyStateAllowed else { return }
        try? await Task.sleep(nanoseconds: 400_000_000)
        emptyStateAllowed = true
        if library.projects.isEmpty && !listLogged {
            listLogged = true
            log("project list shown: 0 projects")
        }
    }

    /// Logs the number of listed projects and the time since Home appeared, once (TEST_PLAN PROJ-01).
    private func logListIfNeeded() {
        guard !listLogged, !library.projects.isEmpty, let start = appearedAt else { return }
        listLogged = true
        let elapsed = max(ProcessInfo.processInfo.systemUptime - start, 0)
        let milliseconds = Int((elapsed * 1000).rounded())
        let listed = HomePresentation.filtered(library.projects, query: "", showArchived: true).count
        log("project list shown: \(listed) projects after \(milliseconds) ms")
    }

    /// Shows an error alert.
    private func showError(_ alert: HomeErrorAlert) {
        errorAlert = alert
        isErrorShown = true
    }

    // MARK: - Log

    /// Writes a line to the app log (category "home"). Never a project name, only ids.
    private func log(_ message: String) {
        LogStore.shared.write("home: " + message, category: "home")
    }

    /// First 8 characters of an id for the log.
    private func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
