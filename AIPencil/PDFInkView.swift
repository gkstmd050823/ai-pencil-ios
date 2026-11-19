import PDFKit
import PencilKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// A PencilKit canvas that remembers which page it lies on.
final class PageCanvas: PKCanvasView {
    var pageIndex = 0
    /// How many strokes the drawing had when it was last looked at; one more means a stroke was just drawn.
    var strokeCount = 0
    /// The page's handwriting as the app last took note of it, and a number that goes up with every change:
    /// a picture made of the handwriting is good for as long as the number it was made at still stands.
    var ink = PKDrawing()
    var inkVersion = 0
    /// The room the handwriting takes on the page, worked out once when it is taken note of.
    var inkBounds = CGRect.null
    /// Set while the app itself is giving the canvas a drawing it has already taken note of.
    var byCode = false

    /// Gives the canvas a drawing the app has taken note of already, so that the canvas telling of the
    /// change is not taken for news. (Should the canvas tell of it only later, it is taken for news after
    /// all, which costs a moment of the canvas showing in the picture's place and nothing else.)
    func take(_ drawing: PKDrawing) {
        byCode = true
        self.drawing = drawing
        byCode = false
        behind = false
    }

    /// The app has changed the handwriting since the canvas was last handed it.
    ///
    /// Until 0.12.2 the canvas was handed the whole of a page's handwriting every time the app's own pen
    /// finished a line and every time its eraser took one, though the canvas was out of sight (the app's
    /// pictures show the handwriting) and no tool of PencilKit's was in hand. PencilKit draws everything
    /// it is handed, as fine as the zoom: zoomed in on a page with a hundred lines that is a great deal
    /// of drawing, done over for each line of a scribble and for each line an eraser crossed (a
    /// diagnostics report had the app not answering for three seconds with the eraser in hand). Now the
    /// canvas is only noted to be behind, and handed the handwriting when it is about to be seen or used,
    /// or when the hand has rested.
    var behind = false

    /// Hands the canvas the handwriting as it stands, if it has not got it.
    func catchUp() {
        if behind { take(ink) }
    }
}

/// The drag that draws a shape: it begins the moment the page is touched, and remembers where.
final class ShapeGesture: UILongPressGestureRecognizer {
    var start = CGPoint.zero
    /// Every place the touch has been at since they were last taken, in the gesture's view: those the
    /// system told of one by one and those it put together into one telling.
    ///
    /// The gesture's action is told where the touch is now. When the app is busy for a moment, the
    /// places a touch went through meanwhile come all at once, and the action hears only of the last:
    /// an eraser moved to and fro over a line was then taken to have gone straight from where it was
    /// before the wait to where it was after, which may be nowhere near the line.
    private var trail: [CGPoint] = []

    /// Whether a touch is in the gesture's hands: one that landed while the gesture was at work.
    private(set) var tracking = false

    func takeTrail() -> [CGPoint] {
        let taken = trail
        trail = []
        return taken
    }

    override func reset() {
        super.reset()
        tracking = false
    }

    private func note(_ touches: Set<UITouch>, _ event: UIEvent) {
        guard let view, let touch = touches.first else { return }
        for one in event.coalescedTouches(for: touch) ?? [touch] {
            trail.append(one.preciseLocation(in: view))
        }
        // (Never more than a drag can sensibly have: the oldest go first.)
        if trail.count > 4000 { trail.removeFirst(trail.count - 4000) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        trail = []
        tracking = true
        note(touches, event)
        super.touchesBegan(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        tracking = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        note(touches, event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        note(touches, event)
        super.touchesEnded(touches, with: event)
        tracking = false
    }
}

/// Watches where a touch goes without getting in anyone's way: it never claims the touch and is never made
/// to let go of it. PencilKit rubs out as it always does, and this tells the app where the eraser is.
final class TouchWatcher: UIGestureRecognizer {
    /// Called as the touch moves: where it was last seen and where it is now, in the view's frame.
    var onMove: ((CGPoint, CGPoint) -> Void)?
    /// Called when the touch lands, and when it is over.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    /// Called with the time of each touch seen (for measuring, in a debug build).
    var onSeen: ((TimeInterval) -> Void)?
    /// Called whenever the touch is over.
    var onLift: (() -> Void)?
    /// Called as the touch moves, with every place it went through since the last call, the place it
    /// was at then first.
    var onPath: (([CGPoint]) -> Void)?
    /// Whether the touch being watched is a pencil's.
    private(set) var pencil = false
    private weak var followed: UITouch?
    private var last = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard followed == nil, let touch = touches.first else { return }
        followed = touch
        pencil = touch.type == .pencil
        last = touch.location(in: view)
        onDown?()
        onMove?(last, last)
        onSeen?(touch.timestamp)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        let point = touch.location(in: view)
        onMove?(last, point)
        if let onPath {
            var way = [last]
            for one in event.coalescedTouches(for: touch) ?? [touch] { way.append(one.location(in: view)) }
            onPath(way)
        }
        onSeen?(touch.timestamp)
        last = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        letGo(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        letGo(touches)
    }

    private func letGo(_ touches: Set<UITouch>) {
        guard let touch = followed, touches.contains(touch) else { return }
        followed = nil
        onUp?()
        onLift?()
        // It never recognises anything; saying so is what readies it for the next touch.
        state = .failed
    }

    override func reset() {
        super.reset()
        if followed != nil {
            followed = nil
            onUp?()
            onLift?()
        }
    }

    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }

    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

/// The document opened once more, for the queue that draws the pages' pictures and for nothing else.
/// PDFKit's objects are not made to be used from two threads at once, and the page view is busy with its
/// own on the main thread; this copy is only ever touched from the one queue.
final class PictureSource {
    private let url: URL
    private var document: PDFDocument?

    init(url: URL) {
        self.url = url
    }

    func page(_ index: Int) -> PDFPage? {
        if document == nil {
            // (Its pages are of the kind that can draw themselves dark.)
            document = DocFile.open(url, delegate: InkPageMaker.shared)
        }
        return document?.page(at: index)
    }

    /// Lets the copy go, to give its memory back; it is opened again when next needed.
    func forget() {
        document = nil
    }
}

/// Numbers the requests for a page's picture, so that a picture which comes back late, for a request that
/// has since been replaced, can be told and dropped. Read from the drawing queue as well as the main one.
final class Ticket {
    private let lock = NSLock()
    private var number = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        number += 1
        return number
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return number
    }
}

/// The page itself, drawn by the app with exactly as many pixels as the screen shows it with, and laid
/// over PDFKit's own picture of it. PDFKit draws a page in tiles, when it gets to them and as fine as it
/// sees fit, and has no setting for either; this picture is drawn in one piece, off the main thread, as
/// soon as the page comes near the screen. PDFKit's picture is what shows until this one is ready, and
/// wherever this one does not reach.
///
/// In the build server's simulator the two pictures are the same to within a grey level: PDFKit's is as
/// sharp there as this one. On an iPad in the hand it is the sharper (iPadOS 27 draws part of a page's
/// layers at a single pixel a point), so since 0.8.0 it is always there and has no setting.
///
/// The view is as large as the page is shown and turned back against the overlay's turning, so a point in
/// it is a point of the page as the reader sees it, measured from its top-left corner.
final class PagePicture: UIView {
    /// A part of the page and how finely it is drawn, in pixels per page point.
    struct Extent: Equatable {
        var rect: CGRect
        var scale: CGFloat
    }

    /// What is on show.
    private(set) var shown: Extent?
    /// What has been asked for and is being drawn.
    var asked: Extent?
    /// Drawing failed once (no memory for it, most likely); it is not tried again for this page.
    var gaveUp = false
    /// How often PencilKit has changed the handwriting on its own since the page was laid out.
    var breaks = 0
    /// For how many looks in a row the picture's pixels have been found off the screen's.
    var offGrid = 0
    let ticket = Ticket()
    private let image = CALayer()
    /// The picture on show.
    private(set) var picture: CGImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true
        image.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(image)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ picture: CGImage, _ extent: Extent) {
        image.frame = extent.rect
        image.contents = picture
        self.picture = picture
        shown = extent
        asked = nil
    }

    /// Lets the picture go, to give its memory back.
    func clear() {
        ticket.next()
        image.contents = nil
        picture = nil
        shown = nil
        asked = nil
    }

    /// A picture of [extent] of [page], whose size as shown is [size]. Made off the main thread.
    static func draw(_ page: PDFPage, size: CGSize, extent: Extent) -> CGImage? {
        let rect = extent.rect, scale = extent.scale
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // PDFKit draws a page with its bottom-left corner at the origin, upward, a point to a unit. The
        // part asked for is measured from the page's top-left corner, downward.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: rect.maxY - size.height)
        context.clip(to: CGRect(origin: .zero, size: size))
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}

/// A formula on a page: its shape, filled with its colour.
final class MathView: UIImageView {
    var item: MathItem

    init(item: MathItem, picture: UIImage?, quarterTurns: Int, dark: Bool) {
        self.item = item
        super.init(image: picture?.withRenderingMode(.alwaysTemplate))
        tintColor = dark ? item.color.onDarkPaper : item.color
        contentMode = .scaleToFill
        isUserInteractionEnabled = true
        bounds = CGRect(x: 0, y: 0, width: item.width, height: item.height)
        center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        // The overlay is turned along with a page that is shown turned. The formula is turned back by as
        // much, so that it stands upright on screen.
        transform = CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }
}

/// The small round button beside a mark of the AI pen. Touching it opens the mark's explanation.
final class MarkBadge: UIButton {
    static let side: CGFloat = 22
    let question: Question

    init(question: Question, active: Bool) {
        self.question = question
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        backgroundColor = InkChoice.markColor.withAlphaComponent(active ? 1 : 0.85)
        layer.cornerRadius = Self.side / 2
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = active ? 2 : 1
        let glyph = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        setImage(UIImage(systemName: "text.alignleft", withConfiguration: glyph), for: .normal)
        tintColor = .white
        accessibilityLabel = "\(question.page + 1)쪽 설명 열기"
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // Easier to touch than it looks.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -9, dy: -9).contains(point)
    }
}

/// Turns the pages two at a time, where two are shown side by side and do not scroll on to the next two:
/// a finger swept to the left brings the next two, to the right the two before, sliding in from that side.
///
/// A pen never turns pages (it writes), and neither does a finger on a page while fingers write. Zoomed
/// in, a sweep moves across the pages as ever, and turns them only from the edge it cannot move past.
final class SpreadTurner: NSObject, UIGestureRecognizerDelegate {
    private weak var view: PDFView?
    private let forward = UISwipeGestureRecognizer()
    private let back = UISwipeGestureRecognizer()
    var scrollOf: (PDFView) -> UIScrollView? = { _ in nil }
    var fingerWrites: () -> Bool = { false }
    /// Something is being written or rubbed out this moment.
    var busy: () -> Bool = { false }

    var isOn = false {
        didSet {
            forward.isEnabled = isOn
            back.isEnabled = isOn
            keepBackSwipe()
        }
    }

    /// The recogniser of the system's own "sweep right anywhere to go back", once it has been found and
    /// switched off.
    private weak var stilled: UIGestureRecognizer?

    /// Since iPadOS 26 a finger swept to the right anywhere on a screen goes back a screen: here it left
    /// the document for the shelf where it was meant to turn back two pages. While pages are turned by
    /// sweeping, that is switched off (going back from the screen's left edge, and by the arrow, stays).
    /// Called now and then as well: the screen above may not be there yet when the pages are laid out.
    func keepBackSwipe() {
        guard isOn else {
            stilled?.isEnabled = true
            stilled = nil
            return
        }
        guard stilled == nil, let view else { return }
        var above: UIResponder? = view
        while let here = above {
            if let navigation = here as? UINavigationController {
                // (Asked for by name: the property is not in every version of the system this is built for.)
                let name = NSSelectorFromString("interactiveContentPopGestureRecognizer")
                if navigation.responds(to: name), let found = navigation.perform(name)?.takeUnretainedValue() as? UIGestureRecognizer {
                    found.isEnabled = false
                    stilled = found
                    DebugLog.write("turning: the system's sweep to go back is off while pages are turned by sweeping")
                }
                return
            }
            above = here.next
        }
    }

    /// The document is being closed: the system's sweep is as it was.
    func letGo() {
        stilled?.isEnabled = true
        stilled = nil
    }

    func attach(to view: PDFView) {
        guard self.view !== view else { return }
        self.view = view
        forward.direction = .left
        back.direction = .right
        for swipe in [forward, back] {
            swipe.addTarget(self, action: #selector(swept(_:)))
            swipe.delegate = self
            swipe.cancelsTouchesInView = false
            swipe.isEnabled = isOn
            view.addGestureRecognizer(swipe)
        }
    }

    @objc private func swept(_ swipe: UISwipeGestureRecognizer) {
        turn(forward: swipe === forward)
    }

    /// Shows the next two pages, or the two before. False at either end of the document.
    @discardableResult
    func turn(forward ahead: Bool) -> Bool {
        guard isOn, let view, let document = view.document, let page = view.currentPage else { return false }
        let index = document.index(for: page)
        guard index != NSNotFound else { return false }
        // (The page PDFKit calls the current one may be either of the two on show.)
        let first = index - index % 2
        let target = ahead ? first + 2 : first - 2
        guard target >= 0, target < document.pageCount, let next = document.page(at: target) else { return false }
        let slide = CATransition()
        slide.type = .push
        slide.subtype = ahead ? .fromRight : .fromLeft
        slide.duration = 0.24
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer.add(slide, forKey: "turn")
        view.go(to: next)
        Diagnostics.shared.step(ahead ? "turned to the next two pages" : "turned to the two pages before")
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if touch.type == .pencil { return false }
        guard fingerWrites() else { return true }
        var above = touch.view
        while let here = above {
            if here is PageOverlay { return false }
            above = here.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isOn, !busy() else { return false }
        guard let view, let scroll = scrollOf(view) else { return true }
        let slack: CGFloat = 6
        if gestureRecognizer === forward {
            return scroll.contentOffset.x >= scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width - slack
        }
        return scroll.contentOffset.x <= -scroll.adjustedContentInset.left + slack
    }
}

/// What PDFKit lays over a page: the page's formulas and the marks of the AI pen, above them the canvas
/// that takes the handwriting, and on top the buttons of the marks.
/// PDFKit sizes this view to the page and zooms it with the page, so a point in it is a point of the page,
/// measured from the page's top-left corner.
final class PageOverlay: UIView {
    let canvas = PageCanvas()
    /// The page drawn sharp, under everything else.
    let pagePicture = PagePicture()
    /// Marks the words a search found.
    private let highlights = UIView()
    /// Follows the eraser, to take the AI pen's marks off the page where it passes.
    let watcher = TouchWatcher()
    /// The drags on the surface below: one draws shapes, one rubs out highlighter, one is the app's own pen.
    var shapeDrag: ShapeGesture?
    var rubDrag: ShapeGesture?
    var penDrag: PenGesture?
    /// The page's handwriting drawn by the app itself, with exactly the screen's pixels (InkPaint): the
    /// highlighter in a picture of its own under the canvas, everything else in one above it. While these
    /// show, the canvas is out of sight. They lie in this view's frame, like the handwriting itself.
    let inkPicture = PagePicture()
    let highPicture = PagePicture()
    /// The number the handwriting had when the pictures on show were made.
    var inkPictureVersion = -1
    /// The pictures stand for the handwriting: they were made of it, and whatever has changed since is a
    /// change the app made itself and is drawing into them. Not so from the moment PencilKit changes the
    /// handwriting on its own canvas, until pictures have been made anew.
    var inkTrusted = false
    /// The handwriting the pictures stand for is none at all, and so there are none.
    var inkEmpty = false
    /// The part of the page where the handwriting has changed since the pictures were made; or all of it.
    var inkDirty = CGRect.null
    var inkDirtyAll = true
    /// Pictures are being made; and whether more has changed meanwhile.
    var inkBusy = false
    var inkAgain = false
    /// How fine the pictures being made are to be (pixels to a page point); nought when none are being made.
    var inkAsking: CGFloat = 0
    /// Pictures that were ready while a line was being written, waiting for the pen to be off the page.
    var inkLanding: (() -> Void)?
    /// A pen or finger is on the canvas at this moment.
    var inkInUse = false
    /// When the canvas was last touched, and when the handwriting last changed.
    var canvasUsed: CFTimeInterval = 0
    var inkTouched: CFTimeInterval = 0
    /// Lines written with the app's own pen, and shapes just drawn: shown as plain filled shapes from the
    /// moment they are made until the picture of the handwriting has them. Highlighter lines go in a view
    /// of their own, under the canvas, laid over the page the way the highlighter's picture is.
    private let penMarks = UIView()
    private let highMarks = UIView()
    /// The line being written and the lines not in the picture yet, drawn the way the picture is drawn.
    private let wetPens = WetInk()
    private let wetHigh = WetInk()
    private let liveTail = CAShapeLayer()
    private let markLines = UIView()
    /// Takes the drags of the tools that do not write through PencilKit: the shape tool, and the eraser
    /// that only takes highlighter. Hidden, and so out of the way, while any other tool is in hand.
    let shapeSurface = UIView()
    /// The shape being drawn, until the hand lets go and it becomes ink.
    let shapePreview = CAShapeLayer()
    /// How many times finer than the page the canvas draws its ink. PDFKit zooms this view by stretching
    /// it, which on its own would stretch the ink's pixels too and leave the lines soft. So the canvas is
    /// made this many times larger, zoomed in on its own drawing by as much, and shrunk back to the page:
    /// the drawing keeps its place and its coordinates, and has that many times the pixels.
    var inkScale: CGFloat = 1 {
        didSet { if inkScale != oldValue { setNeedsLayout() } }
    }
    /// The part of the page the canvas lies over, in this view's frame. A canvas as fine as the screen and
    /// as large as the whole page is the size of the page times the zoom, squared; zoomed in far that is
    /// more than is worth having, and it used to be capped at three times the page, which left handwriting
    /// coarse beyond that zoom. So from where the whole-page canvas would be larger than that, the canvas
    /// covers only the part in view and some way round it (it is a scroll view: its drawing is the whole
    /// page still, scrolled to that part), and can be as fine as the screen at any zoom. Null until the
    /// page view has said where it goes.
    var canvasWindow = CGRect.null {
        didSet { if canvasWindow != oldValue { setNeedsLayout() } }
    }
    /// The most room a canvas takes: three times an A4 page each way, in its own points.
    static let canvasRoom: CGFloat = 595 * 842 * 9
    /// Called when the canvas cannot be laid out because it has not been said yet where it goes.
    var onNeedsWindow: (() -> Void)?
    private var canvasFits: (size: CGSize, scale: CGFloat, window: CGRect) = (.zero, 0, .null)
    /// Shows where the eraser is.
    private let eraserRing = CAShapeLayer()
    /// How far the page is shown turned, in quarter turns clockwise.
    var quarterTurns = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // The paper is white whatever the iPad's appearance. PencilKit would otherwise turn dark ink
        // light on a dark screen, and it would vanish on the page.
        overrideUserInterfaceStyle = .light
        addSubview(pagePicture)
        highlights.isUserInteractionEnabled = false
        addSubview(highlights)
        markLines.isUserInteractionEnabled = false
        addSubview(markLines)
        highPicture.layer.masksToBounds = false
        highPicture.isHidden = true
        addSubview(highPicture)
        highMarks.isUserInteractionEnabled = false
        wetHigh.asLines = !InkPaint.oldHighlighter
        highMarks.addSubview(wetHigh)
        addSubview(highMarks)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)
        inkPicture.layer.masksToBounds = false
        inkPicture.isHidden = true
        addSubview(inkPicture)
        setPaper(dark: false)
        penMarks.isUserInteractionEnabled = false
        penMarks.addSubview(wetPens)
        addSubview(penMarks)
        liveTail.fillColor = nil
        liveTail.lineCap = .round
        liveTail.lineJoin = .round
        liveTail.actions = ["path": NSNull()]
        eraserRing.fillColor = UIColor.systemGray.withAlphaComponent(0.12).cgColor
        eraserRing.strokeColor = UIColor.systemGray.cgColor
        eraserRing.actions = ["path": NSNull(), "hidden": NSNull()]
        eraserRing.isHidden = true
        penMarks.layer.addSublayer(eraserRing)
        canvas.bounces = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.scrollsToTop = false
        shapeSurface.backgroundColor = .clear
        shapeSurface.isHidden = true
        shapePreview.fillColor = nil
        shapePreview.lineCap = .round
        shapePreview.lineJoin = .round
        shapeSurface.layer.addSublayer(shapePreview)
        addSubview(shapeSurface)
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        watcher.isEnabled = false
        addGestureRecognizer(watcher)
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Formulas go under the canvas, so handwriting crosses over them.
    func add(_ view: MathView) {
        insertSubview(view, belowSubview: markLines)
    }

    var mathViews: [MathView] {
        subviews.compactMap { $0 as? MathView }
    }

    var badges: [MarkBadge] {
        subviews.compactMap { $0 as? MarkBadge }
    }

    /// How the highlighter lies on the paper. On white paper it is a tint: it darkens the paper to its
    /// colour and leaves anything darker than itself (print, pen) as it was. On dark paper it lightens.
    func setPaper(dark: Bool) {
        for layer in [highPicture.layer, highMarks.layer] {
            layer.compositingFilter = dark ? "screenBlendMode" : "multiplyBlendMode"
            layer.opacity = Float(dark ? 0.34 : InkChoice.highlighterStrength)
        }
    }

    /// Whether the app's pictures of the handwriting are what shows (and not the canvas).
    private(set) var showsInkPicture = false

    /// The canvas shows the handwriting itself. Whenever the pictures might not be the handwriting as it
    /// stands, this is what is shown: the canvas is always right.
    func showCanvasInk() {
        // (About to be seen, or seen already: it has to have the handwriting as it stands.)
        canvas.catchUp()
        guard showsInkPicture || canvas.alpha != 1 else { return }
        showsInkPicture = false
        canvas.alpha = 1
        inkPicture.isHidden = true
        highPicture.isHidden = true
    }

    /// The app's pictures show the handwriting, and the canvas is out of sight.
    func showInkPicture() {
        guard !showsInkPicture else { return }
        showsInkPicture = true
        inkPicture.isHidden = false
        highPicture.isHidden = false
        canvas.alpha = 0
    }

    /// How many lines are on show as shapes of their own, waiting for the picture to have them.
    var keptCount: Int { wetPens.count + wetHigh.count }

    /// Shows a ring where the eraser is, as large as what it rubs out; nil takes the ring away.
    func showEraser(at place: CGPoint?, radius: CGFloat, fineness: CGFloat) {
        guard let place else {
            if !eraserRing.isHidden { eraserRing.isHidden = true }
            return
        }
        eraserRing.path = CGPath(ellipseIn: CGRect(x: place.x - radius, y: place.y - radius, width: radius * 2, height: radius * 2), transform: nil)
        // (A hairline on screen whatever the zoom.)
        eraserRing.lineWidth = 2.4 / max(fineness, 1)
        eraserRing.contentsScale = fineness
        if eraserRing.isHidden { eraserRing.isHidden = false }
    }

    /// Lets the pictures of the handwriting go. The canvas shows from here on, until new ones are made.
    func dropInkPicture() {
        showCanvasInk()
        if inkPicture.shown != nil { inkPicture.clear() } else { inkPicture.ticket.next() }
        if highPicture.shown != nil { highPicture.clear() }
        inkPictureVersion = -1
        inkTrusted = false
        inkEmpty = false
        inkDirty = .null
        inkDirtyAll = true
    }

    /// Shows the line being written with the app's own pen, and where the pen is expected to go next.
    /// [under] puts it where highlighter goes: under the canvas, as a tint. [fineness] is how many pixels
    /// of the screen a page point takes and [grid] where a pixel begins.
    func drawLive(
        _ line: PenLine, ahead: [PenSample], color: CGColor, fineness: CGFloat, grid: CGPoint, under: Bool = false, afresh: Bool = false,
        from changed: Int = 0
    ) {
        let wet = under ? wetHigh : wetPens
        wet.fit(scale: fineness, grid: grid)
        // ([afresh]: the line has changed from point [changed] on, and is made anew from there.)
        if afresh { wet.restart(from: changed) }
        wet.write(line, color: color)
        // A steadied line trails the pen on purpose; only a line that keeps up with it is drawn ahead.
        if !under, line.steady < 0.05, let end = line.points.last, let width = line.widths.last, !ahead.isEmpty {
            let path = CGMutablePath()
            path.move(to: end)
            for sample in ahead { path.addLine(to: sample.point) }
            liveTail.path = path
            liveTail.lineWidth = width
            liveTail.strokeColor = color
            liveTail.contentsScale = fineness
            if liveTail.superlayer == nil { penMarks.layer.addSublayer(liveTail) }
        } else {
            liveTail.path = nil
        }
    }

    /// Lights up, for a moment, the way from [from] to [to]: a line has just been made straight.
    func flash(from: CGPoint, to: CGPoint, width: CGFloat, fineness: CGFloat) {
        let light = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        light.path = path
        light.fillColor = nil
        light.lineCap = .round
        light.lineWidth = width + 6 / max(fineness / 2, 0.5)
        light.strokeColor = InkChoice.markColor.withAlphaComponent(0.28).cgColor
        light.contentsScale = fineness
        light.opacity = 0
        penMarks.layer.insertSublayer(light, at: 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        light.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { light.removeFromSuperlayer() }
    }

    /// The line being written came to nothing.
    func dropLive() {
        wetPens.drop()
        wetHigh.drop()
        liveTail.path = nil
    }

    /// The line just written is part of the handwriting from this number on, as the stroke made at
    /// [date]; it stays on show until a picture made at that number or later is.
    func keepLive(for version: Int, date: Date?) {
        liveTail.path = nil
        wetPens.keep(version: version, date: date)
        wetHigh.keep(version: version, date: date)
    }

    /// The same for a shape just added to the handwriting: the places its outline goes through.
    func keep(points: [CGPoint], width: CGFloat, widths: [CGFloat]? = nil, color: CGColor, fineness: CGFloat, grid: CGPoint, for version: Int, date: Date?) {
        wetPens.fit(scale: fineness, grid: grid)
        wetPens.add(points: points, width: width, widths: widths, color: color, version: version, date: date)
    }

    /// Takes down the lines the picture now has (those up to [version]; all of them when none is given).
    func dropPreviews(upTo version: Int = .max) {
        wetPens.settle(upTo: version)
        wetHigh.settle(upTo: version)
    }

    /// The handwriting changed by something other than a line being added (a line rubbed out, a step
    /// undone): lines on show whose strokes are no longer in it come down at once.
    func keepPreviews(ofStrokesMadeAt dates: Set<Date>) {
        wetPens.keepOnly(strokesMadeAt: dates)
        wetHigh.keepOnly(strokesMadeAt: dates)
    }

    /// Marks these parts of the page, given in this view's frame, as found by a search.
    func highlight(_ rects: [CGRect]) {
        highlights.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for rect in rects {
            let mark = CALayer()
            mark.frame = rect.insetBy(dx: -1.5, dy: -1)
            mark.cornerRadius = 2
            mark.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.42).cgColor
            highlights.layer.addSublayer(mark)
        }
    }

    /// Draws these marks, and no others. Hands back their buttons, for the caller to wire up.
    func show(_ marks: [Question], active: UUID?) -> [MarkBadge] {
        markLines.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        badges.forEach { $0.removeFromSuperview() }
        var made: [MarkBadge] = []
        for mark in marks {
            let points = mark.points
            guard let first = points.first else { continue }
            let isActive = mark.id == active
            let path = UIBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            let line = CAShapeLayer()
            line.path = path.cgPath
            line.fillColor = nil
            line.strokeColor = InkChoice.markColor.withAlphaComponent(isActive ? 0.92 : 0.55).cgColor
            line.lineWidth = isActive ? 2.8 : 2.2
            line.lineCap = .round
            line.lineJoin = .round
            markLines.layer.addSublayer(line)
            let badge = MarkBadge(question: mark, active: isActive)
            addSubview(badge)
            made.append(badge)
        }
        setNeedsLayout()
        return made
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        markLines.frame = bounds
        shapeSurface.frame = bounds
        highlights.frame = bounds
        inkPicture.frame = bounds
        highPicture.frame = bounds
        penMarks.frame = bounds
        highMarks.frame = bounds
        wetPens.frame = penMarks.bounds
        wetHigh.frame = highMarks.bounds
        // The picture of the page is as large as the page is shown, and stands upright on screen.
        let sideways = quarterTurns % 2 != 0
        let shown = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        if pagePicture.bounds.size != shown || pagePicture.center != middle {
            pagePicture.transform = .identity
            pagePicture.bounds = CGRect(origin: .zero, size: shown)
            pagePicture.center = middle
            pagePicture.transform = CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2)
        }
        if bounds.width > 0, bounds.height > 0 {
            let wholeFits = bounds.width * bounds.height * inkScale * inkScale <= Self.canvasRoom
            var window = bounds
            if !wholeFits {
                window = canvasWindow.intersection(bounds)
                if window.isEmpty {
                    // Not said yet where the canvas goes; it is laid out as soon as that is known.
                    onNeedsWindow?()
                    window = .null
                }
            }
            if !window.isNull, canvasFits.size != bounds.size || canvasFits.scale != inkScale || canvasFits.window != window {
                let rescaled = canvasFits.scale != inkScale
                canvasFits = (bounds.size, inkScale, window)
                canvas.transform = .identity
                canvas.frame = CGRect(x: 0, y: 0, width: window.width * inkScale, height: window.height * inkScale)
                if rescaled || canvas.zoomScale != inkScale {
                    canvas.minimumZoomScale = inkScale
                    canvas.maximumZoomScale = inkScale
                    canvas.zoomScale = inkScale
                }
                canvas.contentSize = CGSize(width: bounds.width * inkScale, height: bounds.height * inkScale)
                canvas.contentOffset = CGPoint(x: window.minX * inkScale, y: window.minY * inkScale)
                // A canvas of part of the page could be scrolled about by a finger, which is the page
                // view's to do; a canvas of the whole page has nowhere to scroll to and is left as it was.
                canvas.isScrollEnabled = window == bounds
                canvas.transform = CGAffineTransform(scaleX: 1 / inkScale, y: 1 / inkScale)
                canvas.center = CGPoint(x: window.midX, y: window.midY)
            }
        }
        // Each button sits at the top-right corner of its mark, kept inside the page.
        let edge = MarkBadge.side / 2 + 2
        for badge in badges {
            let box = badge.question.bounds
            var center = CGPoint(x: box.maxX + 3, y: box.minY - 3)
            if bounds.width > 2 * edge, bounds.height > 2 * edge {
                center.x = min(max(edge, center.x), bounds.width - edge)
                center.y = min(max(edge, center.y), bounds.height - edge)
            }
            badge.center = center
        }
    }

    // A touch that lands on nothing of ours (the canvas switched off, no formula there) goes on to PDFKit,
    // which scrolls the document.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// What the reader screen needs of the page view: where it is, and the things it can be asked to do.
final class ReaderController: ObservableObject {
    fileprivate weak var coordinator: PDFInkView.Coordinator?
    @Published fileprivate(set) var canUndo = false
    @Published fileprivate(set) var canRedo = false
    /// The page in view, counted from zero, and how many pages there are.
    @Published fileprivate(set) var pageIndex = 0
    @Published fileprivate(set) var pageCount = 0

    /// Called when the user asks to edit a formula.
    var onEditMath: ((MathItem) -> Void)?
    /// Called when the user drew a mark with the AI pen: the page, and the mark in the overlay's frame.
    var onMark: ((Int, [CGPoint]) -> Void)?
    /// Called when the user touched a mark to read its explanation again.
    var onOpenMark: ((UUID) -> Void)?
    var onHideMark: ((UUID) -> Void)?
    /// Called to put a mark back on the page that was taken off it.
    var onShowMark: ((UUID) -> Void)?
    var onDeleteMark: ((UUID) -> Void)?
    /// Called when a tool that is to be put down after use has been used.
    var onToolUsed: ((InkTool) -> Void)?
    /// Words were picked out of a page with a finger, and the finger has let go.
    var onPickedText: ((String) -> Void)?
    /// The words picked were copied.
    var onCopiedText: ((String) -> Void)?
    /// The user asked for the words picked to be translated.
    var onTranslate: ((String) -> Void)?

    /// The words picked out of a page now, if any.
    var pickedText: String { coordinator?.picker.text ?? "" }

    /// For the build server: picks the words between two places of the page in view.
    func demoPick(from a: CGPoint, to b: CGPoint) {
        coordinator?.demoPick(from: a, to: b)
    }
    /// Called on a double tap or a squeeze of the Apple Pencil.
    var onPencil: ((PencilAction) -> Void)?

    var currentPageIndex: Int? { coordinator?.currentPageIndex }
    /// The size of the page in view as it is shown, in points.
    var currentPageSize: CGSize? { coordinator?.currentPageSize }

    /// Writes everything to disk and stops the page view from writing again. Used before the document's
    /// pages are renumbered, after which what the page view knows about page numbers is out of date.
    func saveAndRetire() {
        coordinator?.saveAll()
        coordinator?.retired = true
    }

    func placeMath(_ result: MathResult, color: UIColor) {
        coordinator?.placeMath(result, color: color)
    }

    func replaceMath(_ old: MathItem, with result: MathResult) {
        coordinator?.replaceMath(old, with: result)
    }

    /// How a page is shown: its size, and how its overlay is turned.
    func pageShape(forPage index: Int) -> AskCapture.Shape? {
        coordinator?.pageShape(forPage: index)
    }

    /// The handwriting of a page as it stands now.
    func drawing(forPage index: Int) -> PKDrawing? {
        coordinator?.drawing(forPage: index)
    }

    /// Scrolls just far enough for this part of a page to be seen.
    func reveal(_ rect: CGRect, onPage index: Int) {
        coordinator?.reveal(rect, onPage: index)
    }

    func go(toPage index: Int) {
        coordinator?.go(toPage: index)
    }

    /// The document as the page view has it open: for its small pictures and its table of contents.
    var document: PDFDocument? { coordinator?.pdfView?.document }

    /// Every place in the document where these words stand.
    func search(_ text: String) -> [SearchHit] {
        coordinator?.search(text) ?? []
    }

    /// Goes to a place that was found and marks the words there.
    func show(_ hit: SearchHit) {
        coordinator?.show(hit)
    }

    /// Writes the handwriting of the pages in view to disk now.
    func save() {
        coordinator?.saveAll()
    }

    func undo() {
        coordinator?.expectNews()
        coordinator?.undoManager?.undo()
        Diagnostics.shared.step("undo")
    }

    /// Takes all the handwriting off the page in view. It can be undone.
    func clearPage() {
        coordinator?.clearPage()
    }

    func redo() {
        coordinator?.expectNews()
        coordinator?.undoManager?.redo()
    }

    /// For the build server: draws a ring with the AI pen on the page in view, as a hand would have.
    func demoMark(center: CGPoint, radius: CGSize) {
        coordinator?.demoMark(center: center, radius: radius)
    }

    /// For the build server: lays a solid block of ink on the page in view.
    func demoBlock() {
        coordinator?.demoBlock()
    }

    /// For the build server: fills the page in view with handwriting.
    func demoDense(_ count: Int) {
        coordinator?.demoDense(count)
    }

    /// For the build server: writes a shaky line with the app's own pen, plain and steadied.
    func demoPen() {
        coordinator?.demoPen()
    }

    /// For the build server: many lines of highlighter, written the way a pen writes them, and timed.
    func demoHighlightMany() {
        coordinator?.demoHighlightMany()
    }

    /// For the build server: a line being written, the pen still on the page.
    func demoLive() {
        coordinator?.demoLive()
    }

    /// For the build server: lines in dashes and dots, and lines of the brush.
    func demoDashes() {
        coordinator?.demoDashes()
    }

    /// For the build server: shapes drawn by hand and held, made true.
    func demoHeldShapes() {
        coordinator?.demoHeldShapes()
    }

    /// For the build server: turns to the next two pages, as a swipe would.
    func demoTurn() {
        coordinator?.turner.turn(forward: true)
    }

    /// The file the page view shows.
    var pdfURL: URL? { coordinator?.url }

    /// For the build server: moves the eraser across the page in view, as a hand would have.
    func demoErase(from: CGPoint, to: CGPoint) {
        coordinator?.demoErase(from: from, to: to)
    }

    /// For the build server: zooms in this many times past fitting the page.
    func demoZoom(_ factor: Double) {
        coordinator?.demoZoom(factor)
    }

    /// For the build server: one of each shape on the page in view, made the way a drag makes them.
    func demoShapes() {
        coordinator?.demoShapes()
    }
}

/// The reading and writing surface: PDFKit shows and scrolls the pages, and on every page it lays one
/// overlay (iPadOS 16's page overlay) holding the page's formulas, its marks and a PencilKit canvas.
struct PDFInkView: UIViewRepresentable {
    let url: URL
    let store: DrawingStore
    let mathStore: MathStore
    var choice: InkChoice
    /// Off: only Apple Pencil writes and fingers scroll. On: fingers write too.
    var fingerDraws: Bool
    var layout: PageLayoutMode
    /// Pages are shown as dark paper: near-black with light ink.
    var darkPaper: Bool
    /// The page to show first.
    var startPage: Int
    /// The marks of the AI pen to draw on the pages.
    var marks: [Question]
    /// The mark whose explanation is open.
    var activeMark: UUID?
    let controller: ReaderController

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, mathStore: mathStore)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.pageShadowsEnabled = true
        view.backgroundColor = darkPaper ? UIColor(white: 0.05, alpha: 1) : .secondarySystemBackground
        InkPage.dark = darkPaper
        let coordinator = context.coordinator
        coordinator.darkPaper = darkPaper
        coordinator.choice = choice
        coordinator.fingerDraws = fingerDraws
        coordinator.url = url
        coordinator.source = PictureSource(url: url)
        coordinator.apply(marks: marks, active: activeMark)
        coordinator.pdfView = view
        coordinator.controller = controller
        controller.coordinator = coordinator
        coordinator.apply(layout: layout)
        // The provider has to be in place before the document, or the first pages get no overlay.
        view.pageOverlayViewProvider = coordinator
        // Markup mode makes PDFKit pass touches through to the overlays instead of selecting text.
        view.isInMarkupMode = true
        // The delegate has the document make its pages of our own kind, which can draw themselves dark.
        view.document = DocFile.open(url, delegate: coordinator)
        view.addInteraction(UIPencilInteraction(delegate: coordinator))
        coordinator.watch(view)
        Diagnostics.shared.viewAsked = { [weak coordinator] in coordinator?.viewAsText() ?? "" }
        Diagnostics.shared.step("document opened, \(view.document?.pageCount ?? 0) pages")
        if startPage > 0, let page = view.document?.page(at: startPage) {
            // Once the view has been laid out; going to a page before that does nothing.
            DispatchQueue.main.async { view.go(to: page) }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.apply(choice: choice, fingerDraws: fingerDraws)
        context.coordinator.apply(marks: marks, active: activeMark)
        context.coordinator.apply(layout: layout)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.turner.letGo()
        coordinator.saveAll()
        coordinator.stopWatching()
        Diagnostics.shared.step("document closed")
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PDFDocumentDelegate, PKCanvasViewDelegate, UIContextMenuInteractionDelegate, UIPencilInteractionDelegate {
        private let store: DrawingStore
        private let mathStore: MathStore
        private var overlays: [PDFPage: PageOverlay] = [:]
        private var math: [MathItem]
        private var marks: [Question] = []
        private var activeMark: UUID?
        private var layout: PageLayoutMode?
        private var inkScale: CGFloat = 1
        private var watching: [NSObjectProtocol] = []
        /// The words a search found: their page, and where they stand on it in the overlay's frame.
        private var found: (page: Int, rects: [CGRect])?
        /// The handwriting of every page it has changed on, as it stands now, and the pages whose
        /// handwriting has not been written to disk yet.
        private var latest: [Int: PKDrawing] = [:]
        private var unsaved: Set<Int> = []
        private let saveQueue = DispatchQueue(label: "app.aipencil.ink", qos: .utility)
        private let pictureQueue = DispatchQueue(label: "app.aipencil.pages", qos: .userInitiated)
        private var pictureTimer: Timer?
        private var scaleSeen: CGFloat = 0
        /// What the app's own eraser is at work on: the page's lines as they stand, the room each takes,
        /// the handwriting as it was when the eraser came down, and where lines have gone since.
        private var rubbed: (strokes: [PKStroke], boxes: [CGRect], before: PKDrawing, dirty: CGRect, count: Int)?
        /// The file on show, and the same file opened once more for the queue that draws the pages.
        var url: URL?
        var source: PictureSource?
        private let inkQueue = DispatchQueue(label: "app.aipencil.ink.pictures", qos: .userInitiated)
        /// The line being written with the app's own pen, the tool it is written with, and where the
        /// screen's pixels fall on its page.
        private var penLine: PenLine?
        /// Draw and hold. The pen has been held still at the end of a line that was near enough
        /// straight: the line is straight from here on, from where it began to wherever the pen is, as
        /// wide as it was on the whole. Nil while a line is written as the hand writes it.
        private var straight: (from: CGPoint, width: CGFloat, snapped: Bool)?
        /// Draw and hold, for a line that came back round to where it began: the outline of the shape it
        /// was meant to be, which stands in for the line from then on. Nil while there is none.
        private var shaped: [CGPoint]?
        /// The ends of the straight lines on the page being written on. A line made straight that begins
        /// or ends near one is put on it.
        private var joints: [CGPoint] = []
        private var endJoined = false
        /// How many places the line had when it was last looked at for being held: a line that has not
        /// grown since is what it was then.
        private var heldLooked = -1
        private var hold = HoldWatch()
        private var holdTimer: Timer?
        /// Where the pen was last heard from in the line being written, and on which page.
        private var penAt = CGPoint.zero
        private weak var penOverlay: PageOverlay?
        /// Taps the hand through an Apple Pencil Pro when a line is made straight or drawn to a direction.
        private var canvasFeedback: Any?
        /// "-demoEagerCanvas" hands the canvas every change at once, as was done until 0.12.2, for the
        /// build server to set the time that takes beside the time it takes now.
        private static let eagerCanvas = ProcessInfo.processInfo.arguments.contains("-demoEagerCanvas")
        /// "-demoOldWaiting": see WetInk. Told of in the timing of many lines.
        private static let oldWaiting = ProcessInfo.processInfo.arguments.contains("-demoOldWaiting")
        /// The zoom as last measured off the screen, and when.
        private var zoomMeasured: (zoom: CGFloat, at: CFTimeInterval) = (1, 0)
        /// Until when a change the canvas tells of may be PencilKit's own though no tool of PencilKit's
        /// is in hand: for a few seconds after one was, and after an undo or redo (which may be of
        /// something PencilKit did).
        private var newsUntil: CFTimeInterval = 0
        /// Whether the eraser's drag in progress has rubbed anything out.
        private var rubbedAny = false
        /// How the eraser's drag in progress has come in: when it began, when the app was last told of it,
        /// how many times it was told and of how many places, and the longest it waited between two tellings.
        private var rubTold: (began: CFTimeInterval, last: CFTimeInterval, tellings: Int, places: Int, longest: CFTimeInterval) = (0, 0, 0, 0, 0)
        /// When a pencil was last seen held just above a page.
        private var hoverSeen: CFTimeInterval = 0
        /// The eraser is working through a touch its own drag was never told of (see rubByWatch).
        private var watchRubs = false
        /// When a double tap or a squeeze of the pencil last changed the tool.
        private var pencilActed: CFTimeInterval = 0
        /// Turns the pages two at a time where two are shown side by side to be turned.
        let turner = SpreadTurner()
        private var penTool = InkTool.pen
        private var penGrid = CGPoint.zero
        /// The zoom range last given to the page view.
        private var zoomRange: (low: CGFloat, high: CGFloat) = (0, 0)
        /// The scroll views whose lock to one direction has been taken off, and the watch kept on each.
        private let freed = NSHashTable<UIScrollView>.weakObjects()
        private var lockWatches: [NSKeyValueObservation] = []
        private var ticks = 0
        /// Watches the page view's own scroll view, and notes that the canvases are due to be placed.
        private var scrollWatch: NSKeyValueObservation?
        private var placing = false
        weak var pdfView: PDFView?
        weak var controller: ReaderController?
        /// Picking words out of a page with a finger, where fingers do not write.
        private(set) lazy var picker: TextPicker = {
            let picker = TextPicker()
            picker.allowed = { [weak self] view, point in
                guard let self, !self.fingerDraws, let overlay = view as? PageOverlay else { return false }
                // (A finger held on a mark is asking for the mark's menu.)
                return self.mark(at: point, page: overlay.canvas.pageIndex) == nil
            }
            picker.pageOf = { [weak self] view in
                guard let self, let overlay = view as? PageOverlay else { return nil }
                return self.pdfView?.document?.page(at: overlay.canvas.pageIndex)
            }
            picker.zoom = { [weak self] in self?.zoomSeen ?? 1 }
            picker.onPicked = { [weak self] text in self?.controller?.onPickedText?(text) }
            picker.onCopied = { [weak self] text in self?.controller?.onCopiedText?(text) }
            picker.onTranslate = { [weak self] text in self?.controller?.onTranslate?(text) }
            return picker
        }()
        var choice = InkChoice()
        var fingerDraws = false
        var darkPaper = false
        /// Set when the document's pages are about to be renumbered: nothing more is written from here.
        var retired = false

        init(store: DrawingStore, mathStore: MathStore) {
            self.store = store
            self.mathStore = mathStore
            self.math = mathStore.load()
        }

        /// Every canvas shares the undo history of the window it is in.
        var undoManager: UndoManager? { pdfView?.undoManager }

        /// What the canvas tells of in the next few seconds may be a change PencilKit made.
        func expectNews(for seconds: CFTimeInterval = 2.5) {
            newsUntil = max(newsUntil, CACurrentMediaTime() + seconds)
        }

        /// Whether a change the canvas tells of can be one PencilKit made on its own: with a tool in hand
        /// that works on the canvas, with a touch on the canvas now or a moment ago (PencilKit takes a
        /// while to make a stroke of what its pencil wrote), or when it has just been said to expect one.
        private func mayBeNews(from canvas: PageCanvas) -> Bool {
            let now = CACurrentMediaTime()
            if choice.needsCanvas || now < newsUntil { return true }
            if let overlay = canvas.superview as? PageOverlay, overlay.inkInUse || now - overlay.canvasUsed < 4 { return true }
            return false
        }

        func apply(choice: InkChoice, fingerDraws: Bool) {
            guard choice != self.choice || fingerDraws != self.fingerDraws else { return }
            if choice.tool != self.choice.tool { Diagnostics.shared.step("tool " + choice.tool.rawValue) }
            // (A tool of PencilKit's put down: what it did last may still be on its way.)
            if self.choice.needsCanvas, !choice.needsCanvas { expectNews(for: 4) }
            self.choice = choice
            self.fingerDraws = fingerDraws
            // (Fingers that write do not pick words.)
            if fingerDraws { picker.clear() }
            for overlay in overlays.values {
                configure(overlay)
            }
        }

        func apply(marks: [Question], active: UUID?) {
            guard marks != self.marks || active != activeMark else { return }
            self.marks = marks
            activeMark = active
            for overlay in overlays.values {
                showMarks(in: overlay)
            }
        }

        func apply(layout: PageLayoutMode) {
            guard layout != self.layout, let view = pdfView else { return }
            let page = view.currentPage
            self.layout = layout
            // Turning pages one at a time is PDFKit's page view controller; two side by side that scroll
            // on downward are PDFKit's too. Two side by side that are turned two at a time are PDFKit's
            // two pages on their own, with the turning done here: its page view controller shows one page.
            let paged = layout == .paged
            let spreads = layout == .twoUpPaged
            view.displayMode = layout == .twoUp ? .twoUpContinuous : spreads ? .twoUp : (paged ? .singlePage : .singlePageContinuous)
            view.displayDirection = paged ? .horizontal : .vertical
            view.displaysAsBook = false
            view.usePageViewController(paged, withViewOptions: nil)
            turner.attach(to: view)
            turner.scrollOf = { Self.scrollView(in: $0) }
            turner.fingerWrites = { [weak self] in self?.fingerDraws ?? false }
            turner.busy = { [weak self] in self?.penLine != nil || self?.rubbed != nil }
            turner.isOn = spreads
            // (The scroll view the pages are in is another one now; it is looked for again, and the zoom
            // range is given to the page view afresh.)
            scrollWatch?.invalidate()
            scrollWatch = nil
            zoomRange = (0, 0)
            view.autoScales = true
            if let page { DispatchQueue.main.async { view.go(to: page) } }
        }

        private func configure(_ overlay: PageOverlay) {
            let canvas = overlay.canvas
            canvas.tool = choice.pencilKitTool
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            // The canvas takes touches only for the tools that work on it (the lasso, the eraser for part
            // of a line, the pencil). With the formula tool touches reach the formulas under it; with
            // every other tool they reach the surface the app's own tools work on.
            let onSurface = choice.tool == .shape || choice.ownEraser || choice.ownPen
            canvas.isUserInteractionEnabled = choice.needsCanvas
            overlay.shapeSurface.isHidden = !onSurface
            overlay.shapeDrag?.isEnabled = choice.tool == .shape
            overlay.rubDrag?.isEnabled = choice.ownEraser
            overlay.penDrag?.isEnabled = choice.ownPen
            // A tool that works on the canvas has the canvas show; any other, the app's pictures.
            settleInk(overlay)
            let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
            let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
            let writing = fingerDraws ? [pencil, finger] : [pencil]
            for gesture in overlay.shapeSurface.gestureRecognizers ?? [] {
                gesture.allowedTouchTypes = writing
            }
            // PencilKit says nothing of where a touch on its canvas goes, nor of when it lands; the watcher
            // does: for the AI pen's marks under the eraser, and for showing the canvas while it is written on.
            overlay.watcher.allowedTouchTypes = writing
            overlay.watcher.isEnabled = true
        }

        func classForPage() -> AnyClass {
            InkPage.self
        }

        // MARK: saving

        /// The handwriting of a page changed. It goes to disk a moment later and off the main thread:
        /// writing a full page out after every stroke would hold the pen up on a page with much on it.
        ///
        /// [own] says the app made the change itself, and where on the page ([dirty], or everywhere):
        /// the pictures of the handwriting stay on show and are brought up to date. Any other change is
        /// one PencilKit made on its canvas (a line moved by the lasso, cut by its eraser, drawn by its
        /// pencil, undone by it), so the canvas, which is always right, is shown at once.
        private func record(_ drawing: PKDrawing, on canvas: PageCanvas, own: Bool = false, count: Int? = nil, dirty: CGRect? = nil) {
            guard !retired else { return }
            canvas.ink = drawing
            canvas.inkVersion += 1
            // (Counting the lines means listing them, which takes longer the more there are: a count
            // already in hand is used.)
            canvas.strokeCount = count ?? drawing.strokes.count
            canvas.inkBounds = drawing.bounds
            latest[canvas.pageIndex] = drawing
            unsaved.insert(canvas.pageIndex)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveSoon), object: nil)
            perform(#selector(saveSoon), with: nil, afterDelay: 0.8)
            guard let overlay = canvas.superview as? PageOverlay else { return }
            overlay.inkTouched = CACurrentMediaTime()
            if let dirty, own {
                overlay.inkDirty = overlay.inkDirty.union(dirty)
            } else {
                overlay.inkDirtyAll = true
            }
            if !own {
                overlay.inkTrusted = false
                overlay.inkPicture.breaks += 1
                overlay.showCanvasInk()
                overlay.dropPreviews()
            }
        }

        /// A pen or a finger came down on a canvas, or left it. While it is there the canvas shows.
        private func canvasInUse(_ overlay: PageOverlay, _ inUse: Bool) {
            overlay.inkInUse = inUse
            overlay.canvasUsed = CACurrentMediaTime()
            if inUse {
                overlay.showCanvasInk()
                overlay.dropPreviews()
            }
        }

        @objc private func saveSoon() {
            write(waiting: false)
        }

        /// Writes out the pages that are waiting. One queue does all the writing, in order, so a page is
        /// never left with an older state than the last one written.
        private func write(waiting: Bool) {
            guard !retired else { return }
            let store = self.store
            let work = unsaved.compactMap { page in latest[page].map { (page, $0) } }
            unsaved = []
            if waiting {
                saveQueue.sync {
                    for (page, drawing) in work { store.save(drawing, page: page) }
                }
            } else if !work.isEmpty {
                saveQueue.async {
                    for (page, drawing) in work { store.save(drawing, page: page) }
                }
            }
        }

        /// Everything on disk before this returns.
        func saveAll() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveSoon), object: nil)
            write(waiting: true)
        }

        /// The handwriting of a page that is not on screen: as last changed here, or else as on disk.
        private func storedDrawing(page: Int) -> PKDrawing? {
            latest[page] ?? store.load(page: page)
        }

        // MARK: watching the page view

        /// Keeps the reader told of the page in view and of what can be undone, and the ink as fine as
        /// the zoom needs.
        func watch(_ view: PDFView) {
            let center = NotificationCenter.default
            watching.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.tellPage() }
            })
            watching.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.scaleChanged() }
            })
            for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                watching.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { self?.tellUndo() }
                })
            }
            // Leaving the app may be the last that is seen of it: nothing is left waiting to be written.
            watching.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.saveAll()
            })
            watching.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dropUnseenPictures()
            })
            startPictures()
            DispatchQueue.main.async { [weak self] in
                self?.tellPage()
                self?.tellUndo()
                self?.scaleChanged()
            }
        }

        func stopWatching() {
            watching.forEach { NotificationCenter.default.removeObserver($0) }
            watching = []
            pictureTimer?.invalidate()
            pictureTimer = nil
            scrollWatch?.invalidate()
            scrollWatch = nil
            lockWatches.forEach { $0.invalidate() }
            lockWatches = []
        }

        private func tellPage() {
            guard let controller, let view = pdfView, let document = view.document else { return }
            let index = view.currentPage.map { document.index(for: $0) } ?? 0
            if controller.pageIndex != index { controller.pageIndex = index }
            if controller.pageCount != document.pageCount { controller.pageCount = document.pageCount }
        }

        private func tellUndo() {
            guard let controller else { return }
            let undo = undoManager?.canUndo ?? false
            let redo = undoManager?.canRedo ?? false
            if controller.canUndo != undo { controller.canUndo = undo }
            if controller.canRedo != redo { controller.canRedo = redo }
        }

        /// The zoom changed. Once it has settled, the canvases are redrawn as fine as it needs.
        private func scaleChanged() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settleScale), object: nil)
            perform(#selector(settleScale), with: nil, afterDelay: 0.25)
        }

        @objc private func settleScale() {
            guard let view = pdfView else { return }
            // Exactly as fine as the zoom, so that a canvas's pixels are the screen's. (Until 0.7.1 it
            // was rounded up to the next quarter: at a zoom of 2.22 the canvas was drawn 2.25 times finer
            // than the page and then shrunk by a seventieth, which is what blurred a line the moment
            // PencilKit's drawing of it took the place of the app's.) No finer than eight times the page;
            // and after a memory warning, no finer than half as fine again as the page.
            let finest: CGFloat = Self.tight ? 1.5 : max(8, view.maxScaleFactor)
            let zoom = zoomSeen
            let wanted = min(finest, max(1, zoom))
            if abs(wanted - inkScale) > 0.0005 {
                inkScale = wanted
                for overlay in overlays.values where !overlay.inkInUse {
                    overlay.inkScale = wanted
                }
                DebugLog.write("ink: page zoom \(zoom) (PDFKit says \(view.scaleFactor)), canvases drawn \(wanted) times finer than the page")
                Diagnostics.shared.step(String(format: "zoom %.2f", Double(zoom)))
            }
            placeCanvases()
        }

        /// How far the pages zoom. Out, to where a whole page is in view and a little further: smaller
        /// than that there is nothing to read. In, to six times the width of the view (PDFKit's own limit
        /// of five times the page's size is little more than twice that width on a large iPad).
        private func keepZoomRange(_ view: PDFView) {
            let fit = view.scaleFactorForSizeToFit
            guard fit > 0, view.bounds.height > 100 else { return }
            var low = fit
            if let page = view.currentPage {
                let size = AskCapture.shape(of: page).size
                if size.height > 0 { low = min(fit, (view.bounds.height - 24) / size.height) }
            }
            low = max(low * 0.92, fit * 0.3)
            let high = max(fit * 6, 10)
            guard abs(low - zoomRange.low) > 0.002 || abs(high - zoomRange.high) > 0.002 else { return }
            zoomRange = (low, high)
            view.minScaleFactor = low
            view.maxScaleFactor = high
            DebugLog.write("zoom: fits at \(fit); allowed \(low) to \(high) (the view says \(view.minScaleFactor) to \(view.maxScaleFactor))")
        }

        /// The page view's scroll views lock a drag to the direction it began in, across or along: a drag
        /// that begins a little off level can then not be taken down the page. The lock is taken off, so
        /// that a zoomed-in page goes wherever the finger does.
        private func freeScrolling(in view: PDFView) {
            var queue = view.subviews
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if next is PKCanvasView || next is PageOverlay { continue }
                if let scroll = next as? UIScrollView {
                    if !freed.contains(scroll) {
                        // PDFKit puts the lock back on from time to time; each time it does, it comes
                        // off again at once.
                        freed.add(scroll)
                        DebugLog.write("scroll: a \(type(of: scroll)) \(scroll.isDirectionalLockEnabled ? "was locked to one direction at a time; it is free now" : "was free already")")
                        lockWatches.append(scroll.observe(\.isDirectionalLockEnabled, options: [.new]) { scroll, _ in
                            if scroll.isDirectionalLockEnabled { scroll.isDirectionalLockEnabled = false }
                        })
                    }
                    if scroll.isDirectionalLockEnabled { scroll.isDirectionalLockEnabled = false }
                }
                queue.append(contentsOf: next.subviews)
            }
        }

        /// Says where each page's canvas goes: over the whole page while that is not too large a canvas,
        /// and otherwise over the part of the page in view and some way round it. Never while a pen is on
        /// the canvas.
        private func placeCanvases() {
            guard let view = pdfView else { return }
            for overlay in overlays.values where !overlay.inkInUse {
                if overlay.inkScale != inkScale { overlay.inkScale = inkScale }
                let whole = overlay.bounds
                guard whole.width > 0, whole.height > 0 else { continue }
                let scale = overlay.inkScale
                if whole.width * whole.height * scale * scale <= PageOverlay.canvasRoom {
                    overlay.canvasWindow = whole
                    continue
                }
                let seen = overlay.convert(view.bounds, from: view).intersection(whole)
                // (A page out of sight keeps what it had.)
                guard !seen.isEmpty else { continue }
                // Left where it is for as long as it still holds what is in view with a little to spare.
                let now = overlay.canvasWindow
                let needed = seen.insetBy(dx: -seen.width * 0.06, dy: -seen.height * 0.06).intersection(whole)
                if !now.isNull, now != whole, now.contains(needed) { continue }
                let spare = min(0.6, max(0.12, ((PageOverlay.canvasRoom / (seen.width * seen.height * scale * scale)).squareRoot() - 1) / 2))
                overlay.canvasWindow = seen.insetBy(dx: -seen.width * spare, dy: -seen.height * spare).intersection(whole)
            }
        }

        /// The pages were scrolled. The canvases follow, once for however many steps the scrolling took
        /// since the last time.
        private func scrolled() {
            guard !placing else { return }
            placing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.placing = false
                self.placeCanvases()
                // Zoomed in far, the picture of the handwriting is of the part in view only: once that
                // part has been scrolled out of, a new picture is asked for now, not at the next look.
                if self.penLine == nil, self.rubbed == nil {
                    for overlay in self.overlays.values where overlay.window != nil && overlay.inkTrusted && !self.inkReaches(overlay) {
                        self.askInk(for: overlay)
                        self.settleInk(overlay)
                    }
                }
            }
        }

        var currentPageIndex: Int? {
            guard let view = pdfView, let page = view.currentPage else { return nil }
            return view.document?.index(for: page)
        }

        var currentPageSize: CGSize? {
            guard let page = pdfView?.currentPage else { return nil }
            return AskCapture.shape(of: page).size
        }

        func pageShape(forPage index: Int) -> AskCapture.Shape? {
            guard let page = pdfView?.document?.page(at: index) else { return nil }
            return AskCapture.shape(of: page)
        }

        func drawing(forPage index: Int) -> PKDrawing? {
            overlay(forPage: index)?.canvas.ink ?? storedDrawing(page: index)
        }

        func go(toPage index: Int) {
            guard let view = pdfView, let page = view.document?.page(at: index) else { return }
            view.go(to: page)
        }

        // MARK: PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            if let existing = overlays[page] { return existing }
            let overlay = PageOverlay(frame: .zero)
            overlay.inkScale = inkScale
            overlay.onNeedsWindow = { [weak self] in self?.scrolled() }
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            overlay.addGestureRecognizer(hover)
            overlay.quarterTurns = (((page.rotation % 360) + 360) % 360) / 90
            // On dark paper PencilKit shows ink in its dark-screen colours: black ink white.
            overlay.overrideUserInterfaceStyle = darkPaper ? .dark : .light
            overlay.setPaper(dark: darkPaper)
            let canvas = overlay.canvas
            canvas.pageIndex = view.document?.index(for: page) ?? 0
            let draw = ShapeGesture(target: self, action: #selector(drawShape(_:)))
            draw.minimumPressDuration = 0
            overlay.shapeSurface.addGestureRecognizer(draw)
            overlay.shapeDrag = draw
            let rub = ShapeGesture(target: self, action: #selector(rub(_:)))
            rub.minimumPressDuration = 0
            overlay.shapeSurface.addGestureRecognizer(rub)
            overlay.rubDrag = rub
            let pen = PenGesture(target: nil, action: nil)
            pen.onDraw = { [weak self, weak overlay] fresh, ahead in
                guard let self, let overlay else { return }
                self.penDrew(fresh, ahead: ahead, in: overlay)
            }
            pen.onDone = { [weak self, weak overlay] kept in
                guard let self, let overlay else { return }
                self.penDone(kept: kept, in: overlay)
            }
            pen.onCorrect = { [weak self, weak overlay] id, force, most in
                guard let self, let overlay else { return }
                self.penCorrected(id: id, force: force, most: most, in: overlay)
            }
            overlay.shapeSurface.addGestureRecognizer(pen)
            overlay.penDrag = pen
            overlay.watcher.onMove = { [weak self, weak overlay] from, to in
                guard let self, let overlay else { return }
                self.eraserMoved(from: from, to: to, in: overlay)
                self.showEraser(at: to, in: overlay)
            }
            overlay.watcher.onDown = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                DebugLog.write("touch: down on page \(overlay.canvas.pageIndex), \(overlay.watcher.pencil ? "pencil" : "finger"), tool \(self.choice.tool.rawValue)")
                guard overlay.canvas.isUserInteractionEnabled else { return }
                self.canvasInUse(overlay, true)
            }
            overlay.watcher.onPath = { [weak self, weak overlay] way in
                guard let self, let overlay else { return }
                self.rubByWatch(way, in: overlay)
            }
            overlay.watcher.onLift = { [weak self, weak overlay] in
                overlay?.showEraser(at: nil, radius: 0, fineness: 1)
                DebugLog.write("touch: up")
                // (An eraser that worked through the watcher's touch is done when that touch is.)
                if let self, let overlay, self.watchRubs {
                    self.watchRubs = false
                    self.rubEnded(in: overlay)
                }
            }
            overlay.watcher.onUp = { [weak self, weak overlay] in
                guard let self, let overlay, overlay.inkInUse else { return }
                self.canvasInUse(overlay, false)
            }
            configure(overlay)
            if let found, found.page == canvas.pageIndex {
                overlay.highlight(found.rects)
            }
            var start = PKDrawing()
            if let saved = storedDrawing(page: canvas.pageIndex) {
                start = saved
            } else if canvas.pageIndex == 0, ProcessInfo.processInfo.arguments.contains("-demoInk") {
                start = Self.demoDrawing()
            }
            if !start.strokes.isEmpty { canvas.drawing = start }
            canvas.ink = start
            canvas.inkBounds = start.bounds
            canvas.inkVersion = 1
            canvas.strokeCount = start.strokes.count
            canvas.delegate = self
            // (A page with nothing written on it needs no picture of its handwriting.)
            if start.strokes.isEmpty {
                overlay.inkPictureVersion = canvas.inkVersion
                overlay.inkTrusted = true
                overlay.inkEmpty = true
                overlay.inkDirtyAll = false
                settleInk(overlay)
            }
            for item in math where item.page == canvas.pageIndex {
                install(item, in: overlay)
            }
            // A finger on a mark opens its explanation, as long as fingers are not writing.
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapPage(_:)))
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            overlay.addGestureRecognizer(tap)
            picker.attach(to: overlay)
            overlays[page] = overlay
            showMarks(in: overlay)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let overlay = overlayView as? PageOverlay else { return }
            picker.left(overlay)
            // (Its handwriting is in hand already: every change was noted when it was made.)
            overlay.pagePicture.clear()
            overlay.dropInkPicture()
            overlay.dropPreviews()
            overlays[page] = nil
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            guard let overlay = canvasView.superview as? PageOverlay else { return }
            // Only a tool that works on the canvas can be at work on it. (See below.)
            guard choice.needsCanvas, canvasView.isUserInteractionEnabled else {
                Diagnostics.shared.step("canvas said a tool began with \(choice.tool.rawValue) in hand; not taken")
                return
            }
            canvasInUse(overlay, true)
        }

        /// PencilKit says a tool has finished on the canvas. That counts as the tool in hand having been
        /// used only when the tool in hand is one of PencilKit's and a touch was on the canvas.
        ///
        /// Until 0.13.0 it counted whatever was in hand. The canvas is handed the handwriting by code,
        /// at times a moment after the last line was written, and should PencilKit say "finished" for
        /// anything of that kind while the app's own eraser was in hand and set to be put down after
        /// use, the eraser was put down before it had touched the page: taken up right after writing,
        /// it was the pen again by the time it reached the paper.
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard let overlay = canvasView.superview as? PageOverlay else { return }
            guard choice.needsCanvas, overlay.inkInUse else {
                Diagnostics.shared.step("canvas said a tool ended with \(choice.tool.rawValue) in hand; not taken")
                return
            }
            canvasInUse(overlay, false)
            toolUsed()
        }

        /// A tool has done its work. One that is set to be put down after use is handed back now.
        private func toolUsed() {
            guard choice.putsDownAfterUse else { return }
            let tool = choice.tool
            Diagnostics.shared.step("\(tool.rawValue) used, put down")
            DispatchQueue.main.async { [weak self] in
                self?.controller?.onToolUsed?(tool)
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !retired, let canvas = canvasView as? PageCanvas else { return }
            // (What the app itself is putting on the canvas it has taken note of already.)
            if canvas.byCode { return }
            let drawing = canvas.drawing
            let strokes = drawing.strokes
            if choice.tool == .ai, strokes.count == canvas.strokeCount + 1, let stroke = strokes.last {
                // (For the build server, which puts a ring on the canvas by code.) What the AI pen draws
                // is a question, not handwriting. It is lifted off the canvas again and kept as a mark;
                // the canvas is changed a moment later, once PencilKit has finished telling of the stroke.
                let points = Self.points(of: stroke)
                let before = canvas.strokeCount
                DispatchQueue.main.async { [weak self, weak canvas] in
                    guard let self, let canvas else { return }
                    var drawing = canvas.drawing
                    if drawing.strokes.count == before + 1 {
                        drawing.strokes.removeLast()
                        canvas.take(drawing)
                    }
                    self.marked(points, on: canvas)
                }
                return
            }
            guard mayBeNews(from: canvas) else {
                // The app's own pen and eraser change the handwriting themselves and hand the canvas the
                // result. The canvas tells of what it was handed, sometimes a moment later, and by then
                // it may not be the newest any more: taken for a change of PencilKit's, an older state
                // told of late put the handwriting back to what it was before the last line, and that
                // line, still to be seen on the page, was not there for the eraser to find. Nothing the
                // canvas tells of is taken while nothing of PencilKit's can have changed it.
                if strokes.count != canvas.strokeCount {
                    DebugLog.write("canvas: told of \(strokes.count) lines while the page has \(canvas.strokeCount); not taken, the page's own note stands")
                    Diagnostics.shared.step("canvas told of \(strokes.count) lines, page has \(canvas.strokeCount)")
                }
                return
            }
            record(drawing, on: canvas, count: strokes.count)
        }

        // MARK: shapes

        /// Dragging with the shape tool: the shape follows the hand, and becomes ink when it lets go.
        @objc private func drawShape(_ gesture: ShapeGesture) {
            guard let overlay = gesture.view?.superview as? PageOverlay else { return }
            let point = gesture.location(in: overlay)
            // (The width the shape is seen at; its stroke is given the size that draws that wide.)
            let width = choice.penSeenWidth
            switch gesture.state {
            case .began:
                gesture.start = point
            case .changed:
                let outline = ShapeOutline.points(choice.shapeKind, from: gesture.start, to: point, lineWidth: width)
                guard !outline.isEmpty else { return }
                preview(outline, width: width, in: overlay)
            case .ended:
                overlay.shapePreview.path = nil
                guard hypot(point.x - gesture.start.x, point.y - gesture.start.y) > 4 else { return }
                let outline = ShapeOutline.points(choice.shapeKind, from: gesture.start, to: point, lineWidth: width)
                guard outline.count > 1 else { return }
                addOutline(outline, width: width, to: overlay)
                toolUsed()
            default:
                overlay.shapePreview.path = nil
            }
        }

        /// Changes a page's handwriting by code in a way that can be undone and redone. [dirty] is where
        /// on the page it changes (nil: anywhere). [live] says the change is on show already, as a shape
        /// of its own, and the picture of the handwriting may catch up when the hand rests.
        private func setDrawing(_ new: PKDrawing, on canvas: PageCanvas, undoingTo old: PKDrawing, dirty: CGRect? = nil, live: Bool = false) {
            undoManager?.registerUndo(withTarget: self) { [weak canvas] me in
                guard let canvas else { return }
                me.setDrawing(old, on: canvas, undoingTo: new, dirty: dirty)
            }
            // Noted first: the canvas tells of the change it is about to be given, and is told it is known.
            record(new, on: canvas, own: true, dirty: dirty)
            hand(new, to: canvas)
            if !live, let overlay = canvas.superview as? PageOverlay {
                // (Lines still on show as written, whose strokes this change took away, come down now.)
                if overlay.keptCount > 0 {
                    overlay.keepPreviews(ofStrokesMadeAt: Set(new.strokes.map { $0.path.creationDate }))
                }
                askInk(for: overlay)
            }
        }

        /// How many times its own size a page is shown, measured off the screen: how far apart two places
        /// of a page's overlay are in the page view.
        ///
        /// PDFKit has a figure for this (its scaleFactor), and until 0.12.0 everything drawn here was
        /// drawn as fine as that figure said. On an iPad with iPadOS 27 the figure cannot be relied on:
        /// after a quick pinch out and in again it went on saying the zoom at which the page fits the
        /// screen (0.97) while the page stood on screen nearly eight times its size, and said nothing of
        /// a change. The page and the handwriting were then drawn for the smaller size and stretched,
        /// soft, until something else had them drawn again.
        private var zoomSeen: CGFloat {
            let now = CACurrentMediaTime()
            // (Asked for with every place a pen reports; measured a few times a second at most.)
            if now - zoomMeasured.at < 0.05 { return zoomMeasured.zoom }
            var zoom = pdfView?.scaleFactor ?? 1
            if let view = pdfView {
                for overlay in overlays.values where overlay.window != nil && overlay.bounds.width > 1 {
                    let a = overlay.convert(CGPoint.zero, to: view), b = overlay.convert(CGPoint(x: 100, y: 0), to: view)
                    let length = hypot(b.x - a.x, b.y - a.y)
                    if length > 0.01, length.isFinite {
                        zoom = length / 100
                        break
                    }
                }
            }
            zoomMeasured = (zoom, now)
            return zoom
        }

        /// The canvas is told of a change the app made to a page's handwriting. Where the canvas is what
        /// shows, or a tool of PencilKit's is in hand, it is handed the handwriting at once; where the
        /// app's pictures show, it is noted to be behind (see PageCanvas.behind).
        private func hand(_ drawing: PKDrawing, to canvas: PageCanvas) {
            if !Self.eagerCanvas, !choice.needsCanvas, let overlay = canvas.superview as? PageOverlay, overlay.showsInkPicture, !overlay.inkInUse {
                canvas.behind = true
            } else {
                canvas.take(drawing)
            }
        }

        /// How many pixels a point of the page takes on screen now, for shapes drawn over the page.
        private var fineness: CGFloat {
            guard let view = pdfView else { return 2 }
            return min(64, max(1, zoomSeen) * view.traitCollection.displayScale)
        }

        // MARK: the app's own pen

        /// The pen moved: the line grows by the places it has been, and is shown at once.
        private func penDrew(_ fresh: [PenSample], ahead: [PenSample], in overlay: PageOverlay) {
            guard !retired, choice.ownPen else { return }
            if penLine == nil {
                let zoom = max(zoomSeen, 0.5)
                DebugLog.write(String(format: "pen: down with %@ at zoom %.2f", choice.tool.rawValue, Double(zoom)))
                straight = nil
                shaped = nil
                joints = []
                heldLooked = -1
                hold = HoldWatch()
                penTool = choice.tool
                penGrid = Self.pixelGrid(of: overlay.inkPicture, scale: fineness)
                switch penTool {
                case .highlighter:
                    // (A wide line needs its points no nearer than a twentieth of its width: the line is
                    // the same to the eye, and has a third or less of the points to keep, draw and store.)
                    let apart = InkPaint.oldHighlighter ? 0.5 / zoom : max(0.5 / zoom, min(1, choice.highlighterSeenWidth * 0.05))
                    penLine = PenLine(width: choice.highlighterSeenWidth, sense: 0, steady: CGFloat(choice.penSteady), spacing: apart)
                case .ai:
                    penLine = PenLine(width: 2.4, sense: 0, steady: 0, spacing: 0.5 / zoom)
                default:
                    penLine = PenLine(
                        width: choice.penSeenWidth, sense: choice.appPenSense, steady: CGFloat(choice.penSteady), spacing: 0.5 / zoom,
                        taper: choice.appPenTaper, flow: choice.appPenFlow, zoom: zoom, curve: choice.appPenCurve, dash: choice.appPenDash
                    )
                }
            }
            if let last = fresh.last {
                // (Whether the pen is being held still is told on screen, not on the page: see HoldWatch.)
                let zoom = max(zoomSeen, 0.1)
                penAt = last.point
                hold.moved(to: CGPoint(x: last.point.x * zoom, y: last.point.y * zoom), at: CACurrentMediaTime())
            }
            if penOverlay !== overlay || holdTimer == nil {
                penOverlay = overlay
                watchHold()
            }
            // A highlighter set to draw straight is straight from the first place it lands on.
            if straight == nil, shaped == nil, penTool == .highlighter, choice.highlighterStraight, let first = fresh.first, penLine?.points.isEmpty ?? false {
                straight = (first.point, choice.highlighterSeenWidth, false)
            }
            if straight != nil {
                // Made straight already: its far end follows the pen.
                showStraight(in: overlay)
                return
            }
            // Made a shape already: the shape stays as it is until the pen lifts.
            if shaped != nil { return }
            for sample in fresh { penLine?.add(sample) }
            if let line = penLine {
                // (A dashed line is not drawn ahead of the pen: what is ahead may fall in a gap.)
                overlay.drawLive(line, ahead: line.dash == nil ? ahead : [], color: liveColor(penTool), fineness: fineness, grid: penGrid, under: penTool == .highlighter)
            }
        }

        /// The pencil made good a force it had guessed at. Where that changes the part of the line that
        /// is not settled yet, the line is shown again.
        private func penCorrected(id: Int, force: CGFloat, most: CGFloat, in overlay: PageOverlay) {
            guard straight == nil, shaped == nil, var line = penLine else { return }
            let changed = line.correct(id: id, force: force, most: most)
            penLine = line
            if changed {
                overlay.drawLive(line, ahead: [], color: liveColor(penTool), fineness: fineness, grid: penGrid, under: penTool == .highlighter)
            }
        }

        // MARK: draw and hold

        /// Looks several times a second, while a line is being written, whether the pen has come to rest.
        /// (A pen that is held still tells nothing, so there is nothing else to hear it from.)
        private func watchHold() {
            holdTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.lookAtHold()
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func lookAtHold() {
            guard let line = penLine, let overlay = penOverlay else {
                holdTimer?.invalidate()
                holdTimer = nil
                return
            }
            guard straight == nil, shaped == nil, choice.holdStraight, penTool == .pen || penTool == .highlighter, hold.held(at: CACurrentMediaTime()) else { return }
            guard line.points.count != heldLooked, let first = line.points.first else { return }
            heldLooked = line.points.count
            let zoom = max(zoomSeen, 0.1)
            let drawn = line.points + [penAt]
            // Long enough on screen to be a line and not a dot with a pause after it; and near enough
            // straight to have been meant as one.
            if hypot(penAt.x - first.x, penAt.y - first.y) * zoom >= Straighten.shortest, Straighten.isLine(drawn) {
                let width = line.widths.isEmpty ? line.width : line.widths.reduce(0, +) / CGFloat(line.widths.count)
                // (It begins on the end of another straight line it began near.)
                joints = lineEnds(on: overlay.canvas, atLeast: Straighten.shortest / zoom)
                let from = Straighten.joined(first, to: joints, reach: Straighten.joinReach / zoom) ?? first
                straight = (from, width, false)
                DebugLog.write(String(
                    format: "pen: held still, a line of %d points made straight (it bent %.2f points at most)%@",
                    line.points.count, Double(Straighten.bend(drawn)), from == first ? "" : "; it begins on the end of another line"
                ))
                Diagnostics.shared.step("line made straight")
                showStraight(in: overlay)
                overlay.flash(from: from, to: penAt, width: width, fineness: fineness)
                tapHand(at: penAt, in: overlay, finished: true)
                return
            }
            // Not a line. With the pen, a line that comes round to where it began and is a triangle, a
            // rectangle, a circle or an oval as a hand draws one becomes that shape, drawn true.
            guard penTool == .pen, let shape = ShapeFinder.find(drawn) else { return }
            let outline = ShapeFinder.outline(shape)
            guard let start = outline.first else { return }
            var box = CGRect(origin: start, size: .zero)
            for place in outline { box = box.union(CGRect(origin: place, size: .zero)) }
            // (Not a letter with a pause after it: "o", "ㅁ".)
            guard max(box.width, box.height) * zoom >= Straighten.shortest * 1.2 else { return }
            shaped = outline
            overlay.dropLive()
            preview(outline, width: choice.penSeenWidth, in: overlay)
            DebugLog.write(String(
                format: "pen: held still, a line of %d points made %@, %.0f by %.0f points",
                line.points.count, ShapeFinder.name(shape), Double(box.width), Double(box.height)
            ))
            Diagnostics.shared.step("line made a shape")
            tapHand(at: penAt, in: overlay, finished: true)
        }

        /// The ends of the straight lines among a page's handwriting that are at least [long]: the last
        /// few hundred lines written are looked at.
        private func lineEnds(on canvas: PageCanvas, atLeast long: CGFloat) -> [CGPoint] {
            var ends: [CGPoint] = []
            for stroke in canvas.ink.strokes.suffix(400) {
                let path = stroke.path
                guard path.count > 1 else { continue }
                let last = CGFloat(path.count - 1)
                var along: [CGPoint] = []
                for part in 0...8 { along.append(path.interpolatedLocation(at: last * CGFloat(part) / 8)) }
                guard let a = along.first, let b = along.last, hypot(b.x - a.x, b.y - a.y) >= long, Straighten.isLine(along) else { continue }
                ends.append(a.applying(stroke.transform))
                ends.append(b.applying(stroke.transform))
            }
            return ends
        }

        /// Shows an outline over the page as the line it will be: a shape being dragged out, or one a
        /// line drawn by hand has just been made.
        private func preview(_ outline: [CGPoint], width: CGFloat, in overlay: PageOverlay) {
            guard let first = outline.first else {
                overlay.shapePreview.path = nil
                return
            }
            let path = UIBezierPath()
            path.move(to: first)
            for next in outline.dropFirst() { path.addLine(to: next) }
            overlay.shapePreview.path = path.cgPath
            overlay.shapePreview.lineWidth = width
            overlay.shapePreview.contentsScale = fineness
            overlay.shapePreview.strokeColor = (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor
            if let dash = choice.appPenDash {
                overlay.shapePreview.lineDashPattern = [NSNumber(value: Double(max(dash.on, 0.01))), NSNumber(value: Double(dash.off))]
            } else {
                overlay.shapePreview.lineDashPattern = nil
            }
        }

        /// An outline becomes a line of the page's handwriting, of the pen's colour and [width] wide.
        private func addOutline(_ drawn: [CGPoint], width: CGFloat, to overlay: PageOverlay) {
            guard drawn.count > 1 else { return }
            var outline = drawn
            var widths = [CGFloat](repeating: width, count: outline.count)
            if let dash = choice.appPenDash {
                // In dashes or dots, as the pen writes: the outline is first given places close together,
                // so that the dashes end where they should whatever the zoom they are looked at in.
                var fine: [CGPoint] = [drawn[0]]
                var along: [CGFloat] = [0]
                for place in drawn.dropFirst() {
                    guard let last = fine.last, let gone = along.last else { continue }
                    let length = hypot(place.x - last.x, place.y - last.y)
                    guard length > 0.0001 else { continue }
                    let parts = max(1, Int((length / 0.5).rounded(.up)))
                    for part in 1...parts {
                        let share = CGFloat(part) / CGFloat(parts)
                        fine.append(CGPoint(x: last.x + (place.x - last.x) * share, y: last.y + (place.y - last.y) * share))
                        along.append(gone + length * share)
                    }
                }
                let cut = dash.cut(points: fine, widths: [CGFloat](repeating: width, count: fine.count), along: along)
                guard cut.points.count > 1 else { return }
                outline = cut.points
                widths = cut.widths
            }
            var times: [TimeInterval] = []
            for index in outline.indices { times.append(Double(index) * 0.004) }
            let points = PenLine.control(points: outline, widths: widths, times: times)
            let stroke = PKStroke(ink: PKInk(.monoline, color: choice.penUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date()))
            var drawing = overlay.canvas.ink
            let before = drawing
            drawing.strokes.append(stroke)
            setDrawing(drawing, on: overlay.canvas, undoingTo: before, dirty: stroke.renderBounds.insetBy(dx: -2, dy: -2), live: true)
            // The shape as it was shown stays on show until the picture of the handwriting has it.
            overlay.keep(
                points: outline, width: width, widths: widths, color: (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor,
                fineness: fineness, grid: Self.pixelGrid(of: overlay.inkPicture, scale: fineness),
                for: overlay.canvas.inkVersion, date: stroke.path.creationDate
            )
        }

        /// The straight line from where the line began to where the pen is, drawn to a direction when it
        /// is near one. It takes the place of the line being written.
        private func showStraight(in overlay: PageOverlay) {
            guard let made = straight else { return }
            var end = Straighten.end(from: made.from, to: penAt)
            let zoom = max(zoomSeen, 0.5)
            // An end near the end of another straight line is put on it, before any direction.
            if let joint = Straighten.joined(penAt, to: joints, reach: Straighten.joinReach / zoom),
               hypot(joint.x - made.from.x, joint.y - made.from.y) * zoom >= Straighten.shortest {
                end = (joint, true, Straighten.end(from: made.from, to: joint).degrees)
                endJoined = true
            } else {
                endJoined = false
            }
            // (A fountain pen's line keeps its pointed ends when it is made straight.)
            // (A highlighter's line has its points as far apart as any line of the highlighter's.)
            let apart = penTool == .highlighter ? max(0.5 / zoom, min(1, made.width * 0.05)) : 0.5 / zoom
            var line = PenLine(
                width: made.width, sense: 0, steady: 0, spacing: apart,
                taper: penTool == .pen ? choice.appPenTaper : 0, flow: 0, zoom: zoom, dash: penTool == .pen ? choice.appPenDash : nil
            )
            let length = hypot(end.point.x - made.from.x, end.point.y - made.from.y)
            let steps = max(2, min(240, Int(length / 3)))
            for step in 0...steps {
                let along = CGFloat(step) / CGFloat(steps)
                line.add(PenSample(
                    point: CGPoint(x: made.from.x + (end.point.x - made.from.x) * along, y: made.from.y + (end.point.y - made.from.y) * along),
                    force: 0, time: Double(step) * 0.004
                ))
            }
            penLine = line
            overlay.drawLive(line, ahead: [], color: liveColor(penTool), fineness: fineness, grid: penGrid, under: penTool == .highlighter, afresh: true)
            if end.snapped, !made.snapped { tapHand(at: end.point, in: overlay, finished: false) }
            straight?.snapped = end.snapped
        }

        /// A tap through the pencil, where the pencil can give one: a line was made straight, or was
        /// drawn to a direction.
        private func tapHand(at point: CGPoint, in overlay: PageOverlay, finished: Bool) {
            guard let view = pdfView else { return }
            if #available(iOS 18.0, *) {
                let feedback = (canvasFeedback as? UICanvasFeedbackGenerator) ?? UICanvasFeedbackGenerator(view: view)
                canvasFeedback = feedback
                let place = overlay.convert(point, to: view)
                if finished {
                    feedback.pathCompleted(at: place)
                } else {
                    feedback.alignmentOccurred(at: place)
                }
            }
        }

        /// The pen lifted. The line becomes a stroke of the page's handwriting like any other; the AI
        /// pen's becomes a question.
        private func penDone(kept: Bool, in overlay: PageOverlay) {
            guard let line = penLine else { return }
            DebugLog.write("pen: up, \(line.points.count) points, \(kept ? "kept" : "let go")\(straight != nil ? ", made straight" : "")\(shaped != nil ? ", made a shape" : "")")
            penLine = nil
            holdTimer?.invalidate()
            holdTimer = nil
            if let made = straight, kept, let first = line.points.first, let last = line.points.last {
                let lies = Straighten.end(from: first, to: last)
                DebugLog.write(String(
                    format: "pen: a straight line written, %d points from (%.1f, %.1f) to (%.1f, %.1f), at %.1f degrees%@, %.2f wide, bending %.3f points at most",
                    line.points.count, Double(first.x), Double(first.y), Double(last.x), Double(last.y), Double(lies.degrees),
                    endJoined ? " (its end put on the end of another line)" : made.snapped ? " (drawn to that direction)" : "",
                    Double(made.width), Double(Straighten.bend(line.points))
                ))
            }
            straight = nil
            joints = []
            endJoined = false
            if let outline = shaped {
                // The shape the line was made, as it is shown, is what is written.
                shaped = nil
                overlay.shapePreview.path = nil
                overlay.dropLive()
                guard kept, !retired else { return }
                addOutline(outline, width: choice.penSeenWidth, to: overlay)
                DebugLog.write("pen: a shape written, \(outline.count) points round")
                return
            }
            guard kept, !retired else {
                overlay.dropLive()
                return
            }
            switch penTool {
            case .ai:
                var whole = line
                whole.finish()
                overlay.dropLive()
                // (A few page points apart is as fine as a mark is kept.)
                var points: [CGPoint] = []
                for point in whole.points {
                    if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 2.5 { continue }
                    points.append(point)
                }
                if let end = whole.points.last, let last = points.last, end != last { points.append(end) }
                marked(points, on: overlay.canvas)
            case .highlighter:
                commit(line, in: overlay, tool: .highlighter)
                toolUsed()
            default:
                commit(line, in: overlay, tool: .pen)
            }
        }

        /// The colour a line of the app's own is shown in while it is written.
        private func liveColor(_ tool: InkTool) -> CGColor {
            switch tool {
            case .highlighter: return (darkPaper ? choice.highlighterUIColor.onDarkPaper : choice.highlighterUIColor).cgColor
            case .ai: return InkChoice.markColor.cgColor
            default: return (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor
            }
        }

        private func commit(_ written: PenLine, in overlay: PageOverlay, tool: InkTool = .pen) {
            var line = written
            line.finish()
            let high = tool == .highlighter
            // The highlighter's stroke is a plain line in a see-through colour.
            let color = high ? choice.highlighterUIColor.withAlphaComponent(InkChoice.highlighterStrength) : choice.penUIColor
            guard let stroke = line.stroke(color: color) else {
                overlay.dropLive()
                return
            }
            // (A line with pointed ends was given its end just now, as the pen lifted: it is shown anew.)
            overlay.drawLive(
                line, ahead: [], color: liveColor(tool), fineness: fineness, grid: Self.pixelGrid(of: overlay.inkPicture, scale: fineness),
                under: high, afresh: line.taper > 0, from: line.reshapedFrom
            )
            let canvas = overlay.canvas
            var drawing = canvas.ink
            let before = drawing
            drawing.strokes.append(stroke)
            setDrawing(drawing, on: canvas, undoingTo: before, dirty: stroke.renderBounds.insetBy(dx: -2, dy: -2), live: true)
            overlay.keepLive(for: canvas.inkVersion, date: stroke.path.creationDate)
            // (Written without a pause for a long while: the picture catches up now and then all the same.)
            if overlay.keptCount > 24 { askInk(for: overlay) }
        }

        /// For the build server: a line written and one being written, the pen still down, so that
        /// the picture taken shows a line as it is on show while it grows.
        func demoLive() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            for (row, lifts) in [(0.0, true), (1.0, false)] {
                var x = 80.0
                while x < 480 {
                    var chunk: [PenSample] = []
                    for _ in 0..<4 {
                        chunk.append(PenSample(point: CGPoint(x: x, y: 380 + row * 40 + 16 * sin(x / 24)), force: CGFloat(0.4 + 0.5 * abs(sin(x / 60))), time: x / 300))
                        x += 2
                    }
                    penDrew(chunk, ahead: [], in: overlay)
                }
                if lifts { penDone(kept: true, in: overlay) }
            }
            DebugLog.write("pen: a line written and one left being written; \(overlay.keptCount) waiting as shapes")
        }

        /// For the build server: shapes drawn by a shaky hand with the pen held still at the end of each,
        /// as draw and hold has them made true; a line that is no shape; and two straight lines, the
        /// second ending near the end of the first.
        func demoHeldShapes() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func line(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
                var places: [CGPoint] = []
                for step in 0...40 {
                    let along = CGFloat(step) / 40
                    places.append(point(a.x + (b.x - a.x) * along, a.y + (b.y - a.y) * along + 1.5 * sin(along * 17)))
                }
                return places
            }
            var wave: [CGPoint] = []
            for step in 0..<70 {
                let along = CGFloat(step)
                wave.append(point(70 + 3 * along, 450 + 22 * sin(along / 6)))
            }
            let drawings: [[CGPoint]] = [
                HandDrawn.walk([point(70, 130), point(250, 136), point(246, 236), point(73, 230)], short: 0.08),
                HandDrawn.walk([point(320, 240), point(500, 236), point(405, 120)], short: 0.05),
                HandDrawn.oval(center: point(150, 340), a: 62, b: 58, over: 0.04),
                HandDrawn.oval(center: point(400, 340), a: 100, b: 42, degrees: 25),
                wave,
                line(from: point(80, 520), to: point(300, 560)),
                line(from: point(420, 680), to: point(302, 561)),
            ]
            choice.tool = .pen
            func write(_ index: Int) {
                guard index < drawings.count else {
                    DebugLog.write("pen: the shapes held are written; the page has \(overlay.canvas.strokeCount) lines")
                    return
                }
                var chunk: [PenSample] = []
                for (step, place) in drawings[index].enumerated() {
                    chunk.append(PenSample(point: place, force: 0.5, time: Double(step) * 0.004))
                    if chunk.count == 4 {
                        self.penDrew(chunk, ahead: [], in: overlay)
                        chunk = []
                    }
                }
                if !chunk.isEmpty { self.penDrew(chunk, ahead: [], in: overlay) }
                // (The pen rests where it is for longer than the hold takes, then lifts.)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.penDone(kept: true, in: overlay)
                    write(index + 1)
                }
            }
            write(0)
        }

        /// For the build server: how PencilKit itself draws a stroke that runs straight across the page at
        /// [y] (PencilKit draws the handwriting of an exported file, and what the AI is shown): how many
        /// stretches of ink a row of pixels along the stroke's middle has, and how long they and the gaps
        /// between them are on the whole, in page points.
        private func inkRuns(of stroke: PKStroke, y: CGFloat) -> (count: Int, long: CGFloat, apart: CGFloat) {
            let rect = CGRect(x: 50, y: y - 2, width: 380, height: 4)
            let scale: CGFloat = 4
            var made: CGImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                made = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale).cgImage
            }
            guard let image = made, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (0, 0, 0) }
            let width = image.width, height = image.height
            guard width > 0, height > 0, let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return (0, 0, 0) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return (0, 0, 0) }
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            let row = height / 2
            var count = 0, ink = 0, gaps = 0, gapCount = 0, gap = 0
            var inRun = false
            for x in 0..<width {
                let alpha = bytes[row * context.bytesPerRow + x * 4 + 3]
                if alpha > 100 {
                    if !inRun {
                        inRun = true
                        count += 1
                        if count > 1 {
                            gaps += gap
                            gapCount += 1
                        }
                    }
                    ink += 1
                    gap = 0
                } else {
                    inRun = false
                    gap += 1
                }
            }
            return (count, CGFloat(ink) / CGFloat(max(count, 1)) / scale, CGFloat(gaps) / CGFloat(max(gapCount, 1)) / scale)
        }

        /// For the build server: lines in dashes and in dots, straight and waved, with the ballpoint and
        /// with the fountain pen pressed harder in the middle; and two lines of the brush. What became of
        /// each is read back from the page's handwriting and told in the app's notes.
        func demoDashes() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let saved = choice
            func write(_ y: CGFloat, _ kind: PenKind, _ stroke: PenStroke, wave: CGFloat, pressed: Bool) {
                choice.tool = .pen
                choice.penKind = kind
                choice.penStroke = stroke
                var chunk: [PenSample] = []
                var x: CGFloat = 60
                while x <= 420 {
                    let along = (x - 60) / 360
                    let force: CGFloat = pressed ? 0.3 + 3.2 * sin(CGFloat.pi * along) : 1
                    chunk.append(PenSample(point: CGPoint(x: x, y: y + wave * sin(x / 22)), force: force, time: Double(x) / 300, most: PenLine.fullForce))
                    x += 2
                    if chunk.count == 4 {
                        penDrew(chunk, ahead: [], in: overlay)
                        chunk = []
                    }
                }
                if !chunk.isEmpty { penDrew(chunk, ahead: [], in: overlay) }
                penDone(kept: true, in: overlay)
            }
            let before = overlay.canvas.ink.strokes.count
            write(130, .ball, .dashed, wave: 0, pressed: false)
            write(165, .ball, .dotted, wave: 0, pressed: false)
            write(215, .ball, .dashed, wave: 14, pressed: false)
            write(275, .ball, .dotted, wave: 14, pressed: false)
            write(335, .fountain, .dashed, wave: 10, pressed: true)
            write(395, .brush, .solid, wave: 10, pressed: true)
            write(445, .brush, .solid, wave: 0, pressed: true)
            choice = saved
            // What the page's handwriting has of them: how many dashes each line is, and how long they
            // and the gaps between them are along the line.
            for (number, stroke) in overlay.canvas.ink.strokes.dropFirst(before).enumerated() {
                let line = InkPaint.line(of: stroke, step: 0.3)
                var dashes = 0, longest: CGFloat = 0, shortest = CGFloat.infinity, gaps: CGFloat = 0, gapCount = 0
                var run: CGFloat = 0
                var inRun = false
                var thin = CGFloat.infinity, wide: CGFloat = 0
                for index in line.points.indices {
                    let inked = line.widths[index] > 0
                    if inked {
                        thin = min(thin, line.widths[index])
                        wide = max(wide, line.widths[index])
                    }
                    if inked, inRun, index > 0 {
                        run += hypot(line.points[index].x - line.points[index - 1].x, line.points[index].y - line.points[index - 1].y)
                    } else if inked {
                        if index > 0, dashes > 0 {
                            gaps += hypot(line.points[index].x - line.points[index - 1].x, line.points[index].y - line.points[index - 1].y)
                            gapCount += 1
                        }
                        inRun = true
                        run = 0
                    } else if inRun {
                        inRun = false
                        dashes += 1
                        longest = max(longest, run)
                        shortest = min(shortest, run)
                    }
                }
                if inRun {
                    dashes += 1
                    longest = max(longest, run)
                }
                DebugLog.write(String(
                    format: "dashes: line %d is %d dashes, %.2f to %.2f points long, %.2f apart on the whole; %.2f to %.2f wide; %d points",
                    number + 1, dashes, Double(shortest.isFinite ? shortest : longest), Double(longest),
                    Double(gapCount > 0 ? gaps / CGFloat(gapCount) : 0), Double(thin.isFinite ? thin : 0), Double(wide), line.points.count
                ))
                // (The first two lines run straight across, at these heights.)
                if number < 2 {
                    let seen = inkRuns(of: stroke, y: number == 0 ? 130 : 165)
                    DebugLog.write(String(
                        format: "dashes: PencilKit draws line %d as %d stretches of ink, %.2f points long and %.2f apart on the whole",
                        number + 1, seen.count, Double(seen.long), Double(seen.apart)
                    ))
                }
            }
        }

        /// For the build server: forty lines of highlighter written one after another the way a pen
        /// writes them (a few places at a time, the screen brought up to date after each), and how long
        /// the main thread took over them. Run once as the highlighter is now and once as it was
        /// ("-demoOldHighlighter"), the two times stand side by side in the app's notes.
        func demoHighlightMany() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let saved = choice
            let lines = 40
            // ("-demoManyTool pen": with the pen, the lines one over another as in a scribble.)
            let scribble = UserDefaults.standard.string(forKey: "demoManyTool") == "pen"
            var total = 0.0, worst = 0.0, points = 0
            // (What writing a line took and what lifting the pen took, for the first ten lines and the last ten.)
            var writing = [0.0, 0.0], lifting = [0.0, 0.0]
            for row in 0..<lines {
                choice.tool = scribble ? .pen : .highlighter
                let y = scribble ? 300 + CGFloat(row % 8) * 4 : 150 + CGFloat(row % 20) * 28 + CGFloat(row / 20) * 9
                let swing: CGFloat = scribble ? 22 : 3
                var time = Double(row)
                var x: CGFloat = 60
                let began = CACurrentMediaTime()
                while x < 520 {
                    var chunk: [PenSample] = []
                    for _ in 0..<4 {
                        chunk.append(PenSample(point: CGPoint(x: x, y: y + sin(x / 30 + CGFloat(row)) * swing), force: 1, time: time))
                        x += 1.5
                        time += 0.004
                    }
                    penDrew(chunk, ahead: [], in: overlay)
                    CATransaction.flush()
                }
                points += penLine?.points.count ?? 0
                let written = CACurrentMediaTime()
                penDone(kept: true, in: overlay)
                CATransaction.flush()
                let took = (CACurrentMediaTime() - began) * 1000
                total += took
                worst = max(worst, took)
                if row < 10 || row >= lines - 10 {
                    writing[row < 10 ? 0 : 1] += (written - began) * 100
                    lifting[row < 10 ? 0 : 1] += (CACurrentMediaTime() - written) * 100
                }
                // (Told as it goes: zoomed in, on the build server, forty lines can take longer than the
                // picture waits for, and nothing was known of a run that did not end.)
                if (row + 1) % 5 == 0 {
                    DebugLog.write(String(
                        format: "many lines: %d written so far %@ at %.2f pixels a point; the main thread took %.0f ms, the last one %.0f ms (%.0f ms of it when the pen lifted)",
                        row + 1, scribble ? (Self.eagerCanvas ? "with the pen, the canvas handed every line" : Self.oldWaiting ? "with the pen, the waiting tiles drawing themselves" : "with the pen") : "with the highlighter",
                        Double(fineness), total, took, (CACurrentMediaTime() - written) * 1000
                    ))
                }
            }
            choice = saved
            DebugLog.write(String(
                format: "highlighter: %d lines written %@ at %.2f pixels a point, %d points in all; the main thread took %.0f ms, %.1f ms a line, %.1f ms the slowest; %d lines waiting as shapes",
                lines, scribble ? (Self.eagerCanvas ? "with the pen, the canvas handed every line" : Self.oldWaiting ? "with the pen, the waiting tiles drawing themselves" : "with the pen") : (InkPaint.oldHighlighter ? "the old way" : "the new way"),
                Double(fineness), points, total, total / Double(lines), worst, overlay.keptCount
            ))
            DebugLog.write(String(
                format: "highlighter: a line of the first ten took %.1f ms to write and %.1f ms when the pen lifted; of the last ten, %.1f ms and %.1f ms",
                writing[0], lifting[0], writing[1], lifting[1]
            ))
        }

        /// For the build server: a line of highlighter; the same shaky line twice, pressed harder in the
        /// middle, once as the hand made it and once steadied; and straight lines of known widths, to set
        /// the shapes shown while writing beside the strokes they become.
        func demoPen() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            var points: [PKStrokePoint] = []
            for step in 0...60 {
                let place = CGPoint(x: 300 + 3.4 * Double(step), y: 628 + 1.5 * Double(step))
                points.append(PKStrokePoint(
                    location: place, timeOffset: Double(step) * 0.01, size: CGSize(width: 14, height: 14),
                    opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                ))
            }
            let marker = PKStroke(ink: PKInk(.marker, color: choice.highlighterUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date()))
            var drawing = overlay.canvas.ink
            let before = drawing
            drawing.strokes.append(marker)
            setDrawing(drawing, on: overlay.canvas, undoingTo: before)
            // The highlighter as it writes now, over the sample's first lines of text and across itself.
            for (from, to) in [(CGPoint(x: 60, y: 226), CGPoint(x: 420, y: 226)), (CGPoint(x: 200, y: 214), CGPoint(x: 330, y: 250))] {
                var line = PenLine(width: choice.highlighterSeenWidth, sense: 0, steady: 0)
                for step in 0...60 {
                    let along = CGFloat(step) / 60
                    line.add(PenSample(point: CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along), force: 1, time: Double(step) / 240))
                }
                commit(line, in: overlay, tool: .highlighter)
            }
            for (row, steady) in [(0.0, CGFloat(0)), (1.0, CGFloat(0.9))] {
                var line = PenLine(width: 1.4, sense: 1, steady: steady)
                for step in 0...240 {
                    let along = Double(step) / 240
                    let shake = 2.2 * sin(Double(step) * 1.9) + 1.4 * cos(Double(step) * 3.1)
                    let point = CGPoint(x: 70 + 440 * along, y: 540 + row * 52 + 14 * sin(along * 2 * Double.pi) + shake)
                    line.add(PenSample(point: point, force: CGFloat(0.25 + 2.2 * sin(along * Double.pi)), time: Double(step) / 240))
                }
                commit(line, in: overlay)
                DebugLog.write("pen: a line of \(line.points.count) points written, steadied \(steady)")
            }
            // Rings written fast: the pen was heard from only a dozen times on the way round, and the line
            // has to come out round all the same, not as a dozen straight sides.
            for (column, heard) in [8, 12, 20].enumerated() {
                var line = PenLine(width: 1.6, sense: 1, steady: 0)
                for step in 0...heard {
                    let angle = 2 * Double.pi * Double(step) / Double(heard)
                    let point = CGPoint(x: 120 + 110 * Double(column) + 36 * cos(angle), y: 470 + 30 * sin(angle))
                    line.add(PenSample(point: point, force: CGFloat(0.6 + 0.8 * abs(sin(angle))), time: Double(step) / 240))
                }
                commit(line, in: overlay)
            }
            // The fountain pen: the same hook written slowly and fast, with ends as pointed as they are
            // set to begin with and with ends fully pointed; and dots, which have no ends to point.
            for (column, (pace, taper)) in [(1.0, 0.3), (5.0, 0.3), (1.0, 1.0), (5.0, 1.0)].enumerated() {
                var line = PenLine(width: 2.2, sense: 0.5, steady: 0, spacing: 0.3, taper: CGFloat(taper), flow: 0.35, zoom: 1.36)
                let left = 300 + 56 * Double(column)
                for step in 0...90 {
                    let along = Double(step) / 90
                    let point = CGPoint(x: left + 34 * along + 10 * sin(along * 3 * Double.pi), y: 640 + 70 * along * along)
                    line.add(PenSample(point: point, force: CGFloat(0.5 + 0.5 * sin(along * Double.pi)), time: Double(step) / (60 * pace)))
                }
                commit(line, in: overlay)
                var dot = PenLine(width: 2.2, sense: 0.5, steady: 0, spacing: 0.3, taper: CGFloat(taper), flow: 0.35, zoom: 1.36)
                dot.add(PenSample(point: CGPoint(x: left + 20, y: 730), force: 0.8, time: 0))
                commit(dot, in: overlay)
            }
            for (row, width) in [0.4, 1.0, 2.0, 4.0, 8.0].enumerated() {
                var line = PenLine(width: CGFloat(width), sense: 0, steady: 0)
                for step in 0...40 {
                    line.add(PenSample(point: CGPoint(x: 70 + 5 * Double(step), y: 640 + 22 * Double(row)), force: 1, time: Double(step) / 240))
                }
                commit(line, in: overlay)
            }
        }

        /// For the build server: a solid block of ink, for measuring how wide a swath an eraser takes.
        func demoBlock() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            var drawing = overlay.canvas.ink
            let before = drawing
            let size = InkWidth.size(drawing: 8)
            for row in 0..<34 {
                var points: [PKStrokePoint] = []
                for step in 0...42 {
                    points.append(PKStrokePoint(
                        location: CGPoint(x: 80 + 10 * Double(step), y: 80 + 6 * Double(row)), timeOffset: Double(step) * 0.008,
                        size: CGSize(width: size, height: size), opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                    ))
                }
                drawing.strokes.append(PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
            setDrawing(drawing, on: overlay.canvas, undoingTo: before)
        }

        /// For the build server: a page full of handwriting, to see what a full page costs the pen.
        func demoDense(_ count: Int) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            var drawing = overlay.canvas.ink
            let before = drawing
            guard before.strokes.count < count else { return }
            let size = InkWidth.size(drawing: 1)
            for index in 0..<count {
                let left = 50 + Double(index % 20) * 25, top = 60 + Double(index / 20) * 30
                var points: [PKStrokePoint] = []
                for step in 0...14 {
                    let place = CGPoint(x: left + Double(step) * 1.4, y: top + 7 * sin(Double(step) * 0.9 + Double(index)))
                    points.append(PKStrokePoint(
                        location: place, timeOffset: Double(step) * 0.008, size: CGSize(width: size, height: size),
                        opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                    ))
                }
                drawing.strokes.append(PKStroke(ink: PKInk(.monoline, color: choice.penUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
            setDrawing(drawing, on: overlay.canvas, undoingTo: before)
            DebugLog.write("feel: a page of \(drawing.strokes.count) lines laid down")
        }

        func clearPage() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let before = overlay.canvas.ink
            guard !before.strokes.isEmpty else { return }
            setDrawing(PKDrawing(), on: overlay.canvas, undoingTo: before)
        }

        // MARK: the eraser

        /// How much of the page the eraser in hand rubs out round its middle, in page points; nil when the
        /// eraser is not in hand. Every eraser is as wide as its size in points of the screen, whatever
        /// the zoom: PencilKit's eraser for part of a line is (measured on the build server: sizes of 40
        /// and 16 took 39.5 and 16 points of screen), and the app's own are made to be.
        private var eraserReach: CGFloat? {
            guard choice.tool == .eraser, pdfView != nil else { return nil }
            return CGFloat(choice.eraserWidth) / 2 / max(zoomSeen, 0.2)
        }

        /// Shows the ring of the eraser at a place on a page, while the eraser is in hand.
        private func showEraser(at place: CGPoint, in overlay: PageOverlay) {
            guard let reach = eraserReach else { return }
            overlay.showEraser(at: place, radius: reach, fineness: fineness)
        }

        /// An Apple Pencil held just above the page: the eraser's ring shows where it would rub.
        @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
            guard let overlay = gesture.view as? PageOverlay else { return }
            switch gesture.state {
            case .began, .changed:
                hoverSeen = CACurrentMediaTime()
                if eraserReach != nil {
                    showEraser(at: gesture.location(in: overlay), in: overlay)
                } else {
                    overlay.showEraser(at: nil, radius: 0, fineness: 1)
                }
            default:
                overlay.showEraser(at: nil, radius: 0, fineness: 1)
            }
        }

        /// The eraser moved over a page, from one place to the next. A mark of the AI pen that it crosses
        /// is taken off the page; its explanation stays in the list of questions.
        private func eraserMoved(from: CGPoint, to: CGPoint, in overlay: PageOverlay) {
            guard !retired, choice.tool == .eraser, choice.eraserTakesMarks, !choice.eraserHighlighterOnly else { return }
            let page = overlay.canvas.pageIndex
            // What the eraser covers, and no less than a pen's tip does on screen.
            let zoom = max(zoomSeen, 0.1)
            let reach = max(3, 11 / zoom, eraserReach ?? 0)
            for mark in marks where mark.page == page && Self.crosses(from, to, mark.points, within: reach) {
                setMark(mark.id, hidden: true)
                rubbedAny = true
            }
        }

        /// Takes a mark off the page or puts it back, in a way that can be undone and redone.
        private func setMark(_ id: UUID, hidden: Bool) {
            if hidden {
                // Off the page at once, without waiting for the screen above to hand the marks down again.
                marks.removeAll { $0.id == id }
                for overlay in overlays.values {
                    showMarks(in: overlay)
                }
                controller?.onHideMark?(id)
            } else {
                controller?.onShowMark?(id)
            }
            undoManager?.registerUndo(withTarget: self) { me in
                me.setMark(id, hidden: !hidden)
            }
            DebugLog.write(hidden ? "eraser: a mark of the AI pen taken off the page" : "undo: a mark of the AI pen put back on the page")
        }

        /// Whether a line, given as points along it, comes within [reach] of the way from [a] to [b].
        private static func crosses(_ a: CGPoint, _ b: CGPoint, _ line: [CGPoint], within reach: CGFloat) -> Bool {
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -reach, dy: -reach)
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            for point in line where box.contains(point) {
                let along = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
                if hypot(point.x - (a.x + along * dx), point.y - (a.y + along * dy)) <= reach { return true }
            }
            return false
        }

        /// Whether a stroke comes within [reach] of the way from [a] to [b].
        private static func touches(_ stroke: PKStroke, _ a: CGPoint, _ b: CGPoint, within reach: CGFloat) -> Bool {
            var line: [CGPoint] = []
            var size: CGFloat = 0
            let turn = stroke.transform
            // (Points along it no further apart than the eraser reaches, so that it cannot slip between two.)
            for part in stroke.path.interpolatedPoints(by: .distance(max(0.4, reach * 0.7))) {
                line.append(part.location.applying(turn))
                size = max(size, part.size.width)
            }
            if let end = stroke.path.last {
                line.append(end.location.applying(turn))
                size = max(size, end.size.width)
            }
            let half = (InkPaint.isPlain(stroke) ? InkWidth.width(ofSize: size) : size) / 2
            return crosses(a, b, line, within: reach + half)
        }

        /// The app's own eraser: a line it touches goes whole. It is as large as its size says, and with
        /// "highlighter only" it leaves everything but highlighter alone. One drag is one step of the
        /// undo history.
        @objc private func rub(_ gesture: ShapeGesture) {
            guard let overlay = gesture.view?.superview as? PageOverlay else { return }
            let point = gesture.location(in: overlay)
            // Every place the touch went through since the last look, and where it is now.
            var way: [CGPoint] = []
            for place in gesture.takeTrail() { way.append(overlay.convert(place, from: gesture.view)) }
            if let last = way.last {
                if hypot(last.x - point.x, last.y - point.y) > 0.01 { way.append(point) }
            } else {
                way.append(point)
            }
            let now = CACurrentMediaTime()
            switch gesture.state {
            case .began, .changed, .ended:
                // (Its own drag has a touch. An eraser that was working through the watcher's touch has
                // done its part: what it rubbed out is its own step of the undo history.)
                if watchRubs {
                    watchRubs = false
                    rubEnded(in: overlay)
                }
                if gesture.state == .began || rubbed == nil {
                    rubBegin(on: overlay.canvas, at: now)
                    gesture.start = way.first ?? point
                }
                rubAlong(way, from: gesture.start, in: overlay, at: now)
                gesture.start = point
                if gesture.state == .ended {
                    rubEnded(in: overlay)
                } else {
                    // A ring shows how much the eraser covers.
                    overlay.showEraser(at: point, radius: eraserReach ?? CGFloat(choice.eraserWidth) / 2, fineness: fineness)
                }
            default:
                rubEnded(in: overlay)
            }
        }

        /// The eraser through a touch its own drag is not following: a pencil that was on the page
        /// already when the eraser was taken up.
        ///
        /// The eraser's drag is told only of touches that land while the eraser is in hand. A pencil
        /// squeezed for the eraser and put to the page in one motion often lands a moment before the
        /// squeeze is let go, which is when the tool changes: it lands under the pen, the pen lets its
        /// line go when the tool changes under it, and until 0.13.0 nothing took the touch from there.
        /// The eraser's ring followed the pencil (the watcher draws it, and sees every touch) and rubbed
        /// nothing out, until the pencil was lifted and put down again.
        private func rubByWatch(_ way: [CGPoint], in overlay: PageOverlay) {
            guard !retired, choice.ownEraser, overlay.watcher.pencil, way.count > 1 else { return }
            if overlay.rubDrag?.tracking ?? false { return }
            let now = CACurrentMediaTime()
            if rubbed == nil {
                watchRubs = true
                rubBegin(on: overlay.canvas, at: now)
                DebugLog.write("eraser: taken up with the pencil already on the page; it rubs from where the pencil is")
                Diagnostics.shared.step("eraser took over a touch already on the page")
            }
            guard watchRubs else { return }
            rubAlong(Array(way.dropFirst()), from: way[0], in: overlay, at: now)
        }

        /// The eraser comes down: the page's lines are listed once, and the room each takes with them. As
        /// it moves, only the lines whose room it enters are looked at.
        private func rubBegin(on canvas: PageCanvas, at now: CFTimeInterval) {
            let strokes = canvas.ink.strokes
            rubbed = (strokes, strokes.map(\.renderBounds), canvas.ink, .null, strokes.count)
            DebugLog.write("eraser: down, \(strokes.count) lines on the page, \(watchRubs ? "through a touch already on the page" : "its own drag")")
            rubbedAny = false
            rubTold = (now, now, 0, 0, 0)
        }

        /// The eraser went from [start] through the places of [way]: every line it touched on the way goes.
        private func rubAlong(_ way: [CGPoint], from start: CGPoint, in overlay: PageOverlay, at now: CFTimeInterval) {
            guard var work = rubbed, !way.isEmpty else { return }
            let canvas = overlay.canvas
            let reach = eraserReach ?? CGFloat(choice.eraserWidth) / 2
            rubTold.tellings += 1
            rubTold.places += way.count
            rubTold.longest = max(rubTold.longest, now - rubTold.last)
            rubTold.last = now
            let highlighterOnly = choice.eraserHighlighterOnly
            var gone = Set<Int>()
            var from = start
            for to in way {
                let swept = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y))
                    .insetBy(dx: -reach - 1, dy: -reach - 1)
                for index in work.strokes.indices where work.boxes[index].intersects(swept) && !gone.contains(index) {
                    let stroke = work.strokes[index]
                    if highlighterOnly, !InkPaint.isHighlighter(stroke) { continue }
                    if Self.touches(stroke, from, to, within: reach) { gone.insert(index) }
                }
                from = to
            }
            guard !gone.isEmpty else { return }
            rubbedAny = true
            var dirty = CGRect.null
            for index in gone.sorted().reversed() {
                dirty = dirty.union(work.boxes[index])
                work.strokes.remove(at: index)
                work.boxes.remove(at: index)
            }
            dirty = dirty.insetBy(dx: -2, dy: -2)
            work.dirty = work.dirty.union(dirty)
            rubbed = work
            let drawing = PKDrawing(strokes: work.strokes)
            record(drawing, on: canvas, own: true, count: work.strokes.count, dirty: dirty)
            hand(drawing, to: canvas)
            // A line written a moment ago is still on show as written: rubbed out, it comes down at
            // once, without waiting for the picture.
            if overlay.keptCount > 0 {
                overlay.keepPreviews(ofStrokesMadeAt: Set(work.strokes.map { $0.path.creationDate }))
            }
            // Seen at once: the picture is brought up to date now, not when the hand rests.
            askInk(for: overlay)
        }

        /// The eraser's drag is over: what it rubbed out becomes one step of the undo history.
        private func rubEnded(in overlay: PageOverlay) {
            let canvas = overlay.canvas
            overlay.showEraser(at: nil, radius: 0, fineness: 1)
            if let work = rubbed, work.strokes.count != work.count {
                let before = work.before, after = canvas.ink, dirty = work.dirty
                undoManager?.registerUndo(withTarget: self) { [weak canvas] me in
                    guard let canvas else { return }
                    me.setDrawing(before, on: canvas, undoingTo: after, dirty: dirty)
                }
                DebugLog.write("eraser: \(work.count - work.strokes.count) \(choice.eraserHighlighterOnly ? "highlighter lines" : "lines") rubbed out, \(work.strokes.count) lines left on the page")
            } else if let work = rubbed {
                // Noted for the diagnostics: an eraser that met nothing, what there was to meet, and how
                // the drag came in (few tellings of many places, with a long wait, is an app that was busy).
                Diagnostics.shared.step(String(
                    format: "eraser met nothing: %d lines on the page, %d on show as written; %d places in %d tellings over %.0f ms, the longest wait %.0f ms",
                    work.count, overlay.keptCount, rubTold.places, rubTold.tellings, (rubTold.last - rubTold.began) * 1000, rubTold.longest * 1000
                ))
            }
            if rubbed != nil, rubTold.longest > 0.1 {
                DebugLog.write(String(format: "eraser: the app was told of the drag %.0f ms late at one point (%d places in %d tellings)", rubTold.longest * 1000, rubTold.places, rubTold.tellings))
                Diagnostics.shared.step(String(format: "eraser drag told %.0f ms late", rubTold.longest * 1000))
            }
            rubbed = nil
            // (An eraser set to be put down after use is not put down for having met nothing.)
            if rubbedAny { toolUsed() }
            rubbedAny = false
        }

        // MARK: the pages drawn sharp

        /// No more pixels than this go into one picture of a page. A page shown whole at fitting zoom is
        /// well under it on most screens; zoomed in far, only what is in view and some way round it is drawn.
        private static var pictureLimit: CGFloat { tight ? 4_500_000 : 9_000_000 }
        /// The same for a picture of a page's handwriting. It is of the whole page wherever that is not
        /// too much (on a large iPad a page at fitting zoom is nine and a half million pixels): a picture
        /// of the whole page never has to be made anew because the page was scrolled.
        private static var inkLimit: CGFloat { tight ? 4_500_000 : 13_000_000 }
        /// The system has warned that memory is short.
        private static var tight = false
        /// "-softPages" leaves the pages as PDFKit draws them, for the build server to compare against.
        /// (0.6.0 to 0.7.1 had a setting for this; the app always draws the pages itself now.)
        private static let drawsPages = !ProcessInfo.processInfo.arguments.contains("-softPages")
        /// "-demoCanvasInk" leaves the handwriting as PencilKit's canvas draws it, for the build server to
        /// compare against the app's own drawing of it.
        private static let showsCanvas = ProcessInfo.processInfo.arguments.contains("-demoCanvasInk")
        /// "-demoHoldPreviews" leaves the lines of the app's own pen on show as the shapes they are written
        /// as, with the canvas and the picture of the handwriting out of sight, for the build server to look at.
        private static let holdsPreviews = ProcessInfo.processInfo.arguments.contains("-demoHoldPreviews")

        private func startPictures() {
            guard pictureTimer == nil else { return }
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.lookAtPictures()
            }
            // In the common modes, so that it also runs while a finger is scrolling.
            RunLoop.main.add(timer, forMode: .common)
            pictureTimer = timer
        }

        /// Since when the pictures of the page in view have stood at another fineness than the zoom, with
        /// the zoom at rest; whether that has been noted; and the zoom it was measured against.
        private var lateSince: CFTimeInterval = 0
        private var lateTold = false
        private var lateScale: CGFloat = 0

        /// Notes, for the diagnostics and a test's notes, when the page in view has gone a second and a
        /// half with the zoom at rest and a picture that is not as fine as the zoom, and everything that
        /// could be holding the new picture back. (Reported from an iPad in 0.13.7: now and then the
        /// page is not drawn again after zooming. The diagnostics sent with the report were both taken
        /// with the pictures as fine as the zoom, and say nothing of why.)
        private func noteLate(in view: PDFView, now: CFTimeInterval) {
            guard let page = view.currentPage, let overlay = overlays[page], overlay.window != nil else {
                lateSince = 0
                lateTold = false
                return
            }
            let scale = zoomSeen * view.traitCollection.displayScale
            guard scale > 0 else { return }
            var late: [String] = []
            if abs(scale - lateScale) <= 0.0005 * scale {
                if Self.drawsPages {
                    let picture = overlay.pagePicture
                    if picture.gaveUp {
                        late.append("the page's picture was given up")
                    } else if let shown = picture.shown {
                        if abs(shown.scale - scale) > 0.002 * scale {
                            late.append(String(format: "the page's picture is at %.3f", Double(shown.scale)))
                        }
                    } else {
                        late.append("the page has no picture")
                    }
                }
                if overlay.canvas.strokeCount > 0 {
                    if !overlay.showsInkPicture {
                        if !choice.needsCanvas {
                            late.append(String(format: "the canvas shows the handwriting, %.3f times the page", Double(overlay.inkScale)))
                        }
                    } else if let shown = overlay.inkPicture.shown {
                        if abs(shown.scale - scale) > 0.002 * scale {
                            late.append(String(format: "the handwriting's picture is at %.3f", Double(shown.scale)))
                        }
                    } else {
                        late.append("the handwriting has no picture")
                    }
                }
            }
            lateScale = scale
            guard !late.isEmpty else {
                if lateTold {
                    let text = String(format: "pictures as fine as the zoom again, %.1f s after they fell behind", now - lateSince)
                    DebugLog.write(text)
                    Diagnostics.shared.step(text)
                }
                lateSince = 0
                lateTold = false
                return
            }
            if lateSince == 0 {
                lateSince = now
                return
            }
            guard !lateTold, now - lateSince > 1.5 else { return }
            lateTold = true
            var why: [String] = []
            if penLine != nil { why.append("a line is being written") }
            if rubbed != nil { why.append(watchRubs ? "the eraser is down, through a touch it took over" : "the eraser is down") }
            let inUse = overlays.values.filter { $0.inkInUse }.count
            if inUse > 0 {
                why.append(String(format: "%d canvases in use, this one touched %.0f s ago", inUse, now - overlay.canvasUsed))
            }
            if overlay.inkBusy { why.append(String(format: "a picture of the handwriting is being made at %.3f", Double(overlay.inkAsking))) }
            if overlay.inkLanding != nil { why.append("a picture of the handwriting waits to go up") }
            if overlay.inkPicture.gaveUp { why.append("the handwriting's picture was given up") }
            if !overlay.inkTrusted { why.append("the handwriting's picture is not trusted") }
            if let asked = overlay.pagePicture.asked {
                why.append(String(format: "the page's picture is asked for at %.3f", Double(asked.scale)))
            }
            if choice.needsCanvas { why.append("a tool of the canvas is in hand") }
            why.append(String(format: "the handwriting last changed %.1f s ago", now - overlay.inkTouched))
            why.append("\(overlay.keptCount) lines on show as written")
            let what = late.joined(separator: "; ") + " | " + why.joined(separator: "; ")
            DebugLog.write(String(format: "pictures: behind the zoom (%.3f pixels a point) for %.1f s: ", Double(scale), now - lateSince) + what)
            Diagnostics.shared.step(String(format: "pictures behind the zoom %.3f: ", Double(scale)) + what)
        }

        /// Several times a second: has every page in or near view a picture as fine as the zoom, of the
        /// part that is in view, and pictures of its handwriting as it stands? Where not, they are asked for.
        private func lookAtPictures() {
            guard let view = pdfView, view.window != nil else { return }
            picker.fit()
            // Nothing at all while a pen, an eraser or a writing finger is on a page: whatever this would
            // find to do can wait until the line is written, and the main thread is the pen's alone
            // meanwhile. (A touch that was never seen to end counts for twenty seconds and no longer.)
            let now = CACurrentMediaTime()
            noteLate(in: view, now: now)
            if penLine != nil || rubbed != nil || overlays.values.contains(where: { $0.inkInUse && now - $0.canvasUsed < 20 }) { return }
            // The pen is off the page: pictures that were ready while it was on go up now.
            for overlay in overlays.values {
                if let land = overlay.inkLanding {
                    overlay.inkLanding = nil
                    land()
                }
            }
            if scrollWatch == nil, let scroll = Self.scrollView(in: view) {
                scrollWatch = scroll.observe(\.contentOffset) { [weak self] _, _ in self?.scrolled() }
            }
            ticks += 1
            if ticks % 16 == 1 { keepZoomRange(view) }
            if ticks % 16 == 9 {
                freeScrolling(in: view)
                turner.keepBackSwipe()
            }
            placeCanvases()
            let pages = Self.drawsPages
            if ticks == 30 {
                // (Noted once for the build server. The diagnostics text asks for it when it is wanted.)
                DebugLog.write("view:\n" + describeView())
            }
            if ticks % 40 == 5, let megabytes = Diagnostics.footprint().map({ $0 / 1_048_576 }) {
                DebugLog.write("memory: \(megabytes) MB in use with \(overlays.count) pages laid out")
            }
            if !pages {
                for overlay in overlays.values where overlay.pagePicture.shown != nil || overlay.pagePicture.asked != nil {
                    overlay.pagePicture.clear()
                }
            }
            let zoom = zoomSeen
            let scale = zoom * view.traitCollection.displayScale
            guard scale > 0 else { return }
            // While the zoom is still changing nothing is drawn: it would be thrown away at once.
            if abs(scale - scaleSeen) > 0.0005 * scale {
                scaleSeen = scale
                return
            }
            // PDFKit does not always say that the zoom changed (see zoomSeen). The canvases are made as
            // fine as the zoom that is seen, whether it was said or not.
            let finest: CGFloat = Self.tight ? 1.5 : max(8, view.maxScaleFactor)
            if abs(min(finest, max(1, zoom)) - inkScale) > 0.0005 {
                if abs(zoom - view.scaleFactor) > 0.01 * zoom {
                    DebugLog.write("zoom: the pages are seen at \(zoom) times their size while PDFKit says \(view.scaleFactor)")
                    Diagnostics.shared.step(String(format: "zoom seen %.2f, PDFKit says %.2f", Double(zoom), Double(view.scaleFactor)))
                }
                settleScale()
            }
            let around = view.bounds.insetBy(dx: -view.bounds.width * 0.5, dy: -view.bounds.height * 0.6)
            for overlay in overlays.values where overlay.window != nil {
                if pages { refreshPicture(in: overlay, scale: scale, view: view) }
                if !overlay.convert(around, from: view).intersection(overlay.bounds).isEmpty {
                    // (Once the hand has rested a moment: lines written one after another are on show
                    // as their own shapes, and go into the picture together.)
                    if now - overlay.inkTouched > 0.4 { askInk(for: overlay) }
                    settleInk(overlay)
                    // The hand has rested: a canvas that is behind is handed the handwriting now, so that
                    // it has it by the time it is next seen (when the page is zoomed, say). PencilKit
                    // takes the main thread for this, a moment or (zoomed in on a full page) much longer,
                    // so it waits until the pen has been away a good while and is not held over the page.
                    // (In 0.12.3 it was done one second after the last line: just when a hand that had
                    // put the pen down for the eraser came back to the page. The eraser's first moves
                    // reached the app late and all at once.)
                    if overlay.canvas.behind, now - overlay.inkTouched > 3, now - hoverSeen > 1.5 { overlay.canvas.catchUp() }
                } else if overlay.inkPicture.shown != nil || overlay.highPicture.shown != nil {
                    // Far from view: its pictures are let go, and made again when it comes near.
                    overlay.dropInkPicture()
                    overlay.dropPreviews()
                }
            }
        }

        /// Where the screen's pixels fall in a view's own measure: the place, less than a pixel from
        /// the view's corner, where a pixel of the screen begins. PDFKit lays a page wherever the zoom
        /// puts it, which is hardly ever on a whole pixel: the first page of a document fitted to an
        /// iPad's width begins 0.6 pixels below one. A picture whose pixels begin at the page's corner
        /// is then shown shifted by that much, each of its pixels spread over two of the screen's, and
        /// its lines come out softer than the same lines drawn as shapes (which the system fits to the
        /// screen's pixels whatever the shift). So pictures are drawn from where this says instead.
        private static func pixelGrid(of view: UIView, scale: CGFloat) -> CGPoint {
            guard let window = view.window, scale > 0 else { return .zero }
            let dense = window.screen.scale
            let corner = view.convert(CGPoint.zero, to: window)
            let along = view.convert(CGPoint(x: 100, y: 0), to: window)
            // (Only where the view stands upright on screen; a page shown turned keeps its own corner.)
            guard abs(along.y - corner.y) < 0.01, along.x > corner.x else { return .zero }
            func part(_ value: CGFloat) -> CGFloat {
                let pixels = value * dense
                return (pixels.rounded(.up) - pixels) / scale
            }
            return CGPoint(x: part(corner.x), y: part(corner.y))
        }

        /// Whether a picture that begins at [point] has its pixels on the screen's. It is taken to have
        /// left them only once it has been found off them three looks in a row: in the middle of a
        /// movement a page may be anywhere.
        private static func onGrid(_ picture: PagePicture, _ point: CGPoint, _ grid: CGPoint, scale: CGFloat) -> Bool {
            func off(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
                let pixels = (a - b) * scale
                return abs(pixels - pixels.rounded())
            }
            if off(point.x, grid.x) < 0.06, off(point.y, grid.y) < 0.06 {
                picture.offGrid = 0
                return true
            }
            picture.offGrid += 1
            return picture.offGrid < 3
        }

        /// Whether the picture of a page's handwriting reaches as far as the page is in view.
        private func inkReaches(_ overlay: PageOverlay) -> Bool {
            if overlay.inkEmpty { return true }
            guard let view = pdfView, let shown = overlay.inkPicture.shown else { return false }
            let seen = overlay.convert(view.bounds, from: view).intersection(overlay.bounds)
            if seen.isNull || seen.isEmpty { return true }
            return shown.rect.insetBy(dx: -0.75, dy: -0.75).contains(seen)
        }

        /// Shows a page's handwriting as the app's pictures of it, wherever those stand for it and reach
        /// as far as the page is in view, and no tool is in hand that works on the canvas; as the canvas
        /// otherwise.
        private func settleInk(_ overlay: PageOverlay) {
            if Self.holdsPreviews {
                overlay.canvas.alpha = 0
                return
            }
            guard !Self.showsCanvas, !choice.needsCanvas, !overlay.inkInUse, overlay.inkTrusted, inkReaches(overlay) else {
                overlay.showCanvasInk()
                // (The canvas has every line; shapes left on show over it would draw them twice.)
                overlay.dropPreviews()
                return
            }
            overlay.showInkPicture()
        }

        /// Brings the pictures of a page's handwriting up to date: with the handwriting as it stands, as
        /// fine as the zoom, reaching as far as the page is in view. Where the pictures on show are of the
        /// right part at the right zoom and the app knows where the handwriting has changed, only that
        /// part is drawn again. Drawing is off the main thread; one page's pictures are made one at a time,
        /// and whatever changes while they are being made is drawn right after.
        private func askInk(for overlay: PageOverlay) {
            guard !retired, !Self.holdsPreviews, let view = pdfView, overlay.window != nil else { return }
            if overlay.inkBusy {
                overlay.inkAgain = true
                // Pictures being made for a zoom the page has left would be stretched when they came, and
                // the ones for this zoom could not begin until they had: they are told to stop. (A test's
                // notes had a picture six seconds in the making land four zooms late, and none after it.)
                let wanted = zoomSeen * view.traitCollection.displayScale
                if overlay.inkAsking > 0, abs(wanted - overlay.inkAsking) > 0.002 * wanted {
                    overlay.inkAsking = 0
                    overlay.inkPicture.ticket.next()
                }
                return
            }
            let canvas = overlay.canvas
            let picture = overlay.inkPicture
            let version = canvas.inkVersion
            let whole = overlay.bounds
            let scale = zoomSeen * view.traitCollection.displayScale
            guard scale > 0, whole.width > 1, whole.height > 1, !picture.gaveUp else { return }
            if canvas.strokeCount == 0 {
                // Nothing written: no pictures, and nothing to draw.
                if !(overlay.inkEmpty && overlay.inkTrusted && overlay.inkPictureVersion == version) {
                    if picture.shown != nil { picture.clear() }
                    if overlay.highPicture.shown != nil { overlay.highPicture.clear() }
                    overlay.inkPictureVersion = version
                    overlay.inkTrusted = true
                    overlay.inkEmpty = true
                    overlay.inkDirty = .null
                    overlay.inkDirtyAll = false
                    overlay.dropPreviews(upTo: version)
                    settleInk(overlay)
                }
                return
            }
            var want = whole
            var need = whole
            if whole.width * whole.height * scale * scale > Self.inkLimit {
                let seen = overlay.convert(view.bounds, from: view).intersection(whole)
                guard !seen.isNull, !seen.isEmpty else { return }
                need = seen.insetBy(dx: -seen.width * 0.08, dy: -seen.height * 0.08).intersection(whole)
                want = seen.insetBy(dx: -seen.width * 0.4, dy: -seen.height * 0.4).intersection(whole)
                if want.width * want.height * scale * scale > Self.inkLimit { want = need }
            }
            let shown = picture.shown
            let grid = Self.pixelGrid(of: picture, scale: scale)
            var fits = false
            if let shown, abs(shown.scale - scale) < 0.002 * scale {
                fits = shown.rect.insetBy(dx: -0.75, dy: -0.75).contains(need) && Self.onGrid(picture, shown.rect.origin, grid, scale: scale)
            }
            let stale = overlay.inkDirtyAll || !overlay.inkDirty.isNull || overlay.inkPictureVersion != version
                || !overlay.inkTrusted || overlay.inkEmpty
            if fits, !stale { return }
            var extent = PagePicture.Extent(rect: InkPaint.whole(want, scale: scale, origin: grid), scale: scale)
            var base: CGImage?
            var dirty: CGRect?
            if fits, overlay.inkTrusted, !overlay.inkEmpty, !overlay.inkDirtyAll, !overlay.inkDirty.isNull,
               let shown, let image = picture.picture {
                extent = shown
                base = image
                dirty = overlay.inkDirty
            }
            overlay.inkDirty = .null
            overlay.inkDirtyAll = false
            overlay.inkBusy = true
            overlay.inkAsking = extent.scale
            overlay.inkAgain = false
            let ticket = picture.ticket
            let number = ticket.next()
            let breaks = picture.breaks
            let drawing = canvas.ink
            let dark = darkPaper
            let index = canvas.pageIndex
            let began = CACurrentMediaTime()
            // The highlighter's picture is brought up to date the same way, where there is one of the same part.
            let highBase: CGImage? = base != nil && overlay.highPicture.shown == extent ? overlay.highPicture.picture : nil
            inkQueue.async { [weak self, weak overlay] in
                let made = InkPaint.pictures(
                    of: drawing, rect: extent.rect, scale: extent.scale, dark: dark, over: base, redoing: dirty, highOver: highBase,
                    still: { ticket.current == number }
                )
                let took = (CACurrentMediaTime() - began) * 1000
                DispatchQueue.main.async {
                    guard let self, let overlay else { return }
                    if self.penLine != nil, !InkPaint.oldHighlighter {
                        // A line is being written this moment. Putting a picture of this size on screen
                        // takes the main thread a few milliseconds, which are the pen's: the picture waits
                        // until the pen is off the page, and goes up then. (Until 0.12.0 it was let go and
                        // made again when the hand rested. A hand that did not rest, writing line after
                        // line, had every picture made for nothing, and the lines waiting for one piled up.)
                        overlay.inkLanding = { [weak self, weak overlay] in
                            guard let self, let overlay else { return }
                            self.land(made, on: overlay, extent: extent, version: version, ticket: ticket, number: number, breaks: breaks, dirty: dirty, index: index, took: took)
                        }
                        return
                    }
                    self.land(made, on: overlay, extent: extent, version: version, ticket: ticket, number: number, breaks: breaks, dirty: dirty, index: index, took: took)
                }
            }
        }

        /// Puts pictures of a page's handwriting, made at [version] of it, on show.
        private func land(
            _ made: InkPaint.Made?, on overlay: PageOverlay, extent: PagePicture.Extent, version: Int, ticket: Ticket, number: Int,
            breaks: Int, dirty: CGRect?, index: Int, took: Double
        ) {
                do {
                    overlay.inkBusy = false
                    guard ticket.current == number else {
                        // Let go while it was being made (the page left the screen, say).
                        overlay.inkDirtyAll = true
                        return
                    }
                    if self.penLine != nil {
                        // (Only the old way comes here with a line being written: the picture is let go.)
                        if let dirty {
                            overlay.inkDirty = overlay.inkDirty.union(dirty)
                        } else {
                            overlay.inkDirtyAll = true
                        }
                        return
                    }
                    if let made {
                        overlay.inkPicture.show(made.pens, extent)
                        if let high = made.high {
                            overlay.highPicture.show(high, PagePicture.Extent(rect: made.highRect, scale: extent.scale))
                        } else if overlay.highPicture.shown != nil {
                            overlay.highPicture.clear()
                        }
                        overlay.inkPictureVersion = version
                        overlay.inkEmpty = false
                        // (Unless PencilKit changed the handwriting meanwhile: then the canvas goes on showing.)
                        if overlay.inkPicture.breaks == breaks {
                            overlay.inkTrusted = true
                            // The lines just written are on show as they were written, sharp. A picture
                            // made for another zoom than the page stands at now is not as sharp as they
                            // are: they stay until one made for this zoom has them.
                            let now = self.zoomSeen * (self.pdfView?.traitCollection.displayScale ?? 2)
                            if abs(extent.scale - now) < 0.002 * now {
                                overlay.dropPreviews(upTo: version)
                            } else {
                                DebugLog.write(String(format: "ink picture: made at %.3f pixels a point while the page stands at %.3f; the lines just written stay on show", Double(extent.scale), Double(now)))
                            }
                        } else {
                            overlay.inkDirtyAll = true
                        }
                        let how = dirty.map { "part \(Int($0.width)) x \(Int($0.height)) redrawn" } ?? "drawn whole"
                        DebugLog.write(String(format: "ink picture: page %d, %d lines, %d x %d at %.3f pixels a point, %@ in %.1f ms", index, made.strokes, made.pens.width, made.pens.height, Double(extent.scale), how, took))
                    } else {
                        overlay.inkPicture.gaveUp = true
                        overlay.inkTrusted = false
                        DebugLog.write("ink picture: page \(index) could not be drawn")
                    }
                    self.settleInk(overlay)
                    if self.penLine == nil, overlay.inkAgain || overlay.canvas.inkVersion != version {
                        self.askInk(for: overlay)
                    }
                }
        }

        private func refreshPicture(in overlay: PageOverlay, scale: CGFloat, view: PDFView) {
            let picture = overlay.pagePicture
            let whole = picture.bounds
            guard !picture.gaveUp, whole.width > 1, whole.height > 1, let source else { return }
            let around = view.bounds.insetBy(dx: -view.bounds.width * 0.5, dy: -view.bounds.height * 0.6)
            if picture.convert(around, from: view).intersection(whole).isEmpty {
                // Out of view. Its picture is let go once the page is more than a screen and a half away.
                let far = view.bounds.insetBy(dx: -view.bounds.width * 1.5, dy: -view.bounds.height * 1.5)
                if picture.shown != nil, picture.convert(far, from: view).intersection(whole).isEmpty {
                    picture.clear()
                }
                return
            }
            var want = whole
            var need = whole
            if whole.width * whole.height * scale * scale > Self.pictureLimit {
                let seen = picture.convert(view.bounds, from: view).intersection(whole)
                guard !seen.isEmpty else { return }
                need = seen.insetBy(dx: -seen.width * 0.08, dy: -seen.height * 0.08).intersection(whole)
                want = seen.insetBy(dx: -seen.width * 0.45, dy: -seen.height * 0.45).intersection(whole)
                if want.width * want.height * scale * scale > Self.pictureLimit { want = need }
            }
            let grid = Self.pixelGrid(of: picture, scale: scale)
            if let have = picture.asked ?? picture.shown, abs(have.scale - scale) < 0.002 * scale,
               have.rect.insetBy(dx: -0.75, dy: -0.75).contains(need), Self.onGrid(picture, have.rect.origin, grid, scale: scale) {
                return
            }
            // Whole pixels, and the screen's own: see pixelGrid.
            let extent = PagePicture.Extent(rect: InkPaint.whole(want, scale: scale, origin: grid), scale: scale)
            picture.asked = extent
            let ticket = picture.ticket
            let number = ticket.next()
            let size = whole.size
            let index = overlay.canvas.pageIndex
            pictureQueue.async { [weak picture] in
                // (A page scrolled past, or zoomed again, while this waited its turn is not drawn.)
                guard ticket.current == number else { return }
                // (From the queue's own copy of the document: PDFKit's objects are not for sharing between threads.)
                let image = source.page(index).flatMap { PagePicture.draw($0, size: size, extent: extent) }
                DispatchQueue.main.async {
                    guard let picture, ticket.current == number else { return }
                    if let image {
                        picture.show(image, extent)
                        DebugLog.write("page picture: page \(index) part \(extent.rect) at \(extent.scale) pixels a point, \(image.width) x \(image.height)")
                    } else {
                        picture.asked = nil
                        picture.gaveUp = true
                        DebugLog.write("page picture: page \(index) could not be drawn")
                    }
                }
            }
        }

        /// How the page in view is put together and how finely each of its layers is drawn. On an iPad in
        /// the hand PDFKit and PencilKit draw coarser than in the build server's simulator, and this is
        /// how to learn what they do there: the numbers go into the diagnostics text.
        /// How the page view is put together, for the diagnostics text.
        func viewAsText() -> String {
            describeView()
        }

        private func describeView() -> String {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return "no page in view" }
            let canvas = overlay.canvas
            var lines: [String] = []
            lines.append("tool \(choice.tool.rawValue); eraser takes \(choice.eraserHighlighterOnly ? "highlighter only" : choice.eraserKind.rawValue), \(Int(choice.eraserWidth)) wide; put down after use: eraser \(choice.eraserAuto), highlighter \(choice.highlighterAuto), shape \(choice.shapeAuto); pen \(choice.penKind.rawValue)")
            lines.append("zoom \(view.scaleFactor), seen \(zoomSeen), fits at \(view.scaleFactorForSizeToFit), up to \(view.maxScaleFactor); display scale \(view.traitCollection.displayScale); view \(Int(view.bounds.width)) x \(Int(view.bounds.height))")
            let shown = overlay.convert(overlay.bounds, to: nil)
            lines.append("page \(canvas.pageIndex): \(Int(overlay.bounds.width)) x \(Int(overlay.bounds.height)) points, on screen \(Int(shown.width)) x \(Int(shown.height)); \(overlays.count) pages laid out; canvases \(inkScale) times the page")
            lines.append("canvas: \(Int(canvas.bounds.width)) x \(Int(canvas.bounds.height)), zoom \(canvas.zoomScale), content scale \(canvas.contentScaleFactor), \(canvas.strokeCount) lines")
            var ink = "handwriting shown as \(overlay.showsInkPicture ? "the app's pictures" : "the canvas"), trusted \(overlay.inkTrusted), empty \(overlay.inkEmpty), \(overlay.keptCount) lines waiting as shapes"
            if let shown = overlay.inkPicture.shown, let image = overlay.inkPicture.picture {
                ink += "; picture \(image.width) x \(image.height) of \(Int(shown.rect.width)) x \(Int(shown.rect.height)) points at \(shown.scale)"
            }
            if let high = overlay.highPicture.picture { ink += "; highlighter \(high.width) x \(high.height)" }
            lines.append(ink)
            if let page = overlay.pagePicture.picture, let shown = overlay.pagePicture.shown {
                lines.append("page picture \(page.width) x \(page.height) at \(shown.scale)")
            }
            lines.append("canvas layers:")
            var left = 30
            Self.describe(canvas.layer, depth: 1, into: &lines, left: &left, skipping: nil)
            if let host = overlay.superview {
                lines.append("page layers, in a \(type(of: host)):")
                left = 30
                Self.describe(host.layer, depth: 1, into: &lines, left: &left, skipping: overlay.layer)
            }
            return lines.joined(separator: "\n")
        }

        private static func describe(_ layer: CALayer, depth: Int, into lines: inout [String], left: inout Int, skipping: CALayer?) {
            guard left > 0, depth < 8, layer !== skipping else { return }
            left -= 1
            var text = String(repeating: " ", count: depth * 2)
            text += "\(type(of: layer)) \(Int(layer.bounds.width))x\(Int(layer.bounds.height)) scale \(layer.contentsScale)"
            if let metal = layer as? CAMetalLayer {
                text += " drawable \(Int(metal.drawableSize.width))x\(Int(metal.drawableSize.height))"
            }
            if let contents = layer.contents {
                if CFGetTypeID(contents as AnyObject) == CGImage.typeID {
                    let image = contents as! CGImage
                    text += " image \(image.width)x\(image.height)"
                } else {
                    text += " contents \(type(of: contents))"
                }
            }
            let turn = layer.affineTransform()
            if !turn.isIdentity { text += String(format: " x%.3f", Double(hypot(turn.a, turn.b))) }
            if layer.opacity < 1 { text += String(format: " opacity %.2f", Double(layer.opacity)) }
            if layer.isHidden { text += " hidden" }
            lines.append(text)
            for sub in (layer.sublayers ?? []).prefix(10) {
                describe(sub, depth: depth + 1, into: &lines, left: &left, skipping: skipping)
            }
        }

        /// Memory is short: the pictures of pages that are not in view are let go.
        private func dropUnseenPictures() {
            guard let view = pdfView else { return }
            for overlay in overlays.values {
                let picture = overlay.pagePicture
                if picture.convert(view.bounds, from: view).intersection(picture.bounds).isEmpty {
                    picture.clear()
                    overlay.dropInkPicture()
                }
            }
            // From here on, for as long as the document stays open, less is asked of memory: smaller
            // pictures, and canvases no more than half as fine again as the page.
            Self.tight = true
            settleScale()
            if let source {
                pictureQueue.async { source.forget() }
            }
            DebugLog.write("memory: a warning; the pictures of pages out of view were let go")
        }

        // MARK: searching

        func search(_ text: String) -> [SearchHit] {
            guard let document = pdfView?.document else { return [] }
            var hits: [SearchHit] = []
            for selection in document.findString(text, withOptions: [.caseInsensitive]).prefix(300) {
                guard let page = selection.pages.first else { continue }
                // The whole line the words stand in, to show where that is.
                let line = selection.copy() as? PDFSelection ?? selection
                line.extendForLineBoundaries()
                let snippet = (line.string ?? selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                hits.append(SearchHit(page: document.index(for: page), snippet: snippet, selection: selection))
            }
            return hits
        }

        func show(_ hit: SearchHit) {
            guard let view = pdfView else { return }
            // The words are marked on the overlay: PDFKit's own marking would lie under the page's picture.
            var rects: [CGRect] = []
            if let page = hit.selection.pages.first {
                let crop = page.bounds(for: .cropBox)
                for line in hit.selection.selectionsByLine() {
                    let box = line.bounds(for: page)
                    rects.append(CGRect(x: box.minX - crop.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height))
                }
            }
            found = (hit.page, rects)
            for overlay in overlays.values {
                overlay.highlight(overlay.canvas.pageIndex == hit.page ? rects : [])
            }
            view.go(to: hit.selection)
        }

        // MARK: UIPencilInteractionDelegate

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            pencil(setting: "pencilTap", system: UIPencilInteraction.preferredTapAction)
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended else { return }
            pencil(setting: "pencilSqueeze", system: UIPencilInteraction.preferredSqueezeAction)
        }

        /// What the gesture does is the user's choice in this app's settings; left at "system", it is
        /// what they chose for the Pencil in the iPad's own settings.
        private func pencil(setting: String, system: UIPencilPreferredAction) {
            // One gesture of the hand is one change of tool. A double tap and a squeeze that come within
            // a moment of each other (a Pencil Pro held tightly while it is tapped tells of both), or the
            // same gesture told twice, would take the eraser up and put it down again at once.
            let now = CACurrentMediaTime()
            if now - pencilActed < 0.45 {
                Diagnostics.shared.step("pencil \(setting == "pencilTap" ? "tap" : "squeeze") right after another; not taken")
                return
            }
            let action: PencilAction?
            switch UserDefaults.standard.string(forKey: setting) ?? "system" {
            case "eraser": action = .eraser
            case "previous": action = .previous
            case "ai": action = .ai
            case "options": action = .options
            case "off": action = nil
            default:
                // (A shortcut the user tied to the gesture is run by the system; nothing is added to it.)
                switch system {
                case .switchEraser: action = .eraser
                case .switchPrevious: action = .previous
                case .showColorPalette, .showInkAttributes, .showContextualPalette: action = .options
                default: action = nil
                }
            }
            if let action {
                pencilActed = now
                Diagnostics.shared.step("pencil \(setting == "pencilTap" ? "tap" : "squeeze")")
                controller?.onPencil?(action)
            }
        }

        // MARK: marks of the AI pen

        /// The line of a stroke as points a few page points apart.
        private static func points(of stroke: PKStroke) -> [CGPoint] {
            var points: [CGPoint] = []
            for point in stroke.path.interpolatedPoints(by: .distance(3)) {
                points.append(point.location.applying(stroke.transform))
            }
            if points.isEmpty {
                points = stroke.path.map { $0.location.applying(stroke.transform) }
            }
            return points
        }

        private func marked(_ points: [CGPoint], on canvas: PageCanvas) {
            guard let first = points.first else { return }
            let box = Question.bounds(of: points)
            if box.width < 6, box.height < 6 {
                // A touch of the pen, not a mark: it opens the mark it touched.
                if let hit = mark(at: first, page: canvas.pageIndex) {
                    controller?.onOpenMark?(hit.id)
                }
                return
            }
            controller?.onMark?(canvas.pageIndex, points)
        }

        /// The mark, the latest first, whose box holds this point of the page.
        private func mark(at point: CGPoint, page: Int) -> Question? {
            marks.last { $0.page == page && $0.bounds.insetBy(dx: -8, dy: -8).contains(point) }
        }

        private func showMarks(in overlay: PageOverlay) {
            let page = overlay.canvas.pageIndex
            for badge in overlay.show(marks.filter { $0.page == page }, active: activeMark) {
                badge.addTarget(self, action: #selector(openMark(_:)), for: .touchUpInside)
                badge.addInteraction(UIContextMenuInteraction(delegate: self))
            }
        }

        @objc private func openMark(_ badge: MarkBadge) {
            controller?.onOpenMark?(badge.question.id)
        }

        @objc private func tapPage(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, !fingerDraws, let overlay = gesture.view as? PageOverlay else { return }
            // A touch on the page lets go of the words that were picked.
            if picker.isActive {
                picker.clear()
                return
            }
            if let hit = mark(at: gesture.location(in: overlay), page: overlay.canvas.pageIndex) {
                controller?.onOpenMark?(hit.id)
            }
        }

        /// Scrolls just far enough for [rect] of a page's overlay to be seen. Used when the explanation
        /// panel opens and takes room from the pages.
        func reveal(_ rect: CGRect, onPage index: Int) {
            guard let view = pdfView, let page = view.document?.page(at: index) else { return }
            // (Turning pages one at a time, each page fills the view; going to it is all there is to do.)
            guard let overlay = overlays[page], layout != .paged, layout != .twoUpPaged else {
                view.go(to: page)
                return
            }
            let seen = view.bounds.insetBy(dx: 8, dy: 12)
            if seen.contains(overlay.convert(rect, to: view)) { return }
            if let scroll = Self.scrollView(in: view) {
                scroll.scrollRectToVisible(overlay.convert(rect, to: scroll).insetBy(dx: -16, dy: -28), animated: true)
            } else {
                view.go(to: page)
            }
        }

        /// The scroll view PDFKit keeps its pages in (the canvases are scroll views too, and are passed over).
        private static func scrollView(in view: UIView) -> UIScrollView? {
            var queue = view.subviews
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let scroll = next as? UIScrollView, !(next is PKCanvasView) { return scroll }
                queue.append(contentsOf: next.subviews)
            }
            return nil
        }

        func demoPick(from a: CGPoint, to b: CGPoint) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            picker.pick(from: a, to: b, in: overlay)
            DebugLog.write("pick: \(picker.text.count) characters picked: \(picker.text.prefix(80))")
        }

        func demoShapes() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let width = choice.penSeenWidth
            let size = InkWidth.size(drawing: width)
            let drags: [(ShapeKind, CGPoint, CGPoint)] = [
                (.line, CGPoint(x: 70, y: 470), CGPoint(x: 250, y: 474)),
                (.arrow, CGPoint(x: 300, y: 520), CGPoint(x: 500, y: 450)),
                (.rect, CGPoint(x: 70, y: 520), CGPoint(x: 250, y: 620)),
                (.ellipse, CGPoint(x: 300, y: 560), CGPoint(x: 500, y: 660)),
            ]
            for (kind, from, to) in drags {
                let outline = ShapeOutline.points(kind, from: from, to: to, lineWidth: width)
                var points: [PKStrokePoint] = []
                for (index, place) in outline.enumerated() {
                    points.append(PKStrokePoint(
                        location: place, timeOffset: Double(index) * 0.004, size: CGSize(width: size, height: size),
                        opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                    ))
                }
                let stroke = PKStroke(ink: PKInk(.monoline, color: choice.penUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                var drawing = overlay.canvas.ink
                let before = drawing
                drawing.strokes.append(stroke)
                setDrawing(drawing, on: overlay.canvas, undoingTo: before)
            }
        }

        func demoErase(from: CGPoint, to: CGPoint) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            eraserMoved(from: from, to: to, in: overlay)
        }

        func demoZoom(_ factor: Double) {
            guard let view = pdfView else { return }
            keepZoomRange(view)
            view.scaleFactor = view.scaleFactorForSizeToFit * CGFloat(factor)
            DebugLog.write("zoom: asked for \(factor) times fitting, at \(view.scaleFactor) now; the view allows \(view.minScaleFactor) to \(view.maxScaleFactor)")
        }

        func demoMark(center: CGPoint, radius: CGSize) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else {
                DebugLog.write("demo mark: no page to draw on")
                return
            }
            DebugLog.write("overlay: page \(overlay.canvas.pageIndex) bounds \(overlay.bounds.size) page shown \(AskCapture.shape(of: page).size) turned \(page.rotation) ink scale \(overlay.inkScale)")
            overlay.canvas.catchUp()
            var drawing = overlay.canvas.drawing
            drawing.strokes.append(Self.ring(center: center, radius: radius, color: InkChoice.markColor))
            expectNews()
            overlay.canvas.drawing = drawing
        }

        // MARK: formulas

        @discardableResult
        private func install(_ item: MathItem, in overlay: PageOverlay) -> MathView {
            let picture = UIImage(contentsOfFile: mathStore.imageURL(item.image).path)
            let view = MathView(item: item, picture: picture, quarterTurns: overlay.quarterTurns, dark: darkPaper)
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragMath(_:))))
            view.addInteraction(UIContextMenuInteraction(delegate: self))
            overlay.add(view)
            return view
        }

        private func overlay(forPage index: Int) -> PageOverlay? {
            overlays.values.first { $0.canvas.pageIndex == index }
        }

        private func saveMath() {
            guard !retired else { return }
            mathStore.save(math)
        }

        /// The room a formula of this size takes in the overlay: on a page shown turned a quarter, the
        /// formula stands across the overlay.
        private static func footprint(_ size: CGSize, in overlay: PageOverlay) -> CGSize {
            overlay.quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
        }

        /// Where the middle of a formula may be, so that all of it stays on the page.
        private static func keepInside(_ center: CGPoint, size: CGSize, overlay: PageOverlay) -> CGPoint {
            let room = footprint(size, in: overlay)
            let x = min(max(room.width / 2, center.x), max(room.width / 2, overlay.bounds.width - room.width / 2))
            let y = min(max(room.height / 2, center.y), max(room.height / 2, overlay.bounds.height - room.height / 2))
            return CGPoint(x: x, y: y)
        }

        /// Puts a new formula in the middle of what is showing of the current page.
        func placeMath(_ result: MathResult, color: UIColor) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let middle = overlay.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            let size = result.size
            let center = Self.keepInside(middle, size: size, overlay: overlay)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let item = MathItem(
                page: overlay.canvas.pageIndex, latex: result.latex, image: result.image,
                x: Double(center.x - size.width / 2), y: Double(center.y - size.height / 2),
                width: Double(size.width), height: Double(size.height),
                red: Double(red), green: Double(green), blue: Double(blue)
            )
            math.append(item)
            saveMath()
            install(item, in: overlay)
        }

        /// Swaps a formula for an edited one, keeping its middle where it was, and its colour.
        func replaceMath(_ old: MathItem, with result: MathResult) {
            guard let at = math.firstIndex(where: { $0.id == old.id }) else { return }
            var item = math[at]
            let middle = CGPoint(x: item.frame.midX, y: item.frame.midY)
            item.latex = result.latex
            item.image = result.image
            item.width = Double(result.size.width)
            item.height = Double(result.size.height)
            item.x = Double(middle.x) - item.width / 2
            item.y = Double(middle.y) - item.height / 2
            math[at] = item
            saveMath()
            guard let overlay = overlay(forPage: item.page) else { return }
            overlay.mathViews.first { $0.item.id == item.id }?.removeFromSuperview()
            install(item, in: overlay)
        }

        private func duplicate(_ source: MathItem) {
            guard let overlay = overlay(forPage: source.page) else { return }
            var copy = source
            copy.id = UUID()
            let size = CGSize(width: source.width, height: source.height)
            let center = Self.keepInside(CGPoint(x: source.frame.midX + 14, y: source.frame.midY + 14), size: size, overlay: overlay)
            copy.x = Double(center.x) - source.width / 2
            copy.y = Double(center.y) - source.height / 2
            math.append(copy)
            saveMath()
            install(copy, in: overlay)
        }

        private func remove(_ item: MathItem) {
            math.removeAll { $0.id == item.id }
            saveMath()
            overlay(forPage: item.page)?.mathViews.first { $0.item.id == item.id }?.removeFromSuperview()
        }

        /// Dragging a formula moves it about its page; it cannot be dragged off the page.
        @objc private func dragMath(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? MathView, let overlay = view.superview as? PageOverlay else { return }
            let by = gesture.translation(in: overlay)
            let size = CGSize(width: view.item.width, height: view.item.height)
            view.center = Self.keepInside(CGPoint(x: view.center.x + by.x, y: view.center.y + by.y), size: size, overlay: overlay)
            gesture.setTranslation(.zero, in: overlay)
            if gesture.state == .ended || gesture.state == .cancelled {
                view.item.x = Double(view.center.x) - view.item.width / 2
                view.item.y = Double(view.center.y) - view.item.height / 2
                if let at = math.firstIndex(where: { $0.id == view.item.id }) {
                    math[at] = view.item
                }
                saveMath()
            }
        }

        // MARK: UIContextMenuInteractionDelegate

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            if let badge = interaction.view as? MarkBadge {
                let id = badge.question.id
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                    UIMenu(children: [
                        UIAction(title: "설명 열기", image: UIImage(systemName: "text.bubble")) { _ in self?.controller?.onOpenMark?(id) },
                        UIAction(title: "쪽의 표시만 지우기", image: UIImage(systemName: "eye.slash")) { _ in self?.controller?.onHideMark?(id) },
                        UIAction(title: "표시와 설명 삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.controller?.onDeleteMark?(id) },
                    ])
                }
            }
            guard let view = interaction.view as? MathView else { return nil }
            let item = view.item
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "수정", image: UIImage(systemName: "pencil")) { _ in self?.controller?.onEditMath?(item) },
                    UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { _ in self?.duplicate(item) },
                    UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.remove(item) },
                ])
            }
        }

        // MARK: for the build server

        /// A ring drawn by code: the build server's pictures cannot show anyone writing, and this shows
        /// whether ink lands where its coordinates say. Places are in page points, measured from the
        /// page's top-left corner.
        private static func ring(center: CGPoint, radius: CGSize, color: UIColor, ink: PKInkingTool.InkType = .pen) -> PKStroke {
            var points: [PKStrokePoint] = []
            for i in 0...48 {
                let t = Double(i) / 48 * 2 * Double.pi
                let location = CGPoint(x: center.x + radius.width * CGFloat(cos(t)), y: center.y + radius.height * CGFloat(sin(t)))
                points.append(PKStrokePoint(
                    location: location, timeOffset: Double(i) * 0.01, size: CGSize(width: 2.4, height: 2.4),
                    opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                ))
            }
            return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }

        /// The ring round the sample's heading, and under it a line of thin loops, the kind of line
        /// whose edges show at once whether ink is drawn sharp.
        private static func demoDrawing() -> PKDrawing {
            var strokes = [ring(center: CGPoint(x: 130, y: 88), radius: CGSize(width: 86, height: 22), color: .systemRed)]
            var points: [PKStrokePoint] = []
            for i in 0...120 {
                let t = Double(i) / 120
                let location = CGPoint(x: 330 + 190 * t, y: 96 + 9 * sin(t * 14 * Double.pi))
                points.append(PKStrokePoint(
                    location: location, timeOffset: t, size: CGSize(width: 1.4, height: 1.4),
                    opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                ))
            }
            strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date())))
            return PKDrawing(strokes: strokes)
        }
    }
}
