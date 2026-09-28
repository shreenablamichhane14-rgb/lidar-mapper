import SwiftUI
import UIKit

/// What a row's thumbnail depends on. A change (the manifest was rewritten, or the thumbnail
/// step finished) reloads the image; unchanged files come from `HomeThumbnailCache`.
struct HomeThumbnailKey: Hashable, Sendable {
    /// The project.
    let projectID: UUID
    /// `ProjectManifest.modifiedAt`.
    let modifiedAt: Date
    /// True once the runner reported the thumbnail step complete in the current job.
    let thumbnailBuilt: Bool
}

/// One project row on Home: thumbnail, name, subtitle and badge. Pure layout; the list wraps it
/// in a button that carries the VoiceOver label, value and hint (`HomePresentation`), so every
/// part here is hidden from VoiceOver or merged into that button.
///
/// Dynamic Type: system text styles throughout; at accessibility sizes the thumbnail moves above
/// the text so long names wrap instead of truncating. Dark mode: system colors only.
struct HomeProjectRow: View {
    /// The project shown.
    let manifest: ProjectManifest
    /// Name shown (`HomePresentation.displayName`).
    let name: String
    /// Subtitle shown (`HomePresentation.subtitle`).
    let subtitle: String
    /// Badge, if any (`HomePresentation.badge`).
    let badge: HomeBadge?
    /// True while a delete of this project waits for its processing job to end.
    let isDeleting: Bool
    /// Reload key of the thumbnail.
    let thumbnailKey: HomeThumbnailKey

    /// Current text size, to switch to a stacked layout at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Pixel density, for the decoded thumbnail size.
    @Environment(\.displayScale) private var displayScale
    /// Thumbnail edge, following the body text size.
    @ScaledMetric(relativeTo: .body) private var thumbnailSide: CGFloat = 60
    /// The decoded thumbnail, nil until loaded or when the project has none yet.
    @State private var thumbnail: UIImage?

    /// Largest thumbnail edge in points, so huge text sizes do not make the image fill the row.
    private static let maxThumbnailSide: CGFloat = 112
    /// Corner radius of the thumbnail.
    private static let cornerRadius: CGFloat = 10

    /// Creates a row.
    init(manifest: ProjectManifest, name: String, subtitle: String, badge: HomeBadge?,
         isDeleting: Bool, thumbnailKey: HomeThumbnailKey) {
        self.manifest = manifest
        self.name = name
        self.subtitle = subtitle
        self.badge = badge
        self.isDeleting = isDeleting
        self.thumbnailKey = thumbnailKey
    }

    /// Side-by-side layout, stacked at accessibility text sizes.
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnailView
                    textStack
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    thumbnailView
                    textStack
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isDeleting ? 0.5 : 1)
        .task(id: thumbnailKey) {
            let pixels = side * max(displayScale, 1)
            thumbnail = await HomeThumbnailCache.shared.image(projectID: thumbnailKey.projectID, maxPixels: pixels)
        }
    }

    // MARK: Pieces

    /// The clamped thumbnail edge in points.
    private var side: CGFloat {
        min(thumbnailSide, HomeProjectRow.maxThumbnailSide)
    }

    /// The thumbnail, or the mode symbol on a tinted tile while there is none.
    private var thumbnailView: some View {
        let shape = RoundedRectangle(cornerRadius: HomeProjectRow.cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(Color(uiColor: .secondarySystemBackground))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: HomePresentation.symbol(for: manifest.kind))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    /// Name, subtitle and badge.
    private var textStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if isDeleting {
                ProgressView()
                    .controlSize(.small)
            } else if let badge {
                badgeView(badge)
            }
        }
        .multilineTextAlignment(.leading)
    }

    /// The badge line: a small spinner with "Building model..." or a warning symbol with
    /// "Needs another scan".
    @ViewBuilder
    private func badgeView(_ badge: HomeBadge) -> some View {
        switch badge {
        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(HomePresentation.badgeText(.processing))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .needsWork:
            Label(HomePresentation.badgeText(.needsWork), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.orange)
        }
    }
}

/// Carries a decoded thumbnail out of the detached loading task. `UIImage` is immutable, so
/// handing it to the main actor is safe.
private struct HomeThumbnailResult: @unchecked Sendable {
    /// The decoded image, nil when the project has none.
    let image: UIImage?
}

/// Decoded project thumbnails (`ProjectPackage.thumbnailURL`), loaded and downscaled off the
/// main thread and kept in memory by file modification date, so scrolling back to a row and a
/// progress update never touch the disk on main. `NSCache` is thread safe.
final class HomeThumbnailCache: @unchecked Sendable {
    /// The app-wide cache.
    static let shared = HomeThumbnailCache()

    /// Images by "projectID|modification time|pixel size".
    private let cache = NSCache<NSString, UIImage>()

    /// Creates a cache holding up to 150 thumbnails.
    init() {
        cache.countLimit = 150
    }

    /// The project's thumbnail scaled to at most `maxPixels` on its long edge, or nil when the
    /// project has none yet. The file work runs in a detached task.
    func image(projectID: UUID, maxPixels: CGFloat) async -> UIImage? {
        let result = await Task.detached(priority: .utility) { () -> HomeThumbnailResult in
            HomeThumbnailResult(image: HomeThumbnailCache.shared.load(projectID: projectID, maxPixels: maxPixels))
        }.value
        return result.image
    }

    /// Reads, decodes and caches the thumbnail. Any thread. A missing file is normal (the
    /// thumbnail step has not run yet); an unreadable file is logged.
    private func load(projectID: UUID, maxPixels: CGFloat) -> UIImage? {
        guard let package = try? ProjectStore.package(for: projectID) else { return nil }
        let url = package.thumbnailURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let pixels = max(Int(maxPixels.rounded()), 1)
        let key = "\(projectID.uuidString)|\(modified.timeIntervalSinceReferenceDate)|\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let full = UIImage(contentsOfFile: url.path) else {
            LogStore.shared.write("home: thumbnail of \(projectID.uuidString.prefix(8)) could not be decoded", category: "home")
            return nil
        }
        let target = HomeThumbnailCache.fittedSize(full.size, maxPixels: CGFloat(pixels))
        let prepared = full.preparingThumbnail(of: target) ?? full
        cache.setObject(prepared, forKey: key)
        return prepared
    }

    /// `size` scaled down so its long edge is at most `maxPixels`; unchanged when already
    /// smaller or degenerate.
    static func fittedSize(_ size: CGSize, maxPixels: CGFloat) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxPixels, longEdge > 0, maxPixels > 0 else { return size }
        let scale = maxPixels / longEdge
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return CGSize(width: max(width, 1), height: max(height, 1))
    }
}
