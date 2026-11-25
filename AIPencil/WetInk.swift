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
/// draw. There are two sets of them.
///
/// The lower set holds everything that will not change any more: the lines that are waiting for the
/// picture, and of the line being written the part that is settled. Each of these tiles has pixels of
/// its own, and what is added is drawn over what is there: a piece of line is drawn once, when it is
/// settled, and never again for as long as it is on show. (Until 0.13.0 these tiles drew themselves, and
/// a layer that draws itself first clears what it is asked to draw: every waiting line that passed where
/// a new one lay was drawn again with it. Until 0.13.2 the whole of the line being written was in the
/// upper set, drawn again wherever the pen passed: a pencil moved fast to and fro, zoomed in far, wrote a
/// line of twenty-four thousand points in a few seconds, each move drew again every part of it that
/// crossed there, and lifting the pen made the whole of it anew. A test's notes had the app eight
/// seconds behind the pencil.)
///
/// The upper set holds the end of the line being written, which is not settled yet and changes with
/// every move of the pen. It is all that is drawn again as the pen moves.
final class WetInk: UIView {
    private struct Piece {
        var path: CGPath
        var box: CGRect
        /// The first of the line's points in the piece, and the one after its last.
        var from = 0
        var to = 0
        /// Where the piece joins the one before it: the pixels round its first point, which both pieces
        /// reach. Null for a line's first piece.
        ///
        /// Each piece ends in a disc and the next begins with the same disc. Drawn one after the other,
        /// the pixels on that disc's rim that are half covered were covered twice and came out a little
        /// darker than in the picture of the handwriting, which fills the line in one go (seventy to a
        /// hundred and twenty pixels of a screen, on the build server). So a piece is drawn everywhere
        /// but here, and here everything is drawn again from nothing, each line in one go.
        var joint = CGRect.null
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

    /// A tile: a square of the screen's pixels.
    private final class Tile: CALayer {
        weak var ink: WetInk?
        var ofLive = false
        /// A lower tile's own pixels, which what it shows is made of. Nil for an upper tile, which draws
        /// itself when asked (and for a lower one whose pixels could not be had, which does the same).
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
    /// The line being written: its settled pieces (which are in the lower tiles already) and, apart
    /// from them, the piece that is still growing, with the first of the line's points in it.
    private var live: Line?
    private var open: Piece?
    private var openFrom = 0
    /// The lower tiles and the upper ones.
    private var tiles: [Int64: Tile] = [:]
    private var liveTiles: [Int64: Tile] = [:]
    /// What the two sets of tiles are put in: two views, without a size of their own, at this view's corner.
    ///
    /// They have to be views. In 0.12.3 they were plain layers, and every line blinked as the pen
    /// lifted: a layer that is not a view's animates what is done to it, the coming and going of its
    /// sublayers too, as a fade of a quarter of a second. (The tiles themselves were told to animate
    /// nothing, which does not cover the layer they are put in.)
    private let waitingHost = UIView()
    private let liveHost = UIView()
    private var waitingLayer: CALayer { waitingHost.layer }
    private var liveLayer: CALayer { liveHost.layer }
    /// Parts of the lower tiles that have to be drawn again from nothing, by tile.
    private var stale: [Int64: CGRect] = [:]
    /// "-demoOldWaiting" has the lower tiles draw themselves, as they did until 0.13.0, for the build
    /// server to set the time that takes beside the time it takes now.
    private static let oldWaiting = ProcessInfo.processInfo.arguments.contains("-demoOldWaiting")
    /// Pixels to a page point, and where a pixel of the screen begins (see the page view's pixelGrid).
    private(set) var scale: CGFloat = 2
    private var grid = CGPoint.zero
    /// A tile's side in pixels.
    private static let side: CGFloat = 384

    /// How many lines are waiting for the picture to have them.
    var count: Int { lines.count + fastLines.count }

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
        if let live {
            for piece in live.pieces { invalidate(piece.box, live: false) }
        }
        freshen()
        if let open { invalidate(open.box, live: true) }
        if fast { renderFast() }
    }

    // MARK: drawing

    /// Draws those of [pieces] that reach [clip], as the line they are pieces of is drawn.
    private func fill(_ pieces: [Piece], of line: Line, in context: CGContext, clip: CGRect) {
        var any = false
        for piece in pieces where piece.box.intersects(clip) {
            context.addPath(piece.path)
            any = true
        }
        guard any else { return }
        if line.width > 0 {
            context.setStrokeColor(line.color)
            context.setLineWidth(line.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else {
            context.setFillColor(line.color)
            context.fillPath()
        }
    }

    /// Everything the lower tiles show that reaches [clip]: the waiting lines, then the settled pieces
    /// of the line being written.
    private func settledInk(in context: CGContext, clip: CGRect) {
        for line in lines where line.box.intersects(clip) { fill(line.pieces, of: line, in: context, clip: clip) }
        if let live { fill(live.pieces, of: live, in: context, clip: clip) }
    }

    /// What a tile that draws itself shows.
    fileprivate func paint(in context: CGContext, clip: CGRect, live ofLive: Bool) {
        if ofLive {
            if let live, let open { fill([open], of: live, in: context, clip: clip) }
        } else {
            settledInk(in: context, clip: clip)
        }
    }

    /// Pixels of its own for a lower tile at [frame], set up so that a point of the page is drawn where
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

    /// Draws the stale parts of the lower tiles again from nothing.
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
            settledInk(in: context, clip: part)
            context.restoreGState()
            tile.contents = context.makeImage()
        }
    }

    /// Puts pieces of a line on show in the lower tiles: drawn over what the tiles show already, and
    /// nothing that was there is drawn again. (The line has to be among the waiting lines, or be the
    /// line being written with these among its pieces, by the time freshen() is next called.)
    private func put(_ pieces: [Piece], of line: Line) {
        for piece in pieces {
            reach(piece.box, live: false) { at, tile, part, made in
                // (A tile just made, one with a part to draw again, or one that draws itself: drawn the full way.)
                guard !made, self.stale[at] == nil, let context = tile.bitmap else {
                    self.stale[at] = (self.stale[at] ?? .null).union(made ? tile.frame : part)
                    return
                }
                let joint = piece.joint.intersection(part)
                context.saveGState()
                if joint.isNull || joint.isEmpty {
                    context.clip(to: part)
                } else {
                    // (Everywhere in the part but at the joint, which is drawn again whole below.)
                    context.addRect(part)
                    context.addRect(joint)
                    context.clip(using: .evenOdd)
                }
                self.fill([piece], of: line, in: context, clip: part)
                context.restoreGState()
                tile.contents = context.makeImage()
                if !joint.isNull, !joint.isEmpty { self.stale[at] = joint }
            }
        }
    }

    private func key(_ column: Int, _ row: Int) -> Int64 {
        Int64(column) << 32 | Int64(UInt32(bitPattern: Int32(row)))
    }

    /// Has the part of the tiles that covers [rect] drawn again, making tiles where there are none: the
    /// upper tiles at the screen's next turn, or the lower ones when freshen() is next called.
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
        let whole = InkPaint.whole(dirty, scale: scale, origin: grid)
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
                    let part = whole.intersection(tile.frame)
                    if !part.isNull, !part.isEmpty { each(at, tile, part, fresh) }
                }
            }
        }
    }

    /// Takes away the lower tiles that nothing settled reaches any more.
    private func prune() {
        guard !tiles.isEmpty else { return }
        let settled = live?.pieces ?? []
        if lines.isEmpty, settled.isEmpty {
            tiles.values.forEach { $0.removeFromSuperlayer() }
            tiles = [:]
            stale = [:]
            return
        }
        for (at, tile) in tiles {
            let reached = lines.contains { $0.box.intersects(tile.frame) } || settled.contains { $0.box.intersects(tile.frame) }
            if !reached {
                tile.removeFromSuperlayer()
                tiles[at] = nil
                stale[at] = nil
            }
        }
    }

    /// The end of the line that was being written is no longer in the upper tiles: where it was, they
    /// are drawn again, empty. (The tiles themselves stay for the next line, which as a rule begins
    /// close by; only when there are many are they let go.)
    private func wipeLive(_ box: CGRect) {
        if liveTiles.count > 32 {
            liveTiles.values.forEach { $0.removeFromSuperlayer() }
            liveTiles = [:]
        } else {
            invalidate(box, live: true)
        }
    }

    // MARK: the line being written

    /// The points of [line] from [from] up to [to] as a piece: a shape to fill or, for a line of one
    /// width, the line itself, to be drawn that wide.
    private func cut(_ line: PenLine, _ from: Int, _ to: Int?) -> Piece {
        let end = min(to ?? line.points.count, line.points.count)
        // (Where it joins the piece before: the pixels its first point's disc reaches, and one more round them.)
        var joint = CGRect.null
        if from > 0, from < line.points.count {
            let reach = (asLines ? line.width : line.widths[from]) / 2 + 1.5 / scale
            let at = line.points[from]
            joint = InkPaint.whole(CGRect(x: at.x - reach, y: at.y - reach, width: reach * 2, height: reach * 2), scale: scale, origin: grid)
        }
        guard asLines else {
            let path = line.shape(from: from, to: to, fineness: scale)
            return Piece(path: path, box: path.boundingBoxOfPath, from: from, to: end, joint: joint)
        }
        let path = CGMutablePath()
        guard end > 0 else { return Piece(path: path, box: .null, from: from, to: end) }
        let run = InkPaint.thinned(Array(line.points[max(0, min(from, end - 1))..<end]), gap: line.width * InkPaint.wideGap)
        path.move(to: run[0])
        if run.count == 1 { path.addLine(to: run[0]) }
        for point in run.dropFirst() { path.addLine(to: point) }
        let reach = line.width / 2 + 1 / scale
        return Piece(path: path, box: path.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach), from: from, to: end, joint: joint)
    }

    /// Shows the line being written as it stands now.
    func write(_ line: PenLine, color: CGColor) {
        chooseWay()
        if fast {
            writeFast(line, color: color)
            return
        }
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
        let before = open?.box ?? .null
        // A long line is cut into pieces. A piece is closed where the line is settled (what comes after
        // that may still change), and goes into the lower tiles there and then, for good.
        var closed: [Piece] = []
        while line.settled - openFrom > 64 {
            let piece = cut(line, openFrom, line.settled)
            current.pieces.append(piece)
            current.box = current.box.union(piece.box)
            closed.append(piece)
            openFrom = max(0, line.settled - 1)
        }
        if !closed.isEmpty {
            put(closed, of: current)
            freshen()
        }
        // What is left is the end that is still growing: the upper tiles show it, and only it.
        let piece = cut(line, openFrom, nil)
        open = piece
        current.box = current.box.union(piece.box)
        invalidate(before.union(piece.box), live: true)
    }

    /// The line being written has changed from point [from] on (its end was shaped as the pen lifted, or
    /// it was made a straight line): what was made of it from there on is let go, and the next writing
    /// of it makes that anew. What was made of it before that point stays as it is.
    func restart(from: Int = 0) {
        if fast {
            restartFast(from: from)
            return
        }
        guard let live else { return }
        if let open { invalidate(open.box, live: true) }
        open = nil
        guard let first = live.pieces.firstIndex(where: { $0.to > from }) else { return }
        for piece in live.pieces[first...] { invalidate(piece.box, live: false) }
        openFrom = live.pieces[first].from
        live.pieces.removeSubrange(first...)
        freshen()
    }

    /// The line being written came to nothing.
    func drop() {
        if fast {
            if fastLive != nil {
                fastLive = nil
                renderFast()
            }
            return
        }
        guard let gone = live else { return }
        live = nil
        for piece in gone.pieces { invalidate(piece.box, live: false) }
        let end = open
        open = nil
        openFrom = 0
        if !gone.pieces.isEmpty {
            prune()
            freshen()
        }
        wipeLive(end?.box ?? gone.box)
    }

    /// The line being written is part of the handwriting from [version] on, as the stroke made at [date].
    /// It stays on show until the picture has it. Its settled pieces are in the lower tiles already; its
    /// end joins them now.
    func keep(version: Int, date: Date?) {
        if fast {
            // (It is on show already, whole: nothing is drawn.)
            guard let done = fastLive else { return }
            done.version = version
            done.date = date
            fastLines.append(done)
            fastLive = nil
            return
        }
        guard let done = live else { return }
        let end = open
        if let end {
            done.pieces.append(end)
            put([end], of: done)
        }
        done.version = version
        done.date = date
        lines.append(done)
        live = nil
        open = nil
        openFrom = 0
        freshen()
        wipeLive(end?.box ?? done.box)
    }

    /// Any other line that is part of the handwriting from [version] on (a shape, say): the places it
    /// goes through and how wide it is.
    func add(points: [CGPoint], width: CGFloat, widths: [CGFloat]? = nil, color: CGColor, version: Int, date: Date?) {
        guard points.count > 1 else { return }
        chooseWay()
        if fast {
            let line = FastLine(colour: InkGPU.colour(color))
            let wide = widths ?? [CGFloat](repeating: width, count: points.count)
            line.box = Self.stretches(points, wide, from: 0, to: points.count, into: &line.numbers)
            line.version = version
            line.date = date
            fastLines.append(line)
            renderFast()
            return
        }
        let path = InkPaint.shape(points: points, widths: widths ?? [CGFloat](repeating: width, count: points.count), from: 0, fineness: scale)
        let line = Line(color: color)
        line.pieces = [Piece(path: path, box: path.boundingBoxOfPath, from: 0, to: points.count)]
        line.box = line.pieces[0].box
        line.version = version
        line.date = date
        lines.append(line)
        put(line.pieces, of: line)
        freshen()
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
        if fast {
            removeFast { $0.version <= version }
            return
        }
        guard !lines.isEmpty else { return }
        remove { $0.version <= version }
    }

    /// Takes down every line (but the one being written).
    func clear() {
        if fast {
            removeFast { _ in true }
            return
        }
        guard !lines.isEmpty else { return }
        remove { _ in true }
    }

    /// The handwriting has changed some other way (a line rubbed out, undone): the lines whose strokes
    /// are no longer in it are taken down at once, without waiting for the picture.
    func keepOnly(strokesMadeAt dates: Set<Date>) {
        if fast {
            removeFast { line in
                guard let date = line.date else { return true }
                return !dates.contains(date)
            }
            return
        }
        guard !lines.isEmpty else { return }
        remove { line in
            guard let date = line.date else { return true }
            return !dates.contains(date)
        }
    }

    // MARK: by the graphics processor

    // Since 0.18.0 the lines here are drawn by the graphics processor where there is one (see InkGPU):
    // one layer over the part of the page in view, into which every line not in the picture yet is drawn
    // whole each time the pen moves. Nothing is cut into pieces, no tiles are kept, and what a move of
    // the pen costs the main thread does not grow with the line or with the lines beside it. The tiles
    // above are what draws where there is no graphics processor, or with the setting switched off.

    /// The view whose layer the graphics processor draws into. (A view, so that nothing done to it is animated.)
    private final class MetalHost: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
    }

    private final class FastLine {
        /// Every stretch of the line as six numbers (see InkGPU).
        var numbers: [Float] = []
        var colour: SIMD4<Float>
        var version = Int.max
        var date: Date?
        var box = CGRect.null

        init(colour: SIMD4<Float>) {
            self.colour = colour
        }
    }

    /// Whether lines are drawn that way (설정 → "쓰는 중인 선도 GPU로"; on unless switched off).
    static var wantsFast: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-noGPU") || arguments.contains("-noGPULive") { return false }
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "gpuLive") == nil ? true : defaults.bool(forKey: "gpuLive")
    }

    /// Set while the lines on show are the graphics processor's. It changes only while nothing is on show.
    private var fast = false
    private var fastHost: MetalHost?
    private var fastLines: [FastLine] = []
    private var fastLive: FastLine?
    /// Of the line being written: how many of its points have their stretches made for good, how many
    /// numbers those are, and the room they take.
    private var fastDone = 0
    private var fastKept = 0
    private var fastDoneBox = CGRect.null
    /// What the layer was last placed for.
    private var fastScale: CGFloat = 0
    private var fastGrid = CGPoint.zero
    private var fastTries = 0
    /// How long the main thread spent on showing lines this way since last asked: how often, in all, at most (ms).
    private static var shows = 0
    private static var showSum: Double = 0
    private static var showMost: Double = 0
    /// The views that have a layer of the graphics processor's, the latest last. A layer holds the
    /// pixels of a screen three times over: only the two last used keep theirs while empty.
    private static var holders: [() -> WetInk?] = []

    /// For the test notes: what showing lines by the graphics processor cost the main thread since last asked.
    static func takeTimes() -> String? {
        guard shows > 0 else { return nil }
        let text = String(format: "pen: shown by the GPU %d times, %.2f ms of the main thread each on average, %.2f at most", shows, showSum / Double(shows), showMost)
        shows = 0
        showSum = 0
        showMost = 0
        return text
    }

    private func chooseWay() {
        guard lines.isEmpty, live == nil, fastLines.isEmpty, fastLive == nil else { return }
        fast = Self.wantsFast && InkGPU.shared != nil
    }

    /// Stretches for the points from [from] up to [to] of a line, added to [numbers]; the room they take.
    private static func stretches(_ points: [CGPoint], _ widths: [CGFloat], from: Int, to: Int, into numbers: inout [Float]) -> CGRect {
        let count = min(points.count, widths.count)
        var left = CGFloat.infinity, top = CGFloat.infinity, right = -CGFloat.infinity, bottom = -CGFloat.infinity
        var any = false
        func reach(_ point: CGPoint, _ radius: CGFloat) {
            left = min(left, point.x - radius)
            right = max(right, point.x + radius)
            top = min(top, point.y - radius)
            bottom = max(bottom, point.y + radius)
            any = true
        }
        var index = max(0, from)
        let end = min(to, count)
        while index < end {
            let width = widths[index]
            if width > 0 {
                let here = points[index]
                let joinsAfter = index + 1 < count && widths[index + 1] > 0
                if joinsAfter {
                    let next = points[index + 1]
                    numbers.append(Float(here.x))
                    numbers.append(Float(here.y))
                    numbers.append(Float(next.x))
                    numbers.append(Float(next.y))
                    numbers.append(Float(width / 2))
                    numbers.append(Float(widths[index + 1] / 2))
                    reach(here, width / 2)
                    reach(next, widths[index + 1] / 2)
                } else if index == 0 || widths[index - 1] <= 0 {
                    // (A place with nothing inked on either side of it: a dot.)
                    numbers.append(Float(here.x))
                    numbers.append(Float(here.y))
                    numbers.append(Float(here.x))
                    numbers.append(Float(here.y))
                    numbers.append(Float(width / 2))
                    numbers.append(Float(width / 2))
                    reach(here, width / 2)
                }
            }
            index += 1
        }
        guard any else { return .null }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func writeFast(_ line: PenLine, color: CGColor) {
        let current: FastLine
        if let fastLive {
            current = fastLive
        } else {
            current = FastLine(colour: InkGPU.colour(color))
            fastLive = current
            fastDone = 0
            fastKept = 0
            fastDoneBox = .null
        }
        if asLines {
            // A highlighter's line: one width all along, through some of its points. Made anew each time.
            var whole = InkPaint.Line()
            whole.points = line.points
            whole.widths = [CGFloat](repeating: line.width, count: line.points.count)
            whole.even = true
            current.numbers = InkGPU.numbers(of: whole, wide: true)
            var room = CGRect.null
            if let first = line.points.first {
                var left = first.x, right = first.x, top = first.y, bottom = first.y
                for point in line.points {
                    left = min(left, point.x)
                    right = max(right, point.x)
                    top = min(top, point.y)
                    bottom = max(bottom, point.y)
                }
                room = CGRect(x: left, y: top, width: right - left, height: bottom - top).insetBy(dx: -line.width / 2, dy: -line.width / 2)
            }
            current.box = room
        } else if let dash = line.dash {
            // A dashed line is cut to its pattern, whole, each time.
            let cut = dash.cut(points: line.points, widths: line.widths, along: line.along)
            var made: [Float] = []
            current.box = Self.stretches(cut.points, cut.widths, from: 0, to: cut.points.count, into: &made)
            current.numbers = made
        } else {
            // The stretches between points that will stay as they are are made once; only the end of
            // the line, which changes with every move of the pen, is made again.
            let points = line.points, widths = line.widths
            let count = min(points.count, widths.count)
            let stable = max(0, min(line.settled, count) - 2)
            if stable < fastDone {
                fastDone = 0
                fastKept = 0
                fastDoneBox = .null
            }
            if current.numbers.count > fastKept { current.numbers.removeSubrange(fastKept...) }
            if stable > fastDone {
                let room = Self.stretches(points, widths, from: fastDone, to: stable, into: &current.numbers)
                fastDoneBox = fastDoneBox.union(room)
                fastKept = current.numbers.count
                fastDone = stable
            }
            let tail = Self.stretches(points, widths, from: fastDone, to: count, into: &current.numbers)
            current.box = fastDoneBox.union(tail)
        }
        renderFast()
    }

    private func restartFast(from: Int) {
        guard fastLive != nil else { return }
        if from - 2 < fastDone {
            fastDone = 0
            fastKept = 0
            fastDoneBox = .null
        }
    }

    private func removeFast(where gone: (FastLine) -> Bool) {
        let before = fastLines.count
        fastLines.removeAll(where: gone)
        if fastLines.count != before { renderFast() }
    }

    /// Lets the layer go, and the pixels it holds.
    private func dropHost() {
        fastHost?.removeFromSuperview()
        fastHost = nil
        fastScale = 0
    }

    private func makeHost() -> MetalHost? {
        if let fastHost { return fastHost }
        guard let gpu = InkGPU.shared else { return nil }
        let made = MetalHost(frame: .zero)
        made.isUserInteractionEnabled = false
        made.backgroundColor = .clear
        made.isOpaque = false
        made.isHidden = true
        guard let metal = made.layer as? CAMetalLayer else { return nil }
        gpu.ready(metal)
        addSubview(made)
        fastHost = made
        // (This one is the latest; of the others, those with nothing to show beyond the two last give theirs up.)
        var kept: [() -> WetInk?] = []
        for holder in Self.holders {
            if let other = holder(), other !== self, other.fastHost != nil { kept.append(holder) }
        }
        kept.append { [weak self] in self }
        var index = 0
        while index < kept.count - 2 {
            if let other = kept[index](), other.fastLines.isEmpty, other.fastLive == nil { other.dropHost() }
            index += 1
        }
        Self.holders = kept
        return made
    }

    /// Puts the layer over the part of the page in view (and a little round it), on the screen's pixels.
    /// False when none of the page is in view.
    private func placeFast(_ host: MetalHost) -> Bool {
        guard let window, let metal = host.layer as? CAMetalLayer, scale > 0 else { return false }
        let seen = convert(window.bounds, from: nil).intersection(bounds)
        guard !seen.isNull, seen.width > 0.5, seen.height > 0.5 else { return false }
        let same = abs(fastScale - scale) < 0.0005 * scale && abs(fastGrid.x - grid.x) * scale < 0.05 && abs(fastGrid.y - grid.y) * scale < 0.05
        if same, host.frame.insetBy(dx: -1 / scale, dy: -1 / scale).contains(seen) { return true }
        var want = seen.insetBy(dx: -seen.width * 0.1, dy: -seen.height * 0.1).intersection(bounds)
        if want.width * scale > 4096 || want.height * scale > 4096 { want = seen }
        let rect = InkPaint.whole(want, scale: scale, origin: grid)
        let wide = min(4096, max(1, Int((rect.width * scale).rounded())))
        let high = min(4096, max(1, Int((rect.height * scale).rounded())))
        host.frame = CGRect(x: rect.minX, y: rect.minY, width: CGFloat(wide) / scale, height: CGFloat(high) / scale)
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: wide, height: high)
        fastScale = scale
        fastGrid = grid
        return true
    }

    /// Draws every line there is, whole.
    private func renderFast() {
        guard let gpu = InkGPU.shared else { return }
        var all = fastLines
        if let fastLive { all.append(fastLive) }
        if all.isEmpty {
            fastHost?.isHidden = true
            return
        }
        guard let host = makeHost(), let metal = host.layer as? CAMetalLayer else { return }
        guard placeFast(host) else {
            host.isHidden = true
            return
        }
        let began = CACurrentMediaTime()
        var numbers: [Float] = []
        var runs: [InkGPU.LiveRun] = []
        for line in all where !line.numbers.isEmpty {
            let first = numbers.count / 6
            let count = line.numbers.count / 6
            numbers.append(contentsOf: line.numbers)
            if let last = runs.last, last.colour == line.colour {
                runs[runs.count - 1].count = last.count + count
                runs[runs.count - 1].box = last.box.union(line.box)
            } else {
                runs.append(InkGPU.LiveRun(colour: line.colour, first: first, count: count, box: line.box))
            }
        }
        if gpu.show(numbers, runs: runs, on: metal, origin: host.frame.origin, scale: scale) {
            host.isHidden = false
            fastTries = 0
            let took = (CACurrentMediaTime() - began) * 1000
            Self.shows += 1
            Self.showSum += took
            if took > Self.showMost { Self.showMost = took }
        } else if fastTries < 3 {
            // (Nothing to draw into this moment: once more, right after.)
            fastTries += 1
            DispatchQueue.main.async { [weak self] in self?.renderFast() }
        }
    }

    /// The page has moved on screen, perhaps: lines waiting here are drawn again where the layer no
    /// longer reaches as far as the page is in view.
    func tend() {
        guard fast, !fastLines.isEmpty || fastLive != nil, let host = fastHost, let window else { return }
        let seen = convert(window.bounds, from: nil).intersection(bounds)
        guard !seen.isNull, !seen.isEmpty else { return }
        if host.isHidden || !host.frame.insetBy(dx: -1 / scale, dy: -1 / scale).contains(seen) { renderFast() }
    }
}
