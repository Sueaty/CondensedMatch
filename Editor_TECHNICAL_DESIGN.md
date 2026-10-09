# 단일 영상 컷 편집기 기술 설계

> 문서 상태: MVP 구현 기준안 1.0
>
> 작성 기준일: 2026-10-08
>
> 제품 요구사항: [Editor_PRD.md](./Editor_PRD.md)

## 1. 목적과 설계 원칙

이 문서는 SwiftUI + AVFoundation으로 단일 영상의 Split, ripple delete, Undo/Redo, 미리보기, Export를 구현하는 구조를 정의한다.

> 구현 상태(2026-10-09): 스크롤 중 composition seek, 썸네일 타일, Split/Delete/Undo/Redo와 gap-free 타임라인 계산은 구현했다. Split은 요청 지점 주변의 비디오 sample presentation timestamp를 `AVAssetReader`로 읽어 가장 가까운 내부 경계를 선택하며, VFR fixture 테스트가 통과했다. 아래의 재사용 가능한 전체 sample index, 실제 기기 VFR 영상 검증과 장시간 성능 측정은 아직 남았다.

### 1.1 UI 프레임워크 결정

- **핵심 UI는 SwiftUI로 구현한다.** 기존 RallyCut 앱의 `@Observable` 상태, 내비게이션, 디자인 시스템, 접근성 구조를 유지한다.
- 재생, composition, thumbnail, export 같은 미디어 처리는 AVFoundation 서비스로 분리한다.
- UIKit은 기본 아키텍처가 아니다. 실제 기기 프로파일링에서 SwiftUI 타임라인의 스크롤·셀 재사용 성능이 목표를 충족하지 못할 때만 `UICollectionView` 기반 타임라인을 `UIViewControllerRepresentable`로 한정적으로 래핑한다.
- 편집 명령과 시간 매핑은 UI 프레임워크에 의존하지 않는 `MatchCore` 순수 모델이 소유한다.

핵심 원칙:

1. **원본 비파괴**: 원본 파일을 수정하지 않고 시간 범위만 편집한다.
2. **하나의 편집 시간축**: UI, 재생, 명령, Export가 동일한 `EditorState`를 사용한다.
3. **정수 기반 미디어 시간**: 계산은 `CMTime`/`CMTimeRange`로 하고 `Double`은 좌표 변환 경계에서만 쓴다.
4. **결정적 편집 명령**: Split/Delete 전후 상태가 명시적이며 Undo/Redo 결과가 항상 같다.
5. **파생 데이터 분리**: chunk의 타임라인 시작, 썸네일, composition은 원본 상태에서 계산 가능한 파생 데이터다.
6. **최신 요청 우선**: 스크럽 seek와 썸네일 생성은 오래된 비동기 결과가 최신 UI를 덮지 못하게 한다.
7. **정확성 우선 Export**: 속도나 파일 크기보다 미리보기와 출력의 일치, 방향, A/V 동기화를 우선한다.

## 2. 기술 범위

### 2.1 프레임워크

- SwiftUI: 화면 구성, 내비게이션, 상태 렌더링, 접근성
- UIKit: 성능 측정으로 필요성이 확인된 경우에만 타임라인 컬렉션 뷰 구현
- AVFoundation: 자산 검사, composition, 재생, 프레임 추출, Export
- PhotosUI: 단일 영상 선택
- Photos: 결과를 사진 보관함에 저장할 때만 사용
- UniformTypeIdentifiers: 입력/출력 타입 처리

최소 버전은 기존 RallyCut 제품 기준과 동일한 iOS 18이다. 사용하는 API의 availability는 프로젝트 SDK 기준으로 확인한다.

### 2.2 핵심 AVFoundation 구성

- `AVURLAsset`: 원본 자산과 비동기 메타데이터 로딩
- `AVMutableComposition`: 남은 source range를 연속 편집 시간축에 배치
- `AVPlayer` + `AVPlayerItem`: SwiftUI 미리보기와 재생 상태 제어
- `AVAssetImageGenerator`: 화면에 필요한 타임라인 썸네일 생성
- `AVAssetExportSession`: MVP 출력
- 필요 시 `AVMutableVideoComposition`: 원본 transform/표시 방향과 render size 보정

## 3. 아키텍처

```text
PhotosPicker
     │ selected URL / asset
     ▼
VideoEditorView ───────────────► EditorStore
     │ intents / rendered state      │ EditorState + history
     │                               │
     ├────────► TimelineView ─────────┤
     │             │                 ├────────► ThumbnailService
     │             └ scroll/pinch    ├────────► CompositionBuilder ─► AVPlayerItem
     │                               └────────► ExportCoordinator ──► AVAssetExportSession
     └────────► PlayerView / AVPlayer
```

### 3.1 책임 분리

| 타입 | 책임 | 하지 않는 일 |
|---|---|---|
| `VideoEditorView` | 화면 배치, intent 전달, 상태 렌더링 | 시간 계산, AV composition 편집 |
| `EditorStore` | 단일 `EditorState`, 명령 실행, 불변식 검증 | SwiftUI view 직접 조작 |
| `TimelineView` | 타임라인 셀, playhead overlay, 제스처 | source range 변경 |
| `TimelineLayout` | 시간↔x, item frame, inset, zoom 계산 | seek, thumbnail decoding |
| `PlaybackController` | player item 교체, play/pause/seek, time observation | 편집 정책 결정 |
| `CompositionBuilder` | chunks를 연속 AVComposition으로 작성 | 사용자 상태 저장 |
| `ThumbnailService` | 시간별 이미지 비동기 생성·캐시·취소 | 편집 상태 변경 |
| `EditHistory` | Split/Delete 전후 상태 Undo/Redo | 스크롤/줌 이력 |
| `ExportCoordinator` | 호환성 검사, 파일 생성, 진행/취소, 정리 | chunk 변경 |
| `AssetInspector` | 자산 속성과 지원 가능성 판정 | UI 표현 |

## 4. 도메인 모델

예시 Swift 모델:

```swift
struct SourceAsset: Equatable {
    let id: UUID
    let url: URL
    let duration: CMTime
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Float
    let minFrameDuration: CMTime?
    let hasAudio: Bool
    let isVariableFrameRate: Bool
}

struct ClipChunk: Identifiable, Equatable {
    let id: UUID
    let sourceAssetID: UUID
    let sourceRange: CMTimeRange
}

struct EditorState: Equatable {
    var source: SourceAsset
    var chunks: [ClipChunk]
    var selectedChunkID: ClipChunk.ID?
    var playheadTime: CMTime       // composition/edit time
    var pointsPerSecond: CGFloat
    var playback: PlaybackState
    var revision: UInt64
}

enum PlaybackState: Equatable {
    case paused
    case playing
    case scrubbing
    case rebuilding
    case exporting
}
```

예시는 도메인 형태를 보여준다. strict concurrency를 적용할 때 Core Media/Core Graphics 타입의 SDK별 `Sendable` 적합성을 확인하고, 검증 없이 `@unchecked Sendable`을 붙이지 않는다.

### 4.1 저장하는 값과 계산하는 값

저장:

- 각 chunk의 `sourceRange`
- chunk 순서
- 선택 ID
- 편집 playhead 시간
- 줌 배율
- 상태 revision

계산:

- chunk의 edit timeline start
- 전체 편집 길이
- playhead가 속한 chunk와 source time
- collection view item frame
- thumbnail 요청 시간
- AVComposition/AVPlayerItem

`timelineStart`를 chunk에 중복 저장하지 않는다. 앞 chunk duration의 prefix sum으로 계산해 ripple delete 후 불일치를 방지한다.

### 4.2 불변식

모든 편집 명령 후 다음을 assertion과 단위 테스트로 보장한다.

```text
chunks.count >= 1
각 sourceRange.duration > 0
각 sourceRange.start >= 0
CMTimeRangeGetEnd(sourceRange) <= source.duration
모든 chunk의 sourceAssetID == source.id
playheadTime ∈ [0, totalDuration]
selectedChunkID == nil 또는 chunks에 존재
totalDuration == Σ chunk.sourceRange.duration
```

Split만 수행한 상태에서는 source range가 원본 순서를 유지하고 겹치지 않는다. Delete는 일부 범위를 제거하지만 남은 순서는 유지한다.

### 4.3 입력 파일 소유권

`PHPickerViewController`/`NSItemProvider`가 전달하는 file representation URL은 callback 이후 수명이 보장되지 않을 수 있다. import coordinator는 접근 가능한 동안 다음 순서로 처리한다.

1. 세션 전용 임시 디렉터리를 만든다.
2. provider의 임시 파일을 유일한 이름으로 복사한다.
3. 복사본으로 `AVURLAsset`을 만들고 track/duration/composability를 검사한다.
4. 검사가 성공한 뒤에만 `SourceAsset.url`로 채택한다.
5. 선택 취소, 검사 실패, 편집 화면 종료 시 세션 복사본과 thumbnail cache를 정리한다.

원본 URL에 직접 쓰지 않는다. 대용량 복사 실패는 `insufficientDiskSpace` 또는 `assetUnavailable`로 분류하고 편집을 시작하지 않는다.

## 5. 시간 모델

### 5.1 세 종류의 시간

| 이름 | 설명 | 예시 |
|---|---|---|
| Source time | 원본 영상 안의 시간 | C가 원본 20~30초 |
| Edit time | 삭제 후 연속 타임라인 시간 | B 삭제 후 C가 10~20초 |
| Player time | 현재 AVComposition의 시간 | edit time과 1:1 |

UI와 player는 edit time을 사용한다. thumbnail과 source frame 접근 시 edit time을 source time으로 변환한다.

### 5.2 Edit time → Source time

```swift
struct ChunkPlacement {
    let chunk: ClipChunk
    let editRange: CMTimeRange
}
```

placements는 순서대로 누적한다.

```text
cursor = .zero
for chunk in chunks:
  placement.editRange = [cursor, cursor + chunk.sourceRange.duration)
  cursor += chunk.sourceRange.duration
```

edit time `t`가 placement 안에 있으면:

```text
sourceTime = chunk.sourceRange.start + (t - placement.editRange.start)
```

경계가 정확히 두 chunk 사이면 half-open 규칙에 따라 오른쪽 chunk를 선택한다. 전체 끝 시간만 마지막 chunk의 source end로 매핑한다.

### 5.3 CMTime 규칙

- 모델은 입력 자산의 합리적인 media timescale을 사용한다. 여러 track의 timescale이 다르면 계산용 timescale을 정하고 `CMTimeConvertScale`로 변환한다.
- `seconds` 변환은 레이아웃 경계에서만 사용한다.
- 비교는 `CMTimeCompare`, 더하기/빼기는 `CMTimeAdd`/`CMTimeSubtract`를 사용한다.
- invalid, indefinite, positive/negative infinity는 import 단계에서 거부한다.
- 표시 시간의 반올림과 편집 시간의 반올림을 분리한다.

### 5.4 프레임 경계 정렬

Split 후보 `t`를 해당 source time으로 변환한 후 가장 가까운 유효 presentation boundary로 정렬한다.

우선순위:

1. 자산에서 신뢰 가능한 `minFrameDuration`/일정한 frame cadence가 확인되면 그 grid 사용
2. VFR 또는 cadence가 불명확하면 주변 sample presentation timestamp를 읽어 가장 가까운 경계 사용. 현재는 Split 시점에 인접 구간을 읽으며, 반복 Split 성능이 필요하면 index/cache로 확장한다.
3. 임시 preview seek는 AVFoundation tolerance를 사용할 수 있으나 Split 확정은 sample 경계가 준비된 뒤 실행

동률이면 뒤쪽 프레임 경계를 선택한다. 정렬 후 왼쪽 또는 오른쪽이 한 프레임보다 짧으면 Split을 거부한다.

## 6. 타임라인 레이아웃

### 6.1 타임라인 구조

- 기본 구현은 가로 SwiftUI `ScrollView`와 lazy container를 사용한다.
- 실제 기기 측정에서 셀 재사용 또는 스크럽 성능이 목표를 충족하지 못할 때만 단일 section `UICollectionView` 구현으로 교체한다.
- chunk 하나가 하나의 item
- item width = `seconds(chunk.duration) × pointsPerSecond`
- 화면 수평 중앙의 별도 overlay가 playhead
- `contentInset.left/right = viewportWidth / 2`
- 선택 border는 cell decoration 또는 cell layer로 표시
- 썸네일은 item 안에서 일정한 화면 너비 간격으로 반복 배치

긴 영상에서 너무 작은 item이 터치 불가능해지지 않도록 표시 폭과 hit target을 분리한다. 시각 폭은 실제 duration 비율을 유지하고, 탭 판정은 인접 구간과 충돌하지 않는 범위에서 최소 hit 영역을 적용한다.

### 6.2 좌표 변환

viewport 좌표의 playhead는 `bounds.midX`다.

```swift
func contentX(for time: CMTime, scale: TimelineScale) -> CGFloat {
    scale.leadingInset + CGFloat(time.seconds) * scale.pointsPerSecond
}

func time(for contentOffsetX: CGFloat, scale: TimelineScale) -> CMTime {
    let x = contentOffsetX + scale.playheadX - scale.leadingInset
    let seconds = max(0, min(scale.totalSeconds, x / scale.pointsPerSecond))
    return CMTime(seconds: seconds, preferredTimescale: scale.timescale)
}
```

실제 구현은 `CMTime.seconds`에서 NaN/무한대를 검사한다. UI에서 계산한 시간을 모델 timescale로 즉시 변환한다.

### 6.3 줌 알고리즘

playhead 고정 줌:

```text
anchorTime = time(oldContentOffset, oldScale)
newPPS = clamp(pinchStartPPS × gesture.scale, minPPS, maxPPS)
newContentOffsetX = contentX(anchorTime, newScale) - playheadX
```

레이아웃 invalidate와 offset 적용을 같은 main-thread update 안에서 수행한다. floating-point 누적 오차를 피하기 위해 매 gesture update마다 직전 offset을 다시 확대하지 않고, pinch 시작점의 `anchorTime`과 `pinchStartPPS`에서 계산한다.

### 6.4 스크롤 소유권

feedback loop를 막기 위해 타임라인 이동 주체를 명시한다.

```swift
enum TimelineDriver {
    case userScroll
    case player
    case programmaticEdit
    case idle
}
```

- `userScroll`: scroll view가 시간의 source of truth, player는 seek만 수행
- `player`: player 시간이 source of truth, collection offset을 갱신
- `programmaticEdit`: store의 목표 시간이 source of truth
- driver가 바뀔 때 진행 중 seek와 animation을 정리한다.

## 7. 썸네일 파이프라인

### 7.1 요청

- 화면에 보이는 범위와 좌우 prefetch 범위만 요청한다.
- 요청 키: `(assetID, sourceTimeBucket, targetPixelSize, contentScale)`
- edit time을 source time으로 변환해 원본에서 이미지를 만든다.
- zoom에 따라 샘플 간격을 바꾸되 기존 저해상도 이미지를 placeholder로 재사용할 수 있다.

### 7.2 동시성과 취소

- `ThumbnailService`를 actor 또는 직렬 격리된 서비스로 구현한다.
- collection cell reuse 시 task를 취소한다.
- 각 요청은 `EditorState.revision`과 cell represented ID를 캡처한다.
- 완료 시 revision/ID가 다르면 결과를 버린다.
- 메모리 캐시는 cost-limited `NSCache`, 필요하면 세션 전용 디스크 임시 캐시를 사용한다.
- 메모리 경고 시 화면 밖 캐시를 제거한다.

### 7.3 실패 처리

개별 썸네일 실패는 편집 실패가 아니다. 어두운 placeholder와 시간 눈금을 표시하고 재생·Split·Delete는 유지한다.

## 8. 재생 설계

### 8.1 CompositionBuilder

입력: `SourceAsset`, `[ClipChunk]`

출력: immutable `AVComposition`, 선택적 `AVVideoComposition`, duration/placement 메타데이터

알고리즘:

1. 새 `AVMutableComposition` 생성
2. 비디오 composition track 생성
3. 오디오가 있으면 audio track 생성
4. 각 chunk의 source range를 cursor 위치에 순서대로 삽입
5. 비디오와 오디오에 동일한 source range와 cursor를 사용
6. cursor를 chunk duration만큼 증가
7. 방향/표시 크기 보정이 필요하면 video composition instruction 생성
8. immutable snapshot과 placements 반환

삽입 실패는 부분 composition을 사용하지 않고 전체 build 실패로 처리한다.

### 8.2 Player item 교체

Split/Delete/Undo/Redo 후:

1. 재생 정지
2. store revision 증가
3. background에서 새 composition build
4. revision이 최신인지 확인
5. main thread에서 `replaceCurrentItem`
6. player item ready 상태 확인
7. 목표 edit time으로 zero-tolerance seek
8. `readyPaused`로 전이

오래된 build가 늦게 끝나면 폐기한다.

### 8.3 시간 관찰

- 재생 UI는 `addPeriodicTimeObserver`로 약 30Hz 이하에서 갱신한다.
- callback에서 store 전체를 재구성하지 않고 playhead/time label에 필요한 경량 state만 갱신한다.
- observer token은 player 생명주기 동안 보관하고 해제 시 반드시 제거한다.
- 끝 도달은 item 종료 알림과 duration clamp 둘 다 처리한다.

### 8.4 Seek 병합

스크럽 중 모든 좌표 변화마다 별도 정확 seek를 쌓지 않는다.

```text
pendingTime = newest requested time
if seek not running: start seek(pendingTime, tolerant)
on completion:
  if newer pendingTime exists: seek newest
  else if gesture ended: exact seek(finalTime)
```

- 진행 중: 작은 tolerance로 반응성을 우선
- 종료: `toleranceBefore/After = .zero`를 우선하되 자산 특성상 정확 seek 비용이 큰 경우 측정 후 조정
- 비동기 completion은 request generation을 확인한다.

## 9. 편집 명령

### 9.1 명령 인터페이스

```swift
protocol EditCommand {
    func apply(to state: EditorState) throws -> EditorState
}

struct HistoryEntry {
    let kind: EditKind
    let before: EditSnapshot
    let after: EditSnapshot
}

struct EditSnapshot {
    let chunks: [ClipChunk]
    let selectedChunkID: UUID?
    let playheadTime: CMTime
}
```

MVP는 상태가 작으므로 inverse operation을 복잡하게 계산하는 대신 before/after snapshot을 저장한다. 원본 영상 데이터나 thumbnail은 snapshot에 넣지 않는다. 이 방식은 명령 100개 수준에서 메모리 부담이 작고 복원 결과가 결정적이다.

### 9.2 Split 알고리즘

입력: 현재 edit playhead

```text
1. placement = placement containing playhead
2. sourceCandidate = map(editTime → sourceTime)
3. sourceSplit = snapToFrameBoundary(sourceCandidate)
4. leftRange  = [chunk.sourceStart, sourceSplit)
5. rightRange = [sourceSplit, chunk.sourceEnd)
6. validate both durations >= one frame
7. replace target chunk with leftChunk, rightChunk
8. selected = rightChunk.id
9. playhead = original edit playhead adjusted to snapped boundary
10. validate invariants, append history, clear redo
```

새 chunk는 새 UUID를 사용한다. Undo snapshot이 원래 ID를 보존하므로 선택 복원이 가능하다.

### 9.3 Ripple Delete 알고리즘

```text
1. index = selected chunk index
2. require chunks.count > 1
3. deletionEditStart = sum(duration of chunks before index)
4. remove chunk[index]
5. selected = chunk now at index, else chunks.last
6. playhead = min(deletionEditStart, newTotalDuration)
7. validate invariants, append history, clear redo
```

다른 chunk의 source range는 변경하지 않는다. timeline placement는 prefix sum 재계산만으로 자동 ripple된다.

### 9.4 History 정책

- 기본 최대 100개 명령. 초과 시 가장 오래된 history entry를 제거한다.
- Undo: undo stack pop → `before` 복원 → entry를 redo stack에 push
- Redo: redo stack pop → `after` 복원 → entry를 undo stack에 push
- 새 Split/Delete: redo stack clear
- composition build 실패 시 명령 commit을 취소하고 이전 snapshot으로 rollback한다.

## 10. Store와 UI 상태 전이

모든 사용자 입력은 intent로 정규화한다.

```swift
enum EditorIntent {
    case selectChunk(UUID?)
    case beginScrubbing
    case scrub(to: CMTime)
    case endScrubbing(at: CMTime)
    case setZoom(CGFloat)
    case playPause
    case split
    case deleteSelection
    case undo
    case redo
    case export
}
```

`EditorStore`는 main actor에서 순서대로 intent를 처리한다. asset load, composition build, thumbnail, export 같은 무거운 작업은 별도 task에서 수행하고 결과만 main actor에 commit한다.

버튼 enabled 조건:

```text
canSplit = ready/playing && validInteriorFrameBoundary(playhead)
canDelete = selected != nil && chunks.count > 1 && notBusy
canUndo = undoStack not empty && notBusy
canRedo = redoStack not empty && notBusy
canExport = chunks not empty && totalDuration > 0 && readyPaused
```

playing에서 Split/Delete intent가 오면 pause 완료 후 같은 intent를 한 번만 이어서 실행한다.

## 11. Export 설계

### 11.1 MVP 파이프라인

1. 최신 `EditorState.revision`과 snapshot 고정
2. `CompositionBuilder`로 playback과 동일한 ranges/order의 composition 생성
3. composition의 재생·export 가능성과 compatible preset/file type 검사
4. 원본 transform, render size, frame duration 정책 적용
5. 세션별 임시 디렉터리에 유일한 출력 URL 생성
6. `AVAssetExportSession` 실행
7. 성공 후 출력 자산을 다시 열어 duration, video size, transform, frame rate, audio 존재를 검증
8. 사진 저장 또는 share sheet에 URL 전달
9. 실패·취소 시 부분 파일과 임시 파일 삭제

### 11.2 품질 정책

MVP 기본값:

- 우선 `AVAssetExportPresetHighestQuality`와 compatible output type 사용
- source/composition이 passthrough를 안전하게 지원하고 컷·방향·오디오 동기화 회귀 테스트를 통과한 조합에 한해 passthrough 고려
- 입력 display size와 aspect ratio 유지
- 일정 FPS 입력은 원본 frame duration을 목표로 설정
- VFR은 미리보기에 사용한 presentation timing을 보존하는 경로를 우선
- 임의의 1080p/30fps fallback 금지

`HighestQuality`라는 이름만으로 원본 비트레이트·코덱·FPS의 완전 보존을 보장한다고 간주하지 않는다. Export 후 자산 검사와 실제 재생 테스트가 완료 조건이다.

### 11.3 방향과 render size

- `naturalSize`만 사용하지 않고 video track의 `preferredTransform`을 적용한 표시 bounds를 계산한다.
- 음수 origin을 표준화한 transform으로 render canvas 안에 배치한다.
- 최종 render size는 양의 정수 pixel 크기이며 코덱 요구에 맞게 짝수 정렬이 필요하면 aspect ratio를 유지해 처리한다.
- preview와 export가 동일한 orientation 정책을 사용하도록 `CompositionBuildResult`에 display metadata를 포함한다.

### 11.4 진행, 취소, 파일 수명

- 진행률은 export API가 제공하는 상태를 UI가 과도하게 polling하지 않는 주기로 관찰한다.
- 취소 요청은 한 번만 전달하고 UI를 `cancelling` 상태로 둔다.
- 출력 URL은 성공 전까지 사용자 결과로 노출하지 않는다.
- 공유가 끝나거나 사진 저장이 완료될 때까지 파일 수명을 유지한다.
- 앱 시작 시 오래된 세션 임시 파일을 정리할 수 있으나 완료된 사용자 파일은 삭제하지 않는다.

### 11.5 향후 고급 경로

다음 요구가 들어오면 `AVAssetReader`/`AVAssetWriter` 기반 exporter를 별도 전략으로 추가한다.

- 정확한 코덱/프로파일/비트레이트/GOP 제어
- 해상도와 FPS 선택
- 파일 크기 사전 추정
- HDR/색 공간/메타데이터 보존
- 다중 pass, 열·배터리 정책
- 세밀한 진행률과 중단 복구

## 12. 오류 모델

```swift
enum EditorError: LocalizedError {
    case permissionDenied
    case assetUnavailable
    case noVideoTrack
    case unsupportedAsset
    case invalidDuration
    case notComposable
    case frameIndexUnavailable
    case splitAtBoundary
    case wouldCreateEmptyChunk
    case cannotDeleteOnlyChunk
    case compositionBuildFailed(underlying: Error)
    case exportConfigurationUnsupported
    case insufficientDiskSpace
    case exportFailed(underlying: Error)
    case exportCancelled
    case photoLibrarySaveFailed(underlying: Error)
}
```

오류는 사용자 메시지와 진단 로그를 분리한다. 로그에는 원본 파일명이나 경로를 남기지 않고 asset 특성 범주, 단계, underlying error code, revision을 기록한다.

복구 범주:

- 사용자 조치: 권한, 디스크 공간, iCloud 네트워크
- 다른 입력 필요: 손상/DRM/지원하지 않는 자산
- 현재 편집 재시도: composition build/export 일시 실패
- 조용히 무시: 취소된 오래된 thumbnail/seek 결과

## 13. 동시성·생명주기

- UI와 `EditorStore` mutation은 `@MainActor`에 제한한다.
- asset property load, frame index, composition 준비, thumbnail, export는 구조화된 concurrency task로 분리한다.
- 모든 장기 task에 session ID와 revision을 붙인다.
- 새 영상 선택, 화면 종료, 새 edit revision 발생 시 관련 task를 취소한다.
- AVFoundation 객체의 thread-safety를 추측하지 않고 각 서비스가 소유권을 갖는다.
- notification observer, time observer, KVO/observation token은 명시적으로 해제한다.
- 앱 background 진입 시 player를 pause한다. 진행 중 export는 MVP에서 취소하고 부분 파일을 정리하며 편집 snapshot은 유지한다.

## 14. 테스트 전략

### 14.1 단위 테스트

`TimeMappingTests`

- edit↔source 매핑의 시작, 내부, 경계, 끝
- 삭제 후 prefix sum
- 다양한 timescale 변환과 rounding
- 24/30/60fps와 VFR sample index snapping

`TimelineLayoutTests`

- 시간↔좌표 round trip
- 0과 전체 길이의 중앙 정렬
- min/default/max zoom
- 핀치 전후 anchor time 보존
- bounds/rotation 변경 후 offset 재계산

`EditCommandTests`

- 단일/연속 Split
- 첫/중간/마지막 chunk Delete
- only-chunk 삭제 거부
- Split/Delete 전후 source coverage
- Undo/Redo와 새 branch의 redo clear
- 100개 history limit
- 임의 명령 시퀀스 후 invariants property test

`CompositionBuilderTests`

- 비디오+오디오/무음 자산
- chunk 순서, cursor, 전체 duration
- 세로 transform과 render bounds
- 삽입 오류 시 atomic failure

### 14.2 통합 테스트

- fixture 영상으로 실제 AVComposition 생성 후 player item ready 확인
- Split/Delete 후 특정 edit time의 source frame identity 비교
- Export 결과 duration, track count, display size, transform, nominal FPS 검사
- 컷 경계 전후 오디오 샘플과 영상 프레임이 삭제 구간을 포함하지 않는지 확인
- Export 취소·실패 후 임시 파일 정리

### 14.3 UI 테스트

- 영상 선택 → 스크롤 → Split → 선택 → Delete → Undo → Redo → Export happy path
- 버튼 enabled 상태
- 중앙 playhead 고정
- 줌 후 기준 시간 유지
- 권한 거부와 오류 복구
- VoiceOver label 존재

시스템 picker는 UI 자동화가 불안정할 수 있으므로 테스트 전용 dependency로 fixture URL을 주입하고, 별도 수동 테스트에서 실제 picker를 확인한다.

### 14.4 실제 기기·실제 영상 검증

빌드 성공, simulator 재생, fixture export만으로 완료 처리하지 않는다.

- iPhone 13급 기준 기기에서 1080p30 10분
- 지원 범위 내 최신 기기에서 4K60 5분
- Photos에서 촬영한 세로/가로 H.264/HEVC
- VFR, 무음, 회전 metadata, iCloud 원본
- AirPods/전화 등 오디오 인터럽션
- background/foreground, 메모리 경고, 저용량 디스크

프레임 정확성은 눈으로만 판단하지 않고 알려진 색/타임코드 fixture와 메타데이터 검사로 확인한다.

## 15. 성능 설계

- timeline은 duration 비례 cell만 배치하고 bitmap 전체 strip을 한 번에 만들지 않는다.
- 썸네일 target size는 실제 cell pixel 크기를 넘지 않게 한다.
- 확대 수준별 thumbnail 요청을 debounce하고 prefetch window를 제한한다.
- player time update는 화면 refresh보다 자주 UI를 변경하지 않는다.
- composition rebuild는 main thread 밖에서 수행하고, UI는 lightweight snapshot만 적용한다.
- Instruments로 Time Profiler, Allocations, Leaks, Core Animation hitch를 측정한다.
- 4K frame을 원본 크기로 thumbnail cache에 넣지 않는다.
- Export 중 preview playback과 대량 thumbnail 생성을 중단해 I/O·열 경쟁을 줄인다.

## 16. 접근성·현지화 구현

- 문자열은 코드에 직접 넣지 않고 localization resource로 관리한다.
- 시간은 `DateComponentsFormatter`에 의존해 프레임 단위를 잃지 않도록 전용 formatter로 `HH:MM:SS`와 frame/subsecond를 구분한다.
- VoiceOver가 chunk를 읽을 때 `구간 2, 10초부터 15초, 5초 길이, 선택됨`처럼 편집 시간을 제공한다.
- playhead 조절은 accessibility adjustable action으로 앞/뒤 프레임 이동을 제공하는 방안을 검토한다.
- selected/disabled는 색 외에 border, alpha, trait/value로 표현한다.

## 17. 보안·개인정보

- 네트워크 업로드 없음.
- security-scoped 또는 picker 제공 URL의 접근 수명을 올바르게 관리한다.
- 임시 출력·thumbnail은 세션 전용 디렉터리에 두고 작업 완료/취소 후 정리한다.
- 로그와 crash metadata에 사용자 파일 경로, 파일명, 이미지 내용을 넣지 않는다.
- 사진 저장 권한은 실제 저장 시점에만 요청한다.

## 18. 구현 순서와 각 단계의 기술 게이트

### Gate 0. 모델과 fixture

- `CMTime` helper, domain model, invariants, sample assets
- 통과: 시간 매핑과 edit command 순수 단위 테스트

### Gate 1. Import/Playback

- asset inspector, picker, player layer
- 통과: 가로/세로/무음 자산 ready 및 방향 검증

### Gate 2. Timeline

- layout, inset, thumbnail service, selection
- 통과: 좌표 round trip과 시작/끝 중앙 정렬

### Gate 3. Sync/Zoom

- driver state, seek coalescing, periodic observer, pinch
- 통과: 1프레임 이내 최종 동기화와 anchor 보존

### Gate 4. Editing

- composition builder, Split/Delete, rebuild transaction
- 통과: source coverage, ripple, 실제 경계 재생

### Gate 5. History

- snapshot history, rollback, revision cancellation
- 통과: 긴 명령 시퀀스와 branch 테스트

### Gate 6. Export

- compatible preset/type, progress/cancel, output verification
- 통과: PRD AC-06 실제 기기 매트릭스

### Gate 7. Hardening

- cache, memory, background, 권한, 접근성
- 통과: Instruments와 오류 복구 체크리스트

## 19. 관찰 가능성

개발 빌드의 진단 정보:

- source 특성 범주: duration bucket, display size, FPS/VFR, codec, audio 유무
- state revision, chunk 수, total edit duration
- composition build/export 단계별 소요 시간
- seek requested/completed generation과 취소 수
- thumbnail cache hit/miss, 요청·취소 수
- export preset/file type, output 검사 결과

사용자 영상 내용과 식별 가능한 경로는 기록하지 않는다. 진단 overlay는 개발 빌드에만 둔다.

## 20. 주요 위험과 대응

| 위험 | 영향 | 대응 |
|---|---|---|
| edit/source/player 시간 혼용 | 잘못된 컷·seek | 타입/함수 이름 분리, 매핑 단위 테스트 |
| VFR을 nominal FPS로만 계산 | 프레임 오차 | sample timing index, 실제 출력 검증 |
| 회전 transform 누락 | 회전·잘린 Export | display bounds 계산, fixture 테스트 |
| scroll-player feedback loop | 떨림·점프 | `TimelineDriver` 단일 소유권 |
| 비동기 결과 역전 | 오래된 프레임·상태 | revision/generation 검사와 취소 |
| 매 편집마다 UI 정지 | 체감 품질 저하 | background build, atomic item swap |
| passthrough 오해 | 컷·코덱 결과 불일치 | 조합별 호환성 검사, post-export validation |
| 긴 영상 썸네일 메모리 | 종료·버벅임 | viewport 기반 요청, 크기 제한 캐시 |
| Export 중 앱 상태 변화 | 부분 파일·상태 손실 | snapshot 고정, 임시 URL, 정리 정책 |

## 21. 구현 시작 전 체크리스트

- [ ] 실제 deployment target 확정
- [ ] 세로 고정 또는 화면 회전 지원 확정
- [ ] 최대 입력 길이/용량 정책 확정
- [ ] H.264/HEVC, 24/30/60/VFR fixture 준비
- [ ] `pointsPerSecond` 기본/최소/최대 값을 디자인과 공유
- [ ] only-chunk 삭제 불가 정책 확인
- [ ] Split 후 오른쪽 선택, Delete 후 join 위치 이동 정책 확인
- [ ] Export fallback을 실패로 처리하는 MVP 정책 확인
- [ ] 실제 기기 성능 기준과 테스트 기기 확보

## 22. 참고 근거

- [Apple AVMutableComposition](https://developer.apple.com/documentation/avfoundation/avmutablecomposition): 원본 자산의 시간 범위를 새 composition track에 배치하는 편집 모델
- [Apple AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer): periodic/boundary time observation과 custom UI를 위한 player 기반
- [Apple AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession): preset, file type, output URL로 composition export

API를 구현할 때는 프로젝트의 Xcode/SDK 버전에 맞는 최신 Apple Developer Documentation의 availability와 비동기 API 형태를 확인한다.
