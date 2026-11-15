import SwiftUI

/// The formula being written: a new one, or one from the page being edited.
struct MathDraft: Identifiable {
    let id = UUID()
    var editing: MathItem?
    var preset = ""
    var auto = false
}

/// One open document: its pages with handwriting and formulas on top, and the tool bar floating over them.
struct ReaderView: View {
    let doc: Doc
    @EnvironmentObject private var library: Library
    @AppStorage("fingerDraws") private var fingerDraws = false
    @State private var choice = InkChoice()
    @StateObject private var controller = ReaderController()
    /// Changed to have the page view built afresh, after the document's pages were renumbered.
    @State private var reloadToken = UUID()
    @State private var startPage = 0
    @State private var mathDraft: MathDraft?
    @State private var errorText: String?
    @State private var ranDemo = false

    private var mathStore: MathStore { MathStore(folder: library.folder(for: doc.id)) }

    var body: some View {
        PDFInkView(
            url: library.pdfURL(for: doc.id),
            store: DrawingStore(folder: library.folder(for: doc.id)),
            mathStore: mathStore,
            choice: choice,
            fingerDraws: fingerDraws,
            startPage: startPage,
            controller: controller
        )
        .id(reloadToken)
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            ToolBar(choice: $choice)
                .padding(.top, 10)
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
        .alert("하지 못했어요", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onAppear {
            controller.onEditMath = { item in
                mathDraft = MathDraft(editing: item)
            }
            runDemoIfAsked()
        }
    }

    private func addBlankPage() {
        guard let index = controller.currentPageIndex else { return }
        // Everything on disk first, and nothing more written by the old page view: its page numbers are about to be wrong.
        controller.saveAndRetire()
        do {
            try library.insertBlankPage(in: doc, after: index)
            startPage = index + 1
        } catch {
            errorText = error.localizedDescription
            startPage = index
        }
        reloadToken = UUID()
    }

    /// The build server starts the app with these to take pictures of things no one is there to tap.
    private func runDemoIfAsked() {
        guard !ranDemo else { return }
        ranDemo = true
        let arguments = ProcessInfo.processInfo.arguments
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
    }
}

/// The floating tool bar: the tools, then the three colours of the pen or the highlighter.
private struct ToolBar: View {
    @Binding var choice: InkChoice

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InkTool.allCases) { tool in
                Button {
                    choice.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(choice.tool == tool ? Color.accentColor : Color.secondary)
                        .background(choice.tool == tool ? Color.accentColor.opacity(0.14) : Color.clear, in: Circle())
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
