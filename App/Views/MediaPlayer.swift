import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Playback state for one video or track from the Studio.
@MainActor
@Observable
final class MediaPlayback {
    let player: AVPlayer
    private(set) var isPlaying = false
    var current: Double = 0
    private(set) var duration: Double = 0
    /// Width / height of the video picture, when it is known.
    private(set) var aspectRatio: CGFloat?
    private var scrubbing = false

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                if time.seconds.isFinite { self.current = time.seconds }
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            if let length = try? await asset.load(.duration), length.seconds.isFinite {
                self?.duration = length.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let loaded = try? await track.load(.naturalSize, .preferredTransform) {
                let shown = loaded.0.applying(loaded.1)
                if abs(shown.height) > 0 { self?.aspectRatio = abs(shown.width) / abs(shown.height) }
            }
        }
    }

    /// Picks up changes made by the full-screen player.
    func syncState() {
        isPlaying = player.timeControlStatus != .paused
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Starting again after the end begins from the start.
        if duration > 0, current >= duration - 0.15 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func skip(_ seconds: Double) {
        seek(to: min(max(current + seconds, 0), duration))
    }

    /// Called while the slider is dragged and once more when it is released.
    func scrub(editing: Bool) {
        scrubbing = editing
        seek(to: current, precise: !editing)
    }

    func seek(to seconds: Double, precise: Bool = true) {
        current = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    /// Keeps the picture in step with the slider while it is being dragged.
    func scrubMoved() {
        guard scrubbing else { return }
        seek(to: current, precise: false)
    }
}

// MARK: - Controls

/// Play and pause, a seek bar, and skip buttons. Used for both music and video.
struct MediaControls: View {
    @Bindable var playback: MediaPlayback
    var onFullScreen: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: $playback.current,
                in: 0...max(playback.duration, 0.1),
                onEditingChanged: { playback.scrub(editing: $0) }
            )
            .onChange(of: playback.current) { playback.scrubMoved() }
            .disabled(playback.duration <= 0)

            HStack {
                Text(Self.time(playback.current))
                Spacer()
                Text("−" + Self.time(max(playback.duration - playback.current, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 26) {
                Spacer()
                Button { playback.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.title3)
                }
                .accessibilityLabel("Назад на 10 секунд")

                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 56, height: 56)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(playback.isPlaying ? "Пауза" : "Играть")

                Button { playback.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.title3)
                }
                .accessibilityLabel("Вперёд на 10 секунд")
                Spacer()
            }
            .overlay(alignment: .trailing) {
                if let onFullScreen {
                    Button(action: onFullScreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.body)
                    }
                    .accessibilityLabel("На весь экран")
                }
            }
            .tint(Theme.tint)
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Video picture

/// Shows the video picture without the system controls, which do not draw
/// correctly inside glass cards.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class SurfaceView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The system player on its own full screen, with zoom and AirPlay.
struct FullScreenVideo: View {
    let playback: MediaPlayback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: playback.player)
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("Закрыть")
        }
        .onAppear { playback.play() }
    }
}
