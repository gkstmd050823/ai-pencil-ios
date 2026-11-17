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
        DebugLog.write("check: done")
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
