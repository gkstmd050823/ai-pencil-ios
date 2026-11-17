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
}
