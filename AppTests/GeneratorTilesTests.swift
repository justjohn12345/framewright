import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

/// The Effects tab's "Titles and Generators" (titles design section 9; slice 1): each tile's drag payload has its
/// own exported type, the timeline accepts it and places the preset where it is dropped (overwriting, or inserting
/// with Command), and the tiles' "+" is enabled only when a title can be added (not during a drag).
@MainActor
final class GeneratorTilesTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    private func rowPoint(_ track: VETrackID, at seconds: Double) throws -> CGPoint {
        let model = store.timelineModel
        let layout = try XCTUnwrap(model.layout(forTrack: track))
        return CGPoint(x: model.x(forTime: seconds), y: layout.y - model.scrollY + layout.rowHeight / 2)
    }

    func testEachTileHasItsOwnTypeAndTheTimelineTakesIt() throws {
        let types = Set(GeneratorPreset.allCases.map(\.contentType))
        XCTAssertEqual(types.count, 5, "Title, Lower Third, Colour Matte, Title Card and Caption (slice 2)")
        for preset in GeneratorPreset.allCases {
            XCTAssertTrue(TimelineDropDelegate.types.contains(preset.contentType), preset.title)
            XCTAssertTrue(preset.contentType.isDeclared, "\(preset.title) is declared in Info.plist")
            let provider = NSItemProvider()
            provider.register(GeneratorReference(preset: preset))
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(preset.contentType.identifier))
            for other in GeneratorPreset.allCases where other != preset {
                XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(other.contentType.identifier))
            }
            let info = FakeDropInfo(location: .zero, providers: [provider])
            XCTAssertEqual(TimelineDropDelegate.generatorPreset(info), preset)
            XCTAssertNil(TimelineDropDelegate.effectKind(info))
            XCTAssertNil(TimelineDropDelegate.transitionKind(info))
        }
    }

    func testADroppedTileLandsWhereItIsDropped() async throws {
        let media = try await fixture.importMedia()
        let movie = try fixture.placeMovie(media.movie, at: 0)
        store.refreshModel()
        let v1 = store.videoTracks[0].trackID
        let v2 = store.videoTracks[1].trackID
        let gestures = TimelineGestureController(store: store)
        var targeted = false
        var command = false
        var delegate = TimelineDropDelegate(gestures: gestures,
                                            isAssetTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        delegate.commandHeld = { command }
        func drop(_ preset: GeneratorPreset, at point: CGPoint) -> Bool {
            let provider = NSItemProvider()
            provider.register(GeneratorReference(preset: preset))
            let info = FakeDropInfo(location: point, providers: [provider])
            XCTAssertTrue(delegate.handleValidate(info))
            delegate.handleEntered(info)
            XCTAssertTrue(targeted, "the track area shows it can take the drop, as for media")
            XCTAssertEqual(delegate.handleUpdated(info)?.operation, .copy)
            return delegate.handlePerform(info)
        }
        // On V2 over the footage: overwrite at the drop point.
        XCTAssertTrue(drop(.title, at: try rowPoint(v2, at: 0.5)))
        XCTAssertFalse(targeted)
        let title = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(store.clips[title]?.trackID, v2)
        XCTAssertEqual(store.clips[title]?.timelineStart, frames(15))
        XCTAssertEqual(store.clips[title]?.generatorKind, .title)
        XCTAssertEqual(store.undoActionName, "Add Title")
        // On V1 with Command: inserted, the footage rippled.
        command = true
        store.refreshModel()
        XCTAssertTrue(drop(.colourMatte, at: try rowPoint(v1, at: 0)))
        XCTAssertEqual(store.clips[movie]?.timelineStart, CMTime(value: 5, timescale: 1))
        XCTAssertEqual(store.clips[try XCTUnwrap(store.selection.first)]?.generatorKind, .colourMatte)
        // On an audio row: refused with a reason.
        command = false
        store.refreshModel()
        let changes = store.changeCount
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertFalse(drop(.lowerThird, at: try rowPoint(a1, at: 0)))
        XCTAssertEqual(store.statusMessage, "Drop a lower third on a video track.")
        XCTAssertEqual(store.changeCount, changes)
    }

    func testThePlusButtonsFollowWhetherATitleCanBeAdded() async throws {
        let media = try await fixture.importMedia()
        try fixture.placeMovie(media.movie, at: 0)
        let availability = store.laneEffects
        availability.refresh()
        XCTAssertTrue(availability.canAddGenerated)
        store.cancelActiveGesture = {}
        let disabled = await StoreFixture.wait(until: { !availability.canAddGenerated }, timeout: 2)
        XCTAssertTrue(disabled, "a drag disables the tiles' +")
        store.cancelActiveGesture = nil
        let enabled = await StoreFixture.wait(until: { availability.canAddGenerated }, timeout: 2)
        XCTAssertTrue(enabled)
        // The tiles are drawn in the Effects tab.
        let hosted = HostedView(EffectsPanel(store: store), size: NSSize(width: 300, height: 900))
        defer { hosted.close() }
        await hosted.settle()
        XCTAssertNotNil(hosted.bitmap())
    }
}
