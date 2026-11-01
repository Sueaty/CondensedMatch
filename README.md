# Rally Cut

A native iPhone video editor built with SwiftUI, AVFoundation, PhotosUI, and a temporary editing session. Requirements and design live in [Editor_PRD.md](./Editor_PRD.md) and [Editor_TECHNICAL_DESIGN.md](./Editor_TECHNICAL_DESIGN.md). No third-party packages, accounts, analytics, or network client.

## Run

1. Open **RallyCut.xcodeproj** in Xcode 26.
2. Select the **RallyCut** scheme and an iOS 18+ iPhone simulator, then Run.
3. For a physical iPhone, choose your signing team under Signing & Capabilities.

The main screen offers video import without a project list. Import a video from Photos to open the editor with a full-source included clip.

## Editing workflow

- System Photos picker with provider progress, cancellation, owned source copy, and media validation.
- Composition preview, playback controls, scrolling thumbnail timeline, pinch zoom, split/delete/restore, undo/redo, and export.
- Non-destructive edits with in-memory clip state and history; the original source remains unchanged.
- MP4 export with progress, cancellation/retry, source orientation, audio-track timing, Files/system sharing, and add-only Photos saving. Export re-encodes the retained footage.
- Session-only source copies and exports, with file protection until first device unlock.

The timeline keeps its center playhead fixed over gap-free included clips. Pinch zoom spans 3–480 points per second. Split reads nearby video sample presentation timestamps, including variable-frame-rate sources, with a nominal-frame-rate fallback. Export is cancelled on backgrounding and can be retried.

## Code organization and storage

`Sources/MatchCore` contains Codable editing models, timeline interval normalization, edit history, timeline layout. It also compiles independently as a Swift package.

`Sources/App` contains the observable app store, owned-media import, playback, thumbnail generation, composition/export services, and SwiftUI screens. Xcode compiles both source folders directly.

`EditorState` owns editing, playback, duration, and export. The app keeps one active project in memory, including Undo/Redo, selection, and timeline state. Background/foreground transitions retain the current session while the process is alive. App termination starts a fresh session on the next launch.

Working media and exports live in `Library/Caches/EditingSession/<UUID>/`. Returning to the main screen discards the editing session and removes its files. A new app process removes leftover session files and the former `Documents/Matches` library; there is no project JSON, autosave, or relaunch restoration. Videos explicitly saved to Photos or shared outside the app remain untouched. Save or share an export before leaving the editor.

## Verify

```sh
swift test --scratch-path /tmp/RallyCutSwiftBuild
xcodebuild -project RallyCut.xcodeproj -scheme RallyCut \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=18.0' \
  -derivedDataPath /tmp/RallyCutDerived CODE_SIGNING_ALLOWED=NO test
```

Core tests cover editing, time mapping, history, and layout. Media tests generate H.264 fixtures and exercise AVFoundation import, composition, export, audio, orientation, and frame boundaries. UI tests exercise the main screen, session lifecycle, and editor interactions. Fixtures and simulator tests do not establish physical-device performance or human-perceived cut quality on long real videos.

Readable inputs from 1 second to 4 hours are accepted. H.264/HEVC up to 4K is the intended validation envelope. Long real-video scrub performance and physical-device variable-frame-rate behavior require device validation.

`PrivacyInfo.xcprivacy` declares no tracking/collection and documents the disk-space API reason. Photos access uses the system picker and add-only save authorization.
