import Foundation

/// Wording sent to Claude. Kept free of anything that changes from one request to the next, so that the
/// part of a request the API keeps in its cache stays the same.
enum Prompts {
    static func system(language: String) -> String {
        let answerIn: String
        switch language {
        case "en": answerIn = "영어로"
        case "doc": answerIn = "문서가 쓰인 언어로"
        default: answerIn = "한국어로"
        }
        return """
        당신은 사용자가 태블릿으로 문서를 읽으며 공부하는 것을 돕습니다. 사용자는 이해가 안 되는 부분에 펜으로 표시(동그라미나 밑줄)를 하고, 그 설명을 문서 옆의 좁은 패널에서 바로 읽습니다. 사용자는 읽던 흐름을 끊고 싶지 않아 합니다.

        입력
        - 첫 이미지는 해당 쪽 전체이고, 빨간 선이 사용자가 표시한 부분입니다. 둘째 이미지는 그 부분을 확대한 것입니다.
        - 빨간 선과 손글씨는 사용자가 그린 것이며 문서 원문이 아닙니다. 손글씨가 표시된 부분과 관련 있어 보이면 사용자의 메모로 참고하세요.
        - 문서 본문 텍스트가 함께 주어지면 표시된 부분의 앞뒤 맥락과 용어 정의를 찾는 데 쓰세요.

        답하는 방법
        - 표시된 부분이 무엇을 뜻하는지부터 바로 말합니다. 인사, 질문 되풀이, "좋은 질문" 같은 말은 쓰지 않습니다.
        - 처음 두세 문장으로 핵심을 전하고, 그다음에 이해에 필요한 배경, 문서 안에서의 맥락, 짧은 예시를 필요한 만큼만 덧붙입니다.
        - 수식이면 기호 하나하나의 뜻과 식 전체가 말하는 바를, 그림이나 표면 읽는 법과 눈여겨볼 점을, 용어면 정의와 이 문서에서의 쓰임을 설명합니다.
        - 문서에 적힌 내용과 당신이 보탠 일반 지식이 구분되게 씁니다. 문서의 다른 쪽을 근거로 들 때는 쪽 번호를 밝힙니다(예: 3쪽).
        - 표시가 무엇을 가리키는지 애매하면 가장 그럴듯한 해석으로 설명하고, 그렇게 해석했다는 점을 한 문장으로 밝힙니다.
        - 이미지가 흐려 글자를 확신할 수 없는 부분은 추측이라고 밝힙니다.

        형식
        - \(answerIn) 답합니다.
        - 마크다운으로 씁니다. 패널이 좁으므로 문단은 짧게 하고, 표는 꼭 필요할 때만 씁니다.
        - 수식은 LaTeX로 쓰되 문장 속 수식은 $...$, 따로 떼어 보이는 수식은 $$...$$ 로 감쌉니다.
        """
    }

    static func question(page: Int) -> String {
        "\(page)쪽에서 빨간 선으로 표시한 부분을 설명해 주세요."
    }

    /// A request offered as a button under an answer: what the button says, and what is sent.
    struct FollowUp: Identifiable {
        let label: String
        let text: String
        var id: String { label }
    }

    static let followUps = [
        FollowUp(label: "더 쉽게", text: "방금 내용을 더 쉽게, 처음 배우는 사람에게 말하듯 설명해 주세요."),
        FollowUp(label: "예시로", text: "구체적인 예시를 하나 들어 설명해 주세요."),
        FollowUp(label: "한 단계씩", text: "한 단계씩 차례로 풀어서 설명해 주세요."),
        FollowUp(label: "왜 그런지", text: "왜 그렇게 되는지 이유를 더 자세히 설명해 주세요."),
        FollowUp(label: "한 줄 요약", text: "한두 문장으로 요약해 주세요."),
    ]
}

/// How much of the document's text goes along with a question. More of it costs more per question.
enum ContextScope: String, CaseIterable, Identifiable {
    case whole, nearby, pageOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whole: return "문서 전체"
        case .nearby: return "주변 20쪽"
        case .pageOnly: return "표시한 쪽만"
        }
    }

    var hint: String {
        switch self {
        case .whole: return "다른 쪽의 내용까지 참고해요. 긴 문서는 첫 질문이 비싸질 수 있어요."
        case .nearby: return "표시한 쪽이 속한 20쪽만 참고해요."
        case .pageOnly: return "쪽 이미지만 보내요. 가장 저렴하지만 앞뒤 맥락은 몰라요."
        }
    }
}

/// Picks which part of the document's text goes along with a question. The answer has to be the same for
/// every question on the same pages, or the API's cache of it is never read.
enum DocContext {
    /// Above this the whole document is not sent even when asked for: Korean text runs close to a token
    /// per character, and the first question on a document pays to cache all of it.
    static let maxChars = 120_000
    static let blockPages = 20

    struct Result {
        /// Text to send, or nil when none goes along.
        var text: String?
        /// Shown to the user when only part of the document was sent although all of it was wanted.
        var notice: String?
        /// True when the document has no text to speak of; the pages on either side then go along as pictures.
        var scanned = false
    }

    static func build(title: String, pages: [String]?, currentPage: Int, scope: ContextScope) -> Result {
        if scope == .pageOnly { return Result() }
        guard let pages, !pages.isEmpty else { return Result(scanned: true) }
        let total = pages.reduce(0) { $0 + $1.count }
        // A scanned document: a few stray characters a page are not worth sending.
        if total < 40 * pages.count { return Result(scanned: true) }
        if scope == .whole, total <= maxChars { return Result(text: format(title, pages, 0, pages.count)) }
        if pages.count <= blockPages { return Result(text: format(title, pages, 0, pages.count)) }
        let start = min(max(currentPage, 0), pages.count - 1) / blockPages * blockPages
        let end = min(pages.count, start + blockPages)
        return Result(
            text: format(title, pages, start, end),
            notice: scope == .whole ? "문서가 길어 \(start + 1)~\(end)쪽의 본문만 참고했어요." : nil
        )
    }

    private static func format(_ title: String, _ pages: [String], _ start: Int, _ end: Int) -> String {
        var out = "문서 제목: \(title)\n전체 \(pages.count)쪽"
        if start != 0 || end != pages.count { out += " 중 \(start + 1)~\(end)쪽" }
        out += "\n"
        for index in start..<end {
            let text = pages[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(글자 없음)" : pages[index]
            out += "\n===== \(index + 1)쪽 =====\n\(text)\n"
        }
        return out
    }
}
