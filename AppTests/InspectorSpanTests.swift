import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The inspector's span section (effect lanes round 2, item 3): the values an effect span's edges
/// show are absolute (the base the rest of the clip composes to there with the span's own value on
/// it) and round-trip through the relative storage for Motion, Opacity (a fade from 0 included) and
/// Gain; they are re-read after an earlier span changes; the range fields are limited to the clip
/// and the free space of the lane with a note; interpolation, lane and matching a neighbour; the
/// transition section's shares of the cut; the Video section's static values. The long movie is
/// 10 s (300 frames) at 30 fps on a 1920x1080 sequence.
@MainActor
final class InspectorSpanTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "inspector-span-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }
    private var inspector: InspectorModel { store.inspector }
    private var v1: VETrackID { store.videoTracks.first?.trackID ?? 0 }
    private var a1: VETrackID { store.audioTracks.first?.trackID ?? 0 }

    private func frames(_ n: Int64) -> CMTime {
        CMTime(value: n, timescale: 30)
    }

    private func longClip() async throws -> VEClipID {
        let url = fixture.directory.appendingPathComponent("long.mov")
        try TestMediaFactory.writeMovie(to: url, frames: 300)
        let imported: [VEAssetInfo] = await withCheckedContinuation { continuation in
            store.importMedia([url]) { continuation.resume(returning: $0) }
        }
        return try fixture.placeMovie(try XCTUnwrap(imported.first), at: 0)
    }

    @discardableResult
    private func addSpan(_ kind: VESpanKind, lane: Int, clip: VEClipID, _ start: Int64, _ end: Int64,
                         startValues: VESpanValues = VESpanValuesUnchanged(),
                         endValues: VESpanValues = VESpanValuesUnchanged()) throws -> VESpanID {
        let added = store.engine.addSpan(kind: kind, lane: lane, clip: clip,
                                         range: CMTimeRange(start: frames(start), end: frames(end)))
        let id = try XCTUnwrap(added.span, added.message).spanID
        let fields: [(VESpanValues) -> Double] = [\.x, \.y, \.scale, \.rotationDegrees, \.opacity, \.gainDb]
        if fields.contains(where: { !$0(startValues).isNaN || !$0(endValues).isNaN }) {
            XCTAssertTrue(store.engine.setSpanValues(id, start: startValues, end: endValues).ok)
        }
        store.refreshModel()
        return id
    }

    private func values(x: Double = .nan, scale: Double = .nan, opacity: Double = .nan,
                        gainDb: Double = .nan) -> VESpanValues {
        var v = VESpanValuesUnchanged()
        v.x = x
        v.scale = scale
        v.opacity = opacity
        v.gainDb = gainDb
        return v
    }

    private func span(_ id: VESpanID) throws -> VEEffectSpan {
        try XCTUnwrap(store.engine.spanInfo(id))
    }

    // MARK: Values

    func testMotionValuesAreAbsoluteAndRoundTripThroughTheRelativeStorage() async throws {
        let clip = try await longClip()
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 40, y: 0, scale: 1.5, rotationDegrees: 0, opacity: 1),
                                                  forClip: clip).ok)
        // Lane 1: a zoom 1 -> 2 over [0, 60), holding 2 after it; lane 2: a move over [30, 90).
        let zoom = try addSpan(.motion, lane: 1, clip: clip, 0, 60, startValues: values(scale: 1),
                               endValues: values(scale: 2))
        let move = try addSpan(.motion, lane: 2, clip: clip, 30, 90, startValues: values(x: 0, scale: 1),
                               endValues: values(x: 100, scale: 1))
        store.select(span: move)
        XCTAssertEqual(inspector.span?.spanID, move)
        XCTAssertNil(inspector.transition)
        let shown = try span(move)
        // Its start: the static 1.5 times the zoom halfway (1.5); its end: times the zoom's held 2.
        XCTAssertEqual(try XCTUnwrap(inspector.spanValue(.scale, atEnd: false, of: shown)), 225, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(inspector.spanValue(.scale, atEnd: true, of: shown)), 300, accuracy: 1e-9)
        XCTAssertEqual(inspector.spanText(.scale, atEnd: false, of: shown), "225 %")
        XCTAssertEqual(inspector.spanText(.positionX, atEnd: false, of: shown), "40 px", "the static x plus 0")
        XCTAssertEqual(inspector.spanText(.positionX, atEnd: true, of: shown), "140 px")

        // Typed absolute values are stored relative: 150 % at the end over 300 % is 0.5.
        inspector.commitSpanValue(.scale, atEnd: true, "150 %")
        XCTAssertEqual(try span(move).endValues.scale, 0.5, accuracy: 1e-12)
        var edge = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getMotion(&edge, atEdgeOfSpan: move, atEnd: true,
                                                                 frameDuration: store.frameDuration))
        XCTAssertEqual(edge.scale, 1.5, accuracy: 1e-12, "the end shows what was typed")
        XCTAssertEqual(store.undoActionName, "Change Span Values")
        inspector.commitSpanValue(.positionX, atEnd: false, "100")
        XCTAssertEqual(try span(move).startValues.x, 60, accuracy: 1e-12, "100 px over the static 40")
        XCTAssertEqual(try XCTUnwrap(store.clips[clip]).motion(at: frames(30)).x, 100, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(try span(move).startValues.x, 0, accuracy: 1e-12, "one undo step")

        // An edit of the earlier span moves what this one shows; its own value stays.
        XCTAssertTrue(store.engine.setSpanValues(zoom, start: VESpanValuesUnchanged(), end: values(scale: 4)).ok)
        let after = try span(move)
        XCTAssertEqual(after.endValues.scale, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(inspector.spanValue(.scale, atEnd: true, of: after)), 1.5 * 4 * 0.5 * 100,
                       accuracy: 1e-9, "re-read, not cached")

        // Nudges: a burst is one undo step.
        let before = try span(move).endValues.x
        for _ in 0 ..< 5 { inspector.nudgeSpanValue(.positionX, atEnd: true, steps: 1) }
        inspector.endNudgeBurst()
        XCTAssertEqual(try span(move).endValues.x, before + 5, accuracy: 1e-9)
        store.undo()
        XCTAssertEqual(try span(move).endValues.x, before, accuracy: 1e-9)
        // Text that is no value is refused.
        inspector.commitSpanValue(.scale, atEnd: false, "big")
        XCTAssertEqual(inspector.message, "“big” is not a valid scale in %.")
    }

    /// The review's test gap 4: over a base of scale 0 (the clip's static scale is 0) the engine
    /// reports the base as 0, and a typed scale or a Ken Burns drag is refused with the reason (a
    /// factor over 0 shows 0 whatever it is); a position still takes.
    func testAScaleOverABaseOfZeroIsRefusedWithTheReason() async throws {
        let clip = try await longClip()
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 10, y: 0, scale: 0, rotationDegrees: 0, opacity: 1),
                                                  forClip: clip).ok)
        let id = try addSpan(.motion, lane: 1, clip: clip, 0, 60, startValues: values(scale: 1), endValues: values(scale: 2))
        var base = VESpanValuesUnchanged()
        XCTAssertTrue(try XCTUnwrap(store.clips[clip]).getBaseValues(&base, underSpan: id, atEnd: true,
                                                                     frameDuration: store.frameDuration))
        XCTAssertEqual(base.scale, 0)
        XCTAssertEqual(base.x, 10)
        store.select(span: id)
        let changes = store.changeCount
        inspector.commitSpanValue(.scale, atEnd: true, "150 %")
        XCTAssertEqual(store.changeCount, changes, "refused")
        XCTAssertEqual(try span(id).endValues.scale, 2, accuracy: 1e-12)
        XCTAssertTrue(inspector.message?.hasPrefix("The rest of the clip has scale 0 here") == true, inspector.message ?? "")
        inspector.commitSpanValue(.positionX, atEnd: true, "30")
        XCTAssertEqual(try span(id).endValues.x, 20, accuracy: 1e-12, "30 px over the static 10")
        // The Ken Burns editor refuses a drag with the note, and writes nothing.
        let model = try XCTUnwrap(store.kenBurns)
        let before = store.changeCount
        model.applyDrag(.corner(.end, .bottomRight), origin: model.end, translation: CGSize(width: -100, height: 0),
                        location: CGPoint(x: model.end.maxX - 100, y: model.end.maxY - 56))
        model.endDrag()
        XCTAssertEqual(store.changeCount, before)
        XCTAssertEqual(model.note, "The rest of the clip has scale 0 here, so the move cannot change what it shows.")
    }

    func testOpacityAndGainValuesAreAbsolute() async throws {
        let clip = try await longClip()
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 0, y: 0, scale: 1, rotationDegrees: 0, opacity: 0.8),
                                                  forClip: clip).ok)
        // A fade from 0: its start shows 0 whatever the clip's opacity, which the base still knows.
        let fade = try addSpan(.opacity, lane: 1, clip: clip, 0, 30, startValues: values(opacity: 0),
                               endValues: values(opacity: 1))
        store.select(span: fade)
        let shown = try span(fade)
        XCTAssertEqual(inspector.spanText(.opacity, atEnd: false, of: shown), "0 %")
        XCTAssertEqual(inspector.spanText(.opacity, atEnd: true, of: shown), "80 %")
        inspector.commitSpanValue(.opacity, atEnd: false, "40 %")
        XCTAssertEqual(try span(fade).startValues.opacity, 0.5, accuracy: 1e-12, "40 % of the clip's 80 %")
        XCTAssertEqual(try XCTUnwrap(store.clips[clip]).motion(at: .zero).opacity, 0.4, accuracy: 1e-12)
        // A fade can only lower what it applies onto: 100 % is limited to the clip's 80 %, with a note.
        inspector.commitSpanValue(.opacity, atEnd: false, "100")
        XCTAssertEqual(try span(fade).startValues.opacity, 1, accuracy: 1e-12)
        XCTAssertEqual(inspector.message?.hasPrefix("Limited to 80 %"), true, inspector.message ?? "")

        // Gain: the static level plus the span's dB.
        let (_, tone) = try await fixture.importMedia()
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1, overwrite: true))
        let sound = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.setAudioParams(VEAudioParams(gainDb: -6, fadeInDuration: .zero, fadeOutDuration: .zero),
                                                  forClip: sound).ok)
        let gain = try addSpan(.gain, lane: 1, clip: sound, 0, 30)
        store.select(span: gain)
        XCTAssertEqual(inspector.spanText(.gain, atEnd: true, of: try span(gain)), "-6 dB")
        inspector.commitSpanValue(.gain, atEnd: true, "-12dB")
        XCTAssertEqual(try span(gain).endValues.gainDb, -6, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(store.clips[sound]).gainDb(at: frames(45)), -12, accuracy: 1e-9, "held after")
        inspector.nudgeSpanValue(.gain, atEnd: true, steps: 1)
        inspector.endNudgeBurst()
        XCTAssertEqual(try span(gain).endValues.gainDb, -5, accuracy: 1e-9)
    }

    // MARK: Range, interpolation, lane

    func testTheRangeFieldsAreLimitedToTheClipAndTheFreeSpace() async throws {
        let clip = try await longClip()
        let first = try addSpan(.motion, lane: 1, clip: clip, 30, 60)
        try addSpan(.motion, lane: 1, clip: clip, 150, 210)
        store.select(span: first)
        let shown = try span(first)
        XCTAssertEqual(inspector.spanRangeText(.start, of: shown), "00:00:01:00")
        XCTAssertEqual(inspector.spanRangeText(.end, of: shown), "00:00:02:00")
        XCTAssertEqual(inspector.spanRangeText(.duration, of: shown), "00:00:01:00")
        // Into the next span on the lane: limited to the free space, with a note.
        inspector.commitSpanRange(.end, "00:00:06:00")
        XCTAssertEqual(try span(first).end, frames(150))
        XCTAssertEqual(inspector.message, "Limited to the free space on lane 1, 00:00:00:00 – 00:00:05:00.")
        XCTAssertEqual(store.undoActionName, "Change Span Range")
        // A duration moves the end; the start stays.
        inspector.commitSpanRange(.duration, "2s")
        XCTAssertEqual([try span(first).start, try span(first).end], [frames(30), frames(90)])
        XCTAssertNil(inspector.message)
        // A start past the end: a frame before it.
        inspector.commitSpanRange(.start, "150f")
        XCTAssertEqual(try span(first).start, frames(89))
        XCTAssertTrue(inspector.message?.contains("at least a frame long") == true, inspector.message ?? "")
        // Nudges move an end by a frame.
        inspector.nudgeSpanRange(.start, steps: -1)
        XCTAssertEqual(try span(first).start, frames(88))
        // Text that is not a time is refused, nothing changes.
        inspector.commitSpanRange(.start, "soon")
        XCTAssertEqual(try span(first).start, frames(88))
        XCTAssertTrue(inspector.message?.contains("is not a time") == true)

        // Interpolation and lane, one undo step each; a lane with a span there is refused.
        inspector.setSpanInterpolation(.hold)
        XCTAssertEqual(try span(first).interpolation, .hold)
        XCTAssertEqual(store.undoActionName, "Change Span Interpolation")
        inspector.moveSpan(toLane: 2)
        XCTAssertEqual(try span(first).lane, 2)
        let blocker = try addSpan(.motion, lane: 3, clip: clip, 80, 100)
        inspector.moveSpan(toLane: 3)
        XCTAssertEqual(try span(first).lane, 2)
        XCTAssertTrue(inspector.message?.contains("nearest free range") == true, inspector.message ?? "")
        // Remove, one undo step.
        inspector.removeSpan()
        XCTAssertNil(store.engine.spanInfo(first))
        XCTAssertNil(store.selectedSpanID)
        store.undo()
        XCTAssertNotNil(store.engine.spanInfo(first))
        XCTAssertNotNil(store.engine.spanInfo(blocker))
    }

    // MARK: Matching

    func testMatchingASpanEdgeContinuesTheNeighbour() async throws {
        let (movie, _) = try await fixture.importMedia()
        let a = try fixture.placeMovie(movie, at: 0) // [0, 60)
        let b = try fixture.placeMovie(movie, at: 2) // [60, 120), touching A
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: -50, y: 0, scale: 2, rotationDegrees: 0, opacity: 1),
                                                  forClip: a).ok)
        let fromStart = try addSpan(.motion, lane: 1, clip: b, 60, 90)
        let later = try addSpan(.motion, lane: 2, clip: b, 70, 90)
        store.select(span: fromStart)
        XCTAssertTrue(inspector.canMatchSpan(.start))
        XCTAssertFalse(inspector.canMatchSpan(.end), "nothing touches B's end")
        inspector.matchSpan(.start)
        XCTAssertEqual(store.undoActionName, "Match Previous Clip")
        var edge = VEVideoParams()
        XCTAssertTrue(try XCTUnwrap(store.clips[b]).getMotion(&edge, atEdgeOfSpan: fromStart, atEnd: false,
                                                              frameDuration: store.frameDuration))
        XCTAssertEqual(edge.scale, 2, accuracy: 1e-12, "B's first frame shows A's last")
        XCTAssertEqual(edge.x, -50, accuracy: 1e-9)
        store.select(span: later)
        XCTAssertFalse(inspector.canMatchSpan(.start), "it does not start on B's first frame")
        // During a gesture: refused with the reason.
        store.select(span: fromStart)
        store.cancelActiveGesture = {}
        inspector.matchSpan(.start)
        XCTAssertEqual(inspector.message, "Finish the current drag first.")
        store.cancelActiveGesture = nil
    }

    // MARK: Transitions

    func testATransitionsSharesOfTheCutAreEditable() async throws {
        let (movie, _) = try await fixture.importMedia()
        func place(_ at: Double, _ from: Double, _ to: Double) throws -> VEClipID {
            XCTAssertTrue(store.place(asset: movie.assetID, at: store.frameTime(at), videoTrack: v1, audioTrack: 0,
                                      sourceIn: store.frameTime(from), sourceOut: store.frameTime(to), overwrite: true))
            return try XCTUnwrap(store.selection.first)
        }
        let a = try place(0, 0, 1)
        let b = try place(1, 1, 2)
        let added = store.engine.addTransition(fromClip: a, toClip: b, duration: frames(10))
        let id = try XCTUnwrap(added.createdIDs.first?.int64Value)
        store.selectedTransitionID = id
        XCTAssertNil(inspector.span, "a transition has its own section")
        XCTAssertNotNil(inspector.transition)
        XCTAssertEqual(inspector.transitionShares?.before, 5)
        XCTAssertEqual(inspector.shareText(before: true), "50 %")
        inspector.commitShare(before: true, "70")
        XCTAssertEqual(inspector.transitionShares?.before, 7)
        XCTAssertEqual(inspector.transitionShares?.after, 3)
        XCTAssertEqual(store.frames(try XCTUnwrap(store.engine.transitionInfo(id)).duration), 10, "the duration stays")
        XCTAssertEqual(store.undoActionName, "Change Transition")
        inspector.nudgeShare(before: false, steps: 1)
        XCTAssertEqual(inspector.transitionShares?.after, 4)
        store.undo()
        XCTAssertEqual(inspector.transitionShares?.after, 3)
        store.undo()
        XCTAssertEqual(inspector.transitionShares?.before, 5)
        inspector.commitShare(before: false, "150 %")
        XCTAssertEqual(inspector.transitionShares?.after, 10, "at most all of it")
        XCTAssertEqual(inspector.message, "A share is 0 % to 100 %.")
        // Review L3: all of it before the cut would be a fade out; the dissolve keeps a frame after.
        inspector.commitShare(before: true, "100 %")
        XCTAssertEqual(inspector.transitionShares?.before, 9)
        XCTAssertEqual(inspector.transitionShares?.after, 1)
        XCTAssertEqual(store.engine.spanInfo(id)?.transitionStyle, .crossDissolve)
        XCTAssertEqual(inspector.message, InspectorModel.lastFrameAfterCutNote)
        inspector.nudgeShare(before: true, steps: 1)
        XCTAssertEqual(inspector.transitionShares?.after, 1, "a nudge stops there too")
        XCTAssertEqual(store.engine.spanInfo(id)?.transitionStyle, .crossDissolve)
        inspector.commitShare(before: false, "0")
        XCTAssertEqual(inspector.transitionShares?.after, 1)
        // Review L9: the inspector reads the selected transition and its limit from the engine once
        // per model change, however often its body reads them; the store answers from its snapshot.
        let reads = inspector.engineTransitionReads
        for _ in 0 ..< 10 {
            _ = inspector.transition
            _ = inspector.transitionShares
            _ = inspector.transitionKind
            _ = inspector.transitionTiming
            _ = inspector.transitionLimit
            _ = inspector.shareText(before: true)
            XCTAssertEqual(store.selectedTransitionID, id)
        }
        XCTAssertLessThanOrEqual(inspector.engineTransitionReads - reads, 2)
        inspector.nudgeShare(before: false, steps: 1)
        _ = inspector.transitionLimit
        XCTAssertEqual(inspector.transitionShares?.after, 2, "re-read after the model changed")
        XCTAssertLessThanOrEqual(inspector.engineTransitionReads - reads, 4)
        // A fade has no shares.
        XCTAssertTrue(store.engine.removeTransition(id).ok)
        XCTAssertTrue(store.addFade(at: .end, of: b, frames: 10))
        XCTAssertNil(inspector.transitionShares)
    }

    // MARK: Video section

    func testTheVideoSectionShowsStaticValuesWhateverThePlayhead() async throws {
        let clip = try await longClip()
        try addSpan(.motion, lane: 1, clip: clip, 0, 60, startValues: values(scale: 1), endValues: values(scale: 3))
        store.selection = [clip]
        XCTAssertNil(inspector.span, "a clip selection shows the clip")
        for time in [frames(0), frames(30), frames(200)] {
            store.playheadTime = time
            XCTAssertEqual(try XCTUnwrap(inspector.value(.scale)), 100, accuracy: 1e-9, "the static value")
        }
        inspector.setValue(.scale, 50)
        XCTAssertEqual(try XCTUnwrap(store.clips[clip]).videoParams.scale, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(store.clips[clip]).motion(at: frames(200)).scale, 1.5, accuracy: 1e-9,
                       "the span's held 3x composes onto it")
    }

    /// Audio crossfades are lane-0 spans too: their shares of the cut are edited like a dissolve's.
    func testAnAudioCrossfadesSharesAreEditable() async throws {
        let (_, tone) = try await fixture.importMedia()
        func place(_ at: Double, _ from: Double, _ to: Double) throws -> VEClipID {
            XCTAssertTrue(store.place(asset: tone.assetID, at: store.frameTime(at), videoTrack: 0, audioTrack: a1,
                                      sourceIn: store.frameTime(from), sourceOut: store.frameTime(to), overwrite: true))
            return try XCTUnwrap(store.selection.first)
        }
        let a = try place(0, 0, 1)
        let b = try place(1, 1, 2)
        let added = store.engine.addTransition(fromClip: a, toClip: b, duration: frames(12))
        let id = try XCTUnwrap(added.createdIDs.first?.int64Value, added.message)
        store.selectedTransitionID = id
        XCTAssertEqual(inspector.transitionKind, .audioCrossfade)
        XCTAssertEqual(inspector.transitionShares?.before, 6)
        inspector.commitShare(before: false, "25 %")
        XCTAssertEqual(inspector.transitionShares?.after, 3)
        XCTAssertEqual(inspector.transitionShares?.before, 9)
        let span = try XCTUnwrap(store.engine.spanInfo(id))
        XCTAssertEqual(span.start, frames(21), "the crossfade reaches 9 frames before the cut")
        XCTAssertEqual(span.end, frames(33))
    }
}
