import SwiftUI

/// Home content (the live activity plus the page buttons), laid out from the surface's *animated*
/// size. SwiftUI interpolates `width`/`height`/`detail` exactly like it interpolates IslandShape,
/// so everything here moves in lockstep with the morphing surface, including when a hover → expand
/// animation is interrupted and retargeted. Nothing in here animates on its own.
///
/// Choreography, as the surface grows (`t` = 0 pill … 1 expanded), and in reverse on collapse:
///  - artwork grows from the pill's left end cap into the player's artwork slot,
///  - the equalizer fades out over the first third,
///  - the player's text, controls and progress (and the page buttons) fade in over the last part,
///  - idle (clock): the time glides from the pill's centre into Quick Launch's header, the date eases
///    in beside it, and the app icons arrive from the centre outwards,
///  - low battery: the battery and percentage glide into the header, over the idle Quick Launch row.
struct HomeLayer: View, Animatable {
    var width: CGFloat
    var height: CGFloat
    /// 0 at rest, 1 on hover and when expanded: whether the clock shows its date line.
    var detail: CGFloat
    let state: IslandState
    let activity: IslandActivity
    @ObservedObject var nowPlaying: NowPlaying
    /// Not observed here: only the battery view redraws on its changes.
    let power: PowerSource
    let quickLaunch: QuickLaunchApps
    let pointer: IslandPointer
    let fileCount: Int
    /// The pill's right end cap is showing something else (a running command's spinner).
    var hidesEqualizer = false
    let geometry: IslandGeometry
    let requestState: (IslandState) -> Void
    /// Collapse after an action that sends the user elsewhere (launching an app).
    let dismiss: () -> Void

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { .init(.init(width, height), detail) }
        set { width = newValue.first.first; height = newValue.first.second; detail = newValue.second }
    }

    var body: some View {
        let t = geometry.homeExpansion(height: height, activity: activity)
        let open = state == .expanded
        ZStack(alignment: .topLeading) {
            switch activity {
            case .battery(let warning):
                ZStack(alignment: .topLeading) {
                    LowBatteryView(power: power, warning: warning, t: t, width: width, height: height, geometry: geometry)
                    QuickLaunchView(apps: quickLaunch, pointer: pointer, row: QuickLaunchLayout.idleRow, t: t,
                                    centerX: geometry.canvasSize.width / 2, interactive: open) { app in
                        quickLaunch.launch(app)
                        dismiss()
                    }
                }
                .transition(IslandMotion.homeTransition)
            case .nowPlaying:
                nowPlayingContent(t: t, interactive: open)
                    .transition(IslandMotion.homeTransition)
            case .clock:
                ZStack(alignment: .topLeading) {
                    IdleClockView(t: t, detail: detail, height: height, centerX: geometry.canvasSize.width / 2,
                                  leading: geometry.contentLeading(width: width))
                    QuickLaunchView(apps: quickLaunch, pointer: pointer, row: QuickLaunchLayout.idleRow, t: t,
                                    centerX: geometry.canvasSize.width / 2, interactive: open) { app in
                        quickLaunch.launch(app)
                        dismiss()
                    }
                }
                .transition(IslandMotion.homeTransition)
            }
            pageButtons(t: t, interactive: open, inHeader: activity != .nowPlaying, showsEdit: showsQuickLaunch)
        }
        .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func nowPlayingContent(t: CGFloat, interactive: Bool) -> some View {
        let reveal = smoothstep(0.5, 1, t)
        ZStack(alignment: .topLeading) {
            // Player text, controls and progress: laid out across the surface's live width, so the
            // text rides with the artwork on the left and the controls with the right edge instead of
            // being clipped by the growing surface; revealed over the end of the morph.
            if reveal > 0, let track = nowPlaying.track {
                MediaPlayerView(nowPlaying: nowPlaying, track: track)
                    .frame(width: width, height: PlayerLayout.height)
                    .scaleEffect(lerp(0.97, 1, reveal), anchor: .topLeading)
                    .opacity(reveal)
                    .position(x: geometry.canvasSize.width / 2, y: IslandGeometry.topGap + PlayerLayout.height / 2)
                    .allowsHitTesting(interactive)
            }
            // Quick Launch under the player, past a hairline; it arrives after the player does.
            if reveal > 0 {
                Rectangle()
                    .fill(Ink.separator)
                    .frame(width: max(0, width - 2 * PlayerLayout.horizontalPadding), height: 0.5)
                    .opacity(smoothstep(0.6, 1, t))
                    .position(x: geometry.canvasSize.width / 2, y: IslandGeometry.topGap + QuickLaunchLayout.musicSeparatorY)
                QuickLaunchView(apps: quickLaunch, pointer: pointer, row: QuickLaunchLayout.musicRow, t: t,
                                centerX: geometry.canvasSize.width / 2, interactive: interactive) { app in
                    quickLaunch.launch(app)
                    dismiss()
                }
                // Customize, reachable while music plays too: at the end of the app row.
                PageButton(symbol: "slider.horizontal.3", badge: 0, help: "Customize Quick Launch") { requestState(.quickLaunchEdit) }
                    .opacity(smoothstep(0.85, 1, t))
                    .position(geometry.musicRowEditButtonCenter(width: width))
                    .allowsHitTesting(interactive)
            }
            let art = geometry.artworkFrame(width: width, height: height)
            ArtworkView(image: nowPlaying.artwork, cornerRadius: art.cornerRadius)
                .frame(width: art.rect.width, height: art.rect.height)
                .position(x: art.rect.midX, y: art.rect.midY)
            let eq = hidesEqualizer ? 0 : 1 - smoothstep(0, 0.3, t)
            if eq > 0 {
                EqualizerView(isPlaying: nowPlaying.isPlaying)
                    .scaleEffect(lerp(0.6, 1, eq))
                    .opacity(eq)
                    .position(geometry.equalizerCenter(width: width, height: height))
            }
        }
    }

    /// Home layouts with the Quick Launch row (and so its customize button in the header).
    private var showsQuickLaunch: Bool {
        switch activity {
        case .clock, .battery: true
        case .nowPlaying: false
        }
    }

    @ViewBuilder
    private func pageButtons(t: CGFloat, interactive: Bool, inHeader: Bool, showsEdit: Bool) -> some View {
        let reveal = smoothstep(0.65, 1, t)
        if reveal > 0 {
            PageButton(symbol: fileCount == 0 ? "tray" : "tray.full", badge: fileCount, help: "Dropped Files") {
                requestState(.files)
            }
            .opacity(reveal)
            .position(geometry.pageButtonCenter(slot: PageButtonLayout.filesSlot, width: width, height: height, inHeader: inHeader))
            .allowsHitTesting(interactive)
            PageButton(symbol: "calendar", badge: 0, help: "Calendar") { requestState(.calendar) }
                .opacity(reveal)
                .position(geometry.pageButtonCenter(slot: PageButtonLayout.calendarSlot, width: width, height: height, inHeader: inHeader))
                .allowsHitTesting(interactive)
            PageButton(symbol: "magnifyingglass", badge: 0, help: "Find a file") { requestState(.search) }
                .opacity(reveal)
                .position(geometry.pageButtonCenter(slot: PageButtonLayout.searchSlot, width: width, height: height, inHeader: inHeader))
                .allowsHitTesting(interactive)
            if showsEdit {
                PageButton(symbol: "slider.horizontal.3", badge: 0, help: "Customize Quick Launch") { requestState(.quickLaunchEdit) }
                    .opacity(reveal)
                    .position(geometry.pageButtonCenter(slot: PageButtonLayout.editSlot, width: width, height: height, inHeader: true))
                    .allowsHitTesting(interactive)
            }
        }
    }
}
