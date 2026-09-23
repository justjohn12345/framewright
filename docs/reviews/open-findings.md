# Open findings

## Phase 7 export (2026-09-23 review, `2026-09-23-phase7-review.md`)
Ten findings, two HIGH (verified): a cancelled/failed export deletes the user's pre-existing output file (no temp file /
atomic replace); export fails when a video track is shorter than the asset's container duration. MEDIUM: mid-stream audio
decode errors exported as silence and reported as success (verified); container change rewrites the sandbox-granted URL's
extension. Plus six lows and eleven test gaps. All open.

## User feedback from hands-on testing (2026-09-23, iPhone 1280x720 VFR H.264 clip split once)

Functional:
1. RESOLVED AS EXPECTED BEHAVIOUR, with follow-ups: the user split a clip with Cmd+K, selected the first half, pressed the
   Cross Dissolve "+", saw the band on the timeline, but playback showed no visible transition. At a plain split the two
   sides show the same source frames, so the dissolve blends identical pictures (same in Premiere/FCP at a "through
   edit"). Follow-ups: (a) UX: when a dissolve is added at a through edit (both clips from one asset with contiguous
   source ranges), show a status note "Both sides show the same frames here; trim or move one side to see the dissolve";
   (b) still add the VFR integration test (dissolve between two different sources on `vfr_h264_*` media through
   `VEEngine` + the program view, checking the mixed pixels mid-transition); (c) verify panel drag-and-drop in the real
   app once, since only the "+" path has been exercised by hand.
1b. LOW: the Transition inspector shows "Starts" as an absolute timeline time. Show it relative to the cut instead:
   "Cut at 00:00:04:13, −15 f / +15 f" (or start/end offsets), since the duration is what the user edits.
2. MEDIUM: removing a cross dissolve leaves the linked audio crossfade behind. They were added as one undo step, so
   Delete on either should remove the pair (one undo step); Option-Delete (or a context-menu item) removes only that one.
   Same for changing the duration: offer "also change the linked transition" (default on) in the inspector.
3. MEDIUM: noticeable lag between pressing Space and playback starting. Pre-roll from the playhead while paused: keep the
   decode pool filling a short lookahead window (video ~0.5 s, audio ~1 s) from the current playhead whenever the transport
   is stopped and the playhead has been still for ~100 ms, so `play()` finds frames and primed audio and starts within one
   frame. Keep the audio device warm (already done) and measure press-to-first-presented-frame in a test (target < 50 ms
   on cached media, report the cold number).

Feature request:
8. MEDIUM (new capability): animated zoom/pan over time ("as if the cameraman zoomed in"). This is keyframed Motion, not a
   transition: Premiere = Effect Controls > Motion > Position/Scale keyframes with linear/ease interpolation; FCP = the
   Transform keyframes, plus the "Ken Burns" crop mode that sets a start rect and an end rect and animates between them.
   Design: add keyframe tracks to `VideoParams` (position, scale, rotation, opacity; time relative to the clip's source
   in point so trims keep them attached to the picture), interpolation per keyframe (hold, linear, ease-in/out), evaluated
   per frame by the Scheduler into the layer transform; inspector: a keyframe toggle per parameter at the playhead,
   next/previous keyframe, and an FCP-style "Ken Burns" helper (start/end rectangles drawn on the program monitor);
   timeline: keyframe markers on the clip; JSON schema v3 with migration; undo per keyframe edit; export renders the same
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
