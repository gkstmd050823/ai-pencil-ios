import PDFKit
import PencilKit
import UIKit

/// What the pictures of a question are made from. Gathered on the main thread, so the pictures
/// themselves can be made off it.
struct CaptureInput: @unchecked Sendable {
    var pdfURL: URL
    var page: Int
    /// The part of the page to show close up, on the page as it is shown.
    var region: CGRect
    /// The mark the user drew, in the overlay's frame.
    var mark: [CGPoint]
    /// The page's handwriting.
    var drawing: PKDrawing?
    /// The page's typed formulas.
    var math: [MathItem]
    var mathStore: MathStore
    /// Also take plain pictures of the pages on either side (for a document without text).
    var withNeighbours = false
}

/// The pictures sent with a question.
struct Capture: @unchecked Sendable {
    /// The whole page with the mark on it; nil when the close-up is of most of the page and says as much.
    var pageJPEG: Data?
    var cropJPEG: Data
    var crop: UIImage
    var neighbours: [(number: Int, jpeg: Data)] = []
}

/// Turns "the user circled this" into pictures Claude can read: the whole page with the mark on it,
/// and a close-up of the marked part.
enum AskCapture {
    static let pageLongEdge: CGFloat = 1024
    /// The same where the page's text goes along as text: the picture of the whole page is then only
    /// for seeing where on the page the mark is and how the page is laid out, and what a picture costs
    /// goes with the number of its pixels. (The close-up, which is what is read, stays as large as it was.)
    static let pageLongEdgeWithText: CGFloat = 768
    /// A close-up of this much of the page or more makes the picture of the whole page superfluous.
    static let wholePageShare: CGFloat = 0.55
    static let cropLongEdge: CGFloat = 1568
    private static let maxCropScale: CGFloat = 6
    private static let markColor = UIColor(red: 0xE5 / 255.0, green: 0x23 / 255.0, blue: 0x1B / 255.0, alpha: 1)

    /// How a page is shown. PDFKit lays its overlay over a page in the page's own frame, before any
    /// turning, and turns the overlay along with the page. Handwriting, formulas and marks therefore live
    /// in that unturned frame, while the pictures made for Claude show the page upright, as on screen.
    struct Shape {
        /// The size of the page as it is shown: its crop box, turned the way the page is turned.
        var size: CGSize
        /// Takes a point of the overlay to the same point on the page as it is shown.
        var turn: CGAffineTransform
    }

    static func shape(of page: PDFPage) -> Shape {
        let box = page.bounds(for: .cropBox).size
        let sideways = CGSize(width: box.height, height: box.width)
        switch ((page.rotation % 360) + 360) % 360 {
        case 90:
            return Shape(size: sideways, turn: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.height, ty: 0))
        case 180:
            return Shape(size: box, turn: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.width, ty: box.height))
        case 270:
            return Shape(size: sideways, turn: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: box.width))
        default:
            return Shape(size: box, turn: .identity)
        }
    }

    /// The part of the page to show Claude for a mark. A circle gives its own box; an underline or a
    /// short tick has almost no height, so it is grown upward to take in the line of text it sits
    /// under. The result is padded and kept inside the page.
    static func explainRegion(mark: CGRect, pageSize: CGSize) -> CGRect {
        var left = mark.minX, top = mark.minY, right = mark.maxX, bottom = mark.maxY
        let width = right - left
        let height = bottom - top
        // An underline: wide and flat. Take the line of text above it, and a little below.
        if height < 14, width > height * 3 {
            top -= 26
            bottom += 6
        }
        // A tiny mark (a dot or a tick): look at what is round it.
        if right - left < 40 {
            let grow = (40 - (right - left)) / 2
            left -= grow
            right += grow
        }
        if bottom - top < 28 {
            let grow = (28 - (bottom - top)) / 2
            top -= grow
            bottom += grow
        }
        let pad = max(10, 0.12 * max(right - left, bottom - top))
        left = min(max(left - pad, 0), pageSize.width)
        right = min(max(right + pad, 0), pageSize.width)
        top = min(max(top - pad, 0), pageSize.height)
        bottom = min(max(bottom + pad, 0), pageSize.height)
        if right - left < 1 || bottom - top < 1 { return CGRect(origin: .zero, size: pageSize) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Pixels per page point of the close-up: as large as allowed, without blowing a tiny region up absurdly.
    static func cropScale(_ region: CGRect) -> CGFloat {
        let long = max(region.width, region.height, 1)
        // A small part (a formula, a word) is blown up as far as it was, so that its small print stays
        // easy to read; a larger part is drawn at no more than four pixels a point (288 to the inch, at
        // which 10-point type is forty pixels tall). What a picture costs goes with the number of its
        // pixels, and beyond this more pixels made a question dearer without making it clearer.
        let most = max(4, min(maxCropScale, 480 / long))
        return min(cropLongEdge / long, most)
    }

    static func capture(_ input: CaptureInput) -> Capture? {
        guard let document = DocFile.open(input.pdfURL), let page = document.page(at: input.page) else { return nil }
        let shown = shape(of: page)
        let pageSize = shown.size
        let whole = CGRect(origin: .zero, size: pageSize)
        var formulas: [(item: MathItem, picture: UIImage)] = []
        for item in input.math {
            if let picture = UIImage(contentsOfFile: input.mathStore.imageURL(item.image).path) {
                formulas.append((item, picture))
            }
        }

        // (A scanned document has no text to send; its pages are read from their pictures.)
        let hasText = !input.withNeighbours
        let pageScale = (hasText ? pageLongEdgeWithText : pageLongEdge) / max(pageSize.width, pageSize.height, 1)
        let regionShare = input.region.width * input.region.height / max(pageSize.width * pageSize.height, 1)
        let sendsPage = !(hasText && regionShare >= wholePageShare)
        let pagePicture = render(
            page, shape: shown, region: whole, scale: pageScale,
            drawing: input.drawing, formulas: formulas, mark: input.mark, markWidth: max(3, pageScale * 1.6)
        )
        let closeScale = cropScale(input.region)
        let cropPicture = render(
            page, shape: shown, region: input.region, scale: closeScale,
            drawing: input.drawing, formulas: formulas, mark: input.mark, markWidth: max(3, closeScale * 1.1)
        )
        guard let pageJPEG = pagePicture.jpegData(compressionQuality: 0.85),
              let cropJPEG = cropPicture.jpegData(compressionQuality: 0.9)
        else { return nil }
        DebugLog.write("capture: page \(input.page) turned \(page.rotation) size \(pageSize) region \(input.region) page picture \(pagePicture.size) close-up \(cropPicture.size)")

        var capture = Capture(pageJPEG: sendsPage ? pageJPEG : nil, cropJPEG: cropJPEG, crop: cropPicture)
        if input.withNeighbours {
            for index in [input.page - 1, input.page + 1] where index >= 0 && index < document.pageCount {
                guard let other = document.page(at: index) else { continue }
                let otherShape = shape(of: other)
                let otherSize = otherShape.size
                let picture = render(
                    other, shape: otherShape, region: CGRect(origin: .zero, size: otherSize),
                    scale: 768 / max(otherSize.width, otherSize.height, 1),
                    drawing: nil, formulas: [], mark: [], markWidth: 0
                )
                if let jpeg = picture.jpegData(compressionQuality: 0.8) {
                    capture.neighbours.append((index + 1, jpeg))
                }
            }
        }
        return capture
    }

    /// A picture of [region] of the page as it is shown, at [scale] pixels per page point: the page
    /// itself, then the formulas typed on it, the handwriting, and the mark in red.
    private static func render(
        _ page: PDFPage, shape: Shape, region: CGRect, scale: CGFloat,
        drawing: PKDrawing?, formulas: [(item: MathItem, picture: UIImage)], mark: [CGPoint], markWidth: CGFloat
    ) -> UIImage {
        let pageSize = shape.size
        let pixels = CGSize(width: max(1, (region.width * scale).rounded()), height: max(1, (region.height * scale).rounded()))
        // The same part of the page in the overlay's frame, where the handwriting and the formulas are.
        let source = region.applying(shape.turn.inverted())
        var ink: UIImage?
        if let drawing, !drawing.strokes.isEmpty, drawing.bounds.intersects(source) {
            // PencilKit draws for the appearance in force, turning dark ink light on a dark screen.
            // The paper here is white, so the ink is asked for as it looks in light mode.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: source, scale: scale)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pixels))
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -region.minX, y: -region.minY)
            // From here on a point is a point of the page, measured from its top-left corner.

            cg.saveGState()
            cg.clip(to: CGRect(origin: .zero, size: pageSize))
            // PDF drawing measures from the bottom-left corner, upward.
            cg.translateBy(x: 0, y: pageSize.height)
            cg.scaleBy(x: 1, y: -1)
            if let reference = page.pageRef {
                // Fits the page's crop box, turned as the page is turned, into the page's rectangle.
                cg.concatenate(reference.getDrawingTransform(
                    .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true
                ))
                cg.drawPDFPage(reference)
            } else {
                page.draw(with: .cropBox, to: cg)
            }
            cg.restoreGState()

            // A formula keeps its place in the overlay's frame but stands upright on screen, so it is
            // drawn upright here, round the place its middle is shown at.
            for formula in formulas {
                let item = formula.item
                let middle = CGPoint(x: item.frame.midX, y: item.frame.midY).applying(shape.turn)
                let upright = CGRect(x: middle.x - item.width / 2, y: middle.y - item.height / 2, width: item.width, height: item.height)
                if upright.intersects(region) {
                    formula.picture.withTintColor(item.color, renderingMode: .alwaysOriginal).draw(in: upright)
                }
            }
            // Handwriting and the mark are drawn in the overlay's frame, turned as the page is turned.
            cg.concatenate(shape.turn)
            ink?.draw(in: source)
            if let first = mark.first {
                let line = UIBezierPath()
                line.move(to: first)
                for point in mark.dropFirst() { line.addLine(to: point) }
                if mark.count == 1 { line.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
                line.lineWidth = markWidth / scale
                line.lineCapStyle = .round
                line.lineJoinStyle = .round
                markColor.setStroke()
                line.stroke()
            }
        }
    }
}

/// The words of a document's pages, for sending along with a question.
enum DocText {
    private struct Saved: Codable {
        var pageCount: Int
        var pages: [String]
    }

    /// The text of every page. Reading a long document takes a while, so the result is kept beside the
    /// document and used again as long as the number of pages is the same.
    static func load(pdfURL: URL, folder: URL) -> [String] {
        guard let document = DocFile.open(pdfURL) else { return [] }
        let cache = folder.appendingPathComponent("text.json")
        if let data = try? Data(contentsOf: cache), let saved = try? JSONDecoder().decode(Saved.self, from: data),
           saved.pageCount == document.pageCount {
            return saved.pages
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            pages.append(document.page(at: index)?.string ?? "")
        }
        if let data = try? JSONEncoder().encode(Saved(pageCount: pages.count, pages: pages)) {
            try? data.write(to: cache, options: .atomic)
        }
        return pages
    }
}
