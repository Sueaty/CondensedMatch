import SwiftUI
import AVFoundation

/// Included clips form one gap-free edit timeline. The centered playhead is an overlay.
struct EditorTimeline: View {
    let editor: EditorState
    let sourceURL: URL
    let position: Double
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onSelect: (UUID) -> Void

    @State private var viewportWidth = 0.0
    @State private var currentOffset = 0.0
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var isUserScrolling = false
    @State private var provider: TimelineThumbnailProvider?
    @State private var tiles: [EditorTimelineTile] = []
    private let pointsPerSecond = 30.0
    private let tileSeconds = 4.0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(timeLabel(position))
                    .typography(.body)
                    .monospacedDigit()
                    .accessibilityIdentifier("editor-playback-time")
                Spacer()
                Text(timeLabel(editor.totalDuration))
                    .typography(.caption)
                    .monospacedDigit()
                    .foregroundStyle(
                        .secondary)
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    Color.clear
                        .frame(width: viewportWidth / 2, height: 76)
                    ForEach(tiles) { info in

                        TimelineTile(
                            info: info,
                            selected: editor.selectedClipID == info.clipID,
                            provider: provider,
                            onSelect: {
                                onSelect(info.clipID)
                            }
                        )
                    }
                    Color.clear
                        .frame(width: viewportWidth / 2, height: 76)
                }
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: Double.self) { geometry in

                geometry.contentOffset.x
            } action: { _, offset in

                currentOffset = offset
                guard isUserScrolling else {
                    return
                }
                onScrub(time(for: offset))
            }
            .onScrollPhaseChange { _, phase in

                switch phase {
                case .interacting, .decelerating:
                    isUserScrolling = true
                case .idle:
                    if isUserScrolling {
                        isUserScrolling = false
                        onScrubEnd(time(for: currentOffset))
                    }
                default: break
                }
            }
            .overlay {
                Rectangle().fill(MatchColor.lime)
                    .frame(width: 3, height: 90)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .allowsHitTesting(false)
            }
            .background {
                GeometryReader { proxy in

                    Color.clear
                        .onAppear {
                            viewportWidth = proxy.size.width
                        }
                        .onChange(of: proxy.size.width) { _, width in
                            viewportWidth = width
                        }
                }
            }
            .frame(height: 90)
            .background(MatchColor.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear {
            provider = TimelineThumbnailProvider(source: sourceURL)
            tiles = makeTiles()
            scrollPosition.scrollTo(x: position * pointsPerSecond)
        }
        .onChange(of: position) { _, newValue in

            guard !isUserScrolling else {
                return
            }
            scrollPosition.scrollTo(x: newValue * pointsPerSecond)
        }
        .onChange(of: editor.revision) { _, _ in

            tiles = makeTiles()
            scrollPosition.scrollTo(x: editor.playheadTime * pointsPerSecond)
        }
        .accessibilityIdentifier("editor-timeline")
    }

    private func time(for offset: Double) -> Double {
        EditorTimelineLayout.editTime(
            forContentOffset: offset, pointsPerSecond: pointsPerSecond, duration: editor.totalDuration)
    }

    private func makeTiles() -> [EditorTimelineTile] {
        EditorTimelineLayout.tiles(for: editor, pointsPerSecond: pointsPerSecond, tileDuration: tileSeconds)
    }
}

private struct TimelineTile: View {
    let info: EditorTimelineTile
    let selected: Bool
    let provider: TimelineThumbnailProvider?
    let onSelect: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                MatchColor.ink
                    .opacity(info.clipNumber.isMultiple(of: 2) ? 0.85 : 1)
            }
            if info.tileNumber == 0 && info.width >= 100 {
                Text(timeLabel(info.clipDuration))
                    .typography(.caption)
                    .monospacedDigit()
                    .bold()
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        .frame(width: info.width, height: 76)
        .clipped()
        .overlay(alignment: .leading) {
            if info.tileNumber == 0 {
                Rectangle().fill(selected ? MatchColor.lime : .white)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .trailing) {
            if info.isLastInClip {
                Rectangle().fill(selected ? MatchColor.lime : .white)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .top) {
            if selected {
                Rectangle().fill(MatchColor.lime)
                    .frame(height: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if selected {
                Rectangle().fill(MatchColor.lime)
                    .frame(height: 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .task(id: info.sourceTime) {
            image = await provider?.image(at: info.sourceTime)
        }
    }
}

@MainActor
final class TimelineThumbnailProvider {
    private let asset: AVURLAsset
    private let cache = NSCache<NSNumber, UIImage>()

    init(source: URL) {
        asset = AVURLAsset(url: source)
    }

    func image(at time: Double) async -> UIImage? {
        let key = NSNumber(value: Int((time * 10).rounded()))
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 140)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard
            let (cgImage, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)),
            !Task.isCancelled
        else {
            return nil
        }
        let result = UIImage(cgImage: cgImage)
        cache.setObject(result, forKey: key)
        return result
    }
}
