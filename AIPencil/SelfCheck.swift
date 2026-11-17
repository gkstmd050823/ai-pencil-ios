import CoreGraphics
import Foundation

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
        DebugLog.write("check: done")
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
        let corner = (0...30).map { CGPoint(x: 50 + 5 * Double($0), y: 200) } + (1...30).map { CGPoint(x: 200, y: 200 + 5 * Double($0)) }
        note("a corner is not a line", !Straighten.isLine(corner))
        let arc = (0...40).map { step -> CGPoint in
            let angle = Double.pi * Double(step) / 40
            return CGPoint(x: 200 - 100 * cos(angle), y: 300 - 100 * sin(angle))
        }
        note("an arc is not a line", !Straighten.isLine(arc))
        let twice = (0...40).map { CGPoint(x: 50 + 6 * Double($0), y: 200) } + (0...39).map { CGPoint(x: 290 - 6 * Double($0), y: 201) } + [CGPoint(x: 300, y: 200)]
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
