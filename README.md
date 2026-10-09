# Rally Cut

A native, on-device iPhone app built from [Tennis_Condensed_Match_PRD.md](./Tennis_Condensed_Match_PRD.md). Editor requirements and design live in [Editor_PRD.md](./Editor_PRD.md) and [Editor_TECHNICAL_DESIGN.md](./Editor_TECHNICAL_DESIGN.md). SwiftUI, AVFoundation, PhotosUI, and a file-backed repository. No third-party packages, accounts, analytics, or network client.

## Run

1. Open **RallyCut.xcodeproj** in Xcode 26 (the project uses synchronized groups supported by Xcode 16+).
2. Select the **RallyCut** scheme and an iOS 18+ iPhone simulator, then Run.
3. For a physical iPhone, choose your signing team under Signing & Capabilities.

The library begins empty. Import a match video from Photos to begin. Rally Cut does not record video, and no sample recordings or fabricated match results are bundled.

## Implemented workflow

- Library with thumbnails, source/condensed durations, status, creation date, and explicit deletion choices.
- System Photos picker with provider progress, cancellation, owned source copy, media preflight, and warnings. No read permission for the entire Photos library.
- Successful import opens the SwiftUI video editor immediately with a full-source included clip. The editor shows a control-free composition preview, playback controls, a scrolling thumbnail timeline, split/delete/restore, undo/redo, and export.
- Optional AI setup and suggestion review are reached from the editor's More menu rather than occupying editing space. Court selection remains a separate sheet.
- AI results are persisted as pending suggestions; users can review their time ranges, dismiss them, or explicitly replace the current clips with confirmation. Applying suggestions adds an undo step. Analysis never automatically replaces manual edits.
- Actual audio-energy/transient extraction, sampled court-region frame differencing, and Vision `VNDetectHumanBodyPoseRequest` wrist/elbow/shoulder/hip/knee/ankle motion features. One video sample per second; fixed-size grayscale buffers. Analysis runs outside the main actor and checkpoints roughly every 15 source seconds. Vision pose is a supporting signal and does not by itself identify a serve or point winner.
- Versioned fusion and deterministic segmentation: hysteresis, padding, minimum activity, short-gap/first-serve-gap merging, range clamping, and review state. This is a **heuristic baseline**, not a trained tennis sound classifier.
- Original and condensed playback; source-context inspection; inclusion/exclusion; manual additions; 30 levels of persisted undo. Needs-review segments remain included by default.
- Non-destructive AVComposition previews; overlapping retained ranges are united, ordered, and exported once.
- MP4 export with a conservative disk-space allowance, progress, cancellation/retry, source orientation, audio-track timing, Files/system sharing, and add-only Photos saving. Re-encoding is disclosed.
- Atomic versioned project JSON; analysis checkpoint resume; corrupt/missing media handling; source protection. Export writes a unique temporary file and promotes it on success. App-owned media is protected until first device unlock.
- An offline benchmark command for fixed observation streams with ground-truth point intervals.

The app is foreground-first: navigation does not cancel analysis; entering the background pauses it. Export is cancelled on backgrounding and can be retried. It does not promise indefinite background execution.

## Important delivery boundary

This delivers the manual end-to-end workflow and the Phase 2 heuristic baseline, plus Vision pose features, analysis checkpoint resume, and validation infrastructure. It is **not an externally validated MVP release**. No labelled/consented dataset or trained tennis action `.mlmodel` was supplied. The current detector cannot classify racket hits, bounces, speech, or adjacent-court activity as semantic labels. It can miss short/quiet points and retain unrelated movement. All automatic segments are explicitly marked **Needs review**. The next ML step is a Create ML action classifier trained from `serve_start`, `point_active`, `point_end`, and negative between-point examples.

The PRD’s 95% point-time recall, 70% dead-time removal, correction-burden, battery, thermal, and supported-device launch gates remain unmeasured. Phase 3 model training and frozen-corpus evaluation require real data; no fabricated performance figures are used. App Store packaging/privacy submission and an accessibility/device audit remain release work.

Default input: continuous, fixed-camera, landscape singles footage behind the baseline, 1 second–4 hours. H.264/HEVC up to 4K is the intended validation envelope, not a verified compatibility promise. Unsupported but readable setups can continue with warnings. Variable-frame-rate Split has fixture coverage but has not been physically validated. Export uses highest-quality MP4, which can require substantial space and may adapt dimensions to encoder constraints.

## Code organization

`Sources/MatchCore` contains Codable domain models, deterministic segmenting/fusion, interval normalization, undo, the repository, and benchmark measurements. It compiles independently as a Swift package. Schema v1 is the first persisted format; unknown future versions are rejected without modifying source media. Add explicit migrations when introducing v2.

`Sources/App` contains the observable app store, owned-media import, asynchronous analysis actor, composition/export services, and the app UI stages. The Xcode app compiles both folders directly; it does not require installing the package.

The editor uses persisted `EditorState` for its clip list, split/exclude/restore/undo/redo, composition preview, duration, and export. Existing projects are migrated from retained `PointSegment` ranges when loaded; AI suggestions remain separate until accepted. The timeline seeks throughout a scroll, coalescing rapid requests, and keeps its center playhead fixed over gap-free included clips. Its scale is fixed at 30 points per second; pinch zoom is not supported. Split reads nearby video-sample presentation timestamps, including for VFR; nominal frame rate is only a fallback for minimum clip duration. Real-device VFR footage and long-match scrub performance remain unverified. The older segment model remains for compatibility and AI results but is no longer the editor UI's authority.

Projects live at `Documents/Matches/<UUID>/`. “Delete project only” removes `project.json`, leaving the owned video, thumbnail, and exports accessible in Files. “Delete project, local video & exports” removes that project folder. Neither action touches the Photos source or videos already saved/shared externally. Exports from earlier edits remain in Files but are not presented as the current edit. Only explicit project deletion removes those results.

## Verify

```sh
cd /Users/sueaty/Documents/CondensedMatch
swift test
swift run match-benchmark Tests/Fixtures/synthetic-benchmark.json
xcodebuild -project RallyCut.xcodeproj -scheme RallyCut \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=18.0' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

The benchmark fixture is synthetic and only verifies mechanics; its numbers are not detection-quality claims. Supply a JSON array of cases with `name`, `duration`, `activePoints` (`start`, `end`), timestamped `audio`/`visual` samples (`time`, `value` in 0…1), and `hasAudio`. The runner executes fusion/segmentation and reports interval-union point-time recall, dead-time removal, false-segment rate, and retained duration. Undefined denominators are encoded as absent optional values. Correction burden and boundary-error scoring require a separately defined annotation/matching protocol and are not reported.

Media tests generate their own tiny H.264 fixtures, including audio and rotation, and test actual AVFoundation operations. They do not establish human-perceived cut quality or real-world detector accuracy.

Verified on 2026-10-09: 24 core unit tests and 9 media integration tests passed, and the app built for an iPhone 15 / iOS 18.0 simulator. The 2 UI smoke tests passed previously, but do not exercise successful Photos selection or editor gestures. The user reported the prior editor scrub/split/delete/export flow worked on their device. Long real-match footage and physical-device VFR behavior remain unverified.

`PrivacyInfo.xcprivacy` declares no tracking/collection and disk-space access for storage preflight and visible free-space information, using Apple’s documented reasons [E174.1 and 85F4.1](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). Review the declaration again before distribution if dependencies or data handling change.

### Physical-device checklist

- Local and iCloud Photos import, cancellation, large HEVC files, missing/unreadable media.
- Analysis interruption at audio/video stages, process termination, resume, thermal and battery behavior.
- Frame-accurate edits, source/condensed playback with audible synchronization, portrait warnings, variable frame rate.
- Export cancellation/retry, near-full storage, Photos add-only permission, sharing, relaunch.
- Dynamic Type, VoiceOver, landscape layout, and large accessibility sizes across the full workflow.

## Apple references

- [AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)
- [PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker)

The repository-level PRD defines the app-wide contracts and document precedence.
