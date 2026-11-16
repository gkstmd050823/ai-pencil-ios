import XCTest

/// Real touches on the page, which the launch arguments of the other pictures cannot make: a finger
/// writing, rubbing out and drawing in an iPad simulator on the build server. Every step leaves a picture
/// in the folder named by SHOTS, and the app leaves a line in its debug log; those are what is looked at.
/// The test itself fails only if the app cannot be driven at all.
///
/// Places are given in points of the sample's first page, measured from its top-left corner, and turned
/// into places on screen with where that page sits when the document opens fitted to the screen's width.
final class TouchTests: XCTestCase {
    private let app = XCUIApplication()
    /// Where the first page's corner is on screen, and how many screen points a page point takes.
    private let corner = CGPoint(x: 10, y: 159.3)
    private let zoom: CGFloat = 1.3576

    override func setUp() {
        continueAfterFailure = true
    }

    private func start(_ arguments: [String]) {
        app.terminate()
        app.launchArguments = ["-sample", "-fingerDraws", "YES"] + arguments
        app.launch()
        sleep(5)
    }

    private func place(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: corner.x + x * zoom, dy: corner.y + y * zoom))
    }

    private func drag(from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) {
        place(a.0, a.1).press(forDuration: 0.15, thenDragTo: place(b.0, b.1), withVelocity: .slow, thenHoldForDuration: 0.15)
        sleep(1)
    }

    private func shot(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SHOTS"] else { return }
        let file = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }

    func testTouches() {
        // The AI pen in a finger: a line under some words becomes a mark and a question.
        start(["-demoTool", "ai", "-apiBase", "http://127.0.0.1:8787"])
        drag(from: (60, 418), to: (300, 420))
        sleep(7)
        shot("30-touch-ai-mark")

        // The eraser across that mark takes it off the page; undo puts it back.
        start(["-demoTool", "eraser", "-demoEraserAuto", "NO", "-demoHighlighterOnly", "NO"])
        shot("31-touch-mark-before")
        drag(from: (180, 380), to: (180, 460))
        shot("31-touch-mark-erased")
        let undo = app.buttons["실행 취소"]
        if undo.waitForExistence(timeout: 3), undo.isEnabled {
            undo.tap()
            sleep(1)
        }
        shot("31-touch-mark-undone")

        // A pen line, and a highlighter line across it.
        start(["-demoTool", "pen"])
        drag(from: (60, 640), to: (320, 700))
        let highlighter = app.buttons["형광펜"]
        if highlighter.waitForExistence(timeout: 3) {
            highlighter.tap()
            sleep(1)
        }
        drag(from: (60, 700), to: (320, 640))
        shot("32-touch-pen-and-highlighter")

        // The eraser that only takes highlighter, set to be put down after use: the highlighter line goes,
        // the pen line stays, and the pen is back in hand.
        start(["-demoTool", "eraser", "-demoEraserAuto", "YES", "-demoHighlighterOnly", "YES"])
        drag(from: (190, 610), to: (190, 730))
        shot("33-touch-highlighter-only")

        // PencilKit's own eraser, put down after use: the pen line goes and the pen is back in hand.
        start(["-demoTool", "eraser", "-demoEraserAuto", "YES", "-demoHighlighterOnly", "NO"])
        drag(from: (190, 610), to: (190, 730))
        shot("34-touch-erase-then-pen")

        // A shape dragged out with a finger.
        start(["-demoTool", "shape", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (350, 620), to: (520, 720))
        shot("35-touch-shape")

        // The app's own pen: three lines one after another without a pause, then a look once it has paused.
        start(["-demoTool", "pen"])
        drag(from: (60, 760), to: (300, 772))
        place(60, 790).press(forDuration: 0.15, thenDragTo: place(300, 800), withVelocity: .fast, thenHoldForDuration: 0.05)
        place(60, 815).press(forDuration: 0.15, thenDragTo: place(300, 808), withVelocity: .fast, thenHoldForDuration: 0.05)
        shot("36-touch-own-pen-just-written")
        sleep(2)
        shot("36-touch-own-pen-settled")
        // Undo takes the last of them back.
        let undoPen = app.buttons["실행 취소"]
        if undoPen.waitForExistence(timeout: 3), undoPen.isEnabled {
            undoPen.tap()
            sleep(2)
        }
        shot("36-touch-own-pen-undone")

        // The same with PencilKit's pen, which the setting falls back to.
        start(["-demoTool", "pen", "-appPen", "NO"])
        drag(from: (330, 770), to: (540, 800))
        sleep(1)
        shot("37-touch-pencilkit-pen")
        app.terminate()
    }
}
