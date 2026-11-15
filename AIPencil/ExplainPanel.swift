import SwiftUI
import WebKit

/// What the panel's web page is asked to show.
struct ExplainPage: Equatable {
    var question: UUID
    var dark: Bool
    /// The last turn is an answer still arriving.
    var streaming: Bool
    var notice: String?
    var turns: [Turn]
}

/// The answer itself: a web view that lays out Markdown and, with KaTeX, the formulas in it.
struct ExplainWeb: UIViewRepresentable {
    let page: ExplainPage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        if let folder = Bundle.main.url(forResource: "Web", withExtension: nil) {
            view.loadFileURL(folder.appendingPathComponent("explain.html"), allowingReadAccessTo: folder)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.show(page)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var ready = false
        private var waiting: ExplainPage?
        private var shown: ExplainPage?

        func show(_ page: ExplainPage) {
            guard ready else {
                waiting = page
                return
            }
            guard page != shown else { return }
            // Another question: start from an empty page, scrolled to the top.
            let reset = shown?.question != page.question
            shown = page
            let state: [String: Any] = [
                "dark": page.dark,
                "streaming": page.streaming,
                "notice": page.notice ?? "",
                "turns": page.turns.map { ["user": $0.fromUser, "text": $0.text] as [String: Any] },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: state),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript((reset ? "reset();" : "") + "render(\(json));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let page = waiting {
                waiting = nil
                show(page)
            }
        }

        // A link in an answer opens in the browser; the panel itself never leaves its page.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// The explanation of a mark: the answer as it arrives, and a place to ask more.
struct ExplainPanel: View {
    @ObservedObject var session: AskSession
    var onOpenSettings: () -> Void
    /// Asked to bring the mark of this question into view.
    var onLocate: (Question) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        if let panel = session.panel {
            VStack(spacing: 0) {
                header(panel)
                Divider()
                answer(panel)
                footer(panel)
            }
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func header(_ panel: PanelState) -> some View {
        HStack(spacing: 10) {
            Button {
                if let question = session.openQuestion { onLocate(question) }
            } label: {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let crop = session.crop {
                        Image(uiImage: crop)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 54, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("표시한 부분으로 이동")

            VStack(alignment: .leading, spacing: 1) {
                Text("\(panel.page + 1)쪽 설명")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(AIModel.name(panel.model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    UIPasteboard.general.string = panel.turns.filter { !$0.fromUser }.map(\.text).joined(separator: "\n\n")
                } label: {
                    Label("설명 복사", systemImage: "doc.on.doc")
                }
                .disabled(!panel.turns.contains { !$0.fromUser })
                if let question = session.openQuestion {
                    Button {
                        session.setMarkHidden(question.id, !question.markHidden)
                    } label: {
                        Label(
                            question.markHidden ? "쪽에 표시 다시 보이기" : "쪽의 표시만 지우기",
                            systemImage: question.markHidden ? "eye" : "eye.slash"
                        )
                    }
                    Button(role: .destructive) {
                        session.delete(question.id)
                    } label: {
                        Label("이 표시와 설명 삭제", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("더 보기")
            Button {
                session.close()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("닫기")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private func page(_ panel: PanelState) -> ExplainPage {
        var turns = panel.turns
        let arriving = !panel.streaming.isEmpty
        if arriving { turns.append(Turn(fromUser: false, text: panel.streaming)) }
        return ExplainPage(
            question: panel.questionID, dark: colorScheme == .dark, streaming: arriving,
            notice: panel.phase == .done ? panel.notice : nil, turns: turns
        )
    }

    @ViewBuilder
    private func answer(_ panel: PanelState) -> some View {
        let hasWords = !panel.turns.isEmpty || !panel.streaming.isEmpty
        ZStack {
            ExplainWeb(page: page(panel))
                .opacity(hasWords ? 1 : 0)
            if !hasWords {
                if panel.phase == .error {
                    problem(panel)
                        .padding(24)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(waitingText(panel.phase))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waitingText(_ phase: AskPhase) -> String {
        switch phase {
        case .preparing: return "표시한 부분을 살펴보는 중"
        case .waiting: return "Claude에게 보내는 중"
        default: return "설명을 준비하는 중"
        }
    }

    /// What went wrong, and what can be done about it.
    private func problem(_ panel: PanelState) -> some View {
        VStack(spacing: 14) {
            Image(systemName: panel.needsKey ? "key" : "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(panel.error ?? "문제가 생겼어요.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if panel.needsKey {
                    Button("설정 열기", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                }
                Button("다시 시도") { session.retry() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Under an answer: how the follow-up is doing, or the ready-made requests, and the place to type one.
    @ViewBuilder
    private func footer(_ panel: PanelState) -> some View {
        if panel.turns.contains(where: { !$0.fromUser }) {
            Divider()
            if panel.phase == .error {
                HStack(spacing: 10) {
                    Text(panel.error ?? "문제가 생겼어요.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if panel.needsKey {
                        Button("설정 열기", action: onOpenSettings)
                    }
                    Button("다시 시도") { session.retry() }
                }
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            } else if panel.phase != .done {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("답을 쓰는 중")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Prompts.followUps) { item in
                            Button(item.label) { session.followUp(item.text) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 10)
            }
            inputBar(panel)
        }
    }

    private func inputBar(_ panel: PanelState) -> some View {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = (panel.phase == .done || panel.phase == .error) && !words.isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("이어서 질문하기", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 19))
            Button {
                session.followUp(words)
                draft = ""
                typing = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(!ready)
            .accessibilityLabel("보내기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Every question asked about the document, to open one again or throw it away.
struct QuestionListView: View {
    @ObservedObject var session: AskSession
    var onPick: (Question) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The close-up of each question, read once when the list opens.
    @State private var pictures: [UUID: UIImage] = [:]

    private var answered: [Question] {
        session.questions
            .filter { !$0.turns.isEmpty }
            .sorted { ($0.page, $0.createdAt) < ($1.page, $1.createdAt) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if answered.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("아직 질문이 없어요")
                            .font(.headline)
                        Text("AI 펜으로 모르는 부분에 동그라미를 치면 여기에 모여요.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List {
                        ForEach(answered) { question in
                            Button {
                                onPick(question)
                                dismiss()
                            } label: {
                                row(question)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    session.delete(question.id)
                                } label: {
                                    Label("삭제", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("질문 목록")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                for question in answered where pictures[question.id] == nil {
                    pictures[question.id] = session.cropPicture(for: question.id)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private func row(_ question: Question) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let picture = pictures[question.id] {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 64, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(question.page + 1)쪽")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(uiColor: InkChoice.markColor))
                    Text(question.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(summary(question))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if question.markHidden {
                Image(systemName: "eye.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("쪽에서 표시를 지운 질문")
            }
        }
        .padding(.vertical, 2)
    }

    /// The opening paragraph of the answer, with the marks of Markdown and LaTeX taken out.
    private func summary(_ question: Question) -> String {
        let text = question.turns.first { !$0.fromUser }?.text ?? ""
        let opening = text.components(separatedBy: "\n\n").first { paragraph in
            !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? text
        let plain = opening
            .replacingOccurrences(of: "\n", with: " ")
            .filter { !"*#$`\\".contains($0) }
        return String(plain.prefix(140))
    }
}
