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
    private let corner = CGPoint(x: 10, y: 195.3)
    private let zoom: CGFloat = 1.3576

    override func setUp() {
        continueAfterFailure = true
    }

    private func start(_ arguments: [String], fingersWrite: Bool = true) {
        app.terminate()
        app.launchArguments = ["-sample", "-fingerDraws", fingersWrite ? "YES" : "NO"] + arguments
        app.launch()
        sleep(5)
    }

    /// A drag between two places of the screen, in points (for a page that is zoomed in, where places
    /// of the page are not where they are when it fits the screen).
    private func screenDrag(from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) {
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: a.0, dy: a.1))
            .press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: b.0, dy: b.1)), withVelocity: .slow, thenHoldForDuration: 0.15)
        sleep(1)
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

        // The eraser that takes whole lines, put down after use: the pen line goes and the pen is back in hand.
        start(["-demoTool", "eraser", "-demoEraserAuto", "YES", "-demoHighlighterOnly", "NO"])
        drag(from: (190, 610), to: (190, 730))
        shot("34-touch-erase-then-pen")

        // A shape dragged out with a finger.
        start(["-demoTool", "shape", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (350, 620), to: (520, 720))
        shot("35-touch-shape")

        // The app's own pen, on the blank page added earlier: three lines one after another without a
        // pause, then a look once it has paused.
        start(["-demoTool", "pen", "-demoPage", "2", "-demoPenKind", "fountain"])
        drag(from: (60, 200), to: (300, 212))
        place(60, 240).press(forDuration: 0.15, thenDragTo: place(300, 250), withVelocity: .fast, thenHoldForDuration: 0.05)
        place(60, 285).press(forDuration: 0.15, thenDragTo: place(300, 278), withVelocity: .fast, thenHoldForDuration: 0.05)
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

        // The pencil, which is PencilKit's: while it is in hand the canvas shows.
        start(["-demoTool", "pen", "-demoPage", "2", "-demoPenKind", "pencil"])
        drag(from: (330, 380), to: (540, 410))
        shot("37-touch-pencil-just-written")
        sleep(3)
        shot("37-touch-pencil-settled")

        // The highlighter over print, twice over the same words and once across: the words stay as dark
        // as they were, and where the lines cross it is no darker than one line.
        start(["-demoTool", "highlighter", "-demoHighlighterAuto", "NO"])
        drag(from: (40, 163), to: (330, 163))
        drag(from: (60, 166), to: (300, 160))
        drag(from: (150, 140), to: (210, 200))
        shot("42-touch-highlighter-over-print-just-written")
        sleep(2)
        shot("42-touch-highlighter-over-print")

        // Zoomed in as far as the page view goes, the canvas lies over the part of the page in view only,
        // and is as fine as the screen. A line written there has to land under the finger.
        start(["-demoTool", "pen", "-demoPage", "2", "-demoZoom", "3.7", "-demoPenKind", "fountain"])
        screenDrag(from: (150, 500), to: (650, 560))
        shot("39-zoom-pen-just-written")
        sleep(2)
        shot("39-zoom-pen-settled")

        // With fingers left to scroll, a finger dragged up the page scrolls it, canvas and all.
        start(["-demoTool", "pen", "-demoPage", "2", "-demoZoom", "3.7"], fingersWrite: false)
        shot("39-zoom-before-scroll")
        screenDrag(from: (400, 800), to: (400, 650))
        shot("39-zoom-after-scroll")
        // And dragged aslant it goes aslant: across and up the page at once.
        screenDrag(from: (560, 760), to: (360, 560))
        shot("43-zoom-after-slanted-scroll")

        // The eraser rubs the line out where it is seen.
        start(["-demoTool", "eraser", "-demoPage", "2", "-demoZoom", "3.7", "-demoEraserKind", "stroke", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        screenDrag(from: (400, 440), to: (400, 620))
        shot("39-zoom-erased")

        // The pen once more, zoomed in, at 0.8 mm.
        start(["-demoTool", "pen", "-demoPage", "2", "-demoZoom", "3.7", "-demoPenSize", "0.8"])
        screenDrag(from: (150, 700), to: (650, 740))
        shot("39-zoom-own-pen-just-written")
        sleep(2)
        shot("39-zoom-own-pen-settled")

        // How much the eraser that rubs out part of a line takes at a width of 40, on a page full of
        // lines: fitted to the screen, and zoomed in. (The ring that shows where it rubs is drawn to these.)
        start(["-demoTool", "eraser", "-demoPage", "4", "-demoDense", "400", "-demoEraserKind", "part", "-demoEraserWidth", "40", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (80, 300), to: (500, 300))
        shot("40-part-eraser-fitted")
        start(["-demoTool", "eraser", "-demoPage", "4", "-demoZoom", "2.1", "-demoEraserKind", "part", "-demoEraserWidth", "40", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        screenDrag(from: (150, 600), to: (650, 600))
        shot("40-part-eraser-zoomed")

        // The same on a solid block of ink, where the width of what is rubbed out can be read off: one
        // swath at a width of 40 and one at 16, page fitted; then one at 40, zoomed in.
        start(["-demoTool", "eraser", "-demoPage", "5", "-demoBlock", "-demoEraserKind", "part", "-demoEraserWidth", "40", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (60, 140), to: (540, 140))
        start(["-demoTool", "eraser", "-demoPage", "5", "-demoEraserKind", "part", "-demoEraserWidth", "16", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (60, 232), to: (540, 232))
        shot("41-part-eraser-swaths-fitted")
        start(["-demoTool", "eraser", "-demoPage", "5", "-demoZoom", "2.1", "-demoEraserKind", "part", "-demoEraserWidth", "40", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        shot("41-part-eraser-zoomed-before")
        screenDrag(from: (260, 760), to: (780, 760))
        shot("41-part-eraser-zoomed-after")

        // The eraser that takes whole lines, at two sizes, on the page full of lines: a large one takes
        // every line its ring touches, a small one only what it runs over.
        start(["-demoTool", "eraser", "-demoPage", "4", "-demoEraserKind", "stroke", "-demoEraserWidth", "48", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (60, 420), to: (540, 420))
        shot("44-line-eraser-large")
        start(["-demoTool", "eraser", "-demoPage", "4", "-demoEraserKind", "stroke", "-demoEraserWidth", "8", "-demoHighlighterOnly", "NO", "-demoEraserAuto", "NO"])
        drag(from: (60, 540), to: (540, 540))
        shot("44-line-eraser-small")
        let undoRub = app.buttons["실행 취소"]
        if undoRub.waitForExistence(timeout: 3), undoRub.isEnabled {
            undoRub.tap()
            sleep(2)
        }
        shot("44-line-eraser-undone")

        // The tabs: another document's tab shows that document, the first one's brings it back, and a
        // tab's cross closes it.
        start(["-demoTool", "pen"])
        let other = app.buttons["tricky 탭"]
        if other.waitForExistence(timeout: 3) {
            other.tap()
            sleep(4)
        }
        shot("46-tab-other-document")
        let back = app.buttons["샘플 탭"]
        if back.waitForExistence(timeout: 3) {
            back.tap()
            sleep(4)
        }
        shot("46-tab-back")
        let close = app.buttons["tricky 탭 닫기"]
        if close.waitForExistence(timeout: 3) {
            close.tap()
            sleep(2)
        }
        shot("46-tab-closed")

        // Reading only: a finger does not write, whatever tool is in hand and whatever the setting for
        // writing with fingers; it scrolls the page.
        start(["-demoTool", "pen", "-readOnly", "YES"])
        drag(from: (300, 420), to: (300, 300))
        shot("47-read-only-finger-scrolls")
        app.terminate()
    }

}
