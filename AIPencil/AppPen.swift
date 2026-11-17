import PencilKit
import UIKit
import UIKit.UIGestureRecognizerSubclass

// The app's own pen. PencilKit draws a line as it is written and takes no say in how: it cannot be asked
// to steady a shaky hand or to answer more or less to pressure. So for the pen, the highlighter and the AI
// pen the app takes the touches itself, works out the line (steadied, as thick as the pen pressed), and
// shows it as a plain filled shape while it is being written. When the pen lifts the line is handed to
// PencilKit as a stroke like any other, so the lasso, undo and the export all work on it as before; what
// is seen of it on the page from then on is the same shape, drawn by the app (InkPaint).

/// How wide lines come out. PencilKit does not draw a stroke as wide as its points say: its "monoline"
/// ink, which the app's own pen and the shape tool hand their lines over in, draws nothing for a point
/// size of 2 or less, and two points of line for every unit above that. (Measured on the build server:
/// straight lines of sizes 4, 8 and 12 came out 4, 12 and 20 points wide, on the canvas and in a picture
/// made of the drawing alike.) Lines are worked out in the width they are to be seen at, and turned into
/// PencilKit's sizes only when they are handed over.
enum InkWidth {
    private static let rise: CGFloat = 2
    private static let floor: CGFloat = 2

    /// The size to give a stroke's points for the line to come out [width] points wide.
    static func size(drawing width: CGFloat) -> CGFloat {
        floor + max(width, 0.05) / rise
    }

    /// How wide a stroke's point of this size is seen: the other way round. (A size of 2 or less, which
    /// PencilKit draws as next to nothing, is drawn as a hairline.)
    static func width(ofSize size: CGFloat) -> CGFloat {
        max(0.2, rise * (size - floor))
    }

    /// How wide a line was seen for a setting of the width slider that the pen had before 0.8.0; used
    /// to carry a saved setting over to the millimetres the pen is set in now. From 2.3 up it is what PencilKit's
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
    /// The most force the pencil can tell of (nought: not known, and taken to be an Apple Pencil's).
    var most: CGFloat = 0
    /// Set where the force is only the system's guess for now: the number under which the true force is
    /// told a moment later.
    var id: Int?
}

/// How a line's width answers to how hard the pen presses: so many times its ordinary width under no
/// pressure at all, so many at the pressure where it is widest, and how it bends in between. Each kind
/// of pen has its own.
struct PressureCurve: Equatable {
    var low: CGFloat
    var high: CGFloat
    /// Below 1 the line widens quickly under a light hand and slowly under a heavy one; above 1 the other way.
    var gamma: CGFloat
    /// The share of the pencil's full force at which the line is widest.
    var top: CGFloat = 0.72

    /// The fountain pen's. (It is the curve the pen had before the force was reckoned as a share of the
    /// pencil's full force: 0.35 + 0.65 x force^0.75, up to a force of 3, for a pencil whose full force is 25/6.)
    static let fountain = PressureCurve(low: 0.35, high: 0.35 + 0.65 * pow(3, 0.75), gamma: 0.75)
    /// The brush's: from a hair to nearly three times the width, and evenly.
    static let brush = PressureCurve(low: 0.1, high: 2.8, gamma: 1.05)

    /// How many times its ordinary width the line is at this share of the pencil's full force.
    func swell(_ share: CGFloat) -> CGFloat {
        low + (high - low) * pow(min(max(share, 0) / top, 1), gamma)
    }
}

/// A line being written: the places the pen went through, steadied, and a width for each.
///
/// A pen is heard from 240 times a second, a finger 60 or 120. Written at an ordinary speed that is a
/// place every five to ten pixels of the screen, and a line drawn straight from each place to the next
/// shows its corners on every curve. So the places heard of are only the knots of the line: between each
/// two the line follows a curve that runs smoothly through them (a Catmull-Rom spline), worked out into
/// points less than a pixel and a half apart. The stretch up to the newest knot cannot be given its
/// curve until the knot after it is known, so it is drawn straight for the moment and worked out again
/// when the next knot comes: [settled] says how many of the points will not change any more.
struct PenLine {
    /// The width of the line, in points as it is seen, where the pen presses as hard as an ordinary touch.
    let width: CGFloat
    /// How much pressure changes the width: 0 not at all, 1 all the way.
    let sense: CGFloat
    /// How far the line is steadied: 0 goes exactly where the pen goes, 1 trails it most smoothly.
    let steady: CGFloat
    /// Knots nearer than this to the one before are left out. It is given in page points for half a
    /// point of the screen: zoomed in, a letter is small on the page and large on the screen.
    let spacing: CGFloat
    /// How pointed the line's two ends are: 0 as wide as the rest of it, 1 down to a quarter of that.
    /// (A fountain pen's line comes to a point where the nib lands and where it lifts.)
    let taper: CGFloat
    /// How much the pen's pace changes the width, from 0 (not at all) to 1: a nib that moves slowly
    /// leaves more ink, one that moves fast less.
    let flow: CGFloat
    /// Screen points to a page point, for telling the pen's pace as the hand makes it.
    let zoom: CGFloat
    /// How the width answers to pressure.
    let curve: PressureCurve
    /// Whether the steadying eases off as the pen speeds up (it does; the other way is kept to check against).
    let adaptive: Bool

    private(set) var points: [CGPoint] = []
    private(set) var widths: [CGFloat] = []
    private(set) var times: [TimeInterval] = []
    /// How many of the points are as they will stay.
    private(set) var settled = 0

    private struct Knot {
        var point: CGPoint
        var width: CGFloat
        var time: TimeInterval
    }

    private var knots: [Knot] = []
    /// How many of the stretches between knots have been worked out for good.
    private var stretches = 0
    /// Where the steadied line has got to; the pen itself is a little ahead of it.
    private var held: CGPoint?
    private var heldWidth: CGFloat = 0
    private var last: PenSample?
    private var began: TimeInterval = 0
    /// The pen's pace in screen points a second, evened out over the last few places.
    private var pace: CGFloat?
    /// How far the line has gone from where it began, knot to knot, in page points.
    private var run: CGFloat = 0
    /// How hard the pen presses, as a share of its full force, evened out.
    private var press: CGFloat?

    /// A place the pen was heard from, with what the line's width was reckoned from there: kept for the
    /// last few places, so that a force the pencil makes good a moment later can be worked in.
    private struct Heard {
        var id: Int?
        var share: CGFloat?
        var quick: CGFloat
        var step: TimeInterval
        var elapsed: TimeInterval
        /// The pressure and the width as they stood before this place.
        var press: CGFloat?
        var width: CGFloat
        var first: Bool
        /// The knot this place became, if it became one, and how far along the line that was.
        var knot: Int?
        var run: CGFloat = 0
    }

    private var heard: [Heard] = []

    /// An Apple Pencil's full force, as UIKit tells it.
    static let fullForce: CGFloat = 25.0 / 6.0

    /// The share of its width a pointed end comes down to, and how far from the end it is back to full width.
    private var tip: CGFloat { 1 - 0.75 * taper }
    private var tipReach: CGFloat { max(0.6, width * (1.2 + 2.8 * taper)) }

    /// How much of its width the line has at [distance] from one of its ends.
    private func pointed(_ distance: CGFloat) -> CGFloat {
        guard taper > 0 else { return 1 }
        let along = min(1, max(0, distance / tipReach))
        return tip + (1 - tip) * along * (2 - along)
    }

    /// The longest the line trails the pen at full steadying, in seconds.
    private static let trail = 0.085

    init(
        width: CGFloat, sense: CGFloat, steady: CGFloat, spacing: CGFloat = 0.6, taper: CGFloat = 0, flow: CGFloat = 0, zoom: CGFloat = 1,
        curve: PressureCurve = .fountain, adaptive: Bool = true
    ) {
        self.curve = curve
        self.adaptive = adaptive
        self.width = width
        self.sense = min(max(sense, 0), 1)
        self.steady = min(max(steady, 0), 1)
        self.spacing = min(max(spacing, 0.05), 1)
        self.taper = min(max(taper, 0), 1)
        self.flow = min(max(flow, 0), 1)
        self.zoom = max(zoom, 0.05)
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
        // The pen's pace, in points of the screen a second, evened out over the last few places.
        if let before = last {
            let speed = hypot(sample.point.x - before.point.x, sample.point.y - before.point.y) * zoom / CGFloat(step)
            pace = pace.map { $0 + (speed - $0) * 0.15 } ?? speed
        }
        // Slow, the line is a little wider than it is set; fast, narrower.
        var quick: CGFloat = 1
        if flow > 0, let even = pace {
            let fast = min(1, max(0, (even - 150) / 1350))
            quick = 1 + flow * (0.14 - 0.5 * fast * fast * (3 - 2 * fast))
        }
        last = sample
        // The line goes a share of the way to the pen at each sample, the share shrinking with steadying:
        // a quick wobble of the hand is over before the line has followed it. How long the line trails
        // depends on the pen's pace: a slow pen is where a hand shakes, and is steadied most; a fast one
        // is on its way somewhere, and is followed closely, so that the line does not hang back behind
        // it. (Until 0.12.3 it trailed the same at any pace.)
        let ease = adaptive ? 1.6 / (1 + Double(pace ?? 0) / 300) : 1
        let reach = Double(steady) * Self.trail * ease
        let share = reach <= 0 ? 1 : CGFloat(1 - exp(-step / reach))
        let place: CGPoint
        if let held {
            place = CGPoint(x: held.x + (sample.point.x - held.x) * share, y: held.y + (sample.point.y - held.y) * share)
        } else {
            place = sample.point
        }
        held = place
        // How hard the pen presses, as a share of the most it can tell.
        let pressed: CGFloat? = sample.force > 0 ? sample.force / (sample.most > 0 ? sample.most : Self.fullForce) : nil
        var record = Heard(
            id: sample.id, share: pressed, quick: quick, step: step, elapsed: sample.time - began,
            press: press, width: heldWidth, first: knots.isEmpty
        )
        var pressure = press
        heldWidth = widened(record, press: &pressure, held: heldWidth)
        press = pressure
        let before = knots.count
        knot(place, heldWidth, time: sample.time)
        if knots.count > before {
            record.knot = knots.count - 1
            record.run = run
        }
        heard.append(record)
        if heard.count > 48 { heard.removeFirst(heard.count - 48) }
    }

    /// The width the line has after a place of the pen, from the width it had before it. The pressure is
    /// evened out first: a pencil's force jumps about from one telling to the next, and in the first
    /// moments of a line, while the pencil is still landing, it jumps most and is evened out most.
    private func widened(_ place: Heard, press: inout CGFloat?, held: CGFloat) -> CGFloat {
        var squeeze: CGFloat = 1
        if let share = place.share {
            let lag = place.elapsed < 0.04 ? 0.03 : 0.006
            let even = press.map { $0 + (share - $0) * CGFloat(1 - exp(-place.step / lag)) } ?? share
            press = even
            squeeze = curve.swell(even)
        }
        let wanted = max(0.25, width * (1 + sense * (squeeze - 1)) * place.quick)
        return place.first ? wanted : held + (wanted - held) * 0.35
    }

    /// The pencil has made good a force it had only guessed at: the place it told of under [id] was
    /// pressed this hard. The width is reckoned again from that place on. What has changed of the line
    /// is the part that is not settled yet; a knot that is settled stays as it is, however late the word
    /// of its true force comes. True when the line has changed.
    @discardableResult
    mutating func correct(id: Int, force: CGFloat, most: CGFloat = 0) -> Bool {
        guard force > 0, let at = heard.lastIndex(where: { $0.id == id }) else { return false }
        heard[at].share = force / (most > 0 ? most : Self.fullForce)
        heard[at].id = nil
        var pressure = heard[at].press
        var held = heard[at].width
        var changed = false
        for index in at..<heard.count {
            heard[index].press = pressure
            heard[index].width = held
            let place = heard[index]
            held = widened(place, press: &pressure, held: held)
            guard let knot = place.knot, knot < knots.count else { continue }
            let wide = max(0.2, held * pointed(place.run))
            if knot == 0, stretches == 0 {
                knots[0].width = wide
                if !widths.isEmpty { widths[0] = wide }
                changed = true
            } else if knot > stretches {
                knots[knot].width = wide
                changed = true
            }
        }
        press = pressure
        heldWidth = held
        if changed { work(toTheEnd: false) }
        return changed
    }

    private mutating func knot(_ place: CGPoint, _ size: CGFloat, time: TimeInterval, always: Bool = false) {
        if let end = knots.last, !always, hypot(place.x - end.point.x, place.y - end.point.y) < spacing { return }
        if let end = knots.last { run += hypot(place.x - end.point.x, place.y - end.point.y) }
        // (Where the line begins it comes up from a point, if it is a line with pointed ends.)
        knots.append(Knot(point: place, width: max(0.2, size * pointed(run)), time: max(0, time - began)))
        work(toTheEnd: false)
    }

    /// The points of the stretch from knot [index] to the next, the first of them left out.
    private mutating func lay(stretch index: Int) {
        let count = knots.count
        let a = knots[max(index - 1, 0)], b = knots[index], c = knots[index + 1], d = knots[min(index + 2, count - 1)]
        let length = hypot(c.point.x - b.point.x, c.point.y - b.point.y)
        // The way the line is heading at each end of the stretch: toward the knot after from the knot
        // before, and no faster than the stretch is long, so that an uneven pair of neighbours cannot
        // swing the curve out past them.
        func heading(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
            var x = (to.x - from.x) / 2, y = (to.y - from.y) / 2
            let speed = hypot(x, y)
            if speed > length * 1.5, speed > 0 {
                x *= length * 1.5 / speed
                y *= length * 1.5 / speed
            }
            return CGPoint(x: x, y: y)
        }
        let out = heading(a.point, c.point), into = heading(b.point, d.point)
        let pieces = max(1, min(64, Int((length / (spacing * 1.5)).rounded(.up))))
        for piece in 1...pieces {
            let t = CGFloat(piece) / CGFloat(pieces)
            let t2 = t * t, t3 = t2 * t
            let h1 = 2 * t3 - 3 * t2 + 1, h2 = t3 - 2 * t2 + t, h3 = -2 * t3 + 3 * t2, h4 = t3 - t2
            points.append(CGPoint(
                x: h1 * b.point.x + h2 * out.x + h3 * c.point.x + h4 * into.x,
                y: h1 * b.point.y + h2 * out.y + h3 * c.point.y + h4 * into.y
            ))
            widths.append(b.width + (c.width - b.width) * t)
            times.append(b.time + (c.time - b.time) * Double(t))
        }
    }

    /// Works the line out from where it is settled: every stretch that has a knot after it (all of them,
    /// [toTheEnd]) is settled as its curve, and what is left is laid as it stands for now.
    private mutating func work(toTheEnd: Bool) {
        let count = knots.count
        guard count > 0 else { return }
        points.removeSubrange(settled...)
        widths.removeSubrange(settled...)
        times.removeSubrange(settled...)
        if settled == 0 {
            points.append(knots[0].point)
            widths.append(knots[0].width)
            times.append(knots[0].time)
            settled = 1
        }
        while stretches < count - 1, toTheEnd || stretches + 2 <= count - 1 {
            lay(stretch: stretches)
            stretches += 1
            settled = points.count
        }
        var rest = stretches
        while rest < count - 1 {
            lay(stretch: rest)
            rest += 1
        }
    }

    /// The pen lifted. A steadied line is still on its way to where the pen left the page; this takes it
    /// there, so that the line ends where the hand ended it, and settles the whole of it.
    mutating func finish() {
        guard let last, let held else { return }
        let gap = hypot(last.point.x - held.x, last.point.y - held.y)
        if gap > 0.2 {
            let steps = max(1, min(10, Int(gap / 1.5)))
            for step in 1...steps {
                let part = CGFloat(step) / CGFloat(steps)
                let place = CGPoint(x: held.x + (last.point.x - held.x) * part, y: held.y + (last.point.y - held.y) * part)
                knot(place, heldWidth, time: last.time, always: step == steps)
            }
            self.held = last.point
        }
        // A touch that went nowhere is a dot: a second knot right beside the first makes it a line.
        if knots.count == 1 {
            knot(CGPoint(x: knots[0].point.x + 0.1, y: knots[0].point.y), knots[0].width, time: last.time, always: true)
        }
        work(toTheEnd: true)
        guard taper > 0, points.count > 1 else { return }
        if run < tipReach {
            // Too short to have ends (a dot, the stroke of a comma): as wide as it is, all of it.
            for index in widths.indices { widths[index] = max(widths[index], heldWidth) }
            return
        }
        // Where the line ends it goes down to a point as it came up from one.
        var along: CGFloat = 0
        var index = points.count - 1
        while index >= 0, along < tipReach {
            widths[index] = max(0.2, widths[index] * pointed(along))
            if index > 0 { along += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) }
            index -= 1
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

    /// The line from point [from] up to (not including) point [to] as a shape to fill, fine enough for a
    /// screen that shows [fineness] pixels to a page point.
    func shape(from: Int, to: Int? = nil, fineness: CGFloat) -> CGPath {
        InkPaint.shape(points: points, widths: widths, from: from, to: to ?? points.count, fineness: fineness)
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
    /// Called when the pencil makes good a force it had guessed at: the number it was told under, the
    /// force, and the most the pencil can tell.
    var onCorrect: ((Int, CGFloat, CGFloat) -> Void)?
    private weak var followed: UITouch?
    private var origin = CGPoint.zero
    private var since: TimeInterval = 0
    /// The force the pencil last told of in the line being written.
    private var lastForce: CGFloat = 0

    /// A pencil that has just left the page tells a force of nought, and so at times does one that has
    /// only just landed. Nought is what a finger tells, which has no force to tell and is written at the
    /// ordinary width: handed on as it was, the end of a line written lightly swelled to that width, a
    /// lump on the end of every stroke with the pen set to answer much to pressure. The force last told
    /// stands in for it; where none has been told yet, a light one.
    private func samples(_ touches: [UITouch], told: Bool = true) -> [PenSample] {
        touches.map { touch in
            var force: CGFloat = 0
            var id: Int?
            if touch.type == .pencil {
                if touch.force > 0, told { lastForce = touch.force }
                force = touch.force > 0 ? touch.force : (lastForce > 0 ? lastForce : 0.15)
                // (A force the system has only guessed at so far is told again, for good, under this number.)
                if told, touch.estimatedPropertiesExpectingUpdates.contains(.force) { id = touch.estimationUpdateIndex?.intValue }
            }
            return PenSample(point: touch.preciseLocation(in: view), force: force, time: touch.timestamp, most: touch.maximumPossibleForce, id: id)
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
        lastForce = 0
        onDraw?(samples([touch]), [])
        if touch.type == .pencil { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        onDraw?(samples(event.coalescedTouches(for: touch) ?? [touch]), samples(event.predictedTouches(for: touch) ?? [], told: false))
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

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches where touch.type == .pencil {
            // (Only once the force is final: until then more word of it is on its way.)
            guard let id = touch.estimationUpdateIndex?.intValue, touch.force > 0,
                  !touch.estimatedPropertiesExpectingUpdates.contains(.force) else { continue }
            onCorrect?(id, touch.force, touch.maximumPossibleForce)
        }
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
