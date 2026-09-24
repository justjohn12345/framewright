import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// The Ken Burns helper (Final Cut Pro's "Ken Burns" crop mode): a start rectangle (green) and an
/// end rectangle (red) drawn over the whole picture on the program monitor. Each rectangle is the
/// part of the picture that fills the frame at that end of the move; the move between them becomes
/// position and scale keyframes on the first and last frames of its range
/// (`VEEngine.applyKenBurns(clip:start:end:interpolation:from:duration:)`), smoothed with Ease In
/// and Out by default as in FCP (Linear, Ease Out and Ease In can be chosen). Swap exchanges the
/// two framings, like FCP's swap button.
///
/// Range (`MoveRange`): the whole clip (the default, FCP's behaviour), or `durationFrames` from the
/// playhead or from the clip's start, 5 s by default (clamped to what is left of the clip). Before
/// the move the picture holds the start framing and after it the end framing, so a 5 s push in at
/// the head of a 30 s clip holds its end framing for the other 25 s.
///
/// Neighbours: with a clip touching this one's start on its track, "Continue from previous clip"
/// (`continuesFromPrevious`) puts the start rectangle on the framing the previous clip ends with;
/// with one touching its end, "Lead into next clip" (`leadsIntoNext`) puts the end rectangle on the
/// framing the next clip starts with (position and scale; the rectangle is drawn with this clip's
/// rotation and kept inside its picture, `neighbourNote` says when that changed the framing). Each is
/// on by default when that neighbour animates its position or scale or its framing there is not the
/// identity (centred, 100 %): then continuing it is what keeps the cut smooth; next to an unmoved
/// clip the push in stays the default. Turning one on or off resets that rectangle.
///
/// The picture under the rectangles follows the playhead, as in FCP: the clip's unanimated frame at
/// the playhead, or at its first or last frame while the playhead is before or after it
/// (`pictureSeconds`, loaded and paced by `KenBurnsPictureLoader`).
///
/// Default rectangles: when the clip is placed (position or scale animated, or not at the identity)
/// they show the framing the clip has at the range's first and last frames; otherwise the whole
/// picture pushing in gently. A rectangle the user moved or resized keeps its place when the range
/// changes; the others follow the range.
///
/// Geometry, in sequence pixels (origin at the frame's top-left corner, +y down): the picture is
/// shown as the compositor fits it at scale 1 and no offset (`pictureBounds`). A rectangle keeps
/// the sequence's aspect ratio (FCP locks it too), stays inside the picture (so the frame never
/// shows past the picture's edge) and is at least a tenth of the frame wide (a 1000 % zoom). The
/// clip's rotation is kept: a rectangle frames the unrotated picture and the frame shows it turned
/// by the clip's rotation at that end of the move.
@MainActor
final class KenBurnsModel: ObservableObject {
    enum Framing: CaseIterable {
        case start
        case end
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The part of the clip the move covers.
    enum MoveRange: String, CaseIterable, Identifiable {
        /// From the clip's first frame to its last (FCP's Ken Burns).
        case wholeClip
        /// `durationFrames` from the frame under the playhead.
        case fromPlayhead
        /// `durationFrames` from the clip's first frame.
        case fromClipStart

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wholeClip: return "Whole clip"
            case .fromPlayhead: return "From playhead"
            case .fromClipStart: return "From clip start"
            }
        }
    }

    /// A touching neighbour's framing at the cut (its last frame before this clip, its first after).
    struct Neighbour: Equatable {
        let clipID: VEClipID
        let framing: VEMotionFraming
        /// It animates its position or scale.
        let isAnimated: Bool

        /// The framing is the identity (centred, 100 %).
        var isIdentity: Bool { framing.x == 0 && framing.y == 0 && framing.scale == 1 }
        /// "Continue" / "Lead into" is on by default next to this neighbour.
        var isFollowedByDefault: Bool { isAnimated || !isIdentity }

        static func == (a: Neighbour, b: Neighbour) -> Bool {
            a.clipID == b.clipID && a.isAnimated == b.isAnimated && a.framing.x == b.framing.x
                && a.framing.y == b.framing.y && a.framing.scale == b.framing.scale
        }

        /// `clip`'s framing on its last frame (`atEnd`) or its first, as the monitor shows it.
        init?(_ clip: VEClipInfo?, atEnd: Bool, frameDuration: CMTime) {
            guard let clip, clip.trackKind == .video else { return nil }
            let frame = atEnd ? CMTimeSubtract(clip.timelineEnd, frameDuration) : clip.timelineStart
            let motion = clip.motion(at: frame)
            clipID = clip.clipID
            framing = VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
            isAnimated = clip.isAnimated(.positionX) || clip.isAnimated(.positionY) || clip.isAnimated(.scale)
        }
    }

    /// The interpolations the helper offers (FCP's smoothing choices).
    static let interpolations: [VEKeyframeInterpolation] = [.easeInOut, .easeOut, .easeIn, .linear]
    /// The smallest rectangle, as a fraction of the frame's width (a 1000 % zoom).
    static let minimumWidthFraction = 0.1
    /// The default end framing, as a fraction of the largest one (a gentle push in).
    static let defaultEndFraction = 0.8
    /// The default length of a move that does not cover the whole clip.
    static let defaultRangeSeconds = 5.0
    /// The caption shown while the move ends before the clip does.
    static let holdCaption = "Holds the end framing until the clip ends"

    /// The clip as it is now (the store passes every change through `update(clip:)`).
    private(set) var clip: VEClipInfo
    let assetID: VEAssetID
    let sequenceSize: CGSize
    let frameDuration: CMTime
    /// How durations are shown and what a bare typed number means (Settings > Editing).
    let durationDisplay: DurationDisplay
    /// The picture as the compositor fits it into the frame at scale 1, no offset.
    let pictureBounds: CGRect
    /// Loads the picture under the rectangles (the store gives the helper one over its thumbnails).
    let picture: KenBurnsPictureLoader?

    @Published var start: CGRect
    @Published var end: CGRect
    @Published var interpolation: VEKeyframeInterpolation = .easeInOut
    /// The part of the clip the move covers (a change resets the duration to its default).
    @Published var range: MoveRange = .wholeClip {
        didSet {
            guard range != oldValue else { return }
            requestedFrames = nil
            durationNote = nil
            rangeChanged()
        }
    }
    /// The Duration field's text (committed by `commitDuration()`).
    @Published var durationText = ""
    /// Why the last typed duration was refused or limited (nil when it was taken as typed).
    @Published private(set) var durationNote: String?
    /// The program playhead (where "From playhead" starts).
    @Published private(set) var playhead: CMTime
    /// The clip touching this one's start / end on its track (nil when there is none).
    @Published private(set) var previous: Neighbour?
    @Published private(set) var next: Neighbour?
    /// The start rectangle shows the framing the previous clip ends with.
    @Published var continuesFromPrevious = false {
        didSet {
            guard continuesFromPrevious != oldValue else { return }
            editedStart = false
            rangeChanged()
        }
    }
    /// The end rectangle shows the framing the next clip starts with.
    @Published var leadsIntoNext = false {
        didSet {
            guard leadsIntoNext != oldValue else { return }
            editedEnd = false
            rangeChanged()
        }
    }

    /// The duration typed for a partial range (frames, at least 2), or nil for the default.
    private var requestedFrames: Int64?
    /// Rectangles the user moved or resized (they keep their place when the range changes).
    private var editedStart = false
    private var editedEnd = false

    var clipID: VEClipID { clip.clipID }

    /// Nil when the clip cannot take a Ken Burns move (not a single video clip with a picture, or
    /// one frame long); `reason` says why.
    init?(clip: VEClipInfo, asset: VEAssetInfo, sequence: VESequenceInfo, playhead: CMTime,
          durationDisplay: DurationDisplay = .timecode, picture: KenBurnsPictureLoader? = nil,
          previous: VEClipInfo? = nil, next: VEClipInfo? = nil, reason: inout String) {
        guard clip.trackKind == .video, asset.hasVideo, asset.width > 0, asset.height > 0 else {
            reason = "Ken Burns works on a clip with a picture."
            return nil
        }
        let frame = sequence.frameDuration
        let lastFrame = CMTimeSubtract(clip.timelineEnd, frame)
        guard sequence.width > 0, sequence.height > 0, frame.isNumeric, frame.secondsOrZero > 0,
              lastFrame > clip.timelineStart else {
            reason = "The clip is one frame long: a Ken Burns move needs at least two frames."
            return nil
        }
        self.clip = clip
        assetID = asset.assetID
        sequenceSize = CGSize(width: sequence.width, height: sequence.height)
        frameDuration = frame
        self.durationDisplay = durationDisplay
        self.picture = picture
        self.playhead = playhead
        pictureBounds = Self.fittedPicture(width: Double(asset.width), height: Double(asset.height),
                                           in: sequenceSize)
        start = .zero
        end = .zero
        self.previous = Neighbour(previous, atEnd: true, frameDuration: frame)
        self.next = Neighbour(next, atEnd: false, frameDuration: frame)
        continuesFromPrevious = self.previous?.isFollowedByDefault ?? false
        leadsIntoNext = self.next?.isFollowedByDefault ?? false
        rangeChanged()
    }

    // MARK: Range

    /// Frames of `time` from zero on the sequence's frame grid (the frame containing it).
    private func frameIndex(_ time: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 0 }
        return Int64((time.secondsOrZero / frame + 1e-6).rounded(.down))
    }

    private func time(frames: Int64) -> CMTime {
        CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frames))
    }

    /// The clip's length in frames.
    var clipFrames: Int64 { max(0, frameIndex(clip.duration)) }

    /// The range's first frame, counted from the clip's first frame; nil when "From playhead" has
    /// the playhead outside the clip.
    var rangeOffset: Int64? {
        switch range {
        case .wholeClip, .fromClipStart:
            return 0
        case .fromPlayhead:
            let offset = frameIndex(playhead) - frameIndex(clip.timelineStart)
            return offset >= 0 && offset < clipFrames ? offset : nil
        }
    }

    /// Frames of the clip from the range's first frame to its end.
    var remainingFrames: Int64 { rangeOffset.map { clipFrames - $0 } ?? 0 }

    /// The default duration of a partial range: 5 s, or what is left of the clip.
    var defaultFrames: Int64 {
        let seconds = frameDuration.secondsOrZero
        let fiveSeconds = seconds > 0 ? Int64((Self.defaultRangeSeconds / seconds).rounded()) : 0
        return min(fiveSeconds, remainingFrames)
    }

    /// The move's length in frames: the clip's for the whole clip, else the typed or default
    /// duration clamped to what is left of the clip.
    var durationFrames: Int64 {
        switch range {
        case .wholeClip:
            return clipFrames
        case .fromPlayhead, .fromClipStart:
            return min(requestedFrames ?? defaultFrames, remainingFrames)
        }
    }

    /// Why the move cannot be applied with this range (nil when it can).
    var rangeProblem: String? {
        guard let offset = rangeOffset else {
            return "Move the playhead over the clip to start the move there."
        }
        if clipFrames - offset < 2 {
            return "Less than two frames of the clip are left after the playhead: a move needs at least two."
        }
        return nil
    }

    /// The timeline time of the range's first frame (the clip's start while `rangeProblem` is set).
    var rangeStart: CMTime {
        CMTimeAdd(clip.timelineStart, time(frames: rangeOffset ?? 0))
    }

    /// The range's length on the timeline.
    var rangeDuration: CMTime { time(frames: durationFrames) }

    /// The timeline time of the range's last frame (where the end keyframes go).
    var rangeLastFrame: CMTime {
        CMTimeAdd(rangeStart, time(frames: max(0, durationFrames - 1)))
    }

    /// Where the move starts and ends ("00:00:02:00 – 00:00:06:29"): the frames of its keyframes.
    var rangeTimecodes: String {
        "\(Timecode.string(rangeStart, frameDuration: frameDuration)) – "
            + "\(Timecode.string(rangeLastFrame, frameDuration: frameDuration))"
    }

    /// The caption under the range: why it cannot be applied, or that the end framing holds.
    var rangeCaption: String? {
        if let rangeProblem { return rangeProblem }
        return durationFrames < remainingFrames ? Self.holdCaption : nil
    }

    /// Whether the Duration field can be edited (not for the whole clip).
    var isDurationEditable: Bool { range != .wholeClip }

    /// `frames` in the user's duration format.
    func durationString(frames: Int64) -> String {
        DurationFormat.string(frames: frames, frameDuration: frameDuration, display: durationDisplay)
    }

    /// Takes the Duration field's text: parsed like every duration field
    /// (`DurationFormat.parseFrames`), at least two frames and at most what is left of the clip
    /// (`durationNote` says when it was limited). Returns false for text that is not a duration
    /// (`durationNote` says why; the duration stays). The whole clip has no duration to type.
    @discardableResult
    func commitDuration() -> Bool {
        guard isDurationEditable else {
            durationText = durationString(frames: durationFrames)
            return true
        }
        let typed = durationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != durationString(frames: durationFrames) else { return true }
        guard let frames = DurationFormat.parseFrames(typed, frameDuration: frameDuration, display: durationDisplay)
        else {
            durationNote = "“\(typed)” is not a duration (use frames like 45f, seconds like 2.5s, or timecode)."
            return false
        }
        var taken = frames
        var note: String?
        if taken < 2 {
            taken = 2
            note = "A move is at least two frames long."
        }
        if taken > remainingFrames {
            taken = remainingFrames
            note = "Limited to the \(durationString(frames: remainingFrames)) left in the clip."
        }
        requestedFrames = taken
        durationNote = note
        rangeChanged()
        return true
    }

    /// The program playhead moved: the picture follows it, and so does a "From playhead" range.
    func setPlayhead(_ time: CMTime) {
        guard time != playhead else { return }
        playhead = time
        if range == .fromPlayhead { rangeChanged() }
    }

    /// The clip changed while the helper is open (a trim, an undo): the range and the rectangles
    /// the user has not moved follow it.
    func update(clip: VEClipInfo, previous: VEClipInfo? = nil, next: VEClipInfo? = nil) {
        guard clip.clipID == self.clip.clipID else { return }
        self.clip = clip
        let before = Neighbour(previous, atEnd: true, frameDuration: frameDuration)
        let after = Neighbour(next, atEnd: false, frameDuration: frameDuration)
        if before != self.previous { self.previous = before }
        if after != self.next { self.next = after }
        // A neighbour that went away cannot be followed (the didSet refreshes the rectangle).
        if before == nil, continuesFromPrevious { continuesFromPrevious = false }
        if after == nil, leadsIntoNext { leadsIntoNext = false }
        rangeChanged()
    }

    /// The range, the playhead or the clip changed: reformat the duration and move the rectangles
    /// the user has not touched to their defaults.
    private func rangeChanged() {
        durationText = durationString(frames: durationFrames)
        if !editedStart { start = defaultRect(.start) }
        if !editedEnd { end = defaultRect(.end) }
    }

    /// The rectangle `which` has before the user moves it: the clip's framing at that end of the
    /// range when the clip is placed, else the whole picture (start) pushing in gently (end).
    func defaultRect(_ which: Framing) -> CGRect {
        if which == .start, continuesFromPrevious, let previous {
            return constrained(Self.rect(for: previous.framing, sequence: sequenceSize, rotationDegrees: startRotation))
        }
        if which == .end, leadsIntoNext, let next {
            return constrained(Self.rect(for: next.framing, sequence: sequenceSize, rotationDegrees: endRotation))
        }
        let first = clip.motion(at: rangeStart)
        let placed = clip.isAnimated(.positionX) || clip.isAnimated(.positionY) || clip.isAnimated(.scale)
            || first.scale != 1 || first.x != 0 || first.y != 0
        let largest = Self.largestRect(in: pictureBounds, aspect: aspect)
        guard placed else {
            return which == .start ? largest : Self.scaled(largest, by: Self.defaultEndFraction)
        }
        let motion = which == .start ? first : clip.motion(at: rangeLastFrame)
        return constrained(Self.rect(for: VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale),
                                     sequence: sequenceSize, rotationDegrees: motion.rotationDegrees))
    }

    /// Says when a followed neighbour's framing could not be kept exactly (it shows past this clip's
    /// picture, or zooms in further than the helper allows, so its rectangle was kept inside).
    var neighbourNote: String? {
        var parts: [String] = []
        if continuesFromPrevious, let previous, !editedStart, !Self.sameFraming(startFraming, previous.framing) {
            parts.append("the previous clip's end")
        }
        if leadsIntoNext, let next, !editedEnd, !Self.sameFraming(endFraming, next.framing) {
            parts.append("the next clip's start")
        }
        guard !parts.isEmpty else { return nil }
        return "The framing of \(parts.joined(separator: " and ")) reaches past this picture: its rectangle "
            + "was kept inside it."
    }

    /// Two framings the same within a millionth (the engine's `motionValuesMatch`).
    static func sameFraming(_ a: VEMotionFraming, _ b: VEMotionFraming) -> Bool {
        func same(_ u: Double, _ v: Double) -> Bool { abs(u - v) <= 1e-6 * max(1, abs(u), abs(v)) }
        return same(a.x, b.x) && same(a.y, b.y) && same(a.scale, b.scale)
    }

    /// The clip's rotation at the range's first and last frames (kept by the move).
    var startRotation: Double { clip.motion(at: rangeStart).rotationDegrees }
    var endRotation: Double { clip.motion(at: rangeLastFrame).rotationDegrees }

    /// The clip's frame the picture under the rectangles shows: the one under the playhead, or the
    /// clip's first or last frame while the playhead is before or after the clip (timeline time).
    var pictureFrame: CMTime {
        let offset = min(max(0, frameIndex(playhead) - frameIndex(clip.timelineStart)), max(0, clipFrames - 1))
        return CMTimeAdd(clip.timelineStart, time(frames: offset))
    }

    /// Source seconds of that frame's picture, through the clip's speed (a still has one picture).
    var pictureSeconds: Double {
        guard !clip.isStill else { return 0 }
        let offset = CMTimeSubtract(pictureFrame, clip.timelineStart)
        return clip.sourceIn.secondsOrZero + offset.secondsOrZero * clip.speed
    }

    // MARK: Geometry

    /// The picture fitted into the frame (centred, aspect kept), as the compositor draws it.
    static func fittedPicture(width: Double, height: Double, in sequence: CGSize) -> CGRect {
        let fit = min(Double(sequence.width) / width, Double(sequence.height) / height)
        let size = CGSize(width: width * fit, height: height * fit)
        return CGRect(x: (sequence.width - size.width) / 2, y: (sequence.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The largest rectangle of `aspect` (width / height) inside `bounds`, centred.
    static func largestRect(in bounds: CGRect, aspect: CGFloat) -> CGRect {
        let width = min(bounds.width, bounds.height * aspect)
        let size = CGSize(width: width, height: width / aspect)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
                      height: size.height)
    }

    static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let size = CGSize(width: rect.width * factor, height: rect.height * factor)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                      height: size.height)
    }

    /// The position and scale that make `rect` (sequence pixels of the unanimated picture) fill the
    /// frame, the picture turned by `rotationDegrees` (clockwise, about its centre as the
    /// compositor does): scale = frame width / rect width, and the rectangle's centre, scaled and
    /// turned, moves to the frame's centre.
    static func framing(for rect: CGRect, sequence: CGSize, rotationDegrees: Double) -> VEMotionFraming {
        let scale = Double(sequence.width / rect.width)
        let cx = Double(rect.midX - sequence.width / 2)
        let cy = Double(rect.midY - sequence.height / 2)
        let theta = rotationDegrees * .pi / 180
        let vx = cos(theta) * cx - sin(theta) * cy
        let vy = sin(theta) * cx + cos(theta) * cy
        return VEMotionFraming(x: -scale * vx, y: -scale * vy, scale: scale)
    }

    /// The inverse of `framing(for:sequence:rotationDegrees:)`.
    static func rect(for framing: VEMotionFraming, sequence: CGSize, rotationDegrees: Double) -> CGRect {
        let scale = max(framing.scale, 1e-6)
        let width = Double(sequence.width) / scale
        let height = Double(sequence.height) / scale
        let vx = -framing.x / scale
        let vy = -framing.y / scale
        let theta = rotationDegrees * .pi / 180
        let cx = cos(theta) * vx + sin(theta) * vy
        let cy = -sin(theta) * vx + cos(theta) * vy
        return CGRect(x: Double(sequence.width) / 2 + cx - width / 2, y: Double(sequence.height) / 2 + cy - height / 2,
                      width: width, height: height)
    }

    private var aspect: CGFloat { sequenceSize.width / sequenceSize.height }
    private var maximumWidth: CGFloat { min(pictureBounds.width, pictureBounds.height * aspect) }
    private var minimumWidth: CGFloat { min(maximumWidth, sequenceSize.width * Self.minimumWidthFraction) }

    /// `rect` with the frame's aspect ratio, within the size limits, moved inside the picture.
    func constrained(_ rect: CGRect) -> CGRect {
        let width = min(maximumWidth, max(minimumWidth, rect.width))
        let size = CGSize(width: width, height: width / aspect)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin.x = min(max(origin.x, pictureBounds.minX), pictureBounds.maxX - size.width)
        origin.y = min(max(origin.y, pictureBounds.minY), pictureBounds.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    func rect(_ which: Framing) -> CGRect {
        which == .start ? start : end
    }

    private func set(_ which: Framing, _ rect: CGRect) {
        if which == .start {
            start = rect
            editedStart = true
        } else {
            end = rect
            editedEnd = true
        }
    }

    /// Moves a rectangle from `original` by `delta` (sequence pixels), kept inside the picture.
    func move(_ which: Framing, from original: CGRect, by delta: CGSize) {
        set(which, constrained(original.offsetBy(dx: delta.width, dy: delta.height)))
    }

    /// Resizes a rectangle from `original` by dragging `corner` to `point` (sequence pixels): the
    /// opposite corner stays, the aspect ratio stays the frame's, and the rectangle stays inside the
    /// picture and within the size limits.
    func resize(_ which: Framing, from original: CGRect, corner: Corner, to point: CGPoint) {
        let anchor: CGPoint
        let growsRight: Bool
        let growsDown: Bool
        switch corner {
        case .topLeft:
            anchor = CGPoint(x: original.maxX, y: original.maxY)
            growsRight = false
            growsDown = false
        case .topRight:
            anchor = CGPoint(x: original.minX, y: original.maxY)
            growsRight = true
            growsDown = false
        case .bottomLeft:
            anchor = CGPoint(x: original.maxX, y: original.minY)
            growsRight = false
            growsDown = true
        case .bottomRight:
            anchor = CGPoint(x: original.minX, y: original.minY)
            growsRight = true
            growsDown = true
        }
        let wanted = max(abs(point.x - anchor.x), abs(point.y - anchor.y) * aspect)
        let roomX = growsRight ? pictureBounds.maxX - anchor.x : anchor.x - pictureBounds.minX
        let roomY = growsDown ? pictureBounds.maxY - anchor.y : anchor.y - pictureBounds.minY
        let width = max(min(minimumWidth, roomX, roomY * aspect), min(wanted, maximumWidth, roomX, roomY * aspect))
        let height = width / aspect
        let rect = CGRect(x: growsRight ? anchor.x : anchor.x - width, y: growsDown ? anchor.y : anchor.y - height,
                          width: width, height: height)
        set(which, constrained(rect))
    }

    /// Exchanges the start and end framings (FCP's swap button).
    func swap() {
        (start, end) = (end, start)
        editedStart = true
        editedEnd = true
    }

    /// The keyframe values the two rectangles give.
    var startFraming: VEMotionFraming {
        Self.framing(for: start, sequence: sequenceSize, rotationDegrees: startRotation)
    }

    var endFraming: VEMotionFraming {
        Self.framing(for: end, sequence: sequenceSize, rotationDegrees: endRotation)
    }
}

/// Loads the Ken Burns helper's picture through the thumbnail cache, paced for scrubbing: at most one
/// fetch of its own is in flight, and when it lands the latest wanted time is fetched next (the
/// times in between are skipped, like the program monitor's scrub coalescing). Until the wanted
/// picture arrives the last one shown stays up, so the picture never goes blank while scrubbing.
/// Pictures come from the cache (the whole, unanimated source frame), never from the program view.
@MainActor
final class KenBurnsPictureLoader: ObservableObject {
    /// The largest side of the fetched picture (enough for a monitor-sized overlay).
    static let maxDimension = 1280

    let assetID: VEAssetID
    private let cache: ThumbnailCache
    /// The picture to draw: the wanted one once it is cached, else the last one shown.
    @Published private(set) var image: CGImage?
    /// The source seconds last asked for.
    private(set) var wantedSeconds: Double?
    /// The source seconds of this loader's fetch in flight (nil when none).
    private(set) var pendingSeconds: Double?
    /// Fetches this loader started (diagnostics and tests).
    private(set) var fetchesStarted = 0

    init(assetID: VEAssetID, cache: ThumbnailCache) {
        self.assetID = assetID
        self.cache = cache
    }

    /// The picture at `seconds` (source time) is wanted now.
    func want(seconds: Double) {
        wantedSeconds = seconds
        update()
    }

    /// The cache changed (a fetch landed): show what is there and fetch the latest wanted time.
    func update() {
        guard let wanted = wantedSeconds else { return }
        let size = Self.maxDimension
        if let cached = cache.cachedImage(asset: assetID, seconds: wanted, maxDimension: size) {
            if image !== cached { image = cached }
            pendingSeconds = nil
            return
        }
        if image == nil, let any = cache.anyImage(asset: assetID, maxDimension: size) {
            image = any // something of this clip while the first picture loads
        }
        if let pending = pendingSeconds, cache.isFetching(asset: assetID, seconds: pending, maxDimension: size) {
            return // one at a time: the latest wanted time follows when this one lands
        }
        pendingSeconds = wanted
        _ = cache.image(asset: assetID, seconds: wanted, maxDimension: size) // starts the fetch
        if cache.isFetching(asset: assetID, seconds: wanted, maxDimension: size) {
            fetchesStarted += 1
        } else if let arrived = cache.cachedImage(asset: assetID, seconds: wanted, maxDimension: size) {
            image = arrived
            pendingSeconds = nil
        } else {
            pendingSeconds = nil // failed recently: the cache retries later; keep the last picture
        }
    }
}
