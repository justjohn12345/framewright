import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// The Ken Burns editor of one Motion span, drawn over the program monitor: the monitor keeps
/// showing the composed program at the playhead (every track, re-rendered live as a drag edits the
/// span), fitted inside a margin that stands for the space off the frame (`KenBurnsViewport`), and
/// the editor draws the clip's placement box at the span's start (green) and at its end (red) over
/// it, plus a thin outline of every other visible clip's box at the playhead.
///
/// A box is where the clip's picture sits in the frame at that edge: the picture fitted into the
/// frame as the compositor places a clip with identity values, scaled about its centre by the
/// edge's scale, moved by its position and turned by its rotation (`box(for:picture:sequence:)`).
/// The edge's values are its composed Motion (the clip's static values with every span that has
/// started applied, this one at that edge, `VEClipInfo.getMotion(_:atEdgeOfSpan:)`), so a picture in
/// picture at 30 % in the lower right shows its Start box around the picture in the lower right.
/// Dragging a box's body moves it (position), dragging a corner scales it about its centre (the
/// aspect stays the picture's); its rotation is the inspector's. A dragged box goes back to the
/// absolute values that place the picture there (`motion(for:picture:sequence:)`) and those to the
/// span's relative values over what the rest of the clip composes to there
/// (`ProjectStore.relativeFraming`), so the inspector's absolute values are what the box shows.
///
/// Bound to the span and live: it opens when a Motion span is selected (the store keeps it keyed by
/// `spanID`) and every drag of a box or a corner writes the span's values as it moves, inside one
/// coalescing group (`beginDrag`, `applyDrag`, `endDrag`: one undo step per drag; Escape mid-drag
/// cancels it through the group, `cancelDrag`, and the rest of that gesture writes nothing). There is
/// no Apply or Cancel: Undo reverts a drag. The Start, End and Duration fields edit the span's range
/// (`commitRange`, limited to the clip and the free space of its lane), Smoothing its
/// interpolation, Swap exchanges the two placements (one step), and the neighbour toggles make the
/// span continue the previous clip's last frame or lead into the next clip's first frame
/// (`VEEngine.matchSpanEdge`; turning one off gives that edge the clip's own placement back).
///
/// The boxes are never cached across edits: span values are relative and cumulative (a span applies
/// on top of what the rest of the clip composes to, earlier spans' held end values included), so an
/// edit of an earlier span, an undo or a trim moves what this span shows while its own values stay.
/// Every model change reaches `update(span:clip:previous:next:)`, which re-reads both boxes and the
/// other clips' outlines. A drag converts a box to absolute values and those to relative values over
/// the base read when the drag started (the base does not depend on the span's own values, so every
/// step of the drag is exact).
@MainActor
final class KenBurnsModel: ObservableObject {
    enum Framing: CaseIterable {
        case start
        case end
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    /// The Start, End and Duration fields.
    enum RangeField: String, CaseIterable {
        case start, end, duration
    }

    /// A touching neighbour's framing at the cut (its last frame before this clip, its first after).
    struct Neighbour: Equatable {
        let clipID: VEClipID
        let framing: VEMotionFraming

        static func == (a: Neighbour, b: Neighbour) -> Bool {
            a.clipID == b.clipID && a.framing.x == b.framing.x && a.framing.y == b.framing.y
                && a.framing.scale == b.framing.scale
        }

        /// `clip`'s framing on its last frame (`atEnd`) or its first, as the monitor shows it.
        init?(_ clip: VEClipInfo?, atEnd: Bool, frameDuration: CMTime) {
            guard let clip, clip.trackKind == .video else { return nil }
            let frame = atEnd ? CMTimeSubtract(clip.timelineEnd, frameDuration) : clip.timelineStart
            let motion = clip.motion(at: frame)
            clipID = clip.clipID
            framing = VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
        }
    }

    /// Another visible clip's placement box at the playhead, outlined thinly with its track's name.
    struct Outline: Equatable {
        let clipID: VEClipID
        let trackName: String
        let box: KenBurnsBox
    }

    /// The interpolations the editor offers (FCP's smoothing choices).
    static let interpolations: [VEKeyframeInterpolation] = [.easeInOut, .easeOut, .easeIn, .linear]
    /// The smallest box a corner drag makes, as a fraction of the frame's width.
    static let minimumBoxFraction: CGFloat = 0.02
    /// The largest box a corner drag makes, in frame widths (a 1000 % zoom of a full-frame clip).
    static let maximumBoxFrames: CGFloat = 10
    /// How far a box's centre may be dragged off the frame, as a fraction of the frame's size on
    /// each side: within the margin the editor shows around the frame (`KenBurnsViewport`), so a
    /// dragged box can always be grabbed again.
    static let reachFraction: CGFloat = 0.2
    /// The coalescing group of a box drag.
    static let dragGroup = "kenBurns.drag"
    /// The caption shown while the span ends before its clip does (hold after).
    static let holdCaption = "After the move its end placement holds until the clip ends; a later move on the "
        + "clip starts from it"

    private unowned let store: ProjectStore
    let spanID: VESpanID
    /// The span and its clip as they are now (every model change passes through `update`, which
    /// publishes them: the caption and the neighbour toggles read them).
    @Published private(set) var span: VEEffectSpan
    @Published private(set) var clip: VEClipInfo
    let assetID: VEAssetID
    let sequenceSize: CGSize
    let frameDuration: CMTime
    /// The clip's picture size (the asset's display size, its container rotation applied): what the
    /// boxes fit into the frame.
    let pictureSize: CGSize

    /// The boxes as the span's edges show them (or as a drag in progress has put them), in
    /// sequence pixels.
    @Published private(set) var start: KenBurnsBox
    @Published private(set) var end: KenBurnsBox
    /// The other visible clips' boxes at `outlineTime` (the program playhead).
    @Published private(set) var outlines: [Outline] = []
    /// The time the outlines are read at: the program playhead (the monitor shows that frame).
    private(set) var outlineTime: CMTime
    /// How the span moves (its interpolation).
    @Published private(set) var interpolation: VEKeyframeInterpolation
    /// The span's range, re-published with every change of it (the fields show it).
    @Published private(set) var rangeStart: CMTime
    @Published private(set) var rangeEnd: CMTime
    /// The clip touching this one's start / end on its track (nil when there is none).
    @Published private(set) var previous: Neighbour?
    @Published private(set) var next: Neighbour?
    /// Why the last edit was refused or limited (nil when it went as asked).
    @Published private(set) var note: String?
    /// A box drag is in progress (its coalescing group is open).
    @Published private(set) var isDragging = false

    /// The drag in progress was cancelled (Escape, Undo, or an edit that ended its group): the rest
    /// of that gesture writes nothing, until it ends (`endDrag`, `gestureAbandoned`). Without it the
    /// next movement of the same gesture would open a new group and the release commit it.
    private(set) var dragCancelled = false

    /// The bases the span's values apply onto at its start and end, read when a drag starts.
    private var dragBase: (start: VESpanValues, end: VESpanValues)?

    /// Why the editor cannot open on `span` of `clip` (nil when it can): not a Motion span, a clip
    /// without a picture, a sequence without a frame size.
    static func problem(span: VEEffectSpan, clip: VEClipInfo, asset: VEAssetInfo, sequence: VESequenceInfo) -> String? {
        guard span.kind == .motion else { return "Ken Burns edits a Motion span." }
        guard clip.trackKind == .video, asset.hasVideo, asset.width > 0, asset.height > 0 else {
            return "Ken Burns works on a clip with a picture."
        }
        let frame = sequence.frameDuration
        guard sequence.width > 0, sequence.height > 0, frame.isNumeric, frame.secondsOrZero > 0 else {
            return "The sequence has no frame size."
        }
        return nil
    }

    /// Nil when the span is not a Motion span of a video clip with a picture; `reason` says why.
    /// `playhead` is the program playhead (the outlines' time).
    init?(store: ProjectStore, span: VEEffectSpan, clip: VEClipInfo, asset: VEAssetInfo, sequence: VESequenceInfo,
          playhead: CMTime, previous: VEClipInfo? = nil, next: VEClipInfo? = nil, reason: inout String) {
        if let problem = Self.problem(span: span, clip: clip, asset: asset, sequence: sequence) {
            reason = problem
            return nil
        }
        let frame = sequence.frameDuration
        self.store = store
        spanID = span.spanID
        self.span = span
        self.clip = clip
        assetID = asset.assetID
        sequenceSize = CGSize(width: sequence.width, height: sequence.height)
        pictureSize = CGSize(width: asset.width, height: asset.height)
        frameDuration = frame
        outlineTime = playhead
        interpolation = span.interpolation
        rangeStart = span.start
        rangeEnd = span.end
        start = KenBurnsBox(center: .zero, size: .zero, rotationDegrees: 0)
        end = KenBurnsBox(center: .zero, size: .zero, rotationDegrees: 0)
        self.previous = Neighbour(previous, atEnd: true, frameDuration: frame)
        self.next = Neighbour(next, atEnd: false, frameDuration: frame)
        readBoxes()
        readOutlines()
    }

    // MARK: The span and its clip

    /// The span, its clip, a neighbour or another clip changed (an edit, an undo, a trim, an edit of
    /// an earlier span, a track hidden): re-read everything the editor shows. A drag in progress
    /// keeps its boxes.
    func update(span: VEEffectSpan, clip: VEClipInfo, previous: VEClipInfo?, next: VEClipInfo?) {
        guard span.spanID == spanID else { return }
        self.span = span
        self.clip = clip
        if interpolation != span.interpolation { interpolation = span.interpolation }
        if rangeStart != span.start { rangeStart = span.start }
        if rangeEnd != span.end { rangeEnd = span.end }
        let before = Neighbour(previous, atEnd: true, frameDuration: frameDuration)
        let after = Neighbour(next, atEnd: false, frameDuration: frameDuration)
        if before != self.previous { self.previous = before }
        if after != self.next { self.next = after }
        if !isDragging { readBoxes() }
        readOutlines()
    }

    /// The Motion an edge of the span shows (static values with every started span composed on, this
    /// one at that edge), or the clip's Motion there if the engine cannot say.
    private func edgeMotion(atEnd: Bool) -> VEVideoParams {
        var motion = VEVideoParams()
        if clip.getMotion(&motion, atEdgeOfSpan: spanID, atEnd: atEnd, frameDuration: frameDuration) {
            return motion
        }
        return clip.motion(at: atEnd ? CMTimeSubtract(span.end, frameDuration) : span.start)
    }

    /// Re-reads both boxes from the span's edges.
    private func readBoxes() {
        let first = Self.box(for: edgeMotion(atEnd: false), picture: pictureSize, sequence: sequenceSize)
        let last = Self.box(for: edgeMotion(atEnd: true), picture: pictureSize, sequence: sequenceSize)
        if start != first { start = first }
        if end != last { end = last }
    }

    /// The placements the boxes give (position and scale, absolute: what the monitor shows at that
    /// edge and the inspector's Start and End values).
    var startFraming: VEMotionFraming {
        Self.motion(for: start, picture: pictureSize, sequence: sequenceSize).framing
    }

    var endFraming: VEMotionFraming {
        Self.motion(for: end, picture: pictureSize, sequence: sequenceSize).framing
    }

    func box(_ which: Framing) -> KenBurnsBox {
        which == .start ? start : end
    }

    /// The span ends before its clip does: its end placement holds after it (`holdCaption`).
    var caption: String? {
        span.end < clip.timelineEnd ? Self.holdCaption : nil
    }

    // MARK: The other clips

    /// The program playhead moved: the other clips' outlines are read at it.
    func setPlayhead(_ time: CMTime) {
        guard time != outlineTime else { return }
        outlineTime = time
        readOutlines()
    }

    private func readOutlines() {
        let found = Self.outlines(at: outlineTime, excluding: clip.clipID, store: store, sequence: sequenceSize)
        if found != outlines { outlines = found }
    }

    /// The placement box of every video clip visible at `time` except `excluded` (the edited one):
    /// clips under `time` on video tracks that are not hidden, whose media has a picture, bottom
    /// track first, each at its composed Motion there (`VEClipInfo.motion(at:)`).
    static func outlines(at time: CMTime, excluding excluded: VEClipID, store: ProjectStore,
                         sequence: CGSize) -> [Outline] {
        var found: [Outline] = []
        for trackID in store.sequence.videoTrackIDs.map(\.int64Value) {
            guard let track = store.track(trackID), !track.muted else { continue }
            let under = store.clips.values.filter {
                $0.trackID == trackID && $0.clipID != excluded && $0.timelineStart <= time && time < $0.timelineEnd
            }
            for clip in under.sorted(by: { $0.timelineStart < $1.timelineStart }) {
                guard let asset = store.asset(clip.assetID), asset.hasVideo, asset.width > 0, asset.height > 0 else {
                    continue
                }
                let picture = CGSize(width: asset.width, height: asset.height)
                found.append(Outline(clipID: clip.clipID, trackName: track.name,
                                     box: box(for: clip.motion(at: time), picture: picture, sequence: sequence)))
            }
        }
        return found
    }

    // MARK: Writing

    /// The bases the span applies onto at its edges (nil when the engine cannot say).
    private func bases() -> (start: VESpanValues, end: VESpanValues)? {
        var first = VESpanValues()
        var last = VESpanValues()
        guard clip.getBaseValues(&first, underSpan: spanID, atEnd: false, frameDuration: frameDuration),
              clip.getBaseValues(&last, underSpan: spanID, atEnd: true, frameDuration: frameDuration) else { return nil }
        return (first, last)
    }

    /// The span's relative values that make its edges show `start` and/or `end` over `base`.
    private func values(start: VEMotionFraming?, end: VEMotionFraming?,
                        base: (start: VESpanValues, end: VESpanValues)) -> (VESpanValues, VESpanValues)? {
        var from = VESpanValuesUnchanged()
        var to = VESpanValuesUnchanged()
        if let start {
            guard let relative = ProjectStore.relativeFraming(start, base: base.start) else { return nil }
            from = relative
        }
        if let end {
            guard let relative = ProjectStore.relativeFraming(end, base: base.end) else { return nil }
            to = relative
        }
        return (from, to)
    }

    private static let zeroScaleNote = "The rest of the clip has scale 0 here, so the move cannot change what it shows."

    // MARK: Drags

    /// A drag on the overlay: `target` (a box's body or corner, `KenBurnsHit`) grabbed with the box
    /// at `origin`, now `translation` (sequence pixels) from where it started. A body drag moves the
    /// box (its centre stays within `reachFraction` of the frame, or where it already was); a corner
    /// drag scales it about its centre by how far the grabbed corner moved along its diagonal (the
    /// aspect stays, between `minimumBoxFraction` and `maximumBoxFrames` of the frame's width). The
    /// first step that moves opens the drag's coalescing group; every step writes the span's values
    /// inside it. A drag that has not moved changes nothing. Refused during another gesture (a
    /// timeline drag): nothing happens and the note says why.
    func applyDrag(_ target: KenBurnsHit.Target, origin: KenBurnsBox, translation: CGSize) {
        guard translation != .zero, !dragCancelled else { return }
        if !isDragging, !beginDrag() { return }
        let box: KenBurnsBox
        switch target {
        case .body:
            box = moved(origin, by: translation)
        case let .corner(_, corner):
            box = resized(origin, corner: corner, by: translation)
        }
        write(target.framing, box)
    }

    /// Opens the drag's coalescing group (one undo step) and makes Escape cancel it; false (with the
    /// note) while another gesture is in progress.
    @discardableResult
    func beginDrag() -> Bool {
        guard !isDragging else { return true }
        guard !store.isGestureActive else {
            note = "Finish the current drag first."
            return false
        }
        guard let base = bases() else {
            note = "The span no longer exists."
            return false
        }
        store.inspector.endNudgeBurst()
        dragBase = base
        store.engine.beginCoalescing(withKey: Self.dragGroup)
        store.cancelActiveGesture = { [weak self] in self?.cancelDrag() }
        isDragging = true
        note = nil
        return true
    }

    /// Writes one box as a step of the drag.
    private func write(_ which: Framing, _ box: KenBurnsBox) {
        guard isDragging, let base = dragBase else { return }
        let framing = Self.motion(for: box, picture: pictureSize, sequence: sequenceSize).framing
        guard let (from, to) = values(start: which == .start ? framing : nil, end: which == .end ? framing : nil,
                                      base: base) else {
            note = Self.zeroScaleNote
            return
        }
        if which == .start { start = box } else { end = box }
        let result = store.engine.performInCoalescingGroup(Self.dragGroup) {
            self.store.engine.setSpanValues(self.spanID, start: from, end: to)
        }
        guard !result.ok else { return }
        note = result.message
        if result.errorCode == .busy {
            // Another edit ended the group (committing what the drag did): the drag stops, and the
            // rest of the gesture is ignored.
            finishDrag()
            dragCancelled = true
            readBoxes()
        }
    }

    /// The drag was released: its group ends (one undo step). A cancelled drag's gesture ends here
    /// too (the next gesture drags again).
    func endDrag() {
        dragCancelled = false
        guard isDragging else { return }
        if store.engine.coalescingKey == Self.dragGroup {
            store.engine.endCoalescing()
        }
        finishDrag()
        readBoxes()
    }

    /// Escape (or Undo) mid-drag, or a drag the system abandoned: reverts what the drag did. The
    /// rest of the gesture is ignored until it ends.
    func cancelDrag() {
        guard isDragging else { return }
        if store.engine.coalescingKey == Self.dragGroup {
            store.engine.cancelCoalescing()
        }
        finishDrag()
        dragCancelled = true
        readBoxes()
    }

    /// The gesture went away without a release (the system abandoned it): a drag in progress is
    /// reverted, and a cancelled one's gesture is over.
    func gestureAbandoned() {
        cancelDrag()
        dragCancelled = false
    }

    private func finishDrag() {
        isDragging = false
        dragBase = nil
        store.cancelActiveGesture = nil
    }

    /// Where a box's centre may be dragged: the frame and `reachFraction` of it around it, widened to
    /// include `center` (a box already further out is not pulled in by the first step).
    func reach(including center: CGPoint) -> CGRect {
        let frame = CGRect(origin: .zero, size: sequenceSize)
        let reach = frame.insetBy(dx: -sequenceSize.width * Self.reachFraction,
                                  dy: -sequenceSize.height * Self.reachFraction)
        return reach.union(CGRect(origin: center, size: .zero))
    }

    /// `origin` moved by `translation`, its centre kept within `reach`.
    func moved(_ origin: KenBurnsBox, by translation: CGSize) -> KenBurnsBox {
        let bounds = reach(including: origin.center)
        var box = origin
        box.center = CGPoint(x: min(max(origin.center.x + translation.width, bounds.minX), bounds.maxX),
                             y: min(max(origin.center.y + translation.height, bounds.minY), bounds.maxY))
        return box
    }

    /// `origin` scaled about its centre by dragging `corner` by `translation`: the factor is how far
    /// the corner moved along the box's diagonal through it (the aspect stays), limited to boxes
    /// between `minimumBoxFraction` and `maximumBoxFrames` of the frame's width (a box already
    /// outside those keeps its size as the limit). A box without a size (scale 0) keeps it.
    func resized(_ origin: KenBurnsBox, corner: Corner, by translation: CGSize) -> KenBurnsBox {
        let from = origin.corner(corner)
        let diagonal = CGPoint(x: from.x - origin.center.x, y: from.y - origin.center.y)
        let length = diagonal.x * diagonal.x + diagonal.y * diagonal.y
        guard length > 1e-9, origin.size.width > 0 else { return origin }
        let to = CGPoint(x: from.x + translation.width - origin.center.x,
                         y: from.y + translation.height - origin.center.y)
        let wanted = (to.x * diagonal.x + to.y * diagonal.y) / length
        let smallest = min(1, sequenceSize.width * Self.minimumBoxFraction / origin.size.width)
        let largest = max(1, sequenceSize.width * Self.maximumBoxFrames / origin.size.width)
        return origin.scaled(by: min(max(wanted, smallest), largest))
    }

    // MARK: Commands

    /// Refuses a command during a gesture; true when it may go ahead.
    private func mayEdit() -> Bool {
        guard !store.isGestureActive else {
            note = "Finish the current drag first."
            return false
        }
        store.inspector.endNudgeBurst()
        return true
    }

    /// Exchanges the start and end placements (FCP's swap button): one undo step.
    func swap() {
        guard mayEdit(), let base = bases() else { return }
        guard let (from, to) = values(start: endFraming, end: startFraming, base: base) else {
            note = Self.zeroScaleNote
            return
        }
        report(store.engine.setSpanValues(spanID, start: from, end: to))
    }

    /// Smoothing: how the span moves (one undo step).
    func setInterpolation(_ interpolation: VEKeyframeInterpolation) {
        guard mayEdit(), interpolation != span.interpolation else { return }
        report(store.engine.setSpanInterpolation(spanID, interpolation: interpolation))
    }

    private func report(_ result: VEEditResult) {
        note = result.ok ? store.notes(of: result) : result.message
        if !result.ok { store.statusMessage = result.message }
    }

    // MARK: Neighbours

    /// "Continue from previous clip" applies: a clip touches this one's start and the span starts on
    /// the clip's first frame.
    var canContinueFromPrevious: Bool { previous != nil && span.start == clip.timelineStart }

    /// The start shows the placement the previous clip ends with.
    var continuesFromPrevious: Bool {
        guard canContinueFromPrevious, let previous else { return false }
        return Self.sameFraming(edgeFraming(atEnd: false), previous.framing)
    }

    /// The end shows the placement the next clip starts with.
    var leadsIntoNext: Bool {
        guard let next else { return false }
        return Self.sameFraming(edgeFraming(atEnd: true), next.framing)
    }

    private func edgeFraming(atEnd: Bool) -> VEMotionFraming {
        let motion = edgeMotion(atEnd: atEnd)
        return VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
    }

    /// Turns "Continue from previous clip" on (the start matches the previous clip's last frame,
    /// `VEEngine.matchSpanEdge`) or off (the start shows the clip's own placement: neutral start
    /// values). One undo step.
    func setContinuesFromPrevious(_ on: Bool) {
        setFollows(.start, on)
    }

    /// Turns "Lead into next clip" on (the end matches the next clip's first frame) or off (the end
    /// shows the clip's own placement). One undo step.
    func setLeadsIntoNext(_ on: Bool) {
        setFollows(.end, on)
    }

    private func setFollows(_ edge: VEClipEdge, _ on: Bool) {
        guard mayEdit() else { return }
        if on {
            report(store.matchSpanEdge(spanID, edge))
            return
        }
        var neutral = VESpanValuesUnchanged()
        neutral.x = 0
        neutral.y = 0
        neutral.scale = 1
        let unchanged = VESpanValuesUnchanged()
        report(store.engine.setSpanValues(spanID, start: edge == .start ? neutral : unchanged,
                                          end: edge == .end ? neutral : unchanged))
    }

    /// Two framings the same within a millionth (the engine's `motionValuesMatch`).
    static func sameFraming(_ a: VEMotionFraming, _ b: VEMotionFraming) -> Bool {
        func same(_ u: Double, _ v: Double) -> Bool { abs(u - v) <= 1e-6 * max(1, abs(u), abs(v)) }
        return same(a.x, b.x) && same(a.y, b.y) && same(a.scale, b.scale)
    }

    // MARK: Range

    /// A range field's value in the user's duration format: the span's start and end as timeline
    /// times (the end is where the end placement is reached), its length.
    func rangeText(_ field: RangeField) -> String {
        switch field {
        case .start: return store.timelineTimeString(rangeStart)
        case .end: return store.timelineTimeString(rangeEnd)
        case .duration: return store.durationString(frames: store.frames(CMTimeSubtract(rangeEnd, rangeStart)))
        }
    }

    /// Takes a typed Start, End or Duration (parsed like every duration field: timecode, 150f, 5s,
    /// a bare number in the display's unit): the other end stays (Duration moves the end), limited
    /// to the clip and the free space of the lane (`ProjectStore.setSpanRange`; `note` says so).
    /// Text that is not a time is refused with the note. Returns whether it was taken.
    @discardableResult
    func commitRange(_ field: RangeField, _ text: String) -> Bool {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return true }
        guard let frames = DurationFormat.parseFrames(typed, frameDuration: frameDuration,
                                                      display: store.editingPreferences.durationDisplay) else {
            note = "“\(typed)” is not a time (use timecode like 00:00:05:00, frames like 150f or seconds like 5s)."
            return false
        }
        return setRange(field, frames: frames)
    }

    /// Up/Down in a range field: that end (Duration: the end) moves `steps` frames.
    func nudgeRange(_ field: RangeField, steps: Double) {
        let current: Int64
        switch field {
        case .start: current = store.frames(rangeStart)
        case .end: current = store.frames(rangeEnd)
        case .duration: current = store.frames(CMTimeSubtract(rangeEnd, rangeStart))
        }
        setRange(field, frames: max(0, current + Int64(steps)))
    }

    @discardableResult
    private func setRange(_ field: RangeField, frames: Int64) -> Bool {
        guard mayEdit() else { return false }
        var from = rangeStart
        var to = rangeEnd
        switch field {
        case .start: from = store.time(frames: frames)
        case .end: to = store.time(frames: frames)
        case .duration: to = CMTimeAdd(rangeStart, store.time(frames: frames))
        }
        let (ok, text) = store.setSpanRange(spanID, start: from, end: to, typed: field == .start ? .start : .end)
        note = text
        return ok
    }

    // MARK: Geometry

    /// The picture (display size `picture`) fitted into the frame, centred with its aspect kept: its
    /// size as the compositor places a clip with identity values.
    static func fittedSize(picture: CGSize, sequence: CGSize) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        let fit = min(sequence.width / picture.width, sequence.height / picture.height)
        return CGSize(width: picture.width * fit, height: picture.height * fit)
    }

    /// The placement box of a clip whose picture is `picture` (display size) with the Motion values
    /// `params`, in sequence pixels (origin at the frame's top-left corner, +y down): the fitted
    /// picture scaled about its centre by `params.scale`, its centre moved by `params.x`/`params.y`
    /// from the frame's centre, turned clockwise by `params.rotationDegrees` about its centre (the
    /// compositor's order). A scale of 0 or less gives an empty box at the centre.
    static func box(for params: VEVideoParams, picture: CGSize, sequence: CGSize) -> KenBurnsBox {
        let fitted = fittedSize(picture: picture, sequence: sequence)
        let scale = params.scale.isFinite ? max(0, params.scale) : 0
        return KenBurnsBox(center: CGPoint(x: sequence.width / 2 + params.x, y: sequence.height / 2 + params.y),
                           size: CGSize(width: fitted.width * scale, height: fitted.height * scale),
                           rotationDegrees: params.rotationDegrees)
    }

    /// The inverse of `box(for:picture:sequence:)`: the position, scale and rotation that place the
    /// picture in `box` (the scale from its width against the fitted picture's).
    static func motion(for box: KenBurnsBox, picture: CGSize,
                       sequence: CGSize) -> (framing: VEMotionFraming, rotationDegrees: Double) {
        let fitted = fittedSize(picture: picture, sequence: sequence)
        let scale = fitted.width > 0 ? Double(box.size.width / fitted.width) : 0
        return (VEMotionFraming(x: box.center.x - sequence.width / 2, y: box.center.y - sequence.height / 2,
                                scale: scale), box.rotationDegrees)
    }
}

/// A clip's placement box: a rectangle of `size` centred on `center`, turned clockwise by
/// `rotationDegrees` about its centre (+y down, so clockwise on screen). In sequence pixels in the
/// model and in view points on the overlay (`KenBurnsViewport.view(_:)`).
struct KenBurnsBox: Equatable {
    var center: CGPoint
    var size: CGSize
    var rotationDegrees: Double

    private var theta: Double { rotationDegrees * .pi / 180 }

    /// A point given relative to the centre in the box's own (unturned) axes, on the page.
    func point(local: CGPoint) -> CGPoint {
        let c = cos(theta)
        let s = sin(theta)
        return CGPoint(x: center.x + c * local.x - s * local.y, y: center.y + s * local.x + c * local.y)
    }

    /// `point` relative to the centre in the box's own (unturned) axes.
    func local(_ point: CGPoint) -> CGPoint {
        let c = cos(theta)
        let s = sin(theta)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: c * dx + s * dy, y: -s * dx + c * dy)
    }

    /// A corner, turned with the box (the top-left is the picture's top-left corner).
    func corner(_ corner: KenBurnsModel.Corner) -> CGPoint {
        let w = size.width / 2
        let h = size.height / 2
        switch corner {
        case .topLeft: return point(local: CGPoint(x: -w, y: -h))
        case .topRight: return point(local: CGPoint(x: w, y: -h))
        case .bottomRight: return point(local: CGPoint(x: w, y: h))
        case .bottomLeft: return point(local: CGPoint(x: -w, y: h))
        }
    }

    /// The four corners, clockwise from the top-left.
    var corners: [CGPoint] {
        KenBurnsModel.Corner.allCases.map { corner($0) }
    }

    /// The box `factor` times larger about its centre.
    func scaled(by factor: CGFloat) -> KenBurnsBox {
        KenBurnsBox(center: center, size: CGSize(width: size.width * factor, height: size.height * factor),
                    rotationDegrees: rotationDegrees)
    }
}

/// Where the program picture sits in the monitor while the Ken Burns editor is open, and the
/// mapping between monitor points and sequence pixels: the frame fitted (aspect kept, centred)
/// inside the monitor less `margin` of its width on the left and right and of its height at the top
/// and bottom. The margin stands for the space off the frame, so a box larger than the frame or
/// partly off it keeps its corners and body on screen. With a margin of 0 it is the monitor's usual
/// letterbox fit.
struct KenBurnsViewport: Equatable {
    /// The margin on each side while the editor is open, as a fraction of the monitor's size.
    static let marginFraction: CGFloat = 0.15

    let monitor: CGSize
    /// The frame's rectangle in the monitor (points).
    let frame: CGRect
    /// Points per sequence pixel.
    let scale: CGFloat

    init(sequence: CGSize, monitor: CGSize, margin: CGFloat = KenBurnsViewport.marginFraction) {
        self.monitor = monitor
        let inner = CGSize(width: max(0, monitor.width * (1 - 2 * margin)),
                           height: max(0, monitor.height * (1 - 2 * margin)))
        let fit = sequence.width > 0 && sequence.height > 0
            ? min(inner.width / sequence.width, inner.height / sequence.height) : 0
        scale = max(fit, 1e-6)
        let size = CGSize(width: sequence.width * fit, height: sequence.height * fit)
        frame = CGRect(x: (monitor.width - size.width) / 2, y: (monitor.height - size.height) / 2, width: size.width,
                       height: size.height)
    }

    /// Sequence pixels to monitor points.
    func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale)
    }

    /// A box in monitor points (a uniform scale keeps its rotation).
    func view(_ box: KenBurnsBox) -> KenBurnsBox {
        KenBurnsBox(center: view(box.center),
                    size: CGSize(width: box.size.width * scale, height: box.size.height * scale),
                    rotationDegrees: box.rotationDegrees)
    }

    /// Monitor points to sequence pixels.
    func sequence(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
    }

    /// A distance in monitor points to sequence pixels.
    func sequence(_ size: CGSize) -> CGSize {
        CGSize(width: size.width / scale, height: size.height / scale)
    }
}

/// What a press on the Ken Burns overlay grabs, from the two boxes as drawn (view points). The end
/// box is drawn over the start, and with the default push in, or an unanimated clip, the two nest or
/// coincide; so the grab is decided by geometry, not by which is on top: the nearest corner handle,
/// then a box's label (the start's inside its top-left corner, the end's inside its bottom-right),
/// then the nearest edge (a band either side of each edge), then the inside of a box (inside both:
/// the smaller one, whose edges are the nearer). Where the two coincide the start owns the top and
/// left corners and edges, the end the bottom and right, and the inside drags the end. Corners,
/// labels and edges turn with a turned box (the tests are made in each box's own axes).
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

    /// How far from a corner a press grabs it, and from an edge a press grabs the box.
    static let cornerRadius: CGFloat = 8
    static let edgeBand: CGFloat = 6
    /// The labels' hit areas.
    static let labelSize = CGSize(width: 40, height: 16)

    /// Where a box's label is, in the box's own axes relative to its centre (inside it: the start's
    /// at the top-left, the end's at the bottom-right).
    static func labelRect(_ which: KenBurnsModel.Framing, of box: KenBurnsBox) -> CGRect {
        let w = box.size.width / 2
        let h = box.size.height / 2
        return which == .start
            ? CGRect(origin: CGPoint(x: -w, y: -h), size: labelSize)
            : CGRect(x: w - labelSize.width, y: h - labelSize.height, width: labelSize.width, height: labelSize.height)
    }

    /// The target at `point`, or nil (outside both boxes and their handles).
    static func target(at point: CGPoint, start: KenBurnsBox, end: KenBurnsBox) -> Target? {
        let boxes: [(KenBurnsModel.Framing, KenBurnsBox)] = [(.start, start), (.end, end)]
        // Corners: the nearest within reach. On a tie (the boxes coincide there) the start takes the
        // left corners and the end the right ones.
        var corners: [(target: Target, distance: CGFloat, owner: Bool)] = []
        for (which, box) in boxes {
            for corner in KenBurnsModel.Corner.allCases {
                let c = box.corner(corner)
                let distance = hypot(point.x - c.x, point.y - c.y)
                guard distance <= cornerRadius else { continue }
                let left = corner == .topLeft || corner == .bottomLeft
                corners.append((.corner(which, corner), distance, (which == .start) == left))
            }
        }
        if let target = nearest(corners) { return target }
        // Labels (each inside its own box, away from the other's).
        for (which, box) in boxes where labelRect(which, of: box).contains(box.local(point)) {
            return .body(which)
        }
        // Edges: the nearest within the band either side. On a tie the start takes the top and left
        // edges and the end the bottom and right ones.
        var edges: [(target: Target, distance: CGFloat, owner: Bool)] = []
        for (which, box) in boxes {
            let p = box.local(point)
            let w = box.size.width / 2
            let h = box.size.height / 2
            guard p.x >= -w - edgeBand, p.x <= w + edgeBand, p.y >= -h - edgeBand, p.y <= h + edgeBand else { continue }
            let sides: [(CGFloat, Bool)] = [ // (distance, a top or left edge)
                (abs(p.x + w), true), (abs(p.y + h), true), (abs(p.x - w), false), (abs(p.y - h), false),
            ]
            for (distance, topOrLeft) in sides where distance <= edgeBand {
                edges.append((.body(which), distance, (which == .start) == topOrLeft))
            }
        }
        if let target = nearest(edges) { return target }
        // Inside: one box, or the smaller of the two (the end when they coincide).
        let inside = boxes.filter { _, box in
            let p = box.local(point)
            return abs(p.x) <= box.size.width / 2 && abs(p.y) <= box.size.height / 2
        }
        if inside.count == 1 { return .body(inside[0].0) }
        if inside.count == 2 {
            return .body(start.size.width * start.size.height < end.size.width * end.size.height ? .start : .end)
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
