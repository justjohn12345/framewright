import AppKit
import CoreMedia
import CoreTransferable
import FramewrightEngine
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Framewright

/// The timeline's drop path (open finding 1c): what the Effects tab's drag source offers, and what
/// `TimelineDropDelegate` does with it, driven with a test double of SwiftUI's `DropInfo`. A real
/// drag between two views (the window server's drag session) can only be performed by hand or by a
/// UI test; everything after it arrives at the delegate is covered here.
@MainActor
final class TimelineDropTests: XCTestCase {
    /// What a drop offers: registered type identifiers and their item providers.
    private struct FakeDropInfo: TimelineDropInfo {
        var location: CGPoint
        var providers: [NSItemProvider]

        func hasItemsConforming(to contentTypes: [UTType]) -> Bool {
            providers.contains { provider in
                contentTypes.contains { type in provider.hasItemConformingToTypeIdentifier(type.identifier) }
            }
        }

        func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider] {
            providers.filter { provider in
                contentTypes.contains { type in provider.hasItemConformingToTypeIdentifier(type.identifier) }
            }
        }
    }

    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "drop-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// The provider the Effects tab's `.draggable(TransitionReference(kind:))` hands the drag.
    private func transitionProvider(_ kind: TransitionKind) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.register(TransitionReference(kind: kind))
        return provider
    }

    func testTheDragSourceOffersTheExportedTransitionTypes() throws {
        for kind in TransitionKind.allCases {
            let provider = transitionProvider(kind)
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(kind.contentType.identifier),
                          "\(kind) offers \(kind.contentType.identifier): \(provider.registeredTypeIdentifiers)")
            let other = TransitionKind.allCases.first { $0 != kind }
            if let other {
                XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(other.contentType.identifier),
                               "each kind has its own type, so the timeline knows what is dragged before the drop")
            }
            // Declared by the app (Info.plist UTExportedTypeDeclarations), not a dynamic type.
            let declared = try XCTUnwrap(UTType(kind.contentType.identifier))
            XCTAssertTrue(declared.isDeclared, "\(kind.contentType.identifier) is declared in Info.plist")
            XCTAssertFalse(declared.isDynamic)
        }
        XCTAssertEqual(Set(TimelineDropDelegate.types),
                       Set([.framewrightAssetReference, .framewrightCrossDissolve, .framewrightAudioCrossfade,
                            .framewrightFadeEffect, .framewrightGainEffect] + MediaDrop.types),
                       "in-app types, and media files and file promises (Photos)")
        for kind in EffectKind.allCases {
            let provider = NSItemProvider()
            provider.register(EffectReference(kind: kind))
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(kind.contentType.identifier))
            let declared = try XCTUnwrap(UTType(kind.contentType.identifier))
            XCTAssertTrue(declared.isDeclared, "\(kind.contentType.identifier) is declared in Info.plist")
        }
    }

    func testATransitionDroppedOnACutIsAdded() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let a = try fixture.placeMovie(movie, at: 0, track: v1)
        XCTAssertTrue(store.place(asset: movie.assetID, at: store.frameTime(0.8), videoTrack: v1, audioTrack: 0,
                                  sourceIn: store.frameTime(1.2), sourceOut: store.frameTime(2), overwrite: true))
        _ = a
        let gestures = TimelineGestureController(store: store)
        var targeted = false
        let delegate = TimelineDropDelegate(gestures: gestures,
                                            isAssetTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        let model = store.timelineModel
        let row = try XCTUnwrap(model.layout(forTrack: v1))
        let atCut = CGPoint(x: model.x(forTime: 0.8) + 6, y: row.y + 30)
        let dissolve = FakeDropInfo(location: atCut, providers: [transitionProvider(.crossDissolve)])

        XCTAssertTrue(delegate.handleValidate(dissolve))
        delegate.handleEntered(dissolve)
        XCTAssertFalse(targeted, "a transition highlights its cut, not the whole track area")
        XCTAssertEqual(delegate.handleUpdated(dissolve)?.operation, .copy)
        XCTAssertEqual(gestures.transitionDrop?.cut ?? -1, 0.8, accuracy: 1e-9, "the cut under the pointer lights up")
        XCTAssertTrue(delegate.handlePerform(dissolve))
        XCTAssertEqual(store.sequence.transitions.count, 1)
        XCTAssertEqual(store.sequence.transitions.first?.trackID, v1)
        XCTAssertNil(gestures.transitionDrop)

        // A crossfade over a video row is refused, as is anything that is not ours.
        let wrongRow = FakeDropInfo(location: atCut, providers: [transitionProvider(.audioCrossfade)])
        XCTAssertEqual(delegate.handleUpdated(wrongRow)?.operation, .forbidden)
        XCTAssertFalse(delegate.handlePerform(wrongRow))
        XCTAssertTrue(store.statusMessage?.contains("audio track") == true, store.statusMessage ?? "")
        let text = NSItemProvider(object: "hello" as NSString)
        XCTAssertFalse(delegate.handleValidate(FakeDropInfo(location: atCut, providers: [text])))
        delegate.handleExited(dissolve)
        XCTAssertNil(gestures.transitionDrop)
    }

    /// UX round review test gap 5: a dissolve dropped from the Effects tab on a plain split (both
    /// sides play the same media contiguously) is added and the status line says why it shows
    /// nothing, as for the "+" button.
    func testADissolveDroppedOnAThroughEditSaysSoInTheStatusLine() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let clip = try fixture.placeMovie(movie, at: 0, track: v1)
        store.selection = [clip]
        store.playheadTime = store.frameTime(1)
        store.splitAtPlayhead()
        XCTAssertEqual(store.clips.count, 2, "split into a through edit")
        store.statusMessage = nil
        let gestures = TimelineGestureController(store: store)
        var targeted = false
        let delegate = TimelineDropDelegate(gestures: gestures,
                                            isAssetTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        let model = store.timelineModel
        let row = try XCTUnwrap(model.layout(forTrack: v1))
        let atCut = CGPoint(x: model.x(forTime: 1) + 4, y: row.y + 30)
        let dissolve = FakeDropInfo(location: atCut, providers: [transitionProvider(.crossDissolve)])
        XCTAssertTrue(delegate.handleValidate(dissolve))
        delegate.handleEntered(dissolve)
        XCTAssertEqual(delegate.handleUpdated(dissolve)?.operation, .copy)
        XCTAssertEqual(gestures.transitionDrop?.cut ?? -1, 1, accuracy: 1e-9)
        XCTAssertTrue(delegate.handlePerform(dissolve))
        XCTAssertEqual(store.sequence.transitions.count, 1, "added anyway (the user may trim a side next)")
        let note = "Both sides show the same frames here; trim or move one side to see the dissolve"
        XCTAssertTrue(store.statusMessage?.contains(note) == true, store.statusMessage ?? "")
    }

    func testMediaDroppedFromTheBinIsPlaced() async throws {
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let gestures = TimelineGestureController(store: store)
        var targeted = false
        var delegate = TimelineDropDelegate(gestures: gestures,
                                            isAssetTargeted: Binding(get: { targeted }, set: { targeted = $0 }))
        delegate.commandHeld = { false }
        let provider = NSItemProvider()
        provider.register(AssetReference(assetID: movie.assetID))
        let model = store.timelineModel
        let row = try XCTUnwrap(model.layout(forTrack: v1))
        let info = FakeDropInfo(location: CGPoint(x: model.x(forTime: 2), y: row.y + 30), providers: [provider])
        XCTAssertTrue(delegate.handleValidate(info))
        delegate.handleEntered(info)
        XCTAssertTrue(targeted, "media highlights the track area")
        XCTAssertTrue(delegate.handlePerform(info))
        XCTAssertFalse(targeted)
        let placed = await StoreFixture.wait(until: { !store.clips.isEmpty }, timeout: 5)
        XCTAssertTrue(placed, "the payload is read asynchronously, then placed")
        let clip = try XCTUnwrap(store.clips.values.first)
        XCTAssertEqual(clip.trackID, v1)
        XCTAssertEqual(clip.timelineStart.seconds, 2, accuracy: 1.0 / 30)
    }
}
