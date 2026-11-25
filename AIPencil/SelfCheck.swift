import CoreGraphics
import Foundation
import PencilKit
import UIKit

/// Checks of the app's own reckoning that need no screen: run on the build server ("-selfCheck"), each
/// leaving a line in the app's notes that says "ok" or "FAILED". The build fails on a line that says FAILED.
/// (The project has no target for unit tests; this stands in for one.)
enum SelfCheck {
    private static func note(_ name: String, _ passed: Bool, _ detail: String = "") {
        DebugLog.write("check: \(name) \(passed ? "ok" : "FAILED")\(detail.isEmpty ? "" : " (\(detail))")")
    }

    static func run() {
        holding()
        straightLines()
        pressure()
        steadying()
        shapes()
        dashes()
        DebugLog.write("check: done")
    }

    // MARK: dashes, dots and the brush

    /// The dashes of a cut line: where each begins and ends, told by its first and last place's x. (The
    /// lines checked here run straight across.)
    private static func runs(_ points: [CGPoint], _ widths: [CGFloat]) -> [(from: CGFloat, to: CGFloat)] {
        var found: [(from: CGFloat, to: CGFloat)] = []
        var began: CGFloat?
        var last: CGFloat = 0
        for index in points.indices {
            if widths[index] > 0 {
                if began == nil { began = points[index].x }
                last = points[index].x
            } else if let start = began {
                found.append((start, last))
                began = nil
            }
        }
        if let start = began { found.append((start, last)) }
        return found
    }

    private static func dashes() {
        // A line straight across, 62 points long, written in dashes of 3 with gaps of 3.
        func written(spacing: CGFloat, dash: DashPattern?) -> PenLine {
            var line = PenLine(width: 1, sense: 0, steady: 0, spacing: spacing, dash: dash)
            for step in 0...31 {
                line.add(PenSample(point: CGPoint(x: 100 + 2 * CGFloat(step), y: 300), force: 0, time: Double(step) * 0.004))
            }
            // (The pen rests where the line ends before it lifts. Since 0.15.8 the last moments of a
            // touch are taken out of the line as the pencil's way off the paper: without the rest, this
            // line lost its last six points to that, and the counts below were of a shorter line.)
            for rest in 1...5 {
                line.add(PenSample(point: CGPoint(x: 162, y: 300), force: 0, time: (31 + Double(rest)) * 0.004))
            }
            line.finish()
            return line
        }
        let pattern = DashPattern(on: 3, off: 3)
        let line = written(spacing: 0.3, dash: pattern)
        let cut = pattern.cut(points: line.points, widths: line.widths, along: line.along)
        let found = runs(cut.points, cut.widths)
        var worst: CGFloat = 0
        for (number, run) in found.enumerated() where number < found.count - 1 {
            worst = max(worst, abs(run.from - (100 + 6 * CGFloat(number))))
            worst = max(worst, abs(run.to - (103 + 6 * CGFloat(number))))
        }
        note("a line of 62 points in dashes of 3 and gaps of 3 is eleven dashes", found.count == 11, "\(found.count)")
        note("each dash begins and ends where the pattern says", found.count == 11 && worst < 0.01, String(format: "off by %.4f points at most", Double(worst)))

        // The same line with its points four times as far apart (as written zoomed out): the same dashes.
        let coarse = written(spacing: 1, dash: pattern)
        let coarseCut = pattern.cut(points: coarse.points, widths: coarse.widths, along: coarse.along)
        let coarseFound = runs(coarseCut.points, coarseCut.widths)
        var apart: CGFloat = 0
        if coarseFound.count == found.count {
            for number in found.indices {
                apart = max(apart, abs(coarseFound[number].from - found[number].from))
                apart = max(apart, abs(coarseFound[number].to - found[number].to))
            }
        }
        note("the dashes are the same however fine the line's points are", coarseFound.count == found.count && apart < 0.01, String(format: "%.4f apart at most", Double(apart)))

        // Cut in parts, as it is while it is being written, the parts have the dashes of the whole.
        let middle = line.points.count / 2
        let head = pattern.cut(points: line.points, widths: line.widths, along: line.along, from: 0, to: middle + 1)
        let tail = pattern.cut(points: line.points, widths: line.widths, along: line.along, from: middle)
        let headRuns = runs(head.points, head.widths), tailRuns = runs(tail.points, tail.widths)
        var joined = headRuns
        if let last = joined.last, let next = tailRuns.first, abs(next.from - last.to) < 0.001 {
            // (The dash the cut went through is in both parts.)
            joined[joined.count - 1] = (last.from, next.to)
            joined += tailRuns.dropFirst()
        } else {
            joined += tailRuns
        }
        var parted: CGFloat = joined.count == found.count ? 0 : 99
        if joined.count == found.count {
            for number in found.indices {
                parted = max(parted, abs(joined[number].from - found[number].from))
                parted = max(parted, abs(joined[number].to - found[number].to))
            }
        }
        note("a line cut in two parts has the dashes of the whole", parted < 0.01, String(format: "%d and %d dashes, %.4f apart at most", headRuns.count, tailRuns.count, Double(parted)))

        // Dots: next to no length each, and as far apart as the pattern says.
        let dots = DashPattern.dotted(width: 1)
        let dotted = written(spacing: 0.3, dash: dots)
        let dotCut = dots.cut(points: dotted.points, widths: dotted.widths, along: dotted.along)
        let dotRuns = runs(dotCut.points, dotCut.widths)
        var longest: CGFloat = 0, uneven: CGFloat = 0
        for (number, run) in dotRuns.enumerated() {
            longest = max(longest, run.to - run.from)
            if number > 0 { uneven = max(uneven, abs(run.from - dotRuns[number - 1].from - 2.25)) }
        }
        note("a dotted line is dots evenly apart", dotRuns.count == 28 && longest < 0.06 && uneven < 0.01, String(format: "%d dots, %.3f long at most", dotRuns.count, Double(longest)))

        // A whole line has no gaps, and is the shape it always was.
        let whole = written(spacing: 0.3, dash: nil)
        let asBefore = InkPaint.shape(points: whole.points, widths: whole.widths, from: 0, fineness: 4)
        note("a whole line is drawn as it was", whole.shape(from: 0, fineness: 4).boundingBoxOfPath == asBefore.boundingBoxOfPath && whole.along.count == whole.points.count)

        // The dashed line as a stroke, kept as a file's handwriting is kept and read back: the app's
        // drawing of it has the same dashes, and uses the stroke's own places.
        if let stroke = line.stroke(color: .black) {
            var back = InkPaint.line(of: stroke, step: 0.6)
            var kept = "as made"
            if let again = try? PKDrawing(data: PKDrawing(strokes: [stroke]).dataRepresentation()), let read = again.strokes.first {
                back = InkPaint.line(of: read, step: 0.6)
                kept = "read back from its data"
            } else {
                kept = "NOT read back"
            }
            let backRuns = runs(back.points, back.widths)
            var moved: CGFloat = backRuns.count == found.count ? 0 : 99
            if backRuns.count == found.count {
                for number in found.indices {
                    moved = max(moved, abs(backRuns[number].from - found[number].from))
                    moved = max(moved, abs(backRuns[number].to - found[number].to))
                }
            }
            note(
                "a dashed stroke read back from the handwriting has its dashes", kept == "read back from its data" && moved < 0.05,
                String(format: "%d dashes %@, %.4f points off at most", backRuns.count, kept, Double(moved))
            )
            // (A stroke with gaps is not taken for one of a single width: it is filled as a shape.)
            note("a dashed stroke is not drawn as one unbroken line", !back.even)
        } else {
            note("a dashed line makes a stroke", false)
        }

        // The brush: a line pressed lightly is a hair, pressed hard it is much wider, and it grows evenly between.
        func brushed(_ force: CGFloat) -> CGFloat {
            var line = PenLine(width: 2, sense: 1, steady: 0, spacing: 0.3, curve: .brush)
            for step in 0...40 {
                line.add(PenSample(point: CGPoint(x: 100 + 2 * CGFloat(step), y: 300), force: force, time: Double(step) * 0.004, most: PenLine.fullForce))
            }
            return line.widths[line.widths.count / 2]
        }
        let light = brushed(0.1), medium = brushed(1.5), heavy = brushed(3.2)
        let hair: Bool = light < 0.5
        let broad: Bool = heavy > 5
        let between: Bool = medium > light && medium < heavy
        note(
            "the brush writes a hair under a light hand and a broad line under a heavy one", hair && broad && between,
            String(format: "%.2f, %.2f and %.2f points wide for a pen of 2", Double(light), Double(medium), Double(heavy))
        )
    }

    // MARK: shapes

    private static func shapes() {
        func far(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

        // A rectangle drawn a little askew, its ends not quite meeting: a rectangle that lies level.
        let askew = ShapeFinder.find(HandDrawn.walk([point(100, 100), point(300, 104), point(297, 222), point(102, 218)], short: 0.08))
        if case .polygon(let corners)? = askew, corners.count == 4 {
            let sides = [far(corners[0], corners[1]), far(corners[1], corners[2])].sorted()
            let wide = sides[1], tall = sides[0]
            // (Every side runs straight across or straight up.)
            var level = true
            for index in 0..<4 {
                let a = corners[index], b = corners[(index + 1) % 4]
                let upright: Bool = abs(a.x - b.x) < 0.01
                let across: Bool = abs(a.y - b.y) < 0.01
                if !upright, !across { level = false }
            }
            let asWide: Bool = abs(wide - 197.5) < 8
            let asTall: Bool = abs(tall - 118) < 6
            let named: Bool = ShapeFinder.name(.polygon(corners)) == "a rectangle"
            note(
                "a shaky rectangle is a rectangle that lies level", level && asWide && asTall && named,
                String(format: "%.1f by %.1f", Double(wide), Double(tall))
            )
        } else {
            note("a shaky rectangle is a rectangle that lies level", false, "\(String(describing: askew))")
        }

        // The same turned by thirty degrees stays turned, and its corners are made right angles.
        let turned = ShapeFinder.find(HandDrawn.walk([point(200, 100), point(373, 200), point(313, 304), point(140, 204)]))
        if case .polygon(let corners)? = turned, corners.count == 4 {
            let sides = [far(corners[0], corners[1]), far(corners[1], corners[2])].sorted()
            var lies = atan2(corners[1].y - corners[0].y, corners[1].x - corners[0].x) * 180 / .pi
            lies = lies - (lies / 90).rounded(.down) * 90
            let asTurned: Bool = abs(lies - 30) < 2.5
            let asTall: Bool = abs(sides[0] - 120) < 6
            let asWide: Bool = abs(sides[1] - 200) < 8
            let named: Bool = ShapeFinder.name(.polygon(corners)) == "a rectangle"
            note(
                "a rectangle turned thirty degrees stays turned", asTurned && asTall && asWide && named,
                String(format: "%.1f by %.1f at %.1f degrees", Double(sides[1]), Double(sides[0]), Double(lies))
            )
        } else {
            note("a rectangle turned thirty degrees stays turned", false, "\(String(describing: turned))")
        }

        // A triangle: its three corners near where they were drawn.
        let meant = [point(100, 300), point(260, 304), point(180, 170)]
        let three = ShapeFinder.find(HandDrawn.walk(meant, short: 0.05))
        if case .polygon(let corners)? = three, corners.count == 3 {
            var off: CGFloat = 0
            for corner in meant {
                var nearest: CGFloat = 99
                for found in corners { nearest = min(nearest, far(found, corner)) }
                off = max(off, nearest)
            }
            note("a shaky triangle is a triangle", off < 6, String(format: "corners off by %.1f points at most", Double(off)))
        } else {
            note("a shaky triangle is a triangle", false, "\(String(describing: three))")
        }

        // Five corners are kept as five corners.
        let five = ShapeFinder.find(HandDrawn.walk([point(200, 100), point(295, 169), point(259, 281), point(141, 281), point(105, 169)]))
        if case .polygon(let corners)? = five {
            note("five corners are five corners", corners.count == 5)
        } else {
            note("five corners are five corners", false, "\(String(describing: five))")
        }

        // A circle a little wider than tall, gone a little past where it began: a circle.
        let ring = ShapeFinder.find(HandDrawn.oval(center: point(200, 200), a: 60, b: 57, over: 0.04))
        if case .ellipse(let center, let a, let b, _)? = ring {
            let away: CGFloat = far(center, point(200, 200))
            let asLarge: Bool = abs(a - 58.5) < 2.5
            let inPlace: Bool = away < 5
            note(
                "a shaky circle is a circle", a == b && asLarge && inPlace,
                String(format: "%.1f across, its middle off by %.1f", Double(a * 2), Double(away))
            )
        } else {
            note("a shaky circle is a circle", false, "\(String(describing: ring))")
        }

        // An oval turned thirty degrees: as long, as wide and as turned as it was drawn.
        let egg = ShapeFinder.find(HandDrawn.oval(center: point(200, 200), a: 90, b: 40, degrees: 30))
        if case .ellipse(_, let a, let b, let turn)? = egg {
            var lies = turn * 180 / .pi
            lies = lies - (lies / 180).rounded(.down) * 180
            let asLong: Bool = abs(a - 90) < 3.6
            let asWide: Bool = abs(b - 40) < 2.4
            let asTurned: Bool = abs(lies - 30) < 3
            note(
                "an oval turned thirty degrees is that oval", asLong && asWide && asTurned,
                String(format: "%.1f by %.1f at %.1f degrees", Double(a), Double(b), Double(lies))
            )
        } else {
            note("an oval turned thirty degrees is that oval", false, "\(String(describing: egg))")
        }

        // One lying nearly level is made to lie level.
        let flat = ShapeFinder.find(HandDrawn.oval(center: point(200, 200), a: 90, b: 40, degrees: 5))
        if case .ellipse(_, let a, let b, let turn)? = flat {
            let level: Bool = abs(sin(turn)) < 0.0001
            let asLong: Bool = abs(a - 90) < 3.6
            let asWide: Bool = abs(b - 40) < 2.4
            note("an oval nearly level lies level", level && asLong && asWide)
        } else {
            note("an oval nearly level lies level", false, "\(String(describing: flat))")
        }

        // What is not a shape stays as it was drawn: a wave, a star, a ring left open.
        var wave: [CGPoint] = []
        for step in 0..<60 {
            let along = CGFloat(step)
            wave.append(point(100 + 3 * along, 200 + 40 * sin(along / 8)))
        }
        note("a wave is no shape", ShapeFinder.find(wave) == nil)
        let star = HandDrawn.walk([
            point(200, 100), point(230, 190), point(320, 190), point(250, 240), point(280, 330),
            point(200, 275), point(120, 330), point(150, 240), point(80, 190), point(170, 190),
        ], shake: 1)
        note("a star is no shape", ShapeFinder.find(star) == nil)
        let open = Array(HandDrawn.oval(center: point(200, 200), a: 30, b: 45, shake: 1).prefix(70))
        note("a ring left open is no shape", ShapeFinder.find(open) == nil)

        // The end of a straight line is put on the nearest end of another within reach, and on none beyond it.
        let ends = [point(100, 100), point(300, 100), point(306, 108)]
        let put: CGPoint? = Straighten.joined(point(304, 104), to: ends, reach: 12)
        note("an end near another line's end is put on it", put == point(306, 108))
        note("an end far from any other stays", Straighten.joined(point(330, 140), to: ends, reach: 12) == nil)
    }

    // MARK: pressure

    private static func pressure() {
        // The fountain pen's curve is the one the pen had before force was reckoned as a share of the
        // pencil's full force.
        var apart: CGFloat = 0
        for force in [0.05, 0.1, 0.5, 1, 2, 3, 4] as [CGFloat] {
            apart = max(apart, abs(PressureCurve.fountain.swell(force / PenLine.fullForce) - PenLine.swell(force)))
        }
        note("the fountain pen's curve is what it was", apart < 0.0001, "\(apart)")
        note("the brush goes from a hair to much wider", PressureCurve.brush.swell(0) < 0.15 && PressureCurve.brush.swell(1) > 2.5)

        // A pencil that has just landed and hardly moved: its first force was a guess, and is made good.
        var landing = PenLine(width: 2, sense: 1, steady: 0, spacing: 0.3)
        landing.add(PenSample(point: CGPoint(x: 100, y: 100), force: 0.15, time: 0, most: PenLine.fullForce, id: 7))
        landing.add(PenSample(point: CGPoint(x: 100.05, y: 100), force: 0.2, time: 0.004, most: PenLine.fullForce))
        landing.add(PenSample(point: CGPoint(x: 100.1, y: 100), force: 0.25, time: 0.008, most: PenLine.fullForce))
        let thin = landing.widths.first ?? 0
        let changed = landing.correct(id: 7, force: 2.5, most: PenLine.fullForce)
        note("a force made good widens the line where it is not settled", changed && (landing.widths.first ?? 0) > thin + 0.2, "\(thin) to \(landing.widths.first ?? 0)")
        note("a force made good twice counts once", !landing.correct(id: 7, force: 3, most: PenLine.fullForce))

        // A line well on its way: word of an early force comes when that part is settled, and leaves it be.
        var long = PenLine(width: 2, sense: 1, steady: 0, spacing: 0.3)
        for step in 0..<30 {
            long.add(PenSample(
                point: CGPoint(x: 100 + 2 * Double(step), y: 100), force: 0.6, time: Double(step) * 0.004,
                most: PenLine.fullForce, id: step == 3 ? 9 : nil
            ))
        }
        let settled = long.settled
        let points = Array(long.points.prefix(settled)), widths = Array(long.widths.prefix(settled))
        long.correct(id: 9, force: 3.5, most: PenLine.fullForce)
        note(
            "a force made good late leaves the settled part as it was",
            settled > 20 && long.settled >= settled && Array(long.points.prefix(settled)) == points && Array(long.widths.prefix(settled)) == widths,
            "\(settled) points settled"
        )
        note("a force told under a number no place has changes nothing", !long.correct(id: 1234, force: 2))

        // A short line with pointed ends stays as it was on show: lifting the pen changes none of it.
        var short = PenLine(width: 1.42, sense: 0, steady: 0, spacing: 0.3, taper: 0.5)
        for step in 0..<6 {
            short.add(PenSample(point: CGPoint(x: 100 + 0.4 * Double(step), y: 100), force: 0, time: Double(step) * 0.004))
        }
        let shown = short.widths
        short.finish()
        var apartMost: CGFloat = 0
        for (after, before) in zip(short.widths, shown) { apartMost = max(apartMost, abs(after - before)) }
        note("a short pointed line is not changed by the lift", short.widths.count <= shown.count && apartMost < 0.001, "changed by \(apartMost)")
        // A pen that rested where it landed and then set off: its true force, come late, leaves the head as it is.
        var landed = PenLine(width: 1.42, sense: 0, steady: 0, spacing: 0.3, taper: 0.5)
        for step in 0..<14 {
            landed.add(PenSample(
                point: CGPoint(x: 100, y: 100), force: 0.3, time: Double(step) * 0.004, most: PenLine.fullForce, id: step == 0 ? 21 : nil
            ))
        }
        landed.add(PenSample(point: CGPoint(x: 100, y: 100.5), force: 0.3, time: 14 * 0.004, most: PenLine.fullForce))
        let headBefore = landed.widths.first ?? 0
        landed.correct(id: 21, force: 0.2, most: PenLine.fullForce)
        let headAfter = landed.widths.first ?? 0
        note("a force made good late leaves the dot a line began with", headBefore > 1.4 && abs(headAfter - headBefore) < 0.05, "\(headBefore) to \(headAfter)")
        // A pencil slips sideways as it leaves the paper: those last places are not in the line.
        var hooked = PenLine(width: 1.42, sense: 0, steady: 0, spacing: 0.1)
        for step in 0..<40 {
            hooked.add(PenSample(point: CGPoint(x: 100, y: 100 + 0.3 * Double(step)), force: 0, time: Double(step) * 0.004))
        }
        for step in 0..<3 {
            hooked.add(PenSample(point: CGPoint(x: 100.3 + 0.3 * Double(step), y: 111.7), force: 0, time: Double(40 + step) * 0.004))
        }
        hooked.finish()
        var astray: CGFloat = 0
        for point in hooked.points { astray = max(astray, abs(point.x - 100)) }
        let foot = hooked.points.last?.y ?? 0
        note("the pencil's way off the paper is no part of the line", astray < 0.05 && foot > 111, "\(astray) astray, ends at \(foot)")
        // What is settled of a pointed line stays as it is while the line goes on.
        var pointy = PenLine(width: 1.42, sense: 0, steady: 0, spacing: 0.3, taper: 0.5)
        for step in 0..<12 {
            pointy.add(PenSample(point: CGPoint(x: 100 + 0.5 * Double(step), y: 100), force: 0, time: Double(step) * 0.004))
        }
        let early = Array(pointy.widths.prefix(pointy.settled))
        for step in 12..<60 {
            pointy.add(PenSample(point: CGPoint(x: 100 + 0.5 * Double(step), y: 100), force: 0, time: Double(step) * 0.004))
        }
        let head = pointy.widths.first ?? 9
        note(
            "the beginning of a pointed line is not drawn again as the line goes on",
            early.count > 4 && Array(pointy.widths.prefix(early.count)) == early && abs(head - 0.8875) < 0.01, "\(head)"
        )
        // A pen that rests where it landed leaves a dot of its full width, and lifting it changes nothing.
        var dot = PenLine(width: 1.42, sense: 0, steady: 0, spacing: 0.3, taper: 0.5)
        for step in 0..<25 {
            dot.add(PenSample(point: CGPoint(x: 100, y: 100), force: 0, time: Double(step) * 0.004))
        }
        let resting = dot.widths.first ?? 0
        dot.finish()
        let lifted = dot.widths.max() ?? 0
        note("a dot is as wide as the pen, and is so before the pen lifts", resting > 1.4 && abs(lifted - resting) < 0.001, "\(resting), \(lifted)")
    }

    // MARK: steadying

    private static func steadying() {
        // A slow line by a hand that shakes: twelve times a second, two points either way.
        func shaky(_ adaptive: Bool) -> CGFloat {
            var line = PenLine(width: 1.4, sense: 0, steady: 0.5, spacing: 0.3, adaptive: adaptive)
            for step in 0..<240 {
                let time = Double(step) / 240
                line.add(PenSample(point: CGPoint(x: 100 + 80 * time, y: 200 + 2 * sin(2 * Double.pi * 12 * time)), force: 0, time: time))
            }
            // (How far the line is from the way straight across, on the whole, past where it sets out.)
            let later = line.points.dropFirst(line.points.count / 4)
            let squares = later.reduce(CGFloat(0)) { $0 + ($1.y - 200) * ($1.y - 200) }
            return (squares / CGFloat(max(later.count, 1))).squareRoot()
        }
        let even = shaky(false), eased = shaky(true)
        note("a slow shaky line is steadied more than it was", eased < even * 0.97, String(format: "off by %.3f points, %.3f before", Double(eased), Double(even)))

        // A fast line: how far behind the pen its end is.
        func behind(_ adaptive: Bool) -> CGFloat {
            var line = PenLine(width: 1.4, sense: 0, steady: 0.5, spacing: 0.3, adaptive: adaptive)
            var pen: CGFloat = 100
            for step in 0..<48 {
                pen = 100 + 1500 * CGFloat(step) / 240
                line.add(PenSample(point: CGPoint(x: pen, y: 200), force: 0, time: Double(step) / 240))
            }
            return pen - (line.points.last?.x ?? pen)
        }
        let trailing = behind(false), following = behind(true)
        note("a fast line follows the pen more closely than it did", following < trailing * 0.5, String(format: "%.1f points behind, %.1f before", Double(following), Double(trailing)))
    }

    // MARK: draw and hold

    private static func holding() {
        var watch = HoldWatch()
        // A pen on the move is not held.
        for step in 0..<40 { watch.moved(to: CGPoint(x: Double(step) * 6, y: 100), at: Double(step) * 0.01) }
        note("a moving pen is not held", !watch.held(at: 0.41))
        // It comes to rest and stays within a few points of where it rested.
        for step in 0..<50 {
            watch.moved(to: CGPoint(x: 234 + 1.2 * sin(Double(step)), y: 100 + 1.1 * cos(Double(step) * 0.7)), at: 0.4 + Double(step) * 0.01)
        }
        note("a pen at rest is not held at once", !watch.held(at: 0.6))
        note("a pen at rest for long enough is held", watch.held(at: 0.4 + 0.46))
        // A move further than the slack begins the wait again.
        watch.moved(to: CGPoint(x: 242, y: 100), at: 0.9)
        note("a pen that moves on is not held", !watch.held(at: 1.2))
        note("until it has rested again", watch.held(at: 1.36))
    }

    private static func straightLines() {
        // A line drawn by a hand that is not quite steady.
        var line: [CGPoint] = []
        for step in 0...60 {
            let along = Double(step) / 60
            line.append(CGPoint(x: 50 + 300 * along, y: 200 + 14 * along + 2.5 * sin(along * 19)))
        }
        note("a shaky line is a line", Straighten.isLine(line), "bend \(Straighten.bend(line))")
        // A corner, an arc and a line gone over twice are not.
        var corner: [CGPoint] = []
        for step in 0...30 { corner.append(CGPoint(x: 50 + 5 * Double(step), y: 200)) }
        for step in 1...30 { corner.append(CGPoint(x: 200, y: 200 + 5 * Double(step))) }
        note("a corner is not a line", !Straighten.isLine(corner))
        let arc = (0...40).map { step -> CGPoint in
            let angle = Double.pi * Double(step) / 40
            return CGPoint(x: 200 - 100 * cos(angle), y: 300 - 100 * sin(angle))
        }
        note("an arc is not a line", !Straighten.isLine(arc))
        var twice: [CGPoint] = []
        for step in 0...40 { twice.append(CGPoint(x: 50 + 6 * Double(step), y: 200)) }
        for step in 0...39 { twice.append(CGPoint(x: 290 - 6 * Double(step), y: 201)) }
        twice.append(CGPoint(x: 300, y: 200))
        note("a line gone over twice is not a line", !Straighten.isLine(twice))

        // Ends are drawn to level, upright and the two directions between, within five degrees.
        func ended(_ degrees: Double) -> (snapped: Bool, degrees: CGFloat, length: CGFloat) {
            let turn = degrees * Double.pi / 180
            let from = CGPoint(x: 100, y: 100)
            let found = Straighten.end(from: from, to: CGPoint(x: 100 + 200 * cos(turn), y: 100 + 200 * sin(turn)))
            return (found.snapped, found.degrees, hypot(found.point.x - from.x, found.point.y - from.y))
        }
        for (asked, wanted) in [(3.0, 0.0), (-4.0, 0.0), (47.5, 45.0), (88.0, 90.0), (-93.0, -90.0), (176.5, 180.0), (-136.0, -135.0)] {
            let found = ended(asked)
            note("a line at \(asked) degrees lies at \(wanted)", found.snapped && abs(found.degrees - CGFloat(wanted)) < 0.001 && abs(found.length - 200) < 0.01, "\(found)")
        }
        for asked in [20.0, 60.0, -30.0, 6.0, 39.0] {
            let found = ended(asked)
            note("a line at \(asked) degrees stays where it is", !found.snapped && abs(found.degrees - CGFloat(asked)) < 0.001, "\(found)")
        }
    }
}
