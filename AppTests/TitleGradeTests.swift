import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// Titles and colour mattes are not graded (titles design section 5, owner decision 3; slice 1): Copy, Paste and
/// Reset Grade leave them out (and are disabled when only they are selected), the Colour tab's tools edit only the
/// other clips and say why titles are left out, and the inspector shows no Colour rows for them.
@MainActor
final class TitleGradeTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
        fixture = nil
    }

    func testCopyPasteAndResetGradeSkipTitles() async throws {
        let media = try await fixture.importMedia()
        let movie = try fixture.placeMovie(media.movie, at: 0)
        store.targetVideoTrackID = store.videoTracks[0].trackID
        store.playheadTime = .zero
        XCTAssertTrue(store.addGenerated(.title))
        let title = try XCTUnwrap(store.selection.first)
        store.playheadTime = CMTime(value: 300, timescale: 30)
        XCTAssertTrue(store.addGenerated(.colourMatte))
        let matte = try XCTUnwrap(store.selection.first)

        // Only titles and mattes selected: nothing to grade.
        store.selection = [title, matte]
        XCTAssertTrue(store.gradeTargets.isEmpty)
        XCTAssertFalse(store.canCopyGrade)
        XCTAssertFalse(store.canResetGrade)
        store.copyGrade()
        XCTAssertEqual(store.statusMessage, "Select a video clip to copy its grade.")
        XCTAssertFalse(store.gradeTools.isAvailable)
        XCTAssertEqual(store.gradeTools.ungradedGenerated, 2)
        XCTAssertFalse(store.inspector.isAvailable(.exposure))

        // The footage graded and copied; pasted onto footage and a title: the footage only.
        store.selection = [movie]
        XCTAssertTrue(store.engine.setGradeValue(1, for: .exposure, clips: [NSNumber(value: movie)]).ok)
        store.copyGrade()
        XCTAssertTrue(store.hasCopiedGrade)
        XCTAssertTrue(store.engine.resetGrade(ofClips: [NSNumber(value: movie)]).ok)
        store.selection = [movie, title]
        XCTAssertEqual(store.gradeTargets.map(\.clipID), [movie])
        XCTAssertTrue(store.canCopyGrade, "one gradable clip: its grade")
        XCTAssertTrue(store.canPasteGrade)
        XCTAssertTrue(store.pasteGrade())
        XCTAssertEqual(store.clips[movie]?.grade.exposure, 1)
        XCTAssertEqual(store.clips[title]?.hasGrade, false)
        store.selection = [title]
        XCTAssertFalse(store.canPasteGrade, "a title alone takes no grade")
        XCTAssertFalse(store.pasteGrade())
        XCTAssertEqual(store.statusMessage, "Select the video clips to paste the grade onto.")
        store.selection = [title, movie]
        XCTAssertTrue(store.canResetGrade)
        XCTAssertTrue(store.resetGrade())
        XCTAssertEqual(store.clips[movie]?.hasGrade, false)
        // The Colour tab edits the footage only.
        XCTAssertEqual(store.gradeTools.videoTargets.map(\.clipID), [movie])
        XCTAssertEqual(store.gradeTools.ungradedGenerated, 1)
    }

    func testTheColourTabSaysTitlesAreNotGraded() async throws {
        store.playheadTime = .zero
        XCTAssertTrue(store.addGenerated(.title))
        let hosted = HostedView(ColourPanel(store: store), size: NSSize(width: 320, height: 400))
        defer { hosted.close() }
        let withNote = await hosted.pixels()
        store.selection = []
        let empty = await hosted.pixels()
        XCTAssertNotEqual(withNote, empty, "the note is drawn for a selected title")
    }
}
