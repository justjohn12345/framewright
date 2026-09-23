import AppKit
import CoreMedia
import VidEditEngine
import XCTest
@testable import VidEdit

/// An inspector change re-renders the program monitor's current frame by itself (the engine
/// hands the playback controller the new model, which asks the view to render), both while
/// paused and while playing. The test movie is one solid colour per frame (green channel 90 of
/// 255), composited over black: opacity 50 % dims it, 0 % leaves black.
@MainActor
final class ProgramRerenderTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUp() async throws {
        fixture = try StoreFixture()
        fixture.store.defaults = try XCTUnwrap(UserDefaults(suiteName: "rerender-\(UUID())"))
    }

    override func tearDown() async throws {
        fixture?.store.engine.pause()
        fixture?.store.engine.attachProgramView(nil)
        fixture?.cleanUp()
    }

    private var store: ProjectStore { fixture.store }

    /// The centre pixel of what the view shows (RGB 0...255), or nil before anything rendered.
    private func centre(_ view: VEPreviewView) -> (r: Int, g: Int, b: Int)? {
        guard let image = view.snapshot() else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let offset = ((height / 2) * width + width / 2) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func renderOnce(_ view: VEPreviewView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.renderOnce { _ in continuation.resume() }
        }
    }

    func testAnOpacityChangeReRendersTheProgramFrameWhilePausedAndPlaying() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let view = VEPreviewView(frame: NSRect(x: 0, y: 0, width: 480, height: 270))
        store.attachProgramView(view)
        let (movie, _) = try await fixture.importMedia()
        let clip = try fixture.placeMovie(movie, at: 0)
        store.selection = [clip]

        // The picture appears once decoded.
        var original: (r: Int, g: Int, b: Int)?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            await renderOnce(view)
            if let pixel = centre(view), pixel.g > 40 {
                original = pixel
                break
            }
        }
        let shown = try XCTUnwrap(original, "the clip's picture never appeared")
        XCTAssertNil(view.lastError)

        // Paused: the engine re-renders by itself after the edit (no renderOnce from the test).
        let rendersBefore = view.renderCount
        store.inspector.setValue(.opacity, 50)
        let dimmed = await StoreFixture.wait(until: {
            guard view.renderCount > rendersBefore, let pixel = self.centre(view) else { return false }
            return pixel.g < shown.g - 10 && pixel.g > 5
        }, timeout: 10)
        XCTAssertTrue(dimmed, "50 % opacity: \(String(describing: centre(view))) vs \(shown)")
        let rendersAtHalf = view.renderCount
        store.inspector.setValue(.opacity, 0)
        let black = await StoreFixture.wait(until: {
            guard view.renderCount > rendersAtHalf, let pixel = self.centre(view) else { return false }
            return pixel.r < 3 && pixel.g < 3 && pixel.b < 3
        }, timeout: 10)
        XCTAssertTrue(black, "0 % opacity: \(String(describing: centre(view)))")
        store.undo()
        store.undo()
        let restored = await StoreFixture.wait(until: { (self.centre(view)?.g ?? 0) > shown.g - 10 }, timeout: 10)
        XCTAssertTrue(restored, "undo re-renders too")

        // Playing (the clip slowed to 8 s so it is still playing): the playing picture follows.
        XCTAssertTrue(store.engine.setSpeed(0.25, forClip: clip).ok)
        store.engine.play()
        let playing = await StoreFixture.wait(until: { self.store.engine.playbackState == .playing }, timeout: 10)
        XCTAssertTrue(playing, "\(store.engine.playbackState.rawValue)")
        store.inspector.setValue(.opacity, 0)
        var blackWhilePlaying = false
        let playDeadline = Date().addingTimeInterval(5)
        while Date() < playDeadline, !blackWhilePlaying {
            await renderOnce(view) // the view has no window, so no display link: present by hand
            if let pixel = centre(view), pixel.r < 3, pixel.g < 3, pixel.b < 3 {
                blackWhilePlaying = true
            }
        }
        XCTAssertTrue(blackWhilePlaying, "the playing picture shows the new opacity")
        XCTAssertEqual(store.engine.playbackState, .playing, "the edit did not stop playback")
        XCTAssertTrue(store.engine.playbackStats.presentedClockDriven, "the picture was chosen by the running clock")
        store.engine.pause()
    }
}
