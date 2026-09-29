import SwiftUI

/// The `.result` route (docs/MODULES.md 3.29): `ResultScreen(projectID:onExport:onRetry:)`
/// pushed inside the app's NavigationStack (its title and Rename menu are a principal toolbar
/// item). Export hands the result screen's `ExportViewState` to the router, which presents
/// `ExportSheet(projectID:viewState:)`; Retry re-enqueues the project through
/// `ProcessingPlans.retry`. The router comes from the environment (`AppRootView` injects it).
struct AppResultsCoordinator: View {
    /// The project shown.
    let projectID: UUID
    /// App navigation (export sheet).
    @EnvironmentObject private var router: AppRouter

    /// Creates the route for a project.
    init(projectID: UUID) {
        self.projectID = projectID
    }

    /// The result screen with the app's export and retry actions.
    var body: some View {
        let id = projectID
        let appRouter = router
        return ResultScreen(projectID: id, onExport: { viewState in
            appRouter.export(projectID: id, viewState: viewState)
        }, onRetry: {
            ProcessingPlans.retry(projectID: id)
        })
        .id(id)
    }
}
