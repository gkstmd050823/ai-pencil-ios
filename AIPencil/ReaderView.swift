import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The formula being written: a new one, or one from the page being edited.
struct MathDraft: Identifiable {
    let id = UUID()
    var editing: MathItem?
    var preset = ""
    var auto = false
}

/// A copy of the document made for sending elsewhere.
private struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// A request to show the navigator: which of its tabs, and for the search, with which words.
private struct NavigatorRequest: Identifiable {
    let id = UUID()
    var tab: NavigatorSheet.Tab
    var query = ""
}

/// One open document: the tool bar, under it the pages with handwriting, formulas and marks on top, and
/// beside or below them the explanation of a mark when one is open.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @Environment(\.colorScheme) private var scheme
    @AppStorage("fingerDraws") private var fingerDraws = false
    @AppStorage("showAiMarks") private var showAiMarks = true
    @AppStorage("pageLayout") private var layoutMode = PageLayoutMode.vertical
    @AppStorage("darkPaper") private var darkPaper = true
    /// How much of the screen the explanation takes: of its width beside the pages, of its height below them.
    /// While its edge is being dragged the share is kept here and written to the settings once, at the end.
    @AppStorage("panelShare") private var panelShare = 0.44
    @State private var liveShare: Double?
    /// Reading only: fingers scroll and nothing else, and the pen is the AI pen whatever tool is in hand.
    @AppStorage("readOnly") private var readOnly = false
    /// Asking which pages to export, and what was typed.
    @State private var askingPages = false
    @State private var pagesText = ""
    @State private var choice = InkChoice.saved()
    /// The tool that was in hand before the one that is now, for the Pencil's "back to the last tool".
    @State private var previousTool = InkTool.eraser
    @StateObject private var controller = ReaderController()
    @StateObject private var session = AskSession()
    @StateObject private var translator = Translator()
    /// A word or two shown for a moment over the pages ("copied").
    @State private var notice: String?
    /// Changed to have the page view built afresh: after the document's pages were renumbered, or when the
    /// paper changes between light and dark.
    @State private var reloadToken = UUID()
    /// The page to start on: where pages were just put into the document, or the page the build server
    /// asked for ("-demoPage 2"); otherwise the first page.
    @State private var startPage: Int
    /// Picking PDFs whose pages are to go into this document.
    @State private var pickingPages = false
    /// The page view has gone to the page the document was opened at; from then on the page in view is
    /// the page the reader is at, and is kept.
    @State private var placeKept: Bool
    /// The paper as the page view was built with; nil until it has been rebuilt once.
    @State private var paperDark: Bool?
    @State private var bookmarks: [Int] = []
    @State private var mathDraft: MathDraft?
    @State private var errorText: String?
    @State private var showingSettings = false
    @State private var showingQuestions = false
    @State private var navigator: NavigatorRequest?
    @State private var showingOptions = false
    @State private var exporting = false
    @State private var exported: ExportedFile?
    @State private var dragStart: Double?
    @State private var ready = false

    init(doc: Doc) {
        self.doc = doc
        // Where pages were just put in; or the page the build server asked for; or the page it was last read at.
        let asked = UserDefaults.standard.object(forKey: "demoPage") != nil ? max(0, UserDefaults.standard.integer(forKey: "demoPage")) : nil
        let start = Library.startPage(for: doc.id) ?? asked ?? Library.lastPage(for: doc.id) ?? 0
        let page = min(max(start, 0), max(doc.pageCount - 1, 0))
        _startPage = State(initialValue: page)
        _placeKept = State(initialValue: page == 0)
    }

    private var folder: URL { library.folder(for: doc.id) }
    private var mathStore: MathStore { MathStore(folder: folder) }
    private var wantsDark: Bool { darkPaper && scheme == .dark }
    private var showsDark: Bool { paperDark ?? wantsDark }
    private var marked: Bool { bookmarks.contains(controller.pageIndex) }
    /// How many questions of this document have an answer.
    private var answered: Int { session.questions.filter { !$0.turns.isEmpty }.count }

    /// The marks drawn on the pages: all of them, less the ones taken off the page, unless marks are switched off.
    private var marks: [Question] {
        showAiMarks ? session.questions.filter { !$0.markHidden } : []
    }

    private var backdrop: Color {
        showsDark ? Color(white: 0.05) : Color(uiColor: .secondarySystemBackground)
    }

    var body: some View {
        GeometryReader { geometry in
            // On a wide screen the explanation stands beside the pages; otherwise it lies below them.
            // ("-demoWide YES" lets the build server, whose simulator stands upright, see the wide form.)
            let wide = UserDefaults.standard.bool(forKey: "demoWide")
                || (geometry.size.width >= 820 && geometry.size.width > geometry.size.height)
            let total = wide ? geometry.size.width : geometry.size.height
            let length = min(max(wide ? 320 : 280, total * CGFloat(liveShare ?? panelShare)), max(240, total - (wide ? 380 : 240)))
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            // How wide the pages are, which is what the tool bar has to fit in.
            let across = wide && session.panel != nil ? geometry.size.width - length : geometry.size.width
            layout {
                pages(roomy: across >= 790)
                if session.panel != nil {
                    panel(wide: wide, total: total)
                        .frame(width: wide ? length : nil, height: wide ? nil : length)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(backdrop)
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingQuestions = true
                } label: {
                    Label("질문 목록", systemImage: "text.bubble")
                }
                Button {
                    readOnly.toggle()
                    Diagnostics.shared.step(readOnly ? "reading only" : "reading and writing")
                } label: {
                    Label(readOnly ? "읽기 전용 끄기" : "읽기 전용", systemImage: readOnly ? "eye.fill" : "eye")
                }
                if !readOnly {
                    Button {
                        mathDraft = MathDraft()
                    } label: {
                        Label("수식 넣기", systemImage: "sum")
                    }
                    Button {
                        fingerDraws.toggle()
                    } label: {
                        Label(
                            fingerDraws ? "손가락 필기 끄기" : "손가락 필기 켜기",
                            systemImage: fingerDraws ? "hand.draw.fill" : "hand.draw"
                        )
                    }
                }
                Button {
                    openNavigator(.search)
                } label: {
                    Label("문서 안에서 찾기", systemImage: "magnifyingglass")
                }
                menu
            }
        }
        .sheet(item: $mathDraft) { draft in
            MathEditorView(
                initial: draft.editing?.latex ?? draft.preset,
                pageSize: controller.currentPageSize ?? CGSize(width: 595, height: 842),
                store: mathStore,
                autoInsert: draft.auto
            ) { result in
                if let old = draft.editing {
                    controller.replaceMath(old, with: result)
                } else {
                    controller.placeMath(result, color: choice.penUIColor)
                }
                // The formula tool is what the hand needs next: to drag the formula into place.
                pick(.formula)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingQuestions) {
            QuestionListView(session: session) { question in
                session.open(question.id)
                locate(question)
            }
        }
        .sheet(item: $navigator) { request in
            NavigatorSheet(controller: controller, bookmarks: $bookmarks, tab: request.tab, query: request.query)
        }
        .sheet(item: $exported) { file in
            ActivityView(items: [file.url])
        }
        .alert("내보낼 쪽", isPresented: $askingPages) {
            TextField("예: 1-3, 7", text: $pagesText)
                .keyboardType(.numbersAndPunctuation)
            Button("이 쪽만") {
                export(toDocuments: false, pages: [controller.pageIndex])
            }
            Button("적은 쪽만") {
                if let pages = PageRanges.parse(pagesText, count: controller.pageCount) {
                    export(toDocuments: false, pages: pages)
                } else {
                    errorText = "쪽을 알아볼 수 없어요. 1-3, 7처럼 적어 주세요. 이 문서는 \(controller.pageCount)쪽까지 있어요."
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("쉼표로 나누고, 이어진 쪽은 1-3처럼 적어요. 전체 \(controller.pageCount)쪽.")
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: choice) {
            choice.saveSoon()
        }
        .onChange(of: showingOptions) {
            Diagnostics.shared.step(showingOptions ? "tool settings opened" : "tool settings closed")
        }
        .onChange(of: showingSettings) {
            Diagnostics.shared.step(showingSettings ? "settings opened" : "settings closed")
        }
        .onChange(of: showingQuestions) {
            Diagnostics.shared.step(showingQuestions ? "questions opened" : "questions closed")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            InkChoice.saveWaiting()
        }
        .onDisappear {
            InkChoice.saveWaiting()
            if library.showing == doc.id {
                library.showing = nil
                library.pageOnShow = nil
            }
        }
        .fileImporter(isPresented: $pickingPages, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                // (A moment later: the file picker is still on its way out.)
                let place = doc.folder
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    library.incoming = IncomingFiles(urls: urls, folder: place, forDocument: true)
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
        .onChange(of: controller.pageIndex) {
            // (A page view begins at the first page and goes to the page asked for a moment later.)
            if !placeKept {
                guard controller.pageIndex == startPage else { return }
                placeKept = true
            }
            Library.notePage(controller.pageIndex, for: doc.id)
        }
        .onChange(of: library.pagesToAdd) {
            guard let wanted = library.pagesToAdd, wanted.doc == doc.id else { return }
            library.pagesToAdd = nil
            addPages(from: wanted.urls, atEnd: wanted.atEnd)
        }
        .onChange(of: bookmarks) {
            BookmarkStore(folder: folder).save(bookmarks)
        }
        .onChange(of: wantsDark) {
            // The pages are drawn anew for the other paper, from the page that was being read.
            startPage = controller.currentPageIndex ?? startPage
            controller.saveAndRetire()
            paperDark = wantsDark
            reloadToken = UUID()
        }
        .onAppear(perform: setUp)
    }

    private var menu: some View {
        Menu {
            Picker("보기 방식", selection: $layoutMode) {
                ForEach(PageLayoutMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            Divider()
            Button {
                openNavigator(.pages)
            } label: {
                Label("쪽 이동 · 목차 · 책갈피", systemImage: "square.grid.2x2")
            }
            Button {
                toggleBookmark()
            } label: {
                Label(marked ? "책갈피 지우기" : "이 쪽에 책갈피", systemImage: marked ? "bookmark.slash" : "bookmark")
            }
            Menu {
                ForEach(PaperKind.allCases) { kind in
                    Button(kind.label) { addPage(kind) }
                }
            } label: {
                Label("이 쪽 뒤에 쪽 추가", systemImage: "doc.badge.plus")
            }
            Button {
                pickingPages = true
            } label: {
                Label("PDF 가져오기", systemImage: "arrow.down.doc")
            }
            Button {
                export(toDocuments: false)
            } label: {
                Label("PDF로 내보내기", systemImage: "square.and.arrow.up")
            }
            Button {
                pagesText = ""
                askingPages = true
            } label: {
                Label("쪽을 골라 PDF로 내보내기", systemImage: "doc.on.doc")
            }
            Divider()
            Toggle(isOn: $showAiMarks) {
                Label("AI 표시 보이기", systemImage: "pencil.tip.crop.circle")
            }
            Button {
                showingQuestions = true
            } label: {
                Label("질문 목록", systemImage: "list.bullet")
            }
            Divider()
            Button {
                showingSettings = true
            } label: {
                Label("설정", systemImage: "gearshape")
            }
        } label: {
            Label("더 보기", systemImage: "ellipsis.circle")
        }
    }

    /// The tool bar has a strip of its own above the pages, so that it never covers the top of a page.
    private func pages(roomy: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if readOnly {
                    // Reading only: no tools, and a word on what the pen and the fingers do.
                    HStack(spacing: 10) {
                        Image(systemName: "eye")
                            .foregroundStyle(Color(uiColor: InkChoice.markColor))
                        Text("읽기 전용 · 손가락은 넘기기만, 펜으로 동그라미를 치면 설명해 줘요")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Button("끄기") {
                            readOnly = false
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                } else {
                    ToolBar(
                        choice: $choice, showingOptions: $showingOptions, darkPaper: showsDark, roomy: roomy,
                        canUndo: controller.canUndo, canRedo: controller.canRedo, questions: answered,
                        onPick: pick, onUndo: controller.undo, onRedo: controller.redo,
                        onQuestions: { showingQuestions = true }, onClearPage: controller.clearPage
                    )
                }
            }
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(backdrop)
            // Above the pages, so that the bar's shadow falls on them.
            .zIndex(1)
            PDFInkView(
                url: library.pdfURL(for: doc.id),
                store: DrawingStore(folder: folder),
                mathStore: mathStore,
                choice: inHand,
                fingerDraws: fingerDraws && !readOnly,
                layout: layoutMode,
                darkPaper: showsDark,
                startPage: startPage,
                marks: marks,
                activeMark: session.panel?.questionID,
                controller: controller
            )
            .id(reloadToken)
            .ignoresSafeArea(.container, edges: .bottom)
            // The settings of the tool in hand, as a card under the tool bar. (Until 0.9.0 this was a
            // popover, a window of its own that sizes itself to what is in it; the app's crashes on an
            // iPad came when the pen was touched to open it.) A touch anywhere else puts it away.
            .overlay(alignment: .top) {
                if showingOptions, !readOnly {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { showingOptions = false }
                        ToolOptions(choice: $choice, darkPaper: showsDark) {
                            showingOptions = false
                            controller.clearPage()
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if translator.source != nil {
                    TranslationCard(translator: translator) {
                        showingSettings = true
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 54)
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if controller.pageCount > 1 {
                    Button {
                        openNavigator(.pages)
                    } label: {
                        HStack(spacing: 5) {
                            if marked {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                            Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .padding(.bottom, 12)
                    .accessibilityLabel("\(controller.pageCount)쪽 중 \(controller.pageIndex + 1)쪽, 쪽 이동")
                }
            }
            .overlay {
                if exporting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("PDF로 내보내는 중")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                }
            }
        }
    }

    /// The explanation, with a handle on the edge it shares with the pages: dragging it gives the
    /// explanation more room or less.
    private func panel(wide: Bool, total: CGFloat) -> some View {
        let inner = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return inner {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: wide ? 5 : 40, height: wide ? 40 : 5)
                .frame(width: wide ? 18 : nil, height: wide ? nil : 16)
                .frame(maxWidth: wide ? nil : .infinity, maxHeight: wide ? .infinity : nil)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { value in
                            let from = dragStart ?? panelShare
                            dragStart = from
                            let moved = wide ? -value.translation.width : -value.translation.height
                            liveShare = min(0.72, max(0.24, from + Double(moved / max(total, 1))))
                        }
                        .onEnded { _ in
                            if let liveShare { panelShare = liveShare }
                            liveShare = nil
                            dragStart = nil
                        }
                )
                .accessibilityLabel("설명 창 크기 조절")
            ExplainPanel(
                session: session, onOpenSettings: { showingSettings = true }, onLocate: locate,
                onShowQuestions: { showingQuestions = true }
            )
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: wide ? 18 : 0, bottomTrailingRadius: 0, topTrailingRadius: wide ? 0 : 18))
        .shadow(color: .black.opacity(0.14), radius: 12, x: wide ? -2 : 0, y: wide ? 0 : -2)
    }

    /// What the pages are written on with: the tool in hand, or, reading only, the AI pen.
    private var inHand: InkChoice {
        guard readOnly else { return choice }
        var only = choice
        only.tool = .ai
        return only
    }

    /// Takes a tool in hand, remembering the one put down.
    private func pick(_ tool: InkTool) {
        if tool != choice.tool {
            previousTool = choice.tool
            choice.tool = tool
        }
    }

    /// A double tap or a squeeze of the Apple Pencil.
    private func pencil(_ action: PencilAction) {
        // (Reading only, the pen has one tool and nothing to switch to.)
        if readOnly { return }
        switch action {
        case .eraser:
            pick(choice.tool == .eraser ? (previousTool == .eraser ? .pen : previousTool) : .eraser)
        case .ai:
            pick(choice.tool == .ai ? (previousTool == .ai ? .pen : previousTool) : .ai)
        case .previous:
            pick(previousTool)
        case .options:
            showingOptions = true
        }
    }

    private func openNavigator(_ tab: NavigatorSheet.Tab, query: String = "") {
        navigator = NavigatorRequest(tab: tab, query: query)
    }

    private func toggleBookmark() {
        let page = controller.pageIndex
        if bookmarks.contains(page) {
            bookmarks.removeAll { $0 == page }
        } else {
            bookmarks = (bookmarks + [page]).sorted()
        }
    }

    /// Done once, when the document is first shown: the page view's requests are wired to the session.
    private func setUp() {
        // (Each time the screen comes on show, not once: this is the document that pages picked now go into.)
        library.showing = doc.id
        library.pageOnShow = { [weak controller] in controller?.currentPageIndex }
        Library.clearStartPage(for: doc.id)
        guard !ready else { return }
        ready = true
        // (Should the page asked for never come into view, the page in view counts all the same.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { placeKept = true }
        let session = self.session
        let controller = self.controller
        controller.onEditMath = { item in
            mathDraft = MathDraft(editing: item)
        }
        controller.onMark = { page, points in
            session.ask(page: page, points: points)
            if let question = session.openQuestion { locate(question) }
        }
        controller.onOpenMark = { id in
            session.open(id)
            if let question = session.openQuestion { locate(question) }
        }
        controller.onHideMark = { id in
            session.setMarkHidden(id, true)
        }
        controller.onShowMark = { id in
            session.setMarkHidden(id, false)
        }
        controller.onDeleteMark = { id in
            session.delete(id)
        }
        controller.onToolUsed = { tool in
            // A tool set to be put down after use gives way to the one held before it.
            guard choice.tool == tool else { return }
            pick(previousTool == tool ? .pen : previousTool)
            DebugLog.write("tool: \(tool.rawValue) put down after use, \(choice.tool.rawValue) in hand")
        }
        controller.onPencil = { action in
            pencil(action)
        }
        let translator = self.translator
        controller.onTranslate = { text in
            translator.translate(text)
        }
        controller.onPickedText = { text in
            // With "translate as soon as words are picked" on, there is no menu to go through.
            if UserDefaults.standard.bool(forKey: "translateOnPick") { translator.translate(text) }
        }
        controller.onCopiedText = { _ in
            notice = "복사했어요"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { notice = nil }
        }
        bookmarks = BookmarkStore(folder: folder).load()
        // Noted as opened once the screen has settled: it reorders the shelf this screen came from,
        // and the shelf is not given a new order in the middle of being left.
        let opened = doc
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak library] in
            library?.touch(opened)
        }
        Diagnostics.shared.step("reader shown")
        session.attach(title: doc.title, pdfURL: library.pdfURL(for: doc.id), folder: folder, controller: controller)
        runDemoIfAsked()
    }

    /// Brings a question's mark into view. A moment later, because a panel that has just opened is
    /// still taking its room from the pages.
    private func locate(_ question: Question) {
        let controller = self.controller
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            controller.reveal(question.bounds, onPage: question.page)
        }
    }

    private func addPage(_ paper: PaperKind) {
        guard let index = controller.currentPageIndex else { return }
        session.close()
        // Everything on disk first, and nothing more written by the old page view: its page numbers are about to be wrong.
        controller.saveAndRetire()
        do {
            try library.insertBlankPage(in: doc, after: index, paper: paper)
            startPage = index + 1
        } catch {
            errorText = error.localizedDescription
            startPage = index
        }
        // The questions' and bookmarks' page numbers changed on disk along with everything else.
        session.attach(title: doc.title, pdfURL: library.pdfURL(for: doc.id), folder: folder, controller: controller)
        bookmarks = BookmarkStore(folder: folder).load()
        reloadToken = UUID()
    }

    /// Puts the pages of other PDFs into this document, after the page being read or after the last one,
    /// and shows the first of them.
    private func addPages(from urls: [URL], atEnd: Bool) {
        guard library.working == nil else { return }
        let count = max(controller.pageCount, doc.pageCount, 1)
        let index = atEnd ? count - 1 : min(max(controller.currentPageIndex ?? 0, 0), count - 1)
        Diagnostics.shared.step("putting pages in")
        session.close()
        // Everything on disk first, and nothing more written by the old page view: its page numbers are about to be wrong.
        controller.saveAndRetire()
        library.working = "쪽을 넣는 중"
        Task { @MainActor in
            do {
                let result = try await library.insertPages(from: urls, into: doc, after: index)
                startPage = index + 1
                if result.failed > 0 { errorText = "\(result.failed)개 파일은 넣지 못했어요." }
            } catch {
                errorText = error.localizedDescription
                startPage = index
            }
            library.working = nil
            // The questions' and bookmarks' page numbers changed on disk along with everything else.
            session.attach(title: doc.title, pdfURL: library.pdfURL(for: doc.id), folder: folder, controller: controller)
            bookmarks = BookmarkStore(folder: folder).load()
            reloadToken = UUID()
        }
    }

    /// Makes a copy of the document with the handwriting drawn in and offers to send it somewhere.
    /// For the build server the copy is put in the app's Documents folder instead.
    private func export(toDocuments: Bool, pages: [Int]? = nil) {
        guard !exporting else { return }
        Diagnostics.shared.step(pages == nil ? "exporting" : "exporting \(pages?.count ?? 0) pages")
        exporting = true
        controller.save()
        let pdfURL = library.pdfURL(for: doc.id)
        let folder = self.folder
        let title = doc.title
        let withMarks = showAiMarks
        Task { @MainActor in
            let url = await Task.detached(priority: .userInitiated) {
                Exporter.export(pdfURL: pdfURL, folder: folder, title: title, withMarks: withMarks, pages: pages)
            }.value
            exporting = false
            guard let url else {
                errorText = "PDF로 내보내지 못했어요."
                return
            }
            if toDocuments {
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let target = documents.appendingPathComponent("export.pdf")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
                DebugLog.write("export: written to Documents/export.pdf")
            } else {
                exported = ExportedFile(url: url)
            }
        }
    }

    /// The build server starts the app with these to take pictures of things no one is there to tap.
    private func runDemoIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        let session = self.session
        let controller = self.controller
        func later(_ seconds: Double, _ work: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
        if arguments.contains("-demoMath") {
            later(2) { mathDraft = MathDraft(preset: "\\frac{a}{b} = \\sqrt{x^2 + 1}", auto: true) }
        }
        // ("-demoAddPages name.pdf": that file of the app's Documents folder, put in after the page on show.)
        if let name = defaults.string(forKey: "demoAddPages") {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
            later(2) { addPages(from: [file], atEnd: false) }
        }
        if arguments.contains("-demoHighlightMany") {
            later(3) { controller.demoHighlightMany() }
        }
        if arguments.contains("-demoLiveLine") {
            later(3) { controller.demoLive() }
        }
        if arguments.contains("-demoDashes") {
            later(3) { controller.demoDashes() }
        }
        if arguments.contains("-demoHeldShapes") {
            later(3) { controller.demoHeldShapes() }
        }
        if arguments.contains("-demoTurn") {
            later(3) { controller.demoTurn() }
        }
        if arguments.contains("-demoAddPage") {
            later(2) { addPage(PaperKind(rawValue: defaults.string(forKey: "demoPaper") ?? "") ?? .blank) }
        }
        if arguments.contains("-demoAsk") {
            // A ring drawn with the AI pen round the place given ("-demoAskX 300 -demoAskY 200"), or
            // round the heading of the bundled sample.
            let x = defaults.object(forKey: "demoAskX") == nil ? 130 : defaults.double(forKey: "demoAskX")
            let y = defaults.object(forKey: "demoAskY") == nil ? 88 : defaults.double(forKey: "demoAskY")
            choice.tool = .ai
            later(2.5) { controller.demoMark(center: CGPoint(x: x, y: y), radius: CGSize(width: 86, height: 22)) }
        }
        if arguments.contains("-demoFollowUp") {
            // Once the first answer is in, asks something more: the words given, or the first ready-made request.
            let words = defaults.string(forKey: "demoFollowUpText") ?? Prompts.followUps[0].text
            Task { @MainActor in
                for _ in 0..<150 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if session.panel?.phase == .done {
                        session.followUp(words)
                        break
                    }
                }
            }
        }
        if arguments.contains("-demoOpenQuestion") {
            later(2) {
                if let last = session.questions.last {
                    session.open(last.id)
                    locate(last)
                }
            }
        }
        if arguments.contains("-demoQuestions") {
            later(2) { showingQuestions = true }
        }
        if let tool = InkTool(rawValue: defaults.string(forKey: "demoTool") ?? "") {
            choice.tool = tool
        }
        if arguments.contains("-demoOptions") {
            later(2) { showingOptions = true }
        }
        // The eraser's settings, said outright so that one launch's does not carry into the next.
        if defaults.object(forKey: "demoEraserAuto") != nil { choice.eraserAuto = defaults.bool(forKey: "demoEraserAuto") }
        if let kind = EraserKind(rawValue: defaults.string(forKey: "demoEraserKind") ?? "") { choice.eraserKind = kind }
        if defaults.double(forKey: "demoEraserWidth") > 0 { choice.eraserWidth = defaults.double(forKey: "demoEraserWidth") }
        if defaults.object(forKey: "demoHighlighterOnly") != nil { choice.eraserHighlighterOnly = defaults.bool(forKey: "demoHighlighterOnly") }
        if defaults.object(forKey: "demoHighlighterAuto") != nil { choice.highlighterAuto = defaults.bool(forKey: "demoHighlighterAuto") }
        // The pen's, too: its kind, and the width in millimetres of the one in use.
        if let kind = PenKind(rawValue: defaults.string(forKey: "demoPenKind") ?? "") { choice.penKind = kind }
        if let stroke = PenStroke(rawValue: defaults.string(forKey: "demoPenStroke") ?? "") { choice.penStroke = stroke }
        if defaults.object(forKey: "demoHighlighterStraight") != nil { choice.highlighterStraight = defaults.bool(forKey: "demoHighlighterStraight") }
        if defaults.double(forKey: "demoPenSize") > 0 {
            choice.penSize = InkChoice.tidy(defaults.double(forKey: "demoPenSize"), in: InkChoice.penSizeRange)
        }
        let dense = defaults.integer(forKey: "demoDense")
        if dense > 0 {
            later(2.5) { controller.demoDense(dense) }
        }
        if arguments.contains("-demoBlock") {
            later(2.5) { controller.demoBlock() }
        }
        if arguments.contains("-demoPen") {
            later(2.5) { controller.demoPen() }
        }
        if arguments.contains("-demoEraseMark") {
            // The eraser drawn down through the ring round the sample's heading.
            later(3) { controller.demoErase(from: CGPoint(x: 130, y: 50), to: CGPoint(x: 130, y: 130)) }
        }
        if arguments.contains("-demoUndo") {
            later(4.5) { controller.undo() }
        }
        if let tab = NavigatorSheet.Tab(rawValue: defaults.string(forKey: "demoNavigator") ?? "") {
            later(2) { openNavigator(tab, query: defaults.string(forKey: "demoSearch") ?? "") }
        }
        if let words = defaults.string(forKey: "demoFind") {
            // Goes to the first place the words stand at, as picking it from the search results does.
            later(2) { if let hit = controller.search(words).first { controller.show(hit) } }
        }
        if arguments.contains("-demoPickText") {
            // Picks a line and a half of the page, as a finger held and dragged would; with
            // "-demoTranslate", has them translated as the menu's button does.
            later(2.5) { controller.demoPick(from: CGPoint(x: 68, y: 225), to: CGPoint(x: 300, y: 249)) }
            if arguments.contains("-demoTranslate") {
                later(3.2) { translator.translate(controller.pickedText) }
            }
        }
        if arguments.contains("-demoBookmark") {
            later(1.5) { if !marked { toggleBookmark() } }
        }
        if arguments.contains("-demoShapes") {
            choice.tool = .shape
            later(2) { controller.demoShapes() }
        }
        if arguments.contains("-demoExport") {
            // ("-demoExportPages 2,4-5" exports those pages only.)
            let fewer = defaults.string(forKey: "demoExportPages").flatMap { PageRanges.parse($0, count: 100_000) }
            later(3) { export(toDocuments: true, pages: fewer) }
        }
        // "-demoZoom 2.5" zooms in that many times past fitting the page, to see how sharp ink stays.
        let zoom = defaults.double(forKey: "demoZoom")
        if zoom > 0 {
            later(1.5) { controller.demoZoom(zoom) }
        }
    }
}

/// The tool bar: undo and redo, the tools, and a part for the tool in hand (its widths, its colours),
/// which is the same width whatever the tool, so that the bar keeps its size and its place. Touching the
/// tool in hand again opens its settings.
///
/// Whether there is room for the tool's own part is worked out by the screen above from the width it has,
/// and handed down: the bar does not measure itself. Everything on it is drawn by SwiftUI itself.
private struct ToolBar: View {
    @Binding var choice: InkChoice
    @Binding var showingOptions: Bool
    var darkPaper: Bool
    /// There is room for the tool's own part beside the tools.
    var roomy: Bool
    var canUndo: Bool
    var canRedo: Bool
    /// How many questions the document has, shown beside the AI pen.
    var questions: Int
    var onPick: (InkTool) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onQuestions: () -> Void
    var onClearPage: () -> Void

    /// The width kept for the tool's own part.
    private static let room: CGFloat = 304

    private func tint(_ tool: InkTool) -> Color {
        tool == .ai ? Color(uiColor: InkChoice.markColor) : Color.accentColor
    }

    private var hasOptions: Bool {
        choice.tool == .pen || choice.tool == .highlighter || choice.tool == .eraser || choice.tool == .shape
    }

    /// A colour as it will look on the paper.
    private func shown(_ rgb: UInt32) -> Color {
        let color = InkChoice.color(rgb)
        return Color(uiColor: darkPaper ? color.onDarkPaper : color)
    }

    var body: some View {
        HStack(spacing: 1) {
            step("arrow.uturn.backward", "실행 취소", enabled: canUndo, action: onUndo)
            step("arrow.uturn.forward", "다시 실행", enabled: canRedo, action: onRedo)
            rule
            ForEach(InkTool.allCases) { tool in
                Button {
                    if choice.tool == tool, hasOptions {
                        showingOptions = true
                    } else {
                        onPick(tool)
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 18, weight: .medium))
                            .frame(height: 22)
                        // The pen and the highlighter wear their colour.
                        Capsule()
                            .fill(tool == .pen ? shown(choice.penColor) : tool == .highlighter ? shown(choice.highlighterColor) : Color.clear)
                            .frame(width: 18, height: 3)
                    }
                    .frame(width: 44, height: 42)
                    // The tool in hand is the one filled shape on the bar: ink on paper, turned round.
                    // (The AI pen's is in its own colour, the only colour the bar has of its own.)
                    .foregroundStyle(choice.tool == tool ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.7))
                    .background(choice.tool == tool ? (tool == .ai ? tint(tool) : Color.primary) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .accessibilityLabel(tool.label)
            }
            if roomy {
                rule
                own
                    .frame(width: Self.room, height: 42)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 24)
            .padding(.horizontal, 6)
    }

    private func step(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 38, height: 42)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// The part of the bar that belongs to the tool in hand.
    @ViewBuilder
    private var own: some View {
        switch choice.tool {
        case .pen:
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { slot in
                    penSize(slot)
                }
                rule
                quick(InkChoice.penPalette, count: 4, selected: choice.penColor) { choice.penColor = $0 }
            }
        case .highlighter:
            quick(InkChoice.highlighterPalette, count: 6, selected: choice.highlighterColor) { choice.highlighterColor = $0 }
        case .shape:
            HStack(spacing: 0) {
                ForEach(ShapeKind.allCases) { kind in
                    Button {
                        choice.shapeKind = kind
                    } label: {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 36, height: 34)
                            .foregroundStyle(choice.shapeKind == kind ? Color.primary : Color.primary.opacity(0.5))
                            .background(choice.shapeKind == kind ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .accessibilityLabel(kind.label)
                }
                rule
                quick(InkChoice.penPalette, count: 2, selected: choice.penColor) { choice.penColor = $0 }
            }
        case .eraser:
            HStack(spacing: 0) {
                if choice.eraserHighlighterOnly {
                    hint("형광펜만")
                        .frame(width: 96)
                } else {
                    ForEach(EraserKind.allCases) { kind in
                        Button {
                            choice.eraserKind = kind
                        } label: {
                            Text(kind.label)
                                .font(.footnote.weight(.semibold))
                                .frame(width: 46, height: 30)
                                .foregroundStyle(choice.eraserKind == kind ? Color.primary : Color.primary.opacity(0.5))
                                .background(choice.eraserKind == kind ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .accessibilityLabel(kind.label + " 지우개")
                    }
                }
                rule
                ForEach(InkChoice.eraserQuick, id: \.self) { size in
                    eraserSize(size)
                }
                Spacer(minLength: 0)
                more(current: nil)
            }
        case .ai:
            HStack(spacing: 4) {
                hint("모르는 곳에 동그라미를 쳐요")
                Button(action: onQuestions) {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                        Text("\(questions)")
                            .monospacedDigit()
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .foregroundStyle(tint(.ai))
                    .background(tint(.ai).opacity(0.14), in: Capsule())
                }
                .accessibilityLabel("질문 목록, \(questions)개")
                .padding(.trailing, 4)
            }
        case .lasso:
            hint("둘러서 고른 뒤 끌어 옮겨요")
        case .formula:
            hint("수식을 끌어 옮기고, 길게 눌러 고쳐요")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }

    /// One of the pen's three widths: a dot as thick as the line, and the width in millimetres under it.
    /// Touching the one in use opens the pen's settings, where its width can be changed.
    private func penSize(_ slot: Int) -> some View {
        let size = choice.penSizes.indices.contains(slot) ? choice.penSizes[slot] : 0.5
        let selected = choice.penSlot == slot
        let dot = min(17, max(3.5, CGFloat(size) * InkChoice.pointsPerMillimetre * 4))
        return Button {
            if selected {
                showingOptions = true
            } else {
                choice.penSlot = slot
            }
        } label: {
            VStack(spacing: 1) {
                Circle()
                    .fill(selected ? shown(choice.penColor) : Color.primary.opacity(0.5))
                    .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
                    .frame(width: dot, height: dot)
                    .frame(height: 19)
                Text(InkChoice.sizeLabel(size))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .frame(width: 36, height: 38)
            .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .accessibilityLabel("굵기 \(InkChoice.sizeLabel(size))밀리미터")
    }

    /// One of the eraser's sizes: a ring that grows with it.
    private func eraserSize(_ size: Double) -> some View {
        let selected = abs(choice.eraserWidth - size) < 0.5
        let ring = 8 + CGFloat(size) * 0.32
        return Button {
            choice.eraserWidth = size
        } label: {
            Circle()
                .stroke(selected ? Color.primary : Color.primary.opacity(0.45), lineWidth: selected ? 2 : 1.4)
                .frame(width: ring, height: ring)
                .frame(width: 34, height: 34)
                .background(selected ? Color.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .accessibilityLabel("지우개 크기 \(Int(size))")
    }

    /// The first colours of a palette, and a way to the rest.
    private func quick(_ palette: [UInt32], count: Int, selected: UInt32, pick: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(palette.prefix(count), id: \.self) { rgb in
                Button {
                    pick(rgb)
                } label: {
                    Swatch(color: shown(rgb), selected: rgb == selected)
                        .frame(width: 35, height: 42)
                }
                .accessibilityLabel("색 \((palette.firstIndex(of: rgb) ?? 0) + 1)")
            }
            Spacer(minLength: 0)
            more(current: palette.prefix(count).contains(selected) ? nil : selected)
        }
    }

    /// Opens the tool's settings. It wears the colour in use when that is not one of those beside it.
    private func more(current: UInt32?) -> some View {
        Button {
            showingOptions = true
        } label: {
            ZStack {
                if let current {
                    Swatch(color: shown(current), selected: true)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
            }
            .frame(width: 38, height: 42)
        }
        .accessibilityLabel("도구 설정 더 보기")
    }
}

/// A round colour to pick.
private struct Swatch: View {
    let color: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 23, height: 23)
            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 0.75))
            .padding(4)
            .overlay(Circle().stroke(Color.primary, lineWidth: selected ? 2 : 0))
    }
}

/// A line as the tool in hand would write it, on a piece of the paper: about as large as it comes out on
/// a page that fills the screen's width.
private struct StrokeSample: View {
    var color: Color
    var width: CGFloat
    var tint = false
    /// A dash and the gap after it, for a pen that writes in dashes or dots.
    var dash: [CGFloat] = []
    var darkPaper: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let inset: CGFloat = 22
            let span = size.width - 2 * inset
            for step in 0...80 {
                let along = CGFloat(step) / 80
                let point = CGPoint(x: inset + span * along, y: size.height / 2 + sin(along * 2 * .pi) * size.height * 0.2)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(
                path, with: .color(color.opacity(tint ? Double(InkChoice.highlighterStrength) : 1)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
            )
        }
        .frame(height: 58)
        .background(darkPaper ? Color(white: 0.11) : Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.75))
    }
}

/// The settings of the tool in hand: the kind of pen, how thick, which colour; what the eraser takes;
/// whether the tool is put down by itself once it has been used.
private struct ToolOptions: View {
    @Binding var choice: InkChoice
    var darkPaper: Bool
    var onClearPage: () -> Void

    private var eraserHint: String {
        if choice.eraserHighlighterOnly { return "형광펜으로 그은 선만 통째로 지우고, 펜으로 쓴 것은 그대로 둬요." }
        return choice.eraserKind == .stroke ? "원에 닿은 획을 통째로 지워요." : "원이 지나간 자리만 지워요."
    }

    private func shown(_ rgb: UInt32) -> Color {
        let color = InkChoice.color(rgb)
        return Color(uiColor: darkPaper ? color.onDarkPaper : color)
    }

    /// A switch for putting the tool down after one use.
    private func putDown(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.subheadline)
    }

    /// The width of the pen in use, kept to twentieths of a millimetre.
    private var penSize: Binding<Double> {
        Binding(
            get: { choice.penSize },
            set: { choice.penSize = InkChoice.tidy($0, in: InkChoice.penSizeRange) }
        )
    }

    private var highlighterSize: Binding<Double> {
        Binding(
            get: { choice.highlighterSize },
            set: { choice.highlighterSize = ($0 * 2).rounded() / 2 }
        )
    }

    /// About how many points of the screen a point of the page takes when a page fills the screen's width.
    private static let shownAt: CGFloat = 2

    /// The pen's dash and gap as the sample line shows them; empty for a whole line.
    private var penDashShown: [CGFloat] {
        guard let dash = choice.appPenDash else { return [] }
        return [max(dash.on, 0.01) * Self.shownAt, dash.off * Self.shownAt]
    }

    /// What the sliders of the pen in hand do.
    private var penHint: String {
        switch choice.penKind {
        case .fountain:
            return "필압 감도는 누르는 힘이, 속도 반응은 펜의 빠르기가 굵기를 얼마나 바꿀지예요(천천히 쓰면 굵게, 빨리 쓰면 가늘게). 펜끝 선명도는 획의 처음과 끝이 얼마나 뾰족할지, 획 안정화는 손떨림을 얼마나 펴 줄지예요."
        case .brush:
            return "붓은 획의 처음과 끝이 늘 뾰족하고, 천천히 쓰면 굵게 빨리 쓰면 가늘게 나와요. 필압 감도는 누르는 힘이 굵기를 얼마나 바꿀지, 획 안정화는 손떨림을 얼마나 펴 줄지예요."
        default:
            return "획 안정화는 손떨림을 얼마나 펴 줄지예요. 높이면 선이 펜을 조금 늦게 따라와요."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            switch choice.tool {
            case .pen:
                StrokeSample(color: shown(choice.penColor), width: choice.penSeenWidth * Self.shownAt, dash: penDashShown, darkPaper: darkPaper)
                Picker("펜 종류", selection: $choice.penKind) {
                    ForEach(PenKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text(choice.penKind.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("굵기")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        // The three widths kept on the tool bar; the slider changes the one picked.
                        ForEach(0..<3, id: \.self) { slot in
                            Button {
                                choice.penSlot = slot
                            } label: {
                                Text(InkChoice.sizeLabel(choice.penSizes.indices.contains(slot) ? choice.penSizes[slot] : 0.5))
                                    .font(.footnote.weight(.semibold).monospacedDigit())
                                    .frame(width: 46, height: 28)
                                    .foregroundStyle(choice.penSlot == slot ? Color(uiColor: .systemBackground) : Color.primary)
                                    .background(choice.penSlot == slot ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 10) {
                        Slider(value: penSize, in: InkChoice.penSizeRange, step: 0.05)
                        Text(InkChoice.sizeLabel(choice.penSize) + " mm")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                if choice.penKind != .pencil {
                    // These two are worked into the line while it is being written.
                    Picker("선 모양", selection: $choice.penStroke) {
                        ForEach(PenStroke.allCases) { stroke in
                            Text(stroke.label).tag(stroke)
                        }
                    }
                    .pickerStyle(.segmented)
                    SliderRow(title: "필압 감도", value: $choice.penSense, range: 0...1, shown: "\(Int((choice.penSense * 100).rounded()))%")
                        .disabled(choice.penKind != .fountain && choice.penKind != .brush)
                        .opacity(choice.penKind != .fountain && choice.penKind != .brush ? 0.4 : 1)
                    if choice.penKind == .fountain {
                        SliderRow(title: "펜끝 선명도", value: $choice.penTaper, range: 0...1, shown: "\(Int((choice.penTaper * 100).rounded()))%")
                        SliderRow(title: "속도 반응", value: $choice.penFlow, range: 0...1, shown: "\(Int((choice.penFlow * 100).rounded()))%")
                    }
                    SliderRow(title: "획 안정화", value: $choice.penSteady, range: 0...1, shown: "\(Int((choice.penSteady * 100).rounded()))%")
                    Text(penHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    putDown("긋고 멈추면 직선·도형으로 펴기", $choice.holdStraight)
                }
                ColorGrid(palette: InkChoice.penPalette, selection: $choice.penColor, darkPaper: darkPaper)
            case .highlighter:
                StrokeSample(color: shown(choice.highlighterColor), width: choice.highlighterSeenWidth * Self.shownAt, tint: true, darkPaper: darkPaper)
                HStack(spacing: 10) {
                    Text("굵기")
                        .font(.subheadline.weight(.semibold))
                    Slider(value: highlighterSize, in: InkChoice.highlighterSizes, step: 0.5)
                    Text(InkChoice.sizeLabel(choice.highlighterSize) + " mm")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                SliderRow(title: "획 안정화", value: $choice.penSteady, range: 0...1, shown: "\(Int((choice.penSteady * 100).rounded()))%")
                Text("형광펜은 종이를 물들이고 글자는 가리지 않아요. 같은 자리를 여러 번 그어도 더 진해지지 않아요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ColorGrid(palette: InkChoice.highlighterPalette, selection: $choice.highlighterColor, darkPaper: darkPaper)
                putDown("항상 직선으로 긋기", $choice.highlighterStraight)
                if !choice.highlighterStraight {
                    putDown("긋고 멈추면 직선으로 펴기", $choice.holdStraight)
                }
                putDown("한 번 긋고 나면 이전 도구로 돌아가기", $choice.highlighterAuto)
            case .shape:
                Picker("도형", selection: $choice.shapeKind) {
                    ForEach(ShapeKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text("끌어서 그려요. 직선과 화살표는 가로·세로에 가까우면 반듯하게 맞춰져요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("굵기")
                        .font(.subheadline.weight(.semibold))
                    Slider(value: penSize, in: InkChoice.penSizeRange, step: 0.05)
                    Text(InkChoice.sizeLabel(choice.penSize) + " mm")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
                ColorGrid(palette: InkChoice.penPalette, selection: $choice.penColor, darkPaper: darkPaper)
                putDown("한 번 그리고 나면 이전 도구로 돌아가기", $choice.shapeAuto)
            case .eraser:
                Picker("지우개 종류", selection: $choice.eraserKind) {
                    ForEach(EraserKind.allCases) { kind in
                        Text(kind.label + " 지우개").tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(choice.eraserHighlighterOnly)
                Text(eraserHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Every eraser has a size: the ring on the page is what it takes.
                HStack(spacing: 12) {
                    Text("크기")
                        .font(.subheadline.weight(.semibold))
                    Slider(value: $choice.eraserWidth, in: InkChoice.eraserWidths, step: 1)
                    Circle()
                        .stroke(Color.primary.opacity(0.55), lineWidth: 1.4)
                        .frame(width: CGFloat(choice.eraserWidth), height: CGFloat(choice.eraserWidth))
                        .frame(width: 62, height: 62)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("형광펜만 지우기", isOn: $choice.eraserHighlighterOnly)
                    Toggle("AI 펜 표시도 지우기", isOn: $choice.eraserTakesMarks)
                        .disabled(choice.eraserHighlighterOnly)
                    Text("표시만 쪽에서 사라져요. 설명은 질문 목록에 남고, 거기서 표시를 다시 보이게 할 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("지우고 나면 이전 도구로 돌아가기", isOn: $choice.eraserAuto)
                }
                .font(.subheadline)
                Divider()
                Button(role: .destructive, action: onClearPage) {
                    Label("이 쪽 필기 모두 지우기", systemImage: "trash")
                        .font(.subheadline)
                }
            default:
                EmptyView()
            }
        }
        .padding(18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
    }
}

/// A named slider with its value beside the name.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let shown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(shown)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(height: 22)
            Slider(value: $value, in: range)
        }
    }
}

/// The colours of a palette, and under them a way to pick any other colour.
private struct ColorGrid: View {
    let palette: [UInt32]
    @Binding var selection: UInt32
    var darkPaper: Bool

    /// The palette in rows of nine. (Plain rows: a grid that makes its cells as they are needed has no
    /// business in a card that is as tall as what is in it.)
    private var rows: [[UInt32]] {
        stride(from: 0, to: palette.count, by: 9).map { Array(palette[$0..<min($0 + 9, palette.count)]) }
    }

    private func shown(_ rgb: UInt32) -> Color {
        let color = InkChoice.color(rgb)
        return Color(uiColor: darkPaper ? color.onDarkPaper : color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("색")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { rgb in
                            Button {
                                selection = rgb
                            } label: {
                                Swatch(color: shown(rgb), selected: rgb == selection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("색 \((palette.firstIndex(of: rgb) ?? 0) + 1)")
                        }
                    }
                }
            }
            ColorPicker(
                "다른 색 고르기",
                selection: Binding(
                    get: { Color(uiColor: InkChoice.color(selection)) },
                    set: { selection = InkChoice.rgb(UIColor($0)) }
                ),
                supportsOpacity: false
            )
            .font(.subheadline)
        }
    }
}

/// The system's sheet for sending a file somewhere: to Files, to another app, to a printer.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
