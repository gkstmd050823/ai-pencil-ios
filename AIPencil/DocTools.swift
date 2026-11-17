import PDFKit
import PencilKit
import UIKit

/// The pages of a document the reader has marked to come back to, counted from zero.
struct BookmarkStore {
    let folder: URL

    private var url: URL { folder.appendingPathComponent("bookmarks.json") }

    func load() -> [Int] {
        guard let data = try? Data(contentsOf: url), let pages = try? JSONDecoder().decode([Int].self, from: data) else { return [] }
        return pages.sorted()
    }

    func save(_ pages: [Int]) {
        if pages.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(pages.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// After [count] pages were inserted at [index]: bookmarks on that page and later ones move that many pages later.
    func shiftPages(from index: Int, by count: Int = 1) {
        let pages = load()
        guard !pages.isEmpty else { return }
        save(pages.map { $0 >= index ? $0 + count : $0 })
    }
}

/// A place in the document where the words that were searched for stand.
struct SearchHit: Identifiable {
    let id = UUID()
    let page: Int
    /// The line the words stand in.
    let snippet: String
    let selection: PDFSelection
}

/// A page that can be shown as dark paper: white turned near-black and every colour's lightness turned
/// over, with its hue kept, so that black text is white and a blue line is still blue.
final class InkPage: PDFPage {
    /// Set before a document is shown. Pages are drawn dark while it is on.
    static var dark = false

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard InkPage.dark else {
            super.draw(with: box, to: context)
            return
        }
        let area = context.boundingBoxOfClipPath
        context.saveGState()
        // The page on white paper of our own, whatever is under this context.
        context.setFillColor(UIColor.white.cgColor)
        context.fill(area)
        super.draw(with: box, to: context)
        // Light for dark: white paper black, black text white. This turns hues over too...
        context.setBlendMode(.difference)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(area)
        // ...so the page is drawn once more, lending only its hues.
        context.setBlendMode(.hue)
        super.draw(with: box, to: context)
        // Pure black paper is lifted to the dark grey of the rest of the screen.
        context.setBlendMode(.lighten)
        context.setFillColor(UIColor(white: 0.11, alpha: 1).cgColor)
        context.fill(area)
        context.restoreGState()
    }
}

extension UIColor {
    /// The colour as PencilKit shows it on a dark canvas: ink is kept in its light-paper colour and
    /// shown light on dark paper.
    var onDarkPaper: UIColor {
        PKInkingTool.convertColor(self, from: .light, to: .dark)
    }
}

/// The outlines of the shape tool's shapes, as points along them a few page points apart.
enum ShapeOutline {
    /// A line from [a] to [b] that is nearly level or nearly upright is made exactly so.
    static func snapped(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let limit = tan(4 * CGFloat.pi / 180)
        if abs(dy) <= abs(dx) * limit { return CGPoint(x: b.x, y: a.y) }
        if abs(dx) <= abs(dy) * limit { return CGPoint(x: a.x, y: b.y) }
        return b
    }

    private static func run(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(length / 3))
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// Straight runs joined at corners. Each corner is given three times over, which keeps the smooth
    /// curve PencilKit draws through the points from cutting it.
    static func polyline(_ corners: [CGPoint]) -> [CGPoint] {
        var points: [CGPoint] = []
        for index in 1..<corners.count {
            points += run(corners[index - 1], corners[index])
            points += [corners[index], corners[index]]
        }
        return points
    }

    static func points(_ kind: ShapeKind, from a: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> [CGPoint] {
        switch kind {
        case .line:
            return polyline([a, snapped(a, end)])
        case .arrow:
            let b = snapped(a, end)
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 1 else { return [] }
            let head = min(length * 0.4, 9 + lineWidth * 3)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let spread = CGFloat.pi * 0.84
            let left = CGPoint(x: b.x + head * cos(angle + spread), y: b.y + head * sin(angle + spread))
            let right = CGPoint(x: b.x + head * cos(angle - spread), y: b.y + head * sin(angle - spread))
            return polyline([a, b, left, b, right])
        case .rect:
            return polyline([a, CGPoint(x: end.x, y: a.y), end, CGPoint(x: a.x, y: end.y), a])
        case .ellipse:
            let center = CGPoint(x: (a.x + end.x) / 2, y: (a.y + end.y) / 2)
            let rx = abs(end.x - a.x) / 2, ry = abs(end.y - a.y) / 2
            let steps = max(24, Int((rx + ry) * 0.6))
            return (0...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
            }
        }
    }
}
