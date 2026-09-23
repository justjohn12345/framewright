# Open findings

## User feedback from hands-on testing (2026-09-23, iPhone 1280x720 VFR H.264 clip split once)

Functional:
1. HIGH: "cross dissolve didn't work". To determine: (a) drag-and-drop from the Transitions panel never lands (the panel's
   SwiftUI `.draggable` + custom UTType drop was never verified in the real app; the "+" button path may be what worked),
   and/or (b) a dissolve added at the split of a VFR clip does not visibly render during playback/scrub. Reproduce with the
   user's clip type (VFR, 31.579 fps nominal) split with Cmd+K, add via drag AND via "+", scrub across the cut, and check
   the program monitor shows the mix; add an integration test with a VFR source (the generated `vfr_h264_*` media) through
   `VEEngine` + the program view. Fix whichever fails; if the drop is the failure, replace the drag source with an
   `NSItemProvider`-based drag or a plain AppKit drag session that is testable.
2. MEDIUM: removing a cross dissolve leaves the linked audio crossfade behind. They were added as one undo step, so
   Delete on either should remove the pair (one undo step); Option-Delete (or a context-menu item) removes only that one.
   Same for changing the duration: offer "also change the linked transition" (default on) in the inspector.
3. MEDIUM: noticeable lag between pressing Space and playback starting. Pre-roll from the playhead while paused: keep the
   decode pool filling a short lookahead window (video ~0.5 s, audio ~1 s) from the current playhead whenever the transport
   is stopped and the playhead has been still for ~100 ms, so `play()` finds frames and primed audio and starts within one
   frame. Keep the audio device warm (already done) and measure press-to-first-presented-frame in a test (target < 50 ms
   on cached media, report the cold number).

Layout / UX (redesign the default window):
4. MEDIUM: the source monitor beside the program monitor is a poor use of space. Make the source monitor collapsible
   (View > Show Source Monitor, default hidden until an asset is double-clicked), or a single monitor with Source/Program
   tabs like Resolve; when hidden the program monitor takes the full width.
5. MEDIUM: the Transitions panel under the media bin wastes space. Move it into the inspector as a second tab
   ("Inspector" / "Effects"), or a toolbar popover; the "+" add-at-playhead action stays.
6. MEDIUM: the default layout leaves a large empty track area and a small preview. Size the timeline pane to its content
   (tracks × row height + ruler, with a sensible minimum) and give the remaining height to the monitors; persist the split
   positions; let the user collapse empty tracks.
7. LOW-MEDIUM: pop the program preview out to a second display (full-screen "output" window driven by the same playback
   controller, mirrored to the in-window monitor). Worth doing: standard in Premiere/Resolve. Requires the controller's
   frame source to feed two `VEPreviewView`s (fan-out or a second source over the same clock) without double decoding.

The 2026-09-23 full review's twelve facade/app findings and four scaffold items are fixed (see
the history table in `README.md`; the 2026-09-23 full review (git history, commit 75d5e35) keeps the evidence, and the
regression tests are in `EngineTests/Facade/VEEngineReviewRegressionTests.mm`,
`EngineTests/Media/DecodePoolTests.mm`, `EngineTests/Media/FrameCacheTests.mm`,
`EngineTests/Facade/FacadeCommandsTests.cpp`, `AppTests/ReviewRegressionTests.swift` and
`AppTests/KeyboardFocusTests.swift`). What is still open:

## Test gaps (from §5 of the review)
- 9. Real SwiftUI gesture path: `TimelineGestureTests.testARealDragThroughSwiftUIIsCommittedAndNotReverted`
  drives the hosted TimelineView with NSEvents through `NSWindow.sendEvent`, but in the xctest
  host those events never reach SwiftUI's gesture system (even with the window key and the app
  active), so the test skips with that reason. It needs a UI-test target (XCUITest) that
  synthesises real window-server events.
- 11. Carried over: a real-sandbox save/open round trip, and a main-window smoke test that
  triggers the thumbnail/waveform fetches it asserts.
