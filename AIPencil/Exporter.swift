import PDFKit
import PencilKit
import UIKit

/// What was written on a page, as an annotation that draws it. Saving the document turns what it draws
/// into part of the page as other apps see it.
private final class InkStamp: PDFAnnotation {
    var paint: ((CGContext) -> Void)?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        paint?(context)
    }
}

/// Makes a copy of a document with everything written on it laid over its pages: handwriting, formulas
/// and, if wanted, the marks of the AI pen. The pages themselves are not redrawn, so their text can
/// still be selected and searched exactly as before; the handwriting goes in as a picture three times
/// as fine as the page.
enum Exporter {
    static func export(pdfURL: URL, folder: URL, title: String, withMarks: Bool) -> URL? {
        guard let document = DocFile.open(pdfURL), document.pageCount > 0 else { return nil }
        let drawings = DrawingStore(folder: folder)
        let mathStore = MathStore(folder: folder)
        let math = mathStore.load()
        let marks = withMarks ? QuestionStore(folder: folder).load().filter { !$0.markHidden && !$0.turns.isEmpty } : []

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            // The overlay's frame: the page before any turning, measured from its top-left corner.
            let crop = page.bounds(for: .cropBox)
            let frame = CGRect(origin: .zero, size: crop.size)
            let quarterTurns = (((page.rotation % 360) + 360) % 360) / 90

            var ink: UIImage?
            if let drawing = drawings.load(page: index), !drawing.strokes.isEmpty {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: frame, scale: 3)
                }
            }
            var formulas: [(item: MathItem, picture: UIImage)] = []
            for item in math where item.page == index {
                if let shape = UIImage(contentsOfFile: mathStore.imageURL(item.image).path) {
                    formulas.append((item, coloured(shape, item.color)))
                }
            }
            let lines = marks.filter { $0.page == index }.map(\.points)
            if ink == nil, formulas.isEmpty, lines.isEmpty { continue }

            let stamp = InkStamp(bounds: crop, forType: .stamp, withProperties: nil)
            stamp.shouldPrint = true
            stamp.paint = { cg in
                cg.saveGState()
                // From the page's own space (bottom-left corner, upward) to the overlay's frame.
                cg.translateBy(x: crop.minX, y: crop.maxY)
                cg.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(cg)
                for formula in formulas {
                    // A formula stands upright on a page that is shown turned: it is turned back by as much.
                    let item = formula.item
                    cg.saveGState()
                    cg.translateBy(x: item.frame.midX, y: item.frame.midY)
                    cg.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
                    formula.picture.draw(in: CGRect(x: -item.width / 2, y: -item.height / 2, width: item.width, height: item.height))
                    cg.restoreGState()
                }
                ink?.draw(in: frame)
                for points in lines {
                    guard let first = points.first else { continue }
                    let line = UIBezierPath()
                    line.move(to: first)
                    for point in points.dropFirst() { line.addLine(to: point) }
                    line.lineWidth = 2
                    line.lineCapStyle = .round
                    line.lineJoinStyle = .round
                    InkChoice.markColor.withAlphaComponent(0.6).setStroke()
                    line.stroke()
                }
                UIGraphicsPopContext()
                cg.restoreGState()
            }
            page.addAnnotation(stamp)
        }

        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { name = name.replacingOccurrences(of: bad, with: "-") }
        if name.isEmpty { name = "문서" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) (필기).pdf")
        try? FileManager.default.removeItem(at: url)
        return document.write(to: url) ? url : nil
    }

    /// A formula's shape filled with its colour, as a picture with clear paper round the letters.
    private static func coloured(_ shape: UIImage, _ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = shape.scale
        format.opaque = false
        let whole = CGRect(origin: .zero, size: shape.size)
        return UIGraphicsImageRenderer(size: shape.size, format: format).image { context in
            color.setFill()
            context.fill(whole)
            shape.draw(in: whole, blendMode: .destinationIn, alpha: 1)
        }
    }
}
