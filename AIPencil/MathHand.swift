import PencilKit
import SwiftUI

/// What of a formula goes on the page: the formula typeset, the LaTeX it is written in, or both.
enum MathPut: String, CaseIterable, Identifiable {
    case formula, code, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formula: return "수식"
        case .code: return "LaTeX 코드"
        case .both: return "둘 다"
        }
    }

    /// [tex] as letters to be read, not typeset. None when no mark is left to fence it with.
    static func verbatim(_ tex: String) -> String? {
        let line = tex.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
        let marks: [Character] = ["|", "!", "+", "@", "/", ";", ":"]
        guard let mark = marks.first(where: { !line.contains($0) }) else { return nil }
        return "\\verb" + String(mark) + line + String(mark)
    }

    /// What is typeset for [tex]: the preview shows it, and the picture for the page is taken of it.
    func shown(_ tex: String) -> String {
        guard self != .formula, let code = MathPut.verbatim(tex) else { return tex }
        if self == .code { return code }
        return "\\begin{gathered} " + tex + " \\\\[0.4em] {\\small " + code + "} \\end{gathered}"
    }
}

/// A formula written by hand, read by Claude into LaTeX.
final class MathHand: NSObject, ObservableObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()
    @Published private(set) var empty = true
    @Published private(set) var working = false
    @Published private(set) var failure: ClaudeError?
    private var task: Task<Void, Never>?

    /// What Claude answers when it can make out no formula.
    static let nothing = "NONE"

    override init() {
        super.init()
        canvas.delegate = self
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        // Black on white whatever the iPad is set to: it is paper, and Claude is sent what is seen.
        canvas.overrideUserInterfaceStyle = .light
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.alwaysBounceVertical = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let none = canvasView.drawing.strokes.isEmpty
        if none != empty { empty = none }
    }

    func undo() {
        canvas.undoManager?.undo()
    }

    func clear() {
        canvas.drawing = PKDrawing()
        failure = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        working = false
    }

    /// The writing as a picture on white, no larger than Claude looks at.
    func picture() -> Data? {
        let drawing = canvas.drawing
        let box = drawing.bounds
        guard !drawing.strokes.isEmpty, box.width > 0 || box.height > 0 else { return nil }
        let frame = box.insetBy(dx: -24, dy: -24)
        let long = max(frame.width, frame.height)
        let scale = min(3, 1568 / long)
        var ink: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: frame, scale: scale)
        }
        guard let ink else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let whole = CGRect(origin: .zero, size: frame.size)
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(whole)
            ink.draw(in: whole)
        }
        return image.jpegData(compressionQuality: 0.9)
    }

    static func body(jpeg: Data, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "stream": true,
            "output_config": ["effort": "low"],
            "system": Prompts.handwrittenMath,
            "messages": [[
                "role": "user",
                "content": [Claude.image(jpeg), ["type": "text", "text": "이 손글씨 수식을 LaTeX로 옮긴 결과만 출력하세요."]],
            ]],
        ]
        // (The smallest model thinks before it answers unless told not to; the others decide for themselves.)
        if model.hasPrefix("claude-haiku") { body["thinking"] = ["type": "disabled"] }
        if Claude.usesFallbacks(model) { body["fallbacks"] = "default" }
        return body
    }

    /// The LaTeX in an answer, without what is sometimes put round it: a fence of code, dollar signs.
    static func latex(in answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fences = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        for (open, close) in fences {
            if text.count > open.count + close.count, text.hasPrefix(open), text.hasSuffix(close) {
                text = String(text.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// Asks Claude what is written; [done] is handed the LaTeX when it could be read.
    func read(done: @escaping (String) -> Void) {
        guard !working else { return }
        guard let jpeg = picture() else { return }
        failure = nil
        working = true
        let model = AISettings.current.model
        DebugLog.write("math: handwriting sent to be read, " + String(jpeg.count) + " bytes")
        task = Task { @MainActor [weak self] in
            do {
                guard let key = KeyStore.load() ?? (Claude.usesStandIn ? "stand-in-key" : nil) else {
                    throw ClaudeError(message: "Claude API 키가 아직 없어요. 설정에서 키를 입력하면 손글씨를 수식으로 바꿀 수 있어요.", needsKey: true)
                }
                let request = try Claude.request(key: key, model: model, body: Self.body(jpeg: jpeg, model: model))
                var all = ""
                var reason: String?
                for try await event in Claude.stream(request) {
                    switch event {
                    case .text(let words): all += words
                    case .done(let reply): reason = reply.stopReason
                    default: break
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.working = false
                let found = Self.latex(in: all)
                if reason == "refusal" {
                    self.failure = ClaudeError(message: "Claude가 이 손글씨는 읽지 않겠다고 했어요. 다시 써서 시도해 주세요.")
                } else if found.isEmpty || found == Self.nothing {
                    self.failure = ClaudeError(message: "수식을 알아보지 못했어요. 조금 더 크고 또렷하게 써서 다시 시도해 주세요.")
                } else {
                    DebugLog.write("math: handwriting read as " + String(found.count) + " letters of LaTeX")
                    done(found)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.working = false
                self.failure = (error as? ClaudeError) ?? ClaudeError(message: "손글씨를 읽지 못했어요. 연결을 확인하고 다시 시도해 주세요.")
            }
        }
    }
}

/// The paper the formula is written on by hand.
struct MathHandPad: UIViewRepresentable {
    let canvas: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView { canvas }

    func updateUIView(_ view: PKCanvasView, context: Context) {}
}
