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

enum AnnotationColor: Equatable {
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
}

struct AnnotationStyle: Equatable {
    var color: AnnotationColor
    var rootWidth: CGFloat
    var alpha: CGFloat

    static let `default` = AnnotationStyle(color: .red, rootWidth: 5, alpha: 1)
}

struct Annotation: Equatable {
    var tool: AnnotationTool
    var points: [CGPoint]
    var style: AnnotationStyle
    var text: String = ""
}