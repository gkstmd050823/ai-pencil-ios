import SwiftUI
import UniformTypeIdentifiers

/// The shelf: folders and documents, and the ways to get more.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var path = NavigationPath()
    @State private var errorText: String?
    @State private var ranDemo = false

    var body: some View {
        NavigationStack(path: $path) {
            Shelf(folder: nil, path: $path)
                .navigationDestination(for: Folder.self) { folder in
                    Shelf(folder: folder, path: $path)
                }
                .navigationDestination(for: Doc.self) { doc in
                    ReaderView(doc: doc)
                }
        }
        // A PDF handed over by another app ("open in", share sheet): it is copied in and opened at once,
        // whatever was on screen.
        .onOpenURL { url in
            Diagnostics.shared.step("handed a file")
            Task { @MainActor in
                do {
                    let doc = try await library.bringIn(url)
                    path = NavigationPath()
                    path.append(doc)
                } catch {
                    errorText = error.localizedDescription
                }
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: runDemoIfAsked)
    }

    /// The build server starts the app with these to take pictures without anyone tapping: "-sample" opens
    /// the bundled sample (imported once), "-demoNote" makes a blank notebook and opens it, "-demoImport
    /// name.pdf" opens a file the server put in the app's Documents folder, "-demoShelf" fills the shelf
    /// with a folder and a notebook in it.
    private func runDemoIfAsked() {
        guard !ranDemo, path.isEmpty else { return }
        ranDemo = true
        let arguments = ProcessInfo.processInfo.arguments
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

/// One level of the shelf: the top, with its folders, or the inside of a folder.
private struct Shelf: View {
    let folder: Folder?
    @Binding var path: NavigationPath
    @EnvironmentObject private var library: Library
    @AppStorage("librarySort") private var sort = LibrarySort.recent
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
    /// How many files are still being copied in.
    @State private var bringingIn = 0

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 22)]

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Looking for a document looks in every folder; otherwise only what is on this level shows.
    private var docs: [Doc] { library.documents(in: folder?.id, sort: sort, matching: search) }
    private var folders: [Folder] { folder == nil && !searching ? library.folders : [] }

    var body: some View {
        Group {
            if docs.isEmpty && folders.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(folder?.name ?? "문서")
        .searchable(text: $search, prompt: "문서 찾기")
        .toolbar {
            if folder == nil {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("설정", systemImage: "gearshape")
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("정렬", selection: $sort) {
                        ForEach(LibrarySort.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                } label: {
                    Label("정렬", systemImage: "arrow.up.arrow.down")
                }
                Menu {
                    Button {
                        importing = true
                    } label: {
                        Label("PDF 가져오기", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        choosingPaper = true
                    } label: {
                        Label("새 노트 만들기", systemImage: "doc.badge.plus")
                    }
                    if folder == nil {
                        Button {
                            newName = ""
                            makingFolder = true
                        } label: {
                            Label("새 폴더", systemImage: "folder.badge.plus")
                        }
                    }
                } label: {
                    Label("추가", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                // Copied in off the main thread: a large file must not hold the shelf still.
                let place = folder?.id
                bringingIn += urls.count
                Task { @MainActor in
                    var last: Doc?
                    for url in urls {
                        do {
                            last = try await library.bringIn(url, into: place)
                        } catch {
                            errorText = error.localizedDescription
                        }
                        bringingIn -= 1
                    }
                    // One file opens straight away; several stay on the shelf.
                    if urls.count == 1, let doc = last {
                        path.append(doc)
                    }
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .overlay {
            if bringingIn > 0 {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(bringingIn > 1 ? "PDF \(bringingIn)개를 가져오는 중" : "PDF를 가져오는 중")
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
                library.createFolder(named: newName)
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
                if let item = deletingFolder { library.deleteFolder(item) }
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            // "-demoSettings" shows the settings for the build server's picture.
            if folder == nil, !ranDemo, ProcessInfo.processInfo.arguments.contains("-demoSettings") {
                showingSettings = true
            }
            if folder == nil, !ranDemo, ProcessInfo.processInfo.arguments.contains("-demoPapers") {
                choosingPaper = true
            }
            ranDemo = true
        }
    }

    /// The documents opened last, from any folder: the ones most likely to be wanted again.
    private var recent: [Doc] {
        guard folder == nil, !searching else { return [] }
        return Array(library.docs.filter { $0.openedAt != nil }.sorted { ($0.openedAt ?? $0.addedAt) > ($1.openedAt ?? $1.addedAt) }.prefix(8))
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !searching {
                    quickActions
                }
                if recent.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        heading("이어서 보기", count: nil)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(recent) { doc in
                                    NavigationLink(value: doc) {
                                        RecentCard(doc: doc)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { docMenu(doc) }
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 2)
                        }
                    }
                }
                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        heading("폴더", count: folders.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(folders) { item in
                                NavigationLink(value: item) {
                                    FolderCard(folder: item, count: count(in: item))
                                }
                                .buttonStyle(.plain)
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
                        }
                    }
                }
                if !docs.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        heading(searching ? "찾은 문서" : "문서", count: docs.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(docs) { doc in
                                NavigationLink(value: doc) {
                                    DocCard(doc: doc, folderName: folderName(for: doc))
                                }
                                .buttonStyle(.plain)
                                .contextMenu { docMenu(doc) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.bold))
            if let count {
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The ways to get a document, as large buttons at the top of the shelf.
    private var quickActions: some View {
        HStack(spacing: 14) {
            QuickAction(symbol: "square.and.pencil", title: "새 노트", detail: "종이와 크기를 골라요") {
                choosingPaper = true
            }
            QuickAction(symbol: "arrow.down.doc", title: "PDF 가져오기", detail: "파일 앱에서 골라요") {
                importing = true
            }
            if folder == nil {
                QuickAction(symbol: "folder.badge.plus", title: "새 폴더", detail: "문서를 묶어 둬요") {
                    newName = ""
                    makingFolder = true
                }
            }
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

    /// The folder a document found by searching lives in, to show under its name.
    private func folderName(for doc: Doc) -> String? {
        guard searching, let id = doc.folder else { return nil }
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
            } else if folder != nil {
                Image(systemName: "folder")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("빈 폴더예요")
                    .font(.title3.bold())
                Text("오른쪽 위 +로 문서를 가져오거나, 서재에서 문서를 길게 눌러 이 폴더로 옮겨 보세요.")
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
                    Label("PDF 가져오기", systemImage: "plus")
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
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func newNote(_ paper: PaperKind, _ size: CGSize) {
        do {
            path.append(try library.createNote(in: folder?.id, paper: paper, size: size))
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// One of the large buttons at the top of the shelf.
private struct QuickAction: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    private static let tints: [Color] = [
        Color(red: 0.20, green: 0.50, blue: 0.96), Color(red: 0.06, green: 0.64, blue: 0.61),
        Color(red: 0.96, green: 0.58, blue: 0.14), Color(red: 0.90, green: 0.36, blue: 0.48),
        Color(red: 0.36, green: 0.42, blue: 0.84), Color(red: 0.24, green: 0.66, blue: 0.36),
    ]

    private var tint: Color {
        Self.tints[Int(folder.id.uuid.0) % Self.tints.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                Image(systemName: "folder.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(tint.gradient)
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
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
                }
            }
            .frame(width: 62, height: 82)
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(doc.pageCount)쪽")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let opened = doc.openedAt {
                    Text(opened.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 236, height: 106, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @EnvironmentObject private var library: Library
    @State private var cover: UIImage?

    private var detail: String {
        var parts = ["\(doc.pageCount)쪽"]
        if let opened = doc.openedAt {
            parts.append(opened.formatted(.relative(presentation: .named)))
        }
        if let folderName { parts.append(folderName) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color.clear
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                }
            }
            .aspectRatio(0.84, contentMode: .fit)

            Text(doc.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: doc.id) {
            cover = await library.cover(for: doc, width: 440)
        }
    }
}
