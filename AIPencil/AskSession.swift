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
        guard let size = controller?.pageSize(forPage: page), !points.isEmpty else { return }
        task?.cancel()
        settle()
        let region = AskCapture.explainRegion(mark: Question.bounds(of: points), pageSize: size)
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
        DebugLog.write("ask: page \(page) points \(points.count) box \(question.bounds) region \(region) page size \(size)")
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
        crop = store.flatMap { UIImage(contentsOfFile: $0.cropURL(id).path) }
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

            let reply = try await converse(id, key: key, settings: settings, docText: context.text)
            // The answer may have come in just as the panel moved on to another question.
            try Task.checkCancellation()
            DebugLog.write("answer: \(reply.text.count) characters, stop reason \(reply.stopReason ?? "none"), messages \(messages.count + 1)")
            if reply.stopReason == "refusal" {
                throw ClaudeError(message: "이 요청에는 답하지 않았어요. 다른 부분을 표시하거나 질문을 바꿔 보세요.")
            }
            if reply.text.isEmpty {
                throw ClaudeError(message: "답이 비어 있어요. 다시 시도해 주세요.")
            }
            guard var answered = find(id) else { return }
            answered.turns.append(Turn(fromUser: false, text: reply.text))
            answered.model = settings.model
            let content = (try? JSONSerialization.jsonObject(with: reply.content)) as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])
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
            let cut = reply.stopReason == "max_tokens" ? "답이 길어 중간에 끊겼어요. \"이어서\"라고 물어보면 계속돼요." : nil
            let notes = [answered.notice, cut].compactMap { $0 }.joined(separator: "\n")
            show(id) {
                $0.phase = .done
                $0.turns = turns
                $0.streaming = ""
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
            }
        } catch {
            let message = error.localizedDescription
            show(id) {
                $0.phase = .error
                $0.error = message
                $0.streaming = ""
            }
        }
    }

    /// Sends the conversation and waits for the answer. The API checks that the thinking in earlier
    /// answers comes back exactly as it was sent; should it turn a conversation down over that, the way
    /// out it documents is to send the conversation once more with all thinking taken out. That
    /// version is then the one kept, so that it goes back the same way next time.
    @MainActor
    private func converse(_ id: UUID, key: String, settings: AISettings, docText: String?) async throws -> ClaudeReply {
        do {
            let body = Claude.body(settings: settings, docText: docText, messages: messages)
            return try await listen(id, to: Claude.request(key: key, model: settings.model, body: body))
        } catch let error as ClaudeError where error.status == 400 && Claude.hasThinking(messages) {
            DebugLog.write("retrying without thinking after: \(error.message)")
            messages = Claude.withoutThinking(messages)
            if draftID != id { store?.saveMessages(messages, for: id) }
            show(id) {
                $0.phase = .waiting
                $0.streaming = ""
            }
            let body = Claude.body(settings: settings, docText: docText, messages: messages)
            return try await listen(id, to: Claude.request(key: key, model: settings.model, body: body))
        }
    }

    @MainActor
    private func listen(_ id: UUID, to request: URLRequest) async throws -> ClaudeReply {
        var answer = ""
        var shownAt = Date.distantPast
        for try await event in Claude.stream(request) {
            switch event {
            case .started:
                show(id) { state in
                    if state.phase == .waiting { state.phase = .thinking }
                }
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
