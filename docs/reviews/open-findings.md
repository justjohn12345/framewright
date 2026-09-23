# Open findings

## UX round (2026-09-23 review; report in git history at 95f445d)
All eight findings are fixed and test gaps 1-5 are covered (see `integration-notes.md`, "UX round fixes"):
1. VFR pictures are the frame containing the exact source time (`playback::pictureTimeFor`, FrameCache's time
   lookup; the slot lookup is gone from playback and export): `VariableFrameRatePictureTests` (both backends, paused
   and playing), `ExportParityTests.testAVariableFrameRateSourceExportsTheMonitorsPictures` (gap 1),
   `PlaybackLookaheadTests.testPlayStartsPromptlyOnAVariableFrameRateSource`,
   `VEEnginePlaybackTests.testADissolveBetweenTwoVFRSourcesMixesTheirPicturesAtTheFrameCentre`,
   `ExportJobTests.testVariableFrameRateSourceExportsTheMonitorsFrames`.
2. Only transport keys and Escape in the output window: `OutputDisplayTests.testOnlyTheTransportKeysWorkInTheOutputWindow`.
3. Output window hidden while the app is inactive and refused without the editor's display:
   `OutputDisplayTests.testTheOutputGoesAwayWhileTheAppIsInTheBackground`, `testTheOutputNeedsToKnowTheEditorsDisplay`.
4. No source-monitor lookahead while hidden or exporting (`VEEngine.sourceMonitorVisible`):
   `VEEngineExportTests.testTheSourceMonitorKeepsNoLookaheadWhileHiddenOrExporting` (gap 3),
   `WindowLayoutTests.testTheSourceMonitorIsHiddenUntilMediaIsOpenedInIt`.
5. Audio idle timeout 60 s on battery, 5 min on AC (`audio::PowerSource`):
   `PlaybackControllerTests.testTheIdleTimeoutIsFiveMinutesOnACAndOneMinuteOnBattery`,
   `testTheIdleOutputFollowsThePowerSource`, `testTheSystemPowerSourceIsIOKits`.
6. Divider cursor set with change detection, reset when a drag ends outside (`DividerCursor`):
   `PointerHandlingTests.testTheDividerSetsItsCursorOnlyWhenTheShapeChanges`,
   `testADragEndingOutsideTheDividerRestoresTheArrow`.
7. `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade` is skipped under ThreadSanitizer; median of the cached
   starts < 50 ms, worst < 80 ms, values logged.
8. Context-menu monitor filtered on the button and Control first, installed exactly while in a window:
   `PointerHandlingTests.testTheContextMenuMonitorIsInstalledExactlyWhileTheViewIsInAWindow`,
   `testOnlyContextClicksInsideTheViewAskForAMenu`.
Gap 4: `WindowLayoutTests.testTheSidePanelsNarrowInspectorFirstAtTheMinimumWindowWidth`,
`testDraggingTheSourceMonitorDividerPastItsBoundsClamps` (the view's arithmetic, `ContentView.sideWidths` and
`WindowLayoutModel.dragSourceMonitorDivider`; SwiftUI's layout of the panes itself is not inspected). Gap 5:
`TimelineDropTests.testADissolveDroppedOnAThroughEditSaysSoInTheStatusLine`.
Still by hand: the cursor's look over a real divider (the tests observe `DividerCursor.apply`), and the output window
following a real Cmd-Tab on a physical second display (the tests post the activation notifications).

## Phase 7 export (2026-09-23 review; report in git history at 2dde40e)
All ten findings are fixed (regression tests: `EngineTests/Export/ExportRegressionTests.mm` for P1/P2/P3, plus
`ExportJobTests`, `ExportParityTests`, `VEEngineExportTests`, `VideoDurationEditTests.cpp`, `DecodePoolTests`,
`FrameCacheTests`, `ClipAudioSourceTests`, `ExportModelTests`). Test gaps 1-6, 10 and 11 are covered. Still open:
- Gap 7, sandbox-hosted UI test (choose a file in the real save panel, switch the container, export): needs a UI-test
  target (XCUITest) driving the real NSSavePanel in the sandboxed app; the xctest host is not sandboxed and cannot show
  the panel. The model side (container change clears the choice and asks again) is tested in `ExportModelTests`.
- Gap 8, size estimate against a real export in quality mode: the estimate is a bits-per-pixel heuristic (labelled "≈");
  the synthetic burn-in media compresses far better than camera footage, so a tolerance tight enough to mean something
  would only hold for that media. Needs a set of representative camera clips (not in the repository) to calibrate.
- Gap 9, multi-minute 4K export memory (at least 2 min at 4K): the test media has no 4K source, and such an export takes
  minutes per run. `ExportJobTests` now checks 1800 frames at 720p with about 150 footprint samples and a per-frame
  growth bound (20 KB/frame); a 4K soak belongs in a separate, opt-in performance scheme.
- Not deterministic to unit-test: AVAssetWriter's cancel in the middle of `finishWritingWithCompletionHandler`
  (`cancelWriting` while the MP4 index rewrite runs). The early check and the FFmpeg writer's per-packet check are tested
  (`testFinishIsCancellableOnBothWriters`, `testCancelWhileFinishingKeepsTheExistingFile`); the 20 ms polling loop
  around the completion is exercised only when finishing takes longer than one slice.

## User feedback from hands-on testing (2026-09-23, iPhone 1280x720 VFR H.264 clip split once)

Items 1 (with follow-ups a-c), 1b, 2, 3 and the layout items 4-7 are done (UX round; see
`integration-notes.md`, "UX round"). What could only be verified by hand, or needs a UI-test target:
- Dragging a transition from the Effects tab onto a cut through the window server's drag session:
  the drag source's exported types (`TransitionReference`, declared in Info.plist) and everything
  `TimelineDropDelegate` does with a drop are unit-tested (`TimelineDropTests`, with a `DropInfo`
  double); the drag itself needs a person or an XCUITest.
- The program output window on a physical second display (`OutputDisplayController`): the window,
  its attachment to the engine, Escape and screen removal are tested over an injected screen list
  (`OutputDisplayTests`) and the engine's two-view fan-out with real views (`VEEnginePlaybackTests`),
  but that the picture reaches a real display, covers it and follows a hot-unplug needs a person.
- The right-click menu in the timeline is built and tested as items (`contextMenuItems(at:)`); the
  NSMenu pop-up from a real right-click is by hand (the same event-delivery limit as gap 9 below).

Feature request:
8. MEDIUM (new capability): animated zoom/pan over time ("as if the cameraman zoomed in"). This is keyframed Motion, not a
   transition: Premiere = Effect Controls > Motion > Position/Scale keyframes with linear/ease interpolation; FCP = the
   Transform keyframes, plus the "Ken Burns" crop mode that sets a start rect and an end rect and animates between them.
   Design: add keyframe tracks to `VideoParams` (position, scale, rotation, opacity; time relative to the clip's source
   in point so trims keep them attached to the picture), interpolation per keyframe (hold, linear, ease-in/out), evaluated
   per frame by the Scheduler into the layer transform; inspector: a keyframe toggle per parameter at the playhead,
   next/previous keyframe, and an FCP-style "Ken Burns" helper (start/end rectangles drawn on the program monitor);
   timeline: keyframe markers on the clip; JSON schema v4 with migration (v3 added MediaAsset::videoDuration); undo per
   keyframe edit; export renders the same
   evaluation. Implementer should read the FCP and Premiere docs on Ken Burns / Motion keyframes for behaviour details.

9. MEDIUM (new capability): drag and drop clips from Photos.app (iPhoto's successor) into the media bin and the
   timeline. Photos drags deliver file promises, not file URLs: the drop targets must accept `NSFilePromiseReceiver`
   (`com.apple.NSFilePromiseItemMetaData` / `kPasteboardTypeFileURLPromise`) alongside file URLs, receive each promised
   file into a per-project "Media" folder (project-relative, sandbox-writable; ask once where to keep imported media when
   the project is untitled) with progress and cancellation, then import the received files through the normal path.
   Also handle what Photos hands over: HEVC/HEIC, Live Photos (import the video part or the still, user choice), slow-mo
   (VFR at 120/240 fps), portrait rotation, and iCloud items that download on demand (promise may take time). Add a
   "Import from Photos…" menu item using `PHPickerViewController` (no Photos-library entitlement needed) for browsing
   without drag. Tests: a fake promise provider in AppTests; an EngineTests import of an HEIC/HEVC sample.

The 2026-09-23 full review's twelve facade/app findings and four scaffold items are fixed (see
the history table in `README.md`; the 2026-09-23 full review (git history, commit f5190ea) keeps the evidence, and the
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
