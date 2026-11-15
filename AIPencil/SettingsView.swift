import SwiftUI

/// The settings: the Claude API key, and how explanations are asked for.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("model") private var model = AIModel.fallback
    @AppStorage("depth") private var depth = Depth.fast
    @AppStorage("language") private var language = "ko"
    @AppStorage("contextScope") private var scope = ContextScope.whole
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
                    Text("모델")
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
                    Picker("설명 언어", selection: $language) {
                        Text("한국어").tag("ko")
                        Text("English").tag("en")
                        Text("문서의 언어").tag("doc")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("설명 언어")
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
