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
        case .ai: return "sparkles"
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
    /// The pen's line width in page points.
    var penWidth = 2.6
    /// For the app's own pen. How much pressure changes the line's width, from 0 (not at all) to 1; and
    /// how far a shaky line is steadied, from 0 (the line goes exactly where the pen goes) to 1.
    var penSense = 0.5
    var penSteady = 0.25
    var highlighterColor: UInt32 = 0xFFD60A
    var highlighterWidth = 14.0
    var eraserKind = EraserKind.stroke
    /// How wide the eraser that rubs out part of a line is, in page points.
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
        penWidth = read(.penWidth, penWidth)
        penSense = read(.penSense, penSense)
        penSteady = read(.penSteady, penSteady)
        highlighterColor = read(.highlighterColor, highlighterColor)
        highlighterWidth = read(.highlighterWidth, highlighterWidth)
        eraserKind = read(.eraserKind, eraserKind)
        eraserWidth = read(.eraserWidth, eraserWidth)
        eraserHighlighterOnly = read(.eraserHighlighterOnly, eraserHighlighterOnly)
        eraserTakesMarks = read(.eraserTakesMarks, eraserTakesMarks)
        shapeKind = read(.shapeKind, shapeKind)
        eraserAuto = read(.eraserAuto, eraserAuto)
        highlighterAuto = read(.highlighterAuto, highlighterAuto)
        shapeAuto = read(.shapeAuto, shapeAuto)
    }

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
    static let penWidths: ClosedRange<Double> = 0.6...9
    static let highlighterWidths: ClosedRange<Double> = 6...30
    static let eraserWidths: ClosedRange<Double> = 6...48
    /// The colour of the AI pen and of the marks it leaves on the page.
    static let markColor = UIColor(red: 0x6D / 255.0, green: 0x5B / 255.0, blue: 0xF6 / 255.0, alpha: 1)

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

    /// The pen's width as its ink allows it.
    var penLineWidth: CGFloat {
        let allowed = penKind.ink.validWidthRange
        return min(max(CGFloat(penWidth), allowed.lowerBound), allowed.upperBound)
    }

    /// Whether the pen in hand is the app's own, given that the app's own pen is switched on. The pencil
    /// stays PencilKit's: its grain is PencilKit's to draw.
    func usesAppPen(_ on: Bool) -> Bool {
        on && tool == .pen && penKind != .pencil
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
        case .pen, .formula, .shape:
            return PKInkingTool(penKind.ink, color: penUIColor, width: penLineWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: highlighterUIColor, width: CGFloat(highlighterWidth))
        case .eraser:
            return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: CGFloat(eraserWidth))
        case .ai:
            return PKInkingTool(.monoline, color: Self.markColor, width: 2.6)
        case .lasso:
            return PKLassoTool()
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
}

/// How the pages are laid out.
enum PageLayoutMode: String, CaseIterable, Identifiable {
    case vertical, paged, twoUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "세로로 이어 보기"
        case .paged: return "가로로 한 쪽씩 넘기기"
        case .twoUp: return "두 쪽씩 보기"
        }
    }

    var symbol: String {
        switch self {
        case .vertical: return "arrow.up.and.down"
        case .paged: return "arrow.left.and.right"
        case .twoUp: return "book"
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
