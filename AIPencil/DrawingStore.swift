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
}
