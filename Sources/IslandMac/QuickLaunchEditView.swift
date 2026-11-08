import SwiftUI

/// The Quick Launch editor: your apps in launcher order (select one to move or remove it), then the
/// installed apps you can add. Changes apply and are saved immediately.
struct QuickLaunchEditView: View {
    @ObservedObject var apps: QuickLaunchApps
    let onDone: () -> Void
    @State private var selected: URL?

    private typealias L = QuickLaunchEditLayout

    var body: some View {
        let selection = apps.apps.first { $0.id == selected }
        VStack(spacing: 0) {
            header
            currentRow
            controls(selection)
            Rectangle().fill(Ink.separator).frame(height: 0.5)
            HStack {
                Text("Add an app").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
                Spacer()
                if apps.isFull {
                    Text("Remove one to add another").font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: apps.isFull)
            .frame(height: L.addTitleHeight)
            addList
            Spacer(minLength: 0)
        }
        .padding(.horizontal, L.horizontalPadding)
        .padding(.bottom, L.bottomPadding)
        .animation(.easeOut(duration: 0.15), value: apps.apps.map(\.id))
        .onAppear { apps.loadInstalled() }
    }

    private var header: some View {
        HStack {
            PageBackButton(title: "Quick Launch", action: onDone)
            Spacer()
            Text("\(apps.apps.count) of \(QuickLaunchLayout.maxApps)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
                .contentTransition(.numericText())
        }
        .frame(height: L.headerHeight)
    }

    private var currentRow: some View {
        HStack(spacing: L.currentIconSpacing) {
            if apps.apps.isEmpty {
                Text("No apps — add some below").font(.system(size: 11.5)).foregroundStyle(Ink.tertiary)
            }
            ForEach(apps.apps) { app in
                Button { selected = selected == app.id ? nil : app.id } label: {
                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: L.currentIconSize, height: L.currentIconSize)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: ControlLayout.selectionRadius, style: .continuous)
                            .fill(selected == app.id ? Ink.selection : .clear))
                        .animation(.easeOut(duration: 0.12), value: selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .help(app.name)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: L.currentRowHeight)
    }

    /// Move / remove the selected app, or a hint when nothing is selected.
    private func controls(_ selection: QuickLaunchApps.App?) -> some View {
        HStack(spacing: 14) {
            if let app = selection, let index = apps.apps.firstIndex(of: app) {
                GlyphButton(symbol: "chevron.left", enabled: index > 0) { apps.move(app, by: -1) }
                Text(app.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                GlyphButton(symbol: "chevron.right", enabled: index < apps.apps.count - 1) { apps.move(app, by: 1) }
                Button {
                    apps.remove(app)
                    selected = nil
                } label: { CapsuleLabel(title: "Remove") }
                .buttonStyle(PressScaleStyle())
            } else {
                Text("Select an app to move or remove it")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(height: L.controlsHeight)
    }

    private var addList: some View {
        let candidates = apps.installed.filter { app in !apps.apps.contains { $0.bundleID == app.bundleID } }
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(candidates) { app in
                    Button {
                        apps.add(app)
                        selected = app.id
                    } label: {
                        HStack(spacing: 9) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: L.listIconSize, height: L.listIconSize)
                            Text(app.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(apps.isFull ? Ink.tertiary : Ink.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(apps.isFull ? Ink.quaternary : Ink.secondary)
                        }
                        .frame(height: L.listRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .disabled(apps.isFull)
                }
            }
        }
        .frame(height: CGFloat(L.visibleListRows) * L.listRowHeight)
    }
}
