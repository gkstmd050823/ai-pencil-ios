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

/// Files that have come in (picked, or handed over by another app) and wait to be told where to go.
struct IncomingFiles: Identifiable {
    let id = UUID()
    var urls: [URL]
    /// The folder the shelf was showing, offered first.
    var folder: UUID?
    /// Asked for from inside a document, and so most likely meant for it.
    var forDocument = false
}

/// Pages to be put into the document on show. Its own reading screen does it: it has to put away what
/// it holds of the document first.
struct PageAddition: Equatable {
    let id = UUID()
    var doc: UUID
    var urls: [URL]
    /// After the last page when true; after the page being read otherwise.
    var atEnd: Bool
}

enum ImportError: LocalizedError {
    case unreadable
    case unwritable
    case cannotAdd
    /// The file wants a password before it shows anything, and none was given.
    case locked
    case wrongPassword
    /// The password fitted, but no copy that opens without it could be written.
    case cannotUnlock

    var errorDescription: String? {
        switch self {
        case .locked: return "암호가 걸린 PDF예요. 보관함에서 가져오면 암호를 물어봐요."
        case .wrongPassword: return "암호가 맞지 않아요."
        case .cannotUnlock: return "암호는 맞지만 잠금을 푼 사본을 만들지 못했어요."
        case .cannotAdd: return "쪽을 넣지 못했어요. 넣으려는 PDF나 이 문서가 암호로 잠겨 있거나 손상됐을 수 있어요. 새 문서로 가져와 보세요."
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
    /// The documents open as tabs above the pages, in the order they were opened.
    @Published private(set) var tabs: [UUID] = []
    /// Files waiting to be told where to go; while there are some, the question is on screen.
    @Published var incoming: IncomingFiles?
    /// Pages for the document on show, for its reading screen to put in.
    @Published var pagesToAdd: PageAddition?
    /// The document on show in the reading screen, and how to ask it which page is being read. Which
    /// document it is is kept: the app opens on it the next time, unless the shelf was on show.
    @Published var showing: UUID? {
        didSet {
            guard Self.remembers, showing != oldValue else { return }
            if let showing {
                UserDefaults.standard.set(showing.uuidString, forKey: "lastShown")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastShown")
            }
        }
    }

    /// "-noRestore" (every picture the build server takes) has the app open on its shelf and every
    /// document at its first page, whatever was on show the time before.
    static let remembers = !ProcessInfo.processInfo.arguments.contains("-noRestore")

    /// The document that was on show when the app was last seen, if one was and it is still there.
    var lastShown: Doc? {
        guard Self.remembers, let text = UserDefaults.standard.string(forKey: "lastShown"), let id = UUID(uuidString: text) else { return nil }
        return docs.first { $0.id == id }
    }

    /// The page a document was last read at, counted from zero.
    static func lastPage(for id: UUID) -> Int? {
        guard remembers else { return nil }
        return (UserDefaults.standard.dictionary(forKey: "lastPages") as? [String: Int])?[id.uuidString]
    }

    static func notePage(_ page: Int, for id: UUID) {
        guard remembers, page >= 0 else { return }
        var pages = (UserDefaults.standard.dictionary(forKey: "lastPages") as? [String: Int]) ?? [:]
        guard pages[id.uuidString] != page else { return }
        pages[id.uuidString] = page
        UserDefaults.standard.set(pages, forKey: "lastPages")
    }

    private static func forgetPage(of id: UUID) {
        guard var pages = UserDefaults.standard.dictionary(forKey: "lastPages") as? [String: Int], pages[id.uuidString] != nil else { return }
        pages[id.uuidString] = nil
        UserDefaults.standard.set(pages, forKey: "lastPages")
    }
    var pageOnShow: (() -> Int?)?
    /// The folder the shelf is showing, where a file handed over by another app is offered to go.
    var shelfFolder: UUID?
    /// What is being done that the screen has to wait for ("쪽을 넣는 중"); nil when nothing is.
    @Published var working: String?
    /// The page a document is to open at the next time it is opened: where pages were just put into it.
    private static var startPages: [UUID: Int] = [:]

    static func openNext(_ id: UUID, atPage page: Int) {
        startPages[id] = page
    }

    static func startPage(for id: UUID) -> Int? {
        startPages[id]
    }

    static func clearStartPage(for id: UUID) {
        startPages[id] = nil
    }

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
            // (No two with the same identity: a list shown with one in it twice is not safe to show.)
            var seen = Set<UUID>()
            docs = saved.filter { seen.insert($0.id).inserted }
        }
        if let data = try? Data(contentsOf: foldersURL), let saved = try? JSONDecoder().decode([Folder].self, from: data) {
            var seen = Set<UUID>()
            folders = saved.filter { seen.insert($0.id).inserted }
        }
        let open = (UserDefaults.standard.stringArray(forKey: "openTabs") ?? []).compactMap { UUID(uuidString: $0) }
        var seen = Set<UUID>()
        tabs = open.filter { id in docs.contains { $0.id == id } && seen.insert(id).inserted }
    }

    // MARK: tabs

    private func saveTabs() {
        UserDefaults.standard.set(tabs.map(\.uuidString), forKey: "openTabs")
    }

    func openTab(_ id: UUID) {
        guard !tabs.contains(id), docs.contains(where: { $0.id == id }) else { return }
        tabs.append(id)
        saveTabs()
    }

    func closeTab(_ id: UUID) {
        guard tabs.contains(id) else { return }
        tabs.removeAll { $0 == id }
        saveTabs()
    }

    /// Puts documents together into a new one, in the order given: each as it would be exported, with
    /// what was written on it drawn into its pages.
    @MainActor
    func merge(_ parts: [Doc], into place: UUID?) async throws -> Doc {
        guard parts.count > 1 else { throw ImportError.unreadable }
        let id = UUID()
        let target = pdfURL(for: id)
        let sources = parts.map { (pdf: pdfURL(for: $0.id), folder: folder(for: $0.id)) }
        let pages = await Task.detached(priority: .userInitiated) { () -> Int in
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var files: [(url: URL, pages: [Int]?)] = []
            defer { files.forEach { try? FileManager.default.removeItem(at: $0.url) } }
            for (index, source) in sources.enumerated() {
                guard let made = Exporter.export(pdfURL: source.pdf, folder: source.folder, title: "merge-\(index)", withMarks: false) else { return 0 }
                files.append((made, nil))
            }
            guard PDFCopy.write(files, to: target) else { return 0 }
            return PDFDocument(url: target)?.pageCount ?? 0
        }.value
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: folder(for: id))
            throw ImportError.unwritable
        }
        let title = parts.count == 2 ? "\(parts[0].title) + \(parts[1].title)" : "\(parts[0].title) 외 \(parts.count - 1)개"
        return shelve(id, source: target, title: Self.freshTitle(taken: docs.map(\.title), base: title), pages: pages, into: place)
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
    private static func copy(_ source: URL, to target: URL, password: String? = nil) throws -> Int {
        // Files picked from the Files app are only readable between these two calls.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            guard let pdf = PDFDocument(url: target) else { throw ImportError.unreadable }
            if pdf.isLocked {
                // A file that shows nothing without its password (until 0.14.10 it was turned away as
                // one that cannot be read). Everything the app does with a document opens the file as
                // it lies, in a dozen places, and none of them has a password to give. So the password
                // is used once, here, and what is kept is a copy that opens without it. PDFKit cannot
                // write a file that was locked as one that is not locked at all (left to itself it
                // carries the old lock over, and no password fits the copy), so the copy is locked
                // afresh under an owner's password nobody has, with nothing held back: printing,
                // copying and the rest are all allowed, as in the Android app's copy. (0.14.11 kept
                // what the original held back; the user asked for it to be let go here too.) The
                // password itself is kept nowhere and noted nowhere.
                guard let password, !password.isEmpty else { throw ImportError.locked }
                guard pdf.unlock(withPassword: password) else { throw ImportError.wrongPassword }
                let open = directory.appendingPathComponent("unlocked.pdf")
                let options: [PDFDocumentWriteOption: Any] = [
                    .ownerPasswordOption: UUID().uuidString,
                    .accessPermissionsOption: NSNumber(value: Exporter.everything),
                ]
                let pages = pdf.pageCount
                guard pages > 0, pdf.write(to: open, withOptions: options),
                      let check = PDFDocument(url: open), !check.isLocked, check.pageCount == pages else {
                    DebugLog.write("import: the copy without the password does not open; given up")
                    throw ImportError.cannotUnlock
                }
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: open, to: target)
                DebugLog.write("import: a file that wanted a password, kept as a copy that opens without it, \(pages) pages")
                return pages
            }
            guard pdf.pageCount > 0 else { throw ImportError.unreadable }
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
    func bringIn(_ source: URL, into place: UUID? = nil, password: String? = nil, title: String? = nil) async throws -> Doc {
        let id = UUID()
        let target = pdfURL(for: id)
        let pages = try await Task.detached(priority: .userInitiated) {
            try Library.copy(source, to: target, password: password)
        }.value
        return shelve(id, source: source, title: title, pages: pages, into: place)
    }

    /// Where the EPUB a document was made of is kept, taken apart, for reading as it is.
    func bookFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("epub", isDirectory: true)
    }

    /// Keeps the folder an EPUB was taken apart into beside the PDF made of it.
    func keepBook(_ root: URL, for id: UUID) {
        let target = bookFolder(for: id)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: root, to: target)
        } catch {
            DebugLog.write("import: the book itself could not be kept (\(error))")
        }
    }

    /// A name for a new notebook that no document has yet: "새 노트", then "새 노트 2", ...
    static func freshTitle(taken: [String], base: String = "새 노트") -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Makes a notebook of one page of the paper asked for, A4 unless another size is given. (Pages added
    /// to it later are as large as the page they are added after.)
    @discardableResult
    func createNote(in place: UUID? = nil, paper: PaperKind = .blank, size: CGSize = Paper.a4) throws -> Doc {
        let id = UUID()
        let directory = folder(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Paper.data(paper, size: size).write(to: pdfURL(for: id), options: .atomic)
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

    /// Puts the pages of the PDFs at [sources] into [doc] after its page [index] (as shown, counted from
    /// zero), one file after another, and says how many pages went in and how many files could not be
    /// read. Everything written on later pages moves along with them. Nothing of the document may be open
    /// meanwhile: a reading screen puts what it holds away first and opens the document afresh after.
    ///
    /// Unlike a blank page, these pages go into the PDF itself (they are copied in as they are, see
    /// [PDFCopy]); the blank pages listed beside it are renumbered to stand where they stood.
    @MainActor
    func insertPages(from sources: [URL], into doc: Doc, after index: Int) async throws -> (added: Int, failed: Int) {
        let url = pdfURL(for: doc.id)
        let directory = folder(for: doc.id)
        let result = await Task.detached(priority: .userInitiated) { () -> (added: Int, failed: Int) in
            var at = index
            var added = 0
            var failed = 0
            for source in sources {
                // Files picked from the Files app are only readable between these two calls.
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                guard let own = PDFDocument(url: url)?.pageCount, own > 0 else {
                    failed += 1
                    continue
                }
                let list = DocFile.addedPages(of: url)
                let shown = own + list.count
                let place = min(max(at, 0), shown - 1)
                let before = DocFile.ownPages(through: place, added: list, ownCount: own)
                guard let count = PDFCopy.insert(source, into: url, afterPages: before) else {
                    failed += 1
                    continue
                }
                DocFile.replaceAdded(DocFile.relisted(list, ownCount: own, after: place, by: count), of: url)
                DrawingStore(folder: directory).shiftPages(from: place + 1, pageCount: shown, by: count)
                MathStore(folder: directory).shiftPages(from: place + 1, by: count)
                BookmarkStore(folder: directory).shiftPages(from: place + 1, by: count)
                QuestionStore(folder: directory).shiftPages(from: place + 1, by: count)
                DebugLog.write("pages: \(count) put in after page \(place + 1) of \(shown)")
                at = place + count
                added += count
            }
            return (added, failed)
        }.value
        if result.added > 0, let at = docs.firstIndex(where: { $0.id == doc.id }) {
            docs[at].pageCount += result.added
            save()
        }
        guard result.added > 0 else { throw ImportError.cannotAdd }
        return result
    }

    func rename(_ doc: Doc, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let at = docs.firstIndex(where: { $0.id == doc.id }) else { return }
        docs[at].title = name
        save()
    }

    func delete(_ doc: Doc) {
        closeTab(doc.id)
        Self.forgetPage(of: doc.id)
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
