# Timeline interaction correction — 2026-10-20

Current limits: at most 150 included clips, with every newly created clip lasting at least 0.15 seconds and one source frame.

Current requested UI: the white trim handles and their drag hit areas are removed. Permanent clip separators, the selection outline, scrolling, pinch, Split/Delete, and Undo/Redo remain. The latest guardrails and toast behavior are recorded at the end of this document; earlier handle tests describe the previous iteration.

## Evidence boundary

The earlier investigation did **not** thoroughly validate VLLO's trim gestures or pinch zoom. Passing Rally Cut's earlier command tests did not establish equivalence with VLLO. Those claims must not be used as proof that the interactions matched.

- Directly observed in the installed VLLO app through iPhone Mirroring: a centered playhead, horizontal filmstrip, selected clip outline, narrow grips below the clip boundaries, clip duration, and Split selecting the right clip without changing total duration.
- Repeated two further drag attempts on the visible VLLO end grip. Neither produced a measurable change through the available control tool. VLLO's exact drag threshold, snapping, auto-scroll, and cancellation behavior remain unverified.
- The Computer Use API available here exposes click, drag, and scroll, but no pinch input. VLLO timeline pinch is confirmed by the user's direct observation; it has not been synthesized and measured here. Rally Cut's zoom range is an implementation choice, not a recovered VLLO limit.
- Previous REA capture attempts were denied Screen Recording and Accessibility permissions. No successful REA runtime capture or VLLO internal implementation was obtained. The Mac Mirroring executable is a capture host, not the VLLO iOS executable.
- The test edits used the duplicate VLLO project created in the previous investigation. No source media was deleted or exported. Private reference screenshots are not committed.

## Earlier gesture iteration

- Removed the four additional trim command buttons and their implementation.
- Replaced the arrow controls with narrow white edge grips and a selected clip outline. The boundary has a 44pt hit region; direct dragging does not require a long press.
- One timeline coordinator owns scrolling, edge trimming, and pinch zoom. SwiftUI owns the editor screen; viewport-sized UIKit image views render the filmstrip. UIKit's standard recognizers handle direct touch and supported indirect input.
- A grip keeps the initial touch position, including the movement before the pan recognizer crosses its threshold. The viewport offset is clamped after scrolling so rubber banding cannot contaminate a trim delta.
- During dragging, the grip/outline and source preview update. Near the viewport edge, the timeline can auto-scroll. Releasing snaps to a source frame and commits one undoable edit; cancellation does not commit. Extending stays within the selected split clip's original bounds.
- The preview measures the control area before sizing the video, keeping the complete Export button inside the screen. This was verified in the final physical-device screenshots and assertions.
- Pinch changes the timeline scale continuously from 3 to 480 pt/s (initially 30). The edit time at the center playhead, clip selection, source ranges, and undo history stay unchanged. Preview magnification is unaffected.
- Ruler spacing and thumbnail density follow the scale. At maximum zoom, only tiles near the viewport are generated, including for a four-hour source.

Apple documents that Mirroring delivers pinch as transform events and recommends UIPinchGestureRecognizer, and that mouse/trackpad scrolling uses scroll events handled by UIPanGestureRecognizer's allowedScrollTypesMask. The implementation uses those built-in recognizers. Touch gesture tests and mirrored Mac input remain distinct evidence. [Apple TN3210](https://developer.apple.com/documentation/technotes/tn3210-optimizing-your-app-for-iphone-mirroring)

## Verification

- 33 core tests passed, including zoom anchor preservation, bounded visible tiles at maximum zoom, source/edit mapping, trim bounds, older saved JSON, and 350 mixed edits with Undo/Redo.
- The first new UI run passed pinch and repeated Split/scroll tests, but the short grip drag test failed. Preserving the initial touch position corrected the lost drag distance; the targeted grip test then passed.
- Final simulator run: 17/17 passed on iPhone 15 / iOS 18 (12 media, 2 library UI, 3 editor gesture tests). Result bundle: `/tmp/RallyCutTimelineVerifiedSimulator.xcresult`.
- Physical iPhone run: 3/3 editor gesture tests passed on the connected iPhone 15 Pro / iOS 27.0. Covered short direct grip drags at both ends, reextension, one-step Undo, actual two-touch pinch, preserved playhead/selection/history, repeated scroll/Split, Delete, Undo, and Redo. Result bundle: `/tmp/RallyCutTimelineVerifiedDevice.xcresult`.
- Retained iPhone screenshots: `/tmp/RallyCutTimelineVerifiedDeviceScreenshotsFinal`. These verify the corrected grip layout and absence of the extra command row. Physical touch automation does not establish that every mirrored mouse/trackpad input behaves identically.
- Strict formatting lint for the changed Swift files and `git diff --check` passed.

Test fixtures use a DEBUG-only environment variable and an isolated temporary project root. They do not import or edit the user's projects. Generated fixture tests do not establish real match footage quality, long HEVC/4K performance, or exact VLLO behavior.

## Subsequent green-filmstrip / hang correction

The earlier physical pinch screenshot already showed green thumbnail placeholders. The earlier tests asserted scale, playhead, and history without checking that decoded footage remained visible. Those results did not establish rendering stability.

The old pinch path changed every tile's sampling time, cleared each image, and launched fresh AVAssetImageGenerator instances on every gesture update. It also resized a SwiftUI hosting surface to the entire timeline width. Both behaviors have been removed:

- Filmstrip and selection backing views stay viewport-sized. The large scroll canvas provides coordinates only.
- Source samples are stable within zoom levels; existing decoded frames stretch continuously as tile widths change. Cached frames from the same clip fill newly exposed tiles while resampling catches up.
- Pinch suspends new frame generation. Afterward, one reused generator serially processes the latest visible demand, coalesces duplicate times, and retains at most 96 images of at most 240×140 pixels. Leaving the editor cancels decoding and releases the cache.
- AVPlayerLayer receives a player assignment only when the player instance changes, and detaches when the surface is dismantled. The reported private-framework `-12860` message alone does not establish the cause of the hang.
- The test video now has opaque red/blue content. UI assertions detect missing footage after each pinch, and verify playback, scrolling, Split, and Undo afterward. A decoder regression checks 1,000 zoom layout updates across the full scale range without additional decoding while pinching, including four-hour timeline coordinates.

Verification for this correction is recorded separately from the earlier interaction tests. Real-video injection uses `RALLYCUT_EDITOR_TEST_SOURCE` only within the existing isolated DEBUG test session; source files are read and copied, never modified.

### Rendering correction results

- Core: 33/33 passed with `swift test --scratch-path /tmp/RallyCutEditorFixSwift`.
- Full simulator suite: 19/19 passed (13 media, 2 library UI, 4 editor UI), `/tmp/RallyCutPinchRenderingFull.xcresult`.
- Final viewport-sized selection and expanded pinch stress: 3/3 targeted simulator tests passed, `/tmp/RallyCutPinchRenderingFinal.xcresult`. The stress reaches 480 pt/s and sharply zooms back out, checks visible fixture pixels after each gesture, and then plays, scrolls, splits, and undoes.
- iPhone 15 Pro / iOS 27.0: 4/4 editor tests passed, `/tmp/RallyCutPinchRenderingDevice.xcresult`. The final maximum-zoom stress separately passed with the final renderer, `/tmp/RallyCutPinchExtremesDevice.xcresult`. Screenshots are in `/tmp/RallyCutPinchExtremesDeviceScreenshots`.
- Real footage: a 458.462-second, 1920×1080 H.264 match completed the final twelve-gesture stress and subsequent playback, scroll, Split, and Undo in the simulator, `/tmp/RallyCutPinchReal1080.xcresult`. The retained screenshot was visually inspected: source preview and filmstrip show match footage, total duration 07:38. Color-fixture pixel assertions are intentionally not applied to arbitrary footage. Screenshot: `/tmp/RallyCutPinchReal1080Screenshots/A961F177-78B5-4DD8-B2BB-190ED5354B0B.png`.
- No matching `PlayerRemoteXPC` / `12860` messages appeared in the queried simulator app log window. The device result has no console log, so these tests do not establish that the private-framework message is absent on the phone.
- Strict Swift formatting lint and `git diff --check` passed. The user's exact failing asset, 4K/HEVC footage, prolonged thermal behavior, and mirrored trackpad pinch remain unverified.

## Nearby split boundaries appeared to move

The user supplied `finding_frame_error.mp4`, a 2.651-second screen recording. It shows a selected Clip 2 before Split and Clip 3 afterward, with the old selected outline disappearing and the new selected outline starting at the playhead. No error alert appears. This recording demonstrates a successful new split whose earlier boundary becomes visually indistinguishable; it does not show a rejected 0.9-second edit.

The UIKit filmstrip rewrite omitted the permanent white clip separators previously drawn by the SwiftUI thumbnail cells. Only the current selection outline remained. When Split selected the new right-hand clip, the preceding cut appeared to have moved. This was a regression introduced by the thumbnail rendering correction.

Restored a white separator at every visible clip start independently of selection, above the thumbnail cells. The separators use the same edit-time coordinates as the filmstrip and update on scroll, zoom, Undo, and Redo. The edit model and minimum-frame rule are unchanged. Test coverage now includes cuts at 10.0 and 10.9 seconds, selection changes, Undo/Redo, and preservation of both visible cut lines after the second Split.

- Simulator: 4/4 targeted tests passed, including nearby boundaries, selection/Undo/Redo, the decoder suspension regression, and the full-range pinch stress; `/tmp/RallyCutSubsecondSplitSimulator.xcresult`.
- Physical iPhone 15 Pro / iOS 27.0: the nearby-split UI test passed, including a real Split command after zoom, clip count 2→3, both visible boundaries, Undo to 2, and Redo to 3; `/tmp/RallyCutSubsecondSplitDevice.xcresult`.
- The retained device screenshot shows the unselected first cut and the new selected cut around the 0.9-second interval: `/tmp/RallyCutSubsecondSplitDeviceScreenshots/0DAEC4CD-43CE-489A-A307-E3636400A5EC.png`. These tests used isolated generated media; the user's screen recording was inspected, not used as the original match video.
- Strict formatting lint and `git diff --check` passed.

## Split guardrails, toast feedback, and handle removal

- Removed the visible start/end trim grips, their 44pt hit areas, pan/accessibility adjustment handlers, trim auto-scroll/display link, provisional trim state, and source-preview player. There is no invisible edge-drag replacement. Existing trim ranges and history remain readable in the domain model.
- Zoom remains clamped to 3–480 pt/s. Split keeps at least 0.15 seconds and one source frame on both sides, resolves original source timestamps, and commits using the same resolved minimum. The button no longer independently guesses validity from nominal FPS. Only active operations or scrubbing temporarily disable it; other unavailable requests explain the reason in a toast.
- `EditorState.splitRestriction` is shared by eligibility checks and the committed Split. The user set the final product policy to 150 included clips and a 0.15-second minimum, superseding the earlier proposed 500-clip / one-frame policy. Split, restoration, and replacement ranges enforce the cap and minimum; source-frame duration can raise the effective minimum. Existing saved edits and Undo/Redo history remain readable without truncation.
- `EditorSplitLookup` ends the UI wait after 3 seconds, requests cancellation, and discards late results using a request identity. Revision and interaction checks still precede the commit. An OS media call may take longer to acknowledge cancellation; its late result cannot mutate the project or complete a newer request.
- Source frame lookup ignores compressed reader marker-only buffers and rejects snap distances above 0.5 seconds. No source frame is invented when a VFR interval has no internal timestamp.
- Toasts last 4 seconds, replace prior messages, allow editing gestures through, and announce their content to VoiceOver. Boundary, too-short, clip-limit, unreadable-video, and timeout cases provide a next action. Product copy follows the app's existing English UI.
- The earlier 500-clip stress case exposed a related thumbnail queue issue: visible requests beyond the old first-64 cap were never loaded, while naive cache eviction could reload the same demand indefinitely. The queue now processes each current visible key once, and visible cells retain decoded images after cache eviction. The generator/cache remain bounded to one in-flight decode and 96 cached images; visible cells can additionally retain their displayed images until recycled. A 150-clip regression covers demand larger than the cache and verifies completion without repeated decoding.

The guards are covered with deliberately mismatched nominal FPS, one-frame/two-frame clips, an empty timestamp interval, timeout and stale completion, 150-clip Split rejection without history changes, and UI toast/handle absence tests. Tests use isolated DEBUG fixture projects.

### Final requested duration policy

The policy is shared by `EditorState.minimumClipDuration` (0.15) and `maximumIncludedClipCount` (150). Frame resolution uses `max(0.15, track.minFrameDuration)` and passes that same value to the core mutation. The caller cannot bypass the product minimum by supplying a shorter frame duration. A 0.30-second clip at 30fps has only nine frames and cannot yield two valid clips; ten frames can split into two five-frame clips. At 60fps, two 0.15-second clips are representable exactly. UI rejection uses the same 0.15-second and 150-clip values in its toast messages.

### Final policy verification — 2026-10-20

- Core: 35/35 passed using `swift test --scratch-path /tmp/RallyCutEditorFixSwift`, including the 150-clip cap, 0.15-second minimum, rejected edits preserving state/history, restoration/replacement range guards, and mixed edit history.
- Full simulator suite: 31/31 passed on iPhone 15 / iOS 18.0, with no skipped tests. Result bundle: `/tmp/RallyCutGuardrails150Simulator.xcresult`. Includes exact 0.15-second clips at 60fps, source-frame rounding at 30fps, timeout/late-result isolation, dense thumbnail completion, pinch/rendering, and editor UI regressions.
- Physical iPhone 15 Pro / iOS 27.0: 6/6 targeted editor tests passed. Covered short-clip rejection, the 150-clip cap, persistent nearby split boundaries, removal of handles and their drag interception, timeout toast without mutation, and Split during playback followed by Undo. Result bundle: `/tmp/RallyCutGuardrails150Device.xcresult`.
- Retained device screenshots: `/tmp/RallyCutGuardrails150DeviceScreenshots`. Visually inspected `E714E55A-C4FE-42D5-B893-5E7CA5343DFA.png`: the 0.15-second guidance is visible above a 0.29-second selected clip, without white trim handles.
- Strict formatting lint for the changed Swift files and `git diff --check` passed. The installed app was subsequently launched normally on the phone, outside the isolated test session.

These final policy tests used isolated generated media. They do not establish performance for the user's original match asset, 4K/HEVC media, prolonged thermal load, or mirrored trackpad pinch. The earlier real-video regression is recorded separately above.
