import CoreGraphics

/// Snapping a dragged title box to the frame's guides (titles slice 2): its centre lines and the edges of the
/// title-safe and action-safe rectangles (`SafeAreas.lines`, whether or not the guides are shown). Holding Command
/// while dragging does not snap: Final Cut's and Premiere's convention for their guides (Ken Burns boxes do not snap).
///
/// Each axis snaps on its own: of the box's left edge, centre and right edge (top, centre and bottom), the one nearest
/// a vertical (horizontal) line within the threshold moves onto it. A turned box snaps its axis-aligned bounds on the
/// frame. Positions are sequence pixels on the frame.
enum TitleSnapping {
    struct Snap: Equatable {
        /// How far the box moves to lie on the lines it snapped to.
        var offset: CGSize
        /// The lines it snapped to (at most one vertical and one horizontal), drawn while the drag lasts.
        var lines: [SafeAreas.Line]
    }

    /// Where a box whose bounds are `bounds` snaps to among `lines`, within `threshold` (sequence pixels).
    static func snap(bounds: CGRect, to lines: [SafeAreas.Line], threshold: CGFloat) -> Snap {
        var snap = Snap(offset: .zero, lines: [])
        if let x = nearest([bounds.minX, bounds.midX, bounds.maxX], lines.filter(\.vertical), threshold: threshold) {
            snap.offset.width = x.offset
            snap.lines.append(x.line)
        }
        if let y = nearest([bounds.minY, bounds.midY, bounds.maxY], lines.filter { !$0.vertical }, threshold: threshold) {
            snap.offset.height = y.offset
            snap.lines.append(y.line)
        }
        return snap
    }

    /// Where a vertical edge at `x` snaps to among the vertical `lines` within `threshold` (a box's width dragged by
    /// its edge): the snapped x and the line, or nil when no line is near.
    static func snapEdge(x: CGFloat, to lines: [SafeAreas.Line], threshold: CGFloat) -> (x: CGFloat, line: SafeAreas.Line)? {
        nearest([x], lines.filter(\.vertical), threshold: threshold).map { (x + $0.offset, $0.line) }
    }

    /// The (feature, line) pair nearest within `threshold`: how far the feature moves and the line (the first of equal
    /// ones: the lines' order, centre lines first).
    private static func nearest(_ features: [CGFloat], _ lines: [SafeAreas.Line],
                                threshold: CGFloat) -> (offset: CGFloat, line: SafeAreas.Line)? {
        var best: (offset: CGFloat, line: SafeAreas.Line)?
        for line in lines {
            for feature in features {
                let offset = line.position - feature
                guard abs(offset) <= threshold, abs(offset) < abs(best?.offset ?? .infinity) else { continue }
                best = (offset, line)
            }
        }
        return best
    }
}
