import SwiftUI

/// File Search: a field that grows a short list of matches, inside the same island surface.
/// Typing searches after a short pause; ↑/↓ move the selection, Return opens it, Escape goes back.
struct SearchPageView: View {
    @ObservedObject var search: FileSearch
    let onOpen: (FileSearch.Result) -> Void
    let onExit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if !rows.isEmpty || showsEmptyLine {
                // Separates the field from what it found, as Spotlight does.
                Rectangle().fill(Ink.separator).frame(height: 0.5)
                    .transition(.opacity)
            }
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(rows) { result in
                        ResultRow(result: result) { onOpen(result) }
                    }
                }
                // One highlight that slides between rows instead of blinking from row to row.
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: ControlLayout.selectionRadius, style: .continuous)
                        .fill(Ink.selection)
                        .frame(height: FileSearchLayout.rowHeight)
                        .padding(.horizontal, -8)
                        .offset(y: CGFloat(min(search.selection, rows.count - 1)) * FileSearchLayout.rowHeight)
                        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: search.selection)
                }
                .padding(.top, FileSearchLayout.listTopGap - 0.5)
                .transition(.opacity.combined(with: .offset(y: -4)))
            } else if showsEmptyLine {
                Text(search.inaccessibleFolders.isEmpty ? "No matching files"
                     : "No matching files · \(search.inaccessibleFolders.joined(separator: ", ")) not searchable")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: FileSearchLayout.rowHeight)
                    .padding(.top, FileSearchLayout.listTopGap - 0.5)
                    .transition(.opacity)
                    .help("Allow IslandMac in System Settings › Privacy & Security › Files & Folders")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FileSearchLayout.horizontalPadding)
        .animation(.easeOut(duration: 0.15), value: rows.map(\.id))
        .onAppear {
            // The panel becomes key as this page opens; focus the field once it has.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var rows: [FileSearch.Result] { search.text.isEmpty ? [] : search.results }
    private var showsEmptyLine: Bool { rows.isEmpty && search.hasSearched && !search.text.isEmpty }

    private var field: some View {
        // Symbol on the text's baseline (how SF Symbols are designed to sit beside text).
        HStack(alignment: .firstTextBaseline, spacing: FileSearchLayout.iconToText) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FileSearchLayout.fieldIconSize, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            TextField("", text: $search.text, prompt: Text("What do you want to open?").foregroundStyle(Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Ink.primary)
                .tint(.white)
                .focused($focused)
                .onSubmit { if let r = search.selectedResult { onOpen(r) } }
                .onKeyPress(.upArrow) { search.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { search.moveSelection(1); return .handled }
                .onExitCommand(perform: onExit)
                .offset(y: FileSearchLayout.textNudge)
            if search.showsProgress {
                ProgressView().controlSize(.mini).tint(.white).transition(.opacity)
            }
        }
        .frame(height: FileSearchLayout.fieldHeight)
        // Centre the row in the field-only pill (which is a little taller than the row). A visual
        // offset only: the results list below keeps its position.
        .offset(y: FileSearchLayout.fieldCenteringOffset)
    }
}

private struct ResultRow: View {
    let result: FileSearch.Result
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: FileSearchLayout.iconToText) {
                Image(nsImage: result.icon)
                    .resizable()
                    .frame(width: FileSearchLayout.iconSize, height: FileSearchLayout.iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .truncationMode(.middle)
                    Text(result.location)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.secondary)
                        .truncationMode(.head)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: FileSearchLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .padding(.horizontal, -8)
    }
}
