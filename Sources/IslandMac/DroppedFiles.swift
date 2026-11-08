import AppKit

/// This session's dropped files: the Files feature's data, as NowPlaying is music's.
///
/// In memory only, cleared when IslandMac quits. The only things IslandMac ever does with a dropped
/// file are remember its URL, read its name/kind/icon, and ask Finder / the default app to show or
/// open it. Nothing here copies, moves, renames, modifies or deletes a file.
final class DroppedFiles: ObservableObject {
    /// Newest first.
    @Published private(set) var items: [URL] = []
    /// The most recent drop, for the "received" confirmation.
    @Published private(set) var lastDrop: [URL] = []
    /// Items whose original couldn't be found when the user last tried to reveal or open them.
    @Published private(set) var unavailable: Set<URL> = []

    func add(_ urls: [URL]) {
        lastDrop = urls
        // Dropping the same item again moves it to the top instead of duplicating it.
        for url in urls.reversed() {
            items.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
            items.insert(url, at: 0)
            unavailable.remove(url)
        }
        print("session list: \(items.count) item(s)")
    }

    /// Removes the entry from IslandMac's list only. The original file is not touched.
    func removeFromList(_ url: URL) {
        items.removeAll { $0 == url }
        unavailable.remove(url)
        print("removed from list (original untouched): \(url.path)")
    }

    func revealInFinder(_ url: URL) {
        guard isAvailable(url) else { return }
        print("reveal in Finder: \(url.path)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens with the default app (folders open in Finder).
    func open(_ url: URL) {
        guard isAvailable(url) else { return }
        print("open: \(url.path)")
        NSWorkspace.shared.open(url)
    }

    private func isAvailable(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            unavailable.remove(url)
            return true
        }
        unavailable.insert(url)
        print("file unavailable (moved or deleted): \(url.path)")
        return false
    }
}
