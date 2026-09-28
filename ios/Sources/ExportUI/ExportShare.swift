import SwiftUI
import UIKit

/// One finished export waiting to be shared: the file (or zip) and the staging folder that holds
/// it. Drives the share sheet with `.sheet(item:)`.
struct ExportShareItem: Identifiable, Equatable {
    /// Identity of this share.
    let id: UUID
    /// The file handed to the share sheet (never a folder).
    let fileURL: URL
    /// `exports/<stamp>/`, deleted when the share finishes.
    let stagingFolder: URL

    /// An item for a file inside its staging folder.
    init(fileURL: URL, stagingFolder: URL) {
        id = UUID()
        self.fileURL = fileURL
        self.stagingFolder = stagingFolder
    }
}

/// `completionWithItemsHandler` deletes that export's staging folder once the share finishes.
/// A `UIActivityViewController` wrapper (RESEARCH 3.7) for file URLs that stay on disk until
/// the share is done; `onFinish` runs after the handler (the presenter clears its sheet state).
struct ActivityShareSheet: UIViewControllerRepresentable {
    /// Items to share (file URLs from the export runner).
    let items: [Any]
    /// The staging folder to delete when the share finishes, nil to keep the files.
    let stagingFolder: URL?
    /// Called on main after the share finished or was cancelled.
    let onFinish: (() -> Void)?

    /// A share sheet for `items`; `stagingFolder` is removed when it finishes.
    init(items: [Any], stagingFolder: URL?, onFinish: (() -> Void)? = nil) {
        self.items = items
        self.stagingFolder = stagingFolder
        self.onFinish = onFinish
    }

    /// Builds the activity controller and its completion handler.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let folder = stagingFolder
        let finish = onFinish
        controller.completionWithItemsHandler = { _, completed, _, error in
            let outcome = completed ? "completed" : "cancelled"
            LogStore.shared.write("export share \(outcome)\(error == nil ? "" : " with an error")",
                                  category: ExportRunner.logCategory)
            if let folder {
                ExportRunner.removeStagingFolderLater(folder)
            }
            DispatchQueue.main.async {
                finish?()
            }
        }
        return controller
    }

    /// Nothing to update: the items are fixed for the controller's life.
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
