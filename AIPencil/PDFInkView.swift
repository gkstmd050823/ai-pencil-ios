import PDFKit
import PencilKit
import SwiftUI

/// The writing tools of the tool bar.
enum InkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .lasso: return "올가미"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
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

    /// The PencilKit tool this choice stands for. Widths are in page points.
    var pencilKitTool: PKTool {
        switch tool {
        case .pen: return PKInkingTool(.pen, color: Self.penColors[penColor], width: 2.2)
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

/// The reading and writing surface: PDFKit shows and scrolls the pages, and on every page it lays one
/// PencilKit canvas (iPadOS 16's page overlay) that takes the handwriting. PDFKit sizes each canvas to its
/// page and zooms it with the page, so a point on a canvas is a point of the page, measured from the page's
/// top-left corner (checked on the build server with a ring drawn round a heading).
struct PDFInkView: UIViewRepresentable {
    let url: URL
    let store: DrawingStore
    var choice: InkChoice
    /// Off: only Apple Pencil writes and fingers scroll. On: fingers write too.
    var fingerDraws: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.pageShadowsEnabled = true
        view.backgroundColor = .secondarySystemBackground
        context.coordinator.choice = choice
        context.coordinator.fingerDraws = fingerDraws
        // The provider has to be in place before the document, or the first pages get no overlay.
        view.pageOverlayViewProvider = context.coordinator
        // Markup mode makes PDFKit pass touches through to the overlays instead of selecting text.
        view.isInMarkupMode = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.apply(choice: choice, fingerDraws: fingerDraws)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        private let store: DrawingStore
        private var canvases: [PDFPage: PageCanvas] = [:]
        var choice = InkChoice()
        var fingerDraws = false

        init(store: DrawingStore) {
            self.store = store
        }

        func apply(choice: InkChoice, fingerDraws: Bool) {
            guard choice != self.choice || fingerDraws != self.fingerDraws else { return }
            self.choice = choice
            self.fingerDraws = fingerDraws
            for canvas in canvases.values {
                configure(canvas)
            }
        }

        private func configure(_ canvas: PageCanvas) {
            canvas.tool = choice.pencilKitTool
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        }

        func saveAll() {
            for canvas in canvases.values {
                store.save(canvas.drawing, page: canvas.pageIndex)
            }
        }

        // MARK: PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            if let existing = canvases[page] { return existing }
            let canvas = PageCanvas(frame: .zero)
            canvas.pageIndex = view.document?.index(for: page) ?? 0
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            configure(canvas)
            if let saved = store.load(page: canvas.pageIndex) {
                canvas.drawing = saved
            } else if canvas.pageIndex == 0, ProcessInfo.processInfo.arguments.contains("-demoInk") {
                canvas.drawing = Self.demoDrawing()
            }
            canvas.delegate = self
            canvases[page] = canvas
            return canvas
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? PageCanvas else { return }
            store.save(canvas.drawing, page: canvas.pageIndex)
            canvases[page] = nil
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

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let canvas = canvasView as? PageCanvas else { return }
            store.save(canvas.drawing, page: canvas.pageIndex)
        }
    }
}
