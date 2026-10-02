import AppKit
import FramewrightEngine
import SwiftUI
import XCTest
@testable import Framewright

/// The Colour tab's wheels (`GradeToolsModel`, `ColourWheelControl`): one clip shows its wheels; several
/// show where they agree and "mixed" where they differ (colour and level separately); moving a wheel's
/// colour over several clips keeps each clip's level, its level keeps each colour; a drag is one undo step;
/// resets; the colour stays in the disk; the wheel's drawing (neutral centre, saturated rim, each hue where
/// the puck adds it); the tab is a page of the right-hand panel and shows the wheels.
@MainActor
final class ColourWheelsTests: XCTestCase {
    private var fixture: StoreFixture!
    private var store: ProjectStore { fixture.store }
    private var tools: GradeToolsModel { store.gradeTools }

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try makeTestDefaults("colour-wheels")
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
    }

    private func wheel(_ id: VEClipID, _ wheel: VEGradeWheel) -> VEGradeWheelValue {
        store.clips[id]?.gradeWheel(wheel) ?? VEGradeWheelValueNeutral()
    }

    /// Two movie clips on V1 at 0 s and 1 s and the tone on A1; returns (first, second, tone clip).
    private func clips() async throws -> (VEClipID, VEClipID, VEClipID) {
        let (movie, tone) = try await fixture.importMedia()
        let first = try fixture.placeMovie(movie, at: 0)
        let second = try fixture.placeMovie(movie, at: 1)
        let a1 = try XCTUnwrap(store.audioTracks.first).trackID
        XCTAssertTrue(store.place(asset: tone.assetID, at: .zero, videoTrack: 0, audioTrack: a1,
                                  sourceIn: .zero, sourceOut: store.frameTime(1), overwrite: true))
        let sound = try XCTUnwrap(store.selection.first)
        return (first, second, sound)
    }

    func testTheWheelsOfOneAndSeveralClips() async throws {
        let (first, second, sound) = try await clips()
        store.selection = [sound]
        XCTAssertFalse(tools.isAvailable, "sound alone has no grade")
        store.selection = [first]
        XCTAssertTrue(tools.isAvailable)
        tools.setLevel(.gain, 0.5)
        XCTAssertEqual(wheel(first, .gain).level, 0.5)
        XCTAssertEqual(store.undoActionName, "Change Gain")
        tools.setColour(.gain, cb: 0.3, cr: -0.4)
        XCTAssertEqual(wheel(first, .gain).cb, 0.3)
        XCTAssertEqual(wheel(first, .gain).level, 0.5, "the colour keeps the level")
        XCTAssertEqual(tools.wheel(.gain).value.cr, -0.4)

        // Several clips (and their sound): the gain differs, the lift agrees.
        store.selection = [first, second, sound]
        XCTAssertEqual(tools.videoTargets.count, 2)
        let gain = tools.wheel(.gain)
        XCTAssertTrue(gain.colourMixed)
        XCTAssertTrue(gain.levelMixed)
        let lift = tools.wheel(.lift)
        XCTAssertFalse(lift.colourMixed)
        XCTAssertFalse(lift.levelMixed)

        // The colour over both keeps each clip's level; the level over both keeps each colour.
        tools.setColour(.gain, cb: 0, cr: 0.6)
        XCTAssertEqual(wheel(first, .gain).cr, 0.6)
        XCTAssertEqual(wheel(second, .gain).cr, 0.6)
        XCTAssertEqual(wheel(first, .gain).level, 0.5)
        XCTAssertEqual(wheel(second, .gain).level, 0)
        XCTAssertFalse(tools.wheel(.gain).colourMixed)
        XCTAssertTrue(tools.wheel(.gain).levelMixed)
        tools.setLevel(.gain, -0.25)
        XCTAssertEqual(wheel(second, .gain).level, -0.25)
        XCTAssertEqual(wheel(second, .gain).cr, 0.6)
        XCTAssertFalse(store.clips[sound]?.hasGrade ?? true)
        // Levels beyond the range are limited; a colour outside the disk lands on its rim.
        tools.setLevel(.lift, 7)
        XCTAssertEqual(wheel(first, .lift).level, 1)
        tools.setColour(.lift, cb: 3, cr: 4)
        XCTAssertEqual(wheel(first, .lift).cb, 0.6, accuracy: 1e-12)
        XCTAssertEqual(wheel(first, .lift).cr, 0.8, accuracy: 1e-12)
        XCTAssertEqual(GradeToolsModel.limitedColour(cb: .nan, cr: 1).cb, 0)
    }

    func testADragIsOneUndoStepAndTheResets() async throws {
        let (first, second, _) = try await clips()
        store.selection = [first, second]
        tools.beginDrag(.lift, part: "colour")
        for step in 1 ... 5 {
            tools.setColour(.lift, cb: -0.1 * Double(step), cr: 0.05 * Double(step))
        }
        tools.endDrag()
        XCTAssertEqual(wheel(second, .lift).cb, -0.5, accuracy: 1e-12)
        XCTAssertEqual(store.undoActionName, "Change Lift")
        store.undo()
        XCTAssertEqual(wheel(first, .lift).cb, 0, "one undo step for the drag")
        XCTAssertEqual(wheel(second, .lift).cb, 0)
        store.redo()

        tools.beginDrag(.gamma, part: "level")
        tools.setLevel(.gamma, 0.2)
        tools.setLevel(.gamma, 0.4)
        tools.endDrag()
        XCTAssertEqual(store.undoActionName, "Change Gamma")
        XCTAssertTrue(tools.anyWheelSet)

        tools.reset(.gamma)
        XCTAssertEqual(wheel(first, .gamma).level, 0)
        XCTAssertEqual(wheel(first, .lift).cb, -0.5, accuracy: 1e-12, "one wheel's reset keeps the others")
        store.selection = [first]
        store.inspector.setValue(.exposure, 1)
        store.selection = [first, second]
        tools.resetWheels()
        XCTAssertEqual(store.undoActionName, "Reset Wheels")
        XCTAssertFalse(tools.anyWheelSet)
        XCTAssertEqual(store.clips[first]?.grade.exposure, 1, "Reset Wheels keeps the basic grade")
        // The Colour section's Reset is Reset Grade: everything goes.
        tools.setLevel(.gain, 0.3)
        store.inspector.reset(.colour)
        XCTAssertFalse(store.clips[first]?.hasGrade ?? true)
        XCTAssertFalse(store.clips[second]?.hasGrade ?? true)
    }

    func testTheControlsTextAndGeometry() {
        XCTAssertEqual(ColourWheelControl.levelText(0), "0.00")
        XCTAssertEqual(ColourWheelControl.levelText(0.25), "+0.25")
        XCTAssertEqual(ColourWheelControl.levelText(-1), "-1.00")
        // (cb, cr) in a 100-point wheel: the centre, +cb right, +cr up.
        XCTAssertEqual(ColourWheelSurface.position(of: .zero, side: 100), CGPoint(x: 50, y: 50))
        XCTAssertEqual(ColourWheelSurface.position(of: CGPoint(x: 1, y: 0), side: 100), CGPoint(x: 100, y: 50))
        XCTAssertEqual(ColourWheelSurface.position(of: CGPoint(x: 0, y: 1), side: 100), CGPoint(x: 50, y: 0))
        // The hue ring: red where a vectorscope puts red (cr up, leaning left), blue to the right.
        let red = ColourWheelSurface.rgbOf(cb: -0.1, cr: 0.3, luma: 0.55)
        XCTAssertGreaterThan(red.r, red.b)
        let blue = ColourWheelSurface.rgbOf(cb: 0.3, cr: 0, luma: 0.55)
        XCTAssertGreaterThan(blue.b, blue.r)
        XCTAssertEqual(ColourWheelSurface.hues.count, 73)
        // The wheel's hues at full saturation, each the hue of its direction: BT.709's red, green and blue
        // directions give the primaries; any direction keeps the order of its channels.
        func direction(r: Double, g: Double, b: Double) -> (cb: Double, cr: Double) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return ((b - y) / 1.8556, (r - y) / 1.5748)
        }
        for primary: [Double] in [[1, 0, 0], [0, 1, 0], [0, 0, 1]] {
            let d = direction(r: primary[0], g: primary[1], b: primary[2])
            let saturated = ColourWheelSurface.saturatedRGBOf(cb: d.cb * 0.3, cr: d.cr * 0.3)
            XCTAssertEqual(saturated.r, primary[0], accuracy: 1e-4)
            XCTAssertEqual(saturated.g, primary[1], accuracy: 1e-4)
            XCTAssertEqual(saturated.b, primary[2], accuracy: 1e-4)
        }
        for step in 0 ..< 36 {
            let angle = Double(step) / 36 * 2 * .pi
            let small = ColourWheelSurface.rgbOf(cb: cos(angle) * 0.05, cr: sin(angle) * 0.05, luma: 0.5)
            let full = ColourWheelSurface.saturatedRGBOf(cb: cos(angle), cr: sin(angle))
            XCTAssertEqual(max(full.r, full.g, full.b), 1, accuracy: 1e-9)
            XCTAssertEqual(min(full.r, full.g, full.b), 0, accuracy: 1e-9)
            // The same hue: the channels in the same proportion above the weakest.
            let span = max(small.r, small.g, small.b) - min(small.r, small.g, small.b)
            let low = min(small.r, small.g, small.b)
            XCTAssertEqual((small.r - low) / span, full.r, accuracy: 1e-9)
            XCTAssertEqual((small.g - low) / span, full.g, accuracy: 1e-9)
            XCTAssertEqual((small.b - low) / span, full.b, accuracy: 1e-9)
        }
        XCTAssertTrue(ColourWheelSurface.saturatedRGBOf(cb: 0, cr: 0) == (0.5, 0.5, 0.5), "no direction: grey")
    }

    /// The wheel reads as a grading wheel: neutral grey at the centre (no change), the hues strong at the rim,
    /// each where the puck adds it (red up and to the left, blue to the right). Drawn offscreen.
    func testTheWheelIsNeutralAtTheCentreAndSaturatedAtTheRim() async throws {
        let side: CGFloat = 200
        let view = HostedView(ColourWheelSurface(colour: nil, onBegin: {}, onChange: { _ in }, onEnd: {})
            .frame(width: side, height: side), size: NSSize(width: side, height: side))
        defer { view.close() }
        _ = await view.pixels()
        let rep = try XCTUnwrap(view.bitmap())
        let scale = CGFloat(rep.pixelsWide) / side
        func colour(at colour: CGPoint) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let point = ColourWheelSurface.position(of: colour, side: side)
            let pixel = try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
                .usingColorSpace(.sRGB))
            return (pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
        }
        func chroma(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }

        // The centre (beside the cross): grey.
        let centre = try colour(at: CGPoint(x: 0.03, y: 0.03))
        XCTAssertLessThan(chroma(centre), 0.03, "the centre is neutral: \(centre)")
        // BT.709 red's direction (Cb -0.1146, Cr 0.5) and blue's (Cb 0.5, Cr -0.0458), on the ring and inside it.
        let red = CGPoint(x: -0.1146 / 0.513, y: 0.5 / 0.513)
        let blue = CGPoint(x: 0.5 / 0.502, y: -0.0458 / 0.502)
        for (direction, isRed) in [(red, true), (blue, false)] {
            for (radius, least) in [(CGFloat(0.97), CGFloat(0.7)), (0.8, 0.45)] {
                let c = try colour(at: CGPoint(x: direction.x * radius, y: direction.y * radius))
                XCTAssertGreaterThan(chroma(c), least, "strong colour at radius \(radius): \(c)")
                if isRed {
                    XCTAssertEqual(max(c.r, c.g, c.b), c.r, "red at red's direction: \(c)")
                } else {
                    XCTAssertEqual(max(c.r, c.g, c.b), c.b, "blue at blue's direction: \(c)")
                }
            }
        }
        // Half way out: some colour, less than at the rim.
        let half = try colour(at: CGPoint(x: red.x * 0.5, y: red.y * 0.5))
        XCTAssertGreaterThan(chroma(half), 0.15)
        XCTAssertLessThan(chroma(half), chroma(try colour(at: CGPoint(x: red.x * 0.97, y: red.y * 0.97))))
    }

    func testTheColourTabShowsTheWheels() async throws {
        XCTAssertEqual(InspectorTab.allCases, [.inspector, .colour, .effects])
        XCTAssertEqual(InspectorTab.colour.title, "Colour")
        let (first, _, _) = try await clips()
        store.selection = [first]
        store.layout.inspectorTab = .colour
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InspectorPanel(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
        // The wheels' hue rings are drawn: the page has saturated pixels (the rest of the panel is grey).
        XCTAssertGreaterThan(Self.saturatedPixels(of: host), 2000, "the Colour tab draws the three wheels")
        // Nothing selected: the tab says so instead, and draws no wheel.
        store.selection = []
        for _ in 0 ..< 5 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertLessThan(Self.saturatedPixels(of: host), 50)
    }

    /// The pixels of `view`'s drawing whose channels differ by more than 0.3 (strong colour).
    private static func saturatedPixels(of view: NSView) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
                if (channels.max() ?? 0) - (channels.min() ?? 0) > 0.3 { count += 1 }
            }
        }
        return count
    }
}
