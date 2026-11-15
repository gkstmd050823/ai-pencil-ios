import CoreGraphics
import Foundation

/// One thing said in a conversation about a mark. The first request (the pictures and "explain this")
/// is not kept as a turn: the mark itself stands for it.
struct Turn: Codable, Equatable {
    var fromUser: Bool
    var text: String
}

/// A mark made with the AI pen and the conversation it started. Places are in page points, measured
/// from the page's top-left corner.
struct Question: Codable, Identifiable, Equatable {
    var id = UUID()
    var page: Int
    /// The mark as it was drawn: x, y, x, y, ...
    var path: [Double]
    /// The part of the page shown to Claude close up: left, top, right, bottom.
    var region: [Double]
    var createdAt = Date()
    var model: String
    var turns: [Turn] = []
    /// Something the reader should know about the answer, such as that only part of the document was read.
    var notice: String?
    /// The mark is no longer drawn on the page; the explanation is still kept.
    var markHidden = false

    var points: [CGPoint] {
        stride(from: 0, to: path.count - 1, by: 2).map { CGPoint(x: path[$0], y: path[$0 + 1]) }
    }

    /// The box round the mark.
    var bounds: CGRect { Question.bounds(of: points) }

    var regionRect: CGRect {
        guard region.count == 4 else { return bounds }
        return CGRect(x: region[0], y: region[1], width: region[2] - region[0], height: region[3] - region[1])
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var left = first.x, top = first.y, right = first.x, bottom = first.y
        for point in points {
            left = min(left, point.x)
            right = max(right, point.x)
            top = min(top, point.y)
            bottom = max(bottom, point.y)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// The questions of a document on disk, in the document's own folder. Each has three files: what is
/// shown of it, the conversation exactly as it goes to the API (pictures included), and the close-up.
struct QuestionStore {
    let folder: URL

    private func url(_ id: UUID) -> URL {
        folder.appendingPathComponent("qa-\(id.uuidString).json")
    }

    private func messagesURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("qa-\(id.uuidString).messages.json")
    }

    func cropURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("qa-\(id.uuidString).jpg")
    }

    /// Every question of the document, oldest first.
    func load() -> [Question] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found: [Question] = []
        for name in names where name.hasPrefix("qa-") && name.hasSuffix(".json") && !name.hasSuffix(".messages.json") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let question = try? JSONDecoder().decode(Question.self, from: data)
            else { continue }
            found.append(question)
        }
        return found.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ question: Question) {
        guard let data = try? JSONEncoder().encode(question) else { return }
        try? data.write(to: url(question.id), options: .atomic)
    }

    func saveMessages(_ messages: [[String: Any]], for id: UUID) {
        guard let data = try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: messagesURL(id), options: .atomic)
    }

    func loadMessages(for id: UUID) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: messagesURL(id)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    func saveCrop(_ jpeg: Data, for id: UUID) {
        try? jpeg.write(to: cropURL(id), options: .atomic)
    }

    func delete(_ id: UUID) {
        for file in [url(id), messagesURL(id), cropURL(id)] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// After a page was inserted at [index]: questions on that page and later ones move one page later.
    func shiftPages(from index: Int) {
        for var question in load() where question.page >= index {
            question.page += 1
            save(question)
        }
    }
}
