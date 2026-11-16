import PencilKit
import UIKit

// The app's own drawing of the handwriting.
//
// PencilKit keeps the handwriting (a page's strokes are a PKDrawing, on disk and in memory) and can draw
// it, but it draws as it sees fit: in tiles of its own size, which it lays over the page a little off the
// screen's pixels, so that a line which was sharp while it was being written (the app draws that itself,
// as a plain shape) went soft the moment the pen lifted and PencilKit's drawing of it took over. So the
// app draws the finished handwriting too: every plain stroke as the same shape it was written as, into a
// picture that has exactly the screen's pixels. PencilKit's canvas stays underneath, out of sight, and is
// shown only while a tool is in hand that works on the canvas itself (the lasso, the eraser that rubs out
// part of a line, the pencil), or until a picture is ready.
//
// Highlighter goes into a picture of its own, which is laid over the page as a tint (it darkens the
// paper, and leaves print that is darker than itself as dark as it was) and not as paint, so that what is
// written under it stays readable however often it is gone over.

enum InkPaint {
    /// Whether a stroke is highlighter: PencilKit's marker (what the highlighter wrote before 0.8.0), or
    /// a plain line in a see-through colour (what it writes now).
    static func isHighlighter(_ stroke: PKStroke) -> Bool {
        let ink = stroke.ink
        if ink.inkType == .marker { return true }
        return ink.inkType == .monoline && ink.color.cgColor.alpha < 0.99
    }

    /// Whether the app draws a stroke itself. It does where the stroke is a plain line, each point as
    /// wide as it says: the app's own pen, its shapes and its highlighter write such strokes. Anything
    /// else (PencilKit's pencil with its grain, a stroke the part eraser has cut into) is PencilKit's to
    /// draw, and is drawn by it into the same picture.
    static func isPlain(_ stroke: PKStroke) -> Bool {
        stroke.ink.inkType == .monoline && stroke.mask == nil
    }

    /// A stroke as the places it goes through and how wide it is at each, as it is seen on the page.
    struct Line {
        var points: [CGPoint] = []
        var widths: [CGFloat] = []
        /// The same width all along.
        var even = true
    }

    /// The line of a plain stroke, with points no further apart than [step] page points where the stroke
    /// has them that close, and worked out along its curve where it has not.
    static func line(of stroke: PKStroke, step: CGFloat) -> Line {
        let path = stroke.path
        let turn = stroke.transform
        let grown = abs(turn.a * turn.d - turn.b * turn.c).squareRoot()
        var line = Line()
        func add(_ point: PKStrokePoint) {
            let width = max(0.2, InkWidth.width(ofSize: point.size.width) * grown)
            if let first = line.widths.first, abs(width - first) > 0.02 * first { line.even = false }
            line.points.append(turn.isIdentity ? point.location : point.location.applying(turn))
            line.widths.append(width)
        }
        // The stroke's own points first: a line written by the app's pen has them half a screen pixel
        // apart at the zoom it was written at, and is then drawn through exactly the points it was
        // written through.
        var length: CGFloat = 0
        for point in path {
            if let last = line.points.last {
                let here = turn.isIdentity ? point.location : point.location.applying(turn)
                length += hypot(here.x - last.x, here.y - last.y)
            }
            add(point)
        }
        let count = line.points.count
        guard count > 1 else { return line }
        let apart = length / CGFloat(count - 1)
        if apart <= step * 1.5 { return line }
        // Too far apart for this zoom (a shape's outline, a stroke from PencilKit's own pens, a line
        // written zoomed out and looked at zoomed in): the curve PencilKit runs through them is followed.
        line = Line()
        let share = max(0.02, min(1, step / apart))
        for point in path.interpolatedPoints(by: .parametricStep(share)) { add(point) }
        add(path.interpolatedPoint(at: CGFloat(count - 1)))
        return line
    }

    /// The corners of a circle of one, for discs of so many sides, worked out once.
    private static var rounds: [Int: [CGPoint]] = [:]
    private static let roundsLock = NSLock()

    private static func round(sides: Int) -> [CGPoint] {
        roundsLock.lock()
        defer { roundsLock.unlock() }
        if let kept = rounds[sides] { return kept }
        var made: [CGPoint] = []
        for side in 0..<sides {
            let angle = 2 * CGFloat.pi * CGFloat(side) / CGFloat(sides)
            made.append(CGPoint(x: cos(angle), y: sin(angle)))
        }
        rounds[sides] = made
        return made
    }

    /// A line as a shape to fill: a disc at every point and a band between each two. Every piece turns
    /// the same way round, so that where pieces overlap the filling does not cancel.
    ///
    /// The discs are many-sided shapes with straight sides, as many as it takes for a side to be about a
    /// pixel and a half long at [fineness] pixels to a page point. A true circle would be left to whoever
    /// draws the path to make into straight sides, and the layer that shows a line while it is being
    /// written does that for the size of a page point, not for the page as it is zoomed on screen: the
    /// outside of a curve, which is made of these discs, came out in visible corners.
    static func shape(points: [CGPoint], widths: [CGFloat], from: Int, to: Int? = nil, fineness: CGFloat = 4) -> CGPath {
        let path = CGMutablePath()
        let end = min(to ?? points.count, points.count)
        guard end > 0 else { return path }
        let first = max(0, min(from, end - 1))
        for index in first..<end {
            let here = points[index]
            let radius = widths[index] / 2
            let sides = max(10, min(48, Int((2 * CGFloat.pi * radius * fineness / 1.5).rounded(.up))))
            let unit = round(sides: sides)
            path.move(to: CGPoint(x: here.x + unit[0].x * radius, y: here.y + unit[0].y * radius))
            for side in 1..<sides {
                path.addLine(to: CGPoint(x: here.x + unit[side].x * radius, y: here.y + unit[side].y * radius))
            }
            path.closeSubpath()
            guard index > first else { continue }
            let before = points[index - 1]
            let radiusBefore = widths[index - 1] / 2
            let dx = here.x - before.x, dy = here.y - before.y
            let length = hypot(dx, dy)
            guard length > 0.01 else { continue }
            let nx = -dy / length, ny = dx / length
            var corners = [
                CGPoint(x: before.x + nx * radiusBefore, y: before.y + ny * radiusBefore),
                CGPoint(x: here.x + nx * radius, y: here.y + ny * radius),
                CGPoint(x: here.x - nx * radius, y: here.y - ny * radius),
                CGPoint(x: before.x - nx * radiusBefore, y: before.y - ny * radiusBefore),
            ]
            var area: CGFloat = 0
            for corner in 0..<4 {
                let a = corners[corner], b = corners[(corner + 1) % 4]
                area += a.x * b.y - b.x * a.y
            }
            // (The discs go round the way that makes this sum positive.)
            if area < 0 { corners.reverse() }
            path.addLines(between: corners)
            path.closeSubpath()
        }
        return path
    }

    /// Draws a line in a colour.
    static func draw(_ line: Line, color: CGColor, in context: CGContext, fineness: CGFloat = 4) {
        guard let first = line.points.first else { return }
        if line.even {
            context.setStrokeColor(color)
            context.setLineWidth(line.widths[0])
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: first)
            if line.points.count == 1 { context.addLine(to: first) }
            for point in line.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        } else {
            context.setFillColor(color)
            context.addPath(shape(points: line.points, widths: line.widths, from: 0, fineness: fineness))
            context.fillPath()
        }
    }

    /// The colour a stroke is seen in: on dark paper, PencilKit's dark-screen counterpart of it.
    static func color(of stroke: PKStroke, dark: Bool, solid: Bool) -> CGColor {
        let plain = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let shown = dark ? plain.onDarkPaper : plain
        return (solid ? shown.withAlphaComponent(1) : shown).cgColor
    }

    /// [rect] grown to whole pixels at [scale] pixels a point, the grid starting at [origin].
    static func whole(_ rect: CGRect, scale: CGFloat, origin: CGPoint = .zero) -> CGRect {
        let left = ((rect.minX - origin.x) * scale).rounded(.down) / scale + origin.x
        let top = ((rect.minY - origin.y) * scale).rounded(.down) / scale + origin.y
        let right = ((rect.maxX - origin.x) * scale).rounded(.up) / scale + origin.x
        let bottom = ((rect.maxY - origin.y) * scale).rounded(.up) / scale + origin.y
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func canvas(_ rect: CGRect, scale: CGFloat) -> CGContext? {
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// Sets a context up so that a point of the page, measured from its top-left corner downward, is
    /// drawn where it belongs in a picture of [rect].
    private static func aim(_ context: CGContext, at rect: CGRect, scale: CGFloat) {
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
    }

    /// Draws strokes, in their order, where they touch [region]. [wanted] picks the strokes that belong
    /// in this picture; [solid] draws them in their colour at full strength.
    private static func paint(
        _ strokes: [PKStroke], where wanted: (PKStroke) -> Bool, in context: CGContext, picture: CGRect,
        region: CGRect, scale: CGFloat, dark: Bool, solid: Bool
    ) {
        let step = max(0.02, 1.2 / scale)
        var others: [PKStroke] = []
        var othersBox = CGRect.null
        func flush() {
            guard !others.isEmpty else { return }
            // PencilKit draws these, into a picture of just the room they take, on the same pixels.
            let box = whole(othersBox.intersection(region), scale: scale, origin: picture.origin)
            let run = others
            others = []
            othersBox = .null
            guard box.width > 0, box.height > 0 else { return }
            var made: CGImage?
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                made = PKDrawing(strokes: run).image(from: box, scale: scale).cgImage
            }
            guard let made else { return }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(made, in: CGRect(origin: .zero, size: box.size))
            context.restoreGState()
        }
        for stroke in strokes where wanted(stroke) {
            let box = stroke.renderBounds
            guard box.intersects(region) else { continue }
            if isPlain(stroke) {
                flush()
                draw(line(of: stroke, step: step), color: color(of: stroke, dark: dark, solid: solid), in: context, fineness: scale)
            } else {
                others.append(stroke)
                othersBox = othersBox.union(box)
            }
        }
        flush()
    }

    /// What is made of a page's handwriting: the picture of everything but highlighter, covering the
    /// part asked for, and the picture of the highlighter, covering the room the highlighter takes
    /// within that part (none where there is no highlighter).
    struct Made {
        var pens: CGImage
        var high: CGImage?
        var highRect = CGRect.null
        var strokes = 0
    }

    /// Draws the handwriting. Called off the main thread.
    ///
    /// With [base] (the picture now on show, of the same part at the same scale) and [dirty] (the part of
    /// the page where the handwriting has changed since), only that part is drawn again and the rest is
    /// copied: a line added or rubbed out on a full page costs what its neighbourhood costs.
    static func pictures(
        of drawing: PKDrawing, rect: CGRect, scale: CGFloat, dark: Bool, over base: CGImage?, redoing dirty: CGRect?
    ) -> Made? {
        let strokes = drawing.strokes
        guard let context = canvas(rect, scale: scale) else { return nil }
        var region = rect
        if let base, let dirty, base.width == context.width, base.height == context.height {
            context.setBlendMode(.copy)
            context.draw(base, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.setBlendMode(.normal)
            let cut = dirty.intersection(rect)
            // (Nothing of the change is in this picture: the copy is the picture.)
            region = cut.isNull || cut.isEmpty ? .null : whole(cut, scale: scale, origin: rect.origin)
        }
        aim(context, at: rect, scale: scale)
        if !region.isNull {
            if region != rect {
                context.clip(to: region)
                context.clear(region)
            }
            paint(strokes, where: { !isHighlighter($0) }, in: context, picture: rect, region: region, scale: scale, dark: dark, solid: false)
        }
        guard let pens = context.makeImage() else { return nil }
        var made = Made(pens: pens, strokes: strokes.count)
        // The highlighter is few lines, and is drawn afresh each time.
        var room = CGRect.null
        for stroke in strokes where isHighlighter(stroke) { room = room.union(stroke.renderBounds) }
        let inside = room.isNull ? CGRect.null : room.insetBy(dx: -1, dy: -1).intersection(rect)
        guard !inside.isNull, !inside.isEmpty else { return made }
        let highRect = whole(inside, scale: scale, origin: rect.origin)
        if let high = canvas(highRect, scale: scale) {
            aim(high, at: highRect, scale: scale)
            paint(strokes, where: isHighlighter, in: high, picture: highRect, region: highRect, scale: scale, dark: dark, solid: true)
            made.high = high.makeImage()
            made.highRect = highRect
        }
        return made
    }
}
