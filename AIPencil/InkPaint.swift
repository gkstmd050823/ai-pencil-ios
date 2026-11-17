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

    /// Whether a point of a stroke is in a gap of a dashed line: it has no opacity and the size PencilKit
    /// draws nothing for (see PenLine.control). Such a point is a place of no width.
    static func isGap(_ point: PKStrokePoint) -> Bool {
        point.opacity < 0.02 && point.size.width <= InkWidth.nothing + 0.02
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
            let width = isGap(point) ? 0 : max(0.2, InkWidth.width(ofSize: point.size.width) * grown)
            if let first = line.widths.first, abs(width - first) > 0.02 * first { line.even = false }
            line.points.append(turn.isIdentity ? point.location : point.location.applying(turn))
            line.widths.append(width)
        }
        // The stroke's own points first: a line written by the app's pen has them half a screen pixel
        // apart at the zoom it was written at, and is then drawn through exactly the points it was
        // written through.
        // (How far apart the points are is told where the line is inked: a dashed line has no points in
        // its gaps, and is none the coarser for that.)
        var length: CGFloat = 0
        var steps = 0
        for point in path {
            if let last = line.points.last, let wide = line.widths.last, wide > 0, !isGap(point) {
                let here = turn.isIdentity ? point.location : point.location.applying(turn)
                length += hypot(here.x - last.x, here.y - last.y)
                steps += 1
            }
            add(point)
        }
        let count = line.points.count
        guard count > 1 else { return line }
        let apart = length / CGFloat(max(steps, 1))
        // (Its own points do while they are no more than three pixels apart: a line through points that
        // close keeps within a tenth of a pixel of the curve even round a tight bend. Until 0.13.3 they
        // were given up at under two pixels, and PencilKit's curve was worked out anew through a line of
        // tens of thousands of points every time the page was zoomed in a little past where it was written.)
        if apart <= step * 2.5 { return line }
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

    /// A line as a shape to fill: a band between each two points, and at each point what closes the gap
    /// between the band before it and the band after. Every piece turns the same way round, so that
    /// where pieces overlap the filling does not cancel.
    ///
    /// At the line's ends, at the ends of a dash and where the line turns sharply, what closes the gap is
    /// a disc. Everywhere else the two bands meet at a slight angle and the gap is a sliver on either
    /// side, from the point out to the two bands' corners: that sliver is all that is added. (Until
    /// 0.13.2 there was a disc at every point. Zoomed in far, a line has a point every pixel or so and a
    /// disc of forty sides at each: nearly all of every disc lay under the bands, and making and filling
    /// them was most of what a long line cost.) A sliver's straight edge is within three hundredths of
    /// a pixel of the disc's round one, or the disc is drawn.
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
        /// Three or four corners, turned the way every piece is turned; nothing for corners that enclose nothing.
        func add(_ corners: [CGPoint]) {
            var area: CGFloat = 0
            for corner in corners.indices {
                let a = corners[corner], b = corners[(corner + 1) % corners.count]
                area += a.x * b.y - b.x * a.y
            }
            guard abs(area) > 1e-9 else { return }
            // (The discs go round the way that makes this sum positive.)
            path.addLines(between: area < 0 ? corners.reversed() : corners)
            path.closeSubpath()
        }
        for index in first..<end {
            let here = points[index]
            let radius = widths[index] / 2
            // (A place of no width is a gap in a dashed line: nothing there, and nothing to or from it.)
            guard radius > 0 else { continue }
            let joinsBefore = index > first && widths[index - 1] > 0
            let joinsAfter = index + 1 < end && widths[index + 1] > 0
            var round = true
            if joinsBefore, joinsAfter {
                let before = points[index - 1], after = points[index + 1]
                let ax = here.x - before.x, ay = here.y - before.y
                let bx = after.x - here.x, by = after.y - here.y
                let la = hypot(ax, ay), lb = hypot(bx, by)
                if la > 0.01, lb > 0.01 {
                    let turn = (ax * bx + ay * by) / (la * lb)
                    // (How far the sliver's straight edge is inside the disc's round one, in pixels.)
                    let flat = radius * fineness * (1 - ((1 + max(turn, -1)) / 2).squareRoot())
                    if turn > 0, flat < 0.03 {
                        round = false
                        for side in [CGFloat(1), CGFloat(-1)] {
                            add([
                                here,
                                CGPoint(x: here.x - ay / la * radius * side, y: here.y + ax / la * radius * side),
                                CGPoint(x: here.x - by / lb * radius * side, y: here.y + bx / lb * radius * side),
                            ])
                        }
                    }
                }
            }
            if round {
                let sides = max(10, min(48, Int((2 * CGFloat.pi * radius * fineness / 1.5).rounded(.up))))
                let unit = self.round(sides: sides)
                path.move(to: CGPoint(x: here.x + unit[0].x * radius, y: here.y + unit[0].y * radius))
                for side in 1..<sides {
                    path.addLine(to: CGPoint(x: here.x + unit[side].x * radius, y: here.y + unit[side].y * radius))
                }
                path.closeSubpath()
            }
            guard index > first else { continue }
            let before = points[index - 1]
            let radiusBefore = widths[index - 1] / 2
            guard radiusBefore > 0 else { continue }
            let dx = here.x - before.x, dy = here.y - before.y
            let length = hypot(dx, dy)
            guard length > 0.01 else { continue }
            let nx = -dy / length, ny = dx / length
            add([
                CGPoint(x: before.x + nx * radiusBefore, y: before.y + ny * radiusBefore),
                CGPoint(x: here.x + nx * radius, y: here.y + ny * radius),
                CGPoint(x: here.x - nx * radius, y: here.y - ny * radius),
                CGPoint(x: before.x - nx * radiusBefore, y: before.y - ny * radiusBefore),
            ])
        }
        return path
    }

    /// "-demoOldHighlighter" has the highlighter drawn the way it was until 0.12.0, for the build server
    /// to set the time it takes beside the time it takes now.
    static let oldHighlighter = ProcessInfo.processInfo.arguments.contains("-demoOldHighlighter")

    /// How far apart, as a share of its width, the points of a wide line need to be. A highlighter's line
    /// is some fourteen points wide and written through points a fifth of a point apart: a line run
    /// through every seventh of them is the same line to the eye (on a bend as tight as a small letter it
    /// is off by less than a hundredth of a point) and is drawn in a seventh of the time.
    static let wideGap: CGFloat = 0.07

    /// [points] with those left out that are nearer than [gap] to the one kept before them. The first and
    /// the last always stay.
    static func thinned(_ points: [CGPoint], gap: CGFloat) -> [CGPoint] {
        guard points.count > 2, gap > 0 else { return points }
        var kept: [CGPoint] = [points[0]]
        kept.reserveCapacity(points.count / 2)
        var last = points[0]
        for point in points[1..<(points.count - 1)] where hypot(point.x - last.x, point.y - last.y) >= gap {
            kept.append(point)
            last = point
        }
        kept.append(points[points.count - 1])
        return kept
    }

    /// Draws a line in a colour. [wide] says it is a highlighter's, which needs only some of its points.
    ///
    /// A line of many widths is filled a stretch at a time, and only the stretches that reach the part
    /// being drawn. (Until 0.13.3 the whole of it was one shape, filled in one go: a line of fifty
    /// thousand points, zoomed in on so that a tenth of it was in the picture, was made and filled whole,
    /// and one shape of so many pieces costs far more to fill than the same pieces a few hundred at a
    /// time. A picture of such lines took six seconds.) [wanted] is asked between stretches whether the
    /// picture is still wanted; when it is not, the drawing stops where it is.
    static func draw(
        _ line: Line, color: CGColor, in context: CGContext, fineness: CGFloat = 4, wide: Bool = false, wanted: (() -> Bool)? = nil
    ) {
        guard let first = line.points.first else { return }
        if line.even {
            let run = wide && !oldHighlighter ? thinned(line.points, gap: line.widths[0] * wideGap) : line.points
            context.setStrokeColor(color)
            context.setLineWidth(line.widths[0])
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: first)
            if run.count == 1 { context.addLine(to: first) }
            for point in run.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        } else {
            context.setFillColor(color)
            let count = line.points.count
            guard count > stretch + 1 else {
                context.addPath(shape(points: line.points, widths: line.widths, from: 0, fineness: fineness))
                context.fillPath()
                return
            }
            let clip = context.boundingBoxOfClipPath
            // The stretches: which points each has, the room it takes, and the pixels round its first
            // point, where it joins the one before. (A stretch ends in a disc and the next begins with
            // the same disc; filled one after the other the pixels on that disc's rim that are half
            // covered would be covered twice. Each stretch is filled everywhere but at its joints, and
            // each joint is filled once, with the two stretches that meet there as one shape.)
            var parts: [(from: Int, to: Int, box: CGRect, joint: CGRect)] = []
            var from = 0
            while from < count - 1 {
                let to = min(count, from + stretch + 1)
                var left = line.points[from].x, right = left, top = line.points[from].y, bottom = top
                var reach: CGFloat = 0
                for index in from..<to {
                    let point = line.points[index]
                    left = min(left, point.x)
                    right = max(right, point.x)
                    top = min(top, point.y)
                    bottom = max(bottom, point.y)
                    reach = max(reach, line.widths[index])
                }
                var joint = CGRect.null
                if from > 0 {
                    let at = line.points[from]
                    let round = line.widths[from] / 2 + 1.5 / fineness
                    // (Grown to whole pixels of the picture, so that its edge cuts no pixel in two.)
                    let pixels = context.convertToDeviceSpace(CGRect(x: at.x - round, y: at.y - round, width: round * 2, height: round * 2)).integral
                    joint = context.convertToUserSpace(pixels)
                }
                parts.append((from, to, CGRect(x: left, y: top, width: right - left, height: bottom - top).insetBy(dx: -reach, dy: -reach), joint))
                // (The next stretch begins on this one's last point, so that the two join.)
                from = to - 1
            }
            for (number, part) in parts.enumerated() {
                if let wanted, !wanted() { return }
                if part.box.intersects(clip) {
                    let after = number + 1 < parts.count ? parts[number + 1].joint : CGRect.null
                    context.saveGState()
                    context.addRect(clip)
                    if !part.joint.isNull { context.addRect(part.joint) }
                    if !after.isNull { context.addRect(after) }
                    context.clip(using: .evenOdd)
                    context.addPath(shape(points: line.points, widths: line.widths, from: part.from, to: part.to, fineness: fineness))
                    context.fillPath()
                    context.restoreGState()
                }
                if number > 0, part.joint.intersects(clip) {
                    let before = parts[number - 1]
                    context.saveGState()
                    context.clip(to: part.joint)
                    context.addPath(shape(points: line.points, widths: line.widths, from: before.from, to: before.to, fineness: fineness))
                    context.addPath(shape(points: line.points, widths: line.widths, from: part.from, to: part.to, fineness: fineness))
                    context.fillPath()
                    context.restoreGState()
                }
            }
        }
    }

    /// How many points of a long line are filled at a time.
    private static let stretch = 256

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
        region: CGRect, scale: CGFloat, dark: Bool, solid: Bool, still: (() -> Bool)? = nil
    ) {
        // (A highlighter's line is wide: its own points do, a good half point apart, without working out more.)
        let step = solid && !oldHighlighter ? max(0.6, 1.2 / scale) : max(0.02, 1.2 / scale)
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
            if let still, !still() { return }
            if isPlain(stroke) {
                flush()
                draw(line(of: stroke, step: step), color: color(of: stroke, dark: dark, solid: solid), in: context, fineness: scale, wide: solid, wanted: still)
            } else {
                others.append(stroke)
                othersBox = othersBox.union(box)
            }
        }
        flush()
    }

    /// What is made of a page's handwriting: the picture of everything but highlighter, covering the
    /// part asked for, and the picture of the highlighter (none where there is no highlighter). The
    /// highlighter's covers the same part, so that it too can be brought up to date just where the
    /// handwriting changed. (Until 0.12.0 it covered the room the highlighter took and was drawn whole
    /// every time, every line of it: on a page with much highlighter that took longer with each line, and
    /// while lines were being written one after another the picture never caught up with them.)
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
        of drawing: PKDrawing, rect: CGRect, scale: CGFloat, dark: Bool, over base: CGImage?, redoing dirty: CGRect?,
        highOver highBase: CGImage? = nil, still: (() -> Bool)? = nil
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
            paint(strokes, where: { !isHighlighter($0) }, in: context, picture: rect, region: region, scale: scale, dark: dark, solid: false, still: still)
        }
        // (No longer wanted: what there is of it is let go, and whoever asked knows why nothing came.)
        if let still, !still() { return nil }
        guard let pens = context.makeImage() else { return nil }
        var made = Made(pens: pens, strokes: strokes.count)
        if oldHighlighter {
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
        guard strokes.contains(where: isHighlighter), let high = canvas(rect, scale: scale) else { return made }
        var highRegion = rect
        if let highBase, let dirty, highBase.width == high.width, highBase.height == high.height {
            high.setBlendMode(.copy)
            high.draw(highBase, in: CGRect(x: 0, y: 0, width: high.width, height: high.height))
            high.setBlendMode(.normal)
            let cut = dirty.intersection(rect)
            highRegion = cut.isNull || cut.isEmpty ? .null : whole(cut, scale: scale, origin: rect.origin)
        }
        aim(high, at: rect, scale: scale)
        if !highRegion.isNull {
            if highRegion != rect {
                high.clip(to: highRegion)
                high.clear(highRegion)
            }
            paint(strokes, where: isHighlighter, in: high, picture: rect, region: highRegion, scale: scale, dark: dark, solid: true)
        }
        made.high = high.makeImage()
        made.highRect = rect
        return made
    }
}
