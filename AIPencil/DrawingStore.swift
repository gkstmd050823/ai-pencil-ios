import Foundation
import PencilKit

/// Handwriting on disk: one PencilKit drawing per page, in the document's own folder.
struct DrawingStore {
    let folder: URL

    private func url(page: Int) -> URL {
        folder.appendingPathComponent("ink-\(page).drawing")
    }

    func load(page: Int) -> PKDrawing? {
        guard let data = try? Data(contentsOf: url(page: page)) else { return nil }
        return try? PKDrawing(data: data)
    }

    func save(_ drawing: PKDrawing, page: Int) {
        let target = url(page: page)
        if drawing.strokes.isEmpty {
            // A page wiped clean leaves no file behind.
            try? FileManager.default.removeItem(at: target)
            return
        }
        try? drawing.dataRepresentation().write(to: target, options: .atomic)
    }

    /// After a page was inserted at [index] of a document that had [pageCount] pages: the handwriting of
    /// that page and every later one moves one page later. From the last page down, so that no file is
    /// moved onto one still waiting to move.
    func shiftPages(from index: Int, pageCount: Int) {
        guard index < pageCount else { return }
        for page in stride(from: pageCount - 1, through: index, by: -1) {
            let from = url(page: page)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            let to = url(page: page + 1)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }
}
