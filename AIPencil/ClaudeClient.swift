import Foundation

/// A failure worth showing as it is. [needsKey] tells the panel to offer the settings screen.
struct ClaudeError: LocalizedError {
    var message: String
    var needsKey = false
    /// The HTTP status, when the API answered with one.
    var status: Int?

    var errorDescription: String? { message }
}

/// A finished answer.
struct ClaudeReply {
    /// The words of the answer, with the web pages they cite.
    var text: String
    /// Every block of the answer as JSON (an array), in the form it goes back to the API on a follow-up.
    var content: Data
    var stopReason: String?
}

enum ClaudeEvent {
    /// The request reached Claude and it is working on an answer.
    case started
    /// Claude has gone to search the web; words follow once it has read what it found.
    case searching
    case text(String)
    case done(ClaudeReply)
}

/// Talks to the Claude API over plain HTTPS (there is no official Swift SDK): builds the request for
/// "explain what I circled" and reads the answer as it streams in.
enum Claude {
    static let version = "2026-10-21"
    private static let home = "https://api.anthropic.com"

    /// Where requests go. A debug build can be pointed at the stand-in server in tools/ with "-apiBase";
    /// a release build always talks to Anthropic.
    static var base: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let at = arguments.firstIndex(of: "-apiBase"), at + 1 < arguments.count {
            return arguments[at + 1]
        }
        #endif
        return home
    }

    static var usesStandIn: Bool { base != home }

    /// Opus and Sonnet can decline a request on safety grounds; with this the API then tries a fallback
    /// model inside the same call.
    static func usesFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus") || model.hasPrefix("claude-sonnet")
    }

    // MARK: building a request

    private static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    private static func image(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    /// The first message of a conversation: the page, the close-up and the request.
    static func firstMessage(page: Data, crop: Data, pageNumber: Int, neighbours: [(number: Int, jpeg: Data)]) -> [String: Any] {
        var blocks = [
            text("\(pageNumber)쪽 전체 (빨간 선이 표시한 부분):"), image(page),
            text("표시한 부분 확대:"), image(crop),
        ]
        for neighbour in neighbours {
            blocks.append(text("참고용 \(neighbour.number)쪽:"))
            blocks.append(image(neighbour.jpeg))
        }
        blocks.append(text(Prompts.question(page: pageNumber)))
        return ["role": "user", "content": blocks]
    }

    /// The system prompt is two blocks: fixed instructions, then the document's text marked to be cached
    /// for an hour, so every later question about the same document reads it from the cache instead of
    /// paying for it again. Thinking is left to the model; effort is the speed/thoroughness control.
    static func body(settings: AISettings, docText: String?, messages: [[String: Any]], webSearch: Bool) -> [String: Any] {
        var system = [text(Prompts.system(language: settings.language, webSearch: webSearch))]
        if let docText, !docText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var block = text("사용자가 읽고 있는 문서의 본문입니다.\n\n" + docText)
            block["cache_control"] = ["type": "ephemeral", "ttl": "1h"]
            system.append(block)
        }
        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 16000,
            "stream": true,
            "output_config": ["effort": settings.depth.effort],
            "system": system,
            "messages": messages,
            // Caches the conversation so far, which makes follow-up questions cheaper.
            "cache_control": ["type": "ephemeral"],
        ]
        if usesFallbacks(settings.model) { body["fallbacks"] = "default" }
        // Claude decides for itself whether a question needs the web. This version of the tool hands the
        // results straight to the model and is the one all three models take.
        if webSearch {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": webSearchUses]]
        }
        return body
    }

    /// How many searches one answer may make.
    static let webSearchUses = 3

    static func request(key: String, model: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: base + "/v1/messages") else {
            throw ClaudeError(message: "요청 주소가 올바르지 않아요.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        if usesFallbacks(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        // Keys in a fixed order: the same conversation is then the same bytes every time it is sent.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    // MARK: reading the answer

    /// Puts the answer together from the events of the stream. Blocks are kept as the API sent them,
    /// whatever their kind, because a follow-up has to send the answer back unchanged: thinking blocks
    /// with their signatures, empty ones too.
    struct Accumulator {
        private var blocks: [Int: [String: Any]] = [:]
        /// The input of a tool call arrives as pieces of JSON text, put together here until the block ends.
        private var inputs: [Int: String] = [:]
        private(set) var stopReason: String?
        private(set) var finished = false
        /// Set by the event just taken when it opened a search of the web.
        private(set) var startedSearch = false

        /// Takes one event. Hands back the words it added to the answer, if it added any.
        mutating func take(_ event: [String: Any]) throws -> String? {
            startedSearch = false
            switch event["type"] as? String {
            case "content_block_start":
                if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                    blocks[index] = block
                    startedSearch = block["type"] as? String == "server_tool_use"
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any],
                      let kind = delta["type"] as? String
                else { return nil }
                if kind == "input_json_delta" {
                    inputs[index, default: ""] += delta["partial_json"] as? String ?? ""
                    return nil
                }
                if kind == "citations_delta" {
                    // A page the block's words rest on. It is kept whole: part of it is sealed and has to
                    // go back to the API as it came.
                    if let citation = delta["citation"] {
                        var block = blocks[index] ?? [:]
                        block["citations"] = (block["citations"] as? [Any] ?? []) + [citation]
                        blocks[index] = block
                    }
                    return nil
                }
                // A "text_delta" adds to the block's "text", a "thinking_delta" to its "thinking", a
                // "signature_delta" to its "signature".
                guard kind.hasSuffix("_delta") else { return nil }
                let field = String(kind.dropLast("_delta".count))
                guard let piece = delta[field] as? String else { return nil }
                var block = blocks[index] ?? [:]
                block[field] = (block[field] as? String ?? "") + piece
                blocks[index] = block
                if field == "text" { return piece }
            case "content_block_stop":
                if let index = event["index"] as? Int, let json = inputs.removeValue(forKey: index), var block = blocks[index] {
                    block["input"] = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [String: Any]()
                    blocks[index] = block
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "message_stop":
                finished = true
            case "error":
                let error = event["error"] as? [String: Any]
                throw Claude.failure(status: nil, kind: error?["type"] as? String, message: error?["message"] as? String)
            default:
                break
            }
            return nil
        }

        func reply() throws -> ClaudeReply {
            guard finished else {
                throw ClaudeError(message: "답을 받는 도중 연결이 끊겼어요. 다시 시도해 주세요.")
            }
            let content = blocks.keys.sorted().compactMap { blocks[$0] }
            let data = try JSONSerialization.data(withJSONObject: Claude.echo(content), options: [.sortedKeys])
            return ClaudeReply(text: Sources.compose(content), content: data, stopReason: stopReason)
        }
    }

    /// An answer's blocks in the form they go back to the API. They go back unchanged, with one
    /// exception the API asks for: when a fallback model took over part-way through an answer, the
    /// thinking from before the switch is left out, and the block that marks the switch stays where it was.
    static func echo(_ content: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = content.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return content }
        // A search and its result stay only as a pair.
        let answered = Set(content.compactMap { $0["tool_use_id"] as? String })
        var kept: [[String: Any]] = []
        for (index, block) in content.enumerated() {
            let type = block["type"] as? String ?? ""
            let paired = (type == "server_tool_use" && answered.contains(block["id"] as? String ?? ""))
                || (type.hasSuffix("_tool_result") && block["tool_use_id"] != nil)
            if index >= boundary || type == "text" || type == "fallback" || paired { kept.append(block) }
        }
        return kept
    }

    static func hasThinking(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            (message["content"] as? [[String: Any]])?.contains { isThinking($0) } ?? false
        }
    }

    /// The conversation with every thinking block taken out of the answers.
    static func withoutThinking(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else {
                return message
            }
            var copy = message
            copy["content"] = content.filter { !isThinking($0) }
            return copy
        }
    }

    private static func isThinking(_ block: [String: Any]) -> Bool {
        let type = block["type"] as? String
        return type == "thinking" || type == "redacted_thinking"
    }

    /// Sends the request and hands back the answer as it arrives. Stopping the loop that reads the
    /// stream closes the connection.
    static func stream(_ request: URLRequest) -> AsyncThrowingStream<ClaudeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 65536 { break }
                        }
                        throw failure(status: status, body: data)
                    }
                    var accumulator = Accumulator()
                    var started = false
                    // Each event's data is one line of JSON that names its own kind, so the "event:"
                    // lines and the blank lines between events are not needed.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                        if !started {
                            started = true
                            continuation.yield(.started)
                        }
                        if let words = try accumulator.take(event) {
                            continuation.yield(.text(words))
                        }
                        if accumulator.startedSearch {
                            continuation.yield(.searching)
                        }
                    }
                    try Task.checkCancellation()
                    let reply = try accumulator.reply()
                    continuation.yield(.done(reply))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: translate(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Checks a key without spending tokens, by looking up the chosen model with it.
    static func verify(key: String, model: String) async -> Result<String, ClaudeError> {
        guard let url = URL(string: base + "/v1/models/" + model) else {
            return .failure(ClaudeError(message: "요청 주소가 올바르지 않아요."))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return .success("연결됐어요. \(AIModel.name(model)) 모델을 쓸 수 있어요.")
            }
            return .failure(failure(status: status, body: data))
        } catch {
            let translated = translate(error)
            return .failure(translated as? ClaudeError ?? ClaudeError(message: "확인하지 못했어요. 다시 시도해 주세요."))
        }
    }

    // MARK: failures

    private static func failure(status: Int, body: Data) -> ClaudeError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        return failure(status: status, kind: error?["type"] as? String, message: error?["message"] as? String)
    }

    static func failure(status: Int?, kind: String?, message: String?) -> ClaudeError {
        if status == 401 || kind == "authentication_error" {
            return ClaudeError(message: "API 키가 올바르지 않아요. 설정에서 다시 입력해 주세요.", needsKey: true, status: status)
        }
        if status == 403 || kind == "permission_error" {
            return ClaudeError(message: "이 API 키로는 선택한 모델을 쓸 수 없어요. 설정에서 모델을 바꿔 보세요.", status: status)
        }
        if status == 429 || kind == "rate_limit_error" {
            return ClaudeError(message: "요청 한도에 걸렸어요. 잠시 후 다시 시도해 주세요.", status: status)
        }
        if status == 529 || kind == "overloaded_error" {
            return ClaudeError(message: "Claude 서버가 혼잡해요. 잠시 후 다시 시도해 주세요.", status: status)
        }
        let code = status.map { "(\($0))" } ?? ""
        let detail = message ?? kind ?? ""
        return ClaudeError(message: "Claude 오류\(code): \(detail)".trimmingCharacters(in: .whitespaces), status: status)
    }

    /// Turns whatever went wrong into something to show. A request that was stopped on purpose stays
    /// a cancellation, which nobody is shown.
    private static func translate(_ error: Error) -> Error {
        if error is ClaudeError || error is CancellationError { return error }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return ClaudeError(message: "인터넷에 연결할 수 없어요. 연결을 확인하고 다시 시도해 주세요.")
        }
        return ClaudeError(message: error.localizedDescription)
    }
}
