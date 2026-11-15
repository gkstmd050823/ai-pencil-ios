import Foundation
import PDFKit
import UIKit

/// One imported document.
struct Doc: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
}

enum ImportError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "이 파일은 열 수 없어요. 손상됐거나 암호가 걸린 PDF일 수 있어요."
    }
}

/// The documents kept by the app. Each one has a folder of its own under Documents/docs holding a copy of
/// the PDF and the handwriting of every page. Used from the main thread only.
final class Library: ObservableObject {
    @Published private(set) var docs: [Doc] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Doc].self, from: data) {
            docs = saved
        }
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func pdfURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("document.pdf")
    }

    /// Copies the PDF into the app, so it still opens after the original is moved or deleted.
    @discardableResult
    func importPDF(from source: URL, title: String? = nil) throws -> Doc {
        // Files picked from the Files app are only readable between these two calls.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let directory = folder(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: pdfURL(for: id))
            guard let pdf = PDFDocument(url: pdfURL(for: id)), pdf.pageCount > 0 else { throw ImportError.unreadable }
            let name = title ?? source.deletingPathExtension().lastPathComponent
            let doc = Doc(id: id, title: name, pageCount: pdf.pageCount, addedAt: Date())
            docs.insert(doc, at: 0)
            save()
            return doc
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func delete(_ doc: Doc) {
        docs.removeAll { $0.id == doc.id }
        try? FileManager.default.removeItem(at: folder(for: doc.id))
        save()
    }

    /// The first page as a picture [width] points wide, for the shelf.
    func cover(for doc: Doc, width: CGFloat) -> UIImage? {
        guard let page = PDFDocument(url: pdfURL(for: doc.id))?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let size = CGSize(width: width, height: width * bounds.height / max(bounds.width, 1))
        return page.thumbnail(of: size, for: .cropBox)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(docs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
