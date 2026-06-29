import AppKit

enum AnnotationTool: Equatable {
    case pen
    case line
    case rectangle
    case ellipse
    case arrow
    case text
    case highlighter
}

enum AnnotationColor: String, CaseIterable, Equatable {
    case red
    case green
    case blue
    case yellow
    case orange
    case pink
    case white
    case black

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .pink: .systemPink
        case .white: .white
        case .black: .black
        }
    }

    var displayName: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .pink: "Pink"
        case .white: "White"
        case .black: "Black"
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: AnnotationColor
    var rootWidth: CGFloat
    var alpha: CGFloat

    /// Translucency used for highlighting (Shift+color and the highlighter
    /// tool), matching Windows ZoomIt's g_AlphaBlend (0x80 = 50%).
    static let highlightAlpha: CGFloat = 0.5

    static let `default` = AnnotationStyle(color: .red, rootWidth: 5, alpha: 1)
}

struct Annotation: Equatable {
    var tool: AnnotationTool
    var points: [CGPoint]
    var style: AnnotationStyle
    var text: String = ""
    var fontSize: CGFloat = 36
    var fontName: String = ""
    var rightAligned: Bool = false
}