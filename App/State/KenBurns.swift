import CoreGraphics
import CoreMedia
import Foundation
import FramewrightEngine

/// The Ken Burns editor (Final Cut Pro's "Ken Burns" crop mode) of one Motion span: a start
/// rectangle (green) and an end rectangle (red) drawn over the whole picture on the program
/// monitor. Each rectangle is the part of the picture that fills the frame at that edge of the span
/// (its start, and its end, where the end framing is reached).
///
/// Bound to the span and live: it opens when a Motion span is selected (the store keeps it keyed by
/// `spanID`) and every drag of a rectangle or a corner writes the span's values as it moves, inside
/// one coalescing group (`beginDrag`, `applyDrag`, `endDrag`: one undo step per drag; Escape mid-drag
/// cancels it through the group, `cancelDrag`). There is no Apply or Cancel: Undo reverts a drag.
/// The Start, End and Duration fields edit the span's range (`commitRange`, limited to the clip and
/// the free space of its lane), Smoothing its interpolation, Swap exchanges the two framings (one
/// step), and the neighbour toggles make the span continue the previous clip's last frame or lead
/// into the next clip's first frame (`VEEngine.matchSpanEdge`; turning one off gives that edge the
/// clip's own framing back).
///
/// The rectangles are never cached across edits: span values are relative and cumulative (a span
/// applies on top of what the rest of the clip composes to, earlier spans' held end values
/// included), so an edit of an earlier span, an undo or a trim moves what this span shows while its
/// own values stay. Every model change reaches `update(clip:previous:next:)`, which re-reads both
/// framings (`VEClipInfo.getMotion(_:atEdgeOfSpan:)`) and the bases the span applies onto
/// (`getBaseValues`). A drag converts a rectangle to a framing and the framing to the span's
/// relative values over the base read when the drag started (the base does not depend on the
/// span's own values, so every step of the drag is exact).
///
/// The picture under the rectangles follows the playhead, as in FCP: the clip's unanimated frame at
/// the playhead, clamped to the span's range (its first frame before it, its last frame after it),
/// loaded and paced by `KenBurnsPictureLoader`.
///
/// Geometry, in sequence pixels (origin at the frame's top-left corner, +y down): the picture is
/// shown as the compositor fits it at scale 1 and no offset (`pictureBounds`). A rectangle keeps
/// the sequence's aspect ratio (FCP locks it too), stays inside the picture while it is dragged (so
/// the frame never shows past the picture's edge) and is at least a tenth of the frame wide (a
/// 1000 % zoom). The clip's rotation is kept: a rectangle frames the unrotated picture and the frame
/// shows it turned by the rotation at that edge of the span.
///
/// A clip placed smaller, off centre or turned (its static framing S, e.g. a picture in picture at
/// 30 % in the lower right) is framed inside its own window, as Final Cut's Ken Burns crops the
/// clip's own picture within the clip's framing: the window is the frame box through S
/// (`clipWindow`, outlined on the monitor with `windowCaption`), and a rectangle is the part of the
/// picture that fills that window. An edge's composed motion M is expressed relative to S,
/// Φ = (R(-θs)(xm - xs, ym - ys) / ss, sm / ss, θm - θs) (`windowFraming`), and a rectangle from
/// `rect(for: Φ)`; a dragged rectangle's Φ' goes back to the frame as
/// M' = (xs + ss R(θs) Φ'.xy, ss Φ'.scale, θs + Φ'.rotation) (`absoluteFraming`) and then to the
/// span's relative values over its base (`ProjectStore.relativeFraming`). For a clip with no static
/// framing (S the identity) Φ = M. The engine has no crop: a zoom in on a picture in picture
/// enlarges it about its centre rather than cropping inside its window (a user decision, see the
/// effect lanes review, C1).
@MainActor
final class KenBurnsModel: ObservableObject {
    enum Framing: CaseIterable {
        case start
        case end
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
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

    /// The interpolations the editor offers (FCP's smoothing choices).
    static let interpolations: [VEKeyframeInterpolation] = [.easeInOut, .easeOut, .easeIn, .linear]
    /// The smallest rectangle, as a fraction of the frame's width (a 1000 % zoom).
    static let minimumWidthFraction = 0.1
    /// The coalescing group of a rectangle drag.
    static let dragGroup = "kenBurns.drag"
    /// The caption shown while the span ends before its clip does (hold after).
    static let holdCaption = "After the move its end framing holds until the clip ends; a later move on the "
        + "clip starts from it"

    private unowned let store: ProjectStore
    let spanID: VESpanID
    /// The span and its clip as they are now (every model change passes through `update`, which
    /// publishes them: the caption, the neighbour toggles and the picture's time read them).
    @Published private(set) var span: VEEffectSpan
    @Published private(set) var clip: VEClipInfo
    /// The clip's static framing (S): the window the rectangles frame the picture in.
    @Published private(set) var staticFraming: VEVideoParams
    let assetID: VEAssetID
    let sequenceSize: CGSize
    let frameDuration: CMTime
    /// The picture as the compositor fits it into the frame at scale 1, no offset.
    let pictureBounds: CGRect
    /// Loads the picture under the rectangles.
    let picture: KenBurnsPictureLoader?

    /// The rectangles as the span's edges show them (or as a drag in progress has put them).
    @Published private(set) var start: CGRect = .zero
    @Published private(set) var end: CGRect = .zero
    /// The rotation the picture has inside the clip's window at each edge (the edge's rotation less
    /// the static one; a rectangle's framing turns the picture by it).
    @Published private(set) var startRotation: Double = 0
    @Published private(set) var endRotation: Double = 0
    /// How the span moves (its interpolation).
    @Published private(set) var interpolation: VEKeyframeInterpolation
    /// The span's range, re-published with every change of it (the fields show it).
    @Published private(set) var rangeStart: CMTime
    @Published private(set) var rangeEnd: CMTime
    /// The clip touching this one's start / end on its track (nil when there is none).
    @Published private(set) var previous: Neighbour?
    @Published private(set) var next: Neighbour?
    /// The program playhead (the picture follows it).
    @Published private(set) var playhead: CMTime
    /// Why the last edit was refused or limited (nil when it went as asked).
    @Published private(set) var note: String?
    /// A rectangle drag is in progress (its coalescing group is open).
    @Published private(set) var isDragging = false

    /// The drag in progress was cancelled (Escape, Undo, or an edit that ended its group): the rest
    /// of that gesture writes nothing, until it ends (`endDrag`, `gestureAbandoned`). Without it the
    /// next movement of the same gesture would open a new group and the release commit it.
    private(set) var dragCancelled = false

    /// The bases the span's values apply onto at its start and end, read when a drag starts.
    private var dragBase: (start: VESpanValues, end: VESpanValues)?

    /// Nil when the span is not a Motion span of a video clip with a picture; `reason` says why.
    init?(store: ProjectStore, span: VEEffectSpan, clip: VEClipInfo, asset: VEAssetInfo, sequence: VESequenceInfo,
          playhead: CMTime, picture: KenBurnsPictureLoader? = nil, previous: VEClipInfo? = nil,
          next: VEClipInfo? = nil, reason: inout String) {
        guard span.kind == .motion else {
            reason = "Ken Burns edits a Motion span."
            return nil
        }
        guard clip.trackKind == .video, asset.hasVideo, asset.width > 0, asset.height > 0 else {
            reason = "Ken Burns works on a clip with a picture."
            return nil
        }
        let frame = sequence.frameDuration
        guard sequence.width > 0, sequence.height > 0, frame.isNumeric, frame.secondsOrZero > 0 else {
            reason = "The sequence has no frame size."
            return nil
        }
        self.store = store
        spanID = span.spanID
        self.span = span
        self.clip = clip
        assetID = asset.assetID
        sequenceSize = CGSize(width: sequence.width, height: sequence.height)
        frameDuration = frame
        self.picture = picture
        self.playhead = playhead
        interpolation = span.interpolation
        rangeStart = span.start
        rangeEnd = span.end
        pictureBounds = Self.fittedPicture(width: Double(asset.width), height: Double(asset.height), in: sequenceSize)
        staticFraming = clip.videoParams
        self.previous = Neighbour(previous, atEnd: true, frameDuration: frame)
        self.next = Neighbour(next, atEnd: false, frameDuration: frame)
        readFramings()
    }

    // MARK: The span and its clip

    /// The span, its clip or a neighbour changed (an edit, an undo, a trim, an edit of an earlier
    /// span): re-read everything the editor shows. A drag in progress keeps its rectangles.
    func update(span: VEEffectSpan, clip: VEClipInfo, previous: VEClipInfo?, next: VEClipInfo?) {
        guard span.spanID == spanID else { return }
        self.span = span
        self.clip = clip
        let framing = clip.videoParams
        if !Self.sameParams(framing, staticFraming) { staticFraming = framing }
        if interpolation != span.interpolation { interpolation = span.interpolation }
        if rangeStart != span.start { rangeStart = span.start }
        if rangeEnd != span.end { rangeEnd = span.end }
        let before = Neighbour(previous, atEnd: true, frameDuration: frameDuration)
        let after = Neighbour(next, atEnd: false, frameDuration: frameDuration)
        if before != self.previous { self.previous = before }
        if after != self.next { self.next = after }
        if !isDragging { readFramings() }
    }

    /// The Motion an edge of the span shows (what a Ken Burns move sets), or the clip's framing
    /// there if the engine cannot say.
    private func edgeMotion(atEnd: Bool) -> VEVideoParams {
        var motion = VEVideoParams()
        if clip.getMotion(&motion, atEdgeOfSpan: spanID, atEnd: atEnd, frameDuration: frameDuration) {
            return motion
        }
        return clip.motion(at: atEnd ? CMTimeSubtract(span.end, frameDuration) : span.start)
    }

    /// Re-reads both rectangles from the span's edges, inside the clip's window.
    private func readFramings() {
        let first = Self.windowFraming(edgeMotion(atEnd: false), in: staticFraming)
        let last = Self.windowFraming(edgeMotion(atEnd: true), in: staticFraming)
        let startRect = Self.rect(for: first.framing, sequence: sequenceSize, rotationDegrees: first.rotationDegrees)
        let endRect = Self.rect(for: last.framing, sequence: sequenceSize, rotationDegrees: last.rotationDegrees)
        if start != startRect { start = startRect }
        if end != endRect { end = endRect }
        if startRotation != first.rotationDegrees { startRotation = first.rotationDegrees }
        if endRotation != last.rotationDegrees { endRotation = last.rotationDegrees }
    }

    /// The framings the rectangles give on screen (position and scale, the clip's static framing
    /// included: what the monitor shows at that edge).
    var startFraming: VEMotionFraming {
        absoluteFraming(start, rotationDegrees: startRotation)
    }

    var endFraming: VEMotionFraming {
        absoluteFraming(end, rotationDegrees: endRotation)
    }

    /// The on-screen framing that makes `rect` fill the clip's window.
    private func absoluteFraming(_ rect: CGRect, rotationDegrees: Double) -> VEMotionFraming {
        Self.absoluteFraming(Self.framing(for: rect, sequence: sequenceSize, rotationDegrees: rotationDegrees),
                             in: staticFraming)
    }

    // MARK: The clip's window

    /// The clip's window: the frame box through its static framing, before its rotation (centre and
    /// size, in sequence pixels); nil for a clip without a static framing (it fills the frame).
    var clipWindow: CGRect? {
        guard !Self.isIdentity(staticFraming) else { return nil }
        let scale = staticFraming.scale
        let size = CGSize(width: sequenceSize.width * scale, height: sequenceSize.height * scale)
        return CGRect(x: sequenceSize.width / 2 + staticFraming.x - size.width / 2,
                      y: sequenceSize.height / 2 + staticFraming.y - size.height / 2, width: size.width,
                      height: size.height)
    }

    /// The window's corners (top-left, top-right, bottom-right, bottom-left) turned by the static
    /// rotation about its centre, as the compositor turns the clip; empty without a window.
    var clipWindowCorners: [CGPoint] {
        guard let window = clipWindow else { return [] }
        let theta = staticFraming.rotationDegrees * .pi / 180
        let centre = CGPoint(x: window.midX, y: window.midY)
        return [CGPoint(x: window.minX, y: window.minY), CGPoint(x: window.maxX, y: window.minY),
                CGPoint(x: window.maxX, y: window.maxY), CGPoint(x: window.minX, y: window.maxY)].map { corner in
            let dx = Double(corner.x - centre.x)
            let dy = Double(corner.y - centre.y)
            return CGPoint(x: Double(centre.x) + cos(theta) * dx - sin(theta) * dy,
                           y: Double(centre.y) + sin(theta) * dx + cos(theta) * dy)
        }
    }

    /// What the window outline's caption says ("Inside the clip's framing: 30 %, lower right");
    /// nil without a window.
    var windowCaption: String? {
        Self.windowCaption(for: staticFraming)
    }

    static func windowCaption(for framing: VEVideoParams) -> String? {
        guard !isIdentity(framing) else { return nil }
        let percent = framing.scale * 100
        let scaleText = abs(percent - percent.rounded()) < 0.05
            ? String(Int(percent.rounded())) : String(format: "%.1f", percent)
        var parts = ["\(scaleText) %"]
        let horizontal = framing.x > 0.5 ? "right" : framing.x < -0.5 ? "left" : nil
        let vertical = framing.y > 0.5 ? "lower" : framing.y < -0.5 ? "upper" : nil
        switch (vertical, horizontal) {
        case let (v?, h?): parts.append("\(v) \(h)")
        case let (v?, nil): parts.append(v == "lower" ? "below centre" : "above centre")
        case let (nil, h?): parts.append("\(h) of centre")
        case (nil, nil): parts.append("centred")
        }
        let degrees = framing.rotationDegrees
        if abs(degrees) > 1e-9 {
            let text = abs(degrees - degrees.rounded()) < 0.05 ? String(Int(degrees.rounded()))
                : String(format: "%.1f", degrees)
            parts.append("turned \(text)°")
        }
        return "Inside the clip's framing: " + parts.joined(separator: ", ")
    }

    /// No static framing: centred, full size, unturned.
    static func isIdentity(_ framing: VEVideoParams) -> Bool {
        framing.x == 0 && framing.y == 0 && framing.scale == 1 && framing.rotationDegrees == 0
    }

    private static func sameParams(_ a: VEVideoParams, _ b: VEVideoParams) -> Bool {
        a.x == b.x && a.y == b.y && a.scale == b.scale && a.rotationDegrees == b.rotationDegrees
    }

    /// `motion` (an edge's composed framing, as the monitor shows it) relative to the clip's window
    /// `window` (its static framing S): Φ = (R(-θs)(xm - xs, ym - ys) / ss, sm / ss), and the
    /// rotation inside the window θm - θs. The identity window gives `motion` back.
    static func windowFraming(_ motion: VEVideoParams,
                              in window: VEVideoParams) -> (framing: VEMotionFraming, rotationDegrees: Double) {
        let scale = windowScale(window)
        let theta = window.rotationDegrees * .pi / 180
        let dx = motion.x - window.x
        let dy = motion.y - window.y
        let x = (cos(theta) * dx + sin(theta) * dy) / scale
        let y = (-sin(theta) * dx + cos(theta) * dy) / scale
        return (VEMotionFraming(x: x, y: y, scale: motion.scale / scale),
                motion.rotationDegrees - window.rotationDegrees)
    }

    /// The inverse of `windowFraming`: the on-screen framing of `framing` inside `window`,
    /// M = (xs + ss R(θs) Φ.xy, ss Φ.scale).
    static func absoluteFraming(_ framing: VEMotionFraming, in window: VEVideoParams) -> VEMotionFraming {
        let scale = windowScale(window)
        let theta = window.rotationDegrees * .pi / 180
        let x = window.x + scale * (cos(theta) * framing.x - sin(theta) * framing.y)
        let y = window.y + scale * (sin(theta) * framing.x + cos(theta) * framing.y)
        return VEMotionFraming(x: x, y: y, scale: scale * framing.scale)
    }

    /// The window's scale, 1 for a window of scale 0 (the clip is invisible; the span cannot change
    /// that, `zeroScaleNote`), so the rectangles stay finite.
    private static func windowScale(_ window: VEVideoParams) -> Double {
        window.scale.isFinite && abs(window.scale) > 1e-12 ? window.scale : 1
    }

    /// The span ends before its clip does: its end framing holds after it (`holdCaption`).
    var caption: String? {
        span.end < clip.timelineEnd ? Self.holdCaption : nil
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

    /// A drag on the overlay: `target` (a rectangle's body or corner, `KenBurnsHit`) grabbed with the
    /// rectangle at `origin`, now `translation` from where it started and at `location` (sequence
    /// pixels). The first step that moves opens the drag's coalescing group; every step writes the
    /// span's values inside it. A drag that has not moved changes nothing. Refused during another
    /// gesture (a timeline drag): nothing happens and the note says why.
    func applyDrag(_ target: KenBurnsHit.Target, origin: CGRect, translation: CGSize, location: CGPoint) {
        guard translation != .zero, !dragCancelled else { return }
        if !isDragging, !beginDrag() { return }
        let rect: CGRect
        switch target {
        case .body:
            rect = constrained(origin.offsetBy(dx: translation.width, dy: translation.height))
        case let .corner(_, corner):
            rect = resized(origin, corner: corner, to: location)
        }
        write(target.framing, rect)
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

    /// Writes one rectangle as a step of the drag.
    private func write(_ which: Framing, _ rect: CGRect) {
        guard isDragging, let base = dragBase else { return }
        let framing = absoluteFraming(rect, rotationDegrees: which == .start ? startRotation : endRotation)
        guard let (from, to) = values(start: which == .start ? framing : nil, end: which == .end ? framing : nil,
                                      base: base) else {
            note = Self.zeroScaleNote
            return
        }
        if which == .start { start = rect } else { end = rect }
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
            readFramings()
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
        readFramings()
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
        readFramings()
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

    /// Exchanges the start and end framings (FCP's swap button): one undo step.
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

    /// The start shows the framing the previous clip ends with.
    var continuesFromPrevious: Bool {
        guard canContinueFromPrevious, let previous else { return false }
        return Self.sameFraming(edgeFraming(atEnd: false), previous.framing)
    }

    /// The end shows the framing the next clip starts with.
    var leadsIntoNext: Bool {
        guard let next else { return false }
        return Self.sameFraming(edgeFraming(atEnd: true), next.framing)
    }

    private func edgeFraming(atEnd: Bool) -> VEMotionFraming {
        let motion = edgeMotion(atEnd: atEnd)
        return VEMotionFraming(x: motion.x, y: motion.y, scale: motion.scale)
    }

    /// Turns "Continue from previous clip" on (the start matches the previous clip's last frame,
    /// `VEEngine.matchSpanEdge`) or off (the start shows the clip's own framing: neutral start
    /// values). One undo step.
    func setContinuesFromPrevious(_ on: Bool) {
        setFollows(.start, on)
    }

    /// Turns "Lead into next clip" on (the end matches the next clip's first frame) or off (the end
    /// shows the clip's own framing). One undo step.
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
    /// times (the end is where the end framing is reached), its length.
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

    // MARK: Picture

    /// The playhead moved: the picture follows it.
    func setPlayhead(_ time: CMTime) {
        guard time != playhead else { return }
        playhead = time
    }

    /// Frames of `time` from zero on the sequence's frame grid (the frame containing it).
    private func frameIndex(_ time: CMTime) -> Int64 {
        let frame = frameDuration.secondsOrZero
        guard frame > 0 else { return 0 }
        return Int64((time.secondsOrZero / frame + 1e-6).rounded(.down))
    }

    /// The clip's frame the picture under the rectangles shows: the one under the playhead, clamped
    /// to the span's range (its first frame before it, its last frame after it) and to the clip.
    var pictureFrame: CMTime {
        let first = max(frameIndex(span.start), frameIndex(clip.timelineStart))
        let last = max(first, min(frameIndex(span.end), frameIndex(clip.timelineEnd)) - 1)
        let frame = min(max(frameIndex(playhead), first), last)
        return CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frame))
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

    /// `original` resized by dragging `corner` to `point` (sequence pixels): the opposite corner
    /// stays, the aspect ratio stays the frame's, and the rectangle stays inside the picture and
    /// within the size limits.
    func resized(_ original: CGRect, corner: Corner, to point: CGPoint) -> CGRect {
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
        return constrained(rect)
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

/// Loads the Ken Burns editor's picture, paced for scrubbing, with a small cache of its own: the
/// pictures are large (up to `maxDimension`, several MB each) and belong to the editor alone, so they
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

    /// Pictures from `engine` (held weakly: the editor never keeps a closed project's engine).
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
