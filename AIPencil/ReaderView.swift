import PDFKit
import SwiftUI

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
    @AppStorage("panelShare") private var panelShare = 0.44
    @State private var choice = InkChoice.saved()
    /// The tool that was in hand before the one that is now, for the Pencil's "back to the last tool".
    @State private var previousTool = InkTool.eraser
    @StateObject private var controller = ReaderController()
    @StateObject private var session = AskSession()
    /// Changed to have the page view built afresh: after the document's pages were renumbered, or when the
    /// paper changes between light and dark.
    @State private var reloadToken = UUID()
    /// The build server can ask for a page to start on ("-demoPage 2"); otherwise this is the first page.
    @State private var startPage = max(0, UserDefaults.standard.integer(forKey: "demoPage"))
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
            let length = min(max(wide ? 320 : 280, total * CGFloat(panelShare)), max(240, total - (wide ? 380 : 240)))
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pages
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
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: choice) {
            choice.save()
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
                export(toDocuments: false)
            } label: {
                Label("PDF로 내보내기", systemImage: "square.and.arrow.up")
            }
            Divider()
            Toggle(isOn: $showAiMarks) {
                Label("AI 표시 보이기", systemImage: "sparkles")
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
    private var pages: some View {
        VStack(spacing: 0) {
            ToolBar(
                choice: $choice, showingOptions: $showingOptions, darkPaper: showsDark,
                canUndo: controller.canUndo, canRedo: controller.canRedo, questions: answered,
                onPick: pick, onUndo: controller.undo, onRedo: controller.redo,
                onQuestions: { showingQuestions = true }, onClearPage: controller.clearPage
            )
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(backdrop)
            // Above the pages, so that the bar's shadow falls on them.
            .zIndex(1)
            PDFInkView(
                url: library.pdfURL(for: doc.id),
                store: DrawingStore(folder: folder),
                mathStore: mathStore,
                choice: choice,
                fingerDraws: fingerDraws,
                layout: layoutMode,
                darkPaper: showsDark,
                startPage: startPage,
                marks: marks,
                activeMark: session.panel?.questionID,
                controller: controller
            )
            .id(reloadToken)
            .ignoresSafeArea(.container, edges: .bottom)
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
                            panelShare = min(0.72, max(0.24, from + Double(moved / max(total, 1))))
                        }
                        .onEnded { _ in dragStart = nil }
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

    /// Takes a tool in hand, remembering the one put down.
    private func pick(_ tool: InkTool) {
        if tool != choice.tool {
            previousTool = choice.tool
            choice.tool = tool
        }
    }

    /// A double tap or a squeeze of the Apple Pencil.
    private func pencil(_ action: PencilAction) {
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
        guard !ready else { return }
        ready = true
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
        bookmarks = BookmarkStore(folder: folder).load()
        library.touch(doc)
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

    /// Makes a copy of the document with the handwriting drawn in and offers to send it somewhere.
    /// For the build server the copy is put in the app's Documents folder instead.
    private func export(toDocuments: Bool) {
        guard !exporting else { return }
        exporting = true
        controller.save()
        let pdfURL = library.pdfURL(for: doc.id)
        let folder = self.folder
        let title = doc.title
        let withMarks = showAiMarks
        Task {
            let url = await Task.detached(priority: .userInitiated) {
                Exporter.export(pdfURL: pdfURL, folder: folder, title: title, withMarks: withMarks)
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
        if defaults.object(forKey: "demoHighlighterOnly") != nil { choice.eraserHighlighterOnly = defaults.bool(forKey: "demoHighlighterOnly") }
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
        if arguments.contains("-demoBookmark") {
            later(1.5) { if !marked { toggleBookmark() } }
        }
        if arguments.contains("-demoShapes") {
            choice.tool = .shape
            later(2) { controller.demoShapes() }
        }
        if arguments.contains("-demoExport") {
            later(3) { export(toDocuments: true) }
        }
        // "-demoZoom 2.5" zooms in that many times past fitting the page, to see how sharp ink stays.
        let zoom = defaults.double(forKey: "demoZoom")
        if zoom > 0 {
            later(1.5) { controller.demoZoom(zoom) }
        }
    }
}

/// The tool bar: undo and redo, the tools, and a part for the tool in hand, which is the same width
/// whatever the tool, so that the bar keeps its size and its place. Touching the tool in hand again
/// opens its settings.
private struct ToolBar: View {
    @Binding var choice: InkChoice
    @Binding var showingOptions: Bool
    var darkPaper: Bool
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
    private static let room: CGFloat = 232

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

    // Where the whole bar does not fit on one line, the tool's own part is left out; what it holds is
    // in the tool's settings as well.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(withRoom: true)
            bar(withRoom: false)
        }
        .popover(isPresented: $showingOptions) {
            ToolOptions(choice: $choice, darkPaper: darkPaper) {
                showingOptions = false
                onClearPage()
            }
        }
    }

    private func bar(withRoom: Bool) -> some View {
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
                    .foregroundStyle(choice.tool == tool ? tint(tool) : Color.secondary)
                    .background(choice.tool == tool ? tint(tool).opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel(tool.label)
            }
            if withRoom {
                rule
                own
                    .frame(width: Self.room, height: 42)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
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
            quick(InkChoice.penPalette, selected: choice.penColor) { choice.penColor = $0 }
        case .highlighter:
            quick(InkChoice.highlighterPalette, selected: choice.highlighterColor) { choice.highlighterColor = $0 }
        case .shape:
            HStack(spacing: 4) {
                ForEach(ShapeKind.allCases) { kind in
                    Button {
                        choice.shapeKind = kind
                    } label: {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 40, height: 34)
                            .foregroundStyle(choice.shapeKind == kind ? Color.accentColor : Color.secondary)
                            .background(choice.shapeKind == kind ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel(kind.label)
                }
                Spacer(minLength: 0)
                more(current: choice.penColor)
            }
        case .eraser:
            HStack(spacing: 2) {
                if choice.eraserHighlighterOnly {
                    hint("형광펜만 지워요")
                } else {
                    Picker("지우개 종류", selection: $choice.eraserKind) {
                        ForEach(EraserKind.allCases) { kind in
                            Text(kind.label + " 지우개").tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, 6)
                }
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

    /// The first five colours of a palette, and a way to the rest.
    private func quick(_ palette: [UInt32], selected: UInt32, pick: @escaping (UInt32) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(palette.prefix(5), id: \.self) { rgb in
                Button {
                    pick(rgb)
                } label: {
                    Swatch(color: shown(rgb), selected: rgb == selected)
                        .frame(width: 37, height: 42)
                }
                .accessibilityLabel("색 \((palette.firstIndex(of: rgb) ?? 0) + 1)")
            }
            Spacer(minLength: 0)
            more(current: palette.prefix(5).contains(selected) ? nil : selected)
        }
    }

    /// Opens the tool's settings. It wears the colour in use when that is not one of the five beside it.
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
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 40, height: 42)
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
            .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
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
        return choice.eraserKind == .stroke ? "닿은 획을 통째로 지워요." : "문지른 자리만 지워요."
    }

    /// A switch for putting the tool down after one use.
    private func putDown(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .font(.subheadline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch choice.tool {
            case .pen:
                Picker("펜 종류", selection: $choice.penKind) {
                    ForEach(PenKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text(choice.penKind.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SliderRow(title: "굵기", value: $choice.penWidth, range: InkChoice.penWidths, shown: String(format: "%.1f", choice.penWidth), line: CGFloat(choice.penWidth))
                ColorGrid(palette: InkChoice.penPalette, selection: $choice.penColor, darkPaper: darkPaper)
            case .highlighter:
                SliderRow(title: "굵기", value: $choice.highlighterWidth, range: InkChoice.highlighterWidths, shown: String(format: "%.0f", choice.highlighterWidth), line: CGFloat(choice.highlighterWidth) * 0.8)
                ColorGrid(palette: InkChoice.highlighterPalette, selection: $choice.highlighterColor, darkPaper: darkPaper)
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
                SliderRow(title: "굵기", value: $choice.penWidth, range: InkChoice.penWidths, shown: String(format: "%.1f", choice.penWidth), line: CGFloat(choice.penWidth))
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
                // The eraser that takes whole strokes has no size: it takes what its tip touches.
                SliderRow(title: "크기", value: $choice.eraserWidth, range: InkChoice.eraserWidths, shown: "\(Int(choice.eraserWidth.rounded()))", line: nil)
                    .disabled(choice.eraserKind == .stroke && !choice.eraserHighlighterOnly)
                    .opacity(choice.eraserKind == .stroke && !choice.eraserHighlighterOnly ? 0.4 : 1)
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
        .frame(width: 372)
        .presentationCompactAdaptation(.popover)
    }
}

/// A named slider with its value beside the name, and for a thickness a line that thick.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let shown: String
    /// The height of the sample line, when the slider sets a thickness.
    let line: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let line {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 54, height: max(1, min(line * 1.6, 20)))
                }
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 9)

    private func shown(_ rgb: UInt32) -> Color {
        let color = InkChoice.color(rgb)
        return Color(uiColor: darkPaper ? color.onDarkPaper : color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("색")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(palette, id: \.self) { rgb in
                    Button {
                        selection = rgb
                    } label: {
                        Swatch(color: shown(rgb), selected: rgb == selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("색 \((palette.firstIndex(of: rgb) ?? 0) + 1)")
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
