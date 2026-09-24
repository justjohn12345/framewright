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
/// Range (`MoveRange`): the whole clip (the default, FCP's behaviour), `durationFrames` from the
/// playhead or from the clip's start (5 s by default, clamped to what is left of the clip), or a
/// Custom span. Before the move the picture shows the clip's framing without it; after it the end
/// framing holds until the clip ends or the next move starts (which moves on from it), so a 5 s push
/// in at the head of a 30 s clip holds its end framing for the other 25 s.
///
/// Start and End fields (`startText`, `endText`) show the range's first and last frames as timeline
/// times (the ruler's), in the user's duration format, whatever the range; committing a different
/// value (`commitStart()`, `commitEnd()`) makes the range Custom with that end moved and the other
/// kept, clamped to the clip's frames and at least two frames long (`rangeNote` says when it was
/// limited). A typed Duration in Custom (or Existing move) moves the end. A field whose text is
/// still being typed is committed by Return (which then does not press Apply:
/// `hasUncommittedText`) and by Apply.
///
/// Editing a move: when the clip already has position or scale keyframes on its frames
/// (`detectMove(in:frameDuration:)`), the helper opens on that move ("Existing move"): the range is
/// the span from the earliest to the latest of those keyframes' frames, the rectangles show the
/// framing on its first and last frames and the smoothing is the first keyframe's (when the helper
/// offers it), so Apply replaces the move in place. The span follows the keyframes while the helper
/// is open (a keyframe dragged in the timeline, an undo). Keyframes a trim hid do not count, unless
/// they are the only ones: then the move covers the whole clip and `rangeCaption` says why.
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
/// While the helper is open the timeline marks the range on the clip (`bandRange`, forwarded by the
/// store to `KenBurnsTimelineBand`).
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
        /// The move already on the clip (`existingMove`): from its first to its last position or
        /// scale keyframe. Offered only while the clip has one.
        case existingMove
        /// A span typed in the Start and End fields (`customSpan`, counted from the clip's first
        /// frame).
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wholeClip: return "Whole clip"
            case .fromPlayhead: return "From playhead"
            case .fromClipStart: return "From clip start"
            case .existingMove: return "Existing move"
            case .custom: return "Custom"
            }
        }
    }

    /// A move already on the clip: the frames (counted from the clip's first frame) of its earliest
    /// and latest position or scale keyframes that a frame of the clip shows.
    struct ExistingMove: Equatable {
        let first: Int64
        let last: Int64
        /// Position or scale keyframes lie on frames between the two (a curve through them, or
        /// several moves): Apply replaces them.
        let hasKeyframesBetween: Bool
        /// The smoothing of the move's first keyframe (position X, else Y, else scale), when it is
        /// one of `interpolations`; else nil.
        let interpolation: VEKeyframeInterpolation?
    }

    /// A range's first and last frames, counted from the clip's first frame.
    struct FrameSpan: Equatable {
        var first: Int64
        var last: Int64
    }

    /// What `detectMove(in:frameDuration:)` finds on a clip.
    enum MoveDetection: Equatable {
        /// No position or scale keyframes on two different frames of the clip.
        case none
        /// Position or scale keyframes exist, but a trim hid every one of them.
        case hiddenOnly
        case move(ExistingMove)
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
            isAnimated = clip.spans.contains { $0.kind == .motion }
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
    /// The caption shown while the move ends before the clip does (a Motion span holds its end
    /// values after its end; a later move on its lane starts from them).
    static let holdCaption = "After the move its end framing holds until the clip ends or the next move starts"
    /// The caption shown when the clip's position and scale keyframes are all hidden by a trim.
    static let hiddenMoveCaption = "The clip's position and scale keyframes are all in parts a trim hid: "
        + "the move covers the whole clip (Apply replaces them)"

    /// The clip as it is now (the store passes every change through `update(clip:)`).
    private(set) var clip: VEClipInfo
    let assetID: VEAssetID
    let sequenceSize: CGSize
    let frameDuration: CMTime
    /// How durations are shown and what a bare typed number means (Settings > Editing; the store
    /// passes a change on while the helper is open, and the fields not being typed in follow it).
    var durationDisplay: DurationDisplay {
        didSet {
            guard durationDisplay != oldValue else { return }
            rangeChanged()
        }
    }
    /// The picture as the compositor fits it into the frame at scale 1, no offset.
    let pictureBounds: CGRect
    /// Loads the picture under the rectangles (the store gives the helper one over its thumbnails).
    let picture: KenBurnsPictureLoader?

    @Published var start: CGRect
    @Published var end: CGRect
    @Published var interpolation: VEKeyframeInterpolation = .easeInOut
    /// The part of the clip the move covers (a change resets the duration to its default; choosing
    /// Custom keeps the current span).
    @Published var range: MoveRange = .wholeClip {
        willSet {
            if newValue == .custom, range != .custom {
                customSpan = currentSpan ?? wholeSpan
            }
        }
        didSet {
            guard range != oldValue else { return }
            requestedFrames = nil
            rangeNote = nil
            rangeChanged()
        }
    }
    /// The Duration field's text (committed by `commitDuration()`).
    @Published var durationText = ""
    /// The Start and End fields' text: the range's first and last frames as timeline times
    /// (committed by `commitStart()` / `commitEnd()`).
    @Published var startText = ""
    @Published var endText = ""
    /// Why the last typed Start, End or Duration was refused or limited (nil when it was taken as
    /// typed).
    @Published private(set) var rangeNote: String?
    /// The range as the timeline marks it (nil while it cannot be applied); changes only when the
    /// range does.
    @Published private(set) var bandRange: KenBurnsBandRange?
    /// The program playhead (where "From playhead" starts).
    @Published private(set) var playhead: CMTime
    /// The move already on the clip (updated with every clip change while the helper is open).
    @Published private(set) var detection: MoveDetection
    /// The clip touching this one's start / end on its track (nil when there is none).
    @Published private(set) var previous: Neighbour?
    @Published private(set) var next: Neighbour?
    /// The start rectangle shows the framing the previous clip ends with. Turning it on or off
    /// (the user's choice) resets that rectangle; the helper turning it off because the neighbour
    /// went away keeps a rectangle the user moved.
    @Published var continuesFromPrevious = false {
        didSet {
            guard continuesFromPrevious != oldValue else { return }
            if !keepsEditedRectangles { editedStart = false }
            rangeChanged()
        }
    }
    /// The end rectangle shows the framing the next clip starts with (see `continuesFromPrevious`).
    @Published var leadsIntoNext = false {
        didSet {
            guard leadsIntoNext != oldValue else { return }
            if !keepsEditedRectangles { editedEnd = false }
            rangeChanged()
        }
    }

    /// The duration typed for a partial range (frames, at least 2), or nil for the default.
    private var requestedFrames: Int64?
    /// The Custom range as chosen (kept within the clip by `clamped(_:)` when used).
    private var customSpan = FrameSpan(first: 0, last: 1)
    /// Rectangles the user moved or resized (they keep their place when the range changes).
    private(set) var editedStart = false
    private(set) var editedEnd = false
    /// Set while the helper itself turns a neighbour toggle off (the neighbour went away).
    private var keepsEditedRectangles = false

    /// The Start, End and Duration fields.
    enum Field: CaseIterable {
        case start, end, duration
    }

    /// The value each field was last given by the model: a field whose text still equals it is not
    /// being typed in and follows the range; one whose text differs holds what the user is typing and
    /// is left alone until it is committed.
    private var committedText: [Field: String] = [:]

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
        detection = Self.detectMove(in: clip, frameDuration: frame)
        self.previous = Neighbour(previous, atEnd: true, frameDuration: frame)
        self.next = Neighbour(next, atEnd: false, frameDuration: frame)
        if case let .move(move) = detection {
            // Editing the clip's move: it opens as it is. A neighbour is followed only where the move
            // already continues it (its end of the clip, the same framing), so the rectangles show the
            // clip's own framing.
            range = .existingMove
            interpolation = move.interpolation ?? interpolation
            let lastFrame = max(0, clipFrames - 1)
            let span = Self.moveSpan(in: clip)
            continuesFromPrevious = self.previous.map {
                move.first == 0 && Self.sameFraming(edgeFraming(of: span, atEnd: false) ?? framing(atFrame: 0), $0.framing)
            } ?? false
            leadsIntoNext = self.next.map {
                move.last == lastFrame
                    && Self.sameFraming(edgeFraming(of: span, atEnd: true) ?? framing(atFrame: lastFrame), $0.framing)
            } ?? false
        } else {
            continuesFromPrevious = self.previous?.isFollowedByDefault ?? false
            leadsIntoNext = self.next?.isFollowedByDefault ?? false
        }
        rangeChanged()
    }

    // MARK: Existing move

    /// Frames of `time` from zero on a `frameDuration` grid (the frame containing it).
    static func frameIndex(_ time: CMTime, frameDuration: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 0 }
        return Int64((time.secondsOrZero / frame + 1e-6).rounded(.down))
    }

    /// The move already on `clip`: its first Motion span (the frames it covers, counted from the clip's
    /// first frame, and its smoothing when the helper offers it). A span of a single frame is no move
    /// (`.none`). (Motion keyframes became Motion spans; `.hiddenOnly` no longer occurs: a trim clips a
    /// span instead of hiding it.)
    static func detectMove(in clip: VEClipInfo, frameDuration: CMTime) -> MoveDetection {
        guard let span = moveSpan(in: clip) else { return .none }
        let clipStart = frameIndex(clip.timelineStart, frameDuration: frameDuration)
        let first = frameIndex(span.start, frameDuration: frameDuration) - clipStart
        let last = frameIndex(CMTimeSubtract(span.end, frameDuration), frameDuration: frameDuration) - clipStart
        guard last > first else { return .none }
        return .move(ExistingMove(first: first, last: last, hasKeyframesBetween: false,
                                  interpolation: interpolations.contains(span.interpolation) ? span.interpolation : nil))
    }

    /// The Motion span `detectMove` takes as the clip's move: its first by start (nil for an audio
    /// clip or one without Motion spans).
    static func moveSpan(in clip: VEClipInfo) -> VEEffectSpan? {
        guard clip.trackKind == .video else { return nil }
        return clip.spans.filter { $0.kind == .motion }.min { $0.start < $1.start }
    }

    /// The move already on the clip, if any.
    var existingMove: ExistingMove? {
        if case let .move(move) = detection { return move }
        return nil
    }

    /// The ranges the Move menu offers (Existing move only while the clip has one).
    var rangeChoices: [MoveRange] {
        MoveRange.allCases.filter { $0 != .existingMove || existingMove != nil || range == .existingMove }
    }

    /// The clip's position and scale on its frame `offset` frames from its first.
    /// The framing an edge of the Motion span `span` shows: what a Ken Burns move applied to it
    /// (`VEClipInfo.getMotion(_:atEdgeOfSpan:)`; its end framing is reached at the span's end).
    private func edgeFraming(of span: VEEffectSpan?, atEnd: Bool) -> VEMotionFraming? {
        guard let span else { return nil }
        var motion = VEVideoParams()
        guard clip.getMotion(&motion, atEdgeOfSpan: span.spanID, atEnd: atEnd, frameDuration: frameDuration) else {
            return nil
        }
        return VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
    }

    private func framing(atFrame offset: Int64) -> VEMotionFraming {
        let motion = clip.motion(at: CMTimeAdd(clip.timelineStart, time(frames: offset)))
        return VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
    }

    // MARK: Range

    /// Frames of `time` from zero on the sequence's frame grid (the frame containing it).
    private func frameIndex(_ time: CMTime) -> Int64 {
        Self.frameIndex(time, frameDuration: frameDuration)
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
        case .existingMove:
            return existingSpan?.first ?? 0
        case .custom:
            return clamped(customSpan).first
        }
    }

    /// `span` kept within the clip's frames, first before last (for a clip of at least two frames).
    private func clamped(_ span: FrameSpan) -> FrameSpan {
        guard clipFrames >= 2 else { return FrameSpan(first: 0, last: max(0, clipFrames - 1)) }
        let first = min(max(0, span.first), clipFrames - 2)
        return FrameSpan(first: first, last: min(max(first + 1, span.last), clipFrames - 1))
    }

    /// The whole clip as a span.
    private var wholeSpan: FrameSpan { FrameSpan(first: 0, last: max(0, clipFrames - 1)) }

    /// The existing move's frames, kept within the clip's; nil without one.
    private var existingSpan: FrameSpan? {
        guard let move = existingMove else { return nil }
        return clamped(FrameSpan(first: move.first, last: move.last))
    }

    /// The range's first and last frames (counted from the clip's first frame); nil when "From
    /// playhead" has the playhead outside the clip.
    var currentSpan: FrameSpan? {
        guard let offset = rangeOffset else { return nil }
        return FrameSpan(first: offset, last: offset + max(1, durationFrames) - 1)
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
        case .existingMove:
            guard let span = existingSpan else { return clipFrames }
            return span.last - span.first + 1
        case .custom:
            let span = clamped(customSpan)
            return span.last - span.first + 1
        }
    }

    /// Why the move cannot be applied with this range (nil when it can).
    var rangeProblem: String? {
        if clipFrames < 2 {
            return "The clip is one frame long: a Ken Burns move needs at least two frames."
        }
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

    /// The caption under the range: why it cannot be applied, which existing move it edits, that
    /// the clip's keyframes are all hidden by a trim, or that the end framing holds.
    var rangeCaption: String? {
        if let rangeProblem { return rangeProblem }
        if range == .existingMove, let move = existingMove {
            let span = "Editing the move from \(Timecode.string(rangeStart, frameDuration: frameDuration)) to "
                + Timecode.string(rangeLastFrame, frameDuration: frameDuration)
            return move.hasKeyframesBetween ? span + "; keyframes in between are replaced" : span
        }
        if range == .wholeClip, detection == .hiddenOnly { return Self.hiddenMoveCaption }
        return durationFrames < remainingFrames ? Self.holdCaption : nil
    }

    /// Whether the Duration field can be edited (not for the whole clip; in Existing move a typed
    /// duration makes the range Custom).
    var isDurationEditable: Bool { range != .wholeClip }

    /// `frames` in the user's duration format.
    func durationString(frames: Int64) -> String {
        DurationFormat.string(frames: frames, frameDuration: frameDuration, display: durationDisplay)
    }

    /// The span the Start and End fields show and edit: the range's, or the whole clip's while the
    /// range cannot be applied ("From playhead" with the playhead off the clip).
    private var fieldSpan: FrameSpan {
        guard rangeProblem == nil, let span = currentSpan else { return wholeSpan }
        return span
    }

    /// The Start and End fields' committed values: the first and last frames of `fieldSpan` as
    /// timeline times in the user's duration format (the ruler's timecode by default).
    var startString: String { durationString(frames: frameIndex(clip.timelineStart) + fieldSpan.first) }
    var endString: String { durationString(frames: frameIndex(clip.timelineStart) + fieldSpan.last) }

    /// A field's text (trimmed, as a commit reads it) differs from its committed value: Return
    /// commits it instead of pressing Apply.
    var hasUncommittedText: Bool {
        trimmed(startText) != startString || trimmed(endText) != endString
            || (isDurationEditable && trimmed(durationText) != durationString(frames: durationFrames))
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits the Start, End and Duration fields (Apply takes what is still being typed). False
    /// when one holds text that is not a time or duration (`rangeNote` says why).
    func commitFields() -> Bool {
        commitStart() && commitEnd() && commitDuration()
    }

    /// Takes the Start field's text: the timeline frame the move starts on (see `commitBoundary`).
    @discardableResult
    func commitStart() -> Bool { commitBoundary(.start) }

    /// Takes the End field's text: the timeline frame of the end keyframes (see `commitBoundary`).
    @discardableResult
    func commitEnd() -> Bool { commitBoundary(.end) }

    /// Takes the Start (`.start`) or End field's text: a timeline time parsed like the Duration
    /// field (`DurationFormat.parseFrames`: timecode, 150f, 5s, or a bare number in the display's
    /// unit), as the sequence frame from zero. Unchanged text changes nothing. Otherwise the range
    /// becomes Custom with that end moved and the other kept (`fieldSpan`: the whole clip's while
    /// the range cannot be applied), the moved end limited to the clip's frames and to at least two
    /// frames of range (`rangeNote` says when). Returns false for text that is not a time
    /// (`rangeNote` says why; the range stays).
    private func commitBoundary(_ which: Framing) -> Bool {
        let field: Field = which == .start ? .start : .end
        let typed = trimmed(which == .start ? startText : endText)
        guard typed != (which == .start ? startString : endString) else {
            rewrite(field) // spaces around the value
            return true
        }
        guard let frame = DurationFormat.parseFrames(typed, frameDuration: frameDuration, display: durationDisplay)
        else {
            rangeNote = "“\(typed)” is not a time (use timecode like 00:00:05:00, frames like 150f or seconds "
                + "like 5s)."
            return false
        }
        guard clipFrames >= 2 else {
            rangeNote = rangeProblem
            return false
        }
        let clipStart = frameIndex(clip.timelineStart)
        if frame - clipStart == (which == .start ? fieldSpan.first : fieldSpan.last) {
            // The same frame written another way ("2s" for 00:00:02:00): the range stays as it is.
            rewrite(field)
            return true
        }
        let lastFrame = clipFrames - 1
        let current = fieldSpan
        var offset = frame - clipStart
        var note: String?
        if offset < 0 {
            offset = 0
            note = "Limited to the clip's first frame, \(timeText(offset: 0))."
        } else if offset > lastFrame {
            offset = lastFrame
            note = "Limited to the clip's last frame, \(timeText(offset: lastFrame))."
        }
        var span = current
        if which == .start {
            if offset > current.last - 1 {
                offset = max(0, current.last - 1)
                note = "A move is at least two frames long: the start is \(timeText(offset: offset)), a frame "
                    + "before the end."
            }
            span.first = offset
        } else {
            if offset < current.first + 1 {
                offset = min(lastFrame, current.first + 1)
                note = "A move is at least two frames long: the end is \(timeText(offset: offset)), a frame "
                    + "after the start."
            }
            span.last = offset
        }
        setCustom(span, note: note, committing: field)
        return true
    }

    /// The timeline time of the clip's frame `offset` frames from its first, in the user's format.
    private func timeText(offset: Int64) -> String {
        durationString(frames: frameIndex(clip.timelineStart) + offset)
    }

    /// Makes the range Custom over `span` (clip frames), with `note` explaining a limit; the field
    /// `committing` shows its committed value (the other fields keep what is being typed in them).
    private func setCustom(_ span: FrameSpan, note: String?, committing field: Field) {
        if range != .custom { range = .custom } // prefills customSpan, then refreshes
        customSpan = clamped(span)
        rangeNote = note
        rangeChanged(rewriting: [field])
    }

    /// Takes the Duration field's text: parsed like every duration field
    /// (`DurationFormat.parseFrames`), at least two frames and at most what is left of the clip
    /// (`rangeNote` says when it was limited). In Custom and Existing move it moves the range's end
    /// (the range becomes Custom). Returns false for text that is not a duration (`rangeNote` says
    /// why; the duration stays). The whole clip has no duration to type.
    @discardableResult
    func commitDuration() -> Bool {
        guard isDurationEditable else {
            rewrite(.duration)
            return true
        }
        let typed = trimmed(durationText)
        guard typed != durationString(frames: durationFrames) else {
            rewrite(.duration)
            return true
        }
        guard let frames = DurationFormat.parseFrames(typed, frameDuration: frameDuration, display: durationDisplay)
        else {
            rangeNote = "“\(typed)” is not a duration (use frames like 45f, seconds like 2.5s, or timecode)."
            return false
        }
        if let problem = rangeProblem {
            // "From playhead" with the playhead off the clip: there is no range to give a duration.
            rangeNote = problem
            return false
        }
        if frames == durationFrames {
            rewrite(.duration) // the same length written another way: the range stays
            return true
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
        switch range {
        case .existingMove, .custom:
            let first = rangeOffset ?? 0
            setCustom(FrameSpan(first: first, last: first + taken - 1), note: note, committing: .duration)
        case .wholeClip, .fromPlayhead, .fromClipStart:
            requestedFrames = taken
            rangeNote = note
            rangeChanged(rewriting: [.duration])
        }
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
        // A neighbour that went away cannot be followed (the didSet refreshes a rectangle the user
        // has not moved; one the user moved stays where it is).
        keepsEditedRectangles = true
        if before == nil, continuesFromPrevious { continuesFromPrevious = false }
        if after == nil, leadsIntoNext { leadsIntoNext = false }
        keepsEditedRectangles = false
        // The existing move follows its keyframes (dragged in the timeline, undone...).
        let detected = Self.detectMove(in: clip, frameDuration: frameDuration)
        if detected != detection { detection = detected }
        if range == .existingMove, existingMove == nil {
            range = .wholeClip // the move is gone (the didSet refreshes the range)
        } else {
            rangeChanged()
        }
    }

    /// The range, the playhead or the clip changed: reformat the Start, End and Duration fields that
    /// are not being typed in (and the ones in `rewriting`, just committed) and move the rectangles
    /// the user has not touched to their defaults. A field whose text differs from what the model last
    /// put there holds the user's typing: a save, an import, an undo or the playhead moving never
    /// replaces it.
    private func rangeChanged(rewriting: Set<Field> = []) {
        for field in Field.allCases {
            refresh(field, force: rewriting.contains(field))
        }
        let band = rangeProblem == nil
            ? KenBurnsBandRange(clipID: clip.clipID, start: rangeStart.secondsOrZero,
                                end: CMTimeAdd(rangeLastFrame, frameDuration).secondsOrZero)
            : nil
        if band != bandRange { bandRange = band }
        if !editedStart { start = defaultRect(.start) }
        if !editedEnd { end = defaultRect(.end) }
    }

    /// The model's value of `field` now.
    private func modelText(_ field: Field) -> String {
        switch field {
        case .start: return startString
        case .end: return endString
        case .duration: return durationString(frames: durationFrames)
        }
    }

    private func text(_ field: Field) -> String {
        switch field {
        case .start: return startText
        case .end: return endText
        case .duration: return durationText
        }
    }

    private func setText(_ field: Field, _ value: String) {
        guard text(field) != value else { return }
        switch field {
        case .start: startText = value
        case .end: endText = value
        case .duration: durationText = value
        }
    }

    /// Puts the model's value in `field` when it is not being typed in (its text is still what the
    /// model last put there) or when `force`d, and remembers it as the committed value.
    private func refresh(_ field: Field, force: Bool) {
        let value = modelText(field)
        if force || text(field) == (committedText[field] ?? "") {
            setText(field, value)
        }
        committedText[field] = value
    }

    /// Shows the committed value in `field` (after it was committed).
    private func rewrite(_ field: Field) {
        refresh(field, force: true)
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
        let first = rangeMotion(atEnd: false)
        let placed = clip.spans.contains { $0.kind == .motion } || first.scale != 1 || first.x != 0 || first.y != 0
        let largest = Self.largestRect(in: pictureBounds, aspect: aspect)
        guard placed else {
            return which == .start ? largest : Self.scaled(largest, by: Self.defaultEndFraction)
        }
        let motion = which == .start ? first : rangeMotion(atEnd: true)
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
    var startRotation: Double { rangeMotion(atEnd: false).rotationDegrees }
    var endRotation: Double { rangeMotion(atEnd: true).rotationDegrees }

    /// The clip's Motion span over exactly the helper's range, if any (what Apply edits in place).
    private var rangeSpan: VEEffectSpan? {
        let end = CMTimeAdd(rangeStart, rangeDuration)
        return clip.spans.first { $0.kind == .motion && $0.start == rangeStart && $0.end == end }
    }

    /// The Motion at the range's start or end: for a Motion span over exactly the range, the
    /// framings a move applied to it (`VEClipInfo.getMotion(_:atEdgeOfSpan:)`: the span's end values
    /// are reached at its end, one frame after its last frame); otherwise what the range's first or
    /// last frame shows.
    private func rangeMotion(atEnd: Bool) -> VEVideoParams {
        if let span = rangeSpan {
            var motion = VEVideoParams()
            if clip.getMotion(&motion, atEdgeOfSpan: span.spanID, atEnd: atEnd, frameDuration: frameDuration) {
                return motion
            }
        }
        return clip.motion(at: atEnd ? rangeLastFrame : rangeStart)
    }

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

    /// A drag on the overlay: `target` (a rectangle's body or corner, `KenBurnsHit`) grabbed with the
    /// rectangle at `origin`, now `translation` from where it started and at `location` (sequence
    /// pixels). A drag that has not moved changes nothing (a click does not mark the rectangle as
    /// moved, so it keeps following the range).
    func applyDrag(_ target: KenBurnsHit.Target, origin: CGRect, translation: CGSize, location: CGPoint) {
        guard translation != .zero else { return }
        switch target {
        case let .body(which):
            move(which, from: origin, by: translation)
        case let .corner(which, corner):
            resize(which, from: origin, corner: corner, to: location)
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

/// What a press on the Ken Burns overlay grabs, from the two rectangles as drawn (view points). The
/// end rectangle is drawn over the start, and with the default push in, or an unanimated placed clip,
/// the two overlap or coincide; so the grab is decided by geometry, not by which is on top: the
/// nearest corner handle, then a rectangle's label (the start's inside its top-left corner, the
/// end's inside its bottom-right), then the nearest edge (a band either side of each edge), then the
/// inside of a rectangle (inside both: the smaller one, whose edges are the nearer). Where the two coincide
/// the start owns the top and left corners and edges, the end the bottom and right, and the inside
/// drags the end.
enum KenBurnsHit {
    enum Target: Equatable {
        case body(KenBurnsModel.Framing)
        case corner(KenBurnsModel.Framing, KenBurnsModel.Corner)

        var framing: KenBurnsModel.Framing {
            switch self {
            case let .body(which): return which
            case let .corner(which, _): return which
            }
        }
    }

    /// How far from a corner a press grabs it, and from an edge a press grabs the rectangle.
    static let cornerRadius: CGFloat = 8
    static let edgeBand: CGFloat = 6
    /// The labels' hit areas.
    static let labelSize = CGSize(width: 40, height: 16)

    /// Where a rectangle's label is drawn (inside it: the start's at the top-left, the end's at the
    /// bottom-right).
    static func labelRect(_ which: KenBurnsModel.Framing, of rect: CGRect) -> CGRect {
        which == .start
            ? CGRect(origin: rect.origin, size: labelSize)
            : CGRect(x: rect.maxX - labelSize.width, y: rect.maxY - labelSize.height, width: labelSize.width,
                     height: labelSize.height)
    }

    static func cornerPoint(_ corner: KenBurnsModel.Corner, of rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The target at `point`, or nil (outside both rectangles and their handles).
    static func target(at point: CGPoint, start: CGRect, end: CGRect) -> Target? {
        let rects: [(KenBurnsModel.Framing, CGRect)] = [(.start, start), (.end, end)]
        // Corners: the nearest within reach. On a tie (the rectangles coincide there) the start takes
        // the left corners and the end the right ones.
        var corners: [(target: Target, distance: CGFloat, owner: Bool)] = []
        for (which, rect) in rects {
            for corner in KenBurnsModel.Corner.allCases {
                let c = cornerPoint(corner, of: rect)
                let distance = hypot(point.x - c.x, point.y - c.y)
                guard distance <= cornerRadius else { continue }
                let left = corner == .topLeft || corner == .bottomLeft
                corners.append((.corner(which, corner), distance, (which == .start) == left))
            }
        }
        if let target = nearest(corners) { return target }
        // Labels (each inside its own rectangle, away from the other's).
        for (which, rect) in rects where labelRect(which, of: rect).contains(point) {
            return .body(which)
        }
        // Edges: the nearest within the band either side. On a tie the start takes the top and left
        // edges and the end the bottom and right ones.
        var edges: [(target: Target, distance: CGFloat, owner: Bool)] = []
        for (which, rect) in rects {
            guard point.x >= rect.minX - edgeBand, point.x <= rect.maxX + edgeBand,
                  point.y >= rect.minY - edgeBand, point.y <= rect.maxY + edgeBand else { continue }
            let sides: [(CGFloat, Bool)] = [ // (distance, a top or left edge)
                (abs(point.x - rect.minX), true), (abs(point.y - rect.minY), true),
                (abs(point.x - rect.maxX), false), (abs(point.y - rect.maxY), false),
            ]
            for (distance, topOrLeft) in sides where distance <= edgeBand {
                edges.append((.body(which), distance, (which == .start) == topOrLeft))
            }
        }
        if let target = nearest(edges) { return target }
        // Inside: one rectangle, or the smaller of the two (the end when they coincide).
        let inside = rects.filter { $0.1.contains(point) }
        if inside.count == 1 { return .body(inside[0].0) }
        if inside.count == 2 {
            return .body(start.width * start.height < end.width * end.height ? .start : .end)
        }
        return nil
    }

    /// The nearest candidate; among those within half a point of it, one its owner rule prefers.
    private static func nearest(_ candidates: [(target: Target, distance: CGFloat, owner: Bool)]) -> Target? {
        guard let closest = candidates.map(\.distance).min() else { return nil }
        let tied = candidates.filter { $0.distance <= closest + 0.5 }
        return (tied.first { $0.owner } ?? tied.first)?.target
    }
}

/// The Ken Burns range as the timeline marks it: the clip and the timeline seconds from the range's
/// first frame's start to its last frame's end.
struct KenBurnsBandRange: Equatable {
    let clipID: VEClipID
    let start: Double
    let end: Double
}

/// The range the timeline highlights while the Ken Burns helper is open (nil otherwise). A separate
/// object observed only by the timeline's band overlay (`KenBurnsBandView`), so a range that moves
/// with the playhead or with typing redraws that overlay alone: never the clips' canvas, never the
/// timeline model.
@MainActor
final class KenBurnsTimelineBand: ObservableObject {
    @Published private(set) var range: KenBurnsBandRange?

    /// Shows `range` (nil hides the band); publishes only a change.
    func show(_ range: KenBurnsBandRange?) {
        if range != self.range { self.range = range }
    }
}

/// Loads the Ken Burns helper's picture, paced for scrubbing, with a small cache of its own: the
/// pictures are large (up to `maxDimension`, several MB each) and belong to the helper alone, so they
/// never go through the shared `ThumbnailCache` (whose every landing redraws the timeline and the
/// media bin, and whose entries have no byte budget). At most one fetch is in flight; when it lands
/// its picture is shown at once (the playhead may have moved on: a picture a little behind the
/// playhead beats a frozen one while scrubbing) and the latest wanted time is fetched next, the times
/// in between skipped (like the program monitor's scrub coalescing). A failed fetch also moves on to
/// the latest wanted time; a time that failed is not fetched again until another time was wanted.
/// Until the first picture arrives nothing is shown. At most `capacity` pictures are kept (the least
/// recently shown go first), so the loader's memory is bounded however long the scrub. Only the
/// overlay observes it. Pictures are the whole, unanimated source frame, never the program view.
@MainActor
final class KenBurnsPictureLoader: ObservableObject {
    /// The largest side of the fetched picture (enough for a monitor-sized overlay).
    static let maxDimension = 1280
    /// Pictures kept by default: the current one plus a few to step back to.
    nonisolated static let defaultCapacity = 6

    /// Fetches the unanimated picture of an asset at a source time, calling `completion` on the main
    /// thread with it or the error (the engine's `thumbnail(forAsset:at:maxDimension:completion:)`).
    typealias Fetch = (_ asset: VEAssetID, _ time: CMTime, _ maxDimension: Int,
                       _ completion: @escaping (CGImage?, Error?) -> Void) -> Void

    let assetID: VEAssetID
    /// Pictures kept at most.
    let capacity: Int
    /// The picture to draw: the wanted one once it has arrived, else the last one that arrived.
    @Published private(set) var image: CGImage?
    /// The source seconds last asked for.
    private(set) var wantedSeconds: Double?
    /// The source seconds of the fetch in flight (nil when none).
    private(set) var pendingSeconds: Double?
    /// Fetches started, and those that failed (diagnostics and tests).
    private(set) var fetchesStarted = 0
    private(set) var fetchesFailed = 0

    private let fetch: Fetch
    /// Kept pictures by time (milliseconds), and their use order (oldest first).
    private var pictures: [Int64: CGImage] = [:]
    private var useOrder: [Int64] = []
    /// Times whose fetch failed, not fetched again until another time was wanted.
    private var failedMillis: Int64?

    /// Pictures from `engine` (held weakly: the helper never keeps a closed project's engine).
    convenience init(assetID: VEAssetID, engine: VEEngine, capacity: Int = KenBurnsPictureLoader.defaultCapacity) {
        self.init(assetID: assetID, capacity: capacity) { [weak engine] asset, time, size, completion in
            guard let engine else {
                completion(nil, nil)
                return
            }
            engine.thumbnail(forAsset: asset, at: time, maxDimension: size) { image, error in
                completion(image, error)
            }
        }
    }

    init(assetID: VEAssetID, capacity: Int = KenBurnsPictureLoader.defaultCapacity, fetch: @escaping Fetch) {
        self.assetID = assetID
        self.capacity = max(1, capacity)
        self.fetch = fetch
    }

    /// Pictures kept now (at most `capacity`).
    var cachedCount: Int { pictures.count }

    /// The picture at `seconds` (source time) is wanted now.
    func want(seconds: Double) {
        let millis = Self.millis(seconds)
        if millis != wantedSeconds.map(Self.millis) {
            failedMillis = nil // a new time: one that failed may be tried again later
        }
        wantedSeconds = seconds
        drive()
    }

    /// Memory pressure: keeps only the picture on screen.
    func handleMemoryPressure() {
        for millis in useOrder where pictures[millis] !== image {
            pictures[millis] = nil
        }
        useOrder.removeAll { pictures[$0] == nil }
    }

    static func millis(_ seconds: Double) -> Int64 {
        Int64((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
    }

    /// Shows the wanted picture when it is kept, else fetches it (one fetch at a time).
    private func drive() {
        guard let wanted = wantedSeconds else { return }
        let millis = Self.millis(wanted)
        if let kept = pictures[millis] {
            touch(millis)
            if image !== kept { image = kept }
            return
        }
        guard pendingSeconds == nil, millis != failedMillis else { return }
        pendingSeconds = wanted
        fetchesStarted += 1
        fetch(assetID, CMTime(value: millis, timescale: 1000), Self.maxDimension) { [weak self] picture, error in
            MainActor.assumeIsolated {
                self?.landed(millis: millis, picture: picture, error: error)
            }
        }
    }

    private func landed(millis: Int64, picture: CGImage?, error: Error?) {
        pendingSeconds = nil
        if let picture {
            keep(picture, millis: millis)
            image = picture // shown before the next fetch starts
        } else if !isProjectClosed(error) {
            fetchesFailed += 1
            failedMillis = millis
        }
        drive() // the latest wanted time next (also after a failure)
    }

    private func keep(_ picture: CGImage, millis: Int64) {
        pictures[millis] = picture
        touch(millis)
        while useOrder.count > capacity, let oldest = useOrder.first {
            useOrder.removeFirst()
            pictures[oldest] = nil
        }
    }

    private func touch(_ millis: Int64) {
        useOrder.removeAll { $0 == millis }
        useOrder.append(millis)
    }
}
