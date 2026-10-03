import AppKit
import CoreMedia
import FramewrightEngine
import QuartzCore
import SwiftUI
import XCTest
@testable import Framewright

/// The program monitor as a person sees it while editing titles on the picture (titles slice 2): the program's own
/// picture (drawn by a program view in no window, offscreen) under the monitor's layout and its overlays (the title's
/// box, the caret and the selection of typing on the picture, the safe-area guides, the line a drag snapped to),
/// rendered together offscreen, never captured from the screen. Each scene checks that the caret or the selection is
/// drawn over the title where the engine lays its text out, and is written as a PNG file when FW_SNAPSHOTS=1
/// (`TestSnapshots`): the caret and selection on a turned and zoomed title, a snapped drag with the guides, and each
/// preset.
@MainActor
final class TitleOnPictureSnapshotTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var programView: VEPreviewView?
    private let size = NSSize(width: 960, height: 540)

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("titleSnapshots")
        try fixture.configureSequence() // 1920x1080
        TitleInspectorModel.typingIdleSeconds = 60
        let (movie, _) = try await fixture.importMedia()
        let v1 = try XCTUnwrap(store.videoTracks.first).trackID
        XCTAssertTrue(store.place(asset: movie.assetID, at: .zero, videoTrack: v1, audioTrack: 0, overwrite: true))
        store.targetVideoTrackID = v1
        let view = VEPreviewView(frame: NSRect(origin: .zero, size: size))
        store.attachProgramView(view)
        programView = view
    }

    override func tearDown() async throws {
        TitleInspectorModel.typingIdleSeconds = 2.0
        fixture?.store.engine.attachProgramView(nil)
        programView = nil
        fixture?.cleanUp()
        fixture = nil
    }

    private func frames(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 30) }

    /// The program's picture at the playhead once it is complete and no longer changes.
    private func programPicture() async throws -> CGImage {
        let view = try XCTUnwrap(programView)
        var previous: Data?
        for _ in 0 ..< 100 {
            await StoreFixture.wait(until: { false }, timeout: 0.05)
            guard view.missingLayerCount == 0, let image = view.snapshot(),
                  let data = image.dataProvider?.data as Data? else { continue }
            if data == previous { return image }
            previous = data
        }
        return try XCTUnwrap(view.snapshot(), "the program picture")
    }

    /// The monitor's layout over `picture`, hosted in a window, rendered with its layers (the typing surface draws
    /// with Core Animation layers, which a view's own drawing leaves out).
    private func compose(_ picture: CGImage, host: HostedView) async -> NSBitmapImageRep? {
        await host.settle()
        guard let layer = host.host.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return rep
    }

    private func host(_ picture: CGImage) -> HostedView {
        let hosted = HostedView(ProgramMonitorLayout(store: store) {
            Image(decorative: picture, scale: 1).resizable()
        }, size: size)
        store.editorWindow = hosted.window
        return hosted
    }

    private var viewport: KenBurnsViewport {
        KenBurnsViewport(sequence: CGSize(width: 1920, height: 1080), monitor: size, margin: 0)
    }

    /// The colour at a monitor point of `rep` (top-left origin).
    private func colour(_ rep: NSBitmapImageRep, _ point: CGPoint) -> NSColor? {
        rep.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB)
    }

    /// Adds `preset` at 0 with the playhead on frame 10; returns the selected title (the card's title).
    private func add(_ preset: GeneratorPreset) throws -> VEClipID {
        store.playheadTime = frames(0)
        XCTAssertTrue(store.addGenerated(preset))
        let id = try XCTUnwrap(store.selection.first)
        store.playheadTime = frames(10)
        store.titleBox?.setPlayhead(frames(10))
        return id
    }

    func testTheCaretAndTheSelectionOnATurnedZoomedTitle() async throws {
        let id = try add(.lowerThird)
        XCTAssertTrue(store.engine.setTitleText("Jane Doe\nDirector of photography", clips: [NSNumber(value: id)]).ok)
        XCTAssertTrue(store.engine.setVideoParams(VEVideoParams(x: 120, y: -80, scale: 1.25, rotationDegrees: -6,
                                                                opacity: 1), forClip: id).ok)
        let box = try XCTUnwrap(store.titleBox)
        box.update(clip: try XCTUnwrap(store.engine.clipInfo(id)))
        let picture = try await programPicture()
        let hosted = host(picture)
        defer { hosted.close() }
        XCTAssertTrue(box.beginEditing(.selectAll))
        await hosted.settle()
        let textView = try XCTUnwrap(hosted.window.firstResponder as? TitleEditingTextView)
        let editor = try XCTUnwrap(box.editor)
        // A caret after "Jane".
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let caretComposed = await compose(picture, host: hosted)
        let caretShot = try XCTUnwrap(caretComposed)
        TestSnapshots.write(caretShot, name: "typing-caret")
        let caret = try XCTUnwrap(editor.caret(at: 4))
        let middle = viewport.view(CGPoint(x: (caret.top.x + caret.bottom.x) / 2, y: (caret.top.y + caret.bottom.y) / 2))
        let onCaret = try XCTUnwrap(colour(caretShot, middle))
        // "Director" selected.
        textView.setSelectedRange(NSRange(location: 9, length: 8))
        let selectionComposed = await compose(picture, host: hosted)
        let selectionShot = try XCTUnwrap(selectionComposed)
        TestSnapshots.write(selectionShot, name: "typing-selection")
        // The caret is a light line where the engine puts it: lighter there than the same place without it.
        let withoutCaret = try XCTUnwrap(colour(selectionShot, middle))
        func brightness(_ colour: NSColor) -> CGFloat { (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3 }
        XCTAssertGreaterThan(brightness(onCaret), 0.6, "the caret (\(onCaret))")
        XCTAssertGreaterThan(brightness(onCaret), brightness(withoutCaret) + 0.3, "no caret there while a word is selected")
        let quad = try XCTUnwrap(editor.selectionQuads(NSRange(location: 9, length: 8)).first)
        let corner = viewport.view(CGPoint(x: quad.topLeft.x + (quad.bottomRight.x - quad.topLeft.x) * 0.02,
                                           y: quad.topLeft.y + (quad.bottomRight.y - quad.topLeft.y) * 0.1))
        let selected = try XCTUnwrap(colour(selectionShot, corner))
        let unselected = try XCTUnwrap(colour(caretShot, corner))
        XCTAssertGreaterThan(selected.blueComponent - selected.redComponent,
                             unselected.blueComponent - unselected.redComponent + 0.1,
                             "the selection tints the picture blue there")
        box.endEditing()
    }

    func testASnappedDragWithTheGuides() async throws {
        store.showsSafeAreas = true
        let id = try add(.title)
        let box = try XCTUnwrap(store.titleBox)
        // Dragged towards title-safe's left edge, snapping onto it, the drag still held.
        let block = store.engine.titleBlock(ofClip: id)
        box.applyDrag(.body, translation: CGSize(width: 96 - block.minX + 5, height: -300), snapping: true)
        XCTAssertEqual(box.snapLines.map(\.kind), [.titleSafe])
        let picture = try await programPicture()
        let hosted = host(picture)
        defer { hosted.close() }
        let composed = await compose(picture, host: hosted)
        let shot = try XCTUnwrap(composed)
        TestSnapshots.write(shot, name: "snapped-drag")
        // The snapped line is drawn (pink) across the frame at title-safe's left (96 px: 48 points).
        let line = try XCTUnwrap(colour(shot, CGPoint(x: 48, y: 500)))
        XCTAssertGreaterThan(line.redComponent - line.greenComponent, 0.3, "the snap line (\(line))")
        box.endDrag()
    }

    func testThePresets() async throws {
        store.showsSafeAreas = true
        for preset in GeneratorPreset.allCases where preset != .colourMatte {
            let id = try add(preset)
            let picture = try await programPicture()
            let hosted = host(picture)
            let composed = await compose(picture, host: hosted)
            let shot = try XCTUnwrap(composed)
            TestSnapshots.write(shot, name: "preset-\(preset.rawValue)")
            // The box (yellow) outlines the title's block.
            let block = store.engine.titleBlock(ofClip: id)
            let edge = viewport.view(CGPoint(x: block.minX, y: block.midY))
            let yellow = (-1 ... 1).compactMap { dx in colour(shot, CGPoint(x: edge.x + CGFloat(dx), y: edge.y)) }
                .contains { $0.redComponent > 0.8 && $0.greenComponent > 0.6 && $0.blueComponent < 0.5 }
            XCTAssertTrue(yellow, "\(preset.title): its box on the monitor")
            hosted.close()
            store.undo()
        }
    }
}
