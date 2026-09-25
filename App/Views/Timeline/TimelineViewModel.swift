import CoreGraphics
import Foundation

/// Geometry and interaction math of the timeline, independent of SwiftUI and the engine.
///
/// Coordinates: x is in the track area's local space (x = 0 at the left edge of the visible
/// area, so a time t is at t * pixelsPerSecond - scrollX); y is in the track area's local
/// space below the ruler (y = 0 at the top of the first row, rows shifted up by scrollY).
/// Rows run top to bottom: video tracks from the top-most (last) to V1, then audio A1, A2, ...
/// Times are seconds (Double); callers convert to CMTime on the sequence frame grid.
///
/// Lanes: under a track's row of clips come its lanes (`Track.lanes`, `laneHeight` each): lane 0
/// holds the transitions (cross dissolves / crossfades across a cut, fades from and to black or
/// silence), lanes 1-3 the effect spans (Motion and Opacity on video, Gain on audio). Which lanes a
/// track shows is `lanes(hasClips:spans:collapsed:revealTransitionLane:)`: none for an empty track or
/// one whose lanes the user collapsed; lane 0 while the track has a transition (or a transition is
/// dragged over the timeline); the effect lanes in use plus one empty lane to create spans on, never
/// more than `maxEffectLanes`. A span is drawn on its lane over its range: an effect span within
/// its clip, a transition straddling its cut.
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
        /// The lanes drawn under the row, top to bottom (lane 0, the transitions, first); see
        /// `lanes(hasClips:spans:collapsed:revealTransitionLane:)`.
        var lanes: [Int] = []
        /// The user collapsed the track's lanes (the disclosure in its header; a track with clips).
        var lanesCollapsed = false
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
    }

    /// What a span changes (VESpanKind).
    enum SpanKind: Equatable {
        /// Lane 0: a cross dissolve / crossfade or a fade from or to black / silence.
        case transition
        /// Video: position, scale and rotation (a Ken Burns move).
        case motion
        /// Video: opacity (a fade).
        case opacity
        /// Audio: gain in dB.
        case gain
    }

    /// What a transition span does where it sits (VETransitionStyle).
    enum TransitionStyle: Equatable {
        case crossDissolve
        case fadeOut
        case fadeIn
    }

    /// A span of a clip on one of its track's lanes (VEEffectSpan), in timeline seconds.
    struct Span: Equatable, Identifiable {
        let id: Int64
        let clipID: Int64
        let trackID: Int64
        var lane: Int
        var kind: SpanKind
        var start: Double
        var end: Double
        /// Transitions: what it does, and the cut it hangs on (its clip's end for a cross dissolve
        /// or a fade out, its clip's start for a fade in).
        var style: TransitionStyle = .crossDissolve
        var cut: Double = 0
        /// On an audio track (a crossfade rather than a dissolve).
        var isAudio = false

        /// The name drawn on the bar (and used in the inspector).
        var title: String {
            switch kind {
            case .motion: return "Motion"
            case .opacity: return "Fade"
            case .gain: return "Gain"
            case .transition:
                switch style {
                case .crossDissolve: return isAudio ? "Crossfade" : "Cross Dissolve"
                case .fadeIn: return "Fade In"
                case .fadeOut: return "Fade Out"
                }
            }
        }

        /// The SF Symbol drawn on the bar.
        var systemImage: String {
            switch kind {
            case .motion: return "arrow.up.left.and.arrow.down.right"
            case .opacity: return "circle.lefthalf.filled"
            case .gain: return "speaker.wave.2"
            case .transition:
                switch style {
                case .crossDissolve: return isAudio ? "waveform.path" : "square.on.square.dashed"
                case .fadeIn: return "arrow.up.right"
                case .fadeOut: return "arrow.down.right"
                }
            }
        }
    }

    struct TrackLayout: Equatable {
        let track: Track
        /// Top of the row in content coordinates (before scrolling).
        let y: CGFloat
        /// The row and its lanes.
        let height: CGFloat
        /// The row of clips (the lanes follow below it).
        let rowHeight: CGFloat

        /// The lanes shown under the row, top to bottom.
        var lanes: [Int] { track.lanes }

        /// Top of `lane` in content coordinates, or nil when it is not shown.
        func laneY(_ lane: Int) -> CGFloat? {
            guard let index = track.lanes.firstIndex(of: lane) else { return nil }
            return y + rowHeight + CGFloat(index) * TimelineViewModel.laneHeight
        }

        /// The lane at content y `contentY` inside this layout (nil in the row of clips). The spacing
        /// below the last lane belongs to it.
        func lane(atContentY contentY: CGFloat) -> Int? {
            let below = contentY - (y + rowHeight)
            guard below >= 0, !track.lanes.isEmpty else { return nil }
            let index = min(track.lanes.count - 1, Int(below / TimelineViewModel.laneHeight))
            return track.lanes[index]
        }
    }

    enum Hit: Equatable {
        case clipBody(Int64)
        case clipHead(Int64)
        case clipTail(Int64)
        /// The horizontal gain line of an audio clip.
        case gainLine(Int64)
        /// A span's bar on its lane (a transition on lane 0 too).
        case span(Int64)
        /// Within `spanEdgeZone` of a span's start or end (trim; a transition's edge).
        case spanHead(Int64)
        case spanTail(Int64)
        /// Empty space on a lane of a track.
        case lane(track: Int64, lane: Int)
        /// Empty space on a track's row.
        case track(Int64)
        /// Below the last track.
        case none
    }

    enum SnapTarget: Equatable {
        case sequenceStart
        case playhead
        case clipStart(Int64)
        case clipEnd(Int64)
        case spanStart(Int64)
        case spanEnd(Int64)
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
    /// Height of a lane under a track's row.
    static let laneHeight: CGFloat = 14
    /// Effect lanes (1-3) a track has at most; lane 0 holds its transitions.
    static let maxEffectLanes = 3
    /// Width of the trim zone at each edge of a span's bar (at most a quarter of it).
    static let spanEdgeZone: CGFloat = 5
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

    var spans: [Span] = [] {
        didSet {
            spanIndex = Dictionary(spans.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Rows in display order with their geometry (derived from `tracks`, computed once per change).
    private(set) var trackLayouts: [TrackLayout] = []
    /// Index of each clip in `clips` and each span in `spans` (derived).
    private var clipIndex: [Int64: Int] = [:]
    private var spanIndex: [Int64: Int] = [:]

    // MARK: Layout

    /// Rows in display order (top-most video track first, then audio tracks).
    var rowOrder: [Track] {
        trackLayouts.map(\.track)
    }

    /// The lanes a track shows under its row, top to bottom: none for a track without clips or one
    /// whose lanes are `collapsed`; lane 0 while one of `spans` is a transition or
    /// `revealTransitionLane` (a transition is dragged over the timeline); then effect lanes 1 up to
    /// the highest one in use plus one empty lane (to create spans on), at most `maxEffectLanes`.
    static func lanes(hasClips: Bool, spans: [Span], collapsed: Bool, revealTransitionLane: Bool) -> [Int] {
        guard hasClips, !collapsed else { return [] }
        var lanes: [Int] = []
        if revealTransitionLane || spans.contains(where: { $0.lane == 0 }) {
            lanes.append(0)
        }
        let highest = spans.map(\.lane).filter { $0 >= 1 }.max() ?? 0
        lanes.append(contentsOf: 1 ... min(maxEffectLanes, highest + 1))
        return lanes
    }

    private static func layouts(for tracks: [Track]) -> [TrackLayout] {
        let video = tracks.filter { $0.kind == .video }.sorted { $0.index > $1.index }
        let audio = tracks.filter { $0.kind == .audio }.sorted { $0.index < $1.index }
        var y: CGFloat = 0
        var layouts: [TrackLayout] = []
        for track in video + audio {
            let row = track.collapsed ? Self.collapsedTrackHeight
                : track.kind == .video ? Self.videoTrackHeight : Self.audioTrackHeight
            let height = row + CGFloat(track.lanes.count) * Self.laneHeight
            layouts.append(TrackLayout(track: track, y: y, height: height, rowHeight: row))
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

    /// Width of the scrollable time: the sequence and 30 s after it, at the current zoom.
    var contentWidth: CGFloat {
        CGFloat((sequenceEnd + 30) * pixelsPerSecond)
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

    /// Row under a y coordinate (visible space): the row of clips, its lanes and the spacing below.
    func layout(atY y: CGFloat) -> TrackLayout? {
        let contentY = y + scrollY
        return trackLayouts.first { contentY >= $0.y && contentY < $0.y + $0.height + Self.trackSpacing }
    }

    /// The rectangle of the clip's row part (its lanes are below it).
    func rect(forClip clip: Clip) -> CGRect? {
        guard let layout = layout(forTrack: clip.trackID) else { return nil }
        let x0 = x(forTime: clip.start)
        let x1 = x(forTime: clip.end)
        return CGRect(x: x0, y: layout.y - scrollY, width: max(1, x1 - x0), height: layout.rowHeight)
    }

    /// The visible rectangle of `lane` of a track (the whole width), or nil when it is not shown.
    func laneRect(track id: Int64, lane: Int, width: CGFloat) -> CGRect? {
        guard let layout = layout(forTrack: id), let top = layout.laneY(lane) else { return nil }
        return CGRect(x: 0, y: top - scrollY, width: width, height: Self.laneHeight)
    }

    /// The bar of a span on its lane (nil when the lane is not shown): an effect span over its range
    /// within its clip's x range; a transition over its whole range, across its cut.
    func rect(forSpan span: Span) -> CGRect? {
        guard let layout = layout(forTrack: span.trackID), let top = layout.laneY(span.lane) else { return nil }
        var x0 = x(forTime: span.start)
        var x1 = x(forTime: span.end)
        if span.kind != .transition, let clip = clip(id: span.clipID) {
            x0 = max(x0, x(forTime: clip.start))
            x1 = min(x1, x(forTime: clip.end))
        }
        return CGRect(x: x0, y: top - scrollY + 1, width: max(3, x1 - x0), height: Self.laneHeight - 2)
    }

    func clip(id: Int64) -> Clip? {
        clipIndex[id].map { clips[$0] }
    }

    func span(id: Int64) -> Span? {
        spanIndex[id].map { spans[$0] }
    }

    /// The spans of a clip on one lane, in time order.
    func spans(ofClip clipID: Int64, lane: Int) -> [Span] {
        spans.filter { $0.clipID == clipID && $0.lane == lane }.sorted { $0.start < $1.start }
    }

    /// The clip of `trackID` whose time range contains `seconds` (its start included), if any.
    func clip(onTrack trackID: Int64, at seconds: Double) -> Clip? {
        clips.first { $0.trackID == trackID && $0.start <= seconds && seconds < $0.end }
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

    /// Clips whose rect intersects the horizontal range [minX, maxX] (visible culling).
    func clips(visibleIn width: CGFloat) -> [Clip] {
        let start = time(forX: 0)
        let end = time(forX: width)
        return clips.filter { $0.end >= start && $0.start <= end }
    }

    /// Spans whose range intersects the visible width (visible culling).
    func spans(visibleIn width: CGFloat) -> [Span] {
        let start = time(forX: 0)
        let end = time(forX: width)
        return spans.filter { $0.end >= start && $0.start <= end }
    }

    // MARK: Hit testing

    /// What a press at `point` grabs. On a lane: a span's edge (the nearer one within
    /// `spanEdgeZone`, trim), else its bar, else the empty lane. On the row of clips: a clip edge
    /// (trim; between two touching clips the closer edge wins), an audio clip's gain line, a clip
    /// body, else empty track space.
    func hitTest(_ point: CGPoint) -> Hit {
        guard let layout = layout(atY: point.y) else { return .none }
        if let lane = layout.lane(atContentY: point.y + scrollY) {
            return laneHit(point, track: layout.track.id, lane: lane)
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

    /// A press on `lane` of `track`: the nearest span edge within its zone, a span's bar, or the lane.
    private func laneHit(_ point: CGPoint, track: Int64, lane: Int) -> Hit {
        var edge: (hit: Hit, distance: CGFloat)?
        var body: Hit?
        for span in spans where span.trackID == track && span.lane == lane {
            guard let r = rect(forSpan: span), point.x >= r.minX - 1, point.x <= r.maxX + 1 else { continue }
            let zone = min(Self.spanEdgeZone, r.width / 4)
            for (hit, x) in [(Hit.spanHead(span.id), r.minX), (Hit.spanTail(span.id), r.maxX)] {
                let distance = abs(point.x - x)
                if distance <= zone, edge.map({ distance < $0.distance }) ?? true {
                    edge = (hit, distance)
                }
            }
            if point.x >= r.minX, point.x <= r.maxX { body = .span(span.id) }
        }
        return edge?.hit ?? body ?? .lane(track: track, lane: lane)
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
    /// false, e.g. while the playhead itself is dragged), every clip edge except those of
    /// `excluding` and, when `excludingSpans` is given (a span drag), every span edge but those.
    func snapCandidates(excluding: Set<Int64> = [], excludingSpans: Set<Int64>? = nil,
                        includePlayhead: Bool = true) -> [(time: Double, target: SnapTarget)] {
        var result: [(Double, SnapTarget)] = [(0, .sequenceStart)]
        if includePlayhead {
            result.append((playhead, .playhead))
        }
        for clip in clips where !excluding.contains(clip.id) {
            result.append((clip.start, .clipStart(clip.id)))
            result.append((clip.end, .clipEnd(clip.id)))
        }
        if let excludingSpans {
            for span in spans where !excludingSpans.contains(span.id) {
                result.append((span.start, .spanStart(span.id)))
                result.append((span.end, .spanEnd(span.id)))
            }
        }
        return result
    }

    /// The candidate nearest to `seconds` within the snap threshold (in points), if any.
    func snap(_ seconds: Double, excluding: Set<Int64> = [], excludingSpans: Set<Int64>? = nil,
              includePlayhead: Bool = true, thresholdPoints: CGFloat = snapThreshold) -> Snap? {
        let threshold = Double(thresholdPoints) / pixelsPerSecond
        var best: Snap?
        var bestDistance = Double.infinity
        for candidate in snapCandidates(excluding: excluding, excludingSpans: excludingSpans,
                                        includePlayhead: includePlayhead) {
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
    func snapMove(start: Double, end: Double, delta: Double, excluding: Set<Int64>,
                  excludingSpans: Set<Int64>? = nil) -> (delta: Double, snap: Snap?) {
        let startSnap = snap(start + delta, excluding: excluding, excludingSpans: excludingSpans)
        let endSnap = snap(end + delta, excluding: excluding, excludingSpans: excludingSpans)
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
