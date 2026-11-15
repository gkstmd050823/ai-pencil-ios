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
/// and, if wanted, the marks of the AI pen.
///
/// The copy is the file itself with an update added at its end (see [PDFAppend]): the pages are the very
/// bytes they were, so their text can be selected, searched and copied exactly as before. What was
/// written goes over each page as a picture three times as fine as the page. A file that cannot be
/// added to (one with a password, or one put together wrongly) is written anew by PDFKit instead, which
/// shows the same but may lose what the letters of some fonts are.
enum Exporter {
    /// Everything written on one page.
    private struct Written {
        var ink: PKDrawing?
        var formulas: [(item: MathItem, picture: UIImage)] = []
        var lines: [[CGPoint]] = []

        var isEmpty: Bool { ink == nil && formulas.isEmpty && lines.isEmpty }
    }

    /// A picture of what was written: the part of the page it covers, in the overlay's frame, and its
    /// colours and cover, packed.
    private struct Rendered {
        var rect: CGRect
        var columns: Int
        var rows: Int
        var rgb: Data
        var alpha: Data
    }

    static func export(pdfURL: URL, folder: URL, title: String, withMarks: Bool) -> URL? {
        guard let document = DocFile.open(pdfURL), document.pageCount > 0 else { return nil }
        let drawings = DrawingStore(folder: folder)
        let mathStore = MathStore(folder: folder)
        let math = mathStore.load()
        let marks = withMarks ? QuestionStore(folder: folder).load().filter { !$0.markHidden && !$0.turns.isEmpty } : []
        let written: (Int) -> Written = { index in
            var content = Written()
            if let drawing = drawings.load(page: index), !drawing.strokes.isEmpty { content.ink = drawing }
            for item in math where item.page == index {
                if let shape = UIImage(contentsOfFile: mathStore.imageURL(item.image).path) {
                    content.formulas.append((item, coloured(shape, item.color)))
                }
            }
            content.lines = marks.filter { $0.page == index }.map(\.points)
            return content
        }

        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { name = name.replacingOccurrences(of: bad, with: "-") }
        if name.isEmpty { name = "문서" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) (필기).pdf")
        try? FileManager.default.removeItem(at: url)

        do {
            try append(document: document, pdfURL: pdfURL, to: url, written: written)
            DebugLog.write("export: the file as it is, with an update added")
            return url
        } catch {
            DebugLog.write("export: the file could not be added to (\(error)); written anew instead")
            try? FileManager.default.removeItem(at: url)
        }
        return redraw(document: document, to: url, written: written) ? url : nil
    }

    private static func quarterTurns(of page: PDFPage) -> Int {
        (((page.rotation % 360) + 360) % 360) / 90
    }

    // MARK: the file itself, added to

    private static func append(document: PDFDocument, pdfURL: URL, to url: URL, written: (Int) -> Written) throws {
        // Which pages of the document are the file's own and which were added since.
        let added = DocFile.addedPages(of: pdfURL)
        var papers = [AddedPage?](repeating: nil, count: max(document.pageCount - added.count, 0))
        for page in added {
            papers.insert(page, at: min(max(page.index, 0), papers.count))
        }
        guard papers.count == document.pageCount else { throw PDFAppendError("the list of added pages does not fit the document") }

        var slots: [PDFAppend.Slot] = []
        var original = 0
        var changes = 0
        for index in 0..<papers.count {
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFAppendError("a page is missing") }
                // The overlay's frame: the page before any turning, measured from its top-left corner.
                let crop = page.bounds(for: .cropBox)
                let content = written(index)
                var picture: PDFAppend.Picture?
                if !content.isEmpty, let made = render(content, pageSize: crop.size, quarterTurns: quarterTurns(of: page)) {
                    // From the overlay's frame to the page's own measure, which runs upward from the lower left.
                    picture = PDFAppend.Picture(
                        x: crop.minX + made.rect.minX, y: crop.maxY - made.rect.maxY,
                        width: made.rect.width, height: made.rect.height,
                        columns: made.columns, rows: made.rows, rgb: made.rgb, alpha: made.alpha
                    )
                    changes += 1
                }
                if let paper = papers[index] {
                    slots.append(PDFAppend.Slot(
                        original: nil, width: crop.width, height: crop.height,
                        art: Paper.commands(paper.paper, size: crop.size), picture: picture
                    ))
                    changes += 1
                } else {
                    slots.append(PDFAppend.Slot(original: original, picture: picture))
                    original += 1
                }
            }
        }

        try FileManager.default.copyItem(at: pdfURL, to: url)
        // Nothing written and no page added: the copy is the export.
        if changes == 0 { return }
        let data = try Data(contentsOf: pdfURL, options: .mappedIfSafe)
        let update = try PDFAppend.update(of: data, slots: slots)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: update)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // The result has to open with every page in it, or it is not worth keeping.
        guard let check = PDFDocument(url: url), check.pageCount == document.pageCount else {
            throw PDFAppendError("the result does not open as it should")
        }
    }

    /// Where on the page anything was written, in the overlay's frame.
    private static func bounds(of content: Written, quarterTurns: Int) -> CGRect {
        var box = CGRect.null
        if let ink = content.ink { box = box.union(ink.bounds) }
        for formula in content.formulas {
            // A formula stands upright on a page shown turned, so in the page's own frame it lies turned.
            let item = formula.item
            let sideways = quarterTurns % 2 != 0
            let width = sideways ? item.height : item.width, height = sideways ? item.width : item.height
            box = box.union(CGRect(x: item.frame.midX - width / 2, y: item.frame.midY - height / 2, width: width, height: height))
        }
        for points in content.lines {
            for point in points {
                box = box.union(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            }
        }
        return box
    }

    private static func render(_ content: Written, pageSize: CGSize, quarterTurns: Int) -> Rendered? {
        let whole = CGRect(origin: .zero, size: pageSize)
        let wanted = bounds(of: content, quarterTurns: quarterTurns).insetBy(dx: -4, dy: -4).intersection(whole)
        guard !wanted.isNull, !wanted.isInfinite, wanted.width >= 1, wanted.height >= 1 else { return nil }
        // Three points of the picture to a point of the page; fewer when a great deal of a large page is covered.
        let scale = min(3, (8_000_000 / (wanted.width * wanted.height)).squareRoot())
        let columns = max(1, Int((wanted.width * scale).rounded(.up)))
        let rows = max(1, Int((wanted.height * scale).rounded(.up)))
        let rect = CGRect(x: wanted.minX, y: wanted.minY, width: CGFloat(columns) / scale, height: CGFloat(rows) / scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                  data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        var ink: UIImage?
        if let drawing = content.ink {
            // PencilKit draws for the appearance in force; the page is light paper whatever the screen is.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: rect, scale: scale)
            }
        }
        // From here on a point is a point of the overlay's frame.
        cg.translateBy(x: 0, y: CGFloat(rows))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        UIGraphicsPushContext(cg)
        draw(content, ink: ink, inkRect: rect, quarterTurns: quarterTurns)
        UIGraphicsPopContext()

        guard let memory = cg.data else { return nil }
        let stride = cg.bytesPerRow
        let source = memory.bindMemory(to: UInt8.self, capacity: stride * rows)
        var rgb = [UInt8](repeating: 0, count: columns * rows * 3)
        var alpha = [UInt8](repeating: 0, count: columns * rows)
        var any = false
        rgb.withUnsafeMutableBufferPointer { colours in
            alpha.withUnsafeMutableBufferPointer { cover in
                for row in 0..<rows {
                    var from = row * stride
                    var to = row * columns * 3
                    let line = row * columns
                    for column in 0..<columns {
                        let a = Int(source[from + 3])
                        if a == 255 {
                            any = true
                            cover[line + column] = 255
                            colours[to] = source[from]
                            colours[to + 1] = source[from + 1]
                            colours[to + 2] = source[from + 2]
                        } else if a > 0 {
                            // The context keeps each colour already multiplied by its cover; a PDF wants it plain.
                            any = true
                            cover[line + column] = UInt8(a)
                            colours[to] = UInt8(min(255, (Int(source[from]) * 255 + a / 2) / a))
                            colours[to + 1] = UInt8(min(255, (Int(source[from + 1]) * 255 + a / 2) / a))
                            colours[to + 2] = UInt8(min(255, (Int(source[from + 2]) * 255 + a / 2) / a))
                        }
                        from += 4
                        to += 3
                    }
                }
            }
        }
        guard any, let packedColours = PDFFlate.deflate(Data(rgb)), let packedCover = PDFFlate.deflate(Data(alpha)) else { return nil }
        return Rendered(rect: rect, columns: columns, rows: rows, rgb: packedColours, alpha: packedCover)
    }

    /// Draws what was written into the current context, which has to measure in the overlay's frame:
    /// a point is a page point, from the top-left corner of the page before any turning.
    private static func draw(_ content: Written, ink: UIImage?, inkRect: CGRect, quarterTurns: Int) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        for formula in content.formulas {
            // A formula stands upright on a page that is shown turned: it is turned back by as much.
            let item = formula.item
            cg.saveGState()
            cg.translateBy(x: item.frame.midX, y: item.frame.midY)
            cg.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
            formula.picture.draw(in: CGRect(x: -item.width / 2, y: -item.height / 2, width: item.width, height: item.height))
            cg.restoreGState()
        }
        ink?.draw(in: inkRect)
        for points in content.lines {
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
    }

    // MARK: written anew by PDFKit

    private static func redraw(document: PDFDocument, to url: URL, written: (Int) -> Written) -> Bool {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let content = written(index)
            if content.isEmpty { continue }
            let crop = page.bounds(for: .cropBox)
            let frame = CGRect(origin: .zero, size: crop.size)
            let turns = quarterTurns(of: page)
            var ink: UIImage?
            if let drawing = content.ink {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: frame, scale: 3)
                }
            }
            let stamp = InkStamp(bounds: crop, forType: .stamp, withProperties: nil)
            stamp.shouldPrint = true
            stamp.paint = { cg in
                cg.saveGState()
                // From the page's own space (bottom-left corner, upward) to the overlay's frame.
                cg.translateBy(x: crop.minX, y: crop.maxY)
                cg.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(cg)
                draw(content, ink: ink, inkRect: frame, quarterTurns: turns)
                UIGraphicsPopContext()
                cg.restoreGState()
            }
            page.addAnnotation(stamp)
        }
        var options: [PDFDocumentWriteOption: Any] = [:]
        if document.isEncrypted {
            // Left to itself PDFKit carries the old lock into the new file, where no password fits it any
            // more. So the copy is locked afresh the way the original was: open to read without a password,
            // with the same things held back (printing, copying), under an owner's password nobody has.
            options[.ownerPasswordOption] = UUID().uuidString
            options[.accessPermissionsOption] = NSNumber(value: document.accessPermissions.rawValue)
        }
        guard document.write(to: url, withOptions: options.isEmpty ? nil : options) else { return false }
        // A copy that does not open is worse than none.
        guard let check = PDFDocument(url: url), !check.isLocked, check.pageCount == document.pageCount else {
            DebugLog.write("export: the copy written anew does not open; given up")
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
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
