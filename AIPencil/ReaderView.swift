import PDFKit
import SwiftUI

/// The formula being written: a new one, or one from the page being edited.
struct MathDraft: Identifiable {
    let id = UUID()
    var editing: MathItem?
    var preset = ""
    var auto = false
}

/// One open document: the tool bar, under it the pages with handwriting, formulas and marks on top, and
/// beside or below them the explanation of a mark when one is open.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @AppStorage("fingerDraws") private var fingerDraws = false
    @AppStorage("showAiMarks") private var showAiMarks = true
    @AppStorage("pageLayout") private var layoutMode = PageLayoutMode.vertical
    @State private var choice = InkChoice.saved()
    /// The tool that was in hand before the one that is now, for the Pencil's "back to the last tool".
    @State private var previousTool = InkTool.eraser
    @StateObject private var controller = ReaderController()
    @StateObject private var session = AskSession()
    /// Changed to have the page view built afresh, after the document's pages were renumbered.
    @State private var reloadToken = UUID()
    /// The build server can ask for a page to start on ("-demoPage 2"); otherwise this is the first page.
    @State private var startPage = max(0, UserDefaults.standard.integer(forKey: "demoPage"))
    @State private var mathDraft: MathDraft?
    @State private var errorText: String?
    @State private var showingSettings = false
    @State private var showingQuestions = false
    @State private var showingPages = false
    @State private var showingOptions = false
    @State private var ready = false

    private var folder: URL { library.folder(for: doc.id) }
    private var mathStore: MathStore { MathStore(folder: folder) }

    /// The marks drawn on the pages: all of them, less the ones taken off the page, unless marks are switched off.
    private var marks: [Question] {
        showAiMarks ? session.questions.filter { !$0.markHidden } : []
    }

    var body: some View {
        GeometryReader { geometry in
            // On a wide screen the explanation stands beside the pages; otherwise it lies below them.
            // ("-demoWide YES" lets the build server, whose simulator stands upright, see the wide form.)
            let wide = UserDefaults.standard.bool(forKey: "demoWide")
                || (geometry.size.width >= 820 && geometry.size.width > geometry.size.height)
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                pages
                if session.panel != nil {
                    ExplainPanel(session: session, onOpenSettings: { showingSettings = true }, onLocate: locate)
                        .frame(
                            width: wide ? min(460, geometry.size.width * 0.4) : nil,
                            height: wide ? nil : min(max(320, geometry.size.height * 0.46), max(200, geometry.size.height - 160))
                        )
                        .overlay(alignment: wide ? .leading : .top) {
                            Rectangle()
                                .fill(Color(uiColor: .separator))
                                .frame(width: wide ? 0.5 : nil, height: wide ? nil : 0.5)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .navigationTitle(doc.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                Menu {
                    Picker("보기 방식", selection: $layoutMode) {
                        ForEach(PageLayoutMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    Divider()
                    Button {
                        showingPages = true
                    } label: {
                        Label("쪽 이동", systemImage: "square.grid.2x2")
                    }
                    Button {
                        addBlankPage()
                    } label: {
                        Label("이 쪽 뒤에 빈 쪽 추가", systemImage: "doc.badge.plus")
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
        .sheet(isPresented: $showingPages) {
            PageNavigator(url: library.pdfURL(for: doc.id), current: controller.pageIndex) { index in
                controller.go(toPage: index)
            }
        }
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onChange(of: choice) {
            choice.save()
        }
        .onAppear(perform: setUp)
    }

    /// The tool bar has a strip of its own above the pages. Floating over them it covered the top of
    /// the first page, which could then neither be read nor written on.
    private var pages: some View {
        VStack(spacing: 0) {
            ToolBar(
                choice: $choice, showingOptions: $showingOptions,
                canUndo: controller.canUndo, canRedo: controller.canRedo,
                onPick: pick, onUndo: controller.undo, onRedo: controller.redo
            )
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            // Above the pages, so that the bar's shadow falls on them.
            .zIndex(1)
            PDFInkView(
                url: library.pdfURL(for: doc.id),
                store: DrawingStore(folder: folder),
                mathStore: mathStore,
                choice: choice,
                fingerDraws: fingerDraws,
                layout: layoutMode,
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
                        showingPages = true
                    } label: {
                        Text("\(controller.pageIndex + 1) / \(controller.pageCount)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    .padding(.bottom, 10)
                    .accessibilityLabel("\(controller.pageCount)쪽 중 \(controller.pageIndex + 1)쪽, 쪽 이동")
                }
            }
        }
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
        controller.onDeleteMark = { id in
            session.delete(id)
        }
        controller.onPencil = { action in
            pencil(action)
        }
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

    private func addBlankPage() {
        guard let index = controller.currentPageIndex else { return }
        session.close()
        // Everything on disk first, and nothing more written by the old page view: its page numbers are about to be wrong.
        controller.saveAndRetire()
        do {
            try library.insertBlankPage(in: doc, after: index)
            startPage = index + 1
        } catch {
            errorText = error.localizedDescription
            startPage = index
        }
        // The questions' page numbers changed on disk along with everything else.
        session.attach(title: doc.title, pdfURL: library.pdfURL(for: doc.id), folder: folder, controller: controller)
        reloadToken = UUID()
    }

    /// The build server starts the app with these to take pictures of things no one is there to tap.
    private func runDemoIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults.standard
        let session = self.session
        let controller = self.controller
        if arguments.contains("-demoMath") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                mathDraft = MathDraft(preset: "\\frac{a}{b} = \\sqrt{x^2 + 1}", auto: true)
            }
        }
        if arguments.contains("-demoAddPage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                addBlankPage()
            }
        }
        if arguments.contains("-demoAsk") {
            // A ring drawn with the AI pen round the place given ("-demoAskX 300 -demoAskY 200"), or
            // round the heading of the bundled sample.
            let x = defaults.object(forKey: "demoAskX") == nil ? 130 : defaults.double(forKey: "demoAskX")
            let y = defaults.object(forKey: "demoAskY") == nil ? 88 : defaults.double(forKey: "demoAskY")
            choice.tool = .ai
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.demoMark(center: CGPoint(x: x, y: y), radius: CGSize(width: 86, height: 22))
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let last = session.questions.last {
                    session.open(last.id)
                    locate(last)
                }
            }
        }
        if arguments.contains("-demoQuestions") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingQuestions = true
            }
        }
        if arguments.contains("-demoOptions") {
            choice.tool = .pen
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingOptions = true
            }
        }
        if arguments.contains("-demoPages") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showingPages = true
            }
        }
        // "-demoZoom 2.5" zooms in that many times past fitting the page, to see how sharp ink stays.
        let zoom = defaults.double(forKey: "demoZoom")
        if zoom > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                controller.demoZoom(zoom)
            }
        }
    }
}

/// The tool bar: undo and redo, the tools, then the colours of the pen or the highlighter, or a word on
/// how the tool in hand is used. Touching the tool in hand again opens its settings.
private struct ToolBar: View {
    @Binding var choice: InkChoice
    @Binding var showingOptions: Bool
    var canUndo: Bool
    var canRedo: Bool
    var onPick: (InkTool) -> Void
    var onUndo: () -> Void
    var onRedo: () -> Void

    private func tint(_ tool: InkTool) -> Color {
        tool == .ai ? Color(uiColor: InkChoice.markColor) : Color.accentColor
    }

    private var hint: String? {
        switch choice.tool {
        case .ai: return "모르는 부분에 동그라미를 쳐 보세요"
        case .formula: return "수식을 끌어 옮기고, 길게 눌러 고쳐요"
        default: return nil
        }
    }

    private var hasOptions: Bool {
        choice.tool == .pen || choice.tool == .highlighter || choice.tool == .eraser
    }

    // What does not fit on one line is left out: the hint or the colours, which are in the tool's
    // settings as well.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(withExtras: true)
            bar(withExtras: false)
        }
        .popover(isPresented: $showingOptions) {
            ToolOptions(choice: $choice)
        }
    }

    private func bar(withExtras: Bool) -> some View {
        HStack(spacing: 2) {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 42)
            }
            .disabled(!canUndo)
            .accessibilityLabel("실행 취소")
            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 42)
            }
            .disabled(!canRedo)
            .accessibilityLabel("다시 실행")
            Divider()
                .frame(height: 26)
                .padding(.horizontal, 4)
            ForEach(InkTool.allCases) { tool in
                Button {
                    if choice.tool == tool, hasOptions {
                        showingOptions = true
                    } else {
                        onPick(tool)
                    }
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 42)
                        .foregroundStyle(choice.tool == tool ? tint(tool) : Color.secondary)
                        .background(choice.tool == tool ? tint(tool).opacity(0.14) : Color.clear, in: Circle())
                }
                .accessibilityLabel(tool.label)
            }
            if withExtras, choice.tool == .pen || choice.tool == .highlighter {
                Divider()
                    .frame(height: 26)
                    .padding(.horizontal, 6)
                let colors = choice.tool == .pen ? InkChoice.penColors : InkChoice.highlighterColors
                let selected = choice.tool == .pen ? choice.penColor : choice.highlighterColor
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        if choice.tool == .pen { choice.penColor = index } else { choice.highlighterColor = index }
                    } label: {
                        Swatch(color: colors[index], selected: index == selected)
                            .frame(width: 36, height: 42)
                    }
                    .accessibilityLabel("색 \(index + 1)")
                }
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 40, height: 42)
                        .foregroundStyle(Color.secondary)
                }
                .accessibilityLabel("펜 설정")
            } else if withExtras, let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground), in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
    }
}

/// A round colour to pick.
private struct Swatch: View {
    let color: UIColor
    let selected: Bool

    var body: some View {
        Circle()
            .fill(Color(uiColor: color))
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .padding(4)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: selected ? 2 : 0))
    }
}

/// The settings of the tool in hand: the kind of pen, how thick, which colour.
private struct ToolOptions: View {
    @Binding var choice: InkChoice

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
                WidthRow(widths: InkChoice.penWidths.map { min(18, $0 * 3) }, selection: $choice.penWidth)
                ColorRow(colors: InkChoice.penColors, selection: $choice.penColor)
            case .highlighter:
                WidthRow(widths: InkChoice.highlighterWidths.map { min(22, $0) }, selection: $choice.highlighterWidth)
                ColorRow(colors: InkChoice.highlighterColors, selection: $choice.highlighterColor)
            case .eraser:
                Picker("지우개 종류", selection: $choice.eraserKind) {
                    ForEach(EraserKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Text(choice.eraserKind == .stroke ? "닿은 획을 통째로 지워요" : "문지른 자리만 지워요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(18)
        .frame(width: 340)
        .presentationCompactAdaptation(.popover)
    }
}

/// The thicknesses to pick from, each shown as a bar that thick.
private struct WidthRow: View {
    /// How tall each bar is drawn, in points.
    let widths: [CGFloat]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("굵기")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(widths.indices, id: \.self) { index in
                    Button {
                        selection = index
                    } label: {
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: 30, height: widths[index])
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                index == selection ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("굵기 \(index + 1)")
                }
            }
        }
    }
}

private struct ColorRow: View {
    let colors: [UIColor]
    @Binding var selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("색")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        selection = index
                    } label: {
                        Swatch(color: colors[index], selected: index == selection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("색 \(index + 1)")
                }
            }
        }
    }
}

/// Every page as a small picture, to jump to one.
private struct PageNavigator: View {
    let url: URL
    let current: Int
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 18)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(0..<(document?.pageCount ?? 0), id: \.self) { index in
                            Button {
                                onPick(index)
                                dismiss()
                            } label: {
                                PageThumbnail(document: document, index: index, current: index == current)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: document?.pageCount) {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .navigationTitle("쪽 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .onAppear {
            if document == nil { document = PDFDocument(url: url) }
        }
    }
}

private struct PageThumbnail: View {
    let document: PDFDocument?
    let index: Int
    let current: Bool
    @State private var picture: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let picture {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                }
            }
            .aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: current ? 2.5 : 1))
            Text("\(index + 1)")
                .font(.caption.weight(current ? .bold : .regular).monospacedDigit())
                .foregroundStyle(current ? Color.accentColor : Color.secondary)
        }
        .task(id: index) {
            guard picture == nil, let page = document?.page(at: index) else { return }
            picture = page.thumbnail(of: CGSize(width: 340, height: 480), for: .cropBox)
        }
    }
}
