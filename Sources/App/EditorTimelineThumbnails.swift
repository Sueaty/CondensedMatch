import UIKit
import AVFoundation

/// Reuses a small set of image views in viewport coordinates. Zoom never clears decoded frames.
@MainActor
final class TimelineFilmstripView: UIView {
    private var cells: [String: UIImageView] = [:]
    private var boundaries: [UUID: UIView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reset() {
        for view in subviews {
            view.removeFromSuperview()
        }
        cells.removeAll()
        boundaries.removeAll()
    }

    func update(
        tiles: [EditorTimelineTile], clips: [EditorClip], provider: TimelineThumbnailProvider?,
        inset: Double, scale: Double
    ) {
        let identifiers = Set(tiles.map(\.id))
        for identifier in Array(cells.keys) where !identifiers.contains(identifier) {
            cells.removeValue(forKey: identifier)?.removeFromSuperview()
        }
        let ranges = Dictionary(
            uniqueKeysWithValues: clips.map {
                ($0.id, $0.sourceStart...$0.sourceEnd)
            })
        for tile in tiles {
            let cell: UIImageView
            if let existing = cells[tile.id] {
                cell = existing
            } else {
                cell = UIImageView()
                cell.contentMode = .scaleToFill
                cell.clipsToBounds = true
                cell.backgroundColor = .secondarySystemFill
                cells[tile.id] = cell
                addSubview(cell)
            }
            // Round shared edges together to avoid subpixel gaps between adjacent tiles.
            let displayScale = traitCollection.displayScale
            let left = (inset + tile.editStart * scale) * displayScale
            let right = (inset + (tile.editStart + tile.duration) * scale) * displayScale
            cell.frame = CGRect(
                x: left.rounded() / displayScale, y: 0,
                width: (right.rounded() - left.rounded()) / displayScale, height: bounds.height)
            if let range = ranges[tile.clipID], let image = provider?.image(at: tile.sourceTime, in: range) {
                cell.image = image
            }
        }
        // Cuts belong to the edit, independently of which clip currently owns the trim outline.
        // Keep the old cut visible when Split selects the newly created right-hand clip.
        let visibleBoundaries = tiles.filter {
            $0.tileNumber == 0
        }
        let boundaryIDs = Set(visibleBoundaries.map(\.clipID))
        for identifier in Array(boundaries.keys) where !boundaryIDs.contains(identifier) {
            boundaries.removeValue(forKey: identifier)?.removeFromSuperview()
        }
        for tile in visibleBoundaries {
            let boundary: UIView
            if let existing = boundaries[tile.clipID] {
                boundary = existing
            } else {
                boundary = UIView()
                boundary.backgroundColor = .white
                boundary.isUserInteractionEnabled = false
                boundary.isAccessibilityElement = true
                boundary.accessibilityLabel = "Clip boundary"
                boundary.accessibilityIdentifier = "editor-clip-boundary-\(tile.clipID)"
                boundaries[tile.clipID] = boundary
                addSubview(boundary)
            }
            let displayScale = traitCollection.displayScale
            let x = (inset + tile.editStart * scale) * displayScale
            boundary.frame = CGRect(
                x: x.rounded() / displayScale, y: 0, width: 1, height: bounds.height)
            boundary.accessibilityValue = String(format: "%.4f", tile.editStart)
            bringSubviewToFront(boundary)
        }
    }
}

/// One decoder, one in-flight request, bounded decoded memory, and a replaceable visible demand list.
/// Finishing an obsolete request can populate the cache, but never schedules obsolete queued work.
@MainActor
final class TimelineThumbnailProvider {
    var onChange: (() -> Void)?
    private let generator: AVAssetImageGenerator
    private var cache: [Int: UIImage] = [:]
    private var recency: [Int] = []
    private var failed: Set<Int> = []
    private var demand: [Int] = []
    private var completedDemand: Set<Int> = []
    private var suspended = false
    private var stopped = false
    private var worker: Task<Void, Never>?
    private(set) var generationCount = 0

    init(source: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 140)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    }

    func image(at time: Double, in range: ClosedRange<Double>) -> UIImage? {
        let key = Self.key(time)
        if let exact = cache[key] {
            touch(key)
            return exact
        }
        // While pinching, stretch an already decoded frame from the same clip until resampling
        // resumes. A cache miss must not replace visible footage with the editor's green color.
        let nearest = cache.keys.filter {
            range.contains(Double($0) / 10)
        }
        .min {
            abs($0 - key) < abs($1 - key)
        }
        guard let nearest else {
            return nil
        }
        touch(nearest)
        return cache[nearest]
    }

    func cachedImage(at time: Double) -> UIImage? {
        cache[Self.key(time)]
    }

    func request(_ times: [Double], suspended: Bool = false) {
        guard !stopped else {
            return
        }
        var seen: Set<Int> = []
        let latest = times.filter(\.isFinite).map(Self.key).filter {
            seen.insert($0).inserted
        }
        if latest != demand {
            demand = latest
            completedDemand.removeAll()
        }
        self.suspended = suspended
        guard worker == nil, !suspended, nextRequest != nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.loadVisibleFrames()
        }
    }

    private var nextRequest: Int? {
        guard !suspended, !stopped else {
            return nil
        }
        return demand.first {
            cache[$0] == nil && !failed.contains($0) && !completedDemand.contains($0)
        }
    }

    private func loadVisibleFrames() async {
        defer {
            worker = nil
        }
        while !Task.isCancelled, let key = nextRequest {
            generationCount += 1
            do {
                let (frame, _) = try await generator.image(
                    at: CMTime(value: Int64(key), timescale: 10))
                guard !Task.isCancelled, !stopped else {
                    return
                }
                cache[key] = UIImage(cgImage: frame)
                touch(key)
            } catch {
                guard !Task.isCancelled, !stopped else {
                    return
                }
                failed.insert(key)
                touch(key)
            }
            completedDemand.insert(key)
            // At most 96 decoded 240x140 images (about 13 MB), including failed entries.
            while recency.count > 96 {
                let oldest = recency.removeFirst()
                cache.removeValue(forKey: oldest)
                failed.remove(oldest)
            }
            onChange?()
        }
    }

    func stop() {
        stopped = true
        onChange = nil
        demand.removeAll()
        completedDemand.removeAll()
        worker?.cancel()
        generator.cancelAllCGImageGeneration()
        cache.removeAll()
        recency.removeAll()
        failed.removeAll()
    }

    private func touch(_ key: Int) {
        recency.removeAll {
            $0 == key
        }
        recency.append(key)
    }

    private static func key(_ time: Double) -> Int {
        Int((max(0, time) * 10).rounded(.down))
    }
}
