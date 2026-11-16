import SwiftUI

/// What a double tap or a squeeze of the Apple Pencil can be set to do.
private struct PencilChoice: Identifiable {
    let id: String
    let label: String

    static let all = [
        PencilChoice(id: "system", label: "아이패드 설정 따르기"),
        PencilChoice(id: "eraser", label: "지우개로 바꾸기"),
        PencilChoice(id: "previous", label: "직전 도구로 바꾸기"),
        PencilChoice(id: "ai", label: "AI 펜으로 바꾸기"),
        PencilChoice(id: "options", label: "펜 설정 열기"),
        PencilChoice(id: "off", label: "아무것도 안 하기"),
    ]
}

/// The settings: the Claude API key and how explanations are asked for, how writing behaves, how the
/// app looks.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("model") private var model = AIModel.fallback
    @AppStorage("depth") private var depth = Depth.fast
    @AppStorage("language") private var language = "ko"
    @AppStorage("contextScope") private var scope = ContextScope.whole
    @AppStorage("webSearch") private var webSearch = true
    @AppStorage("fingerDraws") private var fingerDraws = false
    @AppStorage("pencilTap") private var pencilTap = "system"
    @AppStorage("pencilSqueeze") private var pencilSqueeze = "system"
    @AppStorage("theme") private var theme = "system"
    @AppStorage("showAiMarks") private var showAiMarks = true
    @AppStorage("pageLayout") private var layoutMode = PageLayoutMode.vertical
    @AppStorage("darkPaper") private var darkPaper = true
    @AppStorage("sharpPages") private var sharpPages = true
    @State private var typedKey = ""
    @State private var savedKey = KeyStore.load()
    @State private var checking = false
    @State private var keyNote: String?
    @State private var keyWorks = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                keySection
                askingSection
                writingSection
                lookSection
                Section {
                    HStack {
                        Text("버전")
                        Spacer()
                        Text(version)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }

    private var keySection: some View {
        Section {
            if let savedKey {
                HStack {
                    Text("저장된 키")
                    Spacer()
                    Text("••••" + String(savedKey.suffix(4)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            SecureField(savedKey == nil ? "sk-ant-..." : "새 키로 바꾸기", text: $typedKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                saveKey()
            } label: {
                HStack(spacing: 8) {
                    Text("저장하고 확인")
                    if checking { ProgressView() }
                }
            }
            .disabled(typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            if let keyNote {
                Text(keyNote)
                    .font(.footnote)
                    .foregroundStyle(keyWorks ? Color.green : Color.red)
            }
            if savedKey != nil {
                Button("키 지우기", role: .destructive) {
                    KeyStore.delete()
                    savedKey = nil
                    keyNote = nil
                }
            }
        } header: {
            Text("Claude API 키")
        } footer: {
            Text("키는 console.anthropic.com → API Keys에서 만들 수 있어요. 사용한 만큼 요금이 청구돼요. 키는 이 아이패드 안에만 저장되고, Claude에게 물어볼 때만 쓰여요.")
        }
    }

    @ViewBuilder
    private var askingSection: some View {
        Section {
            Picker("모델", selection: $model) {
                ForEach(AIModel.all) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("설명에 쓰는 모델")
        } footer: {
            Text("위일수록 정확하고, 아래일수록 빠르고 저렴해요.")
        }

        Section {
            Picker("설명 깊이", selection: $depth) {
                ForEach(Depth.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("설명 깊이")
        } footer: {
            Text(depth.hint)
        }

        Section {
            Picker("참고 범위", selection: $scope) {
                ForEach(ContextScope.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("문서를 얼마나 참고할지")
        } footer: {
            Text(scope.hint)
        }

        Section {
            Toggle("웹 검색", isOn: $webSearch)
            Picker("설명 언어", selection: $language) {
                Text("한국어").tag("ko")
                Text("English").tag("en")
                Text("문서의 언어").tag("doc")
            }
        } footer: {
            Text("웹 검색을 켜 두면 문서 밖의 정보나 최신 내용이 필요할 때 Claude가 웹을 찾아보고 출처를 붙여요. 검색 1,000회에 10달러가 따로 들어요.")
        }
    }

    private var writingSection: some View {
        Section {
            Toggle("손가락으로도 필기", isOn: $fingerDraws)
            Picker("펜슬 두 번 탭", selection: $pencilTap) {
                ForEach(PencilChoice.all) { item in
                    Text(item.label).tag(item.id)
                }
            }
            Picker("펜슬 꽉 쥐기", selection: $pencilSqueeze) {
                ForEach(PencilChoice.all) { item in
                    Text(item.label).tag(item.id)
                }
            }
        } header: {
            Text("필기")
        } footer: {
            Text("손가락 필기를 끄면 애플 펜슬로만 쓰고 손가락으로는 화면을 움직여요. 두 번 탭은 애플 펜슬 2세대와 프로에서, 꽉 쥐기는 프로에서 돼요. 누르는 힘에 따라 굵기가 달라지게 하려면 펜 종류를 만년필로 고르세요(펜을 한 번 더 누르면 나오는 설정).")
        }
    }

    private var lookSection: some View {
        Section {
            Picker("테마", selection: $theme) {
                Text("시스템").tag("system")
                Text("밝게").tag("light")
                Text("어둡게").tag("dark")
            }
            .pickerStyle(.segmented)
            Picker("쪽 보기", selection: $layoutMode) {
                ForEach(PageLayoutMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("어두운 테마에서는 종이도 어둡게", isOn: $darkPaper)
            Toggle("AI 표시 보이기", isOn: $showAiMarks)
            Toggle("쪽을 화면 해상도로 한 번 더 그리기", isOn: $sharpPages)
        } header: {
            Text("화면")
        } footer: {
            Text("종이를 어둡게 하면 흰 종이는 어두운 회색으로, 글자와 필기는 밝게 보여요. 색의 종류는 그대로예요. 내보내는 PDF와 Claude에게 가는 그림은 늘 원래 색이에요.\n\n\"한 번 더 그리기\"를 켜면 쪽이 화면에 가까이 올 때 앱이 화면 해상도 그대로 미리 그려서 덮어요. 문서가 무르게 보이거나 늦게 선명해질 때를 위한 것이고, 끄면 메모리를 덜 써요. 켜고 끈 차이가 보이는지 비교해 보세요.")
        }
    }

    /// Keeps the typed key, then looks up the chosen model with it to see that it works.
    private func saveKey() {
        let key = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeyStore.save(key) else {
            keyWorks = false
            keyNote = "키를 저장하지 못했어요."
            return
        }
        savedKey = key
        typedKey = ""
        checking = true
        keyNote = nil
        let model = self.model
        Task { @MainActor in
            switch await Claude.verify(key: key, model: model) {
            case .success(let note):
                keyWorks = true
                keyNote = note
            case .failure(let error):
                keyWorks = false
                keyNote = "키는 저장했어요. 다만 확인하지 못했어요: \(error.message)"
            }
            checking = false
        }
    }
}
