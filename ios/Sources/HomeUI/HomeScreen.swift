import SwiftUI

/// Title and message of an error alert on Home (texts from `Copy.Errors`).
struct HomeErrorAlert: Equatable {
    /// Alert title.
    let title: String
    /// Alert body.
    let message: String
}

/// Home: the project list with thumbnails, mode subtitles, processing and needs-work badges,
/// search, sort, the empty state and the privacy footer; Rename (swipe and context menu) and
/// Delete with confirmation; and the big New Scan button at the bottom, reachable with one hand,
/// which opens `ModePickerSheet` (MODULES.md 3.28, ARCHITECTURE 10.2).
///
/// Place it as the root of a `NavigationStack` (AppShell's `AppRootView`); it sets the title,
/// the toolbar and the search field of that stack. It never starts a scan or opens a project
/// itself: it calls `onNewScan` after the mode picker closed, `onOpen` for a row (never for a
/// `.capturing` project, which is not listed) and `onSettings` for the gear button.
///
/// Delete first calls `ProcessingRunner.cancel(projectID:)`; while the project's job still runs
/// the row stays disabled with a spinner, and `ProjectLibrary.delete` runs once the job has
/// ended, so no step writes into a deleted package. Disk work (thumbnails, the size logged for a
/// delete, the library listing) runs off the main thread.
///
/// Dialogs, lifecycle and actions live in `HomeScreenActions.swift`; the stored state below is
/// internal (not private) only so that extension can reach it.
struct HomeScreen: View {
    /// The project list (Store).
    @ObservedObject var library: ProjectLibrary
    /// Processing state per project (Pipeline).
    @ObservedObject var runner: ProcessingRunner
    /// Modes the picker enables (build 4: `[.room]`).
    let availableModes: Set<ScanMode>
    /// Called with the picked mode once the mode picker has closed.
    let onNewScan: (ScanMode) -> Void
    /// Called with a project id when its row is tapped.
    let onOpen: (UUID) -> Void
    /// Called when the Settings button is tapped.
    let onSettings: () -> Void

    // MARK: List state

    /// Search text.
    @State var query = ""
    /// Sort order from the More menu.
    @State var sortOrder: HomeSortOrder = .recent
    /// True when archived projects are listed too (the toggle shows only when some exist).
    @State var showArchived = false
    /// False until the first listing had a moment to arrive, so "No scans yet" does not flash
    /// at launch while `ProjectLibrary.reload()` runs.
    @State var emptyStateAllowed = false
    /// Uptime when Home first appeared, for the list load time in the log.
    @State var appearedAt: Double?
    /// True once the list load time was logged.
    @State var listLogged = false

    // MARK: Sheets and dialogs

    /// Drives the mode picker sheet.
    @State var showModePicker = false
    /// The mode picked in the sheet, reported to `onNewScan` after the sheet has closed.
    @State var pickedMode: ScanMode?
    /// The project being renamed (kept after the alert closes; replaced by the next rename).
    @State var renameTarget: ProjectManifest?
    /// Text of the rename field.
    @State var renameText = ""
    /// Drives the rename alert.
    @State var isRenameAlertShown = false
    /// The project whose delete confirmation is up.
    @State var deleteTarget: ProjectManifest?
    /// Drives the delete confirmation.
    @State var isDeleteDialogShown = false
    /// The error alert's texts.
    @State var errorAlert: HomeErrorAlert?
    /// Drives the error alert.
    @State var isErrorShown = false

    // MARK: Deletes

    /// Confirmed deletes that wait for their processing job to end.
    @State var pendingDeletes: Set<UUID> = []
    /// Deletes whose size check or removal is running now.
    @State var deletesInFlight: Set<UUID> = []

    /// Height of the New Scan button, following the text size.
    @ScaledMetric(relativeTo: .title3) private var newScanHeight: CGFloat = 58

    /// Creates Home.
    init(library: ProjectLibrary, runner: ProcessingRunner, availableModes: Set<ScanMode>,
         onNewScan: @escaping (ScanMode) -> Void, onOpen: @escaping (UUID) -> Void, onSettings: @escaping () -> Void) {
        _library = ObservedObject(wrappedValue: library)
        _runner = ObservedObject(wrappedValue: runner)
        self.availableModes = availableModes
        self.onNewScan = onNewScan
        self.onOpen = onOpen
        self.onSettings = onSettings
    }

    /// The list (or empty state) with the title, toolbar, New Scan bar, sheets and dialogs.
    var body: some View {
        let base = mainContent
            .navigationTitle(Copy.Home.title)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: 0) { newScanBar }
        return withLifecycle(withDialogs(base))
    }

    // MARK: - Content

    /// Every project Home may show (not `.capturing`), archived included.
    private var listableCount: Int {
        HomePresentation.filtered(library.projects, query: "", showArchived: true).count
    }

    /// True when some listable project is archived (shows the Show Archived toggle).
    private var hasArchivedProjects: Bool {
        library.projects.contains { $0.isArchived && $0.status != .capturing }
    }

    /// The rows for the current search, archive toggle and sort order.
    private var visibleProjects: [ProjectManifest] {
        let filtered = HomePresentation.filtered(library.projects, query: query, showArchived: showArchived)
        return HomePresentation.sorted(filtered, by: sortOrder)
    }

    /// The list, the empty state, or nothing during the first moment after launch.
    @ViewBuilder
    private var mainContent: some View {
        if listableCount == 0 {
            if emptyStateAllowed {
                emptyState
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            projectList
        }
    }

    /// Active projects, then archived ones under their own header when shown; the privacy
    /// footer under the last section; the search field in the navigation bar drawer.
    private var projectList: some View {
        let visible = visibleProjects
        let active = visible.filter { !$0.isArchived }
        let archived = visible.filter { $0.isArchived }
        let now = Date()
        return List {
            if !active.isEmpty {
                Section {
                    ForEach(active) { manifest in
                        projectRow(manifest, now: now)
                    }
                } footer: {
                    if archived.isEmpty { privacyFooter }
                }
            }
            if !archived.isEmpty {
                Section {
                    ForEach(archived) { manifest in
                        projectRow(manifest, now: now)
                    }
                } header: {
                    Text(Copy.Home.archivedTitle)
                } footer: {
                    privacyFooter
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if visible.isEmpty { noMatchesView }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text(Copy.Home.searchPrompt))
    }

    /// One tappable row with its VoiceOver text, swipe actions and context menu.
    private func projectRow(_ manifest: ProjectManifest, now: Date) -> some View {
        let dateText = HomePresentation.dateText(manifest.createdAt, now: now)
        let state = runner.states[manifest.id]
        let badge = HomePresentation.badge(for: manifest, processing: state)
        let isDeleting = pendingDeletes.contains(manifest.id)
        let key = HomeThumbnailKey(projectID: manifest.id, modifiedAt: manifest.modifiedAt,
                                   thumbnailBuilt: state?.completed.contains(.thumbnail) ?? false)
        let label = HomePresentation.accessibilityLabel(for: manifest, dateText: dateText, badge: badge)
        let value = HomePresentation.accessibilityValue(for: manifest, dateText: dateText, badge: badge)
        return Button {
            open(manifest)
        } label: {
            HomeProjectRow(manifest: manifest,
                           name: HomePresentation.displayName(for: manifest, dateText: dateText),
                           subtitle: HomePresentation.subtitle(for: manifest, dateText: dateText),
                           badge: badge, isDeleting: isDeleting, thumbnailKey: key)
        }
        .disabled(isDeleting)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(Copy.A11y.openProjectHint))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                confirmDelete(manifest)
            } label: {
                Label(Copy.Project.delete, systemImage: "trash")
            }
            .tint(.red)
            Button {
                beginRename(manifest)
            } label: {
                Label(Copy.Project.rename, systemImage: "pencil")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                beginRename(manifest)
            } label: {
                Label(Copy.Project.rename, systemImage: "pencil")
            }
            Button(role: .destructive) {
                confirmDelete(manifest)
            } label: {
                Label(Copy.Project.delete, systemImage: "trash")
            }
        }
    }

    /// "No scans yet" with the privacy footer; scrolls at large text sizes.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView(Copy.Empty.noProjects.title, systemImage: "viewfinder",
                                       description: Text(Copy.Empty.noProjects.body))
                privacyFooter
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
    }

    /// Shown over the list when nothing matches: "No matches" for a search, else "No scans yet"
    /// (every project is archived and archived ones are hidden).
    @ViewBuilder
    private var noMatchesView: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(Copy.Empty.noProjects.title, systemImage: "viewfinder",
                                   description: Text(Copy.Empty.noProjects.body))
        } else {
            ContentUnavailableView(Copy.Empty.noSearchResults.title, systemImage: "magnifyingglass",
                                   description: Text(Copy.Empty.noSearchResults.body))
        }
    }

    /// "Your scans stay on this iPhone. No account needed."
    private var privacyFooter: some View {
        Text(Copy.Home.privacyFooter)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// The full-width New Scan button on a bar material, above the home indicator.
    private var newScanBar: some View {
        Button {
            pickedMode = nil
            showModePicker = true
        } label: {
            Label(Copy.Home.newScan, systemImage: "viewfinder")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: newScanHeight)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityHint(Text(Copy.A11y.newScanHint))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Sort and archive menu (leading) and Settings (trailing).
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            listMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                onSettings()
            } label: {
                Label(Copy.Home.settings, systemImage: "gearshape")
            }
        }
    }

    /// Most Recent or Name, plus Show Archived when some project is archived.
    private var listMenu: some View {
        Menu {
            Picker(selection: $sortOrder) {
                ForEach(HomeSortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            if hasArchivedProjects {
                Toggle(Copy.Home.showArchived, isOn: $showArchived)
            }
        } label: {
            Label(Copy.A11y.more, systemImage: "arrow.up.arrow.down.circle")
        }
    }
}
