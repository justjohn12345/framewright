import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// Copy Style and Paste Style (titles slice 2; like Copy Grade): in the Clip menu (`ProjectStore.canCopyTitleStyle`,
/// `canPasteTitleStyle`) and a title's context menu alike; copying one title's style, or several titles' shared one;
/// pasting it onto several titles as one undo step, each keeping its text and place; other clips left out.
@MainActor
final class TitleStyleTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("titleStyle")
        try fixture.configureSequence()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// A lower third at 0 styled (Helvetica Bold, orange, outline), then three titles at 2 s, 4 s and 6 s with their
    /// own texts and places; returns (lower third, titles).
    private func titles() throws -> (VEClipID, [VEClipID]) {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(.lowerThird))
        let styled = try XCTUnwrap(store.selection.first)
        let ids = [NSNumber(value: styled)]
        XCTAssertTrue(store.engine.setTitleFont(VETitleFont.named("Helvetica-Bold", family: "Helvetica", style: "Bold"),
                                                clips: ids).ok)
        XCTAssertTrue(store.engine.setTitleColour(VEColour(red: 1, green: 0.5, blue: 0), for: .fillColour, clips: ids).ok)
        XCTAssertTrue(store.engine.setTitleToggle(true, for: .outline, clips: ids).ok)
        var plain: [VEClipID] = []
        for (i, text) in ["One", "Two", "Three"].enumerated() {
            store.playheadTime = frames(Int64(60 * (i + 1)))
            XCTAssertTrue(store.addGenerated(.title))
            let id = try XCTUnwrap(store.selection.first)
            XCTAssertTrue(store.engine.setTitleText(text, clips: [NSNumber(value: id)]).ok)
            XCTAssertTrue(store.engine.setTitlePosition(x: 0.2 * Double(i + 1), y: 0.3, width: .nan,
                                                        clips: [NSNumber(value: id)]).ok)
            plain.append(id)
        }
        return (styled, plain)
    }

    /// The context menu's item of `title` for a right-click on `clip`.
    private func contextItem(_ title: String, on clip: VEClipID) throws -> ContextMenuItem? {
        let model = store.timelineModel
        let info = try XCTUnwrap(store.clips[clip])
        let row = try XCTUnwrap(model.layout(forTrack: info.trackID))
        let middle = CMTimeGetSeconds(info.timelineStart) + CMTimeGetSeconds(info.duration) / 2
        let items = TimelineGestureController(store: store)
            .contextMenuItems(at: CGPoint(x: model.x(forTime: middle), y: row.y + 20))
        return items.first { $0.title == title }
    }

    func testCopyAndPasteStyleOntoSeveralTitles() throws {
        let (styled, plain) = try titles()
        store.selection = []
        XCTAssertFalse(store.canCopyTitleStyle)
        XCTAssertFalse(store.canPasteTitleStyle, "nothing copied")
        store.selection = [styled]
        XCTAssertTrue(store.canCopyTitleStyle)
        XCTAssertEqual(try contextItem("Copy Style", on: styled)?.isEnabled, true, "the context menu agrees")
        XCTAssertNil(try contextItem("Copy Grade", on: styled), "titles are not graded: no grade items")
        try XCTUnwrap(contextItem("Copy Style", on: styled)).action()
        XCTAssertTrue(store.hasCopiedTitleStyle)
        XCTAssertEqual(store.statusMessage, "Copied the style of “Name”.")

        store.selection = Set(plain)
        XCTAssertTrue(store.canPasteTitleStyle)
        XCTAssertTrue(store.canCopyTitleStyle, "three titles of the default style share it")
        XCTAssertTrue(store.pasteTitleStyle())
        XCTAssertEqual(store.undoActionName, "Paste Style")
        let source = try XCTUnwrap(store.clips[styled]?.title)
        for (i, id) in plain.enumerated() {
            let title = try XCTUnwrap(store.clips[id]?.title)
            XCTAssertEqual(title.font, source.font)
            XCTAssertEqual(title.fillColour.red, 1)
            XCTAssertTrue(title.outline)
            XCTAssertTrue(title.box, "the lower third's box")
            XCTAssertEqual(title.alignment, .left)
            XCTAssertEqual(title.size, source.size)
            XCTAssertEqual(title.text, ["One", "Two", "Three"][i], "its own text")
            XCTAssertEqual(title.x, 0.2 * Double(i + 1), accuracy: 1e-12, "its own place")
            XCTAssertEqual(title.width, 0.8, "its own wrap width")
        }
        // Now they share a style: Copy Style applies to the three together.
        XCTAssertTrue(store.canCopyTitleStyle)
        store.undo()
        for id in plain {
            XCTAssertEqual(store.clips[id]?.title?.font, VETitleFont.system(weight: .semibold), "one undo step for all")
        }
        // Titles with different styles: nothing to copy, and the command says why.
        store.selection = [styled, plain[0]]
        XCTAssertFalse(store.canCopyTitleStyle)
        store.copyTitleStyle()
        XCTAssertEqual(store.statusMessage,
                       "The selected titles have different styles: select one title to copy its style.")
    }

    func testPasteStyleLeavesOtherClipsOut() async throws {
        let (styled, plain) = try titles()
        let media = try await fixture.importMedia()
        let movie = try fixture.placeMovie(media.movie, at: 0)
        store.selection = [styled]
        store.copyTitleStyle()
        store.selection = [movie, plain[1]]
        XCTAssertTrue(store.canPasteTitleStyle)
        XCTAssertTrue(store.pasteTitleStyle())
        XCTAssertTrue(store.clips[plain[1]]?.title?.outline ?? false)
        XCTAssertNil(store.clips[movie]?.title)
        // The movie's context menu still offers its grade, not a style.
        store.selection = [movie]
        XCTAssertNotNil(try contextItem("Copy Grade", on: movie))
        XCTAssertNil(try contextItem("Copy Style", on: movie))
        // Only the movie selected: Paste Style does not apply.
        XCTAssertFalse(store.canPasteTitleStyle)
        XCTAssertFalse(store.pasteTitleStyle())
        XCTAssertEqual(store.statusMessage, "Select the titles to paste the style onto.")
    }
}
