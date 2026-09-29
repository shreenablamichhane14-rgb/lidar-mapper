import Foundation
import PDFKit

/// Joins single-page PDFs into one document in order (PDFKit): the multi-floor PDF floor plan has
/// one page per floor, each drawn by `PDFPlanWriter` (docs/MODULES.md 3.43d). Nonisolated; the
/// runner calls it off main.
enum ExportPDFPages {
    /// The pages of `pages` in order as one PDF. One input is returned unchanged. Throws
    /// `ExportError.emptyPlan` for no input and `ExportError.encodingFailed(format: "pdf")` when an
    /// input is not a readable PDF or the joined document cannot be written.
    static func merge(_ pages: [Data]) throws -> Data {
        guard let first = pages.first else { throw ExportError.emptyPlan }
        if pages.count == 1 { return first }
        let output = PDFDocument()
        // The source documents stay alive until the joined data is written, because a copied
        // page still draws from its source document's content.
        var sources: [PDFDocument] = []
        for data in pages {
            guard let source = PDFDocument(data: data), source.pageCount > 0 else {
                throw ExportError.encodingFailed(format: "pdf")
            }
            sources.append(source)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                let copy = (page.copy() as? PDFPage) ?? page
                output.insert(copy, at: output.pageCount)
            }
        }
        guard output.pageCount > 0, let joined = output.dataRepresentation() else {
            throw ExportError.encodingFailed(format: "pdf")
        }
        withExtendedLifetime(sources) {}
        return joined
    }

    /// Number of pages of a PDF, 0 when it cannot be read (self-test and logs).
    static func pageCount(_ data: Data) -> Int {
        PDFDocument(data: data)?.pageCount ?? 0
    }
}
