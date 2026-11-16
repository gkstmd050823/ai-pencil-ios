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
    /// Set while the app itself is giving the canvas a drawing it has already taken note of.
    var byCode = false

    /// Gives the canvas a drawing the app has taken note of already, so that the canvas telling of the
    /// change is not taken for news. (Should the canvas tell of it only later, it is taken for news after
    /// all, which costs a moment of the canvas showing in the picture's place and nothing else.)
    func take(_ drawing: PKDrawing) {
        byCode = true
        self.drawing = drawing
        byCode = false
    }
}

/// The drag that draws a shape: it begins the moment the page is touched, and remembers where.
final class ShapeGesture: UILongPressGestureRecognizer {
    var start = CGPoint.zero
}

/// Watches where a touch goes without getting in anyone's way: it never claims the touch and is never made
/// to let go of it. PencilKit rubs out as it always does, and this tells the app where the eraser is.
final class TouchWatcher: UIGestureRecognizer {
    /// Called as the touch moves: where it was last seen and where it is now, in the view's frame.
    var onMove: ((CGPoint, CGPoint) -> Void)?
    /// Called when the touch lands, and when it is over.
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private weak var followed: UITouch?
    private var last = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard followed == nil, let touch = touches.first else { return }
        followed = touch
        last = touch.location(in: view)
        onDown?()
        onMove?(last, last)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = followed, touches.contains(touch) else { return }
        let point = touch.location(in: view)
        onMove?(last, point)
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
        // It never recognises anything; saying so is what readies it for the next touch.
        state = .failed
    }

    override func reset() {
        super.reset()
        if followed != nil {
            followed = nil
            onUp?()
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
/// sharp there as this one. It is kept for an iPad in the hand, where pages were reported to look
/// coarser than in other apps, and can be switched off in the app's settings ("sharpPages").
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
    let ticket = Ticket()
    private let image = CALayer()

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
        shown = extent
        asked = nil
    }

    /// Lets the picture go, to give its memory back.
    func clear() {
        ticket.next()
        image.contents = nil
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
        setImage(UIImage(systemName: "sparkles", withConfiguration: glyph), for: .normal)
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
    /// The page's handwriting drawn by the app with as many pixels as the screen shows it with. PencilKit
    /// draws the canvas with as many pixels as it sees fit, which on an iPad in the hand came out coarse;
    /// so while nothing is being written on the canvas, the canvas is all but hidden and this picture of
    /// the same handwriting shows in its place. It lies in this view's frame, like the handwriting itself.
    let inkPicture = PagePicture()
    /// The number the handwriting had when the picture on show was made, and when the one on its way was
    /// asked for.
    var inkPictureVersion = -1
    var inkAskedVersion = -1
    /// The handwriting has changed since the picture was made, but only by lines that are still on show
    /// as the pen's own shapes: picture and shapes together are the handwriting at this number.
    var inkCoveredVersion = -1
    /// A pen or finger is on the canvas at this moment.
    var inkInUse = false
    /// When the canvas was last touched, and when the handwriting last changed.
    var canvasUsed: CFTimeInterval = 0
    var inkTouched: CFTimeInterval = 0
    /// Lines written with the app's own pen, and shapes just drawn: shown as plain filled shapes from the
    /// moment they are made until the picture of the handwriting has them.
    private let penMarks = UIView()
    private var liveLayers: [CAShapeLayer] = []
    private var liveFrom = 0
    private let liveTail = CAShapeLayer()
    private var kept: [(version: Int, at: CFTimeInterval, layers: [CALayer])] = []
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
    private var canvasFits: (size: CGSize, scale: CGFloat) = (.zero, 0)
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
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)
        inkPicture.layer.masksToBounds = false
        inkPicture.isHidden = true
        addSubview(inkPicture)
        penMarks.isUserInteractionEnabled = false
        addSubview(penMarks)
        liveTail.fillColor = nil
        liveTail.lineCap = .round
        liveTail.lineJoin = .round
        liveTail.actions = ["path": NSNull()]
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

    /// The canvas shows the handwriting itself. Whenever the picture might not be the handwriting as it
    /// stands, this is what is shown: the canvas is always right.
    func showCanvasInk() {
        guard canvas.alpha != 1 || !inkPicture.isHidden else { return }
        // At once, and whatever fading in was under way: a pen may be coming down this moment.
        canvas.layer.removeAnimation(forKey: "opacity")
        inkPicture.layer.removeAnimation(forKey: "opacity")
        canvas.alpha = 1
        inkPicture.isHidden = true
        inkPicture.alpha = 1
    }

    /// The picture shows the handwriting. The canvas stays where it is and goes on taking touches (a view
    /// that is wholly see-through is passed over by touches, so it keeps a trace of itself).
    func showInkPicture() {
        guard inkPicture.isHidden else { return }
        inkPicture.alpha = 0
        inkPicture.isHidden = false
        // Faded in over a moment, so that the handwriting does not seem to jump as it sharpens.
        UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.inkPicture.alpha = 1
            self.canvas.alpha = 0.02
        }
    }

    /// Lets the picture of the handwriting go. The canvas shows from here on, until a new picture is made.
    func dropInkPicture() {
        showCanvasInk()
        if inkPicture.shown != nil || inkPicture.asked != nil { inkPicture.clear() }
        inkPictureVersion = -1
        inkAskedVersion = -1
        inkCoveredVersion = -1
    }

    /// Shows the line being written with the app's own pen, and where the pen is expected to go next.
    func drawLive(_ line: PenLine, ahead: [PenSample], color: CGColor, fineness: CGFloat) {
        if liveLayers.isEmpty || line.points.count - liveFrom > 48 {
            // A long line is cut into pieces, so that only its last piece is worked out again as it grows.
            if let piece = liveLayers.last {
                piece.path = line.shape(from: liveFrom)
                liveFrom = max(0, line.points.count - 1)
            } else {
                liveFrom = 0
            }
            let piece = CAShapeLayer()
            piece.fillColor = color
            piece.strokeColor = nil
            piece.contentsScale = fineness
            piece.actions = ["path": NSNull()]
            penMarks.layer.addSublayer(piece)
            liveLayers.append(piece)
        }
        liveLayers.last?.path = line.shape(from: liveFrom)
        // A steadied line trails the pen on purpose; only a line that keeps up with it is drawn ahead.
        if line.steady < 0.05, let end = line.points.last, let width = line.widths.last, !ahead.isEmpty {
            let path = CGMutablePath()
            path.move(to: end)
            for sample in ahead { path.addLine(to: sample.point) }
            liveTail.path = path
            liveTail.lineWidth = width * PenLine.shownShare
            liveTail.strokeColor = color
            liveTail.contentsScale = fineness
            if liveTail.superlayer == nil { penMarks.layer.addSublayer(liveTail) }
        } else {
            liveTail.path = nil
        }
    }

    /// The line being written came to nothing.
    func dropLive() {
        liveLayers.forEach { $0.removeFromSuperlayer() }
        liveLayers = []
        liveFrom = 0
        liveTail.path = nil
    }

    /// The line just written is part of the handwriting from this number on; its shape stays on show
    /// until a picture made at that number or later is.
    func keepLive(for version: Int) {
        liveTail.path = nil
        kept.append((version, CACurrentMediaTime(), liveLayers))
        liveLayers = []
        liveFrom = 0
    }

    /// The same for any other shape that stands for something just added to the handwriting.
    func keep(_ layer: CALayer, for version: Int) {
        penMarks.layer.addSublayer(layer)
        kept.append((version, CACurrentMediaTime(), [layer]))
    }

    /// Takes down the shapes of lines the picture now has (those up to [version]), or all that have
    /// stood for at least [age] seconds.
    func dropPreviews(upTo version: Int = .max, olderThan age: CFTimeInterval = 0) {
        guard !kept.isEmpty else { return }
        let now = CACurrentMediaTime()
        kept.removeAll { entry in
            guard entry.version <= version, now - entry.at >= age else { return false }
            entry.layers.forEach { $0.removeFromSuperlayer() }
            return true
        }
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
        penMarks.frame = bounds
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
        if bounds.width > 0, bounds.height > 0, canvasFits.size != bounds.size || canvasFits.scale != inkScale {
            canvasFits = (bounds.size, inkScale)
            let larger = CGSize(width: bounds.width * inkScale, height: bounds.height * inkScale)
            canvas.transform = .identity
            canvas.frame = CGRect(origin: .zero, size: larger)
            canvas.minimumZoomScale = inkScale
            canvas.maximumZoomScale = inkScale
            canvas.zoomScale = inkScale
            canvas.contentSize = larger
            canvas.contentOffset = .zero
            canvas.transform = CGAffineTransform(scaleX: 1 / inkScale, y: 1 / inkScale)
            canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
        coordinator?.undoManager?.undo()
    }

    /// Takes all the handwriting off the page in view. It can be undone.
    func clearPage() {
        coordinator?.clearPage()
    }

    func redo() {
        coordinator?.undoManager?.redo()
    }

    /// For the build server: draws a ring with the AI pen on the page in view, as a hand would have.
    func demoMark(center: CGPoint, radius: CGSize) {
        coordinator?.demoMark(center: center, radius: radius)
    }

    /// For the build server: writes a shaky line with the app's own pen, plain and steadied.
    func demoPen() {
        coordinator?.demoPen()
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
    /// The pen is the app's own (steadied, answering to pressure as set) and not PencilKit's.
    var appPen: Bool
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
        coordinator.appPen = appPen
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
        if startPage > 0, let page = view.document?.page(at: startPage) {
            // Once the view has been laid out; going to a page before that does nothing.
            DispatchQueue.main.async { view.go(to: page) }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.apply(choice: choice, fingerDraws: fingerDraws, appPen: appPen)
        context.coordinator.apply(marks: marks, active: activeMark)
        context.coordinator.apply(layout: layout)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
        coordinator.stopWatching()
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
        private var undoHeld = false
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
        /// The drawing a page had when the highlighter eraser was put to it.
        private var rubbedFrom: PKDrawing?
        /// The file on show, and the same file opened once more for the queue that draws the pages.
        var url: URL?
        var source: PictureSource?
        private let inkQueue = DispatchQueue(label: "app.aipencil.ink.pictures", qos: .userInitiated)
        /// The pen takes its touches through the app instead of through PencilKit.
        var appPen = false
        /// The line being written with the app's own pen.
        private var penLine: PenLine?
        private var ticks = 0
        weak var pdfView: PDFView?
        weak var controller: ReaderController?
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

        func apply(choice: InkChoice, fingerDraws: Bool, appPen: Bool) {
            guard choice != self.choice || fingerDraws != self.fingerDraws || appPen != self.appPen else { return }
            self.choice = choice
            self.fingerDraws = fingerDraws
            self.appPen = appPen
            for overlay in overlays.values {
                configure(overlay)
            }
            holdUndoForMarks()
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
            // Turning pages one at a time is PDFKit's page view controller; the other two scroll.
            let paged = layout == .paged
            view.displayMode = layout == .twoUp ? .twoUpContinuous : (paged ? .singlePage : .singlePageContinuous)
            view.displayDirection = paged ? .horizontal : .vertical
            view.displaysAsBook = false
            view.usePageViewController(paged, withViewOptions: nil)
            view.autoScales = true
            if let page { DispatchQueue.main.async { view.go(to: page) } }
        }

        private func configure(_ overlay: PageOverlay) {
            let canvas = overlay.canvas
            canvas.tool = choice.pencilKitTool
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            // With the formula tool the canvas steps aside, so that touches reach the formulas under it;
            // with the shape tool and the eraser that only takes highlighter, so that they reach the
            // surface those two work on.
            let ownPen = choice.usesAppPen(appPen)
            let onSurface = choice.tool == .shape || choice.rubsHighlighterOnly || ownPen
            canvas.isUserInteractionEnabled = choice.tool != .formula && !onSurface
            overlay.shapeSurface.isHidden = !onSurface
            overlay.shapeDrag?.isEnabled = choice.tool == .shape
            overlay.rubDrag?.isEnabled = choice.rubsHighlighterOnly
            overlay.penDrag?.isEnabled = ownPen
            // What the lasso holds, it shows on the canvas.
            if choice.tool == .lasso {
                overlay.showCanvasInk()
                overlay.dropPreviews()
            }
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

        /// A stroke of the AI pen is taken off the canvas again by code, which the undo history knows
        /// nothing of. So while the AI pen is in hand, nothing is entered in the history at all.
        private func holdUndoForMarks() {
            guard let manager = undoManager else { return }
            let wanted = choice.tool == .ai
            if wanted, !undoHeld {
                manager.disableUndoRegistration()
                undoHeld = true
            } else if !wanted, undoHeld {
                manager.enableUndoRegistration()
                undoHeld = false
            }
        }

        // MARK: saving

        /// The handwriting of a page changed. It goes to disk a moment later and off the main thread:
        /// writing a full page out after every stroke would hold the pen up on a page with much on it.
        ///
        /// [covered] says the change is a line that stays on show as a shape of its own until the picture
        /// of the handwriting has it. Any other change may be anything (a line rubbed out, undone, moved),
        /// so the canvas, which is always right, is shown at once.
        private func record(_ drawing: PKDrawing, on canvas: PageCanvas, covered: Bool = false) {
            guard !retired else { return }
            let before = canvas.inkVersion
            canvas.ink = drawing
            canvas.inkVersion = before + 1
            canvas.strokeCount = drawing.strokes.count
            latest[canvas.pageIndex] = drawing
            unsaved.insert(canvas.pageIndex)
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(saveSoon), object: nil)
            perform(#selector(saveSoon), with: nil, afterDelay: 0.8)
            guard let overlay = canvas.superview as? PageOverlay else { return }
            overlay.inkTouched = CACurrentMediaTime()
            if covered {
                if overlay.inkPictureVersion == before || overlay.inkCoveredVersion == before {
                    overlay.inkCoveredVersion = before + 1
                }
            } else {
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
            if undoHeld {
                undoManager?.enableUndoRegistration()
                undoHeld = false
            }
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

        /// The zoom changed. Once it has settled, the canvases are redrawn as fine as it needs: in
        /// quarter steps, so that a small change does not redraw them, and no finer than three times
        /// the page, which is as much as their memory is worth.
        private func scaleChanged() {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settleScale), object: nil)
            perform(#selector(settleScale), with: nil, afterDelay: 0.25)
        }

        @objc private func settleScale() {
            guard let view = pdfView else { return }
            let wanted = min(Self.tight ? 1.5 : 3, max(1, (view.scaleFactor * 4).rounded(.up) / 4))
            guard wanted != inkScale else { return }
            inkScale = wanted
            for overlay in overlays.values {
                overlay.inkScale = wanted
            }
            DebugLog.write("ink: page zoom \(view.scaleFactor), canvases drawn \(wanted) times finer than the page")
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
            overlay(forPage: index)?.canvas.drawing ?? storedDrawing(page: index)
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
            overlay.quarterTurns = (((page.rotation % 360) + 360) % 360) / 90
            // On dark paper PencilKit shows ink in its dark-screen colours: black ink white.
            overlay.overrideUserInterfaceStyle = darkPaper ? .dark : .light
            let canvas = overlay.canvas
            canvas.pageIndex = view.document?.index(for: page) ?? 0
            let draw = ShapeGesture(target: self, action: #selector(drawShape(_:)))
            draw.minimumPressDuration = 0
            overlay.shapeSurface.addGestureRecognizer(draw)
            overlay.shapeDrag = draw
            let rub = ShapeGesture(target: self, action: #selector(rubHighlighter(_:)))
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
            overlay.shapeSurface.addGestureRecognizer(pen)
            overlay.penDrag = pen
            overlay.watcher.onMove = { [weak self, weak overlay] from, to in
                guard let self, let overlay else { return }
                self.eraserMoved(from: from, to: to, in: overlay)
            }
            overlay.watcher.onDown = { [weak self, weak overlay] in
                guard let self, let overlay, overlay.canvas.isUserInteractionEnabled else { return }
                self.canvasInUse(overlay, true)
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
            canvas.inkVersion = 1
            canvas.strokeCount = start.strokes.count
            canvas.delegate = self
            for item in math where item.page == canvas.pageIndex {
                install(item, in: overlay)
            }
            // A finger on a mark opens its explanation, as long as fingers are not writing.
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapPage(_:)))
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            overlay.addGestureRecognizer(tap)
            overlays[page] = overlay
            showMarks(in: overlay)
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let overlay = overlayView as? PageOverlay else { return }
            // (Its handwriting is in hand already: every change was noted when it was made.)
            overlay.pagePicture.clear()
            overlay.dropInkPicture()
            overlay.dropPreviews()
            overlays[page] = nil
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // The window, and with it the undo history, may not have been there when the tool was chosen.
            holdUndoForMarks()
            if let overlay = canvasView.superview as? PageOverlay { canvasInUse(overlay, true) }
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            if let overlay = canvasView.superview as? PageOverlay { canvasInUse(overlay, false) }
            toolUsed()
        }

        /// A tool has done its work. One that is set to be put down after use is handed back now.
        private func toolUsed() {
            guard choice.putsDownAfterUse else { return }
            let tool = choice.tool
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
                // What the AI pen draws is a question, not handwriting. It is lifted off the canvas
                // again and kept as a mark; the canvas is changed a moment later, once PencilKit has
                // finished telling us about the stroke.
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
            record(drawing, on: canvas)
        }

        // MARK: shapes

        /// Dragging with the shape tool: the shape follows the hand, and becomes ink when it lets go.
        @objc private func drawShape(_ gesture: ShapeGesture) {
            guard let overlay = gesture.view?.superview as? PageOverlay else { return }
            let point = gesture.location(in: overlay)
            let width = choice.penLineWidth
            switch gesture.state {
            case .began:
                gesture.start = point
            case .changed:
                let outline = ShapeOutline.points(choice.shapeKind, from: gesture.start, to: point, lineWidth: width)
                guard let first = outline.first else { return }
                let path = UIBezierPath()
                path.move(to: first)
                for next in outline.dropFirst() { path.addLine(to: next) }
                overlay.shapePreview.path = path.cgPath
                overlay.shapePreview.lineWidth = width * PenLine.shownShare
                overlay.shapePreview.contentsScale = fineness
                overlay.shapePreview.strokeColor = (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor
            case .ended:
                overlay.shapePreview.path = nil
                guard hypot(point.x - gesture.start.x, point.y - gesture.start.y) > 4 else { return }
                let outline = ShapeOutline.points(choice.shapeKind, from: gesture.start, to: point, lineWidth: width)
                guard outline.count > 1 else { return }
                var points: [PKStrokePoint] = []
                for (index, place) in outline.enumerated() {
                    points.append(PKStrokePoint(
                        location: place, timeOffset: Double(index) * 0.004, size: CGSize(width: width, height: width),
                        opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                    ))
                }
                let stroke = PKStroke(ink: PKInk(.monoline, color: choice.penUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                var drawing = overlay.canvas.ink
                let before = drawing
                drawing.strokes.append(stroke)
                setDrawing(drawing, on: overlay.canvas, undoingTo: before, covered: true)
                // The shape as it was dragged out stays on show until the picture of the handwriting has it.
                let path = UIBezierPath()
                path.move(to: outline[0])
                for next in outline.dropFirst() { path.addLine(to: next) }
                let shape = CAShapeLayer()
                shape.path = path.cgPath
                shape.fillColor = nil
                shape.lineCap = .round
                shape.lineJoin = .round
                shape.lineWidth = width * PenLine.shownShare
                shape.strokeColor = (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor
                shape.contentsScale = fineness
                overlay.keep(shape, for: overlay.canvas.inkVersion)
                toolUsed()
            default:
                overlay.shapePreview.path = nil
            }
        }

        /// Changes a canvas's drawing by code in a way that can be undone and redone.
        private func setDrawing(_ new: PKDrawing, on canvas: PageCanvas, undoingTo old: PKDrawing, covered: Bool = false) {
            undoManager?.registerUndo(withTarget: self) { [weak canvas] me in
                guard let canvas else { return }
                me.setDrawing(old, on: canvas, undoingTo: new)
            }
            // Noted first: the canvas tells of the change it is about to be given, and is told it is known.
            record(new, on: canvas, covered: covered)
            canvas.take(new)
        }

        /// How many pixels a point of the page takes on screen now, for shapes drawn over the page.
        private var fineness: CGFloat {
            guard let view = pdfView else { return 2 }
            return min(12, max(1, view.scaleFactor) * view.traitCollection.displayScale)
        }

        // MARK: the app's own pen

        /// The pen moved: the line grows by the places it has been, and is shown at once.
        private func penDrew(_ fresh: [PenSample], ahead: [PenSample], in overlay: PageOverlay) {
            guard !retired, choice.usesAppPen(appPen) else { return }
            if penLine == nil {
                penLine = PenLine(width: choice.penLineWidth, sense: choice.appPenSense, steady: CGFloat(choice.penSteady))
            }
            for sample in fresh { penLine?.add(sample) }
            if let line = penLine {
                overlay.drawLive(line, ahead: ahead, color: penShown, fineness: fineness)
            }
        }

        /// The pen lifted. The line becomes a stroke of the page's handwriting like any other.
        private func penDone(kept: Bool, in overlay: PageOverlay) {
            guard let line = penLine else { return }
            penLine = nil
            guard kept, !retired else {
                overlay.dropLive()
                return
            }
            commit(line, in: overlay)
        }

        private var penShown: CGColor {
            (darkPaper ? choice.penUIColor.onDarkPaper : choice.penUIColor).cgColor
        }

        private func commit(_ written: PenLine, in overlay: PageOverlay, ink: PKInkingTool.InkType = .monoline) {
            var line = written
            line.finish()
            guard let stroke = line.stroke(color: choice.penUIColor, ink: ink) else {
                overlay.dropLive()
                return
            }
            overlay.drawLive(line, ahead: [], color: penShown, fineness: fineness)
            let canvas = overlay.canvas
            var drawing = canvas.ink
            let before = drawing
            drawing.strokes.append(stroke)
            setDrawing(drawing, on: canvas, undoingTo: before, covered: true)
            overlay.keepLive(for: canvas.inkVersion)
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
            for (row, steady) in [(0.0, CGFloat(0)), (1.0, CGFloat(0.9))] {
                var line = PenLine(width: 2.6, sense: 1, steady: steady)
                for step in 0...240 {
                    let along = Double(step) / 240
                    let shake = 2.2 * sin(Double(step) * 1.9) + 1.4 * cos(Double(step) * 3.1)
                    let point = CGPoint(x: 70 + 440 * along, y: 540 + row * 52 + 14 * sin(along * 2 * Double.pi) + shake)
                    line.add(PenSample(point: point, force: CGFloat(0.25 + 2.2 * sin(along * Double.pi)), time: Double(step) / 240))
                }
                commit(line, in: overlay)
                DebugLog.write("pen: a line of \(line.points.count) points written, steadied \(steady)")
            }
            for (row, width) in [1.0, 2.0, 4.0, 8.0, 12.0].enumerated() {
                var line = PenLine(width: CGFloat(width), sense: 0, steady: 0)
                for step in 0...40 {
                    line.add(PenSample(point: CGPoint(x: 70 + 5 * Double(step), y: 640 + 22 * Double(row)), force: 1, time: Double(step) / 240))
                }
                commit(line, in: overlay)
            }
        }

        func clearPage() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let before = overlay.canvas.ink
            guard !before.strokes.isEmpty else { return }
            setDrawing(PKDrawing(), on: overlay.canvas, undoingTo: before)
        }

        // MARK: the eraser

        /// The eraser moved over a page, from one place to the next. A mark of the AI pen that it crosses
        /// is taken off the page; its explanation stays in the list of questions.
        private func eraserMoved(from: CGPoint, to: CGPoint, in overlay: PageOverlay) {
            guard !retired, choice.tool == .eraser, choice.eraserTakesMarks, !choice.eraserHighlighterOnly else { return }
            let page = overlay.canvas.pageIndex
            // About what a pen's tip covers on screen, whatever the zoom.
            let reach = max(3, 11 / max(pdfView?.scaleFactor ?? 1, 0.1))
            for mark in marks where mark.page == page && Self.crosses(from, to, mark.points, within: reach) {
                setMark(mark.id, hidden: true)
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

        /// The eraser that only takes highlighter: a highlighter line it touches goes whole, and nothing
        /// else on the page is changed. One drag is one step of the undo history.
        @objc private func rubHighlighter(_ gesture: ShapeGesture) {
            guard let overlay = gesture.view?.superview as? PageOverlay else { return }
            let canvas = overlay.canvas
            let point = gesture.location(in: overlay)
            let reach = CGFloat(choice.eraserWidth) / 2
            switch gesture.state {
            case .began, .changed:
                if gesture.state == .began {
                    rubbedFrom = canvas.drawing
                    gesture.start = point
                }
                var drawing = canvas.drawing
                let count = drawing.strokes.count
                let from = gesture.start
                drawing.strokes.removeAll { stroke in
                    guard stroke.ink.inkType == .marker,
                          stroke.renderBounds.insetBy(dx: -reach, dy: -reach).intersects(CGRect(x: min(from.x, point.x), y: min(from.y, point.y), width: abs(from.x - point.x), height: abs(from.y - point.y)).insetBy(dx: -1, dy: -1))
                    else { return false }
                    var line: [CGPoint] = []
                    var width: CGFloat = 0
                    for part in stroke.path.interpolatedPoints(by: .distance(4)) {
                        line.append(part.location.applying(stroke.transform))
                        width = max(width, part.size.width)
                    }
                    return Self.crosses(from, point, line, within: reach + width / 2)
                }
                if drawing.strokes.count != count {
                    record(drawing, on: canvas)
                    canvas.take(drawing)
                }
                gesture.start = point
                // A ring shows how much the eraser covers.
                overlay.shapePreview.path = UIBezierPath(ovalIn: CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)).cgPath
                overlay.shapePreview.lineWidth = 1
                overlay.shapePreview.strokeColor = UIColor.systemGray.cgColor
            default:
                overlay.shapePreview.path = nil
                if let before = rubbedFrom, before.strokes.count != canvas.drawing.strokes.count {
                    let after = canvas.drawing
                    undoManager?.registerUndo(withTarget: self) { [weak canvas] me in
                        guard let canvas else { return }
                        me.setDrawing(before, on: canvas, undoingTo: after)
                    }
                    DebugLog.write("eraser: \(before.strokes.count - after.strokes.count) highlighter lines rubbed out, \(after.strokes.count) lines left on the page")
                }
                rubbedFrom = nil
                toolUsed()
            }
        }

        // MARK: the pages drawn sharp

        /// No more pixels than this go into one picture of a page. A page shown whole at fitting zoom is
        /// well under it; zoomed in far, only what is in view and some way round it is drawn.
        private static var pictureLimit: CGFloat { tight ? 4_500_000 : 9_000_000 }
        /// The system has warned that memory is short.
        private static var tight = false
        /// The setting that has the app draw the handwriting itself, for showing while nothing is being
        /// written. On unless switched off.
        private static var drawsInk: Bool {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: "sharpInk") == nil || defaults.bool(forKey: "sharpInk")
        }
        /// The setting that has the app draw the pages itself. On unless switched off ("-sharpPages NO"
        /// leaves the pages as PDFKit draws them, for the build server to compare against).
        private static var drawsPages: Bool {
            let defaults = UserDefaults.standard
            return defaults.object(forKey: "sharpPages") == nil || defaults.bool(forKey: "sharpPages")
        }

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

        /// Several times a second: has every page in or near view a picture as fine as the zoom, of the
        /// part that is in view? Where not, one is asked for.
        private func lookAtPictures() {
            guard let view = pdfView, view.window != nil else { return }
            let now = CACurrentMediaTime()
            let pages = Self.drawsPages
            let ink = Self.drawsInk
            ticks += 1
            if ticks % 16 == 14 {
                // Kept for the diagnostics text in the settings, and noted once for the build server.
                let made = describeView()
                Diagnostics.shared.viewNote = made
                if ticks == 30 { DebugLog.write("view:\n" + made) }
            }
            if ticks % 40 == 5, let megabytes = Diagnostics.footprint().map({ $0 / 1_048_576 }) {
                DebugLog.write("memory: \(megabytes) MB in use with \(overlays.count) pages laid out, page pictures \(pages ? "on" : "off"), ink pictures \(ink ? "on" : "off")")
            }
            // What is switched off is taken down: PDFKit's pages, or the canvases, show again.
            if !pages {
                for overlay in overlays.values where overlay.pagePicture.shown != nil || overlay.pagePicture.asked != nil {
                    overlay.pagePicture.clear()
                }
            }
            if !ink {
                for overlay in overlays.values {
                    overlay.dropInkPicture()
                    overlay.dropPreviews(olderThan: 0.5)
                }
            }
            guard pages || ink else { return }
            let scale = view.scaleFactor * view.traitCollection.displayScale
            guard scale > 0 else { return }
            // While the zoom is still changing nothing is drawn: it would be thrown away at once.
            if abs(scale - scaleSeen) > 0.0005 * scale {
                scaleSeen = scale
                return
            }
            let around = view.bounds.insetBy(dx: -view.bounds.width * 0.5, dy: -view.bounds.height * 0.6)
            for overlay in overlays.values where overlay.window != nil {
                if pages { refreshPicture(in: overlay, scale: scale, view: view) }
                if ink {
                    let near = !overlay.convert(around, from: view).intersection(overlay.bounds).isEmpty
                    refreshInk(in: overlay, scale: scale, near: near, now: now)
                }
            }
        }

        /// The handwriting of a page: is its picture the handwriting as it stands, and as fine as the zoom?
        /// Where it is, and nothing is being written on the canvas, the picture is shown in the canvas's
        /// place. Where it is not, the canvas shows and a picture is asked for once the hand has paused.
        private func refreshInk(in overlay: PageOverlay, scale: CGFloat, near: Bool, now: CFTimeInterval) {
            let canvas = overlay.canvas
            let picture = overlay.inkPicture
            if Self.holdsPreviews {
                // For the build server: only the pen's own shapes show, as they are while a line is written.
                canvas.alpha = 0.02
                return
            }
            // The picture is only ever on show while there is one; and once a second, while it is on
            // show, the canvas is asked whether its handwriting is still what the picture was made of. A
            // change nobody told of would otherwise stay hidden behind the picture.
            if !picture.isHidden {
                if picture.shown == nil {
                    overlay.showCanvasInk()
                } else if ticks % 8 == 0 {
                    let real = canvas.drawing
                    if real.strokes.count != canvas.ink.strokes.count || real.bounds != canvas.ink.bounds {
                        DebugLog.write("ink picture: page \(canvas.pageIndex) had changed unnoticed; the canvas shows again")
                        record(real, on: canvas)
                        return
                    }
                }
            }
            let drawing = canvas.ink
            let room = drawing.bounds.insetBy(dx: -2, dy: -2).intersection(overlay.bounds)
            guard near, !picture.gaveUp, !drawing.strokes.isEmpty, !room.isEmpty else {
                overlay.dropInkPicture()
                overlay.dropPreviews(olderThan: 0.5)
                return
            }
            // All of the handwriting in one picture, as fine as the screen unless that is too many pixels.
            var fine = scale
            let pixels = room.width * room.height * fine * fine
            if pixels > Self.pictureLimit { fine *= (Self.pictureLimit / pixels).squareRoot() }
            let left = (room.minX * fine).rounded(.down) / fine, top = (room.minY * fine).rounded(.down) / fine
            let right = (room.maxX * fine).rounded(.up) / fine, bottom = (room.maxY * fine).rounded(.up) / fine
            let extent = PagePicture.Extent(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top), scale: fine)
            let version = canvas.inkVersion
            let upToDate = picture.shown != nil && overlay.inkPictureVersion == version
            let covered = picture.shown != nil && overlay.inkCoveredVersion == version
            if choice.tool != .lasso, !overlay.inkInUse, now - overlay.canvasUsed > 0.5, upToDate || covered {
                overlay.showInkPicture()
                if upToDate { overlay.dropPreviews(upTo: version) }
            } else if !(upToDate || covered) || choice.tool == .lasso {
                overlay.showCanvasInk()
            }
            if upToDate, let shown = picture.shown, abs(shown.scale - fine) < 0.002 * fine { return }
            if let asked = picture.asked, overlay.inkAskedVersion == version, abs(asked.scale - fine) < 0.002 * fine { return }
            // Never while the hand is writing: the picture is drawn once it has rested a full second, so
            // that drawing it does not get in the way of the pen. Nor right after a touch on the canvas.
            guard now - overlay.inkTouched > 1, now - overlay.canvasUsed > 1, !overlay.inkInUse else { return }
            picture.asked = extent
            overlay.inkAskedVersion = version
            let ticket = picture.ticket
            let number = ticket.next()
            let dark = darkPaper
            let index = canvas.pageIndex
            inkQueue.async { [weak overlay] in
                guard ticket.current == number else { return }
                var image: CGImage?
                // (PencilKit draws for the appearance in force; the paper's is asked for by name.)
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                    image = drawing.image(from: extent.rect, scale: extent.scale).cgImage
                }
                DispatchQueue.main.async {
                    guard let overlay, ticket.current == number else { return }
                    if let image {
                        overlay.inkPicture.show(image, extent)
                        overlay.inkPictureVersion = version
                        DebugLog.write("ink picture: page \(index), \(drawing.strokes.count) lines, \(image.width) x \(image.height) at \(extent.scale) pixels a point")
                    } else {
                        overlay.inkPicture.asked = nil
                        overlay.inkPicture.gaveUp = true
                        DebugLog.write("ink picture: page \(index) could not be drawn")
                    }
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
            if let have = picture.asked ?? picture.shown, abs(have.scale - scale) < 0.002 * scale,
               have.rect.insetBy(dx: -0.5, dy: -0.5).contains(need) {
                return
            }
            // Whole pixels, so that the picture's pixels are the screen's.
            let left = (want.minX * scale).rounded(.down) / scale, top = (want.minY * scale).rounded(.down) / scale
            let right = (want.maxX * scale).rounded(.up) / scale, bottom = (want.maxY * scale).rounded(.up) / scale
            let extent = PagePicture.Extent(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top), scale: scale)
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
        private func describeView() -> String {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return "no page in view" }
            let canvas = overlay.canvas
            var lines: [String] = []
            lines.append("zoom \(view.scaleFactor), fits at \(view.scaleFactorForSizeToFit), up to \(view.maxScaleFactor); display scale \(view.traitCollection.displayScale); view \(Int(view.bounds.width)) x \(Int(view.bounds.height))")
            let shown = overlay.convert(overlay.bounds, to: nil)
            lines.append("page \(canvas.pageIndex): \(Int(overlay.bounds.width)) x \(Int(overlay.bounds.height)) points, on screen \(Int(shown.width)) x \(Int(shown.height)); \(overlays.count) pages laid out; canvases \(inkScale) times the page")
            lines.append("canvas: \(Int(canvas.bounds.width)) x \(Int(canvas.bounds.height)), zoom \(canvas.zoomScale), content scale \(canvas.contentScaleFactor), \(canvas.ink.strokes.count) lines, its picture \(overlay.inkPicture.isHidden ? "hidden" : "shown")")
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
            if let action { controller?.onPencil?(action) }
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
            if let hit = mark(at: gesture.location(in: overlay), page: overlay.canvas.pageIndex) {
                controller?.onOpenMark?(hit.id)
            }
        }

        /// Scrolls just far enough for [rect] of a page's overlay to be seen. Used when the explanation
        /// panel opens and takes room from the pages.
        func reveal(_ rect: CGRect, onPage index: Int) {
            guard let view = pdfView, let page = view.document?.page(at: index) else { return }
            // (Turning pages one at a time, each page fills the view; going to it is all there is to do.)
            guard let overlay = overlays[page], layout != .paged else {
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

        func demoShapes() {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let width = choice.penLineWidth
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
                        location: place, timeOffset: Double(index) * 0.004, size: CGSize(width: width, height: width),
                        opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                    ))
                }
                let stroke = PKStroke(ink: PKInk(.monoline, color: choice.penUIColor), path: PKStrokePath(controlPoints: points, creationDate: Date()))
                var drawing = overlay.canvas.drawing
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
            view.scaleFactor = view.scaleFactorForSizeToFit * CGFloat(factor)
            DebugLog.write("zoom: asked for \(factor) times fitting, at \(view.scaleFactor) now; the view allows \(view.minScaleFactor) to \(view.maxScaleFactor)")
        }

        func demoMark(center: CGPoint, radius: CGSize) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else {
                DebugLog.write("demo mark: no page to draw on")
                return
            }
            DebugLog.write("overlay: page \(overlay.canvas.pageIndex) bounds \(overlay.bounds.size) page shown \(AskCapture.shape(of: page).size) turned \(page.rotation) ink scale \(overlay.inkScale)")
            var drawing = overlay.canvas.drawing
            drawing.strokes.append(Self.ring(center: center, radius: radius, color: InkChoice.markColor))
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
