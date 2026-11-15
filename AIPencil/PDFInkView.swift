import PDFKit
import PencilKit
import SwiftUI

/// The tools of the tool bar.
enum InkTool: String, CaseIterable, Identifiable, Codable {
    case pen, highlighter, eraser, ai, lasso, formula

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .ai: return "AI 펜"
        case .lasso: return "올가미"
        case .formula: return "수식 옮기기"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .ai: return "sparkles"
        case .lasso: return "lasso"
        case .formula: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// The kinds of pen. They differ in how the line answers to the hand.
enum PenKind: String, CaseIterable, Identifiable, Codable {
    case fountain, pen, ball, pencil

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fountain: return "만년필"
        case .pen: return "펜"
        case .ball: return "볼펜"
        case .pencil: return "연필"
        }
    }

    var hint: String {
        switch self {
        case .fountain: return "누르는 힘에 따라 굵기가 달라져요"
        case .pen: return "빠르게 그으면 끝이 가늘어져요"
        case .ball: return "굵기가 늘 같아요"
        case .pencil: return "기울이면 넓게 칠해져요"
        }
    }

    var ink: PKInkingTool.InkType {
        switch self {
        case .fountain: return .fountainPen
        case .pen: return .pen
        case .ball: return .monoline
        case .pencil: return .pencil
        }
    }
}

/// What the eraser takes away.
enum EraserKind: String, CaseIterable, Identifiable, Codable {
    case stroke, part

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke: return "획 지우개"
        case .part: return "부분 지우개"
        }
    }
}

/// What is in the user's hand: a tool, and how each tool is set up.
struct InkChoice: Equatable, Codable {
    var tool: InkTool = .pen
    var penKind = PenKind.fountain
    var penColor = 0
    var penWidth = 2
    var highlighterColor = 0
    var highlighterWidth = 1
    var eraserKind = EraserKind.stroke

    static let penColors: [UIColor] = [
        UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        UIColor(red: 0.12, green: 0.44, blue: 0.92, alpha: 1),
        UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1),
        UIColor(red: 0.13, green: 0.62, blue: 0.38, alpha: 1),
        UIColor(red: 0.94, green: 0.55, blue: 0.00, alpha: 1),
        UIColor(red: 0.49, green: 0.30, blue: 1.00, alpha: 1),
    ]
    static let highlighterColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        UIColor(red: 0.37, green: 0.86, blue: 0.54, alpha: 1),
        UIColor(red: 1.00, green: 0.56, blue: 0.72, alpha: 1),
        UIColor(red: 0.39, green: 0.71, blue: 1.00, alpha: 1),
        UIColor(red: 1.00, green: 0.66, blue: 0.30, alpha: 1),
    ]
    /// Line widths in page points, thinnest first.
    static let penWidths: [CGFloat] = [1.2, 1.8, 2.6, 3.8, 5.4]
    static let highlighterWidths: [CGFloat] = [9, 14, 22]
    /// The colour of the AI pen and of the marks it leaves on the page.
    static let markColor = UIColor(red: 0x6D / 255.0, green: 0x5B / 255.0, blue: 0xF6 / 255.0, alpha: 1)

    private static func pick<T>(_ list: [T], _ index: Int) -> T {
        list[min(max(index, 0), list.count - 1)]
    }

    var penUIColor: UIColor { Self.pick(Self.penColors, penColor) }

    /// The PencilKit tool this choice stands for. The formula tool does not write; while it is chosen the
    /// canvases are switched off and keep whatever they had.
    var pencilKitTool: PKTool {
        switch tool {
        case .pen, .formula:
            let ink = penKind.ink
            let allowed = ink.validWidthRange
            let width = min(max(Self.pick(Self.penWidths, penWidth), allowed.lowerBound), allowed.upperBound)
            return PKInkingTool(ink, color: penUIColor, width: width)
        case .highlighter:
            return PKInkingTool(.marker, color: Self.pick(Self.highlighterColors, highlighterColor), width: Self.pick(Self.highlighterWidths, highlighterWidth))
        case .eraser:
            return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: 16)
        case .ai:
            return PKInkingTool(.monoline, color: Self.markColor, width: 2.6)
        case .lasso:
            return PKLassoTool()
        }
    }

    /// The choice as it was left last time, tool settings and all.
    static func saved() -> InkChoice {
        guard let data = UserDefaults.standard.data(forKey: "inkChoice"),
              var choice = try? JSONDecoder().decode(InkChoice.self, from: data)
        else { return InkChoice() }
        // A document opens with something to write with in hand.
        if choice.tool == .formula || choice.tool == .lasso || choice.tool == .eraser { choice.tool = .pen }
        return choice
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "inkChoice")
        }
    }
}

/// How the pages are laid out.
enum PageLayoutMode: String, CaseIterable, Identifiable {
    case vertical, horizontal, twoUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "세로로 넘기기"
        case .horizontal: return "가로로 넘기기"
        case .twoUp: return "두 쪽씩 보기"
        }
    }

    var symbol: String {
        switch self {
        case .vertical: return "arrow.up.and.down"
        case .horizontal: return "arrow.left.and.right"
        case .twoUp: return "book"
        }
    }
}

/// What a double tap or a squeeze of the Apple Pencil asks for.
enum PencilAction {
    /// The eraser, or back from it.
    case eraser
    /// The tool that was in hand before this one.
    case previous
    /// The AI pen, or back from it.
    case ai
    /// The settings of the tool in hand.
    case options
}

/// A PencilKit canvas that remembers which page it lies on.
final class PageCanvas: PKCanvasView {
    var pageIndex = 0
    /// How many strokes the drawing had when it was last looked at; one more means a stroke was just drawn.
    var strokeCount = 0
}

/// A formula on a page: its shape, filled with its colour.
final class MathView: UIImageView {
    var item: MathItem

    init(item: MathItem, picture: UIImage?, quarterTurns: Int) {
        self.item = item
        super.init(image: picture?.withRenderingMode(.alwaysTemplate))
        tintColor = item.color
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
    private let markLines = UIView()
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
        markLines.isUserInteractionEnabled = false
        addSubview(markLines)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)
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
    var onDeleteMark: ((UUID) -> Void)?
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

    func undo() {
        coordinator?.undoManager?.undo()
    }

    func redo() {
        coordinator?.undoManager?.redo()
    }

    /// For the build server: draws a ring with the AI pen on the page in view, as a hand would have.
    func demoMark(center: CGPoint, radius: CGSize) {
        coordinator?.demoMark(center: center, radius: radius)
    }

    /// For the build server: zooms in this many times past fitting the page.
    func demoZoom(_ factor: Double) {
        coordinator?.demoZoom(factor)
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
        view.backgroundColor = .secondarySystemBackground
        let coordinator = context.coordinator
        coordinator.choice = choice
        coordinator.fingerDraws = fingerDraws
        coordinator.apply(marks: marks, active: activeMark)
        coordinator.pdfView = view
        coordinator.controller = controller
        controller.coordinator = coordinator
        coordinator.apply(layout: layout)
        // The provider has to be in place before the document, or the first pages get no overlay.
        view.pageOverlayViewProvider = coordinator
        // Markup mode makes PDFKit pass touches through to the overlays instead of selecting text.
        view.isInMarkupMode = true
        view.document = PDFDocument(url: url)
        view.addInteraction(UIPencilInteraction(delegate: coordinator))
        coordinator.watch(view)
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
        coordinator.saveAll()
        coordinator.stopWatching()
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIContextMenuInteractionDelegate, UIPencilInteractionDelegate {
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
        weak var pdfView: PDFView?
        weak var controller: ReaderController?
        var choice = InkChoice()
        var fingerDraws = false
        /// Set when the document's pages are about to be renumbered: nothing more is written from here.
        var retired = false

        init(store: DrawingStore, mathStore: MathStore) {
            self.store = store
            self.mathStore = mathStore
            self.math = mathStore.load()
        }

        /// Every canvas shares the undo history of the window it is in.
        var undoManager: UndoManager? { pdfView?.undoManager }

        func apply(choice: InkChoice, fingerDraws: Bool) {
            guard choice != self.choice || fingerDraws != self.fingerDraws else { return }
            self.choice = choice
            self.fingerDraws = fingerDraws
            for overlay in overlays.values {
                configure(overlay.canvas)
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
            view.displayMode = layout == .twoUp ? .twoUpContinuous : .singlePageContinuous
            view.displayDirection = layout == .horizontal ? .horizontal : .vertical
            view.displaysAsBook = false
            view.autoScales = true
            if let page { DispatchQueue.main.async { view.go(to: page) } }
        }

        private func configure(_ canvas: PageCanvas) {
            canvas.tool = choice.pencilKitTool
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            // With the formula tool the canvas steps aside, so that touches reach the formulas under it.
            canvas.isUserInteractionEnabled = choice.tool != .formula
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

        func saveAll() {
            guard !retired else { return }
            for overlay in overlays.values {
                store.save(overlay.canvas.drawing, page: overlay.canvas.pageIndex)
            }
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
            DispatchQueue.main.async { [weak self] in
                self?.tellPage()
                self?.tellUndo()
                self?.scaleChanged()
            }
        }

        func stopWatching() {
            watching.forEach { NotificationCenter.default.removeObserver($0) }
            watching = []
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
            let wanted = min(3, max(1, (view.scaleFactor * 4).rounded(.up) / 4))
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
            overlay(forPage: index)?.canvas.drawing ?? store.load(page: index)
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
            let canvas = overlay.canvas
            canvas.pageIndex = view.document?.index(for: page) ?? 0
            configure(canvas)
            if let saved = store.load(page: canvas.pageIndex) {
                canvas.drawing = saved
            } else if canvas.pageIndex == 0, ProcessInfo.processInfo.arguments.contains("-demoInk") {
                canvas.drawing = Self.demoDrawing()
            }
            canvas.strokeCount = canvas.drawing.strokes.count
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
            if !retired {
                store.save(overlay.canvas.drawing, page: overlay.canvas.pageIndex)
            }
            overlays[page] = nil
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // The window, and with it the undo history, may not have been there when the tool was chosen.
            holdUndoForMarks()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !retired, let canvas = canvasView as? PageCanvas else { return }
            let strokes = canvas.drawing.strokes
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
                        canvas.drawing = drawing
                    }
                    self.marked(points, on: canvas)
                }
                return
            }
            canvas.strokeCount = strokes.count
            store.save(canvas.drawing, page: canvas.pageIndex)
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
                switch system {
                case .ignore: action = nil
                case .switchPrevious: action = .previous
                case .showColorPalette, .showInkAttributes, .showContextualPalette: action = .options
                default: action = .eraser
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
            guard let overlay = overlays[page] else {
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

        func demoZoom(_ factor: Double) {
            guard let view = pdfView else { return }
            view.scaleFactor = view.scaleFactorForSizeToFit * CGFloat(factor)
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
            let view = MathView(item: item, picture: picture, quarterTurns: overlay.quarterTurns)
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
