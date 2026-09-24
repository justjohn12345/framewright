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
        /// The track has no clips (only empty tracks can be collapsed).
        var isEmpty = false
        /// Shown as a short strip (`collapsedTrackHeight`): the user collapsed it and it is empty.
        var collapsed = false
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
        /// On an audio track: gain and fades are drawn and editable on the clip.
        var isAudio = false
        var gainDb: Double = 0
        /// Fade durations in seconds.
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        /// On a video track: the starts (seconds) of the sequence frames that show a Motion
        /// keyframe, sorted, one per frame (keyframes of every parameter; see
        /// `VEKeyframe.frameTime`). Drawn as markers along the clip's bottom edge.
        var keyframes: [Double] = []
    }

    struct Transition: Equatable, Identifiable {
        let id: Int64
        let trackID: Int64
        let start: Double
        let end: Double
        var fromClipID: Int64 = 0
        var toClipID: Int64 = 0

        /// The cut the transition is centred on (the outgoing clip's end).
        func cut(in model: TimelineViewModel) -> Double {
            model.clip(id: fromClipID)?.end ?? (start + end) / 2
        }
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
        /// Within `transitionEdgeZone` of a transition band's left or right edge (resize).
        case transitionHead(Int64)
        case transitionTail(Int64)
        /// The fade-in / fade-out handle at an audio clip's top corner.
        case fadeIn(Int64)
        case fadeOut(Int64)
        /// The horizontal gain line of an audio clip.
        case gainLine(Int64)
        /// A keyframe marker of a video clip: the start (seconds) of the frame that shows it (a
        /// click seeks there, a drag moves its keyframes).
        case keyframe(Int64, Double)
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
    /// Height of a collapsed (empty) track's row: room for its header's name and toggles.
    static let collapsedTrackHeight: CGFloat = 22
    static let trackSpacing: CGFloat = 2
    static let edgeZone: CGFloat = 8
    static let snapThreshold: CGFloat = 8
    /// Height of the strip at the top of a row where transitions are drawn and hit.
    static let transitionStripHeight: CGFloat = 16
    /// Width of the resize zone at each edge of a transition band (at most a quarter of it).
    static let transitionEdgeZone: CGFloat = 5
    /// Fade handles: a square this big at the clip's top corner (at the fade's end), hit within
    /// `fadeHandleHitRadius` horizontally and the top `fadeHandleZoneHeight` points vertically.
    static let fadeHandleSize: CGFloat = 7
    static let fadeHandleHitRadius: CGFloat = 6
    static let fadeHandleZoneHeight: CGFloat = 12
    /// On a clip narrower than `narrowClipWidth` points the handles are hit only within the
    /// drawn square (the top `narrowFadeHandleZoneHeight` points), leaving most of its label to
    /// select and move it.
    static let narrowClipWidth: CGFloat = 40
    static let narrowFadeHandleZoneHeight: CGFloat = 1 + fadeHandleSize

    /// Height of the top zone of `clip`'s row in which its fade handles are hit.
    func fadeHandleZoneHeight(forClip clip: Clip) -> CGFloat {
        guard let rect = rect(forClip: clip) else { return 0 }
        return rect.width < Self.narrowClipWidth ? Self.narrowFadeHandleZoneHeight : Self.fadeHandleZoneHeight
    }
    /// Keyframe markers: diamonds this big along the bottom of a video clip, centred on the frame
    /// that shows the keyframe, hit within `keyframeHitRadius` horizontally in the bottom
    /// `keyframeZoneHeight` points of the row.
    static let keyframeMarkerSize: CGFloat = 7
    static let keyframeHitRadius: CGFloat = 5
    static let keyframeZoneHeight: CGFloat = 11
    /// The gain line is hit within this many points vertically.
    static let gainLineHitDistance: CGFloat = 3
    /// Gain line mapping: the top of the content area is `gainMaxDb`, its bottom `gainMinDb`.
    static let gainMaxDb = 24.0
    static let gainMinDb = -60.0
    /// Top inset of a clip's content (below its name label).
    static let clipLabelHeight: CGFloat = 16
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
            let height = track.collapsed ? Self.collapsedTrackHeight
                : track.kind == .video ? Self.videoTrackHeight : Self.audioTrackHeight
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

    func transition(id: Int64) -> Transition? {
        transitions.first { $0.id == id }
    }

    /// The part of a clip's rect below its label, where waveforms, fades and the gain line are.
    func contentRect(forClip clip: Clip) -> CGRect? {
        guard let rect = rect(forClip: clip) else { return nil }
        let body = rect.insetBy(dx: 0.5, dy: 1)
        return CGRect(x: body.minX, y: body.minY + Self.clipLabelHeight, width: body.width,
                      height: max(1, body.height - Self.clipLabelHeight))
    }

    /// y of the gain line for `gainDb` within `content` (clamped to the content area).
    static func gainY(_ gainDb: Double, in content: CGRect) -> CGFloat {
        let fraction = (gainMaxDb - min(gainMaxDb, max(gainMinDb, gainDb))) / (gainMaxDb - gainMinDb)
        return content.minY + CGFloat(fraction) * content.height
    }

    /// Decibels per point of vertical drag on the gain line (`fine`: a tenth of it).
    func decibelsPerPoint(forClip clip: Clip, fine: Bool) -> Double {
        let height = contentRect(forClip: clip)?.height ?? 32
        return (Self.gainMaxDb - Self.gainMinDb) / Double(max(height, 1)) * (fine ? 0.1 : 1)
    }

    /// Centre of the fade-in (`fadeIn` true) or fade-out handle of an audio clip.
    func fadeHandleCenter(forClip clip: Clip, fadeIn: Bool) -> CGPoint? {
        guard clip.isAudio, let rect = rect(forClip: clip) else { return nil }
        let inset = Self.fadeHandleSize / 2 + 1
        let x = fadeIn ? max(x(forTime: clip.start + clip.fadeIn), rect.minX + inset)
            : min(x(forTime: clip.end - clip.fadeOut), rect.maxX - inset)
        return CGPoint(x: x, y: rect.minY + 1 + inset)
    }

    /// Centre of the marker of the keyframe shown by the frame starting at `time` (inside the
    /// clip's rect, whatever the zoom).
    func keyframeMarkerCenter(forClip clip: Clip, time: Double) -> CGPoint? {
        guard !clip.isAudio, let rect = rect(forClip: clip) else { return nil }
        let inset = min(Self.keyframeMarkerSize / 2 + 1, rect.width / 2)
        let x = min(max(x(forTime: time + frameSeconds / 2), rect.minX + inset), rect.maxX - inset)
        return CGPoint(x: x, y: rect.maxY - Self.keyframeMarkerSize / 2 - 2)
    }

    /// Clips whose rect intersects the horizontal range [minX, maxX] (visible culling).
    func clips(visibleIn width: CGFloat) -> [Clip] {
        let start = time(forX: 0)
        let end = time(forX: width)
        return clips.filter { $0.end >= start && $0.start <= end }
    }

    // MARK: Hit testing

    /// What a press at `point` grabs, by priority: a transition band (its edges resize it), an
    /// audio clip's fade handle (top corner zone), a video clip's keyframe marker (bottom zone), a
    /// clip edge (trim), an audio clip's gain line, a clip body, empty track space.
    func hitTest(_ point: CGPoint) -> Hit {
        guard let layout = layout(atY: point.y) else { return .none }
        let rowTop = layout.y - scrollY
        if point.y - rowTop < Self.transitionStripHeight {
            for transition in transitions where transition.trackID == layout.track.id {
                if let r = rect(forTransition: transition), point.x >= r.minX - 1, point.x <= r.maxX + 1 {
                    let zone = min(Self.transitionEdgeZone, r.width / 4)
                    if point.x <= r.minX + zone { return .transitionHead(transition.id) }
                    if point.x >= r.maxX - zone { return .transitionTail(transition.id) }
                    return .transition(transition.id)
                }
            }
        }
        if layout.track.kind == .audio, point.y - rowTop < Self.fadeHandleZoneHeight {
            var best: (hit: Hit, distance: CGFloat)?
            for clip in clips where clip.trackID == layout.track.id && clip.isAudio {
                guard point.y - rowTop < fadeHandleZoneHeight(forClip: clip) else { continue }
                for fadeIn in [true, false] {
                    guard let center = fadeHandleCenter(forClip: clip, fadeIn: fadeIn) else { continue }
                    let distance = abs(point.x - center.x)
                    if distance <= Self.fadeHandleHitRadius, best.map({ distance < $0.distance }) ?? true {
                        best = (fadeIn ? .fadeIn(clip.id) : .fadeOut(clip.id), distance)
                    }
                }
            }
            if let best { return best.hit }
        }
        if layout.track.kind == .video, point.y >= rowTop + layout.height - Self.keyframeZoneHeight {
            var best: (hit: Hit, distance: CGFloat)?
            for clip in clips where clip.trackID == layout.track.id && !clip.keyframes.isEmpty {
                guard let r = rect(forClip: clip), point.x >= r.minX - Self.keyframeHitRadius,
                      point.x <= r.maxX + Self.keyframeHitRadius else { continue }
                for time in clip.keyframes {
                    guard let center = keyframeMarkerCenter(forClip: clip, time: time) else { continue }
                    let distance = abs(point.x - center.x)
                    if distance <= Self.keyframeHitRadius, best.map({ distance < $0.distance }) ?? true {
                        best = (.keyframe(clip.id, time), distance)
                    }
                }
            }
            if let best { return best.hit }
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
                if clip.isAudio, let content = contentRect(forClip: clip),
                   abs(point.y - Self.gainY(clip.gainDb, in: content)) <= Self.gainLineHitDistance {
                    return .gainLine(clip.id)
                }
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
