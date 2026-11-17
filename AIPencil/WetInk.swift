import UIKit

/// The handwriting that is not in the page's picture yet: the line being written, and the lines written
/// since the picture was last made. It is drawn the way the picture is (the same shapes, filled by the
/// same code, on the screen's own pixels), so a line looks while it is being written exactly as it looks
/// afterwards, at any zoom, and nothing changes on screen when the picture takes it over.
///
/// (Until 0.9.0 these lines were shown as shape layers, which the system draws its own way: their curves
/// came out less smooth than in the picture, and far zoomed in they were coarse.)
///
/// The view is as large as the page and holds small square tiles, made only where there is something to
/// draw. A line that grows redraws just the part of the tiles it grew into.
///
/// There are two sets of tiles: one for the lines that are waiting, and above it one for the line being
/// written. (Until 0.12.2 there was one set for both. Each time the pen moved, the part of a tile the
/// line grew into was drawn again with everything in it, which is every waiting line that passes there:
/// a scribble, line over line over line and no pause for a picture to take them, cost more with each
/// line, and the pen fell behind.) Now a pen that moves has only its own line drawn again, and a line
/// that is finished is drawn once more, into the other set, when the pen lifts.
final class WetInk: UIView {
    private struct Piece {
        var path: CGPath
        var box: CGRect
    }

    private final class Line {
        var pieces: [Piece] = []
        /// Not zero: the pieces are lines of this width run through the line's points, and not shapes to fill.
        var width: CGFloat = 0
        var color: CGColor
        /// The number the handwriting had once this line was part of it; the largest there is while it is being written.
        var version = Int.max
        /// When the stroke this line became was made, which tells strokes apart.
        var date: Date?
        var box = CGRect.null

        init(color: CGColor) {
            self.color = color
        }
    }

    /// A tile: a square of the screen's pixels, of the lines that are waiting or of the line being written.
    private final class Tile: CALayer {
        weak var ink: WetInk?
        var ofLive = false
        /// A waiting tile's own pixels, which what it shows is made of (see WetInk.show). Nil for a tile
        /// of the line being written, which draws itself when asked.
        var bitmap: CGContext?

        override func draw(in context: CGContext) {
            guard let ink else { return }
            // (From the tile's own measure to the page's.)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            ink.paint(in: context, clip: context.boundingBoxOfClipPath, live: ofLive)
        }
    }

    /// Lines written from here on are of one width all along (a highlighter's), and are drawn as a line
    /// of that width through some of their points, the way the picture of the handwriting draws them.
    /// Filled as a shape, a disc at every point, such a line cost many times as much to draw each time
    /// the pen moved, and more with every line still on show beside it.
    var asLines = false
    private var lines: [Line] = []
    private var live: Line?
    /// The piece of the line being written that is still growing, and the first of the line's points in it.
    private var open: Piece?
    private var openFrom = 0
    /// The tiles of the lines that are waiting, and those of the line being written.
    private var tiles: [Int64: Tile] = [:]
    private var liveTiles: [Int64: Tile] = [:]
    /// What the two sets of tiles are put in: two views, without a size of their own, at this view's corner.
    ///
    /// They have to be views. In 0.12.3 they were plain layers, and every line blinked as the pen
    /// lifted: a layer that is not a view's animates what is done to it, the coming and going of its
    /// sublayers too, as a fade of a quarter of a second. A finished line goes from one set of tiles to
    /// the other; it was wiped from the first at once and faded into the second. (The tiles themselves
    /// were told to animate nothing, which does not cover the layer they are put in. Until 0.12.2 they
    /// were put in this view's own layer, and a view's layer animates nothing by itself.)
    private let waitingHost = UIView()
    private let liveHost = UIView()
    private var waitingLayer: CALayer { waitingHost.layer }
    private var liveLayer: CALayer { liveHost.layer }
    /// Parts of the waiting tiles that have to be drawn again from nothing, by tile.
    private var stale: [Int64: CGRect] = [:]
    /// "-demoOldWaiting" has the waiting lines' tiles draw themselves, as they did until 0.13.0, for the
    /// build server to set the time that takes beside the time it takes now.
    private static let oldWaiting = ProcessInfo.processInfo.arguments.contains("-demoOldWaiting")
    /// Pixels to a page point, and where a pixel of the screen begins (see the page view's pixelGrid).
    private(set) var scale: CGFloat = 2
    private var grid = CGPoint.zero
    /// A tile's side in pixels.
    private static let side: CGFloat = 384

    /// How many lines are waiting for the picture to have them.
    var count: Int { lines.count }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        // (What is in them is placed in this view's own measure.)
        for host in [waitingHost, liveHost] {
            host.isUserInteractionEnabled = false
            host.backgroundColor = .clear
            host.isOpaque = false
            host.frame = .zero
            // (And nothing of theirs is animated even where something asks for animations around them.)
            host.layer.actions = ["sublayers": NSNull(), "contents": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            addSubview(host)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Says how fine the screen is at the zoom in force and where its pixels fall. When either has
    /// changed, the tiles are made anew.
    func fit(scale: CGFloat, grid: CGPoint) {
        guard scale > 0 else { return }
        if abs(scale - self.scale) < 0.0005 * scale, abs(grid.x - self.grid.x) * scale < 0.05, abs(grid.y - self.grid.y) * scale < 0.05 { return }
        self.scale = scale
        self.grid = grid
        tiles.values.forEach { $0.removeFromSuperlayer() }
        tiles = [:]
        liveTiles.values.forEach { $0.removeFromSuperlayer() }
        liveTiles = [:]
        stale = [:]
        for line in lines { invalidate(line.box, live: false) }
        freshen()
        if let live { invalidate(live.box, live: true) }
    }

    // MARK: drawing

    /// Draws what of a line (and of [extra], a piece of it not yet among its pieces) reaches [clip].
    private func fill(_ line: Line, _ extra: Piece?, in context: CGContext, clip: CGRect) {
        var any = false
        for piece in line.pieces where piece.box.intersects(clip) {
            context.addPath(piece.path)
            any = true
        }
        if let extra, extra.box.intersects(clip) {
            context.addPath(extra.path)
            any = true
        }
        if any, line.width > 0 {
            context.setStrokeColor(line.color)
            context.setLineWidth(line.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else if any {
            context.setFillColor(line.color)
            context.fillPath()
        }
    }

    fileprivate func paint(in context: CGContext, clip: CGRect, live ofLive: Bool) {
        if ofLive {
            if let live { fill(live, open, in: context, clip: clip) }
        } else {
            for line in lines where line.box.intersects(clip) { fill(line, nil, in: context, clip: clip) }
        }
    }

    /// Pixels of its own for a waiting tile at [frame], set up so that a point of the page is drawn where
    /// the tile shows it.
    private func pixels(for frame: CGRect) -> CGContext? {
        let side = Int(Self.side)
        guard !Self.oldWaiting, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        return context
    }

    /// Draws the stale parts of the waiting tiles again from nothing: every waiting line that passes there.
    private func freshen() {
        guard !stale.isEmpty else { return }
        let parts = stale
        stale = [:]
        for (at, part) in parts {
            guard let tile = tiles[at], !part.isNull, !part.isEmpty else { continue }
            guard let context = tile.bitmap else {
                // (A tile without pixels of its own draws itself, as every tile did until 0.13.0.)
                tile.setNeedsDisplay(part.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
                continue
            }
            context.saveGState()
            context.clip(to: part)
            context.clear(part)
            for line in lines where line.box.intersects(part) { fill(line, nil, in: context, clip: part) }
            context.restoreGState()
            tile.contents = context.makeImage()
        }
    }

    /// Puts one more waiting line on show: it is drawn over what its tiles show already, and nothing
    /// that was there is drawn again.
    ///
    /// Until 0.13.0 the tiles of the waiting lines drew themselves the way those of the line being
    /// written do, and a layer that draws itself first clears the part it is asked to draw: every time
    /// a line was finished, every waiting line that passed where it lay was drawn again with it. Lines
    /// scribbled one over another without a pause, zoomed in, took longer to finish with each one (on
    /// the build server 0.6 seconds for the fifth, 1.7 for the fifteenth).
    private func show(_ line: Line) {
        reach(line.box, live: false) { at, tile, part, made in
            // (A tile just made, one with a part to draw again, or one that draws itself: drawn the full way.)
            guard !made, self.stale[at] == nil, let context = tile.bitmap else {
                self.stale[at] = (self.stale[at] ?? .null).union(made ? tile.frame : part)
                return
            }
            context.saveGState()
            context.clip(to: part)
            self.fill(line, nil, in: context, clip: part)
            context.restoreGState()
            tile.contents = context.makeImage()
        }
        freshen()
    }

    private func key(_ column: Int, _ row: Int) -> Int64 {
        Int64(column) << 32 | Int64(UInt32(bitPattern: Int32(row)))
    }

    /// Has the part of the tiles that covers [rect] drawn again, making tiles where there are none: the
    /// tiles of the line being written ([live]) at the screen's next turn, or those of the lines that
    /// are waiting when freshen() is next called.
    private func invalidate(_ rect: CGRect, live ofLive: Bool) {
        reach(rect, live: ofLive) { at, tile, part, _ in
            if ofLive {
                tile.setNeedsDisplay(part.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
            } else {
                self.stale[at] = (self.stale[at] ?? .null).union(part)
            }
        }
    }

    /// The tiles of one of the two sets that [rect] reaches, made where there are none. [each] is given
    /// the tile's place, the tile, the part of the page it shares with [rect] (grown to whole pixels),
    /// and whether the tile was made just now.
    private func reach(_ rect: CGRect, live ofLive: Bool, _ each: (Int64, Tile, CGRect, Bool) -> Void) {
        guard !rect.isNull, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { return }
        let step = Self.side / scale
        let dirty = rect.insetBy(dx: -1.5 / scale, dy: -1.5 / scale).intersection(bounds.insetBy(dx: -step, dy: -step))
        guard !dirty.isNull, !dirty.isEmpty else { return }
        let firstColumn = Int(((dirty.minX - grid.x) / step).rounded(.down)), lastColumn = Int(((dirty.maxX - grid.x) / step).rounded(.down))
        let firstRow = Int(((dirty.minY - grid.y) / step).rounded(.down)), lastRow = Int(((dirty.maxY - grid.y) / step).rounded(.down))
        guard lastColumn - firstColumn < 64, lastRow - firstRow < 64 else { return }
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let at = key(column, row)
                var tile = ofLive ? liveTiles[at] : tiles[at]
                var fresh = false
                if tile == nil {
                    fresh = true
                    let made = Tile()
                    made.ink = self
                    made.ofLive = ofLive
                    made.contentsScale = scale
                    made.isOpaque = false
                    // (Nothing about a tile is animated: it shows what was drawn at once.)
                    made.actions = [
                        "contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "bounds": NSNull(), "position": NSNull(),
                        "opacity": NSNull(), "hidden": NSNull(), "sublayers": NSNull(),
                    ]
                    made.frame = CGRect(x: grid.x + CGFloat(column) * step, y: grid.y + CGFloat(row) * step, width: step, height: step)
                    if ofLive {
                        liveLayer.addSublayer(made)
                        liveTiles[at] = made
                    } else {
                        made.bitmap = pixels(for: made.frame)
                        waitingLayer.addSublayer(made)
                        tiles[at] = made
                    }
                    tile = made
                }
                if let tile {
                    let part = InkPaint.whole(dirty, scale: scale, origin: grid).intersection(tile.frame)
                    if !part.isNull, !part.isEmpty { each(at, tile, part, fresh) }
                }
            }
        }
    }

    /// Takes away the tiles that no waiting line reaches any more.
    private func prune() {
        guard !tiles.isEmpty else { return }
        if lines.isEmpty {
            tiles.values.forEach { $0.removeFromSuperlayer() }
            tiles = [:]
            stale = [:]
            return
        }
        for (at, tile) in tiles {
            let reached = lines.contains { $0.box.intersects(tile.frame) }
            if !reached {
                tile.removeFromSuperlayer()
                tiles[at] = nil
                stale[at] = nil
            }
        }
    }

    /// The line that was being written is no longer: where it was, its tiles are drawn again, empty. (The
    /// tiles themselves stay for the next line, which as a rule begins close by; only when there are many
    /// are they let go.)
    private func wipeLive(_ box: CGRect) {
        if liveTiles.count > 32 {
            liveTiles.values.forEach { $0.removeFromSuperlayer() }
            liveTiles = [:]
        } else {
            invalidate(box, live: true)
        }
    }

    // MARK: the line being written

    /// Shows the line being written as it stands now.
    func write(_ line: PenLine, color: CGColor) {
        let current: Line
        if let live {
            current = live
        } else {
            current = Line(color: color)
            live = current
            open = nil
            openFrom = 0
        }
        if asLines { current.width = line.width }
        // The points from [from] up to [to] as a piece: a shape to fill or, for a line of one width, the
        // line itself, to be drawn that wide.
        func cut(_ from: Int, _ to: Int?) -> Piece {
            guard asLines else {
                let path = line.shape(from: from, to: to, fineness: scale)
                return Piece(path: path, box: path.boundingBoxOfPath)
            }
            let end = min(to ?? line.points.count, line.points.count)
            let path = CGMutablePath()
            guard end > 0 else { return Piece(path: path, box: .null) }
            let run = InkPaint.thinned(Array(line.points[max(0, min(from, end - 1))..<end]), gap: line.width * InkPaint.wideGap)
            path.move(to: run[0])
            if run.count == 1 { path.addLine(to: run[0]) }
            for point in run.dropFirst() { path.addLine(to: point) }
            let reach = line.width / 2 + 1 / scale
            return Piece(path: path, box: path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach))
        }
        var dirty = open?.box ?? .null
        // A long line is cut into pieces, so that only its last piece is worked out again as it grows. A
        // piece is closed where the line is settled: what comes after that may still change.
        while line.settled - openFrom > 64 {
            let piece = cut(openFrom, line.settled)
            current.pieces.append(piece)
            current.box = current.box.union(piece.box)
            dirty = dirty.union(piece.box)
            openFrom = max(0, line.settled - 1)
        }
        let piece = cut(openFrom, nil)
        open = piece
        current.box = current.box.union(piece.box)
        invalidate(dirty.union(piece.box), live: true)
    }

    /// The line being written has changed along its whole length (its ends were shaped as the pen
    /// lifted): what was made of it so far is let go, and the next writing of it makes it anew.
    func restart() {
        guard let live else { return }
        invalidate(live.box, live: true)
        live.pieces = []
        live.box = .null
        open = nil
        openFrom = 0
    }

    /// The line being written came to nothing.
    func drop() {
        guard let gone = live else { return }
        live = nil
        open = nil
        openFrom = 0
        wipeLive(gone.box)
    }

    /// The line being written is part of the handwriting from [version] on, as the stroke made at [date].
    /// It stays on show until the picture has it: it goes over from the tiles of the line being written
    /// to those of the lines that are waiting, where it is drawn this once.
    func keep(version: Int, date: Date?) {
        guard let done = live else { return }
        if let open { done.pieces.append(open) }
        done.version = version
        done.date = date
        lines.append(done)
        live = nil
        open = nil
        openFrom = 0
        show(done)
        wipeLive(done.box)
    }

    /// Any other line that is part of the handwriting from [version] on (a shape, say): the places it
    /// goes through and how wide it is.
    func add(points: [CGPoint], width: CGFloat, widths: [CGFloat]? = nil, color: CGColor, version: Int, date: Date?) {
        guard points.count > 1 else { return }
        let path = InkPaint.shape(points: points, widths: widths ?? [CGFloat](repeating: width, count: points.count), from: 0, fineness: scale)
        let line = Line(color: color)
        line.pieces = [Piece(path: path, box: path.boundingBoxOfPath)]
        line.box = line.pieces[0].box
        line.version = version
        line.date = date
        lines.append(line)
        show(line)
    }

    /// Takes down the lines that [gone] says are no longer wanted.
    private func remove(where gone: (Line) -> Bool) {
        var changed = false
        lines.removeAll { line in
            guard gone(line) else { return false }
            invalidate(line.box, live: false)
            changed = true
            return true
        }
        if changed {
            prune()
            freshen()
        }
    }

    /// The picture has every line up to [version]: those are taken down.
    func settle(upTo version: Int) {
        guard !lines.isEmpty else { return }
        remove { $0.version <= version }
    }

    /// Takes down every line (but the one being written).
    func clear() {
        guard !lines.isEmpty else { return }
        remove { _ in true }
    }

    /// The handwriting has changed some other way (a line rubbed out, undone): the lines whose strokes
    /// are no longer in it are taken down at once, without waiting for the picture.
    func keepOnly(strokesMadeAt dates: Set<Date>) {
        guard !lines.isEmpty else { return }
        remove { line in
            guard let date = line.date else { return true }
            return !dates.contains(date)
        }
    }
}
