import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Titles and colour mattes on the timeline (titles design section 9; slice 1): their own colour (one no other
/// item uses), the first line of the text that has any as the name ("Title" when none has), a matte's colour as a swatch with the
/// name "Colour Matte", no thumbnails (the generator assets never reach the thumbnail service), and a missing font's
/// warning badge, redrawn when the Mac's fonts change.
@MainActor
final class TitleTimelineTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        try fixture.configureSequence()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    private func drawn(_ id: VEClipID) throws -> TimelineViewModel.Clip {
        try XCTUnwrap(store.timelineModel.clips.first { $0.id == id })
    }

    func testTitlesAndMattesHaveTheirOwnLook() throws {
        let titleFill = TimelineItemStyle.baseFill(.titleClip)
        for kind in TimelineItemStyle.Kind.allCases where kind != .titleClip {
            XCTAssertNotEqual(TimelineItemStyle.baseFill(kind), titleFill, "\(kind)")
        }
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let lowerThird = try XCTUnwrap(store.selection.first)
        XCTAssertEqual(try drawn(lowerThird).name, "Name", "the first line")
        XCTAssertEqual(try drawn(lowerThird).generator, .title)
        XCTAssertNil(try drawn(lowerThird).matteColour)
        XCTAssertFalse(try drawn(lowerThird).fontMissing)
        store.titleInspector.textChanged("\nSecond line")
        store.titleInspector.endTyping()
        XCTAssertEqual(try drawn(lowerThird).name, "Second line", "the first line with text")
        store.titleInspector.textChanged(" \n")
        store.titleInspector.endTyping()
        XCTAssertEqual(try drawn(lowerThird).name, "Title", "no text")
        store.titleInspector.textChanged("Jane Doe\nDirector")
        store.titleInspector.endTyping()
        XCTAssertEqual(try drawn(lowerThird).name, "Jane Doe")

        store.playheadTime = frames(300)
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let matte = try XCTUnwrap(store.selection.first)
        store.titleInspector.setMatteColour(VEColour(red: 0.25, green: 0.5, blue: 0.75))
        store.titleInspector.endBurst()
        XCTAssertEqual(try drawn(matte).name, "Colour Matte")
        XCTAssertEqual(try drawn(matte).generator, .colourMatte)
        XCTAssertEqual(try drawn(matte).matteColour, TimelineItemStyle.RGB(red: 0.25, green: 0.5, blue: 0.75))
        // No thumbnails: the generator assets are not the bin's, so the renderer has no asset to ask for frames of.
        XCTAssertNil(store.assetsByID[try XCTUnwrap(store.clips[matte]).assetID])
        XCTAssertNil(store.assetsByID[try XCTUnwrap(store.clips[lowerThird]).assetID])
    }

    func testAMissingFontShowsItsBadgeUntilTheFontsChange() async throws {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.title))
        let title = try XCTUnwrap(store.selection.first)
        store.titleInspector.setFont(VETitleFont.named("NoSuchFont-Bold", family: "No Such Font", style: "Bold"))
        XCTAssertTrue(try drawn(title).fontMissing)
        store.titleInspector.setFont(VETitleFont.system(weight: .bold))
        XCTAssertFalse(try drawn(title).fontMissing)
        store.undo()
        XCTAssertTrue(try drawn(title).fontMissing)
        // The fonts changing rebuilds the timeline's content although the model did not change.
        let builds = store.timelineBuildCount
        _ = store.timelineModel
        XCTAssertEqual(store.timelineBuildCount, builds)
        NotificationCenter.default.post(name: .VEEngineTitleFontsDidChange, object: store.engine)
        _ = store.timelineModel
        XCTAssertEqual(store.timelineBuildCount, builds + 1)
        XCTAssertTrue(try drawn(title).fontMissing, "still missing")

        // Drawn in a hosted timeline (offscreen) without trouble, badge and all.
        let hosted = HostedView(TimelineView(store: store), size: NSSize(width: 900, height: 300))
        defer { hosted.close() }
        let pixels = await hosted.pixels()
        XCTAssertFalse(pixels.isEmpty)
    }
}
