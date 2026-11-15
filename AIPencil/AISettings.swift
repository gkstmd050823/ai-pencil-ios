import Foundation
import Security

/// A Claude model the user can pick.
struct AIModel: Identifiable {
    let id: String
    let name: String
    let hint: String

    static let fallback = "claude-opus-5-5"

    static let all = [
        AIModel(id: "claude-opus-5-5", name: "Opus 5.5", hint: "가장 똑똑함 · 기본값"),
        AIModel(id: "claude-sonnet-5-5", name: "Sonnet 5.5", hint: "빠르고 저렴"),
        AIModel(id: "claude-haiku-5-5", name: "Haiku 5.5", hint: "가장 빠르고 저렴"),
    ]

    static func name(_ id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

/// How hard Claude works on an answer.
enum Depth: String, CaseIterable, Identifiable {
    case fast, balanced, deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "빠르게"
        case .balanced: return "보통"
        case .deep: return "깊게"
        }
    }

    var hint: String {
        switch self {
        case .fast: return "가장 빨리 답해요"
        case .balanced: return "조금 더 꼼꼼해요"
        case .deep: return "어려운 내용에 좋아요, 느려요"
        }
    }

    /// The value of the API's output_config.effort.
    var effort: String {
        switch self {
        case .fast: return "low"
        case .balanced: return "medium"
        case .deep: return "high"
        }
    }
}

/// The settings a question is asked with, as they stand in UserDefaults (where the settings screen keeps them).
struct AISettings {
    var model: String
    var depth: Depth
    var language: String
    var scope: ContextScope

    static var current: AISettings {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: "model") ?? AIModel.fallback
        return AISettings(
            model: AIModel.all.contains { $0.id == model } ? model : AIModel.fallback,
            depth: Depth(rawValue: defaults.string(forKey: "depth") ?? "") ?? .fast,
            language: defaults.string(forKey: "language") ?? "ko",
            scope: ContextScope(rawValue: defaults.string(forKey: "contextScope") ?? "") ?? .whole
        )
    }
}

/// The user's Claude API key, kept in the iPad's keychain.
enum KeyStore {
    private static let service = "app.aipencil.ios"
    private static let account = "claude-api-key"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Where the key goes if the keychain will not take it (an app signed without a keychain group): a
    /// file inside the app's own storage, outside the folder the Files app can see, left out of backups.
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("claude.key")
    }

    static func load() -> String? {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        if let data = try? Data(contentsOf: fileURL), let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return nil
    }

    /// Hands back false when the key could be kept nowhere.
    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        DebugLog.write("key: keychain status \(status)")
        if status == errSecSuccess { return true }
        do {
            var url = fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(key.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Notes for the build server, which cannot look at the running app: in a debug build they go to a file
/// the server reads afterwards. A release build writes nothing.
enum DebugLog {
    static func write(_ line: @autoclosure () -> String) {
        #if DEBUG
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("debug.log")
        let data = Data((line() + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
