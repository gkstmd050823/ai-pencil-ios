import PDFKit
import PencilKit
import SwiftUI

/// The tools of the tool bar.
enum InkTool: String, CaseIterable, Identifiable {
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

/// What is in the user's hand: a tool, and for the pen and the highlighter a colour.
struct InkChoice: Equatable {
    var tool: InkTool = .pen
    var penColor = 0
    var highlighterColor = 0

    static let penColors: [UIColor] = [
        UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        UIColor(red: 0.12, green: 0.44, blue: 0.92, alpha: 1),
        UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1),
    ]
    static let highlighterColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        UIColor(red: 0.37, green: 0.86, blue: 0.54, alpha: 1),
        UIColor(red: 1.00, green: 0.56, blue: 0.72, alpha: 1),
    ]
    /// The colour of the AI pen and of the marks it leaves on the page.
    static let markColor = UIColor(red: 0x6D / 255.0, green: 0x5B / 255.0, blue: 0xF6 / 255.0, alpha: 1)

    /// The PencilKit tool this choice stands for. Widths are in page points. The formula tool does not write;
    /// while it is chosen the canvases are switched off and keep whatever they had.
    var pencilKitTool: PKTool {
        switch tool {
        case .pen, .formula: return PKInkingTool(.pen, color: Self.penColors[penColor], width: 2.2)
        case .highlighter: return PKInkingTool(.marker, color: Self.highlighterColors[highlighterColor], width: 14)
        case .eraser: return PKEraserTool(.vector)
        case .ai: return PKInkingTool(.pen, color: Self.markColor, width: 2.6)
        case .lasso: return PKLassoTool()
        }
    }
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

    init(item: MathItem, picture: UIImage?) {
        self.item = item
        super.init(image: picture?.withRenderingMode(.alwaysTemplate))
        frame = item.frame
        tintColor = item.color
        contentMode = .scaleToFill
        isUserInteractionEnabled = true
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        // The paper is white whatever the iPad's appearance. PencilKit would otherwise turn dark ink
        // light on a dark screen, and it would vanish on the page.
        overrideUserInterfaceStyle = .light
        markLines.isUserInteractionEnabled = false
        markLines.frame = bounds
        markLines.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(markLines)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.frame = bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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

    // Each button sits at the top-right corner of its mark, kept inside the page.
    override func layoutSubviews() {
        super.layoutSubviews()
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
    /// Called when the user asks to edit a formula.
    var onEditMath: ((MathItem) -> Void)?
    /// Called when the user drew a mark with the AI pen: the page, and the mark in page points.
    var onMark: ((Int, [CGPoint]) -> Void)?
    /// Called when the user touched a mark to read its explanation again.
    var onOpenMark: ((UUID) -> Void)?
    var onHideMark: ((UUID) -> Void)?
    var onDeleteMark: ((UUID) -> Void)?

    var currentPageIndex: Int? { coordinator?.currentPageIndex }
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

    /// For the build server: draws a ring with the AI pen on the page in view, as a hand would have.
    func demoMark(center: CGPoint, radius: CGSize) {
        coordinator?.demoMark(center: center, radius: radius)
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
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        let coordinator = context.coordinator
        coordinator.choice = choice
        coordinator.fingerDraws = fingerDraws
        coordinator.apply(marks: marks, active: activeMark)
        coordinator.pdfView = view
        coordinator.controller = controller
        controller.coordinator = coordinator
        // The provider has to be in place before the document, or the first pages get no overlay.
        view.pageOverlayViewProvider = coordinator
        // Markup mode makes PDFKit pass touches through to the overlays instead of selecting text.
        view.isInMarkupMode = true
        view.document = PDFDocument(url: url)
        if startPage > 0, let page = view.document?.page(at: startPage) {
            // Once the view has been laid out; going to a page before that does nothing.
            DispatchQueue.main.async { view.go(to: page) }
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.apply(choice: choice, fingerDraws: fingerDraws)
        context.coordinator.apply(marks: marks, active: activeMark)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIContextMenuInteractionDelegate {
        private let store: DrawingStore
        private let mathStore: MathStore
        private var overlays: [PDFPage: PageOverlay] = [:]
        private var math: [MathItem]
        private var marks: [Question] = []
        private var activeMark: UUID?
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

        func apply(choice: InkChoice, fingerDraws: Bool) {
            guard choice != self.choice || fingerDraws != self.fingerDraws else { return }
            self.choice = choice
            self.fingerDraws = fingerDraws
            for overlay in overlays.values {
                configure(overlay.canvas)
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

        private func configure(_ canvas: PageCanvas) {
            canvas.tool = choice.pencilKitTool
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            // With the formula tool the canvas steps aside, so that touches reach the formulas under it.
            canvas.isUserInteractionEnabled = choice.tool != .formula
        }

        func saveAll() {
            guard !retired else { return }
            for overlay in overlays.values {
                store.save(overlay.canvas.drawing, page: overlay.canvas.pageIndex)
            }
        }

        var currentPageIndex: Int? {
            guard let view = pdfView, let page = view.currentPage else { return nil }
            return view.document?.index(for: page)
        }

        var currentPageSize: CGSize? {
            guard let page = pdfView?.currentPage else { return nil }
            return overlays[page]?.bounds.size ?? page.bounds(for: .cropBox).size
        }

        func pageShape(forPage index: Int) -> AskCapture.Shape? {
            guard let page = pdfView?.document?.page(at: index) else { return nil }
            return AskCapture.shape(of: page)
        }

        func drawing(forPage index: Int) -> PKDrawing? {
            overlay(forPage: index)?.canvas.drawing ?? store.load(page: index)
        }

        // MARK: PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            if let existing = overlays[page] { return existing }
            let overlay = PageOverlay(frame: .zero)
            let canvas = overlay.canvas
            canvas.pageIndex = view.document?.index(for: page) ?? 0
            configure(canvas)
            if let saved = store.load(page: canvas.pageIndex) {
                canvas.drawing = saved
            } else if canvas.pageIndex == 0, ProcessInfo.processInfo.arguments.contains("-demoInk") {
                canvas.drawing = PKDrawing(strokes: [Self.ring(center: CGPoint(x: 130, y: 88), radius: CGSize(width: 86, height: 22), color: .systemRed)])
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

        func demoMark(center: CGPoint, radius: CGSize) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else {
                DebugLog.write("demo mark: no page to draw on")
                return
            }
            DebugLog.write("overlay: page \(overlay.canvas.pageIndex) bounds \(overlay.bounds.size) page shown \(AskCapture.shape(of: page).size) turned \(page.rotation)")
            var drawing = overlay.canvas.drawing
            drawing.strokes.append(Self.ring(center: center, radius: radius, color: InkChoice.markColor))
            overlay.canvas.drawing = drawing
        }

        // MARK: formulas

        @discardableResult
        private func install(_ item: MathItem, in overlay: PageOverlay) -> MathView {
            let picture = UIImage(contentsOfFile: mathStore.imageURL(item.image).path)
            let view = MathView(item: item, picture: picture)
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

        /// Puts a new formula in the middle of what is showing of the current page.
        func placeMath(_ result: MathResult, color: UIColor) {
            guard let view = pdfView, let page = view.currentPage, let overlay = overlays[page] else { return }
            let middle = overlay.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
            let size = result.size
            let x = min(max(0, middle.x - size.width / 2), max(0, overlay.bounds.width - size.width))
            let y = min(max(0, middle.y - size.height / 2), max(0, overlay.bounds.height - size.height))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let item = MathItem(
                page: overlay.canvas.pageIndex, latex: result.latex, image: result.image,
                x: Double(x), y: Double(y), width: Double(size.width), height: Double(size.height),
                red: Double(red), green: Double(green), blue: Double(blue)
            )
            math.append(item)
            saveMath()
            install(item, in: overlay)
        }

        /// Swaps a formula for an edited one, keeping its place (its top-left corner) and its colour.
        func replaceMath(_ old: MathItem, with result: MathResult) {
            guard let at = math.firstIndex(where: { $0.id == old.id }) else { return }
            var item = math[at]
            item.latex = result.latex
            item.image = result.image
            item.width = Double(result.size.width)
            item.height = Double(result.size.height)
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
            copy.x = min(source.x + 14, max(0, Double(overlay.bounds.width) - source.width))
            copy.y = min(source.y + 14, max(0, Double(overlay.bounds.height) - source.height))
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
            guard let view = gesture.view as? MathView, let overlay = view.superview else { return }
            let by = gesture.translation(in: overlay)
            var frame = view.frame.offsetBy(dx: by.x, dy: by.y)
            frame.origin.x = min(max(0, frame.origin.x), max(0, overlay.bounds.width - frame.width))
            frame.origin.y = min(max(0, frame.origin.y), max(0, overlay.bounds.height - frame.height))
            view.frame = frame
            gesture.setTranslation(.zero, in: overlay)
            if gesture.state == .ended || gesture.state == .cancelled {
                view.item.x = Double(frame.origin.x)
                view.item.y = Double(frame.origin.y)
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

        /// A ring drawn by code, for the build server: its pictures cannot show anyone writing, and this
        /// shows whether ink lands where its coordinates say. Places are in page points, measured from the
        /// page's top-left corner.
        private static func ring(center: CGPoint, radius: CGSize, color: UIColor) -> PKStroke {
            var points: [PKStrokePoint] = []
            for i in 0...48 {
                let t = Double(i) / 48 * 2 * Double.pi
                let location = CGPoint(x: center.x + radius.width * CGFloat(cos(t)), y: center.y + radius.height * CGFloat(sin(t)))
                points.append(PKStrokePoint(
                    location: location, timeOffset: Double(i) * 0.01, size: CGSize(width: 2.4, height: 2.4),
                    opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                ))
            }
            return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
    }
}
