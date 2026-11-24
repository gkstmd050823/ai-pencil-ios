import Compression
import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import WebKit

/// The kinds of file, other than PDF, that can be brought in. Each is made into a PDF first: the pages,
/// the pen and the AI pen all work on PDF pages.
enum ForeignKind {
    case word, slides, sheet, text, epub

    static func of(_ url: URL) -> ForeignKind? {
        switch url.pathExtension.lowercased() {
        case "doc", "docx": return .word
        case "ppt", "pptx": return .slides
        case "xls", "xlsx": return .sheet
        case "rtf": return .text
        case "epub": return .epub
        default: return nil
        }
    }

    private static let identifiers = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
        "org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
        "public.rtf", "org.idpf.epub-container",
    ]

    /// What the file picker offers: PDFs and these.
    static var pickable: [UTType] {
        var types: [UTType] = [.pdf]
        for identifier in identifiers {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }
}

enum ConvertError: LocalizedError {
    case unreadable
    case nothing
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "이 파일은 PDF로 바꾸지 못했어요. 손상됐거나 암호·DRM이 걸린 파일일 수 있어요."
        case .nothing: return "이 파일에서는 쪽이 나오지 않았어요. 내용이 비어 있거나 읽을 수 없는 형식이에요."
        case .unwritable: return "바꾼 PDF를 저장하지 못했어요. 아이패드에 남은 공간이 있는지 확인해 주세요."
        }
    }
}

// MARK: zip

/// Reads a zip file: an EPUB is one. (Stored and deflated entries, which is all an EPUB may have.)
struct ZipFile {
    struct Entry {
        let name: String
        let method: Int
        let packed: Int
        let size: Int
        let offset: Int
    }

    private let data: Data
    let entries: [Entry]

    private static func u16(_ data: Data, _ at: Int) -> Int {
        let start = data.startIndex + at
        return Int(data[start]) | (Int(data[start + 1]) << 8)
    }

    private static func u32(_ data: Data, _ at: Int) -> Int {
        u16(data, at) | (u16(data, at + 2) << 16)
    }

    init?(_ data: Data) {
        let count = data.count
        guard count >= 22 else { return nil }
        // The list of what is in the file is at its end, after a mark that is looked for backwards.
        var at = count - 22
        let lowest = max(0, count - 22 - 65535)
        var found = -1
        while at >= lowest {
            if ZipFile.u32(data, at) == 0x0605_4B50 {
                found = at
                break
            }
            at -= 1
        }
        guard found >= 0 else { return nil }
        let number = ZipFile.u16(data, found + 10)
        var place = ZipFile.u32(data, found + 16)
        var list: [Entry] = []
        var index = 0
        while index < number {
            guard place + 46 <= count, ZipFile.u32(data, place) == 0x0201_4B50 else { return nil }
            let nameLength = ZipFile.u16(data, place + 28)
            let extra = ZipFile.u16(data, place + 30)
            let comment = ZipFile.u16(data, place + 32)
            guard place + 46 + nameLength <= count else { return nil }
            let from = data.startIndex + place + 46
            let name = String(decoding: data[from..<(from + nameLength)], as: UTF8.self)
            list.append(Entry(
                name: name, method: ZipFile.u16(data, place + 10), packed: ZipFile.u32(data, place + 20),
                size: ZipFile.u32(data, place + 24), offset: ZipFile.u32(data, place + 42)
            ))
            place += 46 + nameLength + extra + comment
            index += 1
        }
        self.data = data
        entries = list
    }

    func read(_ entry: Entry) -> Data? {
        let head = entry.offset
        guard head + 30 <= data.count, ZipFile.u32(data, head) == 0x0403_4B50 else { return nil }
        let start = head + 30 + ZipFile.u16(data, head + 26) + ZipFile.u16(data, head + 28)
        guard entry.packed >= 0, start + entry.packed <= data.count else { return nil }
        let from = data.startIndex + start
        let body = data.subdata(in: from..<(from + entry.packed))
        if entry.method == 0 { return body }
        guard entry.method == 8, entry.size <= 400_000_000 else { return nil }
        if entry.size == 0 { return Data() }
        let size = entry.size
        let room = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { room.deallocate() }
        let wrote = body.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(room, size, base, body.count, nil, COMPRESSION_ZLIB)
        }
        guard wrote == size else { return nil }
        return Data(bytes: room, count: size)
    }
}

// MARK: epub

/// An EPUB taken apart into a folder: its chapters in reading order, as paths under that folder.
struct Epub: Codable {
    var title: String
    var chapters: [String]
    var names: [String]

    private final class Tags: NSObject, XMLParserDelegate {
        var rootfile: String?
        var items: [String: String] = [:]
        var spine: [String] = []
        var title: String?
        private var inTitle = false
        private var text = ""

        private func plain(_ name: String) -> String {
            let last = name.split(separator: ":").last.map(String.init) ?? name
            return last.lowercased()
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            switch plain(elementName) {
            case "rootfile":
                if rootfile == nil { rootfile = attributeDict["full-path"] }
            case "item":
                if let id = attributeDict["id"], let href = attributeDict["href"] { items[id] = href }
            case "itemref":
                if let id = attributeDict["idref"] { spine.append(id) }
            case "title":
                if title == nil {
                    inTitle = true
                    text = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if inTitle, plain(elementName) == "title" {
                inTitle = false
                let found = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !found.isEmpty { title = found }
            }
        }
    }

    private static func tags(of data: Data) -> Tags {
        let tags = Tags()
        let parser = XMLParser(data: data)
        parser.delegate = tags
        parser.parse()
        return tags
    }

    /// Takes the file apart into [root] (made new) and reads which of its files are the chapters.
    static func unpack(_ file: URL, to root: URL) throws -> Epub {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), let zip = ZipFile(data) else { throw ConvertError.unreadable }
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.standardizedFileURL.path
        for entry in zip.entries {
            if entry.name.hasSuffix("/") || entry.name.hasPrefix("/") { continue }
            let target = root.appendingPathComponent(entry.name).standardizedFileURL
            // (Nothing is written outside the folder, whatever the file calls its parts.)
            guard target.path.hasPrefix(base + "/") else { continue }
            guard let body = zip.read(entry) else { continue }
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: target)
        }
        guard let container = try? Data(contentsOf: root.appendingPathComponent("META-INF/container.xml")),
              let packagePath = tags(of: container).rootfile,
              let package = try? Data(contentsOf: root.appendingPathComponent(packagePath)) else { throw ConvertError.unreadable }
        let read = tags(of: package)
        let folder = (packagePath as NSString).deletingLastPathComponent
        var chapters: [String] = []
        var names: [String] = []
        for id in read.spine {
            guard var href = read.items[id] else { continue }
            if let mark = href.firstIndex(of: "#") { href = String(href[..<mark]) }
            let decoded = href.removingPercentEncoding ?? href
            let path = folder.isEmpty ? decoded : folder + "/" + decoded
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(base + "/"), manager.fileExists(atPath: url.path) else { continue }
            let relative = String(url.path.dropFirst(base.count + 1))
            if chapters.contains(relative) { continue }
            chapters.append(relative)
            names.append(heading(of: url) ?? "\(chapters.count)")
        }
        guard !chapters.isEmpty else { throw ConvertError.unreadable }
        let book = Epub(title: read.title ?? file.deletingPathExtension().lastPathComponent, chapters: chapters, names: names)
        book.save(to: root)
        return book
    }

    /// What a chapter calls itself: its title, or its first heading.
    private static func heading(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let text = String(decoding: data.prefix(60000), as: UTF8.self)
        for tag in ["h1", "h2", "title", "h3"] {
            guard let open = text.range(of: "<\(tag)", options: .caseInsensitive),
                  let begin = text.range(of: ">", range: open.upperBound..<text.endIndex),
                  let close = text.range(of: "</\(tag)", options: .caseInsensitive, range: begin.upperBound..<text.endIndex) else { continue }
            var inner = String(text[begin.upperBound..<close.lowerBound])
            inner = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            inner = inner.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            inner = inner.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, inner.count <= 80 { return inner }
        }
        return nil
    }

    func save(to root: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: root.appendingPathComponent("aipencil-book.json"), options: .atomic)
    }

    static func load(_ root: URL) -> Epub? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("aipencil-book.json")) else { return nil }
        return try? JSONDecoder().decode(Epub.self, from: data)
    }
}

// MARK: pages out of a web view

/// A web view that is not looked at: a file is shown in it, and what it shows is taken as PDF pages.
/// (WebKit shows Word, PowerPoint and Excel files itself, as the Files app's preview does.)
@MainActor
final class WebPages: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var waiting: CheckedContinuation<Bool, Never>?
    private var turn = 0

    init(size: CGSize, scripts: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = scripts
        web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.isUserInteractionEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // Under everything else of the window: a web view that is in no window may show nothing.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        if let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first {
            window.insertSubview(web, at: 0)
        }
    }

    func close() {
        web.stopLoading()
        web.navigationDelegate = nil
        web.removeFromSuperview()
    }

    /// Shows [file]; false when it could not be shown.
    func show(_ file: URL, access: URL) async -> Bool {
        turn += 1
        let mine = turn
        let shown = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiting = continuation
            web.loadFileURL(file, allowingReadAccessTo: access)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.turn == mine else { return }
                self.done(false)
            }
        }
        return shown
    }

    private func done(_ shown: Bool) {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(returning: shown)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        done(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        done(false)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // (Nothing is fetched from the network for a file being converted.)
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(scheme == "http" || scheme == "https" ? .cancel : .allow)
    }

    /// Runs a script that gives a string back.
    func run(_ script: String) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            web.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Waits until the pictures of what is shown are there (two seconds at most).
    func settle() async {
        var tries = 0
        while tries < 20 {
            let state = await run("(function(){var a=document.images,i;for(i=0;i<a.length;i++){if(!a[i].complete)return 'no';}return 'yes';})()")
            if state != "no" { break }
            await pause(0.1)
            tries += 1
        }
        await pause(0.15)
    }

    /// How wide and how high what is shown is, in the web view's points.
    func extent() async -> CGSize {
        let text = await run("(function(){var d=document.documentElement,b=document.body||d;return Math.max(d.scrollWidth,b.scrollWidth)+' '+Math.max(d.scrollHeight,b.scrollHeight);})()")
        let parts = text.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return .zero }
        return CGSize(width: parts[0], height: parts[1])
    }

    private static let cutter = #"""
    (function(H){
      var boxes=[],total=Math.max(document.documentElement.scrollHeight,(document.body||document.documentElement).scrollHeight);
      try{
        var walker=document.createTreeWalker(document.body||document.documentElement,NodeFilter.SHOW_TEXT),range=document.createRange(),node;
        while((node=walker.nextNode())){
          if(!node.nodeValue||!node.nodeValue.trim())continue;
          range.selectNodeContents(node);
          var rects=range.getClientRects();
          for(var i=0;i<rects.length;i++){if(rects[i].height>0&&rects[i].height<H*0.9)boxes.push([rects[i].top+window.scrollY,rects[i].bottom+window.scrollY]);}
        }
        var solid=document.querySelectorAll('img,svg,canvas,video,tr,.slide');
        for(var k=0;k<solid.length;k++){var b=solid[k].getBoundingClientRect();if(b.height>0&&b.height<=H)boxes.push([b.top+window.scrollY,b.bottom+window.scrollY]);}
      }catch(e){}
      var cuts=[0],y=0,guard=0;
      while(y+H<total&&guard++<5000){
        var cut=y+H,moved=true,again=0;
        while(moved&&again++<60){
          moved=false;
          for(var j=0;j<boxes.length;j++){var box=boxes[j];if(box[0]<cut-0.5&&box[1]>cut+0.5&&box[0]>y+1){cut=box[0]-1;moved=true;}}
        }
        if(cut<=y+H*0.2)cut=y+H;
        cuts.push(cut);y=cut;
      }
      cuts.push(total);
      return cuts.join(' ');
    })(HEIGHT)
    """#

    /// Where what is shown can be cut into pages no higher than [height] without cutting through a
    /// line of words, a picture or a row of a table: the top of the first page, of the second, ..., and
    /// the bottom of the last.
    func cuts(height: CGFloat) async -> [CGFloat] {
        let script = WebPages.cutter.replacingOccurrences(of: "HEIGHT", with: String(Double(height)))
        let text = await run(script)
        return text.split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
    }

    /// A part of what is shown, as a PDF of one page.
    func piece(_ rect: CGRect) async -> Data? {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            web.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }

    /// What is shown as the printer would get it: pages of [paper] with [margin] left free all round.
    func printed(paper: CGSize, margin: CGFloat) -> Data {
        let renderer = Sheets(paper: paper, margin: margin)
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, CGRect(origin: .zero, size: paper), nil)
        let count = renderer.numberOfPages
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: count))
        var index = 0
        while index < count {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
            index += 1
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private final class Sheets: UIPrintPageRenderer {
        private let paper: CGRect
        private let inside: CGRect

        init(paper: CGSize, margin: CGFloat) {
            self.paper = CGRect(origin: .zero, size: paper)
            inside = self.paper.insetBy(dx: margin, dy: margin)
            super.init()
        }

        override var paperRect: CGRect { paper }
        override var printableRect: CGRect { inside }
    }
}

/// Writes PDF pages into a file one after another.
final class PageBinder {
    private let context: CGContext
    private let size: CGSize
    private let margin: CGFloat
    private(set) var pages = 0

    /// Pages [size] large; what is put on one stands [margin] below its top.
    init?(url: URL, size: CGSize, margin: CGFloat) {
        var box = CGRect(origin: .zero, size: size)
        guard let made = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        context = made
        self.size = size
        self.margin = margin
    }

    /// Every page of [data] on a page of its own: as large as the page itself when [asItIs], else made
    /// as wide as this file's pages and put at the top of one.
    func add(_ data: Data, asItIs: Bool = false) {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), pdf.numberOfPages > 0 else { return }
        var number = 1
        while number <= pdf.numberOfPages {
            defer { number += 1 }
            guard let page = pdf.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { continue }
            if asItIs {
                var own = CGRect(x: 0, y: 0, width: box.width, height: box.height)
                let media = Data(bytes: &own, count: MemoryLayout<CGRect>.size)
                let info = [kCGPDFContextMediaBox as String: media] as CFDictionary
                context.beginPDFPage(info)
                context.saveGState()
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            } else {
                let scale = size.width / box.width
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: size.height - margin - box.height * scale)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -box.minX, y: -box.minY)
                context.drawPDFPage(page)
                context.restoreGState()
                context.endPDFPage()
            }
            pages += 1
        }
    }

    func close() {
        context.closePDF()
    }
}

// MARK: converting

/// Makes a PDF of a Word, PowerPoint or Excel file or an EPUB.
@MainActor
enum Converter {
    /// Two ways to get pages out of the web view: cut where no line is cut through, or as printed.
    enum Way {
        case sliced, printed
    }

    /// The way each kind is made into pages when none is asked for: a Word file and a workbook as
    /// printed (the printer leaves a margin and fills its pages), a deck slide by slide and a book
    /// cut between its lines on pages of a book's size.
    static func way(for kind: ForeignKind) -> Way {
        switch kind {
        case .slides, .epub: return .sliced
        case .word, .sheet, .text: return .printed
        }
    }

    struct Made {
        /// The PDF, in a folder of its own that is to be thrown away once it has been copied.
        let pdf: URL
        /// For an EPUB, the folder it was taken apart into.
        let book: URL?
        let title: String
    }

    /// A copy of a file that was picked, in a new folder of the app's own: a picked file can only be
    /// read for a moment, and the web view reads it later.
    nonisolated static func borrow(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("convert-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("source." + source.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw ConvertError.unreadable
        }
        return copy
    }

    /// [file] is a copy made by [borrow]; [name] is what the document is to be called.
    static func convert(_ file: URL, kind: ForeignKind, name: String, way asked: Way? = nil, progress: ((String) -> Void)? = nil) async throws -> Made {
        let way = asked ?? Converter.way(for: kind)
        let folder = file.deletingLastPathComponent()
        let target = folder.appendingPathComponent("converted.pdf")
        try? FileManager.default.removeItem(at: target)
        let began = Date()
        var book: URL?
        var title = name
        var count = 0
        if kind == .epub {
            let root = folder.appendingPathComponent("book", isDirectory: true)
            let read = try Epub.unpack(file, to: root)
            book = root
            if name.isEmpty { title = read.title }
            count = try await bookPages(read, root: root, to: target, way: way, progress: progress)
        } else {
            count = try await officePages(file, kind: kind, to: target, way: way)
        }
        guard count > 0, let check = PDFDocument(url: target), check.pageCount > 0 else { throw ConvertError.nothing }
        let took = Date().timeIntervalSince(began)
        DebugLog.write("convert: \(file.pathExtension) made into \(check.pageCount) pages in \(String(format: "%.1f", took)) s (\(way == .sliced ? "cut" : "printed"))")
        return Made(pdf: target, book: book, title: title)
    }

    private static let a4 = CGSize(width: 595.28, height: 841.89)

    private static func officePages(_ file: URL, kind: ForeignKind, to target: URL, way: Way) async throws -> Int {
        // (As wide as an A4 page is at the 96 points to the inch a web page is measured in.)
        let view = CGSize(width: 794, height: 1123)
        let pages = WebPages(size: view, scripts: true)
        defer { pages.close() }
        guard await pages.show(file, access: file.deletingLastPathComponent()) else { throw ConvertError.unreadable }
        await pages.pause(0.5)
        await pages.settle()
        // How WebKit lays these files out was read off the build server's samples (0.16.0): a deck is a
        // column of boxes, one a slide, the later ones filled in only once they are scrolled to; a
        // workbook is a row of tabs over a frame that shows one sheet; a Word file is one long column.
        if kind == .slides, way == .sliced {
            let slides = await slideRects(pages)
            if !slides.isEmpty, let binder = PageBinder(url: target, size: slides[0].size, margin: 0) {
                for rect in slides {
                    if let data = await pages.piece(rect) { binder.add(data, asItIs: true) }
                }
                binder.close()
                if binder.pages > 0 { return binder.pages }
            }
        }
        if kind == .sheet {
            let tabs = Int(await pages.run("String(document.querySelectorAll('.TabView').length)")) ?? 0
            if tabs > 1, let binder = PageBinder(url: target, size: a4, margin: 0) {
                var index = 0
                while index < min(tabs, 40) {
                    if index > 0 {
                        _ = await pages.run("(function(){var t=document.getElementById('Tab\(index)');if(t){t.click();return 'ok';}return 'none';})()")
                        await pages.pause(0.7)
                    }
                    binder.add(pages.printed(paper: a4, margin: 24), asItIs: true)
                    index += 1
                }
                binder.close()
                // (The printer adds an empty page after some sheets: pages with nothing written on them go.)
                if let made = PDFDocument(url: target), made.pageCount > 1 {
                    var at = made.pageCount - 1
                    var removed = false
                    while at >= 0, made.pageCount > 1 {
                        let words = made.page(at: at)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if words.isEmpty {
                            made.removePage(at: at)
                            removed = true
                        }
                        at -= 1
                    }
                    if removed { made.write(to: target) }
                    return made.pageCount
                }
                return binder.pages
            }
        }
        if way == .printed || kind != .slides {
            let data = pages.printed(paper: a4, margin: kind == .slides ? 0 : 28)
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                throw ConvertError.unwritable
            }
            return PDFDocument(url: target)?.pageCount ?? 0
        }
        let extent = await pages.extent()
        guard extent.width > 0, extent.height > 0 else { throw ConvertError.nothing }
        let width = max(extent.width, 200)
        let height = (width * view.height / view.width).rounded()
        let cuts = await pages.cuts(height: height)
        guard cuts.count >= 2, let binder = PageBinder(url: target, size: CGSize(width: width, height: height), margin: 0) else { throw ConvertError.unwritable }
        var index = 0
        while index + 1 < cuts.count {
            let top = cuts[index]
            let bottom = cuts[index + 1]
            index += 1
            guard bottom - top > 1 else { continue }
            if let data = await pages.piece(CGRect(x: 0, y: top, width: width, height: bottom - top)) {
                binder.add(data)
            }
        }
        binder.close()
        return binder.pages
    }

    /// Where each slide of a deck stands in the web view, once every slide has been filled in.
    private static func slideRects(_ pages: WebPages) async -> [CGRect] {
        // Scrolled through from top to bottom: a slide is only laid out once it has come near the screen.
        let high = await pages.extent().height
        var at: CGFloat = 0
        var steps = 0
        while at < high, steps < 400 {
            _ = await pages.run("(function(){window.scrollTo(0,\(Int(at)));return 'ok';})()")
            await pages.pause(0.05)
            at += 900
            steps += 1
        }
        // Until no more slides come: their number the same four looks running. (The boxes that say a
        // slide is on its way stay in the page after it has come, so they cannot be waited out.)
        var tries = 0
        var seen = ""
        var same = 0
        while tries < 60, same < 4 {
            let now = await pages.run("String(document.querySelectorAll('.slide').length)")
            same = now == seen ? same + 1 : 0
            seen = now
            await pages.pause(0.2)
            tries += 1
        }
        _ = await pages.run("(function(){window.scrollTo(0,0);return 'ok';})()")
        await pages.settle()
        let script = "(function(){var s=document.querySelectorAll('.slide'),o=[],i,r;for(i=0;i<s.length;i++){r=s[i].getBoundingClientRect();"
            + "if(r.width>20&&r.height>20)o.push([r.left+window.scrollX,r.top+window.scrollY,r.width,r.height].join(' '));}return o.join(';');})()"
        let text = await pages.run(script)
        var rects: [CGRect] = []
        for part in text.split(separator: ";") {
            let numbers = part.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 4 { rects.append(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])) }
        }
        return rects
    }

    /// The look of a book's pages: the book's own, on paper of this size, with room at the sides.
    private static let bookStyle = "html{-webkit-text-size-adjust:100% !important;font-size:17px !important;}"
        + "body{margin:0 !important;padding:0 52px !important;line-height:1.65;word-break:keep-all;overflow-wrap:break-word;}"
        + "img,svg,video{max-width:100% !important;height:auto !important;}"
        + "pre{white-space:pre-wrap !important;}"

    static func styling(_ css: String) -> String {
        let quoted = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return "(function(){var s=document.getElementById('aipencil-style');"
            + "if(!s){s=document.createElementNS('http://www.w3.org/1999/xhtml','style');s.id='aipencil-style';"
            + "(document.head||document.documentElement).appendChild(s);}"
            + "s.textContent='\(quoted)';return 'ok';})()"
    }

    private static func bookPages(_ book: Epub, root: URL, to target: URL, way: Way, progress: ((String) -> Void)?) async throws -> Int {
        let paper = CGSize(width: 620, height: 877)
        let margin: CGFloat = 46
        let pages = WebPages(size: paper, scripts: false)
        defer { pages.close() }
        guard let binder = PageBinder(url: target, size: paper, margin: margin) else { throw ConvertError.unwritable }
        var number = 0
        for chapter in book.chapters {
            number += 1
            progress?("\(number)/\(book.chapters.count)")
            guard await pages.show(root.appendingPathComponent(chapter), access: root) else { continue }
            _ = await pages.run(styling(bookStyle))
            await pages.settle()
            if way == .printed {
                binder.add(pages.printed(paper: a4, margin: 40), asItIs: true)
                continue
            }
            let cuts = await pages.cuts(height: paper.height - margin * 2)
            var index = 0
            while index + 1 < cuts.count {
                let top = cuts[index]
                let bottom = cuts[index + 1]
                index += 1
                guard bottom - top > 1 else { continue }
                if let data = await pages.piece(CGRect(x: 0, y: top, width: paper.width, height: bottom - top)) {
                    binder.add(data)
                }
            }
        }
        binder.close()
        return binder.pages
    }

    // MARK: on the build server

    private static let outliner = #"""
    (function(){
      var out=[];
      function walk(e,d){
        if(d>5||out.length>500)return;
        var r=e.getBoundingClientRect(),name=(typeof e.className==='string'&&e.className)?'.'+e.className:'';
        out.push(new Array(d+1).join('  ')+e.tagName+(e.id?'#'+e.id:'')+name+' '+Math.round(r.left)+','+Math.round(r.top+window.scrollY)+' '+Math.round(r.width)+'x'+Math.round(r.height)+' '+(e.getAttribute('style')||'').slice(0,140));
        for(var i=0;i<e.children.length&&i<30;i++)walk(e.children[i],d+1);
      }
      walk(document.documentElement,0);
      return out.join('\n')+'\n--- scroll '+document.documentElement.scrollWidth+'x'+document.documentElement.scrollHeight+' frames '+window.frames.length+' url '+location.href+'\n'+document.documentElement.outerHTML.slice(0,6000);
    })()
    """#

    /// "-convertCheck": every file in Documents/convert-in is converted both ways into
    /// Documents/convert-out, with a note of how WebKit laid the file out. The build server looks at
    /// what comes out.
    static func check() {
        Task { @MainActor in
            let manager = FileManager.default
            let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let from = documents.appendingPathComponent("convert-in", isDirectory: true)
            let out = documents.appendingPathComponent("convert-out", isDirectory: true)
            try? manager.createDirectory(at: out, withIntermediateDirectories: true)
            // (A moment for the window to be there.)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let names = ((try? manager.contentsOfDirectory(atPath: from.path)) ?? []).sorted()
            for name in names {
                let file = from.appendingPathComponent(name)
                guard let kind = ForeignKind.of(file) else { continue }
                for way in [Way.sliced, Way.printed] {
                    let label = way == .sliced ? "cut" : "print"
                    do {
                        let copy = try borrow(file)
                        let made = try await convert(copy, kind: kind, name: name, way: way)
                        let kept = out.appendingPathComponent("\(name).\(label).pdf")
                        try? manager.removeItem(at: kept)
                        try manager.copyItem(at: made.pdf, to: kept)
                        if let book = made.book, let read = Epub.load(book) {
                            DebugLog.write("convert: \(name) is \"\(read.title)\", chapters \(read.names.joined(separator: " | "))")
                        }
                        try? manager.removeItem(at: copy.deletingLastPathComponent())
                    } catch {
                        DebugLog.write("convert: \(name) \(label) FAILED: \(error)")
                    }
                }
                if kind != .epub, let copy = try? borrow(file) {
                    let pages = WebPages(size: CGSize(width: 794, height: 1123), scripts: true)
                    if await pages.show(copy, access: copy.deletingLastPathComponent()) {
                        await pages.pause(0.5)
                        let text = await pages.run(outliner)
                        try? text.write(to: out.appendingPathComponent("\(name).dom.txt"), atomically: true, encoding: .utf8)
                    }
                    pages.close()
                    try? manager.removeItem(at: copy.deletingLastPathComponent())
                }
            }
            DebugLog.write("convert: done")
        }
    }
}
