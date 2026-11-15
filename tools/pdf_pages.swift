// Turns the pages of a PDF into pictures and prints the first words of each, so that an export made
// in the simulator can be looked at and its text checked. Run on the build server (a Mac):
//
//   swift tools/pdf_pages.swift export.pdf screenshots/26-export 8
//
// writes screenshots/26-export-p1.png, -p2.png, ... for at most 8 pages.
import AppKit
import Foundation
import PDFKit

let arguments = CommandLine.arguments
guard arguments.count >= 3, let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])) else {
    print("pdf_pages: cannot open \(arguments.count > 1 ? arguments[1] : "(no file)")")
    exit(0)
}
let prefix = arguments[2]
let limit = arguments.count > 3 ? (Int(arguments[3]) ?? 8) : 8
print("pdf_pages: \(arguments[1]) has \(document.pageCount) pages")
for index in 0..<min(document.pageCount, limit) {
    guard let page = document.page(at: index) else { continue }
    let box = page.bounds(for: .cropBox)
    let sideways = (page.rotation / 90) % 2 != 0
    let shown = sideways ? CGSize(width: box.height, height: box.width) : box.size
    let scale: CGFloat = 1.4
    let size = CGSize(width: shown.width * scale, height: shown.height * scale)
    // PDFKit's own picture of the page, with whatever is drawn or stamped on it.
    let picture = page.thumbnail(of: size, for: .cropBox)
    if let tiff = picture.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(prefix)-p\(index + 1).png"))
    }
    let words = (page.string ?? "").split(whereSeparator: { $0.isNewline }).prefix(2).joined(separator: " / ")
    print("pdf_pages: page \(index + 1) turned \(page.rotation) size \(Int(box.width))x\(Int(box.height)) text: \(words.prefix(70))")
}
