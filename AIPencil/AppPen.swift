import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

// The app's own pen. PencilKit draws a line as it is written and takes no say in how: it cannot be asked
// to steady a shaky hand or to answer more or less to pressure. So for the pen the app takes the touches
// itself, works out the line (steadied, as thick as the pen pressed), and shows it as a plain filled shape
// while it is being written. When the pen lifts the line is handed to PencilKit as a stroke like any
// other, so the eraser, the lasso, undo and the export all work on it as before.

/// How wide lines come out. PencilKit does not draw a stroke as wide as its points say: its "monoline"
/// ink, which the app's own pen and the shape tool hand their lines over in, draws next to nothing for a
/// point size of 2 or less, and 1.78 points of line for every unit above that. (Measured on the build
/// server: straight lines of sizes 2, 2.6, 4, 8 and 12 came out 0.2, 1.1, 3.6, 10.7 and 17.8 points wide,
/// on the canvas and in a picture made of the drawing alike.) Lines are worked out in the width they are
/// to be seen at, and turned into PencilKit's sizes only when they are handed over.
enum InkWidth {
    private static let rise: CGFloat = 1.78
    private static let floor: CGFloat = 1.99

    /// The size to give a stroke's points for the line to come out [width] points wide.
    static func size(drawing width: CGFloat) -> CGFloat {
        floor + max(width, 0.05) / rise
    }

    /// How wide a line is seen for a setting of the width slider. From 2.3 up it is what PencilKit's
    /// monoline pen draws at that setting; below, where PencilKit would draw nearly nothing, it runs
    /// evenly down to a fine line that can still be seen.
    static func seen(setting: CGFloat) -> CGFloat {
        if setting >= 2.3 { return rise * (setting - floor) }
        return 0.3 + (max(setting, 0.6) - 0.6) * (rise * (2.3 - floor) - 0.3) / (2.3 - 0.6)
    }
}

/// One place the pen was at: where on the page, how hard it pressed, and when.
struct PenSample {
    var point: CGPoint
    /// As UIKit gives it, where 1 is an ordinary touch. Zero when the touch has no force to tell (a finger).
    var force: CGFloat
    var time: TimeInterval
}

/// A line being written: the places the pen went through, steadied, and a width for each.
struct PenLine {
    /// The width of the line, in points as it is seen, where the pen presses as hard as an ordinary touch.
    let width: CGFloat
    /// How much pressure changes the width: 0 not at all, 1 all the way.
    let sense: CGFloat
    /// How far the line is steadied: 0 goes exactly where the pen goes, 1 trails it most smoothly.
    let steady: CGFloat

    private(set) var points: [CGPoint] = []
    private(set) var widths: [CGFloat] = []
    private(set) var forces: [CGFloat] = []
    private(set) var times: [TimeInterval] = []
    /// Where the steadied line has got to; the pen itself is a little ahead of it.
    private var held: CGPoint?
    private var heldWidth: CGFloat = 0
    private var last: PenSample?
    private var began: TimeInterval = 0

    /// The longest the line trails the pen at full steadying, in seconds.
    private static let trail = 0.085
    /// Points nearer than this to the one before are left out; the line gains nothing from them.
    private static let spacing: CGFloat = 0.6

    init(width: CGFloat, sense: CGFloat, steady: CGFloat) {
        self.width = width
        self.sense = min(max(sense, 0), 1)
        self.steady = min(max(steady, 0), 1)
    }

    /// How many times the ordinary width a line is at this force: thinner for a light hand, up to nearly
    /// twice as thick for a heavy one. A touch without force writes the ordinary width.
    static func swell(_ force: CGFloat) -> CGFloat {
        guard force > 0 else { return 1 }
        return 0.35 + 0.65 * pow(min(force, 3), 0.75)
    }

    mutating func add(_ sample: PenSample) {
        let step = last.map { max(0.0005, sample.time - $0.time) } ?? 0.004
        if last == nil { began = sample.time }
        last = sample
        // The line goes a share of the way to the pen at each sample, the share shrinking with steadying:
        // a quick wobble of the hand is over before the line has followed it.
        let reach = Double(steady) * Self.trail
        let share = reach <= 0 ? 1 : CGFloat(1 - exp(-step / reach))
        let place: CGPoint
        if let held {
            place = CGPoint(x: held.x + (sample.point.x - held.x) * share, y: held.y + (sample.point.y - held.y) * share)
        } else {
            place = sample.point
        }
        held = place
        let wanted = max(0.25, width * (1 + sense * (Self.swell(sample.force) - 1)))
        heldWidth = points.isEmpty ? wanted : heldWidth + (wanted - heldWidth) * 0.35
        put(place, heldWidth, force: sample.force, time: sample.time)
    }

    private mutating func put(_ place: CGPoint, _ size: CGFloat, force: CGFloat, time: TimeInterval, always: Bool = false) {
        if let end = points.last, !always, hypot(place.x - end.x, place.y - end.y) < Self.spacing { return }
        points.append(place)
        widths.append(size)
        forces.append(force)
        times.append(max(0, time - began))
    }

    /// The pen lifted. A steadied line is still on its way to where the pen left the page; this takes it
    /// there, so that the line ends where the hand ended it.
    mutating func finish() {
        guard let last, let held else { return }
        let gap = hypot(last.point.x - held.x, last.point.y - held.y)
        if gap > 0.2 {
            let steps = max(1, min(10, Int(gap / 1.5)))
            for step in 1...steps {
                let part = CGFloat(step) / CGFloat(steps)
                let place = CGPoint(x: held.x + (last.point.x - held.x) * part, y: held.y + (last.point.y - held.y) * part)
                put(place, heldWidth, force: last.force, time: last.time, always: step == steps)
            }
            self.held = last.point
        }
        // A touch that went nowhere is a dot: a second point right beside the first makes it a line.
        if points.count == 1 {
            put(CGPoint(x: points[0].x + 0.1, y: points[0].y), widths[0], force: forces[0], time: last.time, always: true)
        }
    }

    /// The line as a PencilKit stroke. The ink is PencilKit's "monoline", which draws every point as wide
    /// as the point says and adds nothing of its own. (Its "pen" ink thins and fades a line toward its
    /// ends whatever widths it is given, so a line handed over in it changed its look as the pen lifted.)
    func stroke(color: UIColor, ink: PKInkingTool.InkType = .monoline) -> PKStroke? {
        guard points.count > 1 else { return nil }
        var control: [PKStrokePoint] = []
        control.reserveCapacity(points.count)
        for index in points.indices {
            let size = InkWidth.size(drawing: widths[index])
            control.append(PKStrokePoint(
                location: points[index], timeOffset: times[index], size: CGSize(width: size, height: size),
                opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
            ))
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: control, creationDate: Date()))
    }

    /// The line from point [from] onward as a shape to fill: a disc at every point and a band between each
    /// two. Every piece turns the same way round, so that where pieces overlap the filling does not cancel.
    func shape(from: Int) -> CGPath {
        let path = CGMutablePath()
        guard !points.isEmpty else { return path }
        let first = max(0, min(from, points.count - 1))
        for index in first..<points.count {
            let here = points[index]
            let radius = widths[index] / 2
            path.addArc(center: here, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
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
}

/// Follows a pen, or a writing finger, across the page for the app's own pen.
///
/// A pen claims its touch at once, so that the page does not scroll under it. A finger claims it once it
/// has moved a little or stayed a moment: until then a second finger may still land, and two fingers
/// scroll and zoom the page.
final class PenGesture: UIGestureRecognizer {
    /// Called with the places the touch has been since the last call, and the places it is expected to be
    /// next (which are only for showing, and are not part of the line).
    var onDraw: (([PenSample], [PenSample]) -> Void)?
    /// Called when the touch is over: true if the line is to be kept.
    var onDone: ((Bool) -> Void)?
    private weak var followed: UITouch?
    private var origin = CGPoint.zero
    private var since: TimeInterval = 0

    private func samples(_ touches: [UITouch]) -> [PenSample] {
        touches.map { touch in
            PenSample(point: touch.preciseLocation(in: view), force: touch.type == .pencil ? touch.force : 0, time: touch.timestamp)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = followed {
            if state == .possible, !touches.contains(touch) {
                // A second finger before the first had started a line: they are scrolling or zooming.
                followed = nil
                onDone?(false)
                state = .failed
            } else {
                for other in touches where other !== touch { ignore(other, for: event) }
            }
            return
        }
        guard let touch = touches.first else { return }
        followed = touch
        origin = touch.location(in: view)
        since = touch.timestamp
        onDraw?(samples([touch]), [])
        if touch.type == .pencil { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        onDraw?(samples(event.coalescedTouches(for: touch) ?? [touch]), samples(event.predictedTouches(for: touch) ?? []))
        if state == .possible {
            let here = touch.location(in: view)
            if hypot(here.x - origin.x, here.y - origin.y) > 5 || touch.timestamp - since > 0.15 { state = .began }
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        onDraw?(samples([touch]), [])
        followed = nil
        onDone?(true)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        followed = nil
        onDone?(false)
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        if followed != nil {
            // Stopped from outside (the tool was changed under the pen, say): the line is let go.
            followed = nil
            onDone?(false)
        }
    }
}
