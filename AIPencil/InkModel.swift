import PencilKit
import SwiftUI

/// The tools of the tool bar.
enum InkTool: String, CaseIterable, Identifiable, Codable {
    case pen, highlighter, eraser, ai, shape, lasso, formula

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .ai: return "AI 펜"
        case .shape: return "도형"
        case .lasso: return "올가미"
        case .formula: return "수식 옮기기"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .ai: return "pencil.tip.crop.circle"
        case .shape: return "square.on.circle"
        case .lasso: return "lasso"
        case .formula: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// The kinds of pen. They differ in how the line answers to the hand.
enum PenKind: String, CaseIterable, Identifiable, Codable {
    case fountain, pen, ball, pencil

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fountain: return "만년필"
        case .pen: return "펜"
        case .ball: return "볼펜"
        case .pencil: return "연필"
        }
    }

    var hint: String {
        switch self {
        case .fountain: return "누르는 힘에 따라 쓰는 동안 굵기가 달라져요"
        case .pen: return "힘을 주면 조금 굵어져요"
        case .ball: return "힘을 주어도 굵기가 늘 같아요"
        case .pencil: return "누르면 진해지고, 기울이면 넓게 칠해져요"
        }
    }

    var ink: PKInkingTool.InkType {
        switch self {
        case .fountain: return .fountainPen
        case .pen: return .pen
        case .ball: return .monoline
        case .pencil: return .pencil
        }
    }
}

/// What the eraser takes away.
enum EraserKind: String, CaseIterable, Identifiable, Codable {
    case stroke, part

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke: return "획"
        case .part: return "부분"
        }
    }
}

/// What the shape tool draws.
enum ShapeKind: String, CaseIterable, Identifiable, Codable {
    case line, arrow, rect, ellipse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: return "직선"
        case .arrow: return "화살표"
        case .rect: return "네모"
        case .ellipse: return "동그라미"
        }
    }

    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        }
    }
}

/// What is in the user's hand: a tool, and how each tool is set up. Colours are kept as 0xRRGGBB.
struct InkChoice: Equatable, Codable {
    var tool: InkTool = .pen
    var penKind = PenKind.fountain
    var penColor: UInt32 = 0x1C1C1F
    /// The pen's widths in millimetres on the paper, as pens are sold by (0.5, 0.8): three kept on the
    /// tool bar to switch between, and which of the three is in use. The slider in the pen's settings
    /// changes the one in use.
    var penSizes: [Double] = [0.3, 0.5, 0.8]
    var penSlot = 1
    /// For the app's own pen. How much pressure changes the line's width, from 0 (not at all) to 1; and
    /// how far a shaky line is steadied, from 0 (the line goes exactly where the pen goes) to 1.
    var penSense = 0.5
    var penSteady = 0.25
    var highlighterColor: UInt32 = 0xFFD60A
    /// The highlighter's width in millimetres on the paper.
    var highlighterSize = 5.0
    var eraserKind = EraserKind.stroke
    /// How wide the eraser is, in points of the screen, whichever kind it is.
    var eraserWidth = 16.0
    /// The eraser leaves everything but highlighter alone.
    var eraserHighlighterOnly = false
    /// The eraser takes the marks of the AI pen off the page too. Their explanations are kept.
    var eraserTakesMarks = true
    var shapeKind = ShapeKind.line
    /// The tools that are put down by themselves once they have been used, for the one held before.
    var eraserAuto = false
    var highlighterAuto = false
    var shapeAuto = false

    init() {}

    /// Settings saved by an earlier version lack the newer ones; those keep their defaults.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? saved.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        tool = read(.tool, tool)
        penKind = read(.penKind, penKind)
        penColor = read(.penColor, penColor)
        penSizes = read(.penSizes, penSizes)
        penSlot = read(.penSlot, penSlot)
        penSense = read(.penSense, penSense)
        penSteady = read(.penSteady, penSteady)
        highlighterColor = read(.highlighterColor, highlighterColor)
        highlighterSize = read(.highlighterSize, highlighterSize)
        eraserKind = read(.eraserKind, eraserKind)
        eraserWidth = read(.eraserWidth, eraserWidth)
        eraserHighlighterOnly = read(.eraserHighlighterOnly, eraserHighlighterOnly)
        eraserTakesMarks = read(.eraserTakesMarks, eraserTakesMarks)
        shapeKind = read(.shapeKind, shapeKind)
        eraserAuto = read(.eraserAuto, eraserAuto)
        highlighterAuto = read(.highlighterAuto, highlighterAuto)
        shapeAuto = read(.shapeAuto, shapeAuto)
        // Settings saved before 0.8.0 had one pen width, on a scale of PencilKit's own, and a highlighter
        // width in points. The pen in use keeps the width it had; the highlighter too.
        let old = try? decoder.container(keyedBy: OldKeys.self)
        if !saved.contains(.penSizes), let width = try? old?.decodeIfPresent(Double.self, forKey: .penWidth) {
            let size = Double(InkWidth.seen(setting: CGFloat(width)) / Self.pointsPerMillimetre)
            penSizes[1] = Self.tidy(size, in: Self.penSizeRange)
        }
        if !saved.contains(.highlighterSize), let width = try? old?.decodeIfPresent(Double.self, forKey: .highlighterWidth) {
            highlighterSize = Self.tidy(width / Double(Self.pointsPerMillimetre), in: Self.highlighterSizes)
        }
        if penSizes.count != 3 { penSizes = [0.3, 0.5, 0.8] }
        penSizes = penSizes.map { Self.tidy($0, in: Self.penSizeRange) }
        penSlot = min(max(penSlot, 0), 2)
    }

    private enum OldKeys: String, CodingKey {
        case penWidth, highlighterWidth
    }

    /// A page point is 1/72 of an inch.
    static let pointsPerMillimetre: CGFloat = 72 / 25.4

    /// A size kept within its range and to a twentieth of a millimetre.
    static func tidy(_ size: Double, in range: ClosedRange<Double>) -> Double {
        min(max((size * 20).rounded() / 20, range.lowerBound), range.upperBound)
    }

    /// A size in millimetres as it is written: "0.5", and "0.35" where a tenth does not say it.
    static func sizeLabel(_ size: Double) -> String {
        abs(size * 10 - (size * 10).rounded()) < 0.001 ? String(format: "%.1f", size) : String(format: "%.2f", size)
    }

    /// The width in use, in millimetres.
    var penSize: Double {
        get { penSizes.indices.contains(penSlot) ? penSizes[penSlot] : 0.5 }
        set { if penSizes.indices.contains(penSlot) { penSizes[penSlot] = newValue } }
    }

    /// The pen's and the highlighter's line as wide as they are seen on the page, in page points.
    var penSeenWidth: CGFloat { CGFloat(penSize) * Self.pointsPerMillimetre }
    var highlighterSeenWidth: CGFloat { CGFloat(highlighterSize) * Self.pointsPerMillimetre }

    /// The colours offered for the pen: the first five are on the tool bar itself.
    static let penPalette: [UInt32] = [
        0x1C1C1F, 0x1F70EB, 0xE5484D, 0x21A05F, 0xF08C00,
        0x7C4DFF, 0x0B3D91, 0xD6336C, 0x0CA6A6, 0x8D5524,
        0x5C6370, 0x9AA0AA, 0xB8860B, 0x2B8A3E, 0xC2255C,
        0x364FC7, 0x862E9C, 0xFFFFFF,
    ]
    static let highlighterPalette: [UInt32] = [
        0xFFD60A, 0x5EDC8A, 0xFF8FB8, 0x64B5FF, 0xFFA94D,
        0xB69CFF, 0x7FE3D4, 0xD0D4DA,
    ]
    static let penSizeRange: ClosedRange<Double> = 0.1...2.0
    static let highlighterSizes: ClosedRange<Double> = 2...12
    static let eraserWidths: ClosedRange<Double> = 6...60
    /// The eraser sizes kept on the tool bar.
    static let eraserQuick: [Double] = [8, 16, 32]
    /// The colour of the AI pen and of the marks it leaves on the page.
    static let markColor = UIColor(red: 0x0F / 255.0, green: 0xA3 / 255.0, blue: 0x9B / 255.0, alpha: 1)
    /// How strong a highlighter line is where it is laid over the page. (It is laid as a tint that darkens
    /// the paper and leaves what is printed on it as dark as it was, so writing under it stays readable.)
    static let highlighterStrength: CGFloat = 0.5

    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha
        )
    }

    static func rgb(_ color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func part(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return part(r) << 16 | part(g) << 8 | part(b)
    }

    var penUIColor: UIColor { Self.color(penColor) }
    var highlighterUIColor: UIColor { Self.color(highlighterColor) }

    /// The pencil's width as PencilKit takes it: about three of its units to the millimetre, within
    /// what its pencil allows.
    var pencilWidth: CGFloat {
        let allowed = PKInkingTool.InkType.pencil.validWidthRange
        return min(max(CGFloat(penSize) * 6, allowed.lowerBound), allowed.upperBound)
    }

    /// Whether the tool in hand writes through the app itself: the pen (all but the pencil, whose grain
    /// is PencilKit's to draw), the highlighter and the AI pen. The app takes their touches, works out the
    /// line and draws it.
    var ownPen: Bool {
        (tool == .pen && penKind != .pencil) || tool == .highlighter || tool == .ai
    }

    /// Whether the eraser in hand is the app's own: the one that takes whole lines, of any size, and the
    /// one that only takes highlighter. Rubbing out part of a line is PencilKit's.
    var ownEraser: Bool {
        tool == .eraser && (eraserHighlighterOnly || eraserKind == .stroke)
    }

    /// Whether the tool in hand works on PencilKit's canvas itself, which then has to be what shows.
    var needsCanvas: Bool {
        tool == .lasso || (tool == .eraser && !ownEraser) || (tool == .pen && penKind == .pencil)
    }

    /// How much the app's own pen answers to pressure, by the kind of pen: the fountain pen as much as
    /// is set, the plain pen a little, the ballpoint not at all.
    var appPenSense: CGFloat {
        switch penKind {
        case .fountain: return CGFloat(penSense)
        case .pen: return CGFloat(penSense) * 0.4
        case .ball, .pencil: return 0
        }
    }

    /// Whether the tool in hand is put down by itself once it has been used.
    var putsDownAfterUse: Bool {
        switch tool {
        case .eraser: return eraserAuto
        case .highlighter: return highlighterAuto
        case .shape: return shapeAuto
        default: return false
        }
    }

    /// The eraser that only takes highlighter is the app's own: PencilKit's rubs out whatever it meets.
    var rubsHighlighterOnly: Bool {
        tool == .eraser && eraserHighlighterOnly
    }

    /// The PencilKit tool this choice stands for. The formula and shape tools do not write through
    /// PencilKit; while one is chosen the canvases are switched off and keep whatever they had.
    var pencilKitTool: PKTool {
        switch tool {
        case .eraser:
            return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: CGFloat(eraserWidth))
        case .lasso:
            return PKLassoTool()
        case .ai:
            return PKInkingTool(.monoline, color: Self.markColor, width: 2.6)
        case .pen, .formula, .shape, .highlighter:
            // (Of these only the pencil writes on the canvas; the rest are the app's own.)
            return PKInkingTool(.pencil, color: penUIColor, width: pencilWidth)
        }
    }

    /// The choice as it was left last time, tool settings and all.
    static func saved() -> InkChoice {
        guard let data = UserDefaults.standard.data(forKey: "inkChoice2"),
              var choice = try? JSONDecoder().decode(InkChoice.self, from: data)
        else { return InkChoice() }
        // A document opens with something to write with in hand.
        if choice.tool != .pen && choice.tool != .highlighter { choice.tool = .pen }
        return choice
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "inkChoice2")
        }
    }

    private static var waiting: DispatchWorkItem?

    /// Saves the choice a moment from now, once it has stopped changing: a slider being dragged changes
    /// it many times a second, and every save is a write to the settings store that the screens watch.
    func saveSoon() {
        Self.waiting?.cancel()
        let choice = self
        let work = DispatchWorkItem {
            Self.waiting = nil
            choice.save()
        }
        Self.waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Saves now whatever is waiting to be saved.
    static func saveWaiting() {
        guard let work = waiting else { return }
        work.perform()
        work.cancel()
    }
}

/// How the pages are laid out.
enum PageLayoutMode: String, CaseIterable, Identifiable {
    case vertical, paged, twoUp, twoUpPaged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "세로로 이어 보기"
        case .paged: return "가로로 한 쪽씩 넘기기"
        case .twoUp: return "두 쪽씩 세로로 이어 보기"
        case .twoUpPaged: return "두 쪽씩 가로로 넘기기"
        }
    }

    var symbol: String {
        switch self {
        case .vertical: return "arrow.up.and.down"
        case .paged: return "arrow.left.and.right"
        case .twoUp: return "book"
        case .twoUpPaged: return "rectangle.split.2x1"
        }
    }
}

/// What a double tap or a squeeze of the Apple Pencil asks for.
enum PencilAction {
    /// The eraser, or back from it.
    case eraser
    /// The tool that was in hand before this one.
    case previous
    /// The AI pen, or back from it.
    case ai
    /// The settings of the tool in hand.
    case options
}
