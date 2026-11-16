import SwiftUI

/// Translates words picked out of a page. It asks the fastest Claude model, whatever model explanations
/// are set to use: a translation is wanted at once, and is short work.
final class Translator: ObservableObject {
    static let model = "claude-haiku-5-5"
    /// The most that is sent in one go, in characters.
    static let limit = 6000

    /// The words being translated; none when the card is put away.
    @Published private(set) var source: String?
    @Published private(set) var result = ""
    @Published private(set) var working = false
    @Published private(set) var failure: ClaudeError?
    /// Whether the words were longer than is sent in one go, and so cut.
    @Published private(set) var cut = false
    private var task: Task<Void, Never>?
    /// What has been translated while this document is open: asked for again, it is shown at once.
    private var known: [String: String] = [:]

    static func body(_ text: String, language: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 4000,
            "stream": true,
            // (This model thinks before it answers unless told not to; a translation should start at once.)
            "thinking": ["type": "disabled"],
            "output_config": ["effort": "low"],
            "system": Prompts.translation(language: language),
            "messages": [["role": "user", "content": text]],
        ]
    }

    func translate(_ picked: String) {
        let whole = picked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return }
        let text = String(whole.prefix(Self.limit))
        if text == source, failure == nil { return }
        task?.cancel()
        source = text
        cut = text.count < whole.count
        failure = nil
        if let done = known[text] {
            result = done
            working = false
            return
        }
        result = ""
        working = true
        let language = AISettings.current.language
        Diagnostics.shared.step("translation asked")
        task = Task { @MainActor [weak self] in
            do {
                guard let key = KeyStore.load() ?? (Claude.usesStandIn ? "stand-in-key" : nil) else {
                    throw ClaudeError(message: "Claude API 키가 아직 없어요. 설정에서 키를 입력하면 번역을 받을 수 있어요.", needsKey: true)
                }
                let request = try Claude.request(key: key, model: Self.model, body: Self.body(text, language: language))
                var all = ""
                for try await event in Claude.stream(request) {
                    guard case .text(let words) = event else { continue }
                    all += words
                    guard let self, !Task.isCancelled, self.source == text else { return }
                    self.result = all
                }
                guard let self, !Task.isCancelled, self.source == text else { return }
                self.working = false
                if all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.failure = ClaudeError(message: "번역이 비어 있어요. 다시 시도해 주세요.")
                } else {
                    self.known[text] = all
                }
            } catch {
                guard let self, !Task.isCancelled, self.source == text else { return }
                self.working = false
                self.failure = (error as? ClaudeError) ?? ClaudeError(message: "번역을 받지 못했어요. 연결을 확인하고 다시 시도해 주세요.")
            }
        }
    }

    func again() {
        guard let text = source else { return }
        source = nil
        translate(text)
    }

    func close() {
        task?.cancel()
        task = nil
        source = nil
        result = ""
        working = false
        failure = nil
    }
}

/// The translation of the words picked, on a card at the foot of the pages.
struct TranslationCard: View {
    @ObservedObject var translator: Translator
    let onOpenSettings: () -> Void
    @AppStorage("translateOnPick") private var onPick = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("번역")
                    .font(.subheadline.weight(.semibold))
                if translator.working {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = translator.result
                    copied = true
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.medium))
                }
                .disabled(translator.result.isEmpty || translator.working)
                .accessibilityLabel("번역 복사")
                Button {
                    translator.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("번역 닫기")
            }
            .foregroundStyle(.primary)

            Text(translator.source ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let failure = translator.failure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.message)
                        .font(.subheadline)
                    Button(failure.needsKey ? "설정 열기" : "다시 시도") {
                        if failure.needsKey { onOpenSettings() } else { translator.again() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            } else {
                // As tall as the words, up to a limit; past it, they scroll.
                ScrollView {
                    words
                }
                .frame(maxHeight: 230)
                .fixedSize(horizontal: false, vertical: true)
            }
            if translator.cut {
                Text("길어서 앞의 \(Translator.limit)자만 번역했어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            Toggle("글자를 고르면 바로 번역", isOn: $onPick)
                .font(.footnote)
                .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .onChange(of: translator.source) { copied = false }
    }

    private var words: some View {
        Text(translator.result.isEmpty && translator.working ? " " : translator.result)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
