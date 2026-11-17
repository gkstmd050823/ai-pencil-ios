import CoreGraphics
import Foundation

/// Telling that a pen has come to rest at the end of a line, which is how a line is asked to be made
/// straight ("draw and hold").
///
/// Places are given in points of the screen, not of the page: a hand holds a pen as still zoomed in as
/// zoomed out, and what counts as holding still is the same few points of glass either way.
struct HoldWatch {
    /// How far the pen may wander and still count as held still, in points of the screen.
    var slack: CGFloat = 3.5
    /// How long it has to be held, in seconds.
    var time: TimeInterval = 0.45

    private var anchor: CGPoint?
    private var since: TimeInterval = 0

    init(slack: CGFloat = 3.5, time: TimeInterval = 0.45) {
        self.slack = slack
        self.time = time
    }

    /// The pen is at [point] at [now]. Away from where it rested, the wait begins again from here.
    mutating func moved(to point: CGPoint, at now: TimeInterval) {
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= slack { return }
        anchor = point
        since = now
    }

    /// Whether the pen has been held still long enough by [now].
    func held(at now: TimeInterval) -> Bool {
        anchor != nil && now - since >= time
    }
}

/// A line drawn by hand that was meant to be straight, and the straight line it was meant to be.
enum Straighten {
    /// A line shorter than this on screen is not made straight: a dot with a pause after it, the stroke
    /// of a letter.
    static let shortest: CGFloat = 20
    /// The directions a straight line is drawn to when it is near one, in degrees apart, and how near.
    static let step: CGFloat = 45
    static let reach: CGFloat = 5

    /// Whether the places a pen went through are a straight line as a hand draws one: nowhere further
    /// from the way straight between its ends than a sixteenth of its length, and not much longer than
    /// that way (a line gone over twice is not one).
    static func isLine(_ points: [CGPoint]) -> Bool {
        guard points.count > 1, let a = points.first, let b = points.last else { return false }
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord > 0.001 else { return false }
        var off: CGFloat = 0
        var along: CGFloat = 0
        var before = a
        for point in points {
            off = max(off, abs((point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x)) / chord)
            along += hypot(point.x - before.x, point.y - before.y)
            before = point
        }
        return off <= chord * 0.0625 && along <= chord * 1.25
    }

    /// How far the places are from the way straight between the first and the last, at most.
    static func bend(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1, let a = points.first, let b = points.last else { return 0 }
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord > 0.001 else { return 0 }
        return points.map { abs(($0.x - a.x) * (b.y - a.y) - ($0.y - a.y) * (b.x - a.x)) / chord }.max() ?? 0
    }

    /// Where a line from [from] ends when the pen is at [to]: at the same distance in the nearest of the
    /// directions it is drawn to, if that is within reach, and at the pen otherwise. With it, whether it
    /// was drawn to a direction, and the direction it lies in (degrees, 0 to the right, counted the way
    /// the screen's y grows).
    static func end(from: CGPoint, to: CGPoint) -> (point: CGPoint, snapped: Bool, degrees: CGFloat) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return (to, false, 0) }
        let degrees = atan2(dy, dx) * 180 / .pi
        let nearest = (degrees / step).rounded() * step
        guard abs(degrees - nearest) <= reach else { return (to, false, degrees) }
        let turn = nearest * .pi / 180
        return (CGPoint(x: from.x + length * cos(turn), y: from.y + length * sin(turn)), true, nearest)
    }

    /// How near, on screen, the end of a straight line has to come to the end of another to be put on it.
    static let joinReach: CGFloat = 12

    /// The one of [ends] that [point] is nearest to and no further from than [reach]; nil when none is.
    static func joined(_ point: CGPoint, to ends: [CGPoint], reach: CGFloat) -> CGPoint? {
        var best: CGPoint?
        var near = reach
        for end in ends {
            let off = hypot(end.x - point.x, end.y - point.y)
            if off <= near {
                near = off
                best = end
            }
        }
        return best
    }
}

/// A shape a hand drew and meant: one with corners, or a round one.
enum FoundShape: Equatable {
    /// Three, four or five corners, in the order they were drawn.
    case polygon([CGPoint])
    /// A circle or an oval: its middle, half its length and half its width, and how far it is turned (radians).
    case ellipse(center: CGPoint, a: CGFloat, b: CGFloat, turn: CGFloat)
}

/// Tells what shape a line drawn round to where it began was meant to be: a triangle, a rectangle (or any
/// shape of four or five corners), a circle or an oval. A line that is none of these is left as it was
/// drawn. (A shape of six corners or more is too near a circle to tell from one drawn by a shaky hand,
/// and is taken for a circle or an oval.)
///
/// Both kinds of shape are fitted and the better fit wins. The round one is fitted by where the drawn
/// places lie on the whole (their middle, and how far they spread which way); the cornered one by
/// finding the places where the line turns.
enum ShapeFinder {
    static func length(_ points: [CGPoint]) -> CGFloat {
        var along: CGFloat = 0
        for index in points.indices.dropFirst() {
            along += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return along
    }

    /// Whether a line comes back to where it began: its ends no further apart than a seventh of its length.
    static func isClosed(_ points: [CGPoint]) -> Bool {
        guard let first = points.first, let last = points.last else { return false }
        let along = length(points)
        return along > 0 && hypot(last.x - first.x, last.y - first.y) <= along * 0.15
    }

    /// [count] places evenly apart along the way through [points] and back to the first of them.
    static func ring(_ points: [CGPoint], count: Int = 72) -> [CGPoint] {
        guard points.count > 2, let first = points.first else { return points }
        let closed = points + [first]
        let whole = length(closed)
        guard whole > 0 else { return points }
        let step = whole / CGFloat(count)
        var out: [CGPoint] = [first]
        var owed = step
        for index in closed.indices.dropFirst() {
            var from = closed[index - 1]
            let to = closed[index]
            var left = hypot(to.x - from.x, to.y - from.y)
            while left >= owed, out.count < count {
                let share = owed / left
                from = CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share)
                out.append(from)
                left -= owed
                owed = step
            }
            owed -= left
        }
        return out
    }

    /// How far [point] is from the stretch between [a] and [b].
    static func distance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let square = dx * dx + dy * dy
        let along = square > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / square)) : 0
        return hypot(point.x - (a.x + along * dx), point.y - (a.y + along * dy))
    }

    /// The places of [points] (first and last among them) that a line through fewer places has to keep
    /// so as to pass no further than [slack] from any of the others.
    private static func turns(_ points: [CGPoint], slack: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var far: CGFloat = 0
        var at = 0
        for index in 1..<(points.count - 1) {
            let off = distance(points[index], from: first, to: last)
            if off > far {
                far = off
                at = index
            }
        }
        guard far > slack else { return [first, last] }
        return Array(turns(Array(points[...at]), slack: slack).dropLast()) + turns(Array(points[at...]), slack: slack)
    }

    static func find(_ drawn: [CGPoint]) -> FoundShape? {
        guard drawn.count > 8, isClosed(drawn) else { return nil }
        let round = ring(drawn)
        guard round.count > 16 else { return nil }
        let count = CGFloat(round.count)
        let middle = CGPoint(x: round.reduce(0) { $0 + $1.x } / count, y: round.reduce(0) { $0 + $1.y } / count)
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syy: CGFloat = 0
        for point in round {
            let x = point.x - middle.x, y = point.y - middle.y
            sxx += x * x
            sxy += x * y
            syy += y * y
        }
        sxx /= count
        sxy /= count
        syy /= count
        // (Places evenly apart round an oval spread half the square of its half-length along it, and half
        // the square of its half-width across.)
        let mean = (sxx + syy) / 2
        let swing = (((sxx - syy) / 2) * ((sxx - syy) / 2) + sxy * sxy).squareRoot()
        var a = (2 * (mean + swing)).squareRoot()
        var b = (2 * max(mean - swing, 0)).squareRoot()
        var turn = 0.5 * atan2(2 * sxy, sxx - syy)
        guard a > 1, b > 1 else { return nil }
        // The spread tells which way an oval lies. How long and how wide it is, is fitted to the places
        // themselves: places evenly apart along an oval lie thicker along its flat sides than evenly
        // round its middle, and the spread alone made a long oval a tenth shorter than it was drawn.
        var su4: CGFloat = 0, su2v2: CGFloat = 0, sv4: CGFloat = 0, su2: CGFloat = 0, sv2: CGFloat = 0
        for point in round {
            let x = point.x - middle.x, y = point.y - middle.y
            let u = x * cos(turn) + y * sin(turn), v = -x * sin(turn) + y * cos(turn)
            su4 += u * u * u * u
            su2v2 += u * u * v * v
            sv4 += v * v * v * v
            su2 += u * u
            sv2 += v * v
        }
        let weight = su4 * sv4 - su2v2 * su2v2
        if abs(weight) > 1e-9 {
            let along = (su2 * sv4 - sv2 * su2v2) / weight, across = (sv2 * su4 - su2 * su2v2) / weight
            if along > 0, across > 0 {
                a = 1 / along.squareRoot()
                b = 1 / across.squareRoot()
                if b > a {
                    swap(&a, &b)
                    turn += .pi / 2
                }
            }
        }
        let size = (a + b) / 2
        var roundOff: CGFloat = 0
        for point in round {
            let x = point.x - middle.x, y = point.y - middle.y
            let u = x * cos(turn) + y * sin(turn), v = -x * sin(turn) + y * cos(turn)
            roundOff += abs(((u / a) * (u / a) + (v / b) * (v / b)).squareRoot() - 1)
        }
        roundOff /= count

        // The corners: the ring is taken apart at the place furthest from its middle and the place
        // furthest from that one, and each half thinned to the places where it turns.
        var start = 0
        var far: CGFloat = 0
        for (index, point) in round.enumerated() {
            let out = hypot(point.x - middle.x, point.y - middle.y)
            if out > far {
                far = out
                start = index
            }
        }
        let turned = Array(round[start...] + round[..<start])
        var across = 0
        far = 0
        for (index, point) in turned.enumerated() {
            let out = hypot(point.x - turned[0].x, point.y - turned[0].y)
            if out > far {
                far = out
                across = index
            }
        }
        let slack = size * 0.16
        let firstHalf = turns(Array(turned[...across]), slack: slack)
        let secondHalf = turns(Array(turned[across...]) + [turned[0]], slack: slack)
        var corners = Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())
        // (Two corners close together are one.)
        var index = 0
        while corners.count > 2, index < corners.count {
            let after = (index + 1) % corners.count
            let next = corners[after]
            if hypot(next.x - corners[index].x, next.y - corners[index].y) < size * 0.35 {
                corners[index] = CGPoint(x: (corners[index].x + next.x) / 2, y: (corners[index].y + next.y) / 2)
                corners.remove(at: after)
                if after < index { index -= 1 }
            } else {
                index += 1
            }
        }
        var cornerOff = CGFloat.infinity
        if (3...5).contains(corners.count) {
            var sum: CGFloat = 0
            for point in round {
                var near = CGFloat.infinity
                for side in corners.indices {
                    near = min(near, distance(point, from: corners[side], to: corners[(side + 1) % corners.count]))
                }
                sum += near
            }
            cornerOff = sum / (count * size)
        }

        if cornerOff <= 0.09, cornerOff <= roundOff {
            return .polygon(corners.count == 4 ? squared(corners) : corners)
        }
        guard roundOff <= 0.13 else { return nil }
        // Nearly as wide as long, it is a circle; lying nearly level or upright, it is made to.
        if b / a >= 0.88 {
            a = size
            b = size
            turn = 0
        } else {
            let quarter = CGFloat.pi / 2
            let nearest = (turn / quarter).rounded() * quarter
            if abs(turn - nearest) <= 8 * .pi / 180 { turn = nearest }
        }
        return .ellipse(center: middle, a: a, b: b, turn: turn)
    }

    /// Four corners that are all nearly right angles are made a rectangle, and one that lies nearly
    /// level is made to lie level. Any other four corners stay where they are.
    static func squared(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        for index in 0..<4 {
            let before = corners[(index + 3) % 4], here = corners[index], after = corners[(index + 1) % 4]
            let one = atan2(before.y - here.y, before.x - here.x), other = atan2(after.y - here.y, after.x - here.x)
            var angle = abs(one - other) * 180 / .pi
            if angle > 180 { angle = 360 - angle }
            if abs(angle - 90) > 14 { return corners }
        }
        let middle = CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4)
        // Along the first side and the one opposite it, which runs the other way.
        let alongX = (corners[1].x - corners[0].x) + (corners[2].x - corners[3].x)
        let alongY = (corners[1].y - corners[0].y) + (corners[2].y - corners[3].y)
        var turn = atan2(alongY, alongX)
        let quarter = CGFloat.pi / 2
        let nearest = (turn / quarter).rounded() * quarter
        if abs(turn - nearest) <= 8 * .pi / 180 { turn = nearest }
        let wide = (hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y) + hypot(corners[2].x - corners[3].x, corners[2].y - corners[3].y)) / 2
        let tall = (hypot(corners[2].x - corners[1].x, corners[2].y - corners[1].y) + hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)) / 2
        // (Which side of the first side the shape lies on, as it was drawn.)
        let cross = (corners[1].x - corners[0].x) * (corners[2].y - corners[1].y) - (corners[1].y - corners[0].y) * (corners[2].x - corners[1].x)
        let side: CGFloat = cross >= 0 ? 1 : -1
        let ux = cos(turn), uy = sin(turn)
        let vx = -uy * side, vy = ux * side
        func corner(_ p: CGFloat, _ q: CGFloat) -> CGPoint {
            CGPoint(x: middle.x + p * wide / 2 * ux + q * tall / 2 * vx, y: middle.y + p * wide / 2 * uy + q * tall / 2 * vy)
        }
        return [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
    }

    /// What a shape is called in the app's notes.
    static func name(_ shape: FoundShape) -> String {
        switch shape {
        case .polygon(let corners):
            if corners.count == 3 { return "a triangle" }
            if corners.count == 4 {
                // (Sides that meet at right angles: the corner across is as far whichever way round.)
                let one = hypot(corners[2].x - corners[0].x, corners[2].y - corners[0].y)
                let other = hypot(corners[3].x - corners[1].x, corners[3].y - corners[1].y)
                let side = CGPoint(x: corners[1].x - corners[0].x, y: corners[1].y - corners[0].y)
                let next = CGPoint(x: corners[3].x - corners[0].x, y: corners[3].y - corners[0].y)
                let level: CGFloat = abs(side.x * next.x + side.y * next.y)
                let square: Bool = abs(one - other) < 0.01 && level < 0.01 * one
                return square ? "a rectangle" : "a shape of four corners"
            }
            return "a shape of \(corners.count) corners"
        case .ellipse(_, let a, let b, _):
            return a == b ? "a circle" : "an oval"
        }
    }

    /// The places along a shape's outline, a few page points apart, round to where it begins.
    static func outline(_ shape: FoundShape) -> [CGPoint] {
        switch shape {
        case .polygon(let corners):
            guard let first = corners.first else { return [] }
            return ShapeOutline.polyline(corners + [first])
        case .ellipse(let center, let a, let b, let turn):
            let steps = max(36, Int((a + b) * 0.6))
            var places: [CGPoint] = []
            for step in 0...steps {
                let angle: CGFloat = CGFloat(step) / CGFloat(steps) * 2 * CGFloat.pi
                let u: CGFloat = a * cos(angle), v: CGFloat = b * sin(angle)
                places.append(CGPoint(x: center.x + u * cos(turn) - v * sin(turn), y: center.y + u * sin(turn) + v * cos(turn)))
            }
            return places
        }
    }
}

/// Shapes as a hand that is not quite steady draws them, for the app's checks of itself and for the
/// build server to write with: places a few points apart, each a little off where it was meant to be.
enum HandDrawn {
    /// From corner to corner and back toward the first, stopping [short] of it (a share of the last side).
    static func walk(_ corners: [CGPoint], shake: CGFloat = 1.5, short: CGFloat = 0) -> [CGPoint] {
        var places: [CGPoint] = []
        var step = 0
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let count = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            let last = index < corners.count - 1 ? count : Int(CGFloat(count) * (1 - short))
            for part in 0..<last {
                let along = CGFloat(part) / CGFloat(count)
                let x: CGFloat = a.x + (b.x - a.x) * along + shake * sin(CGFloat(step) * 0.9)
                let y: CGFloat = a.y + (b.y - a.y) * along + shake * cos(CGFloat(step) * 1.3)
                places.append(CGPoint(x: x, y: y))
                step += 1
            }
        }
        return places
    }

    /// Round an oval of half-length [a] and half-width [b] turned by [degrees], and [over] of the way
    /// round again past where it began (or short of it, below nought).
    static func oval(center: CGPoint, a: CGFloat, b: CGFloat, degrees: CGFloat = 0, shake: CGFloat = 2, over: CGFloat = 0) -> [CGPoint] {
        let turn = degrees * .pi / 180
        let count = 90
        var places: [CGPoint] = []
        for step in 0...Int(CGFloat(count) * (1 + over)) {
            let angle: CGFloat = 2 * CGFloat.pi * CGFloat(step) / CGFloat(count)
            let u: CGFloat = a * cos(angle) + shake * sin(CGFloat(step) * 0.8)
            let v: CGFloat = b * sin(angle) + shake * cos(CGFloat(step) * 1.1)
            places.append(CGPoint(x: center.x + u * cos(turn) - v * sin(turn), y: center.y + u * sin(turn) + v * cos(turn)))
        }
        return places
    }
}
