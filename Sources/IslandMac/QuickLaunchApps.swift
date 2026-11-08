import AppKit

/// The apps offered in the expanded idle island: the Quick Launch feature's data, as NowPlaying is
/// music's.
///
/// Discovery uses public Spotlight metadata (`NSMetadataQuery`) over the standard application
/// folders, ranked by Spotlight's own launch count (`kMDItemUseCount`), so the list reflects how
/// this Mac is actually used. Nothing is scanned by hand and no permission is needed. Finder is
/// always first: it's always running, so Spotlight never counts it as launched.
///
/// Once the user customizes the list (add / remove / reorder), their choice replaces the ranking and
/// is kept across launches as an ordered list of bundle identifiers in UserDefaults, resolved back
/// to apps through Launch Services (so moved apps still resolve).
final class QuickLaunchApps: ObservableObject {
    struct App: Identifiable, Equatable {
        let url: URL
        let name: String
        let bundleID: String?
        /// Fetched once at discovery, not on every animation frame.
        let icon: NSImage
        var id: URL { url }
        static func == (a: App, b: App) -> Bool { a.url == b.url && a.name == b.name }
    }

    @Published private(set) var apps: [App] = []
    /// Every installed app, by name, for adding (loaded when the editor opens).
    @Published private(set) var installed: [App] = []
    /// The user's own list, if they've customized it; nil means the automatic ranking.
    private var customIDs: [String]? { didSet { UserDefaults.standard.set(customIDs, forKey: Self.defaultsKey) } }
    private static let defaultsKey = "QuickLaunchApps"
    private var installedQuery: NSMetadataQuery?

    /// A fresh query per refresh: a stopped NSMetadataQuery doesn't reliably report again when restarted.
    private var query: NSMetadataQuery?
    private var lastRefresh = Date.distantPast
    private static let finderID = "com.apple.finder"
    private static let refreshInterval: TimeInterval = 15 * 60

    init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) {
            customIDs = saved
            apps = Self.resolve(saved)
            print("quick launch (saved): " + apps.map(\.name).joined(separator: ", "))
        } else {
            refresh()
        }
    }

    /// Re-ranks at most every 15 minutes (called when the launcher is shown). A customized list is
    /// just re-resolved, in case an app was removed from the Mac.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > Self.refreshInterval else { return }
        if let customIDs { lastRefresh = Date(); apps = Self.resolve(customIDs) } else { refresh() }
    }

    // MARK: Customizing

    var isFull: Bool { apps.count >= QuickLaunchLayout.maxApps }

    func add(_ app: App) {
        guard !isFull, let id = app.bundleID, !apps.contains(where: { $0.bundleID == id }) else { return }
        edit { $0.append(id) }
    }

    func remove(_ app: App) {
        guard let id = app.bundleID else { return }
        edit { $0.removeAll { $0 == id } }
    }

    /// Moves `app` one place left (-1) or right (+1).
    func move(_ app: App, by delta: Int) {
        guard let id = app.bundleID else { return }
        edit { ids in
            guard let i = ids.firstIndex(of: id), ids.indices.contains(i + delta) else { return }
            ids.swapAt(i, i + delta)
        }
    }

    /// First edit starts from what's currently shown, then the list is the user's.
    private func edit(_ change: (inout [String]) -> Void) {
        var ids = customIDs ?? apps.compactMap(\.bundleID)
        change(&ids)
        customIDs = ids
        apps = Self.resolve(ids)
        print("quick launch (saved): " + apps.map(\.name).joined(separator: ", "))
    }

    private static func resolve(_ ids: [String]) -> [App] {
        ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map(app(at:))
    }

    /// Loads every installed app (Spotlight, standard application folders) for the editor's Add list.
    func loadInstalled() {
        if let old = installedQuery { old.stop(); NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: old) }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        query.searchScopes = Self.appFolders
        NotificationCenter.default.addObserver(self, selector: #selector(gatheredInstalled(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        installedQuery = query
        query.start()
    }

    @objc private func gatheredInstalled(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === installedQuery else { return }
        var seen = Set<String>(), result: [App] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String, let bundle = Bundle(path: path),
                  let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier, !seen.contains(id),
                  !Self.isBackgroundOnly(bundle) else { continue }
            seen.insert(id)
            result.append(Self.app(at: URL(fileURLWithPath: path)))
        }
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.finderID), !seen.contains(Self.finderID) {
            result.append(Self.app(at: finder))
        }
        installed = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        installedQuery = nil
    }

    private static let appFolders = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]

    private func refresh() {
        lastRefresh = Date()
        if let old = query { old.stop(); NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: old) }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle' AND kMDItemUseCount > 0")
        query.searchScopes = Self.appFolders
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = query
        query.start()
    }

    @objc private func gathered(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        collectResults(query)
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = nil
    }

    private func collectResults(_ query: NSMetadataQuery) {
        var ranked: [(count: Int, app: App)] = []
        var seen = Set<String>()
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let count = item.value(forAttribute: "kMDItemUseCount") as? Int else { continue }
            let url = URL(fileURLWithPath: path)
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, id != Self.finderID, !seen.contains(id),
                  !Self.isBackgroundOnly(bundle) else { continue }
            seen.insert(id)
            ranked.append((count, Self.app(at: url)))
        }
        // The user's own list, once they've made one, always wins over the ranking.
        guard customIDs == nil else { return }
        ranked.sort { $0.count > $1.count }
        var result: [App] = []
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.finderID) {
            result.append(Self.app(at: finder))
        }
        result += ranked.prefix(QuickLaunchLayout.maxApps - result.count).map(\.app)
        if result != apps { apps = result }
        print("quick launch: " + result.map(\.name).joined(separator: ", "))
    }

    /// Opens the app, or brings it forward if it's already running (no second instance).
    func launch(_ app: App) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        print("quick launch: opening \(app.name)")
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { running, error in
            if let error { print("quick launch: \(app.name) failed: \(error.localizedDescription)") }
            else { print("quick launch: \(app.name) active (pid \(running?.processIdentifier ?? -1))") }
        }
    }

    private static func app(at url: URL) -> App {
        App(url: url, name: displayName(url), bundleID: Bundle(url: url)?.bundleIdentifier, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    private static func isBackgroundOnly(_ bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        func flag(_ key: String) -> Bool { (info[key] as? Bool) ?? ((info[key] as? String) == "1") }
        return flag("LSUIElement") || flag("LSBackgroundOnly")
    }

    /// Finder's display name without ".app" and without invisible direction marks some bundles carry.
    private static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return trimmed.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }.map(String.init).joined()
    }
}
