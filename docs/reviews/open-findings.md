# Open findings

Only what is still open. Fixed findings are in the history table of `README.md` (fix commits and regression tests);
the full reports are in git history at the commits the table names.

## Feature requests (from hands-on testing, 2026-09-23)
8. MEDIUM (new capability): animated zoom/pan over time ("as if the cameraman zoomed in"). This is keyframed Motion, not a
   transition: Premiere = Effect Controls > Motion > Position/Scale keyframes with linear/ease interpolation; FCP = the
   Transform keyframes, plus the "Ken Burns" crop mode that sets a start rect and an end rect and animates between them.
   Design: add keyframe tracks to `VideoParams` (position, scale, rotation, opacity; time relative to the clip's source
   in point so trims keep them attached to the picture), interpolation per keyframe (hold, linear, ease-in/out), evaluated
   per frame by the Scheduler into the layer transform; inspector: a keyframe toggle per parameter at the playhead,
   next/previous keyframe, and an FCP-style "Ken Burns" helper (start/end rectangles drawn on the program monitor);
   timeline: keyframe markers on the clip; JSON schema v4 with migration (v3 added MediaAsset::videoDuration); undo per
   keyframe edit; export renders the same evaluation. Implementer should read the FCP and Premiere docs on Ken Burns /
   Motion keyframes for behaviour details. See `integration-notes.md` for where the pieces go.

9. MEDIUM (new capability): drag and drop clips from Photos.app (iPhoto's successor) into the media bin and the
   timeline. Photos drags deliver file promises, not file URLs: the drop targets must accept `NSFilePromiseReceiver`
   (`com.apple.NSFilePromiseItemMetaData` / `kPasteboardTypeFileURLPromise`) alongside file URLs, receive each promised
   file into a per-project "Media" folder (project-relative, sandbox-writable; ask once where to keep imported media when
   the project is untitled) with progress and cancellation, then import the received files through the normal path.
   Also handle what Photos hands over: HEVC/HEIC, Live Photos (import the video part or the still, user choice), slow-mo
   (VFR at 120/240 fps), portrait rotation, and iCloud items that download on demand (promise may take time). Add a
   "Import from Photos…" menu item using `PHPickerViewController` (no Photos-library entitlement needed) for browsing
   without drag. Tests: a fake promise provider in AppTests; an EngineTests import of an HEIC/HEVC sample.

## Test gaps that need a UI-test target (XCUITest) or a person
The xctest host is not sandboxed and its synthesised NSEvents never reach SwiftUI's gesture system or the window
server's drag session, so these are covered at the model level only:
- Real SwiftUI gesture path (full review gap 9): `TimelineGestureTests.testARealDragThroughSwiftUIIsCommittedAndNotReverted`
  drives the hosted TimelineView through `NSWindow.sendEvent` and skips with that reason.
- Sandbox-hosted export round trip (phase 7 gap 7): choose a file in the real save panel, switch the container, export.
  The model side (a container change clears the choice and asks again) is tested in `ExportModelTests`.
- A real-sandbox save/open round trip, and a main-window smoke test that triggers the thumbnail/waveform fetches it
  asserts (full review gap 11).
- Dragging a transition from the Effects tab onto a cut: the exported types (`TransitionReference`) and everything
  `TimelineDropDelegate` does with a drop are unit-tested (`TimelineDropTests`); the drag itself is not.
- The program output on a physical second display: window, engine attachment, Escape, screen removal, key scoping and
  hide/reshow on deactivate are tested over an injected screen list and posted notifications (`OutputDisplayTests`);
  that the picture reaches the display, covers it, follows a hot-unplug and a real Cmd-Tab needs a person.
- The timeline's right-click menu is built and tested as items (`contextMenuItems(at:)`); the NSMenu pop-up from a real
  right-click, and the look of the resize cursor over a real divider (`DividerCursor.apply` is observed in tests), are by hand.

## Test gaps that need media or a performance scheme (phase 7)
- Gap 8, size estimate against a real export in quality mode: the estimate is a bits-per-pixel heuristic (labelled "≈");
  the synthetic burn-in media compresses far better than camera footage, so a tolerance tight enough to mean something
  would only hold for that media. Needs a set of representative camera clips (not in the repository) to calibrate.
- Gap 9, multi-minute 4K export memory (at least 2 min at 4K): the test media has no 4K source, and such an export takes
  minutes per run. `ExportJobTests` checks 1800 frames at 720p with about 150 footprint samples and a per-frame growth
  bound (20 KB/frame); a 4K soak belongs in a separate, opt-in performance scheme.
- Not deterministic to unit-test: AVAssetWriter's cancel in the middle of `finishWritingWithCompletionHandler`
  (`cancelWriting` while the MP4 index rewrite runs). The early check and the FFmpeg writer's per-packet check are tested
  (`testFinishIsCancellableOnBothWriters`, `testCancelWhileFinishingKeepsTheExistingFile`); the 20 ms polling loop
  around the completion is exercised only when finishing takes longer than one slice.
