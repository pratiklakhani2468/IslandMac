import AppKit
import UniformTypeIdentifiers

/// Quick file search: the File Search feature's data, as NowPlaying is music's.
///
/// Local only. Spotlight's public metadata query (`NSMetadataQuery`) finds candidates whose *names*
/// contain any meaningful word of the request, over the user's indexed home folder; a deterministic
/// local ranking then scores them on name, folder path and file type. Nothing reads file contents,
/// nothing leaves the Mac, and there is no language model: the "natural language" is a small set of
/// rules (drop command words, understand "from/in <folder>", map type words like "pdf" or "slides").
final class FileSearch: ObservableObject {
    struct Result: Identifiable, Equatable {
        let url: URL
        let name: String
        /// Parent folders relative to home, e.g. "Documents › College › DSA".
        let location: String
        let isFolder: Bool
        /// The file type's native icon (never reads the file, so no folder-access prompt).
        let icon: NSImage
        var id: URL { url }
        static func == (a: Result, b: Result) -> Bool { a.url == b.url }
    }

    @Published var text = "" { didSet { if text != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [Result] = []
    @Published private(set) var selection = 0
    /// True only while a Spotlight query has been running for a noticeable time.
    @Published private(set) var showsProgress = false
    /// A search has completed for the current text (distinguishes "no results" from "not searched yet").
    @Published private(set) var hasSearched = false
    /// Protected folders IslandMac may not read. Spotlight silently leaves their files out of results
    /// for an app without access, so the page says so instead of just finding nothing.
    @Published private(set) var inaccessibleFolders: [String] = []

    /// A fresh query per search: a stopped NSMetadataQuery doesn't reliably report again when restarted.
    private var query: NSMetadataQuery?
    private var parsed = ParsedQuery(nameTerms: [], folderTerms: [], types: [], wantsFolder: false)
    private var debounce: DispatchWorkItem?
    private var progressDelay: DispatchWorkItem?
    private var started = Date()
    private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    init() {}

    /// Checks access to the privacy-protected folders people keep documents in. Listing them (names
    /// only, never contents) is what lets macOS ask the standard one-time "access files in your …
    /// folder" question, so this runs only when the user opens File Search, never at launch.
    func checkFolderAccess() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        inaccessibleFolders = ["Desktop", "Documents", "Downloads"].filter {
            (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent($0).path)) == nil
        }
        if !inaccessibleFolders.isEmpty { print("file search: no access to \(inaccessibleFolders.joined(separator: ", "))") }
    }

    /// Clears the query and results (called whenever the search surface opens or closes).
    func reset() {
        debounce?.cancel()
        stopQuery()
        text = ""
        results = []
        selection = 0
        hasSearched = false
        showsProgress = false
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }

    /// Rows below the field right now (results, or one "No matching files" line), for the surface height.
    var visibleRows: Int {
        if text.isEmpty { return 0 }
        return results.isEmpty ? (hasSearched ? 1 : 0) : results.count
    }

    var selectedResult: Result? { results.indices.contains(selection) ? results[selection] : nil }

    /// Opens with the user's default app (folders open in Finder). Never modifies the file.
    func open(_ result: Result) {
        print("file search: opening \(result.name)")
        NSWorkspace.shared.open(result.url)
    }

    // MARK: Searching

    private func scheduleSearch() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startQuery() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FileSearchLayout.debounce, execute: work)
    }

    private func startQuery() {
        parsed = ParsedQuery(text)
        stopQuery()
        let terms = parsed.spotlightPatterns
        guard !terms.isEmpty else {
            results = []
            hasSearched = false
            return
        }
        // Spotlight only matches names, so candidates are items whose name contains any term; the
        // ranking below decides using the full path.
        let byName = terms.map { NSPredicate(format: "kMDItemFSName LIKE[cd] %@", $0) }
        // (Spotlight rejects an OR group of one, so a single word is passed as-is.)
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = byName.count == 1 ? byName[0] : NSCompoundPredicate(orPredicateWithSubpredicates: byName)
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = query
        started = Date()
        progressDelay?.cancel()
        let delay = DispatchWorkItem { [weak self] in self?.showsProgress = true }
        progressDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + FileSearchLayout.progressAfter, execute: delay)
        query.start()
    }

    private func stopQuery() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = nil
    }

    @objc private func gathered(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, query === self.query else { return }
        collect(query)
        stopQuery()
    }

    private func collect(_ query: NSMetadataQuery) {
        progressDelay?.cancel()
        showsProgress = false
        var scored: [(Double, Date, Result)] = []
        let items = query.results.prefix(FileSearchLayout.maxCandidates).compactMap { $0 as? NSMetadataItem }
        let paths = items.map { ($0.value(forAttribute: NSMetadataItemPathKey) as? String) ?? "" }
        // Rarer words matter more: weight each word by how few candidate names contain it.
        let weights = parsed.weights(names: paths.map { ($0 as NSString).lastPathComponent })
        for (item, path) in zip(items, paths) {
            guard path.hasPrefix(home + "/"), !Self.isNoise(path) else { continue }
            let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            let isFolder = contentType == "public.folder"
            let score = parsed.score(path: path, home: home, isFolder: isFolder, weights: weights)
            guard score > 0 else { continue }
            let used = (item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date)
                ?? (item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date) ?? .distantPast
            scored.append((score, used, Result(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
                                               location: Self.location(of: path, home: home), isFolder: isFolder,
                                               icon: Self.icon(forPath: path, isFolder: isFolder))))
        }
        // Highest score first; among equals, the most recently used / modified.
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 > $1.1 }
        results = scored.prefix(FileSearchLayout.maxResults).map(\.2)
        selection = 0
        hasSearched = true
        print(String(format: "file search: \"%@\" → %d candidates, %d shown, %.0f ms", text, items.count, results.count,
                     Date().timeIntervalSince(started) * 1000))
    }

    private static func icon(forPath path: String, isFolder: Bool) -> NSImage {
        let type = isFolder ? UTType.folder : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Hidden items, app internals and developer caches aren't things you "open".
    private static func isNoise(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.contains { $0.hasPrefix(".") } || path.contains("/Library/") || path.contains(".app/")
            || (parts.last?.hasPrefix("~$") ?? false)                                    // Office lock/temp files
            || parts.contains { ["node_modules", "DerivedData", "Pods", "__pycache__", "site-packages", "dist-packages"].contains(String($0)) }
    }

    private static func location(of path: String, home: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let relative = parent == home ? "" : parent.hasPrefix(home + "/") ? String(parent.dropFirst(home.count + 1)) : parent
        let parts = relative.split(separator: "/").map(String.init)
        let shown = parts.count > 3 ? ["…"] + parts.suffix(3) : parts
        return shown.isEmpty ? "Home" : shown.joined(separator: " › ")
    }
}

/// The request, reduced to what a local search can actually use.
struct ParsedQuery {
    /// Words expected in the item's name.
    let nameTerms: [String]
    /// Words expected in a containing folder ("… from dsa folder", "… in college").
    let folderTerms: [String]
    /// Acceptable extensions, from type words ("pdf", "slides", "spreadsheet"…).
    let types: Set<String>
    let wantsFolder: Bool

    private static let commandWords: Set<String> = ["open", "find", "show", "launch", "search", "get", "me", "my", "the", "a", "an",
                                                    "please", "file", "files", "document", "called", "named", "for", "of", "and", "to"]
    private static let locationWords: Set<String> = ["from", "in", "inside", "under", "within"]
    private static let folderWords: Set<String> = ["folder", "folders", "directory", "dir"]
    private static let typeWords: [String: Set<String>] = [
        "pdf": ["pdf"], "doc": ["doc", "docx"], "docx": ["docx", "doc"], "word": ["docx", "doc"],
        "ppt": ["ppt", "pptx", "key"], "pptx": ["pptx", "ppt"], "presentation": ["pptx", "ppt", "key", "pdf"], "slides": ["pptx", "ppt", "key", "pdf"],
        "keynote": ["key"], "xls": ["xls", "xlsx"], "xlsx": ["xlsx", "xls"], "excel": ["xlsx", "xls"], "spreadsheet": ["xlsx", "xls", "numbers", "csv"],
        "sheet": ["xlsx", "xls", "numbers", "csv"], "csv": ["csv"], "numbers": ["numbers"], "pages": ["pages"],
        "txt": ["txt"], "text": ["txt", "md", "rtf"], "image": ["png", "jpg", "jpeg", "heic", "gif", "webp"],
        "photo": ["png", "jpg", "jpeg", "heic"], "picture": ["png", "jpg", "jpeg", "heic"], "screenshot": ["png"],
        "png": ["png"], "jpg": ["jpg", "jpeg"], "jpeg": ["jpeg", "jpg"], "zip": ["zip"], "video": ["mp4", "mov", "m4v"],
        "mp4": ["mp4"], "mov": ["mov"],
    ]

    init(nameTerms: [String], folderTerms: [String], types: Set<String>, wantsFolder: Bool) {
        self.nameTerms = nameTerms; self.folderTerms = folderTerms; self.types = types; self.wantsFolder = wantsFolder
    }

    init(_ text: String) {
        let words = Self.tokens(text)
        var names: [String] = [], folders: [String] = [], types = Set<String>(), wantsFolder = false
        var inLocation = false
        for (index, word) in words.enumerated() {
            if Self.locationWords.contains(word) { inLocation = true; continue }
            if Self.folderWords.contains(word) {
                // "exp6 from dsa folder": the folder word closes a location. "open dsa folder": wants a folder.
                if !inLocation && index == words.count - 1 { wantsFolder = true }
                continue
            }
            if Self.commandWords.contains(word) { continue }
            if let exts = Self.typeWords[word], !inLocation { types.formUnion(exts); continue }
            if inLocation { folders.append(word) } else { names.append(word) }
        }
        self.init(nameTerms: names, folderTerms: folders, types: types, wantsFolder: wantsFolder)
    }

    /// Lowercased alphanumeric words ("DSA_Exp6-final.pdf" → dsa, exp6, final, pdf).
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// "exp6" → ("exp", "6"): a word made of letters then digits, which people abbreviate freely.
    static func letterDigitSplit(_ term: String) -> (letters: String, digits: String)? {
        guard let i = term.firstIndex(where: \.isNumber), i != term.startIndex,
              term[..<i].allSatisfy(\.isLetter), term[i...].allSatisfy(\.isNumber) else { return nil }
        return (String(term[..<i]), String(term[i...]))
    }

    /// Adjacent words joined ("x tracer" → "xtracer"), since names often drop the space.
    var joinedPairs: [String] {
        zip(nameTerms, nameTerms.dropFirst()).map { $0 + $1 }
    }

    /// Spotlight name patterns: every meaningful word (single letters only as part of a joined pair),
    /// with letter+digit words loosened ("exp6" → "*exp*6*" also finds "Expt6" and "Exp_6").
    var spotlightPatterns: [String] {
        let words = (nameTerms.isEmpty ? folderTerms : nameTerms).filter { $0.count >= 2 } + joinedPairs
        return Array(Set(words.map { word in
            if let (l, d) = Self.letterDigitSplit(word) { return "*\(l)*\(d)*" }
            return "*\(word)*"
        })).sorted()
    }

    /// How strongly `term` matches a list of name tokens: 1 whole word, 0.6 prefix, 0 none.
    /// Letter+digit words also match abbreviations ("exp6" ~ "expt6", "exp 6").
    static func strength(of term: String, in tokens: [String]) -> Double {
        if tokens.contains(term) { return 1 }
        if let (l, d) = letterDigitSplit(term) {
            for (i, t) in tokens.enumerated() {
                if let (tl, td) = letterDigitSplit(t), td == d, tl.hasPrefix(l) || l.hasPrefix(tl) { return 0.9 }
                if t.hasPrefix(l) || l.hasPrefix(t), i + 1 < tokens.count, tokens[i + 1] == d { return 0.9 }
            }
        }
        if tokens.contains(where: { $0.hasPrefix(term) }) { return 0.6 }
        return 0
    }

    /// Weight per word from the candidate names: a word in few names counts up to 2×, one in most ~1×.
    func weights(names: [String]) -> [String: Double] {
        let tokenized = names.map { Self.tokens($0) }
        let n = Double(max(tokenized.count, 1))
        var result: [String: Double] = [:]
        for term in nameTerms + folderTerms {
            let df = Double(tokenized.filter { Self.strength(of: term, in: $0) > 0 }.count)
            result[term] = min(2, 1 + log(n / (df + 1)) / 3)
        }
        return result
    }

    /// Deterministic relevance score; 0 means "don't show".
    func score(path: String, home: String, isFolder: Bool, weights: [String: Double] = [:]) -> Double {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let base = (isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent).lowercased()
        let nameTokens = Self.tokens(base)
        let relativeFolders = url.deletingLastPathComponent().path.dropFirst(home.count)
        let folderTokens = Self.tokens(String(relativeFolders))
        let terms = nameTerms.isEmpty ? folderTerms : nameTerms
        var score = 0.0, matched = 0

        // 1. Exact name: the request's words are the whole name.
        if !nameTerms.isEmpty, nameTokens == nameTerms { score += 100 }
        // 4. Exact phrase: the words appear together, in order, in the name.
        if nameTerms.count > 1, base.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .contains(nameTerms.joined(separator: " ")) { score += 25 }
        // Joined pairs ("x tracer" → "xtracer") account for both of their words.
        var covered = Set<String>()
        for (a, b) in zip(nameTerms, nameTerms.dropFirst()) where base.replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression).contains(a + b) {
            score += 30 * ((weights[a] ?? 1) + (weights[b] ?? 1)) / 2 * 2; covered.formUnion([a, b]); matched += 2
        }
        for term in terms where !covered.contains(term) {
            let w = weights[term] ?? 1
            let inName = Self.strength(of: term, in: nameTokens)
            if inName > 0 { score += 30 * inName * w; matched += 1 }                              // 2. word in the name
            else if term.count >= 3, base.contains(term) { score += 10 * w; matched += 1 }        // 6. partial
            else if Self.strength(of: term, in: folderTokens) > 0 {                               // 3. a folder on the path
                score += 12 * Self.strength(of: term, in: folderTokens) * w; matched += 1
            }
        }
        // At least half of the request's words must be accounted for (so one common word such as
        // "report" can't carry a request that is otherwise unrelated).
        if matched == 0 || matched * 2 < terms.count { return 0 }
        // Every word should be accounted for somewhere; each missing one costs.
        score -= Double(terms.count - matched) * 15
        // "from <folder>": a strong requirement on the path.
        if !nameTerms.isEmpty {
            for term in folderTerms {
                let inFolders = Self.strength(of: term, in: folderTokens)
                score += inFolders > 0 ? 40 * inFolders : -20                                   // ranks below, not hidden
            }
        }
        // 5. File type.
        if !types.isEmpty { score += types.contains(ext) ? 20 : -15 }
        if wantsFolder { score += isFolder ? 20 : -10 }
        // Shallower items slightly ahead of deeply buried ones.
        score -= Double(folderTokens.count) * 0.5
        return score
    }
}
