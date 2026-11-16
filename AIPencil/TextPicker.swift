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

    private func pagePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
    }

    private func word(at point: CGPoint, on page: PDFPage) -> NSRange? {
        let crop = page.bounds(for: .cropBox)
        let at = CGPoint(x: crop.minX + point.x, y: crop.maxY - point.y)
        if let found = page.selectionForWord(at: at), found.numberOfTextRanges(on: page) > 0 {
            let letters = found.range(at: 0, on: page)
            if letters.length > 0 { return letters }
        }
        let index = page.characterIndex(at: at)
        if index >= 0, index != NSNotFound, index < page.numberOfCharacters {
            return NSRange(location: index, length: 1)
        }
        return nil
    }

    /// The letter at a place, or the nearest one a little way off: a finger between two lines, or just
    /// past a line's end, still means the letters beside it.
    private func letter(near point: CGPoint) -> Int? {
        guard let page else { return nil }
        let count = page.numberOfCharacters
        let steps: [CGFloat] = [0, 3, -3, 6, -6, 10, -10]
        for dy in steps {
            for dx in steps {
                let index = page.characterIndex(at: pagePoint(CGPoint(x: point.x + dx, y: point.y + dy)))
                if index >= 0, index != NSNotFound, index < count { return index }
            }
        }
        return nil
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
            install(in: view)
            show()
            UISelectionFeedbackGenerator().selectionChanged()
            Diagnostics.shared.step("words picked")
        case .changed:
            guard view === overlay else { return }
            stretch(to: point)
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

    /// Picks from the part that stays to the letter at this place.
    private func stretch(to point: CGPoint) {
        guard let index = letter(near: point) else { return }
        let from = min(fixed.location, index)
        let to = max(fixed.location + fixed.length, index + 1)
        let next = NSRange(location: from, length: to - from)
        guard next != range else { return }
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
