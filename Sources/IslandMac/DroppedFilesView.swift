import SwiftUI
import UniformTypeIdentifiers

/// The session's dropped files, shown when the island grows into its `.files` state.
struct DroppedFilesView: View {
    @ObservedObject var files: DroppedFiles
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if files.items.isEmpty {
                Text("No dropped files")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: FilesLayout.rowHeight)
            } else {
                if files.items.count > FilesLayout.maxVisibleRows {
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .frame(height: CGFloat(FilesLayout.maxVisibleRows) * FilesLayout.rowHeight)
                } else {
                    rows
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FilesLayout.horizontalPadding)
        .padding(.bottom, FilesLayout.bottomPadding)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(files.items, id: \.self) { url in
                FileRow(url: url, unavailable: files.unavailable.contains(url),
                        reveal: { files.revealInFinder(url) },
                        open: { files.open(url) },
                        remove: { files.removeFromList(url) })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            PageBackButton(title: "Dropped Files", action: onBack)
            Spacer(minLength: 8)
            // Make "remove" unambiguous: it never touches the file on disk.
            Text("Removing only clears this list")
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(height: FilesLayout.headerHeight)
    }
}

private struct FileRow: View {
    let url: URL
    let unavailable: Bool
    let reveal: () -> Void
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Clicking the row itself is the primary action: Reveal in Finder.
            Button(action: reveal) {
                HStack(spacing: FilesLayout.iconToText) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: FilesLayout.iconSize, height: FilesLayout.iconSize)
                        .opacity(unavailable ? 0.4 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(unavailable ? Ink.secondary : Ink.primary)
                            .truncationMode(.middle)
                        Text(unavailable ? "File unavailable" : detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(unavailable ? Color.orange.opacity(0.9) : Ink.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            RowAction(symbol: "arrow.up.forward.app", help: "Open", action: open)
            RowAction(symbol: "magnifyingglass", help: "Reveal in Finder", action: reveal)
            RowAction(symbol: "minus.circle", help: "Remove from list (the file is kept)", action: remove)
        }
        .frame(height: FilesLayout.rowHeight)
    }

    /// Kind plus the containing folder, enough to tell apart files with similar names.
    private var detail: String {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
        let kind = isFolder ? "Folder" : UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "File"
        return "\(kind) · \(url.deletingLastPathComponent().lastPathComponent)"
    }
}

private struct RowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.control)
                .frame(width: FilesLayout.actionSize, height: FilesLayout.actionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .help(help)
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? ControlLayout.pressedOpacity : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
