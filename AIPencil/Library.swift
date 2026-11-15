import Foundation
import PDFKit
import UIKit

/// One document on the shelf.
struct Doc: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
}

enum ImportError: LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "이 파일은 열 수 없어요. 손상됐거나 암호가 걸린 PDF일 수 있어요."
        case .unwritable: return "문서를 고쳐 쓰지 못했어요. 암호가 걸렸거나 손상된 PDF일 수 있어요."
        }
    }
}

/// The documents kept by the app. Each one has a folder of its own under Documents/docs holding a copy of
/// the PDF, the handwriting of every page, its typed formulas and the questions asked about it. Used from
/// the main thread only.
final class Library: ObservableObject {
    @Published private(set) var docs: [Doc] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    /// A4 in points, the size of a new notebook's pages.
    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

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

    /// A name for a new notebook that no document has yet: "새 노트", then "새 노트 2", ...
    static func freshTitle(taken: [String], base: String = "새 노트") -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Makes a notebook of one blank A4 page.
    @discardableResult
    func createNote() throws -> Doc {
        let id = UUID()
        let directory = folder(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(Self.a4, for: .mediaBox)
        pdf.insert(page, at: 0)
        guard pdf.write(to: pdfURL(for: id)) else {
            try? FileManager.default.removeItem(at: directory)
            throw ImportError.unwritable
        }
        let doc = Doc(id: id, title: Self.freshTitle(taken: docs.map(\.title)), pageCount: 1, addedAt: Date())
        docs.insert(doc, at: 0)
        save()
        return doc
    }

    /// Adds a blank page after page [index], the size and turn of that page. Everything written on later
    /// pages moves along with them. The PDF is written beside itself and swapped in only when that worked.
    func insertBlankPage(in doc: Doc, after index: Int) throws {
        let url = pdfURL(for: doc.id)
        guard let pdf = PDFDocument(url: url), let current = pdf.page(at: index) else { throw ImportError.unreadable }
        let before = pdf.pageCount
        let blank = PDFPage()
        blank.setBounds(current.bounds(for: .mediaBox), for: .mediaBox)
        blank.rotation = current.rotation
        pdf.insert(blank, at: index + 1)
        let edited = folder(for: doc.id).appendingPathComponent("document.edit.pdf")
        try? FileManager.default.removeItem(at: edited)
        guard pdf.write(to: edited) else { throw ImportError.unwritable }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: edited)
        DrawingStore(folder: folder(for: doc.id)).shiftPages(from: index + 1, pageCount: before)
        MathStore(folder: folder(for: doc.id)).shiftPages(from: index + 1)
        QuestionStore(folder: folder(for: doc.id)).shiftPages(from: index + 1)
        if let at = docs.firstIndex(where: { $0.id == doc.id }) {
            docs[at].pageCount = before + 1
            save()
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
