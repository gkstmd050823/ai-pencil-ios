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

/// Makes notebook pages. A page is a real PDF page with its lines drawn on it, so the lines are there in
/// other apps and in exports too.
enum Paper {
    /// A4 in points.
    static let a4 = CGSize(width: 595.28, height: 841.89)
    private static let line = UIColor(red: 0.76, green: 0.80, blue: 0.87, alpha: 1)
    private static let strong = UIColor(red: 0.62, green: 0.68, blue: 0.80, alpha: 1)
    /// 10 mm and 5 mm, the usual spacings of ruled and squared paper.
    private static let ruled: CGFloat = 28.35
    private static let square: CGFloat = 14.17

    private static var made: [String: Data] = [:]
    private static let lock = NSLock()

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
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            cg.setLineWidth(0.6)
            cg.setStrokeColor(line.cgColor)
            cg.setFillColor(line.cgColor)
            switch kind {
            case .blank:
                break
            case .lined:
                var y: CGFloat = 76
                while y < size.height - 36 {
                    cg.move(to: CGPoint(x: 36, y: y))
                    cg.addLine(to: CGPoint(x: size.width - 36, y: y))
                    y += ruled
                }
                cg.strokePath()
            case .grid:
                // Whole squares, centred on the page.
                let columns = floor((size.width - 28) / square), rows = floor((size.height - 28) / square)
                let left = (size.width - columns * square) / 2, top = (size.height - rows * square) / 2
                for i in 0...Int(columns) {
                    let x = left + CGFloat(i) * square
                    cg.move(to: CGPoint(x: x, y: top))
                    cg.addLine(to: CGPoint(x: x, y: top + rows * square))
                }
                for j in 0...Int(rows) {
                    let y = top + CGFloat(j) * square
                    cg.move(to: CGPoint(x: left, y: y))
                    cg.addLine(to: CGPoint(x: left + columns * square, y: y))
                }
                cg.setLineWidth(0.4)
                cg.strokePath()
            case .dots:
                let columns = floor((size.width - 28) / square), rows = floor((size.height - 28) / square)
                let left = (size.width - columns * square) / 2, top = (size.height - rows * square) / 2
                cg.setFillColor(strong.cgColor)
                for i in 0...Int(columns) {
                    for j in 0...Int(rows) {
                        cg.fillEllipse(in: CGRect(x: left + CGFloat(i) * square - 0.7, y: top + CGFloat(j) * square - 0.7, width: 1.4, height: 1.4))
                    }
                }
            case .cornell:
                // A column for cues on the left, notes on the right, a box for the summary at the foot.
                let cue: CGFloat = 158, foot = size.height - 150
                var y: CGFloat = 76
                while y < foot - 8 {
                    cg.move(to: CGPoint(x: cue + 12, y: y))
                    cg.addLine(to: CGPoint(x: size.width - 36, y: y))
                    y += ruled
                }
                cg.strokePath()
                cg.setStrokeColor(strong.cgColor)
                cg.setLineWidth(1)
                cg.move(to: CGPoint(x: cue, y: 44))
                cg.addLine(to: CGPoint(x: cue, y: foot))
                cg.move(to: CGPoint(x: 36, y: foot))
                cg.addLine(to: CGPoint(x: size.width - 36, y: foot))
                cg.strokePath()
            }
        }
    }

    /// One page of this paper, ready to go into a document. With [darkens] it is of the kind that can be
    /// shown as dark paper.
    static func page(_ kind: PaperKind, size: CGSize = a4, darkens: Bool = false) -> PDFPage? {
        guard let document = PDFDocument(data: data(kind, size: size)) else { return nil }
        if darkens { document.delegate = InkPageMaker.shared }
        return document.page(at: 0)
    }

    /// A small picture of the paper, for choosing one.
    static func preview(_ kind: PaperKind) -> UIImage? {
        page(kind)?.thumbnail(of: CGSize(width: 300, height: 424), for: .mediaBox)
    }
}
