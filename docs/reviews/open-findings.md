# Open findings

Only what is still open. Fixed findings are in the history table of `README.md` (fix commits and regression tests);
the full reports are in git history at the commits the table names.

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
- Keyframed Motion (feature request 8): the inspector's keyframe logic (`InspectorModel`), the Ken Burns rectangles
  (`KenBurnsModel`: geometry, limits, swap, apply, lifetime) and the timeline markers (positions, hit testing, a click
  through `TimelineGestureController`) are tested at the model level; dragging the rectangles' bodies and corners on the
  real program monitor (`KenBurnsOverlay`'s SwiftUI gestures), the look of the keyframe controls and the markers, and
  watching an animated clip play are by hand. Ken Burns range and neighbour matching: the range, duration, picture
  time, picture pacing (`KenBurnsPictureLoader`), neighbour toggles, Match and Control-K are tested at the model and
  engine level; by hand: the helper's bar (Move menu, Duration field with Return also pressing Apply, the neighbour
  checkboxes) at narrow monitor widths, the picture following a real scrub smoothly, the inspector's Match menu, and
  that the keyframe diamonds and interpolation checkmarks redraw after each click (the SwiftUI diff itself; the
  controls now draw only from `KeyframeControlState`, whose changes are tested).
- Photos drops and Import from Photos (feature request 9): everything after a drop reaches the drop delegates
  (`MediaBinDropDelegate`, `TimelineDropDelegate`, with a fake promise-carrying `NSItemProvider`), the promise receiving,
  progress, cancellation, the Media folder (next to a saved project; asked once for an untitled one and kept with it),
  Live Photo choice and timeline placement are tested (`PhotosDropTests`), and HEIC/HEVC/slow-motion media through the
  engine (`PhotosMediaTests`). By hand: a real drag from Photos.app (the window server's promise session and
  `NSFilePromiseReceiver` reading the drag pasteboard, which a test cannot produce), an iCloud original downloading
  during a drop, what Photos hands over for a Live Photo and a slow-motion clip on a given macOS version, the
  PHPicker sheet itself (`PhotosImportPicker.present`; its configuration and result handling are tested), and the
  folder panel in the real sandbox (writing next to a project the sandbox granted only as a file falls back to it).

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
