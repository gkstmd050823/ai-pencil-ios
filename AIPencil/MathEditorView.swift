import SwiftUI
import WebKit

/// A formula ready to go on the page: what was typed, its saved picture, and its size in page points.
struct MathResult {
    let latex: String
    let image: String
    let size: CGSize
}

/// The web view that typesets formulas with KaTeX and takes their picture.
final class MathTypesetter: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var ready = false

    /// CSS pixels of the formula's letters in the preview: large, because the picture is taken from the preview.
    static let previewFont = 40.0

    /// What the page reports about the formula it typeset. Lengths are CSS pixels, which here are points.
    struct Layout: Decodable {
        let ok: Bool
        let x: Double?
        let y: Double?
        let w: Double?
        let h: Double?
        let em: Double?
        let error: String?
    }

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = self
        if let folder = Bundle.main.url(forResource: "Web", withExtension: nil) {
            webView.loadFileURL(folder.appendingPathComponent("math.html"), allowingReadAccessTo: folder)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
    }

    /// Typesets [tex] in the preview. Hands back nil when the page is not ready or has no size yet.
    func render(_ tex: String, font: Double = MathTypesetter.previewFont, completion: @escaping (Layout?) -> Void) {
        let size = webView.bounds.size
        guard ready, size.width > 0, size.height > 0,
              let data = try? JSONEncoder().encode(tex), let literal = String(data: data, encoding: .utf8)
        else {
            completion(nil)
            return
        }
        let script = "render(\(literal), \(font), \(Double(size.width)), \(Double(size.height)))"
        webView.evaluateJavaScript(script) { result, _ in
            guard let json = result as? String,
                  let layout = try? JSONDecoder().decode(Layout.self, from: Data(json.utf8))
            else {
                completion(nil)
                return
            }
            completion(layout)
        }
    }

    func clear() {
        webView.evaluateJavaScript("box.textContent = ''", completionHandler: nil)
    }

    /// A picture of the formula as the preview is showing it, with a little air round it.
    func snapshot(of layout: Layout, completion: @escaping (UIImage?) -> Void) {
        guard let x = layout.x, let y = layout.y, let w = layout.w, let h = layout.h else {
            completion(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x - 2, y: y - 2, width: w + 4, height: h + 4)
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, _ in completion(image) }
    }
}

private struct WebPreview: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// Pieces of LaTeX offered as buttons.
private struct Snippet: Identifiable {
    let label: String
    let text: String
    var id: String { label }
}

private let snippets: [Snippet] = [
    Snippet(label: "분수", text: "\\frac{a}{b}"), Snippet(label: "제곱", text: "^{2}"), Snippet(label: "아래첨자", text: "_{i}"),
    Snippet(label: "루트", text: "\\sqrt{x}"), Snippet(label: "합", text: "\\sum_{i=1}^{n}"), Snippet(label: "적분", text: "\\int_{a}^{b}"),
    Snippet(label: "극한", text: "\\lim_{x \\to 0}"), Snippet(label: "벡터", text: "\\vec{v}"),
    Snippet(label: "α", text: "\\alpha "), Snippet(label: "β", text: "\\beta "), Snippet(label: "θ", text: "\\theta "),
    Snippet(label: "λ", text: "\\lambda "), Snippet(label: "π", text: "\\pi "), Snippet(label: "∞", text: "\\infty "),
    Snippet(label: "≤", text: "\\le "), Snippet(label: "≥", text: "\\ge "), Snippet(label: "≠", text: "\\neq "),
    Snippet(label: "≈", text: "\\approx "), Snippet(label: "×", text: "\\times "), Snippet(label: "·", text: "\\cdot "),
    Snippet(label: "→", text: "\\to "), Snippet(label: "∂", text: "\\partial "), Snippet(label: "∇", text: "\\nabla "),
    Snippet(label: "행렬", text: "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}"),
]

/// Types a formula in LaTeX, or writes it by hand for Claude to read into LaTeX, and sees it typeset;
/// "넣기" hands back a picture of it for the page: of the formula, of its LaTeX, or of both.
struct MathEditorView: View {
    let initial: String
    /// The size of the page the formula goes on, in points.
    let pageSize: CGSize
    let store: MathStore
    /// The build server sets this to have the formula put on the page without anyone tapping.
    var autoInsert = false
    let onDone: (MathResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var typesetter = MathTypesetter()
    @State private var text: String
    @State private var layout: MathTypesetter.Layout?
    @State private var size = MathSize.medium
    @State private var saving = false
    @StateObject private var hand = MathHand()
    /// What goes on the page: the formula, the LaTeX it is written in, or both.
    @AppStorage("mathPut") private var putRaw = MathPut.formula.rawValue
    @State private var copied = false

    init(initial: String, pageSize: CGSize, store: MathStore, autoInsert: Bool = false, onDone: @escaping (MathResult) -> Void) {
        self.initial = initial
        self.pageSize = pageSize
        self.store = store
        self.autoInsert = autoInsert
        self.onDone = onDone
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var put: MathPut { autoInsert ? .formula : (MathPut(rawValue: putRaw) ?? .formula) }
    private var problem: String? {
        guard let layout, !layout.ok, !trimmed.isEmpty else { return nil }
        return (layout.error ?? "").replacingOccurrences(of: "KaTeX parse error: ", with: "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Paper to write the formula on by hand; Claude reads it into the LaTeX below.
                    MathHandPad(canvas: hand.canvas)
                        .frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            if hand.empty {
                                Text("여기에 펜으로 수식을 써요")
                                    .font(.footnote)
                                    .foregroundStyle(Color.gray)
                                    .padding(12)
                                    .allowsHitTesting(false)
                            }
                        }
                    HStack(spacing: 10) {
                        Button("되돌리기") { hand.undo() }
                            .disabled(hand.empty || hand.working)
                        Button("모두 지우기") { hand.clear() }
                            .disabled(hand.empty || hand.working)
                        Spacer()
                        if hand.working {
                            ProgressView()
                            Button("그만") { hand.stop() }
                        } else {
                            Button("수식으로 바꾸기") {
                                hand.read { found in text = found }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(hand.empty)
                        }
                    }
                    .buttonStyle(.bordered)
                    if let failure = hand.failure {
                        Text(failure.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    // The preview is always on white, like the paper the formula will sit on.
                    WebPreview(webView: typesetter.webView)
                        .frame(height: 130)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    if let problem {
                        Text("아직 읽을 수 없는 수식이에요: \(String(problem.prefix(90)))")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 84)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Text("LaTeX로 입력해요. 예: \\frac{a}{b} = \\sqrt{x^2 + 1}")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(copied ? "복사했어요" : "코드 복사") {
                            UIPasteboard.general.string = trimmed
                            copied = true
                        }
                        .font(.footnote)
                        .disabled(trimmed.isEmpty)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(snippets) { snippet in
                                Button(snippet.label) { text += snippet.text }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    Picker("크기", selection: $size) {
                        ForEach(MathSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("페이지에 넣을 것")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("페이지에 넣을 것", selection: $putRaw) {
                            ForEach(MathPut.allCases) { kind in
                                Text(kind.label).tag(kind.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(20)
            }
            .navigationTitle(initial.isEmpty ? "수식 넣기" : "수식 고치기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(initial.isEmpty ? "넣기" : "바꾸기") { insert() }
                        .disabled(layout?.ok != true || saving)
                }
            }
        }
        // Typeset a moment after typing stops, and again once the page has loaded.
        .task(id: "\(typesetter.ready)|\(putRaw)|\(text)") {
            copied = false
            guard typesetter.ready else { return }
            if trimmed.isEmpty {
                layout = nil
                typesetter.clear()
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            // The preview may not have been given its size yet the first time round.
            for _ in 0..<8 {
                if Task.isCancelled { return }
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<MathTypesetter.Layout?, Never>) in
                    typesetter.render(put.shown(trimmed)) { continuation.resume(returning: $0) }
                }
                if let result {
                    layout = result
                    if autoInsert, result.ok { insert() }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func insert() {
        guard let shown = layout, shown.ok, !saving else { return }
        saving = true
        let latex = trimmed
        // The picture is taken of the preview, so the formula is first shown as large as the preview has
        // room for: made larger on the page later, it is still sharp.
        typesetter.render(put.shown(latex), font: MathTypesetter.previewFont * 5) { large in
            let fine = (large?.ok == true) ? large : nil
            take(fine ?? shown, latex: latex)
        }
    }

    private func take(_ layout: MathTypesetter.Layout, latex: String) {
        guard let w = layout.w, let h = layout.h, let em = layout.em else {
            saving = false
            return
        }
        DebugLog.write("math: picture of a formula " + String(format: "%.0f x %.0f", w, h) + " points in the preview, an em " + String(format: "%.1f", em) + ", preview " + String(format: "%.0f", Double(typesetter.webView.bounds.width)) + " wide")
        typesetter.snapshot(of: layout) { image in
            guard let image, let shape = MathPicture.inkMask(image), let data = shape.pngData() else {
                saving = false
                return
            }
            let name = UUID().uuidString
            do {
                try data.write(to: store.imageURL(name), options: .atomic)
            } catch {
                saving = false
                return
            }
            let onPage = MathPicture.sizeOnPage(
                width: w + 4, height: h + 4, em: em, emPoints: size.emPoints,
                maxWidth: Double(pageSize.width) - 16, maxHeight: Double(pageSize.height) - 16
            )
            onDone(MathResult(latex: latex, image: name, size: onPage))
            dismiss()
        }
    }
}
