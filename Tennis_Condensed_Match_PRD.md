# Product Requirements Document: Tennis Condensed Match

| Field | Value |
|---|---|
| Working title | Project Condensed Match |
| Document status | Draft for product and engineering review |
| PRD version | 1.2 |
| Date | 2026-10-08 |
| Initial platform | iPhone |
| Proposed minimum OS | iOS 18 or later; confirm after device benchmarking |
| Processing model | On-device only for MVP |
| Primary sport | Singles tennis |

## Related implementation documents

Use this PRD as the source of truth for the complete Condensed Match product, including project persistence, AI-assisted point detection, editor integration, export, privacy, and the iOS 18 platform baseline.

When implementing the **Video Editor**, also use these specialized documents:

- [`Editor_PRD.md`](./Editor_PRD.md): detailed editor UX, interactions, state transitions, edge cases, and acceptance criteria.
- [`Editor_TECHNICAL_DESIGN.md`](./Editor_TECHNICAL_DESIGN.md): editor architecture, media-time model, AVFoundation composition and playback, undo/redo, thumbnail generation, and export implementation guidance.

The specialized documents refine the editor requirements in this PRD; they do not replace app-wide requirements. If a specialized document conflicts with this PRD on project lifetime, persistence, AI integration, minimum OS, or the existing app architecture, this PRD takes precedence until the documents are explicitly reconciled.

## 1. Executive summary

Project Condensed Match is an iPhone video editor that turns an imported tennis recording into a shorter, watchable match without altering the original. The user imports a video and immediately enters a non-destructive editor where they can edit manually, invoke on-device AI to propose point segments, review those suggestions, and preview or export the result.

The MVP solves one problem only: finding and retaining the portions of a tennis video in which a point is being played. It does not determine the score, make line calls, identify the winner, or create player-specific highlights.

The product uses a hybrid approach:

- The video editor provides manual trimming, inclusion, exclusion, and segment-management tools independently of AI.
- User-invoked on-device audio and visual analysis proposes likely point segments.
- Deterministic temporal rules convert observations into editable point segments.
- AVFoundation creates non-destructive condensed playback and an optional exported video.

## 2. Problem statement

Tennis players, parents, and coaches often record entire practices or matches, but reviewing those recordings is inefficient because substantial portions contain preparation, ball collection, breaks, and changeovers rather than active points. Manually scrubbing and cutting every point requires enough effort that many recordings are never reviewed or shared.

The product hypothesis is that users will review and share more recorded tennis if the app provides a trustworthy editor and optional AI assistance that reduces the work of locating and removing dead time.

### Evidence status

This PRD is based on a product hypothesis and competitive-product observation, not completed user research. Before public launch, the team must validate:

- How often target users record matches.
- How much time they currently spend trimming or reviewing recordings.
- Whether users prefer maximum dead-time removal or additional context around points.
- What correction burden users consider acceptable.
- Which editor actions users need before they are willing to rely on AI suggestions.

These unknowns do not block the first technical vertical slice, but they do affect launch positioning and default settings.

## 3. Target users

### Primary persona: self-improving recreational player

- Records singles matches or practice sets with an iPhone behind the baseline.
- Wants to review technique and match patterns without watching the entire recording.
- Is willing to spend a few minutes correcting an automatically generated result, but not manually edit every point.

### Secondary persona: coach or parent

- Records another player's match.
- Wants a compact video that can be reviewed or shared shortly after play.
- Values retaining every point more than creating the shortest possible video.

### MVP environment assumptions

- A single tennis court is fully visible.
- The camera is fixed and landscape-oriented behind a baseline or back fence.
- The recording contains singles tennis.
- Audio is present, although the app must degrade gracefully when audio quality is poor.
- The source is a continuous recording rather than an edited montage.

## 4. Product principles

1. **Never lose the original.** Detection and editing are non-destructive.
2. **Missing a real point is worse than retaining extra dead time.** Defaults prioritize point recall over maximum compression.
3. **Automation must remain reviewable.** Users can see and correct every retained segment.
4. **The first useful result should not require export.** Condensed playback is available directly from the generated timeline.
5. **Privacy is a product feature.** MVP video and inference stay on the device.
6. **AI proposes; deterministic code edits.** Models produce observations and confidence values, while explicit rules determine segment boundaries and composition behavior.
7. **Editing does not depend on AI.** The editor is usable immediately after import, and failed, cancelled, or unavailable analysis never blocks manual editing.

## 5. Goals

Targets below are proposed launch gates and must be validated against a frozen, representative benchmark corpus before beta release.

### User goals

1. A user can turn a supported full-match recording into a condensed, playable timeline without manually marking every point.
2. At least 95% of annotated point-playing time is retained on the benchmark corpus.
3. At least 70% of annotated dead time is removed on the benchmark corpus.
4. The median user makes no more than one segment-level correction per ten detected points during beta evaluation.
5. Users can preview the condensed result before committing time and storage to export.

### Product and engineering goals

1. All analysis runs locally in MVP; no match video or extracted frame is uploaded.
2. Analysis and export survive ordinary UI navigation and provide recoverable state after interruption.
3. The original recording remains unchanged and available until the user explicitly deletes it.
4. The app reports analysis quality and failures without presenting uncertain detection as fact.
5. Detection performance, processing time, battery use, and thermal behavior are measured on each supported device class before release.

## 6. Non-goals

The following are explicitly outside MVP scope:

1. **Autoscoring:** Determining point winners, games, sets, or tiebreak scores requires a more complex perception and rules system.
2. **Apple Watch integration:** Watch-based scoring, confirmation, and recording controls do not improve the core hypothesis enough to justify MVP complexity.
3. **Player-specific highlights:** Identifying and following a selected player depends on stable player identity and point-outcome inference.
4. **Line calling:** Accurate in/out decisions require court calibration and ball localization beyond activity segmentation.
5. **Shot statistics:** Speed, placement, spin, and shot-type classification are separate products.
6. **Cloud processing or backup:** MVP avoids upload latency, storage expense, account requirements, and additional privacy obligations.
7. **Android, iPad, and macOS clients:** The first release validates the workflow on iPhone only.
8. **Automatic social publishing:** Export uses the system share sheet; direct integrations are deferred.
9. **Guaranteed support for handheld, portrait, multi-court, or broadcast footage:** These inputs may be imported but are not supported configurations in MVP.
10. **In-app recording:** Users import an existing video; camera capture and recording permissions are outside this product flow.

## 7. Core user journey

1. The user opens the app and chooses **Import Video**.
2. The app imports the selected video, validates it, creates a project, and opens the **Video Editor**.
3. The user can immediately preview and edit the video manually.
4. From the editor, the user may configure the court region and invoke **Find Points with AI**.
5. Analysis runs on-device and returns candidate point segments as reviewable suggestions in the same editor.
6. The user accepts, rejects, trims, splits, merges, adds, or removes segments while comparing condensed and source context.
7. The user previews the current condensed timeline.
8. The user exports the result or leaves the persistent project to continue later.

## 8. User stories

### P0 stories

1. As a player with an existing recording, I want to import it from Photos and enter the editor immediately so that I can begin working without waiting for analysis.
2. As a user, I want to identify the relevant court area so that activity from adjacent courts is less likely to appear in my result.
3. As a user, I want the app to automatically find probable points so that I do not need to mark every clip manually.
4. As a user, I want the app to retain context immediately before and after each point so that the result does not feel abruptly cut.
5. As a user, I want first-serve faults and the following second serve kept together so that a single point is not fragmented.
6. As a user, I want to preview the condensed match without exporting so that I can evaluate the result immediately.
7. As a user, I want to restore excluded footage and remove false detections so that automation never permanently hides content.
8. As a user, I want to adjust the beginning and end of a segment so that I can correct imperfect boundaries.
9. As a user, I want to export the corrected condensed match so that I can save or share it.
10. As a user, I want clear handling of low-confidence or failed analysis so that I know when manual review is needed.
11. As a privacy-conscious user, I want analysis to remain on my iPhone so that my match footage is not uploaded without consent.
12. As a user, I want AI to be optional and user-invoked so that I remain in control of when analysis changes the proposed edit.
13. As a user, I want AI suggestions to remain distinguishable from my committed edits so that I can review them before relying on them.

### Edge-case stories

1. As a user with a silent or noisy recording, I want the app to explain that detection quality may be reduced and still offer manual editing.
2. As a user whose analysis is interrupted, I want completed work to be preserved so that I do not need to restart from zero.
3. As a user whose device lacks export storage, I want an estimate and actionable warning before export begins.
4. As a user whose video contains no detected points, I want to create segments manually rather than reach a dead end.
5. As a user with an unsupported camera angle, I want guidance before analysis so that I understand how to improve the result.

## 9. Functional requirements

### P0-1: Project creation and recovery

The app must create and maintain local projects for imported videos. Import is the entry point for a new project; previously created projects may be reopened from a secondary recent-projects or project-library entry point.

Acceptance criteria:

- Given the user has created projects, when they open the secondary projects surface, then it displays each project with thumbnail, creation date, source duration, condensed duration when available, and status.
- Given a project is incomplete, when the user opens it, then the app resumes at the latest recoverable stage.
- Given the user deletes a project, then the app clearly distinguishes deleting project metadata, an app-owned source file, and an exported result.
- The app does not delete a Photos-library source asset.

### P0-2: Import video

The app must import a user-selected video using the system photo picker.

Acceptance criteria:

- Import does not require broad Photos-library access when the system picker can provide the selected item.
- Supported video is copied or referenced safely for the lifetime of the project.
- Unsupported or unreadable assets produce an actionable error.
- Import progress is visible for large or cloud-backed Photos assets.
- Successful import creates a persistent project and opens the video editor directly.
- Import failure leaves the user at a recoverable import state and does not create a broken project.

### P0-3: Video editor workspace

The app must provide a non-destructive editor as the primary workspace immediately after import. Manual editing must remain available before, during, and after AI analysis.

Acceptance criteria:

- The imported source is playable as soon as the project opens.
- The editor exposes source and condensed context, an editable timeline, undo and redo, and a clear export action.
- The user can create, trim, split, merge, include, exclude, and delete editable segments without running AI.
- AI features are invoked from the editor and return suggestions to the editor rather than navigating to a separate mandatory workflow.
- AI suggestions do not silently overwrite committed manual edits.
- Closing and reopening the project restores the last committed edit state.

Detailed editor interaction and implementation requirements are maintained in [`Editor_PRD.md`](./Editor_PRD.md) and [`Editor_TECHNICAL_DESIGN.md`](./Editor_TECHNICAL_DESIGN.md). Apply them using the document precedence defined in **Related implementation documents** above.

### P0-4: Preflight validation

Before analysis, the app must inspect whether the input is suitable.

Acceptance criteria:

- The app validates that the asset contains a readable video track.
- The app records whether usable audio exists.
- The app warns about portrait orientation, moving-camera footage, incomplete court visibility, and low remaining storage when detectable.
- Warnings do not destroy or alter the source.
- Users may continue after nonfatal warnings.

### P0-5: Court-region setup

The user must be able to define the portion of the image containing the target court when invoking AI analysis. Court setup is not required for manual editing.

Acceptance criteria:

- The app displays a representative frame and an adjustable region overlay.
- The selected region is stored in normalized coordinates independent of video resolution.
- The app offers reset and confirm actions.
- Analysis outside the selected region is ignored or heavily down-weighted.
- Full automatic court-line calibration is not required.

### P0-6: Optional on-device AI analysis

From the editor, the user may ask the app to generate candidate point intervals using only local computation. Analysis is optional and must not block the manual editor.

Acceptance criteria:

- No source video, audio sample, extracted frame, or model feature is sent over the network.
- The user sees determinate progress when total work is measurable and stage-based progress otherwise.
- The app exposes stages such as preparing, analyzing audio, analyzing video, generating points, and finalizing.
- The user can cancel analysis without losing the source video.
- Completed analysis metadata is persisted incrementally.
- A failed model or media operation reports a categorized error and permits retry or manual editing.
- The editor remains usable when analysis is cancelled, fails, or produces no suggestions.
- Rerunning analysis must state how new suggestions interact with accepted suggestions and manual edits before applying any change.

Technical behavior:

- Audio classification produces timestamped probabilities for racket impact, bounce, speech, adjacent-court activity when distinguishable, and ambient noise.
- Visual analysis produces timestamped court-region activity measurements.
- A temporal fusion component combines observations into an activity probability over time.
- A deterministic segmenter applies start/end hysteresis, context padding, minimum duration, and short-gap merging.
- Model and segmenter versions are stored with every analysis result.

### P0-7: Segment-generation rules

The app must turn observations into point segments without claiming to know the score or winner.

Acceptance criteria:

- Every segment has source start, source end, confidence, inclusion state, and creation source.
- Retained intervals never exceed the source duration.
- Overlapping intervals are merged deterministically.
- Very short false-trigger intervals are rejected according to versioned configuration.
- A short pause consistent with a first-serve fault does not automatically split the point.
- Configurable pre-roll and post-roll are applied without producing overlaps or invalid ranges.
- Low-confidence intervals remain recoverable from the review interface.

### P0-8: Editor review and correction

The user must be able to inspect and correct the generated timeline.

Acceptance criteria:

- The review UI distinguishes included, excluded, and needs-review intervals without relying only on color.
- Tapping a segment plays its source context.
- The user can include or exclude a segment.
- The user can adjust segment start and end times with frame-appropriate precision.
- The user can add a segment manually from excluded footage.
- The user can split and merge segments.
- Undo and redo are available for editing actions.
- Edits persist across relaunch.
- Editing segment metadata does not transcode the source video.

### P0-9: Condensed playback

The app must play included source intervals as one continuous condensed match.

Acceptance criteria:

- Playback follows the current ordered list of included segments.
- Changes to inclusion or boundaries appear in the next preview without full export.
- Audio remains synchronized with video at segment boundaries.
- Playback transitions do not introduce black frames or invalid orientation.
- The app shows both condensed position and, when inspecting a segment, source position.

### P0-10: Export and sharing

The user must be able to export the current condensed timeline to a standard video file.

Acceptance criteria:

- Before export, the app estimates required free space or warns when an estimate is unavailable.
- Export preserves source orientation and synchronized audio.
- Export failure does not damage the source or project metadata.
- The user can cancel export and retry.
- Successful export can be saved to Photos or shared through the system share sheet.
- The app clearly reports output resolution and whether re-encoding occurs.

### P0-11: Local persistence and recovery

The app must persist project, analysis, and editing state.

Acceptance criteria:

- Project metadata includes stable project and segment identifiers.
- Analysis writes recoverable checkpoints rather than saving only at final completion.
- Relaunch after ordinary termination restores the last committed state.
- Corrupt or missing source files are reported without crashing.
- Schema and model-version migrations are testable.

### P0-12: Privacy and data control

Acceptance criteria:

- MVP functions without account creation.
- Network connectivity is not required after any user-requested Photos download completes.
- The app provides a plain-language explanation that video analysis occurs on-device.
- Analytics, if enabled, contain no video, audio, thumbnails, raw model features, player identity, or precise location.
- Any future training-data contribution requires separate, explicit opt-in and is not bundled into general analytics consent.

## 10. P1 requirements: fast follow after MVP

1. Automatic suggestion of the court region, with manual confirmation.
2. User-selectable context presets such as Tight, Balanced, and More Context.
3. Batch export resolution and codec preferences.
4. Improved processing continuation using supported system background mechanisms, while remaining resilient to interruption.
5. Direct comparison between source and condensed durations.
6. Private, opt-in submission of corrected examples for model improvement.
7. Doubles-specific model evaluation and support declaration.

## 11. P2 future considerations

The architecture should not prevent these features, but no MVP work should be added solely for them:

- Autoscoring and Watch confirmation
- Player-specific highlights
- Ball trajectory and shot statistics
- Line calling
- Coach annotations
- Shared team libraries
- Cloud backup and cross-device synchronization
- Android support
- Subscription tiers or team plans

## 12. Detection design

### 12.1 Inputs

- Audio samples aligned to the asset timeline
- Downsampled video frames
- User-selected normalized court region
- Source timing, orientation, and frame-rate metadata

### 12.2 Audio model

The initial custom model should classify short overlapping audio windows. Proposed labels:

- `racket_hit`
- `ball_bounce`
- `speech`
- `applause`
- `adjacent_court_or_distant_hit`
- `ambient_noise`
- `unknown`

The label set may be simplified after dataset inspection. The model output must include timestamp, class probabilities, model version, and inference errors.

### 12.3 Visual validator

The MVP visual component does not need exact ball tracking. It should measure whether motion consistent with active play occurs inside the selected region. Possible implementations, to be benchmarked before selection:

- Classical frame differencing or optical flow
- A compact activity classifier executed with Core ML
- Lightweight object detection used only as supporting evidence

Visual analysis should sample fewer frames than the source frame rate and must not block editor playback or interaction.

### 12.4 Temporal fusion and segmentation

The fusion algorithm converts timestamped signals into a point-activity probability. A deterministic state machine then produces segments:

```text
idle
  -> probable_start when hit confidence and/or court activity cross start criteria
  -> active while supporting events continue
  -> probable_end after activity falls below end criteria
  -> idle when the end condition remains satisfied
```

Post-processing applies:

- Pre-roll and post-roll
- Short-gap merging
- First-serve-fault preservation heuristic
- Minimum and maximum plausible segment durations
- Overlap normalization
- Confidence calculation

Thresholds and timing values are configuration data tied to a segmenter version. They must not be scattered as unexplained constants across UI or media code.

### 12.5 AI boundaries

AI is responsible for classifying observations, not editing video. The following remain deterministic:

- Segment padding
- Gap merging
- Timeline ordering
- User edits
- Composition generation
- Export
- Source retention and deletion

## 13. Technical architecture

```text
Import -> SourceAssetStore -> Video Editor -------------------+
                              |                               |
                              +--> manual edit operations     |
                              |                               |
                              +--> optional AnalysisCoordinator
                                      |                       |
                                      +--> AudioAnalyzer      |
                                      +--> VisualAnalyzer     |
                                      v                       |
                               ObservationFusion              |
                                      v                       |
                               PointSegmenter                 |
                                      v                       |
                               reviewable suggestions --------+
                              |
                              +--> committed PointSegments
                                      |
                                      +--> AVComposition preview
                                      +--> AVAssetExportSession --> export file
```

### Recommended Apple frameworks

- SwiftUI for the application UI
- AVFoundation for asset reading, timeline composition, playback, and export
- Core ML for custom on-device models
- Sound Analysis for file-based audio classification
- Vision or Accelerate for visual activity processing where beneficial
- SwiftData or an equivalently testable local persistence layer for project metadata
- PhotosUI for user-selected imports

### Component boundaries

- `SourceAssetStore`: resolves project-owned and Photos-sourced assets safely.
- `AnalysisCoordinator`: runs cancellable, checkpointed analysis stages.
- `AudioAnalyzer`: converts audio to timestamped class probabilities.
- `VisualAnalyzer`: converts sampled frames to timestamped activity observations.
- `ObservationFusion`: combines signals without UI dependencies.
- `PointSegmenter`: pure deterministic transformation from observations to segments.
- `ProjectRepository`: persists projects, versions, checkpoints, and edits.
- `CompositionBuilder`: creates a playable composition from included source ranges.
- `ExportService`: exports with progress, cancellation, and error reporting.

Processing services should expose asynchronous, typed APIs and stay independent of SwiftUI views.

## 14. Conceptual data model

```swift
struct MatchProject: Identifiable, Codable {
    let id: UUID
    let createdAt: Date
    var source: SourceAssetReference
    var courtRegion: NormalizedRect?
    var analysis: AnalysisRecord?
    var segments: [PointSegment]
    var status: ProjectStatus
}

struct AnalysisRecord: Codable {
    let modelVersion: String
    let segmenterVersion: String
    let startedAt: Date
    var completedAt: Date?
    var completedStage: AnalysisStage
    var warnings: [AnalysisWarning]
}

struct PointSegment: Identifiable, Codable {
    let id: UUID
    var sourceStart: TimeInterval
    var sourceEnd: TimeInterval
    var confidence: Float
    var inclusion: InclusionState
    var origin: SegmentOrigin
}

enum SegmentOrigin: Codable {
    case automatic
    case userCreated
    case userAdjusted
}
```

The production implementation should use precise media time rather than floating-point seconds at AVFoundation boundaries. `TimeInterval` is shown only to keep the conceptual model readable.

## 15. UX requirements

### Screens

1. **Import:** system video picker, import progress, validation, and recoverable errors.
2. **Video Editor:** source/condensed player, editable timeline, manual tools, AI entry points, suggestion review, and export action.
3. **Court Setup:** an editor-presented sheet or mode used when preparing AI analysis.
4. **Analysis Status:** editor-integrated progress, current stage, cancel action, and warnings.
5. **Export:** resolution summary, storage warning, progress, cancel, and share result.
6. **Projects:** a secondary surface for reopening or deleting existing projects; it is not the new-project entry flow.

### Content guidelines

- Say “possible point” or “needs review” rather than claiming certainty.
- Explain why analysis quality may be reduced: no audio, moving camera, court not fully visible, or heavy adjacent-court activity.
- Distinguish “remove from condensed match” from “delete video.”
- Do not use AI terminology as a substitute for explaining product behavior.

### Accessibility

- Support Dynamic Type and VoiceOver for all non-video controls.
- Do not communicate included/excluded/confidence states through color alone.
- Provide text labels for timeline actions.
- Respect Reduce Motion where transitions are nonessential.
- Make trim handles usable with alternative increment/decrement controls, not drag gestures alone.

## 16. Non-functional requirements

### Performance

- Offline analysis must never run expensive work on the main actor.
- Frame sampling must be bounded; the pipeline must not accumulate unbounded pixel buffers.
- Preview generation should use composition metadata and avoid full re-encoding.
- Performance targets must be published per supported reference device after the technical spike.

### Reliability

- No fatal force unwraps or ignored persistence/export errors in production paths.
- Long-running stages support cancellation and checkpointing.
- Source assets are never modified in place.
- Export uses a temporary destination and promotes the file only after successful completion.
- Insufficient-storage and source-unavailable failures are recoverable.

### Privacy and security

- No network dependency for analysis.
- Temporary extracted data is protected with an appropriate iOS file-protection class and removed when no longer required.
- Logs must not contain file paths that expose user names, media content, or raw model inputs.
- Any crash-reporting integration must be reviewed for attachment and breadcrumb behavior.

### Compatibility

- The app must define and publish supported source orientations, codecs, resolutions, durations, and device classes.
- iOS 18 is the proposed baseline, subject to measurement rather than convenience alone.
- Thermal, interruption, and Photos behavior require physical-device validation.

## 17. Success metrics

### Detection quality

- **Point-time recall:** annotated active-point time retained / total annotated active-point time.
- **Dead-time removal rate:** annotated dead time excluded / total annotated dead time.
- **Segment boundary error:** absolute difference between predicted and annotated boundaries.
- **False-segment rate:** included segments containing no target-court point activity.
- **Correction burden:** segment additions, exclusions, and boundary edits per ten annotated points.

### Product behavior

- Percentage of started analyses reaching condensed playback.
- Median time from source selection to first condensed playback.
- Percentage of analyzed projects previewed.
- Percentage of previewed projects exported.
- Export success and cancellation rates.
- Source-to-condensed duration ratio, treated as descriptive rather than a quality metric.

### Reliability and device health

- Analysis failure rate by stage and device class.
- Peak memory during import, analysis, preview, and export.
- Thermal-state escalation during representative workloads.
- Battery consumption per hour of source footage.
- Recovery rate after interruption or relaunch.

### Measurement constraints

- On-device quality analytics must not contain media.
- Detection metrics requiring ground truth are calculated on an internal consented benchmark corpus.
- User-behavior analytics should be opt-in where required and minimize collection.

## 18. Validation and testing strategy

### Benchmark corpus

Create a versioned, access-controlled corpus with consent and annotations for:

- Outdoor and indoor courts
- Hard, clay, and visually varied court surfaces where available
- Daylight, artificial light, shadow, and low-light conditions
- Quiet courts and adjacent-court noise
- Different camera heights and supported behind-baseline positions
- Different iPhone microphones and cameras within supported device classes
- Short points, long rallies, aces, first-serve faults, lets, breaks, and changeovers

Freeze a validation subset before threshold tuning. Training and validation footage must not overlap at the session or player level where practical.

### Automated tests

- Unit tests for segment padding, clamping, merging, overlap handling, ordering, and undo.
- Table-driven tests for first-serve-gap and short-rally cases.
- Golden tests mapping fixed observation streams to expected segments.
- Persistence migration and interrupted-analysis recovery tests.
- Composition tests for segment ordering, audio synchronization, orientation, and duration.
- Export tests across supported codecs and resolutions.
- UI tests for import, review corrections, zero-result fallback, and export errors.

### Physical-device tests

- Long-video import and editing stability
- Incoming call and audio-session interruption
- Screen lock and app backgrounding
- Low-storage behavior
- Thermal throttling
- Cancellation during every analysis stage
- Export cancellation and retry
- Photos asset download and revocation behavior

## 19. Release gates

The MVP may enter external beta only when:

- All P0 requirements and acceptance criteria pass.
- Detection meets the approved point-recall and dead-time-removal targets on the frozen benchmark corpus.
- Correction burden meets the beta target or the team explicitly re-scopes the positioning to assisted editing.
- No known defect can delete or corrupt the source recording.
- Supported device classes complete the physical-device performance and thermal matrix.
- Privacy review confirms no video or derived media leaves the device.
- Accessibility review finds no blocker in the core workflow.
- The app clearly labels unsupported recording setups and uncertain results.

## 20. Delivery phases

### Phase 0: Dataset and measurement foundation

- Finalize the supported imported-video setup.
- Define annotation guidelines for point start, point end, first-serve fault, and dead time.
- Build the benchmark runner and metric calculations.
- Collect or license consented pilot footage.

Exit criterion: the team can run a repeatable evaluation and compare two segmenter versions.

### Phase 1: Manual end-to-end vertical slice

- Import
- Local project persistence
- Manual segment creation and editing
- AVComposition preview
- Export and sharing

Exit criterion: a user can manually create, preview, edit, relaunch, and export a condensed match without source modification.

### Phase 2: Heuristic detector baseline

- Audio energy and visual motion features
- Deterministic point state machine
- Automatic candidate segments
- Confidence and needs-review state

Exit criterion: the benchmark harness measures the complete automatic pipeline, even if accuracy is below launch threshold.

### Phase 3: On-device audio AI

- Label and train the custom audio classifier
- Integrate using Core ML and Sound Analysis
- Version model outputs
- Tune fusion and temporal rules using training data only

Exit criterion: audio AI materially improves correction burden or detection quality over the frozen heuristic baseline.

### Phase 4: Visual validation and hardening

- Reduce adjacent-court false positives
- Improve weak-audio handling
- Add checkpointing and failure recovery
- Complete device performance, memory, battery, and thermal work

Exit criterion: P0 quality and reliability release gates pass.

### Phase 5: External beta

- Conduct observed usability sessions
- Measure correction burden and completion funnel
- Resolve blocker defects
- Revisit default context and confidence settings

Exit criterion: product metrics justify public launch or identify a specific scoped iteration.

No calendar estimate is committed in this PRD because team size, available labelled footage, and supported-device requirements have not been specified.

## 21. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Adjacent courts produce similar sounds | False segments | Court-region visual gating, conservative inclusion, review state |
| Quiet impacts or wind reduce audio quality | Missed points | Visual activity fallback and higher-recall defaults |
| Moving camera invalidates motion analysis | Poor segmentation | Detect global motion, warn, and offer manual editing |
| First-serve faults are split or removed | Unnatural condensed match | Short-gap merge heuristic and annotated test cases |
| Model performs well only on training conditions | Unreliable beta | Diverse corpus, frozen validation set, per-condition reporting |
| Long video overheats older devices | User abandonment or interrupted work | Frame sampling, staged processing, checkpoints, supported-device policy |
| Background execution is interrupted | Incomplete analysis/export | Foreground-first UX, resumable stages, accurate messaging |
| Export doubles storage temporarily | Failure near completion | Preflight estimate, temporary-file lifecycle, retry support |
| Users interpret “AI” as perfect understanding | Loss of trust | Confidence states, review workflow, precise language |
| Scope expands toward SwingVision parity | Delayed validation | Treat scoring, Watch, highlights, and line calling as separate PRDs |

## 22. Dependencies

- Consent-cleared tennis video dataset
- Annotation process and tooling
- ML training environment and model conversion pipeline
- Physical supported iPhones for performance and thermal testing
- Product design for court setup, review, and trimming interactions
- Privacy review for analytics and any future training-data opt-in
- App Store assets, privacy declarations, and support documentation before public release

## 23. Open questions

### Blocking before MVP scope lock

1. **Product:** Is singles-only acceptable for launch messaging?
2. **Engineering/Product:** What minimum iPhone generation and iOS version will be supported?
3. **Product/Design:** Should defaults maximize point retention or minimize total duration? This PRD assumes retention.
4. **ML/Product:** What consented footage is available for training and validation?
5. **Engineering:** What maximum input duration, resolution, codec, and file size will be supported?
6. **Product:** Must first-serve faults always be retained, or should this be a user option?
7. **Product/Design:** Should AI suggestions begin as a preview layer, or be inserted into the editable timeline with a reversible bulk action?
8. **Product/Design:** When analysis is rerun, which manual and previously accepted AI edits are preserved?

### Non-blocking during early implementation

1. **Design:** Which confidence representation best helps users without creating unnecessary review work?
2. **Engineering:** SwiftData versus a lightweight file-backed metadata store after recovery testing.
3. **ML:** Whether classical motion features are sufficient or a compact visual Core ML model provides meaningful improvement.
4. **Product:** Whether exported video needs optional title cards or transitions after core quality is proven.
5. **Legal/Product:** Whether and how users may opt in to contribute corrected clips for training.

### Working defaults until changed

- Import is the only new-project entry point; in-app recording is out of scope.
- Public MVP is singles-only.
- Fixed landscape camera behind the baseline is the only supported setup.
- Point retention is prioritized over maximum compression.
- First-serve faults are retained with the following serve when temporal evidence supports the merge.
- Export defaults to a broadly compatible format and preserves source resolution when practical.

## 24. Technical references

- [Apple: AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)
- [Apple: Sound Analysis](https://developer.apple.com/documentation/soundanalysis)
- [Apple: Core ML](https://developer.apple.com/documentation/coreml)
- [Apple: Vision](https://developer.apple.com/documentation/vision)
- [Apple: Background processing](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask)

## 25. Approval checklist

- [ ] Product approves the problem, personas, goals, and non-goals.
- [ ] Design approves the core journey and correction workflow.
- [ ] Engineering approves platform assumptions and component boundaries.
- [ ] ML approves dataset, labels, evaluation method, and release targets.
- [ ] Privacy approves on-device behavior and analytics boundaries.
- [ ] QA approves the benchmark and physical-device test matrix.
- [ ] Stakeholders agree that scoring, Watch integration, and player highlights require separate scope approval.
