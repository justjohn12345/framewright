import AppKit
import CoreMedia
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The editor window's layout model (open findings 4-6): the source monitor's visibility, the
/// right panel's tab, the timeline pane sized to its tracks, the split positions persisted across
/// launches, and collapsed empty tracks.
@MainActor
final class WindowLayoutTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func suite() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "layout-\(UUID())"))
    }

    // MARK: Source monitor visibility

    func testTheSourceMonitorIsHiddenUntilMediaIsOpenedInIt() async throws {
        let store = fixture.store
        XCTAssertFalse(store.layout.showsSourceMonitor, "hidden by default: the program monitor takes the centre")
        XCTAssertFalse(store.engine.sourceMonitorVisible, "the engine knows it is hidden")
        let (movie, _) = try await fixture.importMedia()
        store.showInSourceMonitor(movie.assetID)
        XCTAssertTrue(store.layout.showsSourceMonitor, "a double-click in the bin shows it")
        XCTAssertTrue(store.engine.sourceMonitorVisible)
        XCTAssertEqual(store.focusArea, .sourceMonitor)

        // Hiding it while it plays pauses it and gives the transport keys back to the program.
        store.engine.sourceMonitorTogglePlay()
        let running = await StoreFixture.wait(until: { store.engine.sourceMonitorPlaybackState != .stopped },
                                              timeout: 10)
        XCTAssertTrue(running)
        store.setSourceMonitorVisible(false)
        XCTAssertFalse(store.layout.showsSourceMonitor)
        XCTAssertEqual(store.engine.sourceMonitorPlaybackState, .stopped, "hiding pauses the source")
        XCTAssertEqual(store.focusArea, .timeline)
        XCTAssertEqual(store.source.assetID, movie.assetID, "the asset and its marks stay for next time")
        // UX round review finding 4: hidden, its controller keeps no lookahead (no decode streams).
        XCTAssertFalse(store.engine.sourceMonitorVisible)
        let dropped = await StoreFixture.wait(until: { store.engine.sourceMonitorPlaybackStats.decodeStreams == 0 },
                                              timeout: 5)
        XCTAssertTrue(dropped, "hidden: the source monitor's pool holds no streams")
        store.setSourceMonitorVisible(true)
        XCTAssertTrue(store.layout.showsSourceMonitor)
        XCTAssertTrue(store.engine.sourceMonitorVisible)
        let resumed = await StoreFixture.wait(until: { store.engine.sourceMonitorPlaybackStats.decodeStreams > 0 },
                                              timeout: 5)
        XCTAssertTrue(resumed, "shown: the lookahead resumes at the paused frame")
        // Reset Window Layout hides it through the same path.
        store.setSourceMonitorVisible(false)
        store.layout.resetToDefaults()
        XCTAssertFalse(store.engine.sourceMonitorVisible)
        store.setSourceMonitorVisible(true)

        // Focusing a field of the inspector brings its tab to the front.
        store.layout.inspectorTab = .effects
        store.requestInspectorFocus(.transitionDuration)
        XCTAssertEqual(store.layout.inspectorTab, .inspector)
    }

    func testAStoreForTestsKeepsItsLayoutInMemory() {
        XCTAssertNil(fixture.store.layout.defaults, "tests never change the app's saved layout")
        let before = UserDefaults.standard.object(forKey: WindowLayoutModel.sourceMonitorKey) as? Bool
        fixture.store.setSourceMonitorVisible(true)
        XCTAssertEqual(UserDefaults.standard.object(forKey: WindowLayoutModel.sourceMonitorKey) as? Bool, before)
    }

    // MARK: Persistence

    func testTheLayoutPersistsAcrossLaunches() throws {
        let defaults = try suite()
        let first = WindowLayoutModel(defaults: defaults)
        XCTAssertFalse(first.showsSourceMonitor)
        XCTAssertEqual(first.inspectorTab, .inspector)
        XCTAssertEqual(first.mediaBinWidth, WindowLayoutModel.defaultMediaBinWidth)
        XCTAssertNil(first.timelineHeight, "fits its tracks until dragged")
        first.showsSourceMonitor = true
        first.inspectorTab = .effects
        first.setMediaBinWidth(300)
        first.setInspectorWidth(320)
        first.setSourceMonitorFraction(0.5)
        first.setTimelineHeight(310, windowHeight: 900)

        let relaunched = WindowLayoutModel(defaults: defaults)
        XCTAssertTrue(relaunched.showsSourceMonitor)
        XCTAssertEqual(relaunched.inspectorTab, .effects)
        XCTAssertEqual(relaunched.mediaBinWidth, 300)
        XCTAssertEqual(relaunched.inspectorWidth, 320)
        XCTAssertEqual(relaunched.sourceMonitorFraction, 0.5)
        XCTAssertEqual(relaunched.timelineHeight, 310)

        // Out-of-range values (a hand-edited or old file) are clamped when read and when set.
        defaults.set(5000.0, forKey: WindowLayoutModel.mediaBinWidthKey)
        defaults.set(-3.0, forKey: WindowLayoutModel.sourceFractionKey)
        defaults.set("sideways", forKey: WindowLayoutModel.inspectorTabKey)
        let clamped = WindowLayoutModel(defaults: defaults)
        XCTAssertEqual(clamped.mediaBinWidth, WindowLayoutModel.mediaBinWidths.upperBound)
        XCTAssertEqual(clamped.sourceMonitorFraction, WindowLayoutModel.sourceFractions.lowerBound)
        XCTAssertEqual(clamped.inspectorTab, .inspector)
        clamped.setInspectorWidth(10)
        XCTAssertEqual(clamped.inspectorWidth, WindowLayoutModel.inspectorWidths.lowerBound)

        // Double-click on the divider: fit again (and forget the dragged height).
        clamped.fitTimelineToContent()
        XCTAssertNil(clamped.timelineHeight)
        XCTAssertNil(WindowLayoutModel(defaults: defaults).timelineHeight)
        clamped.resetToDefaults()
        let reset = WindowLayoutModel(defaults: defaults)
        XCTAssertFalse(reset.showsSourceMonitor)
        XCTAssertEqual(reset.mediaBinWidth, WindowLayoutModel.defaultMediaBinWidth)
        XCTAssertEqual(reset.inspectorTab, .inspector)
    }

    // MARK: Side panels and the source monitor divider (UX round review, test gap 4)

    /// At the window's minimum width (1100 pt) the monitors keep `minimumCentreWidth`: the inspector
    /// gives up width first, down to its minimum, and only then the bin.
    func testTheSidePanelsNarrowInspectorFirstAtTheMinimumWindowWidth() {
        let window: CGFloat = 1100
        let dividers = 2 * WindowLayoutModel.dividerThickness
        let centre = ContentView.minimumCentreWidth
        func centreWidth(_ sides: (bin: CGFloat, inspector: CGFloat)) -> CGFloat {
            window - sides.bin - sides.inspector - dividers
        }

        // The defaults fit: nothing narrows.
        let defaults = ContentView.sideWidths(windowWidth: window, binWidth: WindowLayoutModel.defaultMediaBinWidth,
                                              inspectorWidth: WindowLayoutModel.defaultInspectorWidth)
        XCTAssertEqual(defaults.bin, WindowLayoutModel.defaultMediaBinWidth)
        XCTAssertEqual(defaults.inspector, WindowLayoutModel.defaultInspectorWidth)
        XCTAssertGreaterThan(centreWidth(defaults), centre)

        // 130 pt too wide: only the inspector narrows (it has 160 pt above its minimum).
        let some = ContentView.sideWidths(windowWidth: window, binWidth: 400, inspectorWidth: 400)
        XCTAssertEqual(some.bin, 400, "the bin keeps its width while the inspector can give")
        XCTAssertEqual(some.inspector, 270)
        XCTAssertEqual(centreWidth(some), centre, accuracy: 1e-9)

        // Both at their maximum (270 pt too wide): the inspector goes to its minimum (220 pt), then
        // the bin gives the remaining 50 pt.
        let widest = ContentView.sideWidths(windowWidth: window, binWidth: WindowLayoutModel.mediaBinWidths.upperBound,
                                            inspectorWidth: WindowLayoutModel.inspectorWidths.upperBound)
        XCTAssertEqual(widest.inspector, WindowLayoutModel.inspectorWidths.lowerBound)
        XCTAssertEqual(widest.bin, WindowLayoutModel.mediaBinWidths.upperBound - 50)
        XCTAssertEqual(centreWidth(widest), centre, accuracy: 1e-9)

        // A window narrower than both minimums allow: both at their minimum (the window's minimum
        // size keeps this from happening; the panels never go below their own minimums).
        let narrow = ContentView.sideWidths(windowWidth: 700, binWidth: 300, inspectorWidth: 300)
        XCTAssertEqual(narrow.inspector, WindowLayoutModel.inspectorWidths.lowerBound)
        XCTAssertEqual(narrow.bin, WindowLayoutModel.mediaBinWidths.lowerBound)
    }

    /// Dragging the divider between the monitors past either bound clamps the source monitor's share
    /// (and what is saved); dragging back follows the pointer again, relative to the drag's start.
    func testDraggingTheSourceMonitorDividerPastItsBoundsClamps() throws {
        let defaults = try suite()
        let layout = WindowLayoutModel(defaults: defaults)
        let start = layout.sourceMonitorFraction
        XCTAssertEqual(start, WindowLayoutModel.defaultSourceFraction)
        let area: CGFloat = 800

        layout.dragSourceMonitorDivider(from: start, by: 40, areaWidth: area)
        XCTAssertEqual(layout.sourceMonitorFraction, start + 0.05, accuracy: 1e-9, "follows the pointer")
        let bounds = WindowLayoutModel.sourceFractions
        let saved = { defaults.double(forKey: WindowLayoutModel.sourceFractionKey) }
        layout.dragSourceMonitorDivider(from: start, by: 600, areaWidth: area)
        XCTAssertEqual(layout.sourceMonitorFraction, bounds.upperBound, "clamped at the top")
        XCTAssertEqual(saved(), bounds.upperBound)
        layout.dragSourceMonitorDivider(from: start, by: -600, areaWidth: area)
        XCTAssertEqual(layout.sourceMonitorFraction, bounds.lowerBound, "clamped at the bottom")
        XCTAssertEqual(saved(), bounds.lowerBound)
        layout.dragSourceMonitorDivider(from: start, by: -8, areaWidth: area)
        XCTAssertEqual(layout.sourceMonitorFraction, start - 0.01, accuracy: 1e-9,
                       "back inside: under the pointer again")
        // A zero-width area (not laid out yet) or a non-finite translation changes nothing.
        let before = layout.sourceMonitorFraction
        layout.dragSourceMonitorDivider(from: start, by: 100, areaWidth: 0)
        layout.dragSourceMonitorDivider(from: start, by: .infinity, areaWidth: area)
        XCTAssertEqual(layout.sourceMonitorFraction, before)
    }

    // MARK: Timeline height

    func testTheTimelineFitsItsTracksWithinBounds() throws {
        let layout = WindowLayoutModel(defaults: nil)
        let chrome = TimelineView.rulerHeight + TimelineView.scrollBarHeight
        // Two video and two audio rows (the default sequence): 64 + 64 + 48 + 48 + 3 spacings.
        let content: CGFloat = 2 * 64 + 2 * 48 + 3 * 2
        let fitted = WindowLayoutModel.fittedTimelineHeight(contentHeight: content)
        XCTAssertGreaterThanOrEqual(fitted, content + chrome)
        XCTAssertLessThan(fitted, content + chrome + 8)
        XCTAssertEqual(layout.timelineHeight(contentHeight: content, windowHeight: 900), fitted,
                       "the rows, nothing more: the monitors get the rest")
        // Few tracks: the minimum. Many: at most the maximum share, the monitors keep their room.
        XCTAssertEqual(layout.timelineHeight(contentHeight: 20, windowHeight: 900), WindowLayoutModel.minimumTimelineHeight)
        let tall = layout.timelineHeight(contentHeight: 2000, windowHeight: 900)
        XCTAssertEqual(tall, 900 * WindowLayoutModel.maximumTimelineShare)
        XCTAssertLessThanOrEqual(tall, 900 - WindowLayoutModel.minimumMonitorHeight)
        // Dragged: kept whatever the tracks, but never more than the window allows.
        layout.setTimelineHeight(400, windowHeight: 900)
        XCTAssertEqual(layout.timelineHeight(contentHeight: content, windowHeight: 900), 400)
        XCTAssertEqual(layout.timelineHeight(contentHeight: content, windowHeight: 640),
                       min(640 * WindowLayoutModel.maximumTimelineShare,
                           640 - WindowLayoutModel.minimumMonitorHeight - WindowLayoutModel.dividerThickness),
                       "a height saved on a larger screen still leaves the monitors their room")
        XCTAssertEqual(layout.timelineHeight, 400, "the saved height itself is kept for a larger window")
        layout.setTimelineHeight(10, windowHeight: 900)
        XCTAssertEqual(layout.timelineHeight, WindowLayoutModel.minimumTimelineHeight)
    }

    func testTheTimelineContentHeightFollowsTracksAndCollapsedRows() throws {
        let store = fixture.store
        let initial = store.timelineContentHeight
        XCTAssertEqual(initial, 2 * TimelineViewModel.videoTrackHeight + 2 * TimelineViewModel.audioTrackHeight
            + 3 * TimelineViewModel.trackSpacing)
        XCTAssertTrue(store.engine.addTrack(of: .audio, name: nil).ok)
        XCTAssertEqual(store.timelineContentHeight,
                       initial + TimelineViewModel.audioTrackHeight + TimelineViewModel.trackSpacing)
    }

    // MARK: Collapsed empty tracks

    func testEmptyTracksCollapseAndExpandWhenTheyGetAClip() async throws {
        let store = fixture.store
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        let v2 = try XCTUnwrap(store.videoTracks.last).trackID
        try fixture.placeMovie(movie, at: 0, track: v1)
        let full = store.timelineContentHeight
        let builds = store.timelineBuildCount

        store.setTrack(v1, collapsed: true)
        XCTAssertFalse(store.isTrackCollapsed(v1), "a track with clips does not collapse")
        store.setTrack(v2, collapsed: true)
        XCTAssertTrue(store.isTrackCollapsed(v2))
        let row = try XCTUnwrap(store.timelineModel.trackLayouts.first { $0.track.id == v2 })
        XCTAssertEqual(row.height, TimelineViewModel.collapsedTrackHeight, "a collapsed row is short")
        XCTAssertTrue(row.track.collapsed)
        XCTAssertEqual(store.timelineContentHeight,
                       full - TimelineViewModel.videoTrackHeight + TimelineViewModel.collapsedTrackHeight)
        XCTAssertEqual(store.timelineBuildCount, builds + 1, "rebuilt once for the collapse")
        _ = store.timelineModel
        XCTAssertEqual(store.timelineBuildCount, builds + 1, "and cached again")

        // A clip placed on the collapsed track shows it at full height again.
        try fixture.placeMovie(movie, at: 3, track: v2)
        XCTAssertFalse(store.isTrackCollapsed(v2))
        XCTAssertEqual(store.timelineModel.trackLayouts.first { $0.track.id == v2 }?.height,
                       TimelineViewModel.videoTrackHeight)
        store.setTrack(v2, collapsed: false)
        XCTAssertFalse(store.collapsedTrackIDs.contains(v2))

        // A new project forgets collapse states (track ids restart).
        store.setTrack(try XCTUnwrap(store.audioTracks.last).trackID, collapsed: true)
        store.newProject()
        XCTAssertTrue(store.collapsedTrackIDs.isEmpty)
    }
}
