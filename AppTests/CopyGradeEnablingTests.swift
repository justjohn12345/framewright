import CoreMedia
import FramewrightEngine
import XCTest
@testable import Framewright

/// When Copy Grade applies, in the Clip menu (`ProjectStore.canCopyGrade`, which its item's enabled
/// state reads) and in the clip's context menu alike: exactly one video clip selected, or several
/// whose grades are identical (then their shared grade is copied); several clips with different
/// grades: disabled, and the command copies nothing. Paste Grade and Reset Grade are unchanged.
@MainActor
final class CopyGradeEnablingTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("copygrade")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    /// Three movie clips on V1 at 0 s, 1 s and 2 s (the first linked to a tone clip on A1); returns the
    /// three clips and the tone clip.
    private func clips() async throws -> (VEClipID, VEClipID, VEClipID, VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        let third = try fixture.placeMovie(movie, at: 2)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let sound = try XCTUnwrap(store.selection.first)
        XCTAssertTrue(store.engine.linkClip(first, withClip: sound).ok)
        return (first, second, third, sound)
    }

    private func look(exposure: Double, saturation: Double) -> VEGradeParams {
        var grade = VEGradeParamsNeutral()
        grade.exposure = exposure
        grade.saturation = saturation
        return grade
    }

    private func setGrade(_ grade: VEGradeParams, _ clips: [VEClipID]) {
        XCTAssertTrue(store.engine.setGrade(grade, forClips: clips.map { NSNumber(value: $0) }).ok)
    }

    /// The context menu's item of `title` for a right-click on `clip` (which is in the selection, so the
    /// selection stays).
    private func contextItem(_ title: String, on clip: VEClipID, file: StaticString = #filePath,
                             line: UInt = #line) throws -> ContextMenuItem {
        let model = store.timelineModel
        let info = try XCTUnwrap(store.clips[clip], file: file, line: line)
        let row = try XCTUnwrap(model.layout(forTrack: info.trackID), file: file, line: line)
        let middle = CMTimeGetSeconds(info.timelineStart) + CMTimeGetSeconds(info.duration) / 2
        let selection = store.selection
        let items = TimelineGestureController(store: store)
            .contextMenuItems(at: CGPoint(x: model.x(forTime: middle), y: row.y + 20))
        XCTAssertEqual(store.selection, selection, "the right-click keeps the selection", file: file, line: line)
        return try XCTUnwrap(items.first { $0.title == title }, "\(title) in the menu", file: file, line: line)
    }

    /// Copy Grade's enabled state in the Clip menu and in the context menu, which must agree.
    private func copyGradeEnabled(rightClicking clip: VEClipID, file: StaticString = #filePath,
                                  line: UInt = #line) throws -> Bool {
        let menu = store.canCopyGrade
        let context = try contextItem("Copy Grade", on: clip, file: file, line: line).isEnabled
        XCTAssertEqual(menu, context, "the Clip menu and the context menu agree", file: file, line: line)
        return menu
    }

    func testOneClipCanBeCopied() async throws {
        let (first, _, third, sound) = try await clips()
        setGrade(look(exposure: 0.5, saturation: 1.4), [first])

        // One video clip, also with its linked sound selected.
        for selection: Set<VEClipID> in [[first], [first, sound]] {
            store.selection = selection
            XCTAssertTrue(try copyGradeEnabled(rightClicking: first), "\(selection)")
        }
        try contextItem("Copy Grade", on: first).action()
        XCTAssertTrue(store.hasCopiedGrade)
        XCTAssertEqual(store.statusMessage, "Copied the grade of “clip.mov”.")
        XCTAssertEqual(store.engine.copiedGrade.exposure, 0.5)

        // Paste is unchanged.
        store.selection = [third]
        XCTAssertTrue(try contextItem("Paste Grade", on: third).isEnabled)
        XCTAssertTrue(store.pasteGrade())
        XCTAssertEqual(store.clips[third]?.grade.saturation, 1.4)

        // An ungraded clip alone can be copied too (it copies "no grade"), as before.
        store.selection = [third]
        XCTAssertTrue(store.resetGrade())
        XCTAssertTrue(try copyGradeEnabled(rightClicking: third))
    }

    func testTwoClipsWithEqualGradesCanBeCopied() async throws {
        let (first, second, third, sound) = try await clips()
        let shared = look(exposure: -0.75, saturation: 0.6)
        setGrade(shared, [first, second])

        store.selection = [first, second, sound]
        XCTAssertTrue(try copyGradeEnabled(rightClicking: second))
        store.copyGrade()
        XCTAssertTrue(store.hasCopiedGrade)
        XCTAssertEqual(store.statusMessage, "Copied the grade of the 2 selected clips.")
        XCTAssertEqual(store.engine.copiedGrade.exposure, -0.75)
        XCTAssertEqual(store.engine.copiedGrade.saturation, 0.6)

        // Pasting it onto the third clip gives it the shared grade.
        store.selection = [third]
        XCTAssertTrue(store.pasteGrade())
        XCTAssertEqual(store.clips[third]?.grade.exposure, -0.75)
        XCTAssertEqual(store.clips[third]?.grade.saturation, 0.6)

        // Two ungraded clips are equal too.
        store.selection = [first, second]
        XCTAssertTrue(store.resetGrade())
        XCTAssertTrue(try copyGradeEnabled(rightClicking: first))
    }

    func testTwoClipsWithDifferentGradesCannotBeCopied() async throws {
        let (first, second, third, _) = try await clips()
        setGrade(look(exposure: 1, saturation: 1.2), [first])
        setGrade(look(exposure: 1, saturation: 0.8), [second])
        // Something copied earlier, from the third clip.
        setGrade(look(exposure: -2, saturation: 1), [third])
        store.selection = [third]
        store.copyGrade()
        XCTAssertEqual(store.engine.copiedGrade.exposure, -2)

        // One value differs: disabled in both menus.
        store.selection = [first, second]
        XCTAssertFalse(try copyGradeEnabled(rightClicking: first))
        XCTAssertFalse(try copyGradeEnabled(rightClicking: second))
        // A graded clip and an ungraded one differ too.
        store.selection = [second, third]
        XCTAssertTrue(store.resetGrade())
        store.selection = [first, third]
        XCTAssertFalse(try copyGradeEnabled(rightClicking: third))

        // The command (its shortcut is disabled with the item; called anyway) copies nothing and says why.
        store.selection = [first, second]
        store.copyGrade()
        XCTAssertEqual(store.statusMessage, "The selected clips have different grades: select one clip to copy its grade.")
        XCTAssertEqual(store.engine.copiedGrade.exposure, -2, "what was copied before stays")

        // Paste and Reset still apply to the selection.
        XCTAssertTrue(try contextItem("Paste Grade", on: first).isEnabled)
        XCTAssertTrue(store.canPasteGrade)
        XCTAssertTrue(try contextItem("Reset Grade", on: first).isEnabled)
        XCTAssertTrue(store.canResetGrade)
        XCTAssertTrue(store.pasteGrade())
        XCTAssertEqual(store.clips[first]?.grade.exposure, -2)
        XCTAssertEqual(store.clips[second]?.grade.exposure, -2)

        // Now equal: Copy is enabled again.
        XCTAssertTrue(try copyGradeEnabled(rightClicking: first))
    }
}
