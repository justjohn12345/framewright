import CoreGraphics
import Foundation

/// Which title-safe and action-safe percentages the program monitor's guides draw (Settings > Editing): SMPTE ST
/// 2046-1's for HD (action-safe 93 % of the frame, title-safe 90 %; the default) or the classic television pair
/// (90 % and 80 %). Final Cut's and Premiere's guides draw the same kind of rectangles; for web video, where nothing
/// is overscanned, they are composition aids rather than limits.
enum SafeAreaStandard: String, CaseIterable, Identifiable {
    case smpte
    case classic

    var id: String { rawValue }

    /// The action-safe rectangle's side as a fraction of the frame's.
    var actionFraction: CGFloat {
        switch self {
        case .smpte: return 0.93
        case .classic: return 0.90
        }
    }

    /// The title-safe rectangle's side as a fraction of the frame's.
    var titleFraction: CGFloat {
        switch self {
        case .smpte: return 0.90
        case .classic: return 0.80
        }
    }

    var title: String {
        switch self {
        case .smpte: return "SMPTE ST 2046-1 (action 93 %, title 90 %)"
        case .classic: return "Classic (action 90 %, title 80 %)"
        }
    }
}

/// The safe-area guides of a frame, in sequence pixels (origin at the frame's top-left, +y down): the action-safe and
/// title-safe rectangles (centred, each side the standard's fraction of the frame's), the frame's centre lines, and
/// the lines a dragged title box snaps to (`TitleSnapping`).
struct SafeAreas: Equatable {
    let frame: CGSize
    let standard: SafeAreaStandard

    /// A line of the guides: vertical at `position` = x, or horizontal at `position` = y.
    struct Line: Equatable {
        enum Kind: Equatable {
            case centre
            case actionSafe
            case titleSafe
        }
        let kind: Kind
        let vertical: Bool
        let position: CGFloat
    }

    var action: CGRect { Self.centred(frame, fraction: standard.actionFraction) }
    var title: CGRect { Self.centred(frame, fraction: standard.titleFraction) }
    var centre: CGPoint { CGPoint(x: frame.width / 2, y: frame.height / 2) }

    /// The centre lines and the edges of both rectangles: what a title box snaps to.
    var lines: [Line] {
        let action = self.action
        let title = self.title
        return [Line(kind: .centre, vertical: true, position: centre.x),
                Line(kind: .centre, vertical: false, position: centre.y),
                Line(kind: .titleSafe, vertical: true, position: title.minX),
                Line(kind: .titleSafe, vertical: true, position: title.maxX),
                Line(kind: .titleSafe, vertical: false, position: title.minY),
                Line(kind: .titleSafe, vertical: false, position: title.maxY),
                Line(kind: .actionSafe, vertical: true, position: action.minX),
                Line(kind: .actionSafe, vertical: true, position: action.maxX),
                Line(kind: .actionSafe, vertical: false, position: action.minY),
                Line(kind: .actionSafe, vertical: false, position: action.maxY)]
    }

    private static func centred(_ frame: CGSize, fraction: CGFloat) -> CGRect {
        let size = CGSize(width: frame.width * fraction, height: frame.height * fraction)
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width,
                      height: size.height)
    }
}
