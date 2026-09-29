import AVFoundation
import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// The Sequence Settings sheet's model (Sequence > Sequence Settings…): it shows the sequence's settings
/// (a preset or custom size, a standard or custom frame rate), says what applying new ones does, asks
/// before a size or frame-rate change reaches a sequence with clips, applies as one undo step and closes;
/// refusals stay in the sheet. The first movie placed in a new project sets the sequence (the store's
/// status line names it), and the Ken Burns editor open on a span follows a size change.
@MainActor
final class SequenceSettingsTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    private func openSheet() throws -> SequenceSettingsModel {
        fixture.store.showSequenceSettings()
        return try XCTUnwrap(fixture.store.sequenceSettingsModel)
    }

    func testTheFirstMovieSetsANewProjectsSequence() async throws {
        let store = fixture.store
        XCTAssertFalse(store.sequence.isConfigured)
        XCTAssertEqual([store.sequence.width, store.sequence.height], [1920, 1080])
        let (movie, _) = try await fixture.importMedia()
        try fixture.placeMovie(movie, at: 0)
        XCTAssertTrue(store.sequence.isConfigured)
        XCTAssertEqual([store.sequence.width, store.sequence.height], [320, 180])
        XCTAssertEqual(store.statusMessage, "The sequence takes “clip.mov”'s settings: 320×180 at 30 fps.")
        XCTAssertTrue(store.engine.undo())
        XCTAssertFalse(store.engine.sequence.isConfigured)
    }

    func testTheSheetShowsTheSettingsAndAppliesThemAsOneStep() async throws {
        let store = fixture.store
        // An empty sequence: the preset shown, no confirmation, applied at once.
        var model = try openSheet()
        XCTAssertEqual(model.sizeChoice, .preset(2)) // 1920 × 1080
        XCTAssertEqual(model.frameRateTitle(at: model.frameRateIndex), "30 fps")
        XCTAssertEqual(model.frameDurations.count, 8, "the standard rates only")
        XCTAssertEqual(model.audioSampleRate, 48000)
        // Applying the same values still configures the new project's sequence (its first movie will
        // not change it), and says so.
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.changes, ["The sequence keeps these settings: the first video clip placed on it will "
            + "not change them."])
        model.sizeChoice = .preset(0) // 3840 × 2160
        model.frameRateIndex = try XCTUnwrap(model.frameDurations.firstIndex { CMTimeCompare($0, CMTime(value: 1, timescale: 25)) == 0 })
        XCTAssertTrue(model.canApply)
        XCTAssertTrue(model.changes.contains("The frame becomes 3840×2160 (from 1920×1080)."), "\(model.changes)")
        XCTAssertTrue(model.apply())
        XCTAssertNil(store.sequenceSettingsModel, "the sheet closes")
        XCTAssertEqual([store.sequence.width, store.sequence.height], [3840, 2160])
        XCTAssertEqual(CMTimeCompare(store.frameDuration, CMTime(value: 1, timescale: 25)), 0)
        XCTAssertTrue(store.sequence.isConfigured)
        XCTAssertEqual(store.engine.undoActionName, "Sequence Settings")
        XCTAssertEqual(store.statusMessage, "Sequence settings: 3840×2160, 25 fps, 48 kHz.")

        // With a clip: a frame-rate change asks first; Cancel leaves everything; the confirmation applies.
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        XCTAssertEqual([store.sequence.width, store.sequence.height], [3840, 2160], "configured: kept")
        model = try openSheet()
        XCTAssertEqual(model.sizeChoice, .preset(0))
        model.frameRateIndex = try XCTUnwrap(model.frameDurations.firstIndex {
            CMTimeCompare($0, CMTime(value: 1001, timescale: 30000)) == 0
        })
        model.audioSampleRate = 44100
        XCTAssertTrue(model.changes.contains { $0.hasPrefix("The frame rate becomes 29.97 fps (from 25)") }, "\(model.changes)")
        XCTAssertTrue(model.changes.contains("Audio is mixed and exported at 44.1 kHz (from 48 kHz)."))
        XCTAssertFalse(model.apply(), "asks first")
        XCTAssertTrue(model.confirming)
        XCTAssertEqual(model.confirmationMessage, model.changes.joined(separator: "\n"))
        XCTAssertEqual(CMTimeCompare(store.frameDuration, CMTime(value: 1, timescale: 25)), 0, "not yet")
        model.confirming = false // Cancel
        XCTAssertNotNil(store.sequenceSettingsModel)
        XCTAssertFalse(model.apply())
        XCTAssertTrue(model.confirm())
        XCTAssertNil(store.sequenceSettingsModel)
        XCTAssertEqual(CMTimeCompare(store.frameDuration, CMTime(value: 1001, timescale: 30000)), 0)
        XCTAssertEqual(store.sequence.audioSampleRate, 44100)
        XCTAssertNotNil(store.clips[clip])
        XCTAssertTrue(store.engine.undo())
        XCTAssertEqual(CMTimeCompare(store.frameDuration, CMTime(value: 1, timescale: 25)), 0)
        XCTAssertEqual(store.sequence.audioSampleRate, 48000)
    }

    func testTheSharpeningIsAppliedWithTheSettings() throws {
        let store = fixture.store
        let model = try openSheet()
        XCTAssertTrue(model.sharpenScaledDownSources)
        model.sharpenScaledDownSources = false
        XCTAssertTrue(model.changes.contains("Scaled-down sources are no longer sharpened."), "\(model.changes)")
        XCTAssertTrue(store.engine.sharpenScaledDownSources, "not before Apply")
        XCTAssertTrue(model.apply())
        XCTAssertFalse(store.engine.sharpenScaledDownSources)
        XCTAssertFalse(try openSheet().sharpenScaledDownSources, "the sheet shows the project's setting")
    }

    func testCustomSizesAndRatesAndRefusals() throws {
        let store = fixture.store
        // A sequence at a rate outside the list (a project made elsewhere) shows it as custom.
        XCTAssertTrue(store.engine.applySequenceSettings(VESequenceSettings(width: 1000, height: 600,
                                                                           frameDuration: CMTime(value: 1, timescale: 15),
                                                                           audioSampleRate: 32000,
                                                                           sharpenScaledDownSources: true)).ok)
        let model = try openSheet()
        XCTAssertEqual(model.sizeChoice, .custom)
        XCTAssertEqual(model.widthText, "1000")
        XCTAssertEqual(model.heightText, "600")
        XCTAssertEqual(model.frameDurations.count, 9)
        XCTAssertEqual(model.frameRateTitle(at: model.frameRateIndex), "Custom 15 fps")
        XCTAssertEqual(model.sampleRates, [32000, 44100, 48000])
        XCTAssertEqual(SequenceSettingsModel.sampleRateTitle(32000), "32 kHz")
        XCTAssertEqual(SequenceSettingsModel.sampleRateTitle(44100), "44.1 kHz")
        // Not a number, then odd: refused in the sheet.
        model.widthText = "wide"
        XCTAssertEqual(model.validationMessage, "Type the width and height in pixels.")
        XCTAssertFalse(model.canApply)
        model.widthText = "1001"
        XCTAssertEqual(model.validationMessage,
                       "The frame width and height must be even numbers (video encoders need them).")
        XCTAssertFalse(model.apply())
        XCTAssertNotNil(model.refusal)
        model.widthText = "1002"
        XCTAssertNil(model.validationMessage)
        XCTAssertTrue(model.apply())
        XCTAssertEqual(store.sequence.width, 1002)
        // Cancel closes without a change.
        let again = try openSheet()
        again.sizeChoice = .preset(3)
        again.cancel()
        XCTAssertNil(store.sequenceSettingsModel)
        XCTAssertEqual(store.sequence.width, 1002)
    }

    /// The Ken Burns editor open on a span when the frame size changes: it opens afresh in the new sequence
    /// pixels (its frame box is the new frame, its boxes where the picture now is).
    func testTheKenBurnsEditorFollowsASizeChange() async throws {
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        XCTAssertEqual([store.sequence.width, store.sequence.height], [320, 180])
        let lane = store.engine.addSpan(kind: .motion, lane: 1, clip: clip,
                                        range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
        XCTAssertTrue(lane.ok, lane.message)
        let span = try XCTUnwrap(lane.createdIDs.first).int64Value
        store.select(span: span)
        let before = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(before.sequenceSize, CGSize(width: 320, height: 180))
        let startBefore = before.start
        XCTAssertTrue(store.engine.applySequenceSettings(VESequenceSettings(width: 640, height: 360,
                                                                           frameDuration: store.frameDuration,
                                                                           audioSampleRate: 48000,
                                                                           sharpenScaledDownSources: true)).ok)
        let after = try XCTUnwrap(store.kenBurns)
        XCTAssertEqual(after.spanID, span)
        XCTAssertEqual(after.sequenceSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(after.start.center.x, startBefore.center.x * 2, accuracy: 1e-6)
        XCTAssertEqual(after.start.center.y, startBefore.center.y * 2, accuracy: 1e-6)
        XCTAssertEqual(after.start.size.width, startBefore.size.width * 2, accuracy: 1e-6)
    }
}
