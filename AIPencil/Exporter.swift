import PDFKit
import PencilKit
import UIKit

/// Makes a copy of a document with everything written on it drawn in: handwriting, formulas and, if
/// wanted, the marks of the AI pen. The pages themselves go in as they are, so their text can still be
/// selected and searched; the handwriting goes in as a picture three times as fine as the page.
enum Exporter {
    static func export(pdfURL: URL, folder: URL, title: String, withMarks: Bool) -> URL? {
        guard let document = PDFDocument(url: pdfURL), document.pageCount > 0 else { return nil }
        let drawings = DrawingStore(folder: folder)
        let mathStore = MathStore(folder: folder)
        let math = mathStore.load()
        let marks = withMarks ? QuestionStore(folder: folder).load().filter { !$0.markHidden && !$0.turns.isEmpty } : []

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let shape = AskCapture.shape(of: page)
                let whole = CGRect(origin: .zero, size: shape.size)
                context.beginPage(withBounds: whole, pageInfo: [:])
                let cg = context.cgContext

                // The page. PDF drawing measures from the bottom-left corner, upward.
                cg.saveGState()
                cg.translateBy(x: 0, y: shape.size.height)
                cg.scaleBy(x: 1, y: -1)
                if let reference = page.pageRef {
                    cg.concatenate(reference.getDrawingTransform(.cropBox, rect: whole, rotate: 0, preserveAspectRatio: true))
                    cg.drawPDFPage(reference)
                } else {
                    page.draw(with: .cropBox, to: cg)
                }
                cg.restoreGState()

                // Formulas stand upright, round the place their middle is shown at.
                for item in math where item.page == index {
                    guard let picture = UIImage(contentsOfFile: mathStore.imageURL(item.image).path) else { continue }
                    let middle = CGPoint(x: item.frame.midX, y: item.frame.midY).applying(shape.turn)
                    let upright = CGRect(x: middle.x - item.width / 2, y: middle.y - item.height / 2, width: item.width, height: item.height)
                    picture.withTintColor(item.color, renderingMode: .alwaysOriginal).draw(in: upright)
                }

                // Handwriting and marks are in the overlay's frame, turned as the page is turned.
                cg.saveGState()
                cg.concatenate(shape.turn)
                if let drawing = drawings.load(page: index), !drawing.strokes.isEmpty {
                    let frame = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
                    var ink: UIImage?
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        ink = drawing.image(from: frame, scale: 3)
                    }
                    ink?.draw(in: frame)
                }
                for mark in marks where mark.page == index {
                    let points = mark.points
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
                cg.restoreGState()
            }
        }

        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { name = name.replacingOccurrences(of: bad, with: "-") }
        if name.isEmpty { name = "문서" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) (필기).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
