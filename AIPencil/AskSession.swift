import PencilKit
import SwiftUI

/// Where the question in the panel stands.
enum AskPhase {
    /// Making the pictures of the marked part.
    case preparing
    /// Sent; nothing has come back yet.
    case waiting
    /// Claude has the request and is working on it.
    case thinking
    /// The answer is arriving.
    case streaming
    case done
    case error
}

/// What the explanation panel shows.
struct PanelState: Equatable {
    var questionID: UUID
    var page: Int
    var model: String
    var turns: [Turn] = []
    var phase = AskPhase.preparing
    /// The answer as far as it has arrived.
    var streaming = ""
    var error: String?
    var needsKey = false
    var notice: String?
    /// Claude is searching the web for this answer right now.
    var searching = false
}

/// The questions of the open document: asks Claude about a mark, keeps the conversation that follows,
/// and holds what the panel shows. Used from the main thread only.
final class AskSession: ObservableObject {
    /// Every question of the document, oldest first. One that was asked but not answered yet is in
    /// here too, though not on disk.
    @Published private(set) var questions: [Question] = []
    @Published private(set) var panel: PanelState?
    /// The close-up of the question in the panel.
    @Published private(set) var crop: UIImage?

    private weak var controller: ReaderController?
    private var title = ""
    private var pdfURL: URL?
    private var folder: URL?
    private var store: QuestionStore?

    /// The question that was asked and has no answer yet. It goes away if the panel is closed first.
    private var draftID: UUID?
    private var draftDrawing: PKDrawing?
    private var cropJPEG: Data?
    /// The conversation of the question in the panel, as it goes to the API. Read from disk when needed.
    private var messages: [[String: Any]] = []
    private var task: Task<Void, Never>?
    /// The document's text, page by page, once it has been read.
    private var pages: [String]?
    /// The last request had to go without the web search it asked for.
    private var searchRefused = false
    private var textTask: Task<Void, Never>?

    deinit {
        task?.cancel()
        textTask?.cancel()
    }

    /// Points the session at a document. Its saved questions are read at once, and its text in the
    /// background, ahead of the first question.
    func attach(title: String, pdfURL: URL, folder: URL, controller: ReaderController) {
        close()
        self.title = title
        self.pdfURL = pdfURL
        self.folder = folder
        self.controller = controller
        let store = QuestionStore(folder: folder)
        self.store = store
        questions = store.load()
        pages = nil
        textTask?.cancel()
        textTask = Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .utility) {
                DocText.load(pdfURL: pdfURL, folder: folder)
            }.value
            if Task.isCancelled { return }
            self?.pages = text
        }
    }

    var openQuestion: Question? {
        guard let id = panel?.questionID else { return nil }
        return find(id)
    }

    /// The saved close-up of a question.
    func cropPicture(for id: UUID) -> UIImage? {
        store.flatMap { UIImage(contentsOfFile: $0.cropURL(id).path) }
    }

    private func find(_ id: UUID) -> Question? {
        questions.first { $0.id == id }
    }

    private func amend(_ id: UUID, _ change: (inout Question) -> Void) {
        guard let at = questions.firstIndex(where: { $0.id == id }) else { return }
        var question = questions[at]
        change(&question)
        questions[at] = question
    }

    private func show(_ id: UUID, _ change: (inout PanelState) -> Void) {
        guard var state = panel, state.questionID == id else { return }
        change(&state)
        panel = state
    }

    // MARK: asking

    /// The user drew a mark with the AI pen.
    func ask(page: Int, points: [CGPoint]) {
        guard let shape = controller?.pageShape(forPage: page), !points.isEmpty else { return }
        task?.cancel()
        settle()
        // What to show close up is worked out on the page as the reader sees it: on a page shown
        // turned, an underline is only flat once it has been turned too.
        let shown = Question.bounds(of: points.map { $0.applying(shape.turn) })
        let region = AskCapture.explainRegion(mark: shown, pageSize: shape.size)
        let question = Question(
            page: page,
            path: points.flatMap { [Double($0.x), Double($0.y)] },
            region: [Double(region.minX), Double(region.minY), Double(region.maxX), Double(region.maxY)],
            model: AISettings.current.model
        )
        draftID = question.id
        draftDrawing = controller?.drawing(forPage: page)
        messages = []
        cropJPEG = nil
        crop = nil
        questions.append(question)
        panel = PanelState(questionID: question.id, page: page, model: question.model)
        DebugLog.write("ask: page \(page) points \(points.count) box \(question.bounds) region \(region) page shown \(shape.size)")
        start(question.id)
    }

    /// Asks something more about the question in the panel.
    func followUp(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let state = panel, !words.isEmpty, state.phase == .done || state.phase == .error,
              var question = find(state.questionID), question.turns.contains(where: { !$0.fromUser })
        else { return }
        if messages.isEmpty {
            messages = store?.loadMessages(for: question.id) ?? []
        }
        guard !messages.isEmpty else {
            show(question.id) {
                $0.phase = .error
                $0.error = "이 설명의 대화 기록을 읽지 못해 이어서 물을 수 없어요."
            }
            return
        }
        // After a follow-up that failed, the last thing said is already the user's: it is replaced, not stacked.
        if question.turns.last?.fromUser == true {
            question.turns.removeLast()
            if messages.last?["role"] as? String == "user" { messages.removeLast() }
        }
        question.turns.append(Turn(fromUser: true, text: words))
        messages.append(["role": "user", "content": words])
        let turns = question.turns
        amend(question.id) { $0.turns = turns }
        show(question.id) { $0.turns = turns }
        start(question.id)
    }

    func retry() {
        guard let state = panel, state.phase == .error, !messages.isEmpty || draftID == state.questionID else { return }
        start(state.questionID)
    }

    /// Shows a saved question again. Nothing is asked of Claude.
    func open(_ id: UUID) {
        guard panel?.questionID != id, let question = find(id) else { return }
        task?.cancel()
        settle()
        messages = []
        cropJPEG = nil
        panel = PanelState(
            questionID: id, page: question.page, model: question.model,
            turns: question.turns, phase: .done, notice: question.notice
        )
        crop = cropPicture(for: id)
    }

    func close() {
        task?.cancel()
        task = nil
        settle()
        messages = []
        cropJPEG = nil
        panel = nil
        crop = nil
    }

    /// Takes the mark off the page, or puts it back. The explanation is kept either way.
    func setMarkHidden(_ id: UUID, _ hidden: Bool) {
        amend(id) { $0.markHidden = hidden }
        if id != draftID, let question = find(id) { store?.save(question) }
    }

    func delete(_ id: UUID) {
        if panel?.questionID == id { close() }
        questions.removeAll { $0.id == id }
        store?.delete(id)
    }

    /// Leaves the question in the panel the way it is on disk: one that was never answered goes away,
    /// and so does a follow-up that was never answered.
    private func settle() {
        if let draft = draftID {
            questions.removeAll { $0.id == draft }
            draftID = nil
            draftDrawing = nil
        }
        if let id = panel?.questionID {
            amend(id) { question in
                if question.turns.last?.fromUser == true { question.turns.removeLast() }
            }
        }
    }

    private func start(_ id: UUID) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            await self?.run(id)
        }
    }

    /// Sends the request for the question in the panel, making its pictures first when it has none yet.
    @MainActor
    private func run(_ id: UUID) async {
        guard let asked = find(id), let pdfURL, let folder, let store else { return }
        let first = messages.isEmpty
        show(id) {
            $0.phase = first ? .preparing : .waiting
            $0.error = nil
            $0.needsKey = false
            $0.streaming = ""
            $0.searching = false
        }
        do {
            let settings = AISettings.current
            guard let key = KeyStore.load() ?? (Claude.usesStandIn ? "stand-in-key" : nil) else {
                throw ClaudeError(message: "Claude API 키가 아직 없어요. 설정에서 키를 입력하면 바로 설명을 받을 수 있어요.", needsKey: true)
            }
            // The text is read when the document is opened. A question asked straight away waits a
            // little for it, and goes without when a long document is still being read.
            var waited = 0
            while pages == nil, waited < 40 {
                try await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            let context = DocContext.build(title: title, pages: pages, currentPage: asked.page, scope: settings.scope)
            if first {
                let mathStore = MathStore(folder: folder)
                let input = CaptureInput(
                    pdfURL: pdfURL, page: asked.page, region: asked.regionRect, mark: asked.points,
                    drawing: draftDrawing, math: mathStore.load().filter { $0.page == asked.page },
                    mathStore: mathStore, withNeighbours: context.scanned
                )
                let made = await Task.detached(priority: .userInitiated) {
                    AskCapture.capture(input)
                }.value
                try Task.checkCancellation()
                guard let capture = made else { throw ClaudeError(message: "이 쪽을 읽을 수 없어요.") }
                crop = capture.crop
                cropJPEG = capture.cropJPEG
                messages = [Claude.firstMessage(
                    page: capture.pageJPEG, crop: capture.cropJPEG, pageNumber: asked.page + 1, neighbours: capture.neighbours
                )]
                let notice = context.notice
                amend(id) { $0.notice = notice }
                show(id) { $0.phase = .waiting }
            }

            let sent = messages.count
            let reply: ClaudeReply
            do {
                reply = try await converse(id, key: key, settings: settings, docText: context.text)
                // The answer may have come in just as the panel moved on to another question.
                try Task.checkCancellation()
                DebugLog.write("answer: \(reply.text.count) characters, stop reason \(reply.stopReason ?? "none"), messages \(messages.count)")
                if reply.stopReason == "refusal" {
                    throw ClaudeError(message: "이 요청에는 답하지 않았어요. 다른 부분을 표시하거나 질문을 바꿔 보세요.")
                }
                if reply.text.isEmpty {
                    throw ClaudeError(message: "답이 비어 있어요. 다시 시도해 주세요.")
                }
            } catch let error as ClaudeError {
                // An answer that is not kept is not part of the conversation either: asking again sends
                // the question as it stood.
                if messages.count > sent { messages.removeSubrange(sent...) }
                throw error
            }
            guard var answered = find(id) else { return }
            answered.turns.append(Turn(fromUser: false, text: reply.text))
            answered.model = settings.model
            let turns = answered.turns
            amend(id) {
                $0.turns = turns
                $0.model = settings.model
            }
            if draftID == id {
                draftID = nil
                draftDrawing = nil
                if let cropJPEG { store.saveCrop(cropJPEG, for: id) }
            }
            store.save(answered)
            store.saveMessages(messages, for: id)
            var cut: String?
            if reply.stopReason == "max_tokens" {
                cut = "답이 길어 중간에 끊겼어요. \"이어서\"라고 물어보면 계속돼요."
            } else if reply.stopReason == "pause_turn" {
                cut = "검색이 길어져 답을 끝내지 못했어요. 다시 물어봐 주세요."
            }
            let notes = [answered.notice, cut, searchRefused ? "이 API 키로는 웹 검색을 쓸 수 없어 검색 없이 답했어요." : nil]
                .compactMap { $0 }
                .joined(separator: "\n")
            show(id) {
                $0.phase = .done
                $0.turns = turns
                $0.streaming = ""
                $0.searching = false
                $0.model = settings.model
                $0.notice = notes.isEmpty ? nil : notes
            }
        } catch is CancellationError {
            // Stopped on purpose: another question took its place, or the panel was closed.
        } catch let error as ClaudeError {
            DebugLog.write("failed: \(error.message)")
            show(id) {
                $0.phase = .error
                $0.error = error.message
                $0.needsKey = error.needsKey
                $0.streaming = ""
                $0.searching = false
            }
        } catch {
            let message = error.localizedDescription
            show(id) {
                $0.phase = .error
                $0.error = message
                $0.streaming = ""
                $0.searching = false
            }
        }
    }

    /// Sends the conversation and waits for the answer, which is added to the conversation as it comes:
    /// in one piece, or in several when the API paused it and it was taken up again.
    @MainActor
    private func converse(_ id: UUID, key: String, settings: AISettings, docText: String?) async throws -> ClaudeReply {
        var webSearch = settings.webSearch
        searchRefused = false
        var strippedThinking = false
        var resumed = 0
        var words = ""
        var parts: [[String: Any]] = []
        var last = ClaudeReply(text: "", content: Data(), stopReason: nil)
        while true {
            do {
                let body = Claude.body(settings: settings, docText: docText, messages: messages, webSearch: webSearch)
                last = try await listen(id, to: Claude.request(key: key, model: settings.model, body: body), after: words)
            } catch let error as ClaudeError where error.status == 400 && parts.isEmpty {
                if webSearch, error.message.range(of: "search", options: .caseInsensitive) != nil {
                    // An organisation can switch web search off; the request is then turned down whole.
                    // The question is worth answering without it.
                    DebugLog.write("retrying without web search after: \(error.message)")
                    webSearch = false
                    searchRefused = true
                    continue
                }
                if !strippedThinking, Claude.hasThinking(messages) {
                    // The API checks that the thinking in earlier answers comes back exactly as it was
                    // sent. Should it turn a conversation down over that, the way out it documents is
                    // to send the conversation once more with all thinking taken out. That version is
                    // then the one kept, so that it goes back the same way next time.
                    DebugLog.write("retrying without thinking after: \(error.message)")
                    strippedThinking = true
                    messages = Claude.withoutThinking(messages)
                    if draftID != id { store?.saveMessages(messages, for: id) }
                    show(id) {
                        $0.phase = .waiting
                        $0.streaming = ""
                    }
                    continue
                }
                throw error
            }
            let content = (try? JSONSerialization.jsonObject(with: last.content)) as? [[String: Any]] ?? []
            parts += content
            messages.append(["role": "assistant", "content": content])
            words = Sources.compose(parts)
            // After a long run of searches the API hands the turn back unfinished. Sending it back as it
            // is, with nothing added, makes it carry on from where it stopped.
            if last.stopReason == "pause_turn", resumed < 3 {
                resumed += 1
                continue
            }
            return ClaudeReply(text: words, content: last.content, stopReason: last.stopReason)
        }
    }

    /// Reads one answer as it streams in, showing its words after [before], the words of the part of the
    /// turn already received.
    @MainActor
    private func listen(_ id: UUID, to request: URLRequest, after before: String) async throws -> ClaudeReply {
        var answer = before
        var shownAt = Date.distantPast
        for try await event in Claude.stream(request) {
            switch event {
            case .started:
                show(id) { state in
                    if state.phase == .waiting { state.phase = .thinking }
                }
            case .searching:
                show(id) { $0.searching = true }
            case .text(let words):
                answer += words
                // Shown at most twenty times a second: laying the answer out afresh for every few
                // letters would only slow it down.
                if Date().timeIntervalSince(shownAt) >= 0.05 {
                    shownAt = Date()
                    let soFar = answer
                    show(id) {
                        $0.phase = .streaming
                        $0.streaming = soFar
                        $0.searching = false
                    }
                }
            case .done(let reply):
                return reply
            }
        }
        try Task.checkCancellation()
        throw ClaudeError(message: "답을 받는 도중 연결이 끊겼어요. 다시 시도해 주세요.")
    }
}
