# Open findings

Only what is still open. Fixed findings are in the history table of `README.md` (fix commits and regression tests);
the full reports are in git history at the commits the table names.

## Effect lanes (2026-09-24 review, `2026-09-24-effect-lanes-review.md`)
One CRITICAL (the Ken Burns editor assumes a full-frame clip: on a picture-in-picture it draws the picture full size,
the rectangles many frames wide, and the first drag destroys the framing; a true crop needs an engine window/scissor,
a user decision), four HIGH (a v4 project with a fade out under an incoming crossfade refuses to open; Escape/Undo
mid Ken Burns drag is reopened by the next mouse move; a refused transition drop leaves its red pill and the lane-0
reveal on screen; a dissolve dropped near a lone clip's edge silently becomes a fade), eight MEDIUM (silent drops of
fades/dissolves/spans by edits, a dissolve changing partner after a ripple delete, fades deleting incoming crossfades,
the scroll wheel changing axis, no vertical scroll bar, mid-drag row shifts from the lane-0 reveal, the redraw budget
during Ken Burns drags, loading that refuses instead of repairing), eleven LOW, and three design items from the
user's notes (compact rows, a user-owned preview/timeline split, restoring the window frame). All open; the next fix
round works from the report.

## Keyframed Motion, Ken Burns and Photos drops (2026-09-24 review; report in git history at b9add9f)
Effect lanes round 2 replaced the keyframe-era app tests (`KeyframedMotionTests`, `MotionReviewTests`): the Ken Burns
geometry, the picture loader (3), the press rules (12) and the loader's engine path now live in `KenBurnsEditorTests`,
the static values and matching in `StaticMotionTests`, held Control-K (15) in `EffectLanesTimelineTests`; the tests of
the removed range fields, markers and Apply (11, 16-18, 25) went with the UI they covered (see "Effect lanes round 2").
Effect lanes round 1 removed the keyframe API with its tests (`KeyframeInsertTests.cpp`, `KeyframeEditTests.cpp`,
`KeyframeRefusalTests.cpp`, `VEEngineKeyframe*Tests.mm` and the keyframe app tests): the same guarantees for spans
(no frame changes on a split, a cut or an added span; exact values against a Newton reference) are in
`EffectSpanTests.cpp`, `SpanEditTests.cpp`, `SpanPictureTests.cpp` and `SchedulerSpanTests.cpp`.
All twenty-six findings are fixed and test gaps 1-5 are covered, except the items listed under the UI-test section
below (see `integration-notes.md`, "Motion/Photos review fix round"):
1. Adding a keyframe keeps every frame (`insertKeyframeKeepingValues`): `KeyframeInsertTests.cpp` (AddKeyframe, the
   Control-K toggle and SetMotionValue's add path inside a hold, a linear, each ease and a custom curve, every frame
   against the value before and an independent Newton reference), `VEEngineKeyframeReviewTests.testAddingKeyframesInsideAHoldAndAnEaseKeepsEveryFrame`,
   `KeyframedMotionTests.testTheDiamondInsideAHoldOrAnEaseKeepsTheSegmentAndTheInspectorSaysWhatItIs`.
2. Live Photos pair within one promise only; Settings > Media > Live Photos: `PhotosDropTests.testUnrelatedItemsWithOneNameAreNeverPairedNorDeleted`,
   `testTheLivePhotoSettingRoundTripsWithTheQuestionsRememberedChoice`.
3. The Ken Burns loader's own bounded cache: `KeyframedMotionTests.testKenBurnsPictureLoaderShowsEveryLandedPictureWhileScrubbingOneFetchAtATime`,
   `...MovesOnAfterAFailedFetchAndKeepsTheLastPicture`, `...MemoryIsBounded`,
   `testTheKenBurnsHelperLoadsItsPictureFromTheEngineWithoutTheSharedCache`,
   `TimelineRedrawTests.testKenBurnsPicturesLandingRedrawNeitherTheTimelineNorTheBin` (overlay, bin and timeline hosted: 0/0/0).
4. A value on a frame whose keyframe is elsewhere in its span lands on the frame's start (`planMotionValueAtFrame`):
   `KeyframeInsertTests` ("a split's out point", "a 1.5x clip"), `VEEngineKeyframeReviewTests.testAValueTypedOnASplitsLastFrameShowsExactlyAndANudgeBurstIsOneStep`,
   `testAValueTypedOnAFrameOfASpedUpClipShowsExactly`, `MotionReviewTests.testANudgeOnASplitsLastFrameShowsExactlyWhatWasTyped`.
5. Frames evaluate at the keyframe tick (`motionTimeAt`): `KeyframeInsertTests` ("Keyframe on the next precise tick ...
   after a hold (NTSC, 999/1000)").
6. Late placement checks the timeline: `PhotosReceivingTests.testMediaArrivingAfterAnEditStaysInTheBinWithAMessage`,
   `testMediaArrivingDuringAGestureOrANudgeBurstStaysInTheBin`, `testARefusedPlacementSaysWhyAndAnOccupiedDropPointTakesAnInsert`,
   `testADropOffTheTracksImportsIntoTheBin`.
7. Quit, close, New and Open ask while media arrives: `PhotosReceivingTests.testQuitNewAndOpenAskWhileMediaIsArriving`.
8. Only a chosen Media folder is stored; Save As and copies use their own: `PhotosReceivingTests.testSaveAsElsewhereAndACopiedProjectFolderUseTheirOwnMediaFolder`,
   `testAnEarlierVersionsStoredMediaFolderIsDroppedOnSaveAsAndInACopy`, `PhotosMediaTests.testTheMediaFolderBookmarkIsSavedWithTheProject`.
9. Pasteboard promises settle each reader call: `PhotosReceivingTests.testAPasteboardPromiseMovesEachFileOutOfStagingAndCompletesAtThePromisedCount`,
   `testFewerReaderCallsThanPromisedKeepTheItemUntilCancelWhichDeletesWhatArrivedAtOnce`, `testMoreReaderCallsThanPromisedImportTheExtraFilesToo`,
   `testAReaderErrorFailsOnlyItsFile`, `testAPromiseReleasedWhilePendingDeletesWhatArrivedAndWhatComesLater`.
10. Media folder marker, staging, non-media, refused imports: `PhotosReceivingTests.testThePanelsFolderGetsAMediaFolderAndAnExistingMediaFolderNeedsTheMarker`,
    `testWhenTheProjectsFolderIsNotWritableThePanelAsksWithTheReason`, `testTwoPromisedFilesWithOneNameBothArrive`,
    `testTheDragPasteboardIsPartitionedOncePerItemAndNonMediaPromisesAreRefused`, `testANonMediaPromiseIsNotReceivedAndAFileTheImportRefusesIsDeleted`.
11. Typed range text survives model changes: `MotionReviewTests.testTypedRangeTextSurvivesASaveAModelChangeAndThePlayhead`.
12. The start rectangle is reachable: `MotionReviewTests.testTheStartRectangleIsReachableUnderTheEnd`, `testCoincidingRectanglesShareTheirHandles`.
13. The parity movement check measures the animation: `ExportParityTests.testAnAnimatedClipExportsTheMonitorsPictures`.
14. Thread-safe `adopt`: `PhotosReceivingTests.testAdoptingFromManyThreadsNeverLosesAFile`.
15. Held Control-K: `MotionReviewTests.testHeldControlKTogglesOnce` (through `KeyboardController.handle`).
16. Drag state and clicks: `MotionReviewTests.testAClickWithoutMovementDoesNotPinARectangle`.
17. A duration off the clip is refused: `MotionReviewTests.testADurationTypedWithThePlayheadOffTheClipIsRefused`.
18. A moved rectangle survives its neighbour going: `MotionReviewTests.testARectangleMovedNextToANeighbourStaysWhenTheNeighbourGoes`.
19. Curve order and overshoot: `KeyframeTests.cpp` ("validation", "a curve part divided again ..."), `KeyframeInsertTests`
    ("an overshooting custom curve ..."), `ProjectJSONTests` ("backwards").
20. Animated still pieces: `KeyframeRefusalTests.cpp` ("isThroughEdit: pieces of an animated still ...").
21. Keyframes on every edit path, refusal codes: `KeyframeRefusalTests.cpp`, `VEEngineKeyframeReviewTests.testAnUnknownMotionParameterIsRefusedNotTreatedAsPositionX`.
22. JSON: `ProjectJSONTests.cpp` ("keyframe errors and warnings", "a model keyframe that is not custom ..."); the v4
    golden test no longer writes its file.
23. Trash, stale and failed bookmarks, scope past New, one partition: `PhotosReceivingTests.testAStoredFolderInTheTrashOrGoneIsNotUsedAndAMovedOneIsFollowed`,
    `testTheFoldersSecurityScopeOutlivesNewWhileAPromiseMayStillDeliver`, `testTheDragPasteboardIsPartitionedOncePerItemAndNonMediaPromisesAreRefused`.
24. PHPicker and bundles, question queue: `PhotosReceivingTests.testAPickedLivePhotoBundleIsUnpackedAndThePartNotChosenLeavesNoBundle`,
    `testAPickerWhoseSheetWentAwayWithoutItsDelegateCanBeShownAgain`, `testLivePhotoQuestionsWaitForAGestureAndNeverStack`,
    `testCancellingTheLivePhotoQuestionLeavesNothingBehind`, `testAdoptingFromManyThreadsNeverLosesAFile` (names).
25. UI details: `MotionReviewTests` (`testTheClipMenuItemFollowsThePlayhead`, `testPaddedOrEquivalentTextChangesNothing`,
    `testKenBurnsReopenedOnTheSameClipKeepsItAndAMultiSelectionClosesIt`, `testTheDurationFormatFollowsThePreferenceWhileOpen`,
    `testATrimEdgeNearerThanAMarkerKeepsThePress`, `testAnAbandonedMarkerDragPutsTheKeyframesBack`).
26. Build and test plumbing: `PhotosDropTests.testTheDropTargetsAcceptEveryPromiseType`,
    `PhotosMediaTests.testTheSlowMotionTableMatchesTheScript`, `testAnIncompleteOrOutdatedTestMediaDirectoryIsRecognised`.
Test gaps: 1 and 2 by `KeyframeInsertTests.cpp` (also "Animated clips: a split at 1.5x, an overwrite inside, a move onto
and a ripple keep the pictures"), `KeyframeTests.cpp`; 3 by `VEEngineKeyframeReviewTests.mm` and `PhotosMediaTests`; 4 by
`KeyframedMotionTests`, `MotionReviewTests`, `TimelineRedrawTests` (the band test now asserts its host draws); 5 by
`PhotosReceivingTests` and `PhotosDropTests` (the provider double completes once; a source completing after cancel is
`testASourceCompletingAfterCancelIsIgnoredAndItsFilesDeleted`; an item-provider error and a cancel before the main hop are
`testAnItemProviderErrorAndACancelBeforeTheMainHop`).
Still open, with reasons:
- `VEEditErrorNotRepresentable` from the keyframe calls needs a 128-bit overflow of a clip's source time: no facade
  input reaches it, so its message is covered by reading only.
- What the real Photos drag hands over (one listed type per file for a Live Photo? a rename or an overwrite when two
  promised files share a name in the staging folder?) is not observable in the test host; the double of the
  receiver's contract covers both counts, errors and collisions (by hand, below).

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
  controls now draw only from `KeyframeControlState`, whose changes are tested). Since the Motion/Photos fix round,
  also by hand: a real press on the overlay reaching the rectangle `KenBurnsHit` picks and a cancelled drag resetting
  its `@GestureState` (the hit rules and `applyDrag` are tested), the inspector's Video rows keeping a field's focus
  when the clip gets its first keyframe (one `VideoParameterRows` view either way), and the Clip menu's Add/Remove
  Motion Keyframe title in the real menu bar as the playhead moves (`motionKeyframeMenuState` is tested). Ken Burns editing: the existing-move
  detection, the Custom range (parsing, clamping, the mode switch, Apply), the timeline band (geometry, its redraw
  budget, pixels at its edges) and marker drags through `TimelineGestureController` (groups, limits, one undo step,
  Escape, the helper following) are tested; by hand: Return in the Start/End/Duration fields committing the field
  without pressing Apply and then pressing it (the default-button shortcut is dropped while `hasUncommittedText`;
  AppKit's key-equivalent routing itself is not observable in the test host), the bar's layout with the three fields
  at narrow monitor widths, and a real mouse drag of a marker through SwiftUI.
- Photos drops and Import from Photos (feature request 9): everything after a drop reaches the drop delegates
  (`MediaBinDropDelegate`, `TimelineDropDelegate`, with a fake promise-carrying `NSItemProvider`), the promise receiving,
  progress, cancellation, the Media folder (next to a saved project; asked once for an untitled one and kept with it),
  Live Photo choice and timeline placement are tested (`PhotosDropTests`, `PhotosReceivingTests`), and
  HEIC/HEVC/slow-motion media through the
  engine (`PhotosMediaTests`). By hand: a real drag from Photos.app (the window server's promise session and
  `NSFilePromiseReceiver` reading the drag pasteboard, which a test cannot produce; `PasteboardFilePromise` is tested
  over a double of its contract and `DragContents` over item descriptions), an iCloud original downloading during a
  drop, what Photos hands over for a Live Photo and a slow-motion clip on a given macOS version (and whether it renames
  or overwrites a same-named file in the staging folder), the PHPicker sheet itself (`PhotosImportPicker.present`; its
  configuration, stale-sheet recovery and result handling are tested), the folder panel in the real sandbox (writing
  next to a project the sandbox granted only as a file falls back to it; simulated with a read-only folder), and a
  security-scoped Media folder bookmark going stale (a plain bookmark's rewrite is tested).

## Effect lanes round 1: by hand
- Open a project saved by the previous version with keyframed Motion, audio fades and dissolves: the program
  monitor, playback and an export look and sound as before (the render is proven equal frame by frame in
  `MigrationRenderTests`; this checks the app path end to end on real media).

## Effect lanes round 2: by hand
The gesture controller, the store, the inspector model and the Ken Burns model are tested with synthetic points and
direct calls (`EffectLanesTimelineTests`, `InspectorSpanTests`, `KenBurnsEditorTests`, `TimelineRedrawTests`); what the
test host cannot drive:
- Real mouse drags through SwiftUI on the lanes: a range drag on an empty lane (Option for a fade), moving and trimming
  a span, a transition's edges and bar, the snap line and the status line while dragging, the cursor over span edges.
- The Ken Burns overlay's real drags (the SwiftUI gesture calling `applyDrag`/`endDrag`, a cancelled gesture reverting
  through `cancelDrag`), Escape mid-drag from the keyboard, and the program monitor following each drag step.
- Dragging a transition, Fade or Gain from the Effects tab onto a cut, a free clip edge or a lane (lane 0 appearing
  under the tracks while a transition is dragged); `TimelineDropDelegate` is tested with a drop double.
- The right-click menu's Set Interpolation and Move to Lane submenus in a real NSMenu (the items and actions are tested).
- The look: span bars, icons and labels at several zooms, the header's lane names and disclosure, the readout of a
  Fade or Gain span on the monitor, the inspector's span section and the overlay's bar at narrow widths; Return and
  focus loss committing the range fields (`NumericField`); Escape with a text field focused leaving the editor open.
- `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade` on AirPods or another Bluetooth output: it skips and
  its message and log line give the measured latency (the decision is read from CoreAudio at run time).

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
