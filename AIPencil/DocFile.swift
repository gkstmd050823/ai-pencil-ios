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

    /// The document as it is shown: for each page, nil when it is one of the PDF's own [ownCount] pages,
    /// and otherwise which of the added pages it is (its place in the list).
    static func layout(_ added: [AddedPage], ownCount: Int) -> [Int?] {
        var shown = [Int?](repeating: nil, count: max(ownCount, 0))
        for (at, page) in added.enumerated() {
            shown.insert(at, at: min(max(page.index, 0), shown.count))
        }
        return shown
    }

    /// How many of the PDF's own pages stand at page [index] of the document as shown, or before it.
    static func ownPages(through index: Int, added: [AddedPage], ownCount: Int) -> Int {
        layout(added, ownCount: ownCount).prefix(max(index + 1, 0)).filter { $0 == nil }.count
    }

    /// The list of added pages once [count] pages have been put into the PDF itself right after page
    /// [index] of the document as shown: the added pages that stood later stand [count] pages later. The
    /// list comes back in the order the pages stand in, which is an order they can be put in one by one.
    static func relisted(_ added: [AddedPage], ownCount: Int, after index: Int, by count: Int) -> [AddedPage] {
        var out: [AddedPage] = []
        for (place, which) in layout(added, ownCount: ownCount).enumerated() {
            guard let which else { continue }
            var page = added[which]
            page.index = place > index ? place + count : place
            out.append(page)
        }
        return out
    }

    /// Writes the list of added pages over the one that was there.
    static func replaceAdded(_ pages: [AddedPage], of pdfURL: URL) {
        let url = listURL(for: pdfURL)
        if pages.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: url, options: .atomic)
        }
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
