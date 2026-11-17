import CoreGraphics
import Foundation
import UIKit

/// A typeset formula placed on a page. Position and size are in page points, measured from the page's
/// top-left corner. [image] names the picture of the formula (its shape only), which is drawn in the colour
/// given; [latex] is what was typed, kept so the formula can be edited later.
struct MathItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var latex: String
    var image: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var red: Double
    var green: Double
    var blue: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var color: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
}

/// The formulas of a document on disk: one list for the whole document, and a picture file per formula.
struct MathStore {
    let folder: URL

    private var indexURL: URL { folder.appendingPathComponent("math.json") }

    func imageURL(_ name: String) -> URL {
        folder.appendingPathComponent("math-\(name).png")
    }

    func load() -> [MathItem] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([MathItem].self, from: data)) ?? []
    }

    func save(_ items: [MathItem]) {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: indexURL)
        } else if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// After a page was inserted at [index]: formulas on that page and later ones move one page later.
    func shiftPages(from index: Int, by count: Int = 1) {
        let items = load()
        guard !items.isEmpty else { return }
        save(items.map { item in
            var moved = item
            if moved.page >= index { moved.page += count }
            return moved
        })
    }
}

/// How big a formula is on the page: the height of one em of it, in points.
enum MathSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "작게"
        case .medium: return "보통"
        case .large: return "크게"
        }
    }

    var emPoints: Double {
        switch self {
        case .small: return 12
        case .medium: return 16
        case .large: return 24
        }
    }
}

enum MathPicture {
    /// The size on the page of a formula that measured [width] x [height] in the preview, where one em of it
    /// measured [em], when an em should be [emPoints] points on the page. A formula too big for the page is
    /// scaled down to fit, keeping its shape.
    static func sizeOnPage(width: Double, height: Double, em: Double, emPoints: Double, maxWidth: Double, maxHeight: Double) -> CGSize {
        var w = width / max(em, 1) * emPoints
        var h = height / max(em, 1) * emPoints
        let fit = min(1, maxWidth / max(w, 1), maxHeight / max(h, 1))
        w *= fit
        h *= fit
        return CGSize(width: w, height: h)
    }

    /// Turns a picture of dark letters, on white or on nothing, into the letters' shape alone: black where
    /// there was ink, clear elsewhere. The shape can then be drawn in any colour.
    static func inkMask(_ image: UIImage) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let result: CGImage? = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let alpha = Double(bytes[i + 3]) / 255
                var ink = 0.0
                if alpha > 0 {
                    // Colours are stored multiplied by alpha; divide to get the colour itself.
                    let luminance = (0.299 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.114 * Double(bytes[i + 2])) / 255 / alpha
                    ink = alpha * (1 - min(1, luminance))
                }
                bytes[i] = 0
                bytes[i + 1] = 0
                bytes[i + 2] = 0
                bytes[i + 3] = UInt8(max(0, min(255, ink * 255)))
                i += 4
            }
            return context.makeImage()
        }
        guard let mask = result else { return nil }
        return UIImage(cgImage: mask, scale: image.scale, orientation: .up)
    }
}
