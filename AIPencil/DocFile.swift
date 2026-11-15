import PDFKit
import UIKit

/// A page the reader added to a document: where it stands and what paper it is.
struct AddedPage: Codable, Equatable {
    /// The page's place in the document, counted from zero, once the pages listed before this one are in.
    var index: Int
    var paper: PaperKind
    /// The size of the page in points, as it is shown.
    var width: Double
    var height: Double
}

/// Has a document make its pages of the kind that can be shown as dark paper.
final class InkPageMaker: NSObject, PDFDocumentDelegate {
    static let shared = InkPageMaker()

    func classForPage() -> AnyClass { InkPage.self }
}

/// A document as the app keeps it: the PDF as it was brought in and, beside it, a list of the pages
/// added since. The PDF is never written again. PDFKit writes a file by drawing its pages anew, and in
/// such a copy the letters of many fonts no longer say what they are: text read from it, to search or
/// to send along with a question, comes out as other letters.
enum DocFile {
    private static func listURL(for pdfURL: URL) -> URL {
        pdfURL.deletingLastPathComponent().appendingPathComponent("pages.json")
    }

    static func addedPages(of pdfURL: URL) -> [AddedPage] {
        guard let data = try? Data(contentsOf: listURL(for: pdfURL)),
              let pages = try? JSONDecoder().decode([AddedPage].self, from: data) else { return [] }
        return pages
    }

    /// Notes one more added page. It takes its place the next time the document is opened.
    static func add(_ page: AddedPage, to pdfURL: URL) throws {
        let data = try JSONEncoder().encode(addedPages(of: pdfURL) + [page])
        try data.write(to: listURL(for: pdfURL), options: .atomic)
    }

    /// The document with its added pages in place. A [delegate] becomes the document's before any page
    /// is made, and the added pages are then of the kind that can be shown as dark paper, like the rest.
    static func open(_ pdfURL: URL, delegate: PDFDocumentDelegate? = nil) -> PDFDocument? {
        guard let document = PDFDocument(url: pdfURL) else { return nil }
        document.delegate = delegate
        for added in addedPages(of: pdfURL) {
            let size = CGSize(width: added.width, height: added.height)
            // A page there must be, or every later page would stand one place too early.
            let page = Paper.page(added.paper, size: size, darkens: delegate != nil) ?? PDFPage()
            document.insert(page, at: min(max(added.index, 0), document.pageCount))
        }
        return document
    }
}
