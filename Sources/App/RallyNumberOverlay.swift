import AVFoundation
import CoreImage
import UIKit

/// Burns the small "Rally 7" tag into the corner of an exported video (5B).
///
/// Draws with Core Image rather than `AVVideoCompositionCoreAnimationTool`, which crashes in the simulator.
@MainActor
enum RallyNumberOverlay {
    static func videoComposition(
        for composition: AVComposition,
        labels: [RallyExportPlan.Label]
    ) async throws -> AVMutableVideoComposition {
        let size = try await renderSize(of: composition)
        let tags = TagImages(labels: labels, shortSide: min(size.width, size.height))
        return try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let frame = request.sourceImage
            let time = request.compositionTime.seconds
            guard let tag = tags.image(at: time) else {
                request.finish(with: frame, context: nil)
                return
            }
            // Core Image puts the origin at the bottom left; the tag sits top left.
            let extent = frame.extent
            let placed = tag.transformed(
                by: CGAffineTransform(
                    translationX: extent.minX + tags.margin,
                    y: extent.maxY - tags.margin - tag.extent.height
                )
            )
            request.finish(with: placed.composited(over: frame), context: nil)
        }
    }

    private static func renderSize(of composition: AVComposition) async throws -> CGSize {
        guard let track = try await composition.loadTracks(withMediaType: .video).first else {
            return CGSize(width: 1920, height: 1080)
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}

/// One pre-drawn tag per rally, looked up by composition time while frames render.
private final class TagImages: @unchecked Sendable {
    let margin: CGFloat
    private let labels: [RallyExportPlan.Label]
    private let images: [Int: CIImage]

    @MainActor
    init(labels: [RallyExportPlan.Label], shortSide: CGFloat) {
        let fontSize = max(14, shortSide * 0.04)
        margin = shortSide * 0.04
        self.labels = labels.filter {
            $0.end > $0.start
        }
        var images: [Int: CIImage] = [:]
        for label in self.labels where images[label.number] == nil {
            images[label.number] = Self.draw("Rally \(label.number)", fontSize: fontSize)
        }
        self.images = images
    }

    func image(at time: Double) -> CIImage? {
        guard let label = labels.first(where: { time >= $0.start && time < $0.end }) else {
            return nil
        }
        return images[label.number]
    }

    @MainActor
    private static func draw(_ title: String, fontSize: CGFloat) -> CIImage? {
        let text = NSAttributedString(
            string: title,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
        )
        let textSize = text.size()
        let horizontal = fontSize * 0.6
        let vertical = fontSize * 0.3
        let size = CGSize(
            width: ceil(textSize.width + horizontal * 2),
            height: ceil(textSize.height + vertical * 2)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height * 0.3).fill()
            text.draw(at: CGPoint(x: horizontal, y: vertical))
        }
        return CIImage(image: image)
    }
}
