import SwiftUI
import AVFoundation

/// SwiftUI owns the editor chrome; the timeline coordinates touch, mouse, scroll, and pinch input.
struct EditorTimeline: View {
    let editor: EditorState
    let sourceURL: URL
    let position: Double
    let isEnabled: Bool
    let onScrubStart: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(timeLabel(position))
                    .typography(.body)
                    .monospacedDigit()
                    .accessibilityIdentifier("editor-playback-time")
                    .accessibilityValue(String(format: "%.4f", position))
                Spacer()
                Text(timeLabel(editor.totalDuration))
                    .typography(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("editor-total-duration")
                    .accessibilityValue(String(format: "%.4f", editor.totalDuration))
            }
            TimelineScrollSurface(configuration: self)
                .frame(height: 124)
                .background(MatchColor.ink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    Rectangle()
                        .fill(MatchColor.lime)
                        .frame(width: 2, height: 124)
                        .allowsHitTesting(false)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-timeline")
    }
}

private struct TimelineScrollSurface: UIViewControllerRepresentable {
    let configuration: EditorTimeline

    func makeUIViewController(context: Context) -> TimelineViewController {
        let controller = TimelineViewController()
        controller.loadViewIfNeeded()
        controller.viewport.update(configuration)
        return controller
    }

    func updateUIViewController(_ controller: TimelineViewController, context: Context) {
        controller.viewport.update(configuration)
    }

    static func dismantleUIViewController(_ controller: TimelineViewController, coordinator: ()) {
        controller.viewport.cancelInteraction()
        controller.viewport.stopLoadingThumbnails()
    }
}

private final class TimelineViewController: UIViewController {
    let viewport = TimelineViewport()

    override func loadView() {
        view = viewport
    }
}

private final class TimelineViewport: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private enum Interaction {
        case idle
        case scrolling
        case zooming
    }

    let scrollView = UIScrollView()
    let canvas = UIView()
    private let filmstrip = TimelineFilmstripView()
    private let ruler = TimelineRulerView()
    private let selection = TimelineSelectionView()
    private let durationLabel = UILabel()
    private var configuration: EditorTimeline?
    private var provider: TimelineThumbnailProvider?
    private var sourceURL: URL?
    private var interaction = Interaction.idle
    private var scale = EditorTimelineZoom.initialScale
    private var pinchStartScale = EditorTimelineZoom.initialScale
    private var pinchTime = 0.0
    private var revision: UInt64?
    private var previousWidth = 0.0
    private var settingOffset = false
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.allowedScrollTypesMask = .all
        scrollView.accessibilityIdentifier = "editor-timeline-scroll"
        scrollView.accessibilityLabel = "Video timeline"
        addSubview(scrollView)
        scrollView.addSubview(canvas)
        canvas.addSubview(filmstrip)
        selection.isUserInteractionEnabled = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        durationLabel.textAlignment = .center
        durationLabel.isUserInteractionEnabled = false
        pinch.delegate = self
        addGestureRecognizer(pinch)
        tap.delegate = self
        tap.require(toFail: pinch)
        scrollView.addGestureRecognizer(tap)
        ruler.isUserInteractionEnabled = false
        addSubview(ruler)
        installOverlays()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func installOverlays() {
        canvas.addSubview(selection)
        canvas.addSubview(durationLabel)
    }

    func update(_ configuration: EditorTimeline) {
        let changedRevision = revision != configuration.editor.revision
        self.configuration = configuration
        if sourceURL != configuration.sourceURL {
            provider?.stop()
            filmstrip.reset()
            sourceURL = configuration.sourceURL
            provider = TimelineThumbnailProvider(source: configuration.sourceURL)
            provider?.onChange = { [weak self] in
                self?.render()
            }
        }
        if changedRevision {
            cancelInteraction()
            revision = configuration.editor.revision
        }
        scrollView.isScrollEnabled =
            configuration.isEnabled && interaction != .zooming
        pinch.isEnabled = configuration.isEnabled
        layoutContent()
        if interaction == .idle {
            setOffset(configuration.position * scale)
        }
        render()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let changedWidth = previousWidth != bounds.width
        previousWidth = bounds.width
        scrollView.frame = bounds
        ruler.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
        layoutContent()
        if changedWidth, interaction == .idle, let configuration {
            setOffset(configuration.position * scale)
        }
        render()
    }

    private func layoutContent() {
        let width = bounds.width + (configuration?.editor.totalDuration ?? 0) * scale
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: 124)
        scrollView.contentSize = canvas.bounds.size
        scrollView.accessibilityValue = String(format: "%.4f", scale)
    }

    private func setOffset(_ offset: Double) {
        settingOffset = true
        scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        settingOffset = false
    }

    private func timeAtPlayhead() -> Double {
        EditorTimelineLayout.editTime(
            forContentOffset: scrollView.contentOffset.x, pointsPerSecond: scale,
            duration: configuration?.editor.totalDuration ?? 0)
    }

    private func render() {
        guard let configuration, bounds.width > 0 else {
            return
        }
        let lower = max(0, (scrollView.contentOffset.x - bounds.width / 2) / scale)
        let upper = min(
            configuration.editor.totalDuration, (scrollView.contentOffset.x + bounds.width / 2) / scale)
        let tiles = EditorTimelineLayout.tiles(
            for: configuration.editor, pointsPerSecond: scale,
            tileDuration: EditorTimelineZoom.thumbnailDuration(scale: scale),
            visibleRange: min(lower, upper)...max(lower, upper))
        // The scroll canvas carries coordinates only. Decoded images and their backing layers
        // occupy the viewport, even for hours of footage at the highest zoom.
        filmstrip.frame = CGRect(x: scrollView.contentOffset.x, y: 24, width: bounds.width, height: 76)
        filmstrip.update(
            tiles: tiles, clips: configuration.editor.includedClips, provider: provider,
            inset: bounds.width / 2 - scrollView.contentOffset.x, scale: scale)
        provider?.request(tiles.map(\.sourceTime), suspended: interaction == .zooming)
        ruler.configure(
            scale: scale, offset: scrollView.contentOffset.x, duration: configuration.editor.totalDuration)
        renderSelection()
    }

    func stopLoadingThumbnails() {
        provider?.stop()
    }

    private func renderSelection() {
        guard let configuration,
            let clip = configuration.editor.includedClips.first(where: {
                $0.id == configuration.editor.selectedClipID
            }),
            let editStart = try? configuration.editor.editTime(atSourceTime: clip.sourceStart, in: clip.id)
        else {
            for view in [selection, durationLabel] {
                view.isHidden = true
            }
            return
        }
        let start = clip.sourceStart
        let end = clip.sourceEnd
        let x = bounds.width / 2 + (editStart + start - clip.sourceStart) * scale
        let width = (end - start) * scale
        selection.frame = CGRect(x: scrollView.contentOffset.x, y: 24, width: bounds.width, height: 76)
        selection.configure(start: x - scrollView.contentOffset.x, width: max(1, width))
        selection.isHidden = false
        durationLabel.text = timeLabel(end - start)
        let labelWidth = min(max(40, durationLabel.intrinsicContentSize.width + 8), max(40, width))
        durationLabel.frame = CGRect(
            x: max(x, x + width - labelWidth - 3), y: 78, width: labelWidth, height: 18)
        durationLabel.isHidden = width < 40
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard configuration?.isEnabled == true, interaction == .idle else {
            return
        }
        interaction = .scrolling
        configuration?.onScrubStart()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !settingOffset else {
            return
        }
        render()
        if interaction == .scrolling {
            configuration?.onScrub(timeAtPlayhead())
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            finishScroll()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScroll()
    }

    private func finishScroll() {
        guard interaction == .scrolling else {
            return
        }
        let time = timeAtPlayhead()
        setOffset(time * scale)
        render()
        interaction = .idle
        configuration?.onScrubEnd(time)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard configuration?.isEnabled == true, interaction == .idle, let configuration else {
            return
        }
        let time = (recognizer.location(in: canvas).x - bounds.width / 2) / scale
        guard time >= 0, time < configuration.editor.totalDuration,
            let clip = try? configuration.editor.includedClip(atEditTime: time)
        else {
            return
        }
        configuration.onSelect(clip.id)
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard let configuration else {
            return
        }
        switch recognizer.state {
        case .began:
            pinchTime = timeAtPlayhead()
            pinchStartScale = scale
            interaction = .zooming
            provider?.request([], suspended: true)
            setOffset(scrollView.contentOffset.x)
            scrollView.isScrollEnabled = false
            configuration.onScrubStart()
        case .changed:
            guard interaction == .zooming else {
                return
            }
            scale = EditorTimelineZoom.scale(startingAt: pinchStartScale, magnification: recognizer.scale)
            layoutContent()
            setOffset(
                EditorTimelineZoom.contentOffset(
                    editTime: pinchTime, scale: scale, duration: configuration.editor.totalDuration))
            render()
        case .ended, .cancelled, .failed:
            guard interaction == .zooming else {
                return
            }
            interaction = .idle
            scrollView.isScrollEnabled = configuration.isEnabled
            render()
            configuration.onScrubEnd(pinchTime)
        default:
            break
        }
    }

    func cancelInteraction() {
        interaction = .idle
        scrollView.isScrollEnabled = configuration?.isEnabled == true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        configuration?.isEnabled == true
            && (gestureRecognizer === pinch || interaction != .zooming)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === pinch && otherGestureRecognizer === scrollView.panGestureRecognizer)
            || (otherGestureRecognizer === pinch && gestureRecognizer === scrollView.panGestureRecognizer)
    }

}

private final class TimelineSelectionView: UIView {
    private var clipRect = CGRect.zero

    func configure(start: Double, width: Double) {
        isOpaque = false
        backgroundColor = .clear
        clipRect = CGRect(x: start, y: 1, width: width, height: 74)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        UIColor.white.setStroke()
        let outline = UIBezierPath(roundedRect: clipRect, cornerRadius: 3)
        outline.lineWidth = 2
        outline.stroke()
    }
}

private final class TimelineRulerView: UIView {
    private var scale = 30.0
    private var offset = 0.0
    private var duration = 0.0

    func configure(scale: Double, offset: Double, duration: Double) {
        self.scale = scale
        self.offset = offset
        self.duration = duration
        isOpaque = false
        backgroundColor = .clear
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let major = EditorTimelineZoom.rulerInterval(scale: scale)
        let minor = major / 5
        let first = max(0, Int(floor((offset - bounds.width / 2) / scale / minor)))
        let last = min(Int(ceil(duration / minor)), Int(ceil((offset + bounds.width / 2) / scale / minor)))
        guard first <= last else {
            return
        }
        for tick in first...last {
            let time = Double(tick) * minor
            let x = bounds.width / 2 + time * scale - offset
            let isMajor = tick.isMultiple(of: 5)
            context.setStrokeColor(UIColor.secondaryLabel.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: x, y: isMajor ? 17 : 20))
            context.addLine(to: CGPoint(x: x, y: 24))
            context.strokePath()
            if isMajor {
                let text = major < 1 ? String(format: "%.1fs", time) : timeLabel(time)
                (text as NSString).draw(
                    at: CGPoint(x: x + 3, y: 2),
                    withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                        .foregroundColor: UIColor.secondaryLabel,
                    ])
            }
        }
    }
}
