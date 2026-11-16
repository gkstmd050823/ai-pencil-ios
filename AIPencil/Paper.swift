import PDFKit
import UIKit

/// The kinds of paper a notebook page can be made of.
enum PaperKind: String, CaseIterable, Identifiable, Codable {
    case blank, lined, grid, dots, cornell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank: return "백지"
        case .lined: return "줄 노트"
        case .grid: return "모눈"
        case .dots: return "점 노트"
        case .cornell: return "코넬 노트"
        }
    }
}

/// The sizes of paper a notebook can be made of.
enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case a3, a4, a5, b5, letter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a3: return "A3"
        case .a4: return "A4"
        case .a5: return "A5"
        case .b5: return "B5"
        case .letter: return "레터"
        }
    }

    /// Width and height in millimetres, standing upright. (B5 is the one notebooks are sold in here: 182 x 257.)
    private var upright: (Double, Double) {
        switch self {
        case .a3: return (297, 420)
        case .a4: return (210, 297)
        case .a5: return (148, 210)
        case .b5: return (182, 257)
        case .letter: return (215.9, 279.4)
        }
    }

    /// The size in page points.
    func points(landscape: Bool) -> CGSize {
        let (width, height) = upright
        let w = (width * 72 / 25.4 * 100).rounded() / 100, h = (height * 72 / 25.4 * 100).rounded() / 100
        return landscape ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    func millimetres(landscape: Bool) -> String {
        let (width, height) = upright
        func text(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value) }
        return landscape ? "\(text(height)) × \(text(width)) mm" : "\(text(width)) × \(text(height)) mm"
    }
}

/// Makes notebook pages. A page is a real PDF page with its lines drawn on it, so the lines are there in
/// other apps and in exports too.
enum Paper {
    /// The lines and dots of a paper, measured from the page's top left corner. They are worked out once
    /// and drawn two ways: on a page made for the screen, and as PDF commands in an export.
    struct Art {
        struct Strokes {
            /// Red, green and blue, each from 0 to 1.
            var color: [Double]
            var width: Double
            var segments: [(CGPoint, CGPoint)]
        }

        struct Dots {
            var color: [Double]
            var radius: Double
            var centres: [CGPoint]
        }

        var strokes: [Strokes] = []
        var dots: Dots?
    }

    /// A4 in points.
    static let a4 = CGSize(width: 595.28, height: 841.89)
    private static let line: [Double] = [0.76, 0.80, 0.87]
    private static let strong: [Double] = [0.62, 0.68, 0.80]
    /// 10 mm and 5 mm, the usual spacings of ruled and squared paper.
    private static let ruled: CGFloat = 28.35
    private static let square: CGFloat = 14.17

    private static var made: [String: Data] = [:]
    private static let lock = NSLock()

    static func art(_ kind: PaperKind, size: CGSize) -> Art {
        var out = Art()
        switch kind {
        case .blank:
            break
        case .lined:
            var rows: [(CGPoint, CGPoint)] = []
            var y: CGFloat = 76
            while y < size.height - 36 {
                rows.append((CGPoint(x: 36, y: y), CGPoint(x: size.width - 36, y: y)))
                y += ruled
            }
            out.strokes.append(Art.Strokes(color: line, width: 0.6, segments: rows))
        case .grid:
            // Whole squares, centred on the page.
            let columns = max(0, floor((size.width - 28) / square)), rows = max(0, floor((size.height - 28) / square))
            let left = (size.width - columns * square) / 2, top = (size.height - rows * square) / 2
            var segments: [(CGPoint, CGPoint)] = []
            for i in 0...Int(columns) {
                let x = left + CGFloat(i) * square
                segments.append((CGPoint(x: x, y: top), CGPoint(x: x, y: top + rows * square)))
            }
            for j in 0...Int(rows) {
                let y = top + CGFloat(j) * square
                segments.append((CGPoint(x: left, y: y), CGPoint(x: left + columns * square, y: y)))
            }
            out.strokes.append(Art.Strokes(color: line, width: 0.4, segments: segments))
        case .dots:
            let columns = max(0, floor((size.width - 28) / square)), rows = max(0, floor((size.height - 28) / square))
            let left = (size.width - columns * square) / 2, top = (size.height - rows * square) / 2
            var centres: [CGPoint] = []
            for i in 0...Int(columns) {
                for j in 0...Int(rows) {
                    centres.append(CGPoint(x: left + CGFloat(i) * square, y: top + CGFloat(j) * square))
                }
            }
            out.dots = Art.Dots(color: strong, radius: 0.7, centres: centres)
        case .cornell:
            // A column for cues on the left, notes on the right, a box for the summary at the foot.
            let cue: CGFloat = min(158, size.width * 0.27), foot = size.height - min(150, size.height * 0.18)
            var rows: [(CGPoint, CGPoint)] = []
            var y: CGFloat = 76
            while y < foot - 8 {
                rows.append((CGPoint(x: cue + 12, y: y), CGPoint(x: size.width - 36, y: y)))
                y += ruled
            }
            out.strokes.append(Art.Strokes(color: line, width: 0.6, segments: rows))
            out.strokes.append(Art.Strokes(color: strong, width: 1, segments: [
                (CGPoint(x: cue, y: 44), CGPoint(x: cue, y: foot)),
                (CGPoint(x: 36, y: foot), CGPoint(x: size.width - 36, y: foot)),
            ]))
        }
        return out
    }

    private static func color(_ parts: [Double]) -> UIColor {
        UIColor(red: parts[0], green: parts[1], blue: parts[2], alpha: 1)
    }

    /// One page of this paper as PDF data. A page of a kind and size is drawn once and kept: a notebook
    /// has many pages of the same paper, and they are put together each time it is opened.
    static func data(_ kind: PaperKind, size: CGSize = a4) -> Data {
        let fit = CGSize(width: max(size.width, 72), height: max(size.height, 72))
        let key = "\(kind.rawValue) \(fit.width) \(fit.height)"
        lock.lock()
        let kept = made[key]
        lock.unlock()
        if let kept { return kept }
        let data = draw(kind, size: fit)
        lock.lock()
        made[key] = data
        lock.unlock()
        return data
    }

    private static func draw(_ kind: PaperKind, size: CGSize) -> Data {
        let bounds = CGRect(origin: .zero, size: size)
        let pattern = art(kind, size: size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            for group in pattern.strokes {
                cg.setStrokeColor(color(group.color).cgColor)
                cg.setLineWidth(group.width)
                for segment in group.segments {
                    cg.move(to: segment.0)
                    cg.addLine(to: segment.1)
                }
                cg.strokePath()
            }
            if let dots = pattern.dots {
                cg.setFillColor(color(dots.color).cgColor)
                let r = dots.radius
                for centre in dots.centres {
                    cg.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
                }
            }
        }
    }

    /// The same lines and dots as PDF drawing commands, measured from the top left corner. An export
    /// that adds a page to a file without PDFKit draws the page with these.
    static func commands(_ kind: PaperKind, size: CGSize) -> String {
        let pattern = art(kind, size: size)
        /// Numbers with blanks between them, then the command they belong to.
        func put(_ values: [Double], _ command: String) -> String {
            values.map { PDFAppend.number($0) }.joined(separator: " ") + " " + command
        }
        var out = ""
        for group in pattern.strokes {
            out += put(group.color, "RG ") + put([group.width], "w\n")
            for segment in group.segments {
                let a = segment.0, b = segment.1
                out += put([Double(a.x), Double(a.y)], "m ") + put([Double(b.x), Double(b.y)], "l\n")
            }
            out += "S\n"
        }
        if let dots = pattern.dots {
            out += put(dots.color, "rg\n")
            // A circle as four curves; 0.5523 of the radius is how far their handles reach.
            let r = dots.radius
            let k = dots.radius * 0.5523
            for centre in dots.centres {
                let x = Double(centre.x)
                let y = Double(centre.y)
                out += put([x + r, y], "m ")
                out += put([x + r, y + k, x + k, y + r, x, y + r], "c ")
                out += put([x - k, y + r, x - r, y + k, x - r, y], "c ")
                out += put([x - r, y - k, x - k, y - r, x, y - r], "c ")
                out += put([x + k, y - r, x + r, y - k, x + r, y], "c f\n")
            }
        }
        return out
    }

    /// One page of this paper, ready to go into a document. With [darkens] it is of the kind that can be
    /// shown as dark paper.
    static func page(_ kind: PaperKind, size: CGSize = a4, darkens: Bool = false) -> PDFPage? {
        guard let document = PDFDocument(data: data(kind, size: size)) else { return nil }
        if darkens { document.delegate = InkPageMaker.shared }
        return document.page(at: 0)
    }

    /// A small picture of the paper, for choosing one.
    static func preview(_ kind: PaperKind, size: CGSize = a4) -> UIImage? {
        let longest = max(size.width, size.height, 1)
        let small = CGSize(width: (size.width * 420 / longest).rounded(), height: (size.height * 420 / longest).rounded())
        return page(kind, size: size)?.thumbnail(of: small, for: .mediaBox)
    }
}
