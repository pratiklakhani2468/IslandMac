import SwiftUI

/// Small "music is playing" bars for the compact pill.
///
/// Music exposes no audio levels, so this is not audio-reactive: each bar follows two slow sine
/// waves at unrelated speeds, which reads as calm, continuous playback without random jitter.
/// While paused the timeline stops and the bars settle to low dots.
struct EqualizerView: View {
    let isPlaying: Bool

    /// Per bar: two angular speeds (rad/s) and a phase.
    private static let motion: [(Double, Double, Double)] = [(3.9, 6.7, 0.0), (4.9, 3.1, 1.9), (3.3, 5.6, 3.7), (4.3, 7.5, 5.3)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: CompactLayout.barSpacing) {
                ForEach(0..<CompactLayout.barCount, id: \.self) { i in
                    Capsule()
                        .fill(Ink.primary)
                        .frame(width: CompactLayout.barWidth, height: barHeight(i, t))
                }
            }
            .frame(height: CompactLayout.barMaxHeight)
            .animation(.easeInOut(duration: 0.35), value: isPlaying)
        }
    }

    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        guard isPlaying else { return CompactLayout.barMinHeight }
        let (a, b, phase) = Self.motion[i % Self.motion.count]
        let level = 0.5 + 0.27 * sin(t * a + phase) + 0.18 * sin(t * b + phase * 1.7) // 0.05...0.95
        return CompactLayout.barMinHeight + (CompactLayout.barMaxHeight - CompactLayout.barMinHeight) * level
    }
}
