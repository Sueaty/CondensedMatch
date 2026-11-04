import AVFoundation
import RallyKit
import SwiftUI

/// How a rally search ended, reported back to the editor.
enum RallyFindingCompletion {
    case found([FoundRally])
    case rejected(RallyRejection)
    case failed(String)
    case stopped
}

/// Runs one rally search and holds what the 2B screen shows while it runs.
@MainActor
@Observable
final class RallyFindingSession: Identifiable {
    enum Step: Int, CaseIterable {
        case checkingVideo
        case scanning
        case placingRallies

        var title: String {
            switch self {
            case .checkingVideo:
                return "Checked the video"
            case .scanning:
                return "Scanning the match"
            case .placingRallies:
                return "Putting rallies on your timeline"
            }
        }
    }

    private(set) var step: Step
    private(set) var fraction = 0.0
    private(set) var secondsLeft: Double?
    private(set) var rallies: [FoundRally] = []
    private(set) var thumbnails: [FoundRally.ID: UIImage] = [:]

    private let source: URL
    private let check: RallyVideoCheck?
    private let finder: RallyFinderFunction
    private var task: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    init(source: URL, check: RallyVideoCheck?, finder: @escaping RallyFinderFunction) {
        self.source = source
        self.check = check
        self.finder = finder
        step = check == nil ? .checkingVideo : .scanning
    }

    func start(completion: @escaping @MainActor (RallyFindingCompletion) -> Void) {
        guard task == nil else {
            return
        }
        let source = source
        let check = check
        let finder = finder
        let work = Task.detached(priority: .userInitiated) {
            try await finder(source, check) { update in
                Task { @MainActor [weak self] in
                    self?.apply(update)
                }
            }
        }
        task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.result
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else {
                return
            }
            switch result {
            case .success(.found(let rallies)):
                self.rallies = rallies
                self.fraction = 1
                self.step = .placingRallies
                completion(.found(rallies))
            case .success(.rejected(let rejection)):
                completion(.rejected(rejection))
            case .failure(let error):
                if !(error is CancellationError) {
                    completion(.failed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        thumbnailTask?.cancel()
    }

    /// The last three rallies, oldest first, each with its number in the whole list.
    var latestRallies: [(number: Int, rally: FoundRally)] {
        let numbered = rallies.enumerated().map { index, rally in
            (number: index + 1, rally: rally)
        }
        return Array(numbered.suffix(3))
    }

    private func apply(_ update: RallyFindingProgress) {
        guard task?.isCancelled != true, step != .placingRallies else {
            return
        }
        switch update {
        case .checkingVideo:
            step = .checkingVideo
        case .scanning(let fraction, _, let secondsLeft, let ralliesSoFar):
            step = .scanning
            self.fraction = fraction
            self.secondsLeft = secondsLeft
            rallies = ralliesSoFar
            loadThumbnails()
        }
    }

    private func loadThumbnails() {
        let missing = latestRallies
            .map(\.rally)
            .filter {
                thumbnails[$0.id] == nil
            }
        guard !missing.isEmpty, thumbnailTask == nil else {
            return
        }
        let source = source
        thumbnailTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            for rally in missing {
                guard !Task.isCancelled else {
                    break
                }
                let time = CMTime(seconds: rally.start, preferredTimescale: 600)
                if let image = try? await generator.image(at: time).image {
                    self?.thumbnails[rally.id] = UIImage(cgImage: image)
                }
            }
            self?.thumbnailTask = nil
            if !Task.isCancelled {
                self?.loadThumbnails()
            }
        }
    }
}

/// 2B: the full-screen progress shown while rallies are found.
struct RallyFindingView: View {
    @State var session: RallyFindingSession
    let completion: @MainActor (RallyFindingCompletion) -> Void
    @State private var showStopConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Eyebrow(title: "On your iPhone · Nothing uploaded")

                    Text("Watching the match\nso you don't have to.")
                        .typography(.title2)
                        .fixedSize(horizontal: false, vertical: true)

                    summary

                    steps

                    if !session.latestRallies.isEmpty {
                        latestFound
                    }

                    Text("Keep RallyCut open while we look.")
                        .typography(.caption)
                        .foregroundStyle(MatchColor.muted)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .background(MatchColor.paper)
            .foregroundStyle(MatchColor.ink)
            .navigationTitle("Finding rallies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showStopConfirmation = true
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("rally-finding-cancel")
                }
            }
            .alert("Stop finding rallies?", isPresented: $showStopConfirmation) {
                Button("Keep Finding", role: .cancel) {
                }

                Button("Stop", role: .destructive) {
                    session.stop()
                    completion(.stopped)
                }
            } message: {
                Text("Rallies found so far won't be saved.")
            }
        }
        .accessibilityIdentifier("rally-finding")
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(completion: completion)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(session.rallies.count)")
                    .font(.system(size: 48, weight: .regular, design: .serif))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("rally-finding-count")

                Text(session.rallies.count == 1 ? "rally found so far" : "rallies found so far")
                    .typography(.body)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))

                    Capsule()
                        .fill(MatchColor.lime)
                        .frame(width: proxy.size.width * session.fraction)
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.3), value: session.fraction)
            .accessibilityHidden(true)

            Text(progressCaption)
                .typography(.caption)
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.65))
                .accessibilityIdentifier("rally-finding-progress")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MatchColor.ink, in: RoundedRectangle(cornerRadius: 24))
    }

    private var progressCaption: String {
        switch session.step {
        case .checkingVideo:
            return "Checking the video…"
        case .placingRallies:
            return "100% scanned"
        case .scanning:
            let percent = "\(Int((session.fraction * 100).rounded(.down)))% scanned"
            guard let secondsLeft = session.secondsLeft else {
                return percent + " · estimating time left"
            }
            let minutes = Int((secondsLeft / 60).rounded(.up))
            return percent + (minutes <= 1 ? " · about 1 min left" : " · about \(minutes) min left")
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RallyFindingSession.Step.allCases, id: \.self) { step in
                stepRow(step)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
    }

    private func stepRow(_ step: RallyFindingSession.Step) -> some View {
        let current = session.step.rawValue
        let isDone = step.rawValue < current
        let isActive = step.rawValue == current
        return HStack(spacing: 12) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(MatchColor.done)
                } else if isActive {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(MatchColor.muted.opacity(0.5))
                }
            }
            .font(.system(size: 18))
            .frame(width: 20, height: 20)

            Text(step.title)
                .typography(.body)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isDone || isActive ? MatchColor.ink : MatchColor.muted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : isActive ? "In progress" : "Not started")
    }

    private var latestFound: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Just found")
                .typography(.caption)
                .fontWeight(.semibold)
                .tracking(1)
                .foregroundStyle(MatchColor.muted)

            HStack(spacing: 8) {
                ForEach(session.latestRallies, id: \.rally.id) { item in
                    RallyThumbnail(
                        number: item.number,
                        rally: item.rally,
                        image: session.thumbnails[item.rally.id]
                    )
                }

                ForEach(0..<max(0, 3 - session.latestRallies.count), id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                }
            }
        }
    }
}

private struct RallyThumbnail: View {
    let number: Int
    let rally: FoundRally
    let image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(MatchColor.ink.opacity(0.15))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .topLeading) {
                badge("#\(number)", foreground: MatchColor.ink, background: MatchColor.lime)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                badge(duration, foreground: .white, background: .black.opacity(0.7))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rally \(number), \(duration)")
    }

    private var duration: String {
        let seconds = Int(rally.duration.rounded())
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    private func badge(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }
}
