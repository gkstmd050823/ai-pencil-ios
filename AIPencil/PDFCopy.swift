import Foundation
import PDFKit

/// Which pages of a document are meant by something like "1-3, 7, 10-12".
enum PageRanges {
    /// The pages named, counted from zero, in the order they are named and each once; nil when the text
    /// names no page of a document of [count] pages or cannot be read.
    static func parse(_ text: String, count: Int) -> [Int]? {
        var pages: [Int] = []
        var seen = Set<Int>()
        let cleaned = text.replacingOccurrences(of: "쪽", with: "").replacingOccurrences(of: "~", with: "-")
        for part in cleaned.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard ends.count == 1 || ends.count == 2, let first = ends[0], let last = ends.count == 2 ? ends[1] : ends[0] else { return nil }
            guard first >= 1, last >= first else { return nil }
            // (Pages past the end of the document are left out.)
            guard first <= count else { continue }
            for page in first...min(last, count) {
                if seen.insert(page - 1).inserted { pages.append(page - 1) }
            }
        }
        return pages.isEmpty ? nil : pages
    }
}

/// Makes a new PDF file out of pages of others: some pages of one document, or several documents one
/// after another.
///
/// The pages are copied as they are written in their files, object by object, with everything a page
/// needs (its fonts, its pictures) and nothing else: the text of a copied page is exactly the text it
/// had. PDFKit can put pages together too, but it writes every page anew when it saves, and in a file
/// written that way the letters of fonts that were only partly included (Korean fonts, as a rule) no
/// longer say which letters they are. It is used only where this cannot read a file (an encrypted one).
enum PDFCopy {
    /// A file to take pages from, and which (all of them when nil), counted from zero.
    struct Part {
        var data: Data
        var pages: [Int]?
    }

    /// With [secondAfter] there are two parts, and the pages of the second go in after that many pages of
    /// the first, which is a document that pages are being put into: its table of contents is kept too,
    /// with the places it names.
    static func join(_ parts: [Part], secondAfter: Int? = nil) throws -> Data {
        var out: [UInt8] = Array("%PDF-1.7\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
        // Object 1 is the catalogue and 2 the list of pages; both are written last.
        var offsets: [Int: Int] = [:]
        var next = 3
        // The pages of each part, in their order.
        var groups: [[PDFValue]] = []
        // What the catalogue has besides the pages: the first part's table of contents, when it is kept.
        var extras = PDFDict()

        func begin(_ number: Int) {
            offsets[number] = out.count
            out += Array("\(number) 0 obj\n".utf8)
        }
        func end() {
            out += Array("\nendobj\n".utf8)
        }

        for (order, part) in parts.enumerated() {
            var kids: [PDFValue] = []
            try part.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                let reader = try PDFReader(bytes)
                let leaves = try reader.pages()
                let wanted = part.pages ?? Array(leaves.indices)
                // Every page of the file and every part of its page tree: a reference to one of these
                // from a page that is copied (a link to another page, say) must not drag that page along.
                var tree = Set<Int>()
                for leaf in leaves {
                    tree.insert(leaf.page)
                    var up: Int? = leaf.parent
                    var hops = 0
                    while let node = up, !tree.contains(node), hops < 64 {
                        tree.insert(node)
                        up = try reader.get(node).dict?["Parent"]?.refNumber
                        hops += 1
                    }
                }
                var renumbered: [Int: Int] = [:]
                var waiting: [(old: Int, new: Int)] = []
                var pageNumbers: [(old: Int, new: Int)] = []
                for index in wanted where leaves.indices.contains(index) {
                    let old = leaves[index].page
                    // (A page asked for twice is in the new file once.)
                    if renumbered[old] != nil { continue }
                    renumbered[old] = next
                    pageNumbers.append((old, next))
                    kids.append(.ref(next, 0))
                    next += 1
                }

                func copied(_ value: PDFValue, depth: Int = 0) -> PDFValue {
                    guard depth < 200 else { return .null }
                    switch value {
                    case .ref(let number, _):
                        if let known = renumbered[number] { return .ref(known, 0) }
                        if tree.contains(number) { return .null }
                        renumbered[number] = next
                        waiting.append((number, next))
                        next += 1
                        return .ref(next - 1, 0)
                    case .array(let items):
                        return .array(items.map { copied($0, depth: depth + 1) })
                    case .dict(let table):
                        var made = PDFDict()
                        for key in table.keys {
                            if let item = table[key] { made[key] = copied(item, depth: depth + 1) }
                        }
                        return .dict(made)
                    default:
                        return value
                    }
                }

                for (old, new) in pageNumbers {
                    guard var page = try reader.get(old).dict else { throw PDFAppendError("a page that is not a dictionary") }
                    // What a page may leave to the part of the tree it hangs from is written on the page itself.
                    for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where page[key] == nil {
                        var up = page["Parent"]?.refNumber
                        var hops = 0
                        while let node = up, hops < 64 {
                            guard let above = try reader.get(node).dict else { break }
                            if let found = above[key] {
                                page[key] = found
                                break
                            }
                            up = above["Parent"]?.refNumber
                            hops += 1
                        }
                    }
                    page["Parent"] = nil
                    // (Its place in the document's structure tree and in article threads, which are not copied.)
                    page["StructParents"] = nil
                    page["B"] = nil
                    var made = copied(.dict(page)).dict ?? PDFDict()
                    made["Parent"] = .ref(2, 0)
                    begin(new)
                    PDFAppend.write(.dict(made), into: &out)
                    end()
                }
                if secondAfter != nil, order == 0, let root = try reader.resolve(reader.trailer["Root"])?.dict {
                    // The table of contents points at pages, all of which have their new numbers by now;
                    // what it points at by name is listed in one of two other places.
                    if let outlines = root["Outlines"] { extras["Outlines"] = copied(outlines) }
                    if let places = root["Dests"] { extras["Dests"] = copied(places) }
                    if let names = try reader.resolve(root["Names"])?.dict, let places = names["Dests"] {
                        var kept = PDFDict()
                        kept["Dests"] = copied(places)
                        extras["Names"] = .dict(kept)
                    }
                }
                var at = 0
                while at < waiting.count {
                    let (old, new) = waiting[at]
                    at += 1
                    guard let found = try reader.found(old) else {
                        begin(new)
                        out += Array("null".utf8)
                        end()
                        continue
                    }
                    if let body = found.body, var info = found.value.dict {
                        // A stream: its bytes go over as they are, packed however they were packed.
                        info["Length"] = .number(String(body.count))
                        let table = copied(.dict(info))
                        begin(new)
                        PDFAppend.write(table, into: &out)
                        out += Array("\nstream\n".utf8)
                        out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[body]))
                        out += Array("\nendstream".utf8)
                        end()
                    } else {
                        let value = copied(found.value)
                        begin(new)
                        PDFAppend.write(value, into: &out)
                        end()
                    }
                    if next > 4_000_000 { throw PDFAppendError("too many objects") }
                }
            }
            groups.append(kids)
        }
        var kids = groups.flatMap { $0 }
        if let after = secondAfter, groups.count == 2 {
            let cut = min(max(after, 0), groups[0].count)
            kids = Array(groups[0][..<cut]) + groups[1] + Array(groups[0][cut...])
        }
        guard !kids.isEmpty else { throw PDFAppendError("no pages to copy") }

        var pages = PDFDict()
        pages["Type"] = .name("Pages")
        pages["Kids"] = .array(kids)
        pages["Count"] = .number(String(kids.count))
        begin(2)
        PDFAppend.write(.dict(pages), into: &out)
        end()
        var catalogue = PDFDict()
        catalogue["Type"] = .name("Catalog")
        catalogue["Pages"] = .ref(2, 0)
        for key in extras.keys {
            catalogue[key] = extras[key]
        }
        begin(1)
        PDFAppend.write(.dict(catalogue), into: &out)
        end()

        let start = out.count
        var table = "xref\n0 \(next)\n0000000000 65535 f \n"
        for number in 1..<next {
            if let offset = offsets[number] {
                table += String(format: "%010d 00000 n \n", offset)
            } else {
                table += "0000000000 65535 f \n"
            }
        }
        table += "trailer\n<< /Size \(next) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        out += Array(table.utf8)
        return Data(out)
    }

    /// The same with PDFKit, for files this code cannot read. Every page is written anew.
    static func joinWithPDFKit(_ parts: [(url: URL, pages: [Int]?)]) -> Data? {
        let made = PDFDocument()
        for part in parts {
            guard let source = PDFDocument(url: part.url) else { return nil }
            for index in part.pages ?? Array(0..<source.pageCount) {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                made.insert(page, at: made.pageCount)
            }
        }
        return made.pageCount > 0 ? made.dataRepresentation() : nil
    }

    /// Puts every page of [addition] into the file at [base], after its first [count] pages, and says how
    /// many pages went in; nil when it could not be done, and the file is then as it was.
    ///
    /// The file's own pages are copied as they are, or not at all: there is no falling back on PDFKit for
    /// them, which would write them anew and could lose what their letters are. A file whose pages cannot
    /// be copied as they are (an encrypted one) cannot have pages put into it. The pages that come in are
    /// another matter: when the file they come from cannot be read here but PDFKit can read it, PDFKit
    /// writes that file anew first and its pages are taken from that.
    static func insert(_ addition: URL, into base: URL, afterPages count: Int) -> Int? {
        guard let own = try? Data(contentsOf: base, options: .mappedIfSafe),
              let before = PDFDocument(data: own)?.pageCount, before > 0,
              let more = try? Data(contentsOf: addition, options: .mappedIfSafe) else { return nil }
        var made: Data?
        do {
            made = try join([Part(data: own, pages: nil), Part(data: more, pages: nil)], secondAfter: count)
        } catch {
            DebugLog.write("copy: could not put the pages in as they are (\(error))")
            if let other = PDFDocument(data: more), !other.isLocked, let anew = other.dataRepresentation() {
                made = try? join([Part(data: own, pages: nil), Part(data: anew, pages: nil)], secondAfter: count)
            }
        }
        guard let made, let after = PDFDocument(data: made)?.pageCount, after > before else { return nil }
        // Written beside the file and then put in its place, so that the file is never half written.
        let beside = base.deletingLastPathComponent().appendingPathComponent("document.new.pdf")
        do {
            try made.write(to: beside, options: .atomic)
            _ = try FileManager.default.replaceItemAt(base, withItemAt: beside)
            return after - before
        } catch {
            try? FileManager.default.removeItem(at: beside)
            return nil
        }
    }

    /// Pages of files on disk put together into one file at [target]. False when it could not be done.
    static func write(_ parts: [(url: URL, pages: [Int]?)], to target: URL) -> Bool {
        var data: Data?
        do {
            data = try join(try parts.map { Part(data: try Data(contentsOf: $0.url, options: .mappedIfSafe), pages: $0.pages) })
        } catch {
            DebugLog.write("copy: could not copy the pages as they are (\(error)); PDFKit writes them anew")
            data = joinWithPDFKit(parts)
        }
        guard let data, PDFDocument(data: data)?.pageCount ?? 0 > 0 else { return false }
        do {
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
