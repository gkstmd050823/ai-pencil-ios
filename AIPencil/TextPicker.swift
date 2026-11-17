import PDFKit
import UIKit

/// Picking out words of a page with a finger: a finger held still on a word takes that word, dragging
/// on from there takes everything up to where the finger is, and the two ends can be moved afterwards by
/// their knobs. Lifting the finger brings up the menu to copy the words or have them translated.
///
/// It works on pages whose text is in the file (a PDF made from text, or a scan that has been through
/// text recognition). PDFKit's own picking is not used: what it marks lies under the app's picture of
/// the page, and its gestures are off while the page is drawn on.
///
/// Places are in the frame of the page's overlay: the page's crop box, measured from its top left.
final class TextPicker: NSObject, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    /// Whether a finger held at this place of this overlay may pick words now.
    var allowed: ((UIView, CGPoint) -> Bool)?
    /// The page an overlay lies on.
    var pageOf: ((UIView) -> PDFPage?)?
    /// How many screen points a page point takes now.
    var zoom: (() -> CGFloat)?
    /// The finger let go with these words picked.
    var onPicked: ((String) -> Void)?
    var onCopied: ((String) -> Void)?
    var onTranslate: ((String) -> Void)?

    private weak var overlay: UIView?
    private var page: PDFPage?
    private var crop = CGRect.zero
    /// The part that stays picked while the finger moves: the word it came down on, or the end that is
    /// not being dragged.
    private var fixed = NSRange(location: 0, length: 0)
    private var range = NSRange(location: 0, length: 0)
    private var boxes: [CGRect] = []
    /// Where each letter of the page stands (see readLetters).
    private var letters: [CGRect] = []
    /// How tall a letter of the page is, as a rule.
    private var letterHeight: CGFloat = 10
    private let shade = UIView()
    private let head = UIView()
    private let tail = UIView()
    private var menu: UIEditMenuInteraction?
    /// From the finger on a knob to the line of text the knob stands on.
    private var reach = CGPoint.zero
    private var zoomSeen: CGFloat = 0

    var isActive: Bool { page != nil && range.length > 0 }

    /// The words picked, as one piece of text.
    var text: String {
        guard let page, range.length > 0 else { return "" }
        let picked = page.selection(for: range)?.string ?? ""
        return Self.tidy(picked)
    }

    /// Lines broken in the middle of a sentence are joined again; a word cut in two at a line's end is
    /// made whole.
    static func tidy(_ text: String) -> String {
        var out = ""
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines where !line.isEmpty {
            if out.isEmpty {
                out = line
            } else if out.hasSuffix("-"), let before = out.dropLast().last, before.isLetter, let next = line.first, next.isLowercase {
                out = String(out.dropLast()) + line
            } else {
                out += " " + line
            }
        }
        return out
    }

    // MARK: setting up

    /// Lets words be picked on this overlay.
    func attach(to overlay: UIView) {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.32
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        hold.delegate = self
        overlay.addGestureRecognizer(hold)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let view = gesture.view else { return false }
        // (A knob's own drag: always.)
        if view === head || view === tail { return true }
        let point = gesture.location(in: view)
        guard allowed?(view, point) ?? false, let page = pageOf?(view) else { return false }
        // Only where there are words to take.
        return word(at: point, on: page) != nil
    }

    // MARK: picking

    private func word(at point: CGPoint, on page: PDFPage) -> NSRange? {
        let crop = page.bounds(for: .cropBox)
        let at = CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
        // (PDFKit hands back the nearest word however far off it is. A finger held on bare paper picks
        // nothing: the word has to be under the finger, or within a few points of it.)
        if let found = page.selectionForWord(at: at), found.numberOfTextRanges(on: page) > 0,
           found.bounds(for: page).insetBy(dx: -8, dy: -8).contains(at) {
            let letters = found.range(at: 0, on: page)
            if letters.length > 0 { return letters }
        }
        let index = page.characterIndex(at: at)
        if index >= 0, index != NSNotFound, index < page.numberOfCharacters,
           page.characterBounds(at: index).insetBy(dx: -8, dy: -8).contains(at) {
            return NSRange(location: index, length: 1)
        }
        return nil
    }

    /// Notes where every letter of the page stands, in the overlay's frame. A letter with no place of its
    /// own (a line's end) is given a null box, and so are the gaps between words and anything far larger
    /// than a letter (the room PDFKit gives a gap can reach over other lines): a finger means a letter.
    private func readLetters() {
        guard let page else {
            letters = []
            return
        }
        let count = min(page.numberOfCharacters, 30000)
        let written = Array((page.string ?? "").utf16)
        var all: [CGRect] = []
        all.reserveCapacity(count)
        var heights: [CGFloat] = []
        for index in 0..<count {
            let box = page.characterBounds(at: index)
            var blank = false
            if index < written.count, let mark = Unicode.Scalar(UInt32(written[index])) {
                blank = mark.properties.isWhitespace
            }
            if !blank, box.width > 0, box.height > 0 {
                all.append(CGRect(x: box.minX - crop.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height))
                heights.append(box.height)
            } else {
                all.append(.null)
            }
        }
        heights.sort()
        letterHeight = heights.isEmpty ? 10 : max(2, heights[heights.count / 2])
        for index in all.indices where !all[index].isNull {
            if all[index].height > letterHeight * 3 || all[index].width > letterHeight * 8 { all[index] = .null }
        }
        letters = all
    }

    /// The letter a dragging finger means: on the line nearest the finger, up or down, the letter nearest
    /// along it. A finger out past the end of a line means the end of that line, and one between two
    /// lines the nearer of them.
    ///
    /// The words picked are the letters between two numbers in the page's own order of letters, and on a
    /// page with formulas that order is not always the order they stand in: a letter of a fraction, or
    /// one written small above or below the line, can stand on a line and be numbered far from the rest
    /// of it. Taken for what the finger meant, such a letter made the words picked leap to wherever it
    /// was numbered (a film of 0.13.3 has them begin two lines up, twice, with a formula between). So of
    /// the letters on the finger's line, those numbered together with few others are passed over when
    /// letters numbered together with many are within a few letters' reach.
    private func letter(near point: CGPoint) -> Int? {
        // The line: where the letter nearest the finger has its middle. Up and down counts four times as
        // much as along, and no more than that. (Until 0.13.5 it counted for everything: on a page of two
        // columns whose lines do not stand at the same heights, a finger passing between two lines of
        // its own column was nearer, up and down, to a line of the other column, and the words picked
        // leapt across the page and back at every line. A test's notes have the finger at 238 across
        // and the letter it was taken to mean at 315, the other column's first, again and again.)
        var bestScore = CGFloat.greatestFiniteMagnitude
        var middle: CGFloat?
        for box in letters where !box.isNull {
            let dx = max(box.minX - point.x, point.x - box.maxX, 0)
            let dy = max(box.minY - point.y, point.y - box.maxY, 0)
            let score = dy * 4 + dx
            if score < bestScore {
                bestScore = score
                middle = box.midY
            }
        }
        guard let middle else { return nil }
        // The letters on it, in the page's order, each with how far along the line it is from the finger.
        var onLine: [(index: Int, off: CGFloat)] = []
        for (index, box) in letters.enumerated() where !box.isNull && abs(box.midY - middle) <= letterHeight * 0.6 {
            onLine.append((index, max(box.minX - point.x, point.x - box.maxX, 0)))
        }
        guard !onLine.isEmpty else { return nil }
        // Those numbered close together belong together (a run of words; the other column's line, at
        // the same height, is another run). Each run: how many letters, and its letter nearest the finger.
        var runs: [(count: Int, index: Int, off: CGFloat)] = []
        var last = -1000
        for letter in onLine {
            if letter.index - last > 40 || runs.isEmpty {
                runs.append((1, letter.index, letter.off))
            } else {
                runs[runs.count - 1].count += 1
                if letter.off < runs[runs.count - 1].off {
                    runs[runs.count - 1].index = letter.index
                    runs[runs.count - 1].off = letter.off
                }
            }
            last = letter.index
        }
        let near = letterHeight * 3
        let full = runs.filter { $0.count >= 6 && $0.off <= near }
        let wanted = full.isEmpty ? runs : full
        var best = wanted[0]
        for run in wanted where run.off < best.off { best = run }
        return best.index
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard let view = gesture.view else { return }
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            guard let under = pageOf?(view), let taken = word(at: point, on: under) else { return }
            clear()
            overlay = view
            page = under
            crop = under.bounds(for: .cropBox)
            fixed = taken
            range = taken
            readLetters()
            install(in: view)
            show()
            UISelectionFeedbackGenerator().selectionChanged()
            Diagnostics.shared.step("words picked")
        case .changed:
            guard view === overlay else { return }
            stretch(to: point, whole: true)
        case .ended:
            guard view === overlay, isActive else { return }
            onPicked?(text)
            showMenu()
        case .cancelled, .failed:
            if view === overlay { showMenu() }
        default:
            break
        }
    }

    /// Picks from the part that stays to this place. [whole]: the word at the place is taken whole (a
    /// finger dragging); otherwise the letter there ends it (a knob being moved).
    ///
    /// Which letters lie between two places of a page is PDFKit's to say: it is asked for what is picked
    /// from the middle of the part that stays to where the finger is, as it would pick them itself.
    /// (Until 0.13.6 the app found the letter nearest the finger by rules of its own and took everything
    /// between the two in the page's order of letters. On a page of two columns, or with formulas, the
    /// rules kept being wrong one way or another, while Apple's own reader, which leaves it to PDFKit,
    /// picked the same pages smoothly.) Only when PDFKit has nothing to say are the app's own rules used.
    private func stretch(to point: CGPoint, whole: Bool = false) {
        guard let page else { return }
        var from = fixed.location
        var to = fixed.location + fixed.length
        var how = "nothing"
        func take(_ picked: PDFSelection?) -> Bool {
            guard let picked else { return false }
            var any = false
            for part in 0..<picked.numberOfTextRanges(on: page) {
                let letters = picked.range(at: part, on: page)
                guard letters.length > 0 else { continue }
                from = min(from, letters.location)
                to = max(to, letters.location + letters.length)
                any = true
            }
            return any
        }
        let finger = CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
        let middle = page.characterBounds(at: min(fixed.location + fixed.length / 2, max(page.numberOfCharacters - 1, 0)))
        if middle.width > 0, take(page.selection(from: CGPoint(x: middle.midX, y: middle.midY), to: finger)) {
            how = "as PDFKit picks"
        } else if let index = letter(near: point) {
            from = min(from, index)
            to = max(to, index + 1)
            how = "the nearest letter"
        } else {
            return
        }
        if whole, let word = page.selectionForWord(at: finger), word.bounds(for: page).insetBy(dx: -4, dy: -4).contains(finger) {
            _ = take(word)
        }
        let next = NSRange(location: from, length: to - from)
        guard next != range else { return }
        if abs(next.length - range.length) > 60 {
            // (Noted for a test: the words picked grew or shrank by much at once.)
            DebugLog.write(String(
                format: "words: from %d letters to %d at once (%@); the finger at (%.0f, %.0f), the part that stays at letter %d",
                range.length, next.length, how, Double(point.x), Double(point.y), fixed.location
            ))
        }
        range = next
        show()
    }

    @objc private func knobMoved(_ gesture: UILongPressGestureRecognizer) {
        guard let overlay, let knob = gesture.view, range.length > 0, let first = boxes.first, let last = boxes.last else { return }
        let point = gesture.location(in: overlay)
        switch gesture.state {
        case .began:
            menu?.dismissMenu()
            if knob === head {
                // The first letter moves; the last one stays.
                fixed = NSRange(location: range.location + range.length - 1, length: 1)
                reach = CGPoint(x: first.minX - point.x, y: first.midY - point.y)
            } else {
                fixed = NSRange(location: range.location, length: 1)
                reach = CGPoint(x: last.maxX - point.x, y: last.midY - point.y)
            }
        case .changed:
            stretch(to: CGPoint(x: point.x + reach.x, y: point.y + reach.y))
        case .ended, .cancelled, .failed:
            onPicked?(text)
            showMenu()
        default:
            break
        }
    }

    /// For the build server: picks the words between two places of an overlay, as a finger would have.
    func pick(from a: CGPoint, to b: CGPoint, in view: UIView) {
        guard let under = pageOf?(view), let taken = word(at: a, on: under) else { return }
        clear()
        overlay = view
        page = under
        crop = under.bounds(for: .cropBox)
        fixed = taken
        range = taken
        readLetters()
        install(in: view)
        stretch(to: b)
        show()
        onPicked?(text)
        showMenu()
    }

    /// Lets go of the words.
    func clear() {
        guard page != nil else { return }
        menu?.dismissMenu()
        if let menu, let overlay { overlay.removeInteraction(menu) }
        menu = nil
        shade.removeFromSuperview()
        head.removeFromSuperview()
        tail.removeFromSuperview()
        page = nil
        overlay = nil
        range = NSRange(location: 0, length: 0)
        boxes = []
        letters = []
    }

    /// The overlay is going away: words picked on it go with it.
    func left(_ view: UIView) {
        if view === overlay { clear() }
    }

    // MARK: showing

    private func install(in view: UIView) {
        shade.isUserInteractionEnabled = false
        shade.frame = view.bounds
        shade.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(shade)
        for knob in [head, tail] {
            if knob.gestureRecognizers?.isEmpty ?? true {
                // (Held from the moment it is touched, so that the page does not scroll under the finger.)
                let drag = UILongPressGestureRecognizer(target: self, action: #selector(knobMoved(_:)))
                drag.minimumPressDuration = 0
                drag.delegate = self
                knob.addGestureRecognizer(drag)
                knob.layer.addSublayer(CALayer())
                knob.layer.addSublayer(CALayer())
            }
            view.addSubview(knob)
        }
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        self.menu = menu
    }

    /// Called now and then: the knobs keep their size on screen when the page is zoomed.
    func fit() {
        guard isActive, let now = zoom?(), abs(now - zoomSeen) > 0.001 else { return }
        place()
    }

    private func show() {
        guard let page, let picked = page.selection(for: range) else { return }
        boxes = picked.selectionsByLine().map { line in
            let box = line.bounds(for: page)
            return CGRect(x: box.minX - crop.minX, y: crop.maxY - box.maxY, width: box.width, height: box.height)
        }.filter { $0.width > 0 && $0.height > 0 }
        place()
    }

    private func place() {
        guard let overlay else { return }
        let tint: UIColor = overlay.tintColor ?? UIColor.systemTeal
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let old = shade.layer.sublayers ?? []
        for (at, box) in boxes.enumerated() {
            let mark: CALayer
            if at < old.count {
                mark = old[at]
            } else {
                mark = CALayer()
                shade.layer.addSublayer(mark)
            }
            mark.frame = box.insetBy(dx: -0.5, dy: -1)
            mark.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        }
        for layer in old.dropFirst(boxes.count) { layer.removeFromSuperlayer() }

        let scale = max(zoom?() ?? 1, 0.05)
        zoomSeen = scale
        let dot = 11 / scale
        let bar = 2 / scale
        let room = 40 / scale
        if let first = boxes.first, let last = boxes.last {
            // Each knob is a bar the height of its line with a dot on it: above the first letter, below
            // the last. The room round it that takes the finger is larger than what is drawn.
            let ends: [(UIView, CGFloat, CGRect, Bool)] = [(head, first.minX, first, true), (tail, last.maxX, last, false)]
            for (knob, x, box, above) in ends {
                knob.isHidden = false
                knob.frame = CGRect(x: x - room / 2, y: box.minY - (above ? room * 0.7 : 0), width: room, height: box.height + room * 0.7)
                let line = knob.layer.sublayers?[0]
                let ball = knob.layer.sublayers?[1]
                let top = above ? room * 0.7 : 0
                line?.frame = CGRect(x: room / 2 - bar / 2, y: top - (above ? dot * 0.3 : 0), width: bar, height: box.height + dot * 0.3)
                line?.backgroundColor = tint.cgColor
                ball?.frame = CGRect(x: room / 2 - dot / 2, y: above ? top - dot : top + box.height, width: dot, height: dot)
                ball?.cornerRadius = dot / 2
                ball?.backgroundColor = tint.cgColor
            }
        } else {
            head.isHidden = true
            tail.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: the menu

    private func showMenu() {
        guard let menu, isActive, let first = boxes.first else { return }
        let point = CGPoint(x: first.midX, y: first.minY)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let words = text
        guard !words.isEmpty else { return nil }
        return UIMenu(children: [
            UIAction(title: "복사") { [weak self] _ in
                UIPasteboard.general.string = words
                self?.onCopied?(words)
                self?.clear()
            },
            UIAction(title: "번역") { [weak self] _ in
                self?.onTranslate?(words)
            },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        var all = CGRect.null
        for box in boxes { all = all.union(box) }
        return all.isNull ? CGRect(origin: configuration.sourcePoint, size: .zero) : all
    }
}
