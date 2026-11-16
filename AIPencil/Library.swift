import Foundation
import PDFKit
import UIKit

/// One document on the shelf.
struct Doc: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
    /// The folder the document is in; nil when it lies on the shelf itself.
    var folder: UUID?
    var openedAt: Date?
    /// For a notebook, the paper its pages are made of; pages added later are of the same.
    var paper: PaperKind?
}

/// A folder on the shelf. Folders hold documents, not other folders.
struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
}

enum ImportError: LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "이 파일은 열 수 없어요. 손상됐거나 암호가 걸린 PDF일 수 있어요."
        case .unwritable: return "저장하지 못했어요. 아이패드에 남은 공간이 있는지 확인해 주세요."
        }
    }
}

/// The documents kept by the app. Each one has a folder of its own under Documents/docs holding a copy of
/// the PDF, a list of the pages added to it, the handwriting of every page, its typed formulas and the
/// questions asked about it. Used from the main thread only.
final class Library: ObservableObject {
    @Published private(set) var docs: [Doc] = []
    @Published private(set) var folders: [Folder] = []

    private let root: URL
    /// The covers already read or drawn since the app started.
    private let covers = NSCache<NSString, UIImage>()
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var foldersURL: URL { root.appendingPathComponent("folders.json") }

    /// A4 in points, the size of a new notebook's pages.
    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("docs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let saved = try? JSONDecoder().decode([Doc].self, from: data) {
            docs = saved
        }
        if let data = try? Data(contentsOf: foldersURL), let saved = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = saved
        }
    }

    /// The documents to show: those in [folder], or, when something is being looked for, the ones in
    /// any folder whose name has it.
    func documents(in folder: UUID?, sort: LibrarySort, matching search: String) -> [Doc] {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        let found = wanted.isEmpty
            ? docs.filter { $0.folder == folder }
            : docs.filter { $0.title.localizedCaseInsensitiveContains(wanted) && (folder == nil || $0.folder == folder) }
        switch sort {
        case .recent: return found.sorted { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }
        case .name: return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: return found.sorted { $0.addedAt > $1.addedAt }
        }
    }

    @discardableResult
    func createFolder(named name: String) -> Folder {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: Self.freshTitle(taken: folders.map(\.name), base: wanted.isEmpty ? "새 폴더" : wanted))
        folders.append(folder)
        saveFolders()
        return folder
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, let at = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[at].name = wanted
        saveFolders()
    }

    /// Takes the folder away. What was in it is not deleted: it goes back on the shelf.
    func deleteFolder(_ folder: Folder) {
        for at in docs.indices where docs[at].folder == folder.id {
            docs[at].folder = nil
        }
        folders.removeAll { $0.id == folder.id }
        save()
        saveFolders()
    }

    func move(_ doc: Doc, to folder: UUID?) {
        guard let at = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        docs[at].folder = folder
        save()
    }

    /// Notes that the document was opened just now, for the "recently opened" order.
    func touch(_ doc: Doc) {
        guard let at = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        docs[at].openedAt = Date()
        save()
    }

    private func saveFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }

    func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func pdfURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("document.pdf")
    }

    /// Copies a PDF to [target] in a new folder and counts its pages. Run off the main thread: a large
    /// file, or one that has to come down from iCloud first, takes a while.
    private static func copy(_ source: URL, to target: URL) throws -> Int {
        // Files picked from the Files app are only readable between these two calls.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            guard let pdf = PDFDocument(url: target), pdf.pageCount > 0 else { throw ImportError.unreadable }
            return pdf.pageCount
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func shelve(_ id: UUID, source: URL, title: String?, pages: Int, into place: UUID?) -> Doc {
        let name = title ?? source.deletingPathExtension().lastPathComponent
        let doc = Doc(id: id, title: name, pageCount: pages, addedAt: Date(), folder: place)
        docs.insert(doc, at: 0)
        save()
        return doc
    }

    /// Copies the PDF into the app, so it still opens after the original is moved or deleted.
    @discardableResult
    func importPDF(from source: URL, title: String? = nil, into place: UUID? = nil) throws -> Doc {
        let id = UUID()
        let pages = try Library.copy(source, to: pdfURL(for: id))
        return shelve(id, source: source, title: title, pages: pages, into: place)
    }

    /// The same without holding the screen still while the file is copied.
    @MainActor
    func bringIn(_ source: URL, into place: UUID? = nil) async throws -> Doc {
        let id = UUID()
        let target = pdfURL(for: id)
        let pages = try await Task.detached(priority: .userInitiated) {
            try Library.copy(source, to: target)
        }.value
        return shelve(id, source: source, title: nil, pages: pages, into: place)
    }

    /// A name for a new notebook that no document has yet: "새 노트", then "새 노트 2", ...
    static func freshTitle(taken: [String], base: String = "새 노트") -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Makes a notebook of one A4 page of the paper asked for.
    @discardableResult
    func createNote(in place: UUID? = nil, paper: PaperKind = .blank) throws -> Doc {
        let id = UUID()
        let directory = folder(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Paper.data(paper).write(to: pdfURL(for: id), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ImportError.unwritable
        }
        let doc = Doc(id: id, title: Self.freshTitle(taken: docs.map(\.title)), pageCount: 1, addedAt: Date(), folder: place, paper: paper)
        docs.insert(doc, at: 0)
        save()
        return doc
    }

    /// Adds a page after page [index], as large as that page is shown. Everything written on later pages
    /// moves along with them. The PDF itself is left as it is: the new page goes on the list kept beside it.
    func insertBlankPage(in doc: Doc, after index: Int, paper: PaperKind = .blank) throws {
        let url = pdfURL(for: doc.id)
        guard let pdf = DocFile.open(url), let current = pdf.page(at: index) else { throw ImportError.unreadable }
        let before = pdf.pageCount
        // A page shown turned by a quarter is as wide as its own height.
        let crop = current.bounds(for: .cropBox).size
        let sideways = (current.rotation / 90) % 2 != 0
        let shown = sideways ? CGSize(width: crop.height, height: crop.width) : crop
        do {
            try DocFile.add(AddedPage(index: index + 1, paper: paper, width: shown.width, height: shown.height), to: url)
        } catch {
            throw ImportError.unwritable
        }
        DrawingStore(folder: folder(for: doc.id)).shiftPages(from: index + 1, pageCount: before)
        MathStore(folder: folder(for: doc.id)).shiftPages(from: index + 1)
        BookmarkStore(folder: folder(for: doc.id)).shiftPages(from: index + 1)
        QuestionStore(folder: folder(for: doc.id)).shiftPages(from: index + 1)
        if let at = docs.firstIndex(where: { $0.id == doc.id }) {
            docs[at].pageCount = before + 1
            save()
        }
    }

    func rename(_ doc: Doc, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let at = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        docs[at].title = name
        save()
    }

    func delete(_ doc: Doc) {
        docs.removeAll { $0.id == doc.id }
        try? FileManager.default.removeItem(at: folder(for: doc.id))
        save()
    }

    /// The first page as a picture [width] pixels wide, for the shelf. It is drawn once, off the main
    /// thread, and kept beside the document: the first page of a document never changes, and opening
    /// every document to draw its cover each time the shelf is shown made the shelf slow to appear.
    @MainActor
    func cover(for doc: Doc, width: CGFloat) async -> UIImage? {
        let key = doc.id.uuidString as NSString
        if let kept = covers.object(forKey: key) { return kept }
        let pdf = pdfURL(for: doc.id)
        let file = folder(for: doc.id).appendingPathComponent("cover.jpg")
        let picture = await Task.detached(priority: .utility) { () -> UIImage? in
            if let data = try? Data(contentsOf: file), let saved = UIImage(data: data) { return saved }
            guard let page = DocFile.open(pdf)?.page(at: 0) else { return nil }
            let shown = AskCapture.shape(of: page).size
            let size = CGSize(width: width, height: width * shown.height / max(shown.width, 1))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let made = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                page.thumbnail(of: size, for: .cropBox).draw(in: CGRect(origin: .zero, size: size))
            }
            try? made.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
            return made
        }.value
        if let picture { covers.setObject(picture, forKey: key) }
        return picture
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(docs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
