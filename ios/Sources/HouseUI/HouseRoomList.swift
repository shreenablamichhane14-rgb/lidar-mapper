import SwiftUI
import Combine

// Room lists of House projects (docs/MODULES.md 3.41, UX_COPY section 5): the in-visit room list
// sheet over the dimmed camera, and the project room screen Results opens. Both read only the
// manifest, the Structure report and the edit log (`HousePresentation.rows`). One-handed: the
// main actions sit at the bottom. Rows carry a symbol for their status so color is never the
// only signal.

/// The in-visit room list sheet: floor sections, rows, low-memory banner, Scan Next Room,
/// Add Floor, Finish Building; tapping a "needs additional scan" row offers Rescan.
struct HouseRoomListView: View {
    /// The house flow.
    @ObservedObject var model: HouseFlowModel
    /// The row whose Rescan offer is showing.
    @State private var rescanRow: HouseRoomRow?
    /// The Rescan offer is showing.
    @State private var showsRescanOffer = false

    /// Creates the list for `model`.
    init(model: HouseFlowModel) {
        self.model = model
    }

    /// Header, banner, rows and the bottom actions.
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.House.title)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                if !model.progressText.isEmpty {
                    Text(model.progressText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            if model.lowMemory {
                HouseBanner(text: Copy.HouseUI.lowMemoryHint, systemImage: "memorychip")
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            HouseRoomRowsList(rows: model.rows) { row in
                rowTapped(row)
            } menu: { row in
                Button(Copy.House.rescanRoom) { model.rescan(row.id) }
            }
            actions
        }
        .confirmationDialog(rescanRow?.statusText ?? "", isPresented: $showsRescanOffer, titleVisibility: .visible,
                            presenting: rescanRow) { row in
            Button(Copy.House.rescanRoom) { model.rescan(row.id) }
            Button(Copy.Project.cancel, role: .cancel) {}
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    /// Scan Next Room (primary, full width), then Add Floor and Finish Building.
    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                model.scanNextRoom()
            } label: {
                Label(Copy.House.addRoom, systemImage: "plus.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack(spacing: 10) {
                Button {
                    model.addFloor()
                } label: {
                    Text(Copy.House.addFloor)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                if model.lowMemory {
                    finishButton
                        .buttonStyle(.borderedProminent)
                } else {
                    finishButton
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Finish Building (prominent when memory is low, D17).
    private var finishButton: some View {
        Button {
            model.finishBuilding()
        } label: {
            Text(Copy.House.finishBuilding)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    /// A "needs additional scan" row offers Rescan; other rows do nothing on tap (their menu has it).
    private func rowTapped(_ row: HouseRoomRow) {
        guard row.status == .needsScan else { return }
        rescanRow = row
        showsRescanOffer = true
    }
}

/// A rounded banner with a symbol (low memory, failed merge).
struct HouseBanner: View {
    /// The text.
    let text: String
    /// SF Symbol shown first.
    let systemImage: String

    /// Symbol and text on a tinted rounded rectangle, read as one element.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}

/// The rows grouped by floor, each with its status symbol and text; `menu` adds per-row actions
/// (a context menu and a swipe action).
struct HouseRoomRowsList<MenuContent: View>: View {
    /// The rows, floor then capture order.
    let rows: [HouseRoomRow]
    /// Row tap.
    let onTap: (HouseRoomRow) -> Void
    /// Per-row actions.
    let menu: (HouseRoomRow) -> MenuContent

    /// Creates the list.
    init(rows: [HouseRoomRow], onTap: @escaping (HouseRoomRow) -> Void,
         @ViewBuilder menu: @escaping (HouseRoomRow) -> MenuContent) {
        self.rows = rows
        self.onTap = onTap
        self.menu = menu
    }

    /// Sections per floor, or the empty state.
    var body: some View {
        List {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.Empty.noRooms.title)
                        .font(.headline)
                    Text(Copy.Empty.noRooms.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(HousePresentation.floorSections(rows)) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// One row: symbol, status text; tap, context menu and swipe action.
    private func rowView(_ row: HouseRoomRow) -> some View {
        Button {
            onTap(row)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(for: row.status))
                    .foregroundStyle(Self.tint(for: row.status))
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(row.statusText)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
        .contextMenu { menu(row) }
        .swipeActions(edge: .trailing) { menu(row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibility)
        .accessibilityHint(row.status == .needsScan ? Copy.A11y.rescanRoomHint : "")
        .accessibilityAddTraits(.isButton)
    }

    /// The status symbol (checkmark for done, warning for rooms needing a scan).
    static func symbol(for status: HouseRoomStatus) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .needsScan: return "exclamationmark.triangle.fill"
        case .needsLineUp: return "arrow.up.and.down.and.arrow.left.and.right"
        case .notProcessed: return "clock"
        }
    }

    /// The status tint (never the only signal).
    static func tint(for status: HouseRoomStatus) -> Color {
        switch status {
        case .done: return Color.green
        case .needsScan: return Color.orange
        case .needsLineUp: return Color.yellow
        case .notProcessed: return Color.secondary
        }
    }
}

/// The room screen of an existing house (Results 5c opens it): rows with the Structure report,
/// Continue Scanning, per-row Rescan and Line Up by Hand, Join Rooms Again after a crashed
/// merge, and the "These rooms didn't line up" alert once per report.
struct HouseProjectScreen: View {
    /// Rows, flags and the alert of the project.
    @StateObject private var model: HouseProjectModel
    /// Continue Scanning (AppShell opens `.continueProject`).
    private let onContinueScanning: () -> Void
    /// Rescan of one room (AppShell opens `.rescan`).
    private let onRescan: (UUID) -> Void
    /// Line Up by Hand for one room (AppShell opens `AlignRoomsScreen`).
    private let onLineUp: (UUID) -> Void
    /// Join Rooms Again, after the crashed attempt was cleared (AppShell enqueues processing).
    private let onJoinAgain: () -> Void

    /// Creates the screen of `projectID` with the actions AppShell wires.
    init(projectID: UUID, onContinueScanning: @escaping () -> Void, onRescan: @escaping (UUID) -> Void,
         onLineUp: @escaping (UUID) -> Void, onJoinAgain: @escaping () -> Void) {
        _model = StateObject(wrappedValue: HouseProjectModel(projectID: projectID))
        self.onContinueScanning = onContinueScanning
        self.onRescan = onRescan
        self.onLineUp = onLineUp
        self.onJoinAgain = onJoinAgain
    }

    /// Progress, the failed-merge banner, the rows and Continue Scanning at the bottom.
    var body: some View {
        VStack(spacing: 0) {
            if !model.progressText.isEmpty {
                Text(model.progressText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            if model.showsJoinAgain {
                VStack(alignment: .leading, spacing: 8) {
                    HouseBanner(text: Copy.HouseUI.mergeFailedBody, systemImage: "exclamationmark.triangle.fill")
                    Button(Copy.HouseUI.joinRoomsAgain) { joinAgain() }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            HouseRoomRowsList(rows: model.rows) { row in
                rowTapped(row)
            } menu: { row in
                Button(Copy.House.rescanRoom) { onRescan(row.id) }
                if model.rows.count > 1 {
                    Button(Copy.House.alignManual) { onLineUp(row.id) }
                }
            }
            Button {
                onContinueScanning()
            } label: {
                Label(Copy.House.continueRoom, systemImage: "plus.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(Copy.House.title)
        .onAppear { model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .mapperManifestDidChange)) { _ in
            model.load()
        }
        .alert(model.alert?.title ?? "", isPresented: $model.alertPresented, presenting: model.alert) { current in
            alertButtons(current)
        } message: { current in
            Text(current.body)
        }
    }

    /// A row that needs lining up opens the alignment screen; one that needs a scan, Rescan.
    private func rowTapped(_ row: HouseRoomRow) {
        switch row.status {
        case .needsLineUp: onLineUp(row.id)
        case .needsScan: onRescan(row.id)
        case .done, .notProcessed: break
        }
    }

    /// Clears the crashed attempt, then hands over to AppShell.
    private func joinAgain() {
        if model.clearCrashedAttempt() { onJoinAgain() }
    }

    /// Up to three alert buttons; Cancel takes the cancel role.
    @ViewBuilder private func alertButtons(_ current: HouseAlert) -> some View {
        if let first = current.actions.first {
            alertButton(first)
        }
        if current.actions.count > 1 {
            alertButton(current.actions[1])
        }
        if current.actions.count > 2 {
            alertButton(current.actions[2])
        }
    }

    /// One alert button and its action.
    private func alertButton(_ action: HouseAlertAction) -> some View {
        let role: ButtonRole? = HouseAlert.isDismissal(action) ? .cancel : nil
        return Button(HouseAlert.title(for: action), role: role) {
            model.alert = nil
            switch action {
            case .lineUp(let room): onLineUp(room)
            case .rescan(let room): onRescan(room)
            case .joinAgain: joinAgain()
            case .ok, .cancel, .openSettings, .resume, .finishNow, .startFresh, .keepLooking: break
            }
        }
    }
}
