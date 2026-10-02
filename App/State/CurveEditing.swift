import CoreGraphics
import Foundation

/// The curve editor's rules (pure, so they are tested on their own): the points the editor shows, adding,
/// moving and removing a point. Points are in the curve's own coordinates (x the input, y the output, both 0
/// to 1); a curve has 2 to `maximumPoints` points, x strictly increasing; no points is the identity, which
/// the editor shows as its two ends.
enum CurveEditing {
    static let maximumPoints = 16
    /// The least distance between two points' x (so x stays strictly increasing while dragging).
    static let minimumGap: CGFloat = 0.01
    /// How far beyond the editor's square (in points of the view) a dragged point is removed.
    static let dragOutDistance: CGFloat = 24

    /// The points the editor shows and edits: `points`, or the identity's two ends for none.
    static func editable(_ points: [CGPoint]) -> [CGPoint] {
        points.isEmpty ? [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)] : points
    }

    /// `point` added to `points` (the editable points) in x order, limited to [0, 1]; nil when the curve has
    /// its most points or another point is within `minimumGap` in x. Returns the points and the new point's
    /// index.
    static func adding(_ point: CGPoint, to points: [CGPoint]) -> (points: [CGPoint], index: Int)? {
        let base = editable(points)
        guard base.count < maximumPoints else { return nil }
        let limited = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        guard !base.contains(where: { abs($0.x - limited.x) < minimumGap }) else { return nil }
        let index = base.firstIndex { $0.x > limited.x } ?? base.count
        var result = base
        result.insert(limited, at: index)
        return (result, index)
    }

    /// Point `index` of `points` (the editable points) moved to `point`: limited to [0, 1], and in x to at
    /// least `minimumGap` from its neighbours (so the order is kept).
    static func moving(_ index: Int, to point: CGPoint, in points: [CGPoint]) -> [CGPoint] {
        var result = editable(points)
        guard result.indices.contains(index) else { return result }
        let lower = index > 0 ? result[index - 1].x + minimumGap : 0
        let upper = index + 1 < result.count ? result[index + 1].x - minimumGap : 1
        let x = lower <= upper ? min(upper, max(lower, point.x)) : result[index].x
        result[index] = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, point.y)))
        return result
    }

    /// Point `index` removed from `points` (the editable points); with two points left it becomes the
    /// identity (no points).
    static func removing(_ index: Int, from points: [CGPoint]) -> [CGPoint] {
        var result = editable(points)
        guard result.indices.contains(index) else { return points }
        guard result.count > 2 else { return [] }
        result.remove(at: index)
        return result
    }

    /// The index of the point of `points` within `radius` (in the view's points) of `location`, the nearest,
    /// in a square editor `side` points wide (y up), or nil.
    static func hit(_ location: CGPoint, in points: [CGPoint], side: CGFloat, radius: CGFloat = 8) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in editable(points).enumerated() {
            let p = viewPoint(point, side: side)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance <= radius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// A curve point in the view (y down) of a square `side` points wide.
    static func viewPoint(_ point: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: point.x * side, y: (1 - point.y) * side)
    }

    /// A view location as a curve point (not limited).
    static func curvePoint(_ location: CGPoint, side: CGFloat) -> CGPoint {
        let side = max(side, 1)
        return CGPoint(x: location.x / side, y: 1 - location.y / side)
    }

    /// Whether a drag at `location` is far enough outside the square to remove its point.
    static func isDraggedOut(_ location: CGPoint, side: CGFloat) -> Bool {
        location.x < -dragOutDistance || location.y < -dragOutDistance || location.x > side + dragOutDistance
            || location.y > side + dragOutDistance
    }
}
