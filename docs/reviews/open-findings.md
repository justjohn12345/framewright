# Open findings

## Phase 6 (2026-09-23 review, `2026-09-23-phase6-review.md`)
Eleven findings, none above MEDIUM: linked crossfade shortens the video dissolve (1), paused monitor presents a layer-missing frame before the picture lands and the test was weakened to hide it (2), preference changes do not refresh views (3), inspector wipes the status line (4), plus lows 5-11 and six test gaps. All still open.

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
