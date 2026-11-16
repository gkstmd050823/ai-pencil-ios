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
final class WetInk: UIView {
    private struct Piece {
        var path: CGPath
        var box: CGRect
    }

    private final class Line {
        var pieces: [Piece] = []
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

    /// A tile: a square of the screen's pixels.
    private final class Tile: CALayer {
        weak var ink: WetInk?

        override func draw(in context: CGContext) {
            guard let ink else { return }
            // (From the tile's own measure to the page's.)
            context.translateBy(x: -frame.minX, y: -frame.minY)
            ink.paint(in: context, clip: context.boundingBoxOfClipPath)
        }
    }

    private var lines: [Line] = []
    private var live: Line?
    /// The piece of the line being written that is still growing, and the first of the line's points in it.
    private var open: Piece?
    private var openFrom = 0
    private var tiles: [Int64: Tile] = [:]
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
        for line in lines { invalidate(line.box) }
        if let live { invalidate(live.box) }
    }

    // MARK: drawing

    fileprivate func paint(in context: CGContext, clip: CGRect) {
        func fill(_ line: Line, _ extra: Piece?) {
            var any = false
            for piece in line.pieces where piece.box.intersects(clip) {
                context.addPath(piece.path)
                any = true
            }
            if let extra, extra.box.intersects(clip) {
                context.addPath(extra.path)
                any = true
            }
            if any {
                context.setFillColor(line.color)
                context.fillPath()
            }
        }
        for line in lines where line.box.intersects(clip) { fill(line, nil) }
        if let live { fill(live, open) }
    }

    private func key(_ column: Int, _ row: Int) -> Int64 {
        Int64(column) << 32 | Int64(UInt32(bitPattern: Int32(row)))
    }

    /// Has the part of the tiles that covers [rect] drawn again, making tiles where there are none.
    private func invalidate(_ rect: CGRect) {
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
                var tile = tiles[at]
                if tile == nil {
                    let made = Tile()
                    made.ink = self
                    made.contentsScale = scale
                    made.isOpaque = false
                    // (Nothing about a tile is animated: it shows what was drawn at once.)
                    made.actions = ["contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(), "bounds": NSNull(), "position": NSNull()]
                    made.frame = CGRect(x: grid.x + CGFloat(column) * step, y: grid.y + CGFloat(row) * step, width: step, height: step)
                    layer.addSublayer(made)
                    tiles[at] = made
                    tile = made
                }
                if let tile {
                    let inside = dirty.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY).intersection(tile.bounds)
                    if !inside.isNull, !inside.isEmpty { tile.setNeedsDisplay(inside) }
                }
            }
        }
    }

    /// Takes away the tiles that no line reaches any more.
    private func prune() {
        guard !tiles.isEmpty else { return }
        if lines.isEmpty, live == nil {
            tiles.values.forEach { $0.removeFromSuperlayer() }
            tiles = [:]
            return
        }
        for (at, tile) in tiles {
            let reached = lines.contains { $0.box.intersects(tile.frame) } || (live?.box.intersects(tile.frame) ?? false)
            if !reached {
                tile.removeFromSuperlayer()
                tiles[at] = nil
            }
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
        var dirty = open?.box ?? .null
        // A long line is cut into pieces, so that only its last piece is worked out again as it grows. A
        // piece is closed where the line is settled: what comes after that may still change.
        while line.settled - openFrom > 64 {
            let path = line.shape(from: openFrom, to: line.settled, fineness: scale)
            let piece = Piece(path: path, box: path.boundingBoxOfPath)
            current.pieces.append(piece)
            current.box = current.box.union(piece.box)
            dirty = dirty.union(piece.box)
            openFrom = max(0, line.settled - 1)
        }
        let path = line.shape(from: openFrom, fineness: scale)
        let piece = Piece(path: path, box: path.boundingBoxOfPath)
        open = piece
        current.box = current.box.union(piece.box)
        invalidate(dirty.union(piece.box))
    }

    /// The line being written came to nothing.
    func drop() {
        guard let gone = live else { return }
        live = nil
        open = nil
        openFrom = 0
        invalidate(gone.box)
        prune()
    }

    /// The line being written is part of the handwriting from [version] on, as the stroke made at [date].
    /// It stays on show until the picture has it.
    func keep(version: Int, date: Date?) {
        guard let done = live else { return }
        if let open { done.pieces.append(open) }
        done.version = version
        done.date = date
        lines.append(done)
        live = nil
        open = nil
        openFrom = 0
    }

    /// Any other line that is part of the handwriting from [version] on (a shape, say): the places it
    /// goes through and how wide it is.
    func add(points: [CGPoint], width: CGFloat, color: CGColor, version: Int, date: Date?) {
        guard points.count > 1 else { return }
        let path = InkPaint.shape(points: points, widths: [CGFloat](repeating: width, count: points.count), from: 0, fineness: scale)
        let line = Line(color: color)
        line.pieces = [Piece(path: path, box: path.boundingBoxOfPath)]
        line.box = line.pieces[0].box
        line.version = version
        line.date = date
        lines.append(line)
        invalidate(line.box)
    }

    /// Takes down the lines that [gone] says are no longer wanted.
    private func remove(where gone: (Line) -> Bool) {
        var changed = false
        lines.removeAll { line in
            guard gone(line) else { return false }
            invalidate(line.box)
            changed = true
            return true
        }
        if changed { prune() }
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
