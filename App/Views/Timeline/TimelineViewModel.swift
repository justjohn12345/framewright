import CoreGraphics
import Foundation

/// Geometry and interaction math of the timeline, independent of SwiftUI and the engine.
///
/// Coordinates: x is in the track area's local space (x = 0 at the left edge of the visible
/// area, so a time t is at t * pixelsPerSecond - scrollX); y is in the track area's local
/// space below the ruler (y = 0 at the top of the first row, rows shifted up by scrollY).
/// Rows run top to bottom: video tracks from the top-most (last) to V1, then audio A1, A2, ...
/// Times are seconds (Double); callers convert to CMTime on the sequence frame grid.
struct TimelineViewModel: Equatable {
    enum TrackKind: Equatable {
        case video
        case audio
    }

    struct Track: Equatable, Identifiable {
        let id: Int64
        let kind: TrackKind
        /// Index within its kind (video: 0 = V1, the bottom one).
        let index: Int
        var name: String = ""
        var muted = false
        var solo = false
        var locked = false
    }

    struct Clip: Equatable, Identifiable {
        let id: Int64
        let trackID: Int64
        var assetID: Int64 = 0
        var name: String = ""
        var start: Double
        var end: Double
        var sourceIn: Double = 0
        var speed: Double = 1
        var linkedClipID: Int64 = 0
        var isStill = false
    }

    struct Transition: Equatable, Identifiable {
        let id: Int64
        let trackID: Int64
        let start: Double
        let end: Double
    }

    struct TrackLayout: Equatable {
        let track: Track
        /// Top of the row in content coordinates (before scrolling).
        let y: CGFloat
        let height: CGFloat
    }

    enum Hit: Equatable {
        case clipBody(Int64)
        case clipHead(Int64)
        case clipTail(Int64)
        case transition(Int64)
        /// Empty space on a track.
        case track(Int64)
        /// Below the last track.
        case none
    }

    enum SnapTarget: Equatable {
        case sequenceStart
        case playhead
        case clipStart(Int64)
        case clipEnd(Int64)
    }

    struct Snap: Equatable {
        /// The time the dragged edge snapped to.
        let time: Double
        let target: SnapTarget
    }

    static let videoTrackHeight: CGFloat = 64
    static let audioTrackHeight: CGFloat = 48
    static let trackSpacing: CGFloat = 2
    static let edgeZone: CGFloat = 8
    static let snapThreshold: CGFloat = 8
    /// Height of the strip at the top of a row where transitions are drawn and hit.
    static let transitionStripHeight: CGFloat = 14
    static let minPixelsPerSecond = 2.0
    static let maxPixelsPerSecond = 2000.0

    var pixelsPerSecond: Double = 50
    var scrollX: CGFloat = 0
    var scrollY: CGFloat = 0
    /// Sequence frame duration in seconds (for snapping to the frame grid).
    var frameSeconds: Double = 1.0 / 30.0
    var playhead: Double = 0
    var tracks: [Track] = [] {
        didSet { trackLayouts = Self.layouts(for: tracks) }
    }

    var clips: [Clip] = [] {
        didSet {
            clipIndex = Dictionary(clips.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    var transitions: [Transition] = []

    /// Rows in display order with their geometry (derived from `tracks`, computed once per change).
    private(set) var trackLayouts: [TrackLayout] = []
    /// Index of each clip in `clips` (derived).
    private var clipIndex: [Int64: Int] = [:]

    // MARK: Layout

    /// Rows in display order (top-most video track first, then audio tracks).
    var rowOrder: [Track] {
        trackLayouts.map(\.track)
    }

    private static func layouts(for tracks: [Track]) -> [TrackLayout] {
        let video = tracks.filter { $0.kind == .video }.sorted { $0.index > $1.index }
        let audio = tracks.filter { $0.kind == .audio }.sorted { $0.index < $1.index }
        var y: CGFloat = 0
        var layouts: [TrackLayout] = []
        for track in video + audio {
            let height = track.kind == .video ? Self.videoTrackHeight : Self.audioTrackHeight
            layouts.append(TrackLayout(track: track, y: y, height: height))
            y += height + Self.trackSpacing
        }
        return layouts
    }

    /// Total height of all rows.
    var contentHeight: CGFloat {
        guard let last = trackLayouts.last else { return 0 }
        return last.y + last.height
    }

    /// End of the last clip in seconds.
    var sequenceEnd: Double {
        clips.map(\.end).max() ?? 0
    }

    func x(forTime seconds: Double) -> CGFloat {
        CGFloat(seconds * pixelsPerSecond) - scrollX
    }

    func time(forX x: CGFloat) -> Double {
        Double(x + scrollX) / pixelsPerSecond
    }

    /// Time at `x` snapped to the frame grid and never negative.
    func frameTime(forX x: CGFloat) -> Double {
        snapToFrame(time(forX: x))
    }

    func snapToFrame(_ seconds: Double) -> Double {
        guard frameSeconds > 0 else { return max(0, seconds) }
        return max(0, (seconds / frameSeconds).rounded() * frameSeconds)
    }

    func layout(forTrack id: Int64) -> TrackLayout? {
        trackLayouts.first { $0.track.id == id } // a handful of rows: a scan beats hashing
    }

    /// Row under a y coordinate (visible space).
    func layout(atY y: CGFloat) -> TrackLayout? {
        let contentY = y + scrollY
        return trackLayouts.first { contentY >= $0.y && contentY < $0.y + $0.height + Self.trackSpacing }
    }

    func rect(forClip clip: Clip) -> CGRect? {
        guard let layout = layout(forTrack: clip.trackID) else { return nil }
        let x0 = x(forTime: clip.start)
        let x1 = x(forTime: clip.end)
        return CGRect(x: x0, y: layout.y - scrollY, width: max(1, x1 - x0), height: layout.height)
    }

    func rect(forTransition transition: Transition) -> CGRect? {
        guard let layout = layout(forTrack: transition.trackID) else { return nil }
        let x0 = x(forTime: transition.start)
        let x1 = x(forTime: transition.end)
        return CGRect(x: x0, y: layout.y - scrollY, width: max(4, x1 - x0), height: Self.transitionStripHeight)
    }

    func clip(id: Int64) -> Clip? {
        clipIndex[id].map { clips[$0] }
    }

    /// Clips whose rect intersects the horizontal range [minX, maxX] (visible culling).
    func clips(visibleIn width: CGFloat) -> [Clip] {
        let start = time(forX: 0)
        let end = time(forX: width)
        return clips.filter { $0.end >= start && $0.start <= end }
    }

    // MARK: Hit testing

    func hitTest(_ point: CGPoint) -> Hit {
        guard let layout = layout(atY: point.y) else { return .none }
        let rowTop = layout.y - scrollY
        if point.y - rowTop < Self.transitionStripHeight {
            for transition in transitions where transition.trackID == layout.track.id {
                if let r = rect(forTransition: transition), point.x >= r.minX, point.x <= r.maxX {
                    return .transition(transition.id)
                }
            }
        }
        // Edge zones win over bodies so the edit point between two touching clips can be trimmed
        // from either side (the closer edge wins).
        var best: (hit: Hit, distance: CGFloat)?
        func consider(_ hit: Hit, _ distance: CGFloat) {
            if let current = best, current.distance <= distance { return }
            best = (hit, distance)
        }
        for clip in clips where clip.trackID == layout.track.id {
            guard let r = rect(forClip: clip) else { continue }
            let zone = min(Self.edgeZone, r.width / 3)
            if point.x >= r.minX - 0.5, point.x <= r.minX + zone {
                consider(.clipHead(clip.id), abs(point.x - r.minX))
            }
            if point.x >= r.maxX - zone, point.x <= r.maxX + 0.5 {
                consider(.clipTail(clip.id), abs(point.x - r.maxX))
            }
        }
        if let best {
            return best.hit
        }
        for clip in clips where clip.trackID == layout.track.id {
            if let r = rect(forClip: clip), point.x >= r.minX, point.x < r.maxX {
                return .clipBody(clip.id)
            }
        }
        return .track(layout.track.id)
    }

    /// Clips whose rect intersects `rect` (visible space), for marquee selection.
    func clipIDs(intersecting area: CGRect) -> Set<Int64> {
        let normalized = area.standardized
        var ids = Set<Int64>()
        for clip in clips {
            if let r = rect(forClip: clip), r.intersects(normalized) {
                ids.insert(clip.id)
            }
        }
        return ids
    }

    /// `ids` plus their linked partners.
    func expandingLinks(_ ids: Set<Int64>) -> Set<Int64> {
        var result = ids
        for clip in clips where ids.contains(clip.id) && clip.linkedClipID != 0 {
            result.insert(clip.linkedClipID)
        }
        return result
    }

    // MARK: Snapping

    /// Snap candidates in seconds: the sequence start, the playhead (unless `includePlayhead` is
    /// false, e.g. while the playhead itself is dragged) and every clip edge except those of
    /// `excluding`.
    func snapCandidates(excluding: Set<Int64> = [],
                        includePlayhead: Bool = true) -> [(time: Double, target: SnapTarget)] {
        var result: [(Double, SnapTarget)] = [(0, .sequenceStart)]
        if includePlayhead {
            result.append((playhead, .playhead))
        }
        for clip in clips where !excluding.contains(clip.id) {
            result.append((clip.start, .clipStart(clip.id)))
            result.append((clip.end, .clipEnd(clip.id)))
        }
        return result
    }

    /// The candidate nearest to `seconds` within the snap threshold (in points), if any.
    func snap(_ seconds: Double, excluding: Set<Int64> = [], includePlayhead: Bool = true,
              thresholdPoints: CGFloat = snapThreshold) -> Snap? {
        let threshold = Double(thresholdPoints) / pixelsPerSecond
        var best: Snap?
        var bestDistance = Double.infinity
        for candidate in snapCandidates(excluding: excluding, includePlayhead: includePlayhead) {
            let distance = abs(candidate.time - seconds)
            if distance <= threshold, distance < bestDistance {
                best = Snap(time: candidate.time, target: candidate.target)
                bestDistance = distance
            }
        }
        return best
    }

    /// Snaps a moved range [start + delta, end + delta]: whichever edge is closer to a candidate
    /// decides. Returns the adjusted delta and the snap used.
    func snapMove(start: Double, end: Double, delta: Double, excluding: Set<Int64>) -> (delta: Double, snap: Snap?) {
        let startSnap = snap(start + delta, excluding: excluding)
        let endSnap = snap(end + delta, excluding: excluding)
        switch (startSnap, endSnap) {
        case let (s?, e?):
            let ds = abs(s.time - (start + delta))
            let de = abs(e.time - (end + delta))
            return ds <= de ? (s.time - start, s) : (e.time - end, e)
        case let (s?, nil):
            return (s.time - start, s)
        case let (nil, e?):
            return (e.time - end, e)
        case (nil, nil):
            return (delta, nil)
        }
    }

    // MARK: Zoom and ruler

    /// Zooms by `factor` keeping the time under `anchorX` in place.
    mutating func zoom(by factor: Double, anchorX: CGFloat) {
        let anchorTime = time(forX: anchorX)
        pixelsPerSecond = min(Self.maxPixelsPerSecond, max(Self.minPixelsPerSecond, pixelsPerSecond * factor))
        scrollX = max(0, CGFloat(anchorTime * pixelsPerSecond) - anchorX)
    }

    /// Seconds between labelled ruler ticks: the smallest "nice" interval at least `minSpacing`
    /// points wide (a whole number of frames at fine zoom).
    func rulerInterval(minSpacing: CGFloat = 80) -> Double {
        let nice: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        let frameSteps: [Double] = [1, 2, 5, 10, 15]
        for frames in frameSteps where frameSeconds > 0 {
            let seconds = frames * frameSeconds
            if seconds < 1, CGFloat(seconds * pixelsPerSecond) >= minSpacing {
                return seconds
            }
        }
        for seconds in nice where CGFloat(seconds * pixelsPerSecond) >= minSpacing {
            return seconds
        }
        return nice.last ?? 3600
    }

    /// Labelled tick times covering the visible `width`.
    func rulerTicks(width: CGFloat, minSpacing: CGFloat = 80) -> [Double] {
        let interval = rulerInterval(minSpacing: minSpacing)
        let first = (time(forX: 0) / interval).rounded(.down) * interval
        var ticks: [Double] = []
        var t = max(0, first)
        let end = time(forX: width)
        while t <= end + interval, ticks.count < 2000 {
            ticks.append(t)
            t += interval
        }
        return ticks
    }
}
