import SwiftUI

/// Now-playing content shown inside the expanded island. Sized by the caller to the expanded surface.
struct MediaPlayerView: View {
    @ObservedObject var nowPlaying: NowPlaying
    let track: Track

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: PlayerLayout.artworkToText) {
                // Slot for the shared artwork, which IslandView draws so it can grow out of the pill.
                Color.clear.frame(width: PlayerLayout.artworkSize, height: PlayerLayout.artworkSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                controls
            }
            Spacer(minLength: 0)
            ProgressRow(nowPlaying: nowPlaying, duration: track.duration)
                .padding(.trailing, PageButtonLayout.reserve) // room for IslandView's page buttons
        }
        .padding(.horizontal, PlayerLayout.horizontalPadding)
        .padding(.top, PlayerLayout.topPadding)
        .padding(.bottom, PlayerLayout.bottomPadding)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            TransportButton(symbol: "backward.fill", size: 13) { nowPlaying.previousTrack() }
            TransportButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                nowPlaying.togglePlayPause()
            }
            TransportButton(symbol: "forward.fill", size: 13) { nowPlaying.nextTrack() }
        }
    }
}

/// Track artwork, or a quiet placeholder while it loads or when the track has none.
struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Ink.selection
                Image(systemName: "music.note").resizable().scaledToFit()
                    .foregroundStyle(Ink.tertiary).scaleEffect(0.38)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Ink.primary)
                .frame(width: PlayerLayout.controlHitSize, height: PlayerLayout.controlHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? ControlLayout.pressedScale : 1)
            .opacity(configuration.isPressed ? ControlLayout.pressedOpacity : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Elapsed time, a scrubbable progress bar, and remaining time.
private struct ProgressRow: View {
    @ObservedObject var nowPlaying: NowPlaying
    let duration: TimeInterval
    /// Non-nil while the user drags the bar; the bar follows the finger, and the seek is sent on release.
    @State private var scrubFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = scrubFraction.map { $0 * duration } ?? nowPlaying.position(at: context.date)
            let fraction = duration > 0 ? elapsed / duration : 0
            HStack(spacing: 10) {
                timeLabel(Self.format(elapsed), alignment: .trailing)
                bar(fraction: fraction)
                timeLabel("-" + Self.format(duration - elapsed), alignment: .leading)
            }
        }
        .frame(height: PlayerLayout.progressRowHeight)
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.fill)
                Capsule().fill(Ink.primary)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
            .frame(height: scrubFraction == nil ? PlayerLayout.progressBarHeight : PlayerLayout.progressBarScrubHeight)
            .frame(maxHeight: .infinity)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: scrubFraction == nil)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrubFraction = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded { _ in
                        if let f = scrubFraction { nowPlaying.seek(to: f * duration) }
                        scrubFraction = nil
                    }
            )
        }
    }

    private func timeLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Ink.tertiary)
            .frame(minWidth: 32, alignment: alignment)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
