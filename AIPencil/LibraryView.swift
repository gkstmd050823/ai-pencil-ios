import SwiftUI
import UniformTypeIdentifiers

/// The shelf: folders and documents, and the ways to get more.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var path = NavigationPath()
    @State private var errorText: String?
    @State private var ranDemo = false
    /// Files brought in that want a password, still to be asked about, and where they are to go.
    @State private var lockedFiles: [URL] = []
    @State private var lockedPlace: UUID?
    @State private var lockedWrong = false
    @State private var askingPassword = false
    @State private var passwordText = ""

    var body: some View {
        NavigationStack(path: $path) {
            Shelf(path: $path)
                .navigationDestination(for: Doc.self) { doc in
                    ReaderHost(first: doc)
                }
        }
        // A PDF handed over by another app ("open in", share sheet): asked about like one that was picked,
        // whatever is on screen.
        .onOpenURL { url in
            Diagnostics.shared.step("handed a file")
            library.incoming = IncomingFiles(urls: [url], folder: library.shelfFolder)
        }
        .sheet(item: $library.incoming) { files in
            ImportSheet(files: files) { place in
                bringIn(files.urls, into: place)
            } onAdd: { doc, atEnd in
                asPDFs(files.urls) { addPages($0, to: doc, atEnd: atEnd) }
            }
        }
        // While files are copied or pages put in, nothing else is to be touched: a page written on meanwhile
        // would be written on a document that is about to be opened afresh.
        .overlay {
            if let working = library.working {
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(working)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                }
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .alert(lockedWrong ? "암호가 맞지 않아요" : "암호가 걸린 PDF예요", isPresented: $askingPassword) {
            SecureField("암호", text: $passwordText)
            Button("취소", role: .cancel) { skipLocked() }
            Button("열기") { openLocked() }
        } message: {
            Text(lockedHint)
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-selfCheck") { SelfCheck.run() }
            if ProcessInfo.processInfo.arguments.contains("-convertCheck") { Converter.check() }
            runDemoIfAsked()
        }
    }

    /// Each file becomes a document in [place]. One file opens straight away; several stay on the shelf.
    private func bringIn(_ urls: [URL], into place: UUID?) {
        guard !urls.isEmpty, library.working == nil else { return }
        library.working = urls.count > 1 ? "PDF \(urls.count)개를 준비하는 중" : "PDF를 준비하는 중"
        let reading = library.showing != nil
        Task { @MainActor in
            var last: Doc?
            for url in urls {
                do {
                    if let kind = ForeignKind.of(url) {
                        last = try await converted(url, kind: kind, into: place)
                    } else {
                        last = try await library.bringIn(url, into: place)
                    }
                } catch ImportError.locked {
                    // (Asked about once the others are in.)
                    lockedFiles.append(url)
                    lockedPlace = place
                } catch {
                    errorText = error.localizedDescription
                }
            }
            library.working = nil
            if urls.count == 1, let doc = last {
                // (In place of a document that is on show; on top of the shelf otherwise, folder and all.)
                if reading { path = NavigationPath() }
                path.append(doc)
            }
            if !lockedFiles.isEmpty {
                lockedWrong = false
                passwordText = ""
                askingPassword = true
            }
        }
    }

    private var lockedHint: String {
        let name = lockedFiles.first?.deletingPathExtension().lastPathComponent ?? ""
        return "\(name)\n암호를 넣으면 잠금을 푼 사본을 앱 안에 보관해요. 암호는 저장하지 않아요."
    }

    /// The file being asked about is left out; the next one, if there is one, is asked about.
    private func skipLocked() {
        passwordText = ""
        lockedWrong = false
        if !lockedFiles.isEmpty { lockedFiles.removeFirst() }
        askNextLocked()
    }

    private func askNextLocked() {
        guard !lockedFiles.isEmpty else { return }
        // (A moment later: the sheet that has just gone must be gone before the next comes up.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { askingPassword = true }
    }

    private func openLocked() {
        guard let url = lockedFiles.first, library.working == nil else { return }
        let password = passwordText
        passwordText = ""
        let place = lockedPlace
        let reading = library.showing != nil
        library.working = "PDF를 준비하는 중"
        Task { @MainActor in
            var made: Doc?
            do {
                made = try await library.bringIn(url, into: place, password: password)
                lockedWrong = false
                lockedFiles.removeFirst()
            } catch ImportError.wrongPassword {
                lockedWrong = true
            } catch ImportError.locked {
                // (Nothing was typed.)
                lockedWrong = true
            } catch {
                errorText = error.localizedDescription
                lockedWrong = false
                lockedFiles.removeFirst()
            }
            library.working = nil
            if lockedFiles.isEmpty {
                if let doc = made {
                    if reading { path = NavigationPath() }
                    path.append(doc)
                }
            } else {
                askNextLocked()
            }
        }
    }

    /// A Word, PowerPoint or Excel file or an EPUB becomes a document: a PDF is made of it and brought
    /// in like any other. An EPUB is kept as well, to be read as it is from inside the document.
    @MainActor
    private func converted(_ url: URL, kind: ForeignKind, into place: UUID?) async throws -> Doc {
        Diagnostics.shared.step("making a PDF of a file")
        library.working = "PDF로 바꾸는 중"
        let name = url.deletingPathExtension().lastPathComponent
        let copy = try await Task.detached(priority: .userInitiated) { try Converter.borrow(url) }.value
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let made = try await Converter.convert(copy, kind: kind, name: name) { step in
            library.working = "PDF로 바꾸는 중 \(step)"
        }
        let doc = try await library.bringIn(made.pdf, into: place, title: made.title)
        if let book = made.book { library.keepBook(book, for: doc.id) }
        return doc
    }

    /// Hands on the files with those that are not PDFs made into PDFs. (The PDFs made lie in the
    /// temporary folder, which the system empties.)
    private func asPDFs(_ urls: [URL], then go: @escaping ([URL]) -> Void) {
        guard urls.contains(where: { ForeignKind.of($0) != nil }) else {
            go(urls)
            return
        }
        guard library.working == nil else { return }
        library.working = "PDF로 바꾸는 중"
        Task { @MainActor in
            var ready: [URL] = []
            for url in urls {
                guard let kind = ForeignKind.of(url) else {
                    ready.append(url)
                    continue
                }
                do {
                    let copy = try await Task.detached(priority: .userInitiated) { try Converter.borrow(url) }.value
                    let made = try await Converter.convert(copy, kind: kind, name: url.deletingPathExtension().lastPathComponent)
                    ready.append(made.pdf)
                } catch {
                    errorText = error.localizedDescription
                }
            }
            library.working = nil
            if !ready.isEmpty { go(ready) }
        }
    }

    /// The files' pages go into a document that is open. The one on show does it itself, having put its
    /// own things away; any other has nothing open, is added to here, and is then shown.
    private func addPages(_ urls: [URL], to doc: Doc, atEnd: Bool) {
        guard !urls.isEmpty, library.working == nil else { return }
        if doc.id == library.showing {
            library.pagesToAdd = PageAddition(doc: doc.id, urls: urls, atEnd: atEnd)
            return
        }
        library.working = "쪽을 넣는 중"
        let reading = library.showing != nil
        Task { @MainActor in
            do {
                let last = max(doc.pageCount - 1, 0)
                let result = try await library.insertPages(from: urls, into: doc, after: last)
                if result.failed > 0 { errorText = "\(result.failed)개 파일은 넣지 못했어요." }
                Library.openNext(doc.id, atPage: last + 1)
                if let now = library.docs.first(where: { $0.id == doc.id }) {
                    if reading { path = NavigationPath() }
                    path.append(now)
                }
            } catch {
                errorText = error.localizedDescription
            }
            library.working = nil
        }
    }

    /// The build server starts the app with these to take pictures without anyone tapping: "-sample" opens
    /// the bundled sample (imported once), "-demoNote" makes a blank notebook and opens it, "-demoImport
    /// name.pdf" opens a file the server put in the app's Documents folder, "-demoShelf" fills the shelf
    /// with a folder and a notebook in it.
    private func runDemoIfAsked() {
        guard !ranDemo, path.isEmpty else { return }
        ranDemo = true
        let arguments = ProcessInfo.processInfo.arguments
        // ("-demoIncoming name.pdf": as if that file of the app's Documents folder had been handed over by
        // another app; with "-demoIncomingFor YES", as if it had been picked from inside the document on show.)
        if let name = UserDefaults.standard.string(forKey: "demoIncoming") {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            let inside = UserDefaults.standard.bool(forKey: "demoIncomingFor")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                library.incoming = IncomingFiles(urls: [file], folder: library.shelfFolder, forDocument: inside)
            }
        }
        if arguments.contains("-sample") {
            if let existing = library.docs.first(where: { $0.title == "샘플" }) {
                path.append(existing)
            } else if let url = Bundle.main.url(forResource: "Sample", withExtension: "pdf"),
                      let doc = try? library.importPDF(from: url, title: "샘플") {
                path.append(doc)
            }
        } else if arguments.contains("-demoNote") {
            let defaults = UserDefaults.standard
            let paper = PaperKind(rawValue: defaults.string(forKey: "demoPaper") ?? "") ?? .blank
            // ("-demoPaperSize a5 -demoLandscape YES" for another size of paper.)
            let size = (PaperSize(rawValue: defaults.string(forKey: "demoPaperSize") ?? "") ?? .a4).points(landscape: defaults.bool(forKey: "demoLandscape"))
            if let note = try? library.createNote(paper: paper, size: size) { path.append(note) }
        } else if let name = UserDefaults.standard.string(forKey: "demoImport") {
            let title = (name as NSString).deletingPathExtension
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let existing = library.docs.first(where: { $0.title == title }) {
                path.append(existing)
            } else if let doc = try? library.importPDF(from: documents.appendingPathComponent(name), title: title) {
                path.append(doc)
            }
        } else if arguments.contains("-demoShelf") {
            if library.folders.isEmpty {
                let folder = library.createFolder(named: "1학기 수업")
                _ = try? library.createNote(in: folder.id)
                if let tricky = library.docs.first(where: { $0.title == "tricky" }) {
                    library.move(tricky, to: folder.id)
                }
            }
        } else if let doc = library.lastShown {
            // The document that was being read when the app was last seen, at the page it was at.
            Diagnostics.shared.step("back to the document last read")
            path.append(doc)
        }
    }
}

/// How the shelf is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, added

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "최근 연 순"
        case .name: return "이름순"
        case .added: return "추가한 순"
        }
    }
}

/// The colours of the app's own surfaces: paper tones in the light, a step or two up from black in the dark.
/// Black (in the dark, its opposite) is kept for one thing at a time: the place chosen, the button that adds.
enum Tone {
    static func shade(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }

    static let page = shade(0xECEAE5, 0x1C1C1E)
    static let side = shade(0xE2E0DA, 0x242426)
    static let card = shade(0xFFFFFF, 0x2C2C2F)
    static let line = shade(0xD6D4CD, 0x3A3A3E)
    static let chip = shade(0xDEDCD6, 0x38383C)
    static let ink = shade(0x17181A, 0xF1F1EF)
    static let onInk = shade(0xFFFFFF, 0x17181A)
    /// The bar the reading screen's tabs stand on, and the tab of the document on show.
    static let bar = shade(0xDEDCD6, 0x2C2C2F)
    static let tabOn = shade(0xF2F2F7, 0x4A4A4F)
    /// The tool bar afloat over the pages: black, whatever the light.
    static let pill = Color(red: 0.055, green: 0.055, blue: 0.063)

    /// How long ago, in Korean whatever language the iPad is set to (the app's own words are Korean, and
    /// "1 minute ago" stood among them).
    static func ago(_ date: Date) -> String {
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: Locale(identifier: "ko_KR"))
        return style.format(date)
    }
}

/// What the shelf is showing: every document, a sorting of them, or what is in one folder.
private enum ShelfPlace: Hashable {
    case home, all, recent, asked
    case folder(UUID)
}

/// The shelf: a list of places down its left side (every document, the ones read lately, the ones asked
/// about, each folder), and beside it the documents of the place chosen, their first pages large.
/// (Until 0.14.13 the folders were cards among the documents and were gone into like a document; they
/// were awkward to get to.)
private struct Shelf: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var library: Library
    @AppStorage("librarySort") private var sort = LibrarySort.recent
    @State private var place = ShelfPlace.home
    @State private var search = ""
    @State private var importing = false
    @State private var showingSettings = false
    @State private var errorText: String?
    @State private var renamingDoc: Doc?
    @State private var renamingFolder: Folder?
    @State private var makingFolder = false
    @State private var deletingDoc: Doc?
    @State private var deletingFolder: Folder?
    @State private var newName = ""
    @State private var choosingPaper = false
    @State private var ranDemo = false
    /// The document that others are being picked to be put together with.
    @State private var mergingFrom: Doc?
    /// Picking several documents at once, and the ones picked.
    @State private var selecting = false
    @State private var picked: Set<UUID> = []
    @State private var deletingPicked = false
    /// How many files are still being copied in.
    @State private var bringingIn = 0
    /// How many questions each document has, counted when the shelf comes up.
    @State private var asked: [UUID: Int] = [:]
    @State private var askedStamp = 0

    /// The folder being shown, when it is a folder that is.
    private var folder: Folder? {
        guard case .folder(let id) = place else { return nil }
        return library.folders.first { $0.id == id }
    }

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var docs: [Doc] {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        var found: [Doc]
        switch place {
        // Home shows only what is in no folder (a search there looks through everything).
        case .home: found = wanted.isEmpty ? library.docs.filter { $0.folder == nil } : library.docs
        case .all: found = library.docs
        case .recent: found = library.docs.filter { $0.openedAt != nil }
        case .asked: found = library.docs.filter { (asked[$0.id] ?? 0) > 0 }
        case .folder(let id): found = library.docs.filter { $0.folder == id }
        }
        if !wanted.isEmpty {
            found = found.filter { $0.title.localizedCaseInsensitiveContains(wanted) }
        }
        let order = place == .recent ? LibrarySort.recent : sort
        switch order {
        case .recent: return found.sorted { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }
        case .name: return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .added: return found.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private var title: String {
        switch place {
        case .home: return "홈"
        case .all: return "모든 문서"
        case .recent: return "최근 본 문서"
        case .asked: return "질문한 문서"
        case .folder: return folder?.name ?? "폴더"
        }
    }

    /// The documents last read, for the row at the top of home.
    private var lately: [Doc] {
        guard place == .home, !searching, !selecting else { return [] }
        let read = library.docs.filter { $0.openedAt != nil }
        return Array(read.sorted { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }.prefix(3))
    }

    var body: some View {
        GeometryReader { space in
            let narrow = space.size.width < 640
            HStack(spacing: 0) {
                if !narrow {
                    sidebar
                        .frame(width: space.size.width < 900 ? 232 : 280)
                }
                VStack(spacing: 0) {
                    header(narrow: narrow)
                    if docs.isEmpty && lately.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
            }
        }
        .background(Tone.page.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing, allowedContentTypes: ForeignKind.pickable, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                // Where they go is asked next, with this folder offered first. (A moment later: the file
                // picker is still on its way out, and a sheet put up meanwhile does not come up.)
                let place = folder?.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    library.incoming = IncomingFiles(urls: urls, folder: place)
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .overlay {
            if bringingIn > 0 {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(bringingIn > 1 ? "PDF \(bringingIn)개를 준비하는 중" : "PDF를 준비하는 중")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $choosingPaper) {
            PaperSheet { paper, size in
                newNote(paper, size)
            }
        }
        .sheet(item: $mergingFrom) { first in
            MergeSheet(first: first, others: library.docs.filter { $0.id != first.id }) { parts in
                merge(parts)
            }
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renamingDoc != nil || renamingFolder != nil }, set: { if !$0 { renamingDoc = nil; renamingFolder = nil } })) {
            TextField("이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("바꾸기") {
                if let doc = renamingDoc { library.rename(doc, to: newName) }
                if let item = renamingFolder { library.renameFolder(item, to: newName) }
            }
        }
        .alert("새 폴더", isPresented: $makingFolder) {
            TextField("폴더 이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                let made = library.createFolder(named: newName)
                place = .folder(made.id)
            }
        }
        .confirmationDialog(
            deleteDocTitle,
            isPresented: Binding(get: { deletingDoc != nil }, set: { if !$0 { deletingDoc = nil } }), titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let doc = deletingDoc { library.delete(doc) }
            }
        }
        .confirmationDialog(
            deleteFolderTitle,
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible
        ) {
            Button("폴더 삭제", role: .destructive) {
                if let item = deletingFolder {
                    if place == .folder(item.id) { place = .home }
                    library.deleteFolder(item)
                }
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            // "-demoSettings" shows the settings for the build server's picture.
            if !ranDemo, ProcessInfo.processInfo.arguments.contains("-demoSettings") {
                showingSettings = true
            }
            if !ranDemo, ProcessInfo.processInfo.arguments.contains("-demoPapers") {
                choosingPaper = true
            }
            if !ranDemo, ProcessInfo.processInfo.arguments.contains("-demoMerge"), library.docs.count > 1 {
                // (For the build server: the two newest documents put together.)
                merge(Array(library.docs.prefix(2)))
            }
            ranDemo = true
            library.shelfFolder = folder?.id
            askedStamp += 1
            Diagnostics.shared.step("shelf shown, \(library.docs.count) documents")
        }
        .onChange(of: place) {
            library.shelfFolder = folder?.id
            selecting = false
            picked = []
        }
        .task(id: askedStamp) {
            // (A look into each document's folder for the files its questions are kept in; nothing is read.)
            let folders = library.docs.map { ($0.id, library.folder(for: $0.id)) }
            let counted = await Task.detached(priority: .utility) { () -> [UUID: Int] in
                var out: [UUID: Int] = [:]
                for (id, url) in folders {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                    let count = names.filter { $0.hasPrefix("qa-") && $0.hasSuffix(".json") && !$0.hasSuffix(".messages.json") }.count
                    if count > 0 { out[id] = count }
                }
                return out
            }.value
            asked = counted
        }
    }

    // MARK: the list of places

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("AI 펜슬")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("설정")
                }
                .foregroundStyle(.primary)
                .padding(.leading, 12)
                .frame(height: 56)

                sideRow(.home, "house", "홈", count: nil)
                    .dropDestination(for: String.self) { dragged, _ in
                        drop(dragged, into: nil)
                    }
                sideRow(.all, "doc.on.doc", "모든 문서", count: library.docs.count)
                    // (A document dragged here is taken out of its folder.)
                    .dropDestination(for: String.self) { dragged, _ in
                        drop(dragged, into: nil)
                    }
                sideRow(.recent, "clock", "최근 본 문서", count: nil)
                sideRow(.asked, "pencil.tip.crop.circle", "질문한 문서", count: asked.isEmpty ? nil : asked.count)

                Text("폴더")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                ForEach(library.folders) { item in
                    sideRow(.folder(item.id), "folder", item.name, count: count(in: item))
                        // A document dragged onto a folder goes into it.
                        .dropDestination(for: String.self) { dragged, _ in
                            drop(dragged, into: item.id)
                        }
                        .contextMenu {
                            Button {
                                newName = item.name
                                renamingFolder = item
                            } label: {
                                Label("이름 바꾸기", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingFolder = item
                            } label: {
                                Label("폴더 삭제", systemImage: "trash")
                            }
                        }
                }
                Button {
                    newName = ""
                    makingFolder = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 17))
                            .frame(width: 24)
                        Text("새 폴더")
                            .font(.system(size: 15))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Tone.side.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Tone.line)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private func sideRow(_ spot: ShelfPlace, _ symbol: String, _ name: String, count: Int?) -> some View {
        let chosen = place == spot
        return Button {
            place = spot
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 24)
                Text(name)
                    .font(.system(size: 15, weight: chosen ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 13).monospacedDigit())
                        .opacity(0.7)
                }
            }
            .foregroundStyle(chosen ? Tone.onInk : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(chosen ? Tone.ink : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: the top of the documents

    private func header(narrow: Bool) -> some View {
        HStack(spacing: 10) {
            if narrow {
                // No room for the list: the places are a menu.
                Menu {
                    Button("홈") { place = .home }
                    Button("모든 문서") { place = .all }
                    Button("최근 본 문서") { place = .recent }
                    Button("질문한 문서") { place = .asked }
                    ForEach(library.folders) { item in
                        Button {
                            place = .folder(item.id)
                        } label: {
                            Label(item.name, systemImage: "folder")
                        }
                    }
                    Divider()
                    Button("설정") { showingSettings = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 19))
                        .frame(width: 40, height: 40)
                }
            }
            Text(title)
                .font(.system(size: narrow ? 22 : 30, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if selecting {
                Button(picked.count == docs.count ? "선택 해제" : "전체 선택") {
                    picked = picked.count == docs.count ? [] : Set(docs.map(\.id))
                }
                Button("완료") {
                    selecting = false
                    picked = []
                }
                .fontWeight(.semibold)
            } else {
                searchField
                Menu {
                    Picker("정렬", selection: $sort) {
                        ForEach(LibrarySort.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("정렬")
                if !docs.isEmpty {
                    Button {
                        selecting = true
                        picked = []
                        Diagnostics.shared.step("picking documents")
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 19))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("여러 개 선택")
                }
                addMenu
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, narrow ? 16 : 36)
        .frame(height: 64)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("문서 찾기", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("찾는 말 지우기")
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .frame(maxWidth: 280)
        .background(Tone.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var addMenu: some View {
        Menu {
            Button {
                importing = true
            } label: {
                Label("파일 가져오기", systemImage: "square.and.arrow.down")
            }
            Button {
                choosingPaper = true
            } label: {
                Label("새 노트 만들기", systemImage: "doc.badge.plus")
            }
            Button {
                newName = ""
                makingFolder = true
            } label: {
                Label("새 폴더", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("추가")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Tone.onInk)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Tone.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel("추가")
    }

    // MARK: the documents

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !lately.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        heading("이어서 보기", count: nil)
                        HStack(spacing: 14) {
                            ForEach(lately) { doc in
                                NavigationLink(value: doc) {
                                    RecentCard(doc: doc)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !docs.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        heading(gridTitle, count: docs.count)
                        ShelfGrid(minimum: 138, maximum: 172, spacing: 22, rowSpacing: 22) {
                            ForEach(docs) { doc in
                                docCell(doc)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 10)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { pickedBar }
        }
        .confirmationDialog(
            "고른 문서 \(picked.count)개를 지울까요? 필기와 설명도 함께 지워져요.",
            isPresented: $deletingPicked, titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                for doc in library.docs where picked.contains(doc.id) { library.delete(doc) }
                selecting = false
                picked = []
            }
        }
    }

    private var gridTitle: String {
        if searching { return "찾은 문서" }
        return place == .home ? "폴더에 넣지 않은 문서" : "문서"
    }

    /// A document on the shelf: a way into it, or, while several are being picked, something to pick.
    @ViewBuilder
    private func docCell(_ doc: Doc) -> some View {
        if selecting {
            Button {
                if picked.contains(doc.id) {
                    picked.remove(doc.id)
                } else {
                    picked.insert(doc.id)
                }
            } label: {
                DocCard(doc: doc, folderName: folderName(for: doc), mark: picked.contains(doc.id), asked: asked[doc.id] ?? 0)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: doc) {
                DocCard(doc: doc, folderName: folderName(for: doc), asked: asked[doc.id] ?? 0)
            }
            .buttonStyle(.plain)
            .contextMenu { docMenu(doc) }
            // Dragged onto a folder, it goes into the folder.
            .draggable(doc.id.uuidString)
        }
    }

    /// Moves the documents dragged here (by their identities) into a folder, or out of every folder.
    private func drop(_ dragged: [String], into place: UUID?) -> Bool {
        var moved = false
        for text in dragged {
            guard let id = UUID(uuidString: text), let doc = library.docs.first(where: { $0.id == id }), doc.folder != place else { continue }
            library.move(doc, to: place)
            moved = true
        }
        if moved { Diagnostics.shared.step("document dragged to a folder") }
        return moved
    }

    /// What can be done with the documents picked.
    private var pickedBar: some View {
        let chosen = docs.filter { picked.contains($0.id) }
        return HStack(spacing: 18) {
            Text(chosen.isEmpty ? "문서를 눌러 고르세요" : "\(chosen.count)개 선택")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                if chosen.contains(where: { $0.folder != nil }) {
                    Button {
                        for doc in chosen { library.move(doc, to: nil) }
                        selecting = false
                        picked = []
                    } label: {
                        Label("폴더 밖으로", systemImage: "tray.and.arrow.up")
                    }
                }
                ForEach(library.folders) { item in
                    Button {
                        for doc in chosen { library.move(doc, to: item.id) }
                        selecting = false
                        picked = []
                    } label: {
                        Label(item.name, systemImage: "folder")
                    }
                }
            } label: {
                Label("폴더로 이동", systemImage: "folder")
            }
            .disabled(chosen.isEmpty || (library.folders.isEmpty && !chosen.contains(where: { $0.folder != nil })))
            Button {
                selecting = false
                picked = []
                merge(chosen)
            } label: {
                Label("합치기", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(chosen.count < 2)
            Button(role: .destructive) {
                deletingPicked = true
            } label: {
                Label("삭제", systemImage: "trash")
            }
            .disabled(chosen.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            if let count {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The ways to get a document, as large buttons at the top of the shelf.
    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickAction(symbol: "square.and.pencil", title: "새 노트") {
                choosingPaper = true
            }
            QuickAction(symbol: "arrow.down.doc", title: "파일 가져오기") {
                importing = true
            }
            if folder == nil {
                QuickAction(symbol: "folder.badge.plus", title: "새 폴더") {
                    newName = ""
                    makingFolder = true
                }
            } else {
                // In a folder: a place to drag a document to, to take it out of the folder.
                QuickAction(symbol: "tray.and.arrow.up", title: "폴더 밖으로", detail: "문서를 여기로 끌어다 놓아요", dashed: true) {}
                    .dropDestination(for: String.self) { dragged, _ in
                        drop(dragged, into: nil)
                    }
            }
            Spacer(minLength: 0)
        }
    }

    private var deleteDocTitle: String {
        let name = deletingDoc?.title ?? ""
        return "\"" + name + "\" 문서를 지울까요? 필기와 설명도 함께 지워져요."
    }

    private var deleteFolderTitle: String {
        let name = deletingFolder?.name ?? ""
        return "\"" + name + "\" 폴더를 지울까요? 안에 있던 문서는 지워지지 않고 폴더 밖으로 나와요."
    }

    private func count(in item: Folder) -> Int {
        library.docs.filter { $0.folder == item.id }.count
    }

    /// The folder a document lives in, to show under its name wherever documents of every folder are shown.
    private func folderName(for doc: Doc) -> String? {
        if case .folder = place { return nil }
        guard let id = doc.folder else { return nil }
        return library.folders.first { $0.id == id }?.name
    }

    @ViewBuilder
    private func docMenu(_ doc: Doc) -> some View {
        Button {
            newName = doc.title
            renamingDoc = doc
        } label: {
            Label("이름 바꾸기", systemImage: "pencil")
        }
        Button {
            selecting = true
            picked = [doc.id]
        } label: {
            Label("여러 개 선택", systemImage: "checkmark.circle")
        }
        if library.docs.count > 1 {
            Button {
                mergingFrom = doc
            } label: {
                Label("다른 문서와 합치기", systemImage: "rectangle.stack.badge.plus")
            }
        }
        if !library.folders.isEmpty {
            Menu {
                if doc.folder != nil {
                    Button {
                        library.move(doc, to: nil)
                    } label: {
                        Label("폴더 밖으로", systemImage: "tray.and.arrow.up")
                    }
                }
                ForEach(library.folders.filter { $0.id != doc.folder }) { item in
                    Button {
                        library.move(doc, to: item.id)
                    } label: {
                        Label(item.name, systemImage: "folder")
                    }
                }
            } label: {
                Label("폴더로 옮기기", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            deletingDoc = doc
        } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if searching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("\"\(search)\"에 맞는 문서가 없어요")
                    .font(.headline)
            } else if place == .recent || place == .asked {
                Image(systemName: place == .recent ? "clock" : "pencil.tip.crop.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text(place == .recent ? "아직 연 문서가 없어요" : "아직 질문한 문서가 없어요")
                    .font(.title3.bold())
            } else if folder != nil {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("빈 폴더예요")
                    .font(.title3.bold())
                Text("오른쪽 위 +로 문서를 가져오거나, 서재에서 문서를 길게 눌러 이 폴더로 옮겨 보세요.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !library.docs.isEmpty {
                // Home, with every document in a folder and none read yet.
                Image(systemName: "folder")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("문서는 모두 폴더 안에 있어요")
                    .font(.title3.bold())
                Text("왼쪽에서 폴더를 고르거나 \"모든 문서\"를 눌러 보세요.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("읽다가 막히면 동그라미")
                    .font(.title2.bold())
                Text("PDF를 가져와 필기하다가, 모르는 부분에 AI 펜으로 동그라미를 치면 바로 설명해 줘요.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    importing = true
                } label: {
                    Label("파일 가져오기", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                Button("새 노트 만들기") { choosingPaper = true }
            }
        }
        .padding(36)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Puts documents together into a new one and opens it.
    private func merge(_ parts: [Doc]) {
        guard parts.count > 1 else { return }
        let place = folder?.id
        bringingIn += 1
        Diagnostics.shared.step("merging \(parts.count) documents")
        Task { @MainActor in
            do {
                let made = try await library.merge(parts, into: place)
                DebugLog.write("merge: \(parts.count) documents put together, \(made.pageCount) pages")
                path.append(made)
            } catch {
                errorText = "문서를 합치지 못했어요."
            }
            bringingIn -= 1
        }
    }

    private func newNote(_ paper: PaperKind, _ size: CGSize) {
        do {
            path.append(try library.createNote(in: folder?.id, paper: paper, size: size))
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Picking the documents to put together with one, in the order they are to follow it.
private struct MergeSheet: View {
    let first: Doc
    let others: [Doc]
    let onMerge: ([Doc]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [UUID] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("1")
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor, in: Circle())
                        Text(first.title)
                        Spacer()
                        Text("\(first.pageCount)쪽")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("맨 앞")
                }
                Section {
                    ForEach(others) { doc in
                        Button {
                            if let at = picked.firstIndex(of: doc.id) {
                                picked.remove(at: at)
                            } else {
                                picked.append(doc.id)
                            }
                        } label: {
                            HStack {
                                if let at = picked.firstIndex(of: doc.id) {
                                    Text("\(at + 2)")
                                        .font(.footnote.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Color.accentColor, in: Circle())
                                } else {
                                    Circle()
                                        .stroke(Color.secondary.opacity(0.5), lineWidth: 1.2)
                                        .frame(width: 24, height: 24)
                                }
                                Text(doc.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(doc.pageCount)쪽")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("뒤에 붙일 문서 (누른 순서대로)")
                } footer: {
                    Text("고른 문서들을 이어 붙인 새 문서가 만들어져요. 원래 문서는 그대로 남아요. 필기와 수식은 새 문서의 쪽에 그려 넣어져서, 새 문서에서는 지우거나 고칠 수 없어요.")
                }
            }
            .navigationTitle("문서 합치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("합치기") {
                        let parts = [first] + picked.compactMap { id in others.first { $0.id == id } }
                        dismiss()
                        onMerge(parts)
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }
}

/// One of the large buttons at the top of the shelf.
private struct QuickAction: View {
    let symbol: String
    let title: String
    var detail: String?
    /// Drawn with a broken outline: a place to drop something, not a button to press.
    var dashed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(dashed ? 0.32 : 0.18), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : []))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Choosing the paper of a new notebook: how large, which way up, and what is printed on it.
private struct PaperSheet: View {
    let onPick: (PaperKind, CGSize) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("noteSize") private var size = PaperSize.a4
    @AppStorage("noteLandscape") private var landscape = false

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20)]

    private var points: CGSize { size.points(landscape: landscape) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("종이 크기")
                            .font(.subheadline.weight(.semibold))
                        Picker("종이 크기", selection: $size) {
                            ForEach(PaperSize.allCases) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Picker("방향", selection: $landscape) {
                                Text("세로").tag(false)
                                Text("가로").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            Spacer()
                            Text(size.millimetres(landscape: landscape))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("종이 종류")
                        .font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(PaperKind.allCases) { kind in
                            Button {
                                let chosen = points
                                dismiss()
                                onPick(kind, chosen)
                            } label: {
                                VStack(spacing: 9) {
                                    PaperPreview(kind: kind, size: points)
                                        .frame(height: 190)
                                    Text(kind.label)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("새 노트")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { Diagnostics.shared.step("paper sheet opened") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
            }
        }
    }
}

private struct PaperPreview: View {
    let kind: PaperKind
    let size: CGSize
    @State private var picture: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
        .task(id: "\(kind.rawValue) \(Int(size.width)) \(Int(size.height))") {
            picture = Paper.preview(kind, size: size)
        }
    }
}

/// A folder on the shelf. Each folder has a colour of its own, the same every time.
private struct FolderCard: View {
    let folder: Folder
    let count: Int

    private static func shade(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }

    private static let back = shade(0xD9C79E, 0x7C6F52)
    private static let front = shade(0xECDDB8, 0x94855F)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { space in
                let wide = space.size.width * 0.82
                let tall = wide * 0.76
                ZStack(alignment: .bottom) {
                    FolderBack()
                        .fill(Self.back)
                    RoundedRectangle(cornerRadius: wide * 0.055, style: .continuous)
                        .fill(Self.front)
                        .frame(height: tall * 0.78)
                }
                .frame(width: wide, height: tall)
                // Standing on the bottom of its place, as the documents' covers do, just above its name.
                .position(x: space.size.width / 2, y: space.size.height - tall / 2 - 4)
            }
            .aspectRatio(0.84, contentMode: .fit)

            Text(folder.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("문서 \(count)개")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The back of a card folder: a sheet with a tab standing up at its top left.
private struct FolderBack: Shape {
    func path(in rect: CGRect) -> Path {
        let round = rect.width * 0.055
        let tabWide = rect.width * 0.38
        let tabTall = rect.height * 0.13
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + round))
        path.addQuadCurve(to: CGPoint(x: rect.minX + round, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWide, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWide + tabTall * 0.8, y: rect.minY + tabTall))
        path.addLine(to: CGPoint(x: rect.maxX - round, y: rect.minY + tabTall))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabTall + round), control: CGPoint(x: rect.maxX, y: rect.minY + tabTall))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - round))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - round, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + round, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - round), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A document opened lately, in the row at the top of the shelf: smaller than on the shelf, and lying down.
private struct RecentCard: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color.clear
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                }
            }
            .frame(width: 62, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let opened = doc.openedAt {
                    Text(Tone.ago(opened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        .background(Tone.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: doc.id) {
            cover = await library.cover(for: doc, width: 440)
        }
    }
}

/// A document on the shelf: its first page standing on the bottom edge of a box, its name beneath.
private struct DocCard: View {
    let doc: Doc
    /// Shown when the document was found by searching, to say where it lives.
    var folderName: String?
    /// While several documents are being picked: whether this one is.
    var mark: Bool?
    /// How many questions were asked in it.
    var asked = 0
    @EnvironmentObject private var library: Library
    @State private var cover: UIImage?

    private var detail: String {
        var parts = ["\(doc.pageCount)쪽"]
        if let opened = doc.openedAt {
            parts.append(Tone.ago(opened))
        }
        if let folderName { parts.append(folderName) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Every document in a box of one size, whatever the shape of its page: the rows stay even.
            ZStack {
                Tone.card
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .padding(12)
                }
            }
            .aspectRatio(1.16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let mark {
                    Image(systemName: mark ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(mark ? Color.accentColor : Color.secondary)
                        .background(Circle().fill(Color(uiColor: .systemBackground)).padding(2))
                        .padding(4)
                }
            }

            Text(doc.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                if asked > 0 {
                    // (The one colour the shelf has: the AI pen's. Until 0.15.0 it was set on the whole
                    // row and the grey of the text beside it gave way to it.)
                    let teal = Color(uiColor: InkChoice.markColor)
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.caption)
                        .foregroundStyle(teal)
                    Text("\(asked)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(teal)
                }
            }
        }
        .task(id: doc.id) {
            cover = await library.cover(for: doc, width: 440)
        }
    }
}
