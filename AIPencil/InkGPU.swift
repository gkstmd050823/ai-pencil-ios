import Metal
import PencilKit
import UIKit

/// The picture of a page's handwriting, made by the graphics processor.
///
/// The app's own drawing of the handwriting (see InkPaint) fills every line as a shape with Core Graphics,
/// on the processor: at a zoom of five a full page of writing is millions of pixels and tens of thousands
/// of small shapes, and the picture is seconds in the making. Here the same lines are handed to Metal as
/// they are: every stretch of a line, from one of its points to the next, is one small piece, and the
/// graphics processor works out for each pixel how far it is from that stretch (a shape with a round end
/// of its own width at either point). Nothing is made into triangles on the processor, and nothing
/// depends on the zoom but one number: a page drawn again at another zoom is the same pieces drawn again.
///
/// A line is many stretches that overlap, and a pixel on the line's edge is half covered by more than
/// one of them. Painted one over the other they would darken that edge. So the lines of one colour that
/// follow one another are first drawn into a picture of how much of each pixel is covered, each pixel
/// keeping the most any stretch covers of it, and that is then painted in the colour over what is there
/// already. (Core Graphics fills a line as one shape, which comes to the same.)
///
/// What comes out is a picture like InkPaint's, for the same part of the page on the same pixels, and
/// is put on screen the same way: nothing else in the app knows which of the two made it. Strokes that
/// are PencilKit's to draw (its pencil, a line the part eraser has cut) are not drawn here; a page that
/// has them in view is left to InkPaint.
///
/// Used from one queue at a time.
final class InkGPU {
    /// Nil where there is no graphics processor to be had, or its programs could not be made.
    static let shared: InkGPU? = InkGPU()

    /// Whether the pictures are to be made here (설정 → "GPU로 필기 그리기"; on unless switched off).
    static var wanted: Bool {
        if ProcessInfo.processInfo.arguments.contains("-noGPU") { return false }
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "gpuInk") == nil ? true : defaults.bool(forKey: "gpuInk")
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cover: MTLRenderPipelineState
    private let paint: MTLRenderPipelineState

    /// A stroke's line as it was last worked out, by the moment the stroke was made.
    private struct Kept {
        var count: Int
        var turn: CGAffineTransform
        var first: CGPoint
        var step: CGFloat
        var line: InkPaint.Line
    }

    private var kept: [Date: Kept] = [:]
    /// How long the last picture's parts took, in milliseconds: working out the lines, the graphics
    /// processor's drawing, and bringing the picture back.
    private(set) var lastLines: Double = 0
    private(set) var lastDrawing: Double = 0
    private(set) var lastCopy: Double = 0
    private(set) var lastRuns = 0

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Piece { packed_float2 a; packed_float2 b; float ra; float rb; };
    struct Page { float2 origin; float2 size; float scale; float pad; };
    struct Reached {
        float4 position [[position]];
        float2 at;
        float2 a [[flat]];
        float2 b [[flat]];
        float ra [[flat]];
        float rb [[flat]];
    };

    vertex Reached piece_vertex(uint corner [[vertex_id]], uint which [[instance_id]],
                                const device Piece *pieces [[buffer(0)]], constant Page &page [[buffer(1)]]) {
        Piece piece = pieces[which];
        float2 a = piece.a;
        float2 b = piece.b;
        float2 run = b - a;
        float length_ = length(run);
        float2 along = length_ > 1e-6 ? run / length_ : float2(1.0, 0.0);
        float2 across = float2(-along.y, along.x);
        float reach = max(piece.ra, piece.rb) + 1.5 / page.scale;
        float far = (corner & 1) != 0 ? length_ + reach : -reach;
        float side = (corner & 2) != 0 ? reach : -reach;
        float2 at = a + along * far + across * side;
        Reached out;
        out.at = at;
        out.a = a;
        out.b = b;
        out.ra = piece.ra;
        out.rb = piece.rb;
        float2 share = (at - page.origin) / page.size;
        out.position = float4(share.x * 2.0 - 1.0, 1.0 - share.y * 2.0, 0.0, 1.0);
        return out;
    }

    // How far a place is from the shape two discs and what lies between them make (inside: less than nothing).
    static float away(float2 p, float2 a, float2 b, float ra, float rb) {
        float2 pa = p - a;
        float2 ba = b - a;
        float h = dot(ba, ba);
        if (h < 1e-10) { return length(pa) - max(ra, rb); }
        float l = sqrt(h);
        float2 q = float2(fabs(dot(pa, float2(ba.y, -ba.x)) / l), dot(pa, ba) / l);
        float slope = (ra - rb) / l;
        if (fabs(slope) >= 1.0) { return min(length(pa) - ra, length(p - b) - rb); }
        float level = sqrt(1.0 - slope * slope);
        float k = dot(q, float2(-slope, level));
        if (k < 0.0) { return length(q) - ra; }
        if (k > level * l) { return length(q - float2(0.0, l)) - rb; }
        return dot(q, float2(level, slope)) - ra;
    }

    fragment float4 piece_fragment(Reached in [[stage_in]], constant Page &page [[buffer(1)]]) {
        float d = away(in.at, in.a, in.b, in.ra, in.rb);
        // How much of the pixel is covered: all of it half a pixel inside the edge, none half a pixel
        // outside. A line thinner than a pixel covers no pixel whole: what its far edge leaves free is taken off.
        float thin = 2.0 * min(in.ra, in.rb);
        float covered = clamp(0.5 - d * page.scale, 0.0, 1.0) - clamp(0.5 - (d + thin) * page.scale, 0.0, 1.0);
        return float4(covered, covered, covered, covered);
    }

    struct Whole { float4 position [[position]]; };

    vertex Whole whole_vertex(uint corner [[vertex_id]]) {
        Whole out;
        float2 at = float2((corner & 1) != 0 ? 3.0 : -1.0, (corner & 2) != 0 ? 3.0 : -1.0);
        out.position = float4(at, 0.0, 1.0);
        return out;
    }

    struct Tint { float4 colour; };

    fragment float4 whole_fragment(Whole in [[stage_in]], texture2d<float> covered [[texture(0)]], constant Tint &tint [[buffer(0)]]) {
        float share = covered.read(uint2(in.position.xy)).r;
        // (Colour times its own strength already: what is painted is laid over what is there.)
        return tint.colour * share;
    }
    """

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            DebugLog.write("gpu: no graphics processor to be had")
            return nil
        }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let covering = MTLRenderPipelineDescriptor()
            covering.vertexFunction = library.makeFunction(name: "piece_vertex")
            covering.fragmentFunction = library.makeFunction(name: "piece_fragment")
            covering.colorAttachments[0].pixelFormat = .r8Unorm
            covering.colorAttachments[0].isBlendingEnabled = true
            covering.colorAttachments[0].rgbBlendOperation = .max
            covering.colorAttachments[0].alphaBlendOperation = .max
            covering.colorAttachments[0].sourceRGBBlendFactor = .one
            covering.colorAttachments[0].sourceAlphaBlendFactor = .one
            covering.colorAttachments[0].destinationRGBBlendFactor = .one
            covering.colorAttachments[0].destinationAlphaBlendFactor = .one
            cover = try device.makeRenderPipelineState(descriptor: covering)
            let painting = MTLRenderPipelineDescriptor()
            painting.vertexFunction = library.makeFunction(name: "whole_vertex")
            painting.fragmentFunction = library.makeFunction(name: "whole_fragment")
            painting.colorAttachments[0].pixelFormat = .bgra8Unorm
            painting.colorAttachments[0].isBlendingEnabled = true
            painting.colorAttachments[0].rgbBlendOperation = .add
            painting.colorAttachments[0].alphaBlendOperation = .add
            painting.colorAttachments[0].sourceRGBBlendFactor = .one
            painting.colorAttachments[0].sourceAlphaBlendFactor = .one
            painting.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            painting.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            paint = try device.makeRenderPipelineState(descriptor: painting)
        } catch {
            DebugLog.write("gpu: the programs could not be made: \(error)")
            return nil
        }
        DebugLog.write("gpu: \(device.name)")
    }

    /// Lines of one colour that are painted together: every stretch of them as six numbers (where it
    /// begins and ends, and half its width at either end), and which parts of the picture they reach.
    private struct Run {
        var colour: SIMD4<Float>
        var numbers: [Float] = []
        /// The picture as thirty-two squares by thirty-two: a bit for each square a line of the run reaches.
        var cells = [UInt64](repeating: 0, count: 16)
    }

    /// The lines to draw into one picture, as runs to be painted one after the other.
    ///
    /// A line goes into the last run of its colour unless a run after that one has ink where the line
    /// is: lines that do not meet can be painted in any order. A page written in black with words in red
    /// here and there is then two runs, and not a run for every time the colour changes. (The first
    /// comparison on the build server had a page of two thousand lines, every seventh red: five hundred
    /// and seventy runs, each two passes of the graphics processor.)
    private struct Batch {
        let rect: CGRect
        var runs: [Run] = []
        var pieces = 0

        init(rect: CGRect) {
            self.rect = rect
        }

        private func cells(of box: CGRect) -> [UInt64] {
            var cells = [UInt64](repeating: 0, count: 16)
            guard rect.width > 0, rect.height > 0 else { return cells }
            func square(_ share: CGFloat) -> Int { min(31, max(0, Int((share * 32).rounded(.down)))) }
            let left = square((box.minX - rect.minX) / rect.width), right = square((box.maxX - rect.minX) / rect.width)
            let top = square((box.minY - rect.minY) / rect.height), bottom = square((box.maxY - rect.minY) / rect.height)
            var row = top
            while row <= bottom {
                var column = left
                while column <= right {
                    let bit = row * 32 + column
                    cells[bit / 64] |= UInt64(1) << UInt64(bit % 64)
                    column += 1
                }
                row += 1
            }
            return cells
        }

        mutating func add(_ line: InkPaint.Line, colour: SIMD4<Float>, wide: Bool, box: CGRect) {
            var points = line.points
            var widths = line.widths
            // (A highlighter's line needs only some of its points, as in InkPaint.)
            if wide, line.even, points.count > 2, let width = widths.first {
                points = InkPaint.thinned(points, gap: width * InkPaint.wideGap)
                widths = [CGFloat](repeating: width, count: points.count)
            }
            let count = points.count
            guard count > 0, widths.count == count else { return }
            var made: [Float] = []
            made.reserveCapacity(count * 6)
            func piece(_ a: CGPoint, _ b: CGPoint, _ ra: CGFloat, _ rb: CGFloat) {
                made.append(Float(a.x))
                made.append(Float(a.y))
                made.append(Float(b.x))
                made.append(Float(b.y))
                made.append(Float(ra))
                made.append(Float(rb))
            }
            var index = 0
            while index < count {
                let width = widths[index]
                if width > 0 {
                    let joinsAfter = index + 1 < count && widths[index + 1] > 0
                    if joinsAfter {
                        piece(points[index], points[index + 1], width / 2, widths[index + 1] / 2)
                    } else if index == 0 || widths[index - 1] <= 0 {
                        // (A place with nothing inked on either side of it: a dot.)
                        piece(points[index], points[index], width / 2, width / 2)
                    }
                }
                index += 1
            }
            guard !made.isEmpty else { return }
            let mine = cells(of: box)
            var target = -1
            var at = runs.count - 1
            while at >= 0 {
                if runs[at].colour == colour {
                    target = at
                    break
                }
                var meets = false
                var word = 0
                while word < 16 {
                    if runs[at].cells[word] & mine[word] != 0 {
                        meets = true
                        break
                    }
                    word += 1
                }
                if meets { break }
                at -= 1
            }
            if target < 0 {
                runs.append(Run(colour: colour))
                target = runs.count - 1
            }
            runs[target].numbers.append(contentsOf: made)
            var word = 0
            while word < 16 {
                runs[target].cells[word] |= mine[word]
                word += 1
            }
            pieces += made.count / 6
        }
    }

    private static func colour(_ colour: CGColor) -> SIMD4<Float> {
        var parts: [CGFloat] = [0, 0, 0, 1]
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let same = colour.converted(to: space, intent: .defaultIntent, options: nil), let found = same.components, found.count >= 4 {
            parts = found
        }
        let alpha = Float(parts[3])
        // (Each part in 255ths, as a picture keeps them: runs are told apart by what will be seen.)
        func part(_ value: CGFloat) -> Float { (Float(value) * alpha * 255).rounded() / 255 }
        return SIMD4<Float>(part(parts[0]), part(parts[1]), part(parts[2]), (alpha * 255).rounded() / 255)
    }

    private func line(of stroke: PKStroke, step: CGFloat) -> InkPaint.Line {
        let path = stroke.path
        let date = path.creationDate
        let count = path.count
        let first = count > 0 ? path[0].location : .zero
        if let have = kept[date], have.count == count, have.turn == stroke.transform, have.first == first {
            // The same line does for the same zoom, and a line that is the stroke's own points does for
            // any zoom further out than the one it was worked out for.
            let own = have.line.points.count == count
            if abs(have.step - step) < 0.01 * step || (own && step > have.step) { return have.line }
        }
        let line = InkPaint.line(of: stroke, step: step)
        if kept.count > 30000 { kept = [:] }
        kept[date] = Kept(count: count, turn: stroke.transform, first: first, step: step, line: line)
        return line
    }

    /// Lets go of the lines kept (the app is short of memory, or a test wants to start from nothing).
    func forget() {
        kept = [:]
    }

    /// The pictures of [drawing] for the part [rect] of its page at [scale] pixels a point: what
    /// InkPaint.pictures makes. Nil when it is not for the graphics processor to draw (a stroke of
    /// PencilKit's in view, too many colours taking turns, a picture too large), when it is no longer
    /// wanted, or when something went wrong; the caller then has InkPaint draw it.
    func pictures(of drawing: PKDrawing, rect: CGRect, scale: CGFloat, dark: Bool, still: (() -> Bool)? = nil) -> InkPaint.Made? {
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let began = CACurrentMediaTime()
        let strokes = drawing.strokes
        var pens = Batch(rect: rect)
        var high = Batch(rect: rect)
        var anyHigh = false
        let step = max(0.02, 1.2 / scale)
        let highStep = max(0.6, 1.2 / scale)
        for stroke in strokes {
            let isHigh = InkPaint.isHighlighter(stroke)
            if isHigh { anyHigh = true }
            let box = stroke.renderBounds
            guard box.intersects(rect) else { continue }
            guard InkPaint.isPlain(stroke) else { return nil }
            let colour = Self.colour(InkPaint.color(of: stroke, dark: dark, solid: isHigh))
            if isHigh {
                high.add(line(of: stroke, step: highStep), colour: colour, wide: true, box: box)
            } else {
                pens.add(line(of: stroke, step: step), colour: colour, wide: false, box: box)
            }
            if pens.runs.count > 96 || high.runs.count > 96 { return nil }
        }
        if let still, !still() { return nil }
        lastLines = (CACurrentMediaTime() - began) * 1000
        lastDrawing = 0
        lastCopy = 0
        lastRuns = pens.runs.count
        guard let pensPicture = draw(pens, rect: rect, scale: scale, width: width, height: height) else { return nil }
        var made = InkPaint.Made(pens: pensPicture, strokes: strokes.count)
        made.byGPU = true
        if anyHigh {
            guard let highPicture = draw(high, rect: rect, scale: scale, width: width, height: height) else { return nil }
            made.high = highPicture
            made.highRect = rect
        }
        if let still, !still() { return nil }
        return made
    }

    private func draw(_ batch: Batch, rect: CGRect, scale: CGFloat, width: Int, height: Int) -> CGImage? {
        let began = CACurrentMediaTime()
        let wanted = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        wanted.usage = [.renderTarget]
        wanted.storageMode = .shared
        let share = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        share.usage = [.renderTarget, .shaderRead]
        share.storageMode = .private
        guard let picture = device.makeTexture(descriptor: wanted), let covered = device.makeTexture(descriptor: share),
              let commands = queue.makeCommandBuffer() else { return nil }
        // (The picture is so many whole pixels, and the part asked for seldom is: a point of the page is
        // aimed at the pixel InkPaint puts it on. The first comparison on the build server, at 4.54
        // pixels a point, had the two pictures a third of a pixel apart at the far side of the page.)
        var page: [Float] = [Float(rect.minX), Float(rect.minY), Float(CGFloat(width) / scale), Float(CGFloat(height) / scale), Float(scale), 0, 0, 0]
        guard let pageBuffer = device.makeBuffer(bytes: &page, length: page.count * MemoryLayout<Float>.stride, options: .storageModeShared) else { return nil }
        var pieces: MTLBuffer?
        var tints: MTLBuffer?
        var numbers: [Float] = []
        numbers.reserveCapacity(batch.pieces * 6)
        var firsts: [Int] = []
        for run in batch.runs {
            firsts.append(numbers.count / 6)
            numbers.append(contentsOf: run.numbers)
        }
        if !numbers.isEmpty {
            pieces = numbers.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            var colours: [Float] = []
            for run in batch.runs {
                colours.append(run.colour.x)
                colours.append(run.colour.y)
                colours.append(run.colour.z)
                colours.append(run.colour.w)
            }
            tints = colours.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            guard pieces != nil, tints != nil else { return nil }
        }
        if batch.runs.isEmpty {
            // Nothing in view: a clear picture.
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = picture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            encoder.endEncoding()
        }
        var number = 0
        for run in batch.runs {
            guard let pieces, let tints else { return nil }
            // How much of each pixel the lines of this run cover.
            let first = MTLRenderPassDescriptor()
            first.colorAttachments[0].texture = covered
            first.colorAttachments[0].loadAction = .clear
            first.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            first.colorAttachments[0].storeAction = .store
            guard let covering = commands.makeRenderCommandEncoder(descriptor: first) else { return nil }
            covering.setRenderPipelineState(cover)
            covering.setVertexBuffer(pieces, offset: firsts[number] * 6 * MemoryLayout<Float>.stride, index: 0)
            covering.setVertexBuffer(pageBuffer, offset: 0, index: 1)
            covering.setFragmentBuffer(pageBuffer, offset: 0, index: 1)
            covering.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: run.numbers.count / 6)
            covering.endEncoding()
            // That, in the run's colour, over what is in the picture already.
            let second = MTLRenderPassDescriptor()
            second.colorAttachments[0].texture = picture
            second.colorAttachments[0].loadAction = number == 0 ? .clear : .load
            second.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            second.colorAttachments[0].storeAction = .store
            guard let painting = commands.makeRenderCommandEncoder(descriptor: second) else { return nil }
            painting.setRenderPipelineState(paint)
            painting.setFragmentTexture(covered, index: 0)
            painting.setFragmentBuffer(tints, offset: number * 4 * MemoryLayout<Float>.stride, index: 0)
            painting.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            painting.endEncoding()
            number += 1
        }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            DebugLog.write("gpu: the drawing did not come through (\(commands.error.map { String(describing: $0) } ?? "no word why"))")
            return nil
        }
        let drawn = CACurrentMediaTime()
        lastDrawing += (drawn - began) * 1000
        // The picture's pixels, as Core Graphics keeps them: blue first, colour times strength.
        let row = width * 4
        guard let data = NSMutableData(length: row * height) else { return nil }
        picture.getBytes(data.mutableBytes, bytesPerRow: row, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
        lastCopy += (CACurrentMediaTime() - drawn) * 1000
        return image
    }
}

// MARK: on the build server

/// "-gpuCheck": pages of handwriting made up here are drawn both ways, by InkPaint and by the graphics
/// processor, at several zooms. What comes out is set side by side: how long each took, and how far
/// apart the two pictures are, pixel by pixel. The pictures themselves are kept in Documents/gpu-out.
enum InkGPUCheck {
    /// A page of lines as the app's pen writes them: [count] wavy lines of changing width in two colours,
    /// some highlighter under them, and a dashed line.
    private static func page(lines count: Int, seed: UInt64) -> PKDrawing {
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 100000) / 100000
        }
        var strokes: [PKStroke] = []
        for number in 0..<count {
            // (A fountain pen's line: it presses harder in the middle.)
            var line = PenLine(width: 0.9 + next() * 1.2, sense: 0.5, steady: 0, spacing: 0.11, taper: 0.3)
            let x = 40 + next() * 500
            let y = 40 + next() * 740
            let long = 12 + next() * 60
            let high = 4 + next() * 14
            let turns = 1 + next() * 3
            let steps = 40
            for step in 0...steps {
                let share = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: x + long * share, y: y + sin(share * turns * 2 * .pi) * high + share * (next() - 0.5) * 2)
                let force = 0.25 + 0.6 * sin(share * .pi)
                line.add(PenSample(point: point, force: force, time: Double(step) * 0.004))
            }
            line.finish()
            let colour: UIColor = number % 7 == 3 ? UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1) : .black
            if let stroke = line.stroke(color: colour) { strokes.append(stroke) }
        }
        // Highlighter: wide lines of one width, in a colour that is seen through.
        for row in 0..<4 {
            var line = PenLine(width: 14, sense: 0, steady: 0, spacing: 0.2)
            for step in 0...60 {
                line.add(PenSample(point: CGPoint(x: 60 + CGFloat(step) * 7, y: 120 + CGFloat(row) * 180 + sin(CGFloat(step) / 6) * 3), force: 0, time: Double(step) * 0.004))
            }
            line.finish()
            let colour = row % 2 == 0 ? UIColor(red: 1, green: 0.9, blue: 0.1, alpha: 0.4) : UIColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 0.4)
            if let stroke = line.stroke(color: colour) { strokes.append(stroke) }
        }
        return PKDrawing(strokes: strokes)
    }

    private static func bytes(of image: CGImage) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// How far apart two pictures are: of the pixels that have ink in either, how many differ by more
    /// than a little in how strongly they are inked, the mean difference and the largest (in 255ths).
    private static func apart(_ one: CGImage, _ other: CGImage) -> String {
        guard one.width == other.width, one.height == other.height, let a = bytes(of: one), let b = bytes(of: other) else {
            return "not the same size (\(one.width) x \(one.height) and \(other.width) x \(other.height))"
        }
        var inked = 0
        var sum = 0
        var most = 0
        var over16 = 0
        var over48 = 0
        var colourMost = 0
        var index = 0
        let count = a.count
        while index < count {
            let alphaA = Int(a[index + 3]), alphaB = Int(b[index + 3])
            if alphaA > 0 || alphaB > 0 {
                inked += 1
                let gap = abs(alphaA - alphaB)
                sum += gap
                if gap > most { most = gap }
                if gap > 16 { over16 += 1 }
                if gap > 48 { over48 += 1 }
                let colour = max(abs(Int(a[index]) - Int(b[index])), abs(Int(a[index + 1]) - Int(b[index + 1])), abs(Int(a[index + 2]) - Int(b[index + 2])))
                if colour > colourMost { colourMost = colour }
            }
            index += 4
        }
        guard inked > 0 else { return "nothing inked in either" }
        let mean = Double(sum) / Double(inked)
        return String(format: "%d inked pixels, strength apart %.2f on average, %d at most; %d pixels (%.2f%%) apart by more than 16, %d by more than 48; colour apart %d at most", inked, mean, most, over16, Double(over16) * 100 / Double(inked), over48, colourMost)
    }

    private static func keep(_ image: CGImage, _ name: String, in folder: URL) {
        guard let data = UIImage(cgImage: image).pngData() else { return }
        try? data.write(to: folder.appendingPathComponent(name))
    }

    /// The middle of a picture, cut out: what is kept of the large ones.
    private static func middle(_ image: CGImage, side: Int) -> CGImage {
        let width = min(side, image.width), height = min(side, image.height)
        return image.cropping(to: CGRect(x: (image.width - width) / 2, y: (image.height - height) / 2, width: width, height: height)) ?? image
    }

    static func run() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("gpu-out", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let gpu = InkGPU.shared else {
                DebugLog.write("gpu check: no graphics processor here; nothing compared")
                DebugLog.write("gpu check: done")
                return
            }
            let whole = CGRect(x: 0, y: 0, width: 595, height: 842)
            for (name, lines) in [("page300", 300), ("page2000", 2000)] {
                let drawing = page(lines: lines, seed: UInt64(lines))
                var points = 0
                for stroke in drawing.strokes { points += stroke.path.count }
                DebugLog.write("gpu check: \(name): \(drawing.strokes.count) strokes, \(points) points")
                for scale in [CGFloat(2), CGFloat(4.54), CGFloat(10)] {
                    // (At the largest zoom the part in view, as the app asks for it: a picture has a size it does not go over.)
                    let rect = scale > 6 ? CGRect(x: 150, y: 250, width: 300, height: 240) : whole
                    var began = CACurrentMediaTime()
                    let byHand = InkPaint.pictures(of: drawing, rect: rect, scale: scale, dark: false, over: nil, redoing: nil)
                    let slow = (CACurrentMediaTime() - began) * 1000
                    gpu.forget()
                    began = CACurrentMediaTime()
                    let cold = gpu.pictures(of: drawing, rect: rect, scale: scale, dark: false)
                    let first = (CACurrentMediaTime() - began) * 1000
                    let firstParts = String(format: "lines %.1f, drawing %.1f, copy %.1f", gpu.lastLines, gpu.lastDrawing, gpu.lastCopy)
                    began = CACurrentMediaTime()
                    let warm = gpu.pictures(of: drawing, rect: rect, scale: scale, dark: false)
                    let second = (CACurrentMediaTime() - began) * 1000
                    let secondParts = String(format: "lines %.1f, drawing %.1f, copy %.1f", gpu.lastLines, gpu.lastDrawing, gpu.lastCopy)
                    guard let byHand, let cold, warm != nil else {
                        DebugLog.write("gpu check: \(name) at \(scale): a picture did not come (InkPaint \(byHand != nil), GPU \(cold != nil))")
                        continue
                    }
                    DebugLog.write("gpu check: " + name + " at " + String(describing: scale) + ": runs of one colour, pens " + String(gpu.lastRuns))
                    DebugLog.write(String(format: "gpu check: %@ at %.2f, %d x %d: InkPaint %.1f ms; GPU %.1f ms the first time (%@), %.1f ms again (%@)", name, Double(scale), cold.pens.width, cold.pens.height, slow, first, firstParts, second, secondParts))
                    DebugLog.write("gpu check: \(name) at \(scale): pens: " + apart(byHand.pens, cold.pens))
                    if let a = byHand.high, let b = cold.high {
                        DebugLog.write("gpu check: \(name) at \(scale): highlighter: " + apart(a, b))
                    } else {
                        DebugLog.write("gpu check: \(name) at \(scale): highlighter: InkPaint \(byHand.high != nil), GPU \(cold.high != nil)")
                    }
                    if lines == 300 {
                        let tag = String(format: "%@-%.0f", name, Double(scale * 100))
                        keep(middle(byHand.pens, side: 700), "\(tag)-cpu.png", in: folder)
                        keep(middle(cold.pens, side: 700), "\(tag)-gpu.png", in: folder)
                        if let a = byHand.high, let b = cold.high {
                            keep(middle(a, side: 700), "\(tag)-high-cpu.png", in: folder)
                            keep(middle(b, side: 700), "\(tag)-high-gpu.png", in: folder)
                        }
                    }
                }
            }
            DebugLog.write("gpu check: done")
        }
    }
}
