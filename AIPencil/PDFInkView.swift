import PDFKit
import PencilKit
import SwiftUI

/// A PencilKit canvas that remembers which page it lies on.
final class PageCanvas: PKCanvasView {
    var pageIndex = 0
}

/// The reading and writing surface: PDFKit shows and scrolls the pages, and on every page it lays one
/// PencilKit canvas (iPadOS 16's page overlay) that takes the handwriting. PDFKit sizes each canvas to its
/// page and zooms it with the page, so a drawing is stored in the page's own coordinates.
struct PDFInkView: UIViewRepresentable {
    let url: URL
    let store: DrawingStore
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
        // The provider has to be in place before the document, or the first pages get no overlay.
        view.pageOverlayViewProvider = context.coordinator
        // Markup mode makes PDFKit pass touches through to the overlays instead of selecting text.
        view.isInMarkupMode = true
        context.coordinator.fingerDraws = fingerDraws
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.setFingerDraws(fingerDraws)
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.saveAll()
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        private let store: DrawingStore
        private var canvases: [PDFPage: PageCanvas] = [:]
        /// The system's floating palette of pens, eraser, lasso and ruler.
        private let toolPicker = PKToolPicker()
        var fingerDraws = false

        init(store: DrawingStore) {
            self.store = store
        }

        func setFingerDraws(_ on: Bool) {
            guard on != fingerDraws else { return }
            fingerDraws = on
            for canvas in canvases.values {
                canvas.drawingPolicy = on ? .anyInput : .pencilOnly
            }
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
            canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            if let saved = store.load(page: canvas.pageIndex) {
                canvas.drawing = saved
            }
            canvas.delegate = self
            toolPicker.addObserver(canvas)
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvases[page] = canvas
            return canvas
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            // The palette shows for whichever canvas is first responder; the page coming on screen takes it.
            overlayView.becomeFirstResponder()
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? PageCanvas else { return }
            store.save(canvas.drawing, page: canvas.pageIndex)
            toolPicker.removeObserver(canvas)
            canvases[page] = nil
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let canvas = canvasView as? PageCanvas else { return }
            store.save(canvas.drawing, page: canvas.pageIndex)
        }
    }
}
