import SwiftUI

/// Brief feedback after the system volume changes: a speaker symbol and the level as a bar.
struct VolumeFeedbackView: View {
    @ObservedObject var volume: SystemVolume

    var body: some View {
        let silent = volume.isMuted || volume.level == 0
        HStack(spacing: SystemFeedbackLayout.iconToBar) {
            Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: Double(volume.level))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(silent ? Ink.secondary : Ink.primary)
                .frame(width: SystemFeedbackLayout.iconWidth)
                .contentTransition(.symbolEffect(.replace))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.fill)
                    // Muted keeps showing the level it will return to, dimmed.
                    Capsule().fill(volume.isMuted ? Ink.tertiary : Ink.primary)
                        // Never narrower than its own height, so a low level is still a round dot.
                        .frame(width: volume.level > 0 ? max(SystemFeedbackLayout.barHeight, geo.size.width * CGFloat(volume.level)) : 0)
                }
                .frame(height: SystemFeedbackLayout.barHeight)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, SystemFeedbackLayout.horizontalPadding)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: volume.level)
        .animation(.easeOut(duration: 0.15), value: volume.isMuted)
    }
}
