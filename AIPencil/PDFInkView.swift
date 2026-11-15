import PDFKit
import PencilKit
import SwiftUI

/// The tools of the tool bar.
enum InkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, formula

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .lasso: return "올가미"
        case .formula: return "수식 옮기기"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
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

    /// The PencilKit tool this choice stands for. Widths are in page points. The formula tool does not write;
    /// while it is chosen the canvases are switched off and keep whatever they had.
    var pencilKitTool: PKTool {
        switch tool {
        case .pen, .formula: return PKInkingTool(.pen, color: Self.penColors[penColor], width: 2.2)
        case .highlighter: return PKInkingTool(.marker, color: Self.highlighterColors[highlighterColor], width: 14)
        case .eraser: return PKEraserTool(.vector)
        case .lasso: return PKLassoTool()
        }
    }
}

/// A PencilKit canvas that remembers which page it lies on.
final class PageCanvas: PKCanvasView {
    var pageIndex = 0
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

/// What PDFKit lays over a page: the page's formulas, and above them the canvas that takes the handwriting.
/// PDFKit sizes this view to the page and zooms it with the page, so a point in it is a point of the page,
/// measured from the page's top-left corner.
final class PageOverlay: UIView {
    let canvas = PageCanvas()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
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
        insertSubview(view, belowSubview: canvas)
    }

    var mathViews: [MathView] {
        subviews.compactMap { $0 as? MathView }
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
}

/// The reading and writing surface: PDFKit shows and scrolls the pages, and on every page it lays one
/// overlay (iPadOS 16's page overlay) holding the page's formulas and a PencilKit canvas.
struct PDFInkView: UIViewRepresentable {
    let url: URL
    let store: DrawingStore
    let mathStore: MathStore
    var choice: InkChoice
    /// Off: only Apple Pencil writes and fingers scroll. On: fingers write too.
    var fingerDraws: Bool
    /// The page to show first.
    var startPage: Int
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
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate, UIContextMenuInteractionDelegate {
        private let store: DrawingStore
        private let mathStore: MathStore
        private var overlays: [PDFPage: PageOverlay] = [:]
        private var math: [MathItem]
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
                canvas.drawing = Self.demoDrawing()
            }
            canvas.delegate = self
            for item in math where item.page == canvas.pageIndex {
                install(item, in: overlay)
            }
            overlays[page] = overlay
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
            store.save(canvas.drawing, page: canvas.pageIndex)
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

        /// A ring drawn by code, for the build server: its pictures cannot show anyone writing, and this shows
        /// whether ink lands where its coordinates say. The ring is placed, in page points measured from the
        /// page's top-left corner, round the heading of the bundled sample's first page.
        private static func demoDrawing() -> PKDrawing {
            let center = CGPoint(x: 130, y: 88)
            let radius = CGSize(width: 86, height: 22)
            var points: [PKStrokePoint] = []
            for i in 0...48 {
                let t = Double(i) / 48 * 2 * Double.pi
                let location = CGPoint(x: center.x + radius.width * CGFloat(cos(t)), y: center.y + radius.height * CGFloat(sin(t)))
                points.append(PKStrokePoint(
                    location: location, timeOffset: Double(i) * 0.01, size: CGSize(width: 2.4, height: 2.4),
                    opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2
                ))
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date())
            return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemRed), path: path)])
        }
    }
}
