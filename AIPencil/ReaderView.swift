import SwiftUI

/// The formula being written: a new one, or one from the page being edited.
struct MathDraft: Identifiable {
    let id = UUID()
    var editing: MathItem?
    var preset = ""
    var auto = false
}

/// One open document: its pages with handwriting, formulas and marks on top, the tool bar floating over
/// them, and beside or below them the explanation of a mark when one is open.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @AppStorage("fingerDraws") private var fingerDraws = false
    @AppStorage("showAiMarks") private var showAiMarks = true
    @State private var choice = InkChoice()
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
                    controller.placeMath(result, color: InkChoice.penColors[choice.penColor])
                }
                // The formula tool is what the hand needs next: to drag the formula into place.
                choice.tool = .formula
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
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: setUp)
    }

    private var pages: some View {
        PDFInkView(
            url: library.pdfURL(for: doc.id),
            store: DrawingStore(folder: folder),
            mathStore: mathStore,
            choice: choice,
            fingerDraws: fingerDraws,
            startPage: startPage,
            marks: marks,
            activeMark: session.panel?.questionID,
            controller: controller
        )
        .id(reloadToken)
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .top) {
            ToolBar(choice: $choice)
                .padding(.top, 10)
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
            let defaults = UserDefaults.standard
            let x = defaults.object(forKey: "demoAskX") == nil ? 130 : defaults.double(forKey: "demoAskX")
            let y = defaults.object(forKey: "demoAskY") == nil ? 88 : defaults.double(forKey: "demoAskY")
            choice.tool = .ai
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.demoMark(center: CGPoint(x: x, y: y), radius: CGSize(width: 86, height: 22))
            }
        }
        if arguments.contains("-demoFollowUp") {
            // Once the first answer is in, asks the first of the ready-made follow-ups.
            Task { @MainActor in
                for _ in 0..<150 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if session.panel?.phase == .done {
                        session.followUp(Prompts.followUps[0].text)
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
    }
}

/// The floating tool bar: the tools, then the three colours of the pen or the highlighter.
private struct ToolBar: View {
    @Binding var choice: InkChoice

    private func tint(_ tool: InkTool) -> Color {
        tool == .ai ? Color(uiColor: InkChoice.markColor) : Color.accentColor
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InkTool.allCases) { tool in
                Button {
                    choice.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(choice.tool == tool ? tint(tool) : Color.secondary)
                        .background(choice.tool == tool ? tint(tool).opacity(0.14) : Color.clear, in: Circle())
                }
                .accessibilityLabel(tool.label)
            }
            if choice.tool == .pen || choice.tool == .highlighter {
                Divider()
                    .frame(height: 26)
                    .padding(.horizontal, 6)
                let colors = choice.tool == .pen ? InkChoice.penColors : InkChoice.highlighterColors
                let selected = choice.tool == .pen ? choice.penColor : choice.highlighterColor
                ForEach(colors.indices, id: \.self) { index in
                    Button {
                        if choice.tool == .pen { choice.penColor = index } else { choice.highlighterColor = index }
                    } label: {
                        Circle()
                            .fill(Color(uiColor: colors[index]))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .padding(5)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: index == selected ? 2 : 0))
                            .frame(width: 40, height: 46)
                    }
                    .accessibilityLabel("색 \(index + 1)")
                }
            } else if choice.tool == .ai {
                Text("모르는 부분에 동그라미를 쳐 보세요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else if choice.tool == .formula {
                Text("수식을 끌어 옮기고, 길게 눌러 고쳐요")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
    }
}
