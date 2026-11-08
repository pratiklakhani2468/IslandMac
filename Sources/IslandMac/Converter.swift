import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Convert: what happens when files are dropped on the island, as QuickTerminal is commands.
///
/// The dropped files are shown with buttons for what the app can do to their kind of file
/// (`ConversionPlanner`); a button that needs a setting (Compress, Resolution) opens a few choices
/// in its place. The result is saved beside the original under a free name (`ConversionRunner`).
/// Files can be kept in the Dropped Files shelf instead.
final class Converter: ObservableObject {
    enum Phase: Equatable {
        /// Nothing dropped.
        case idle
        /// Files are here; pick a conversion.
        case choosing
        case working
        case done
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        let kind: FileKind
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// What's running, for the progress line.
    struct Job: Equatable {
        let from: String
        let to: String
        let summary: String
    }

    /// A short line under the buttons.
    struct Hint: Equatable {
        enum Style: Equatable {
            /// Something went wrong.
            case error
            /// Worth knowing, nothing wrong ("Already well compressed").
            case info
        }
        let text: String
        let style: Style
    }

    @Published private(set) var phase: Phase = .idle { didSet { updateLayout() } }
    @Published private(set) var items: [Item] = [] { didSet { updateLayout() } }
    /// The button whose choices are showing (Compress → Light, Medium, Strong), if any.
    @Published private(set) var choosing: ActionButton? { didSet { updateLayout() } }
    /// Resolution and sound of a dropped video, once read (decides its buttons).
    @Published private(set) var video = VideoFacts() { didSet { updateLayout() } }
    @Published private(set) var hint: Hint? { didSet { updateLayout() } }
    @Published private(set) var thumbnail: NSImage?
    /// "MOV · 24.3 MB · 0:42".
    @Published private(set) var details = ""
    @Published private(set) var job: Job?
    @Published private(set) var outputs: [ConversionOutput] = []
    /// After a batch: files that were skipped or failed.
    @Published private(set) var note: String? { didSet { updateLayout() } }

    /// Changes every frame of a conversion: observed only by the progress view.
    let progress = ConvertProgress()
    /// The island's size for the current content: observed by the island.
    let layout = ConvertLayoutState()

    var onClose: (() -> Void)?
    var onKeepInShelf: (([URL]) -> Void)?
    /// A conversion ended (done, failed or cancelled).
    var onFinished: (() -> Void)?

    private var task: Task<Void, Never>?

    var primary: Item? { items.first }
    var kind: FileKind { primary?.kind ?? .other }
    var buttons: [ActionButton] { primary.map { ConversionPlanner.buttons(for: $0.url, kind: $0.kind, video: video) } ?? [] }
    var isWorking: Bool { phase == .working }

    // MARK: Files

    /// Takes newly dropped files. False while a conversion is running (it keeps the island).
    @discardableResult
    func load(_ urls: [URL]) -> Bool {
        guard !isWorking else { return false }
        items = urls.map { Item(url: $0, kind: FileKind.of($0)) }
        choosing = nil
        video = VideoFacts()
        hint = nil
        note = nil
        outputs = []
        job = nil
        thumbnail = nil
        details = primary.map { $0.kind == .folder ? Self.folderDetails($0.url) : "\($0.kind.label) · \(Self.size($0.url))" } ?? ""
        phase = .choosing
        if let primary {
            print("convert: \(urls.count) file(s), first \(primary.name) (\(primary.kind.label))")
            describe(primary)
        }
        updateLayout()
        return true
    }

    /// Shown instead of buttons when there's nothing the app can do to the file.
    var unsupportedMessage: String? {
        guard phase == .choosing, buttons.isEmpty else { return nil }
        return kind == .folder ? "Folders can't be converted yet" : "This file type isn't supported yet"
    }

    /// Thumbnail and details (length, pixel size, pages), read in the background.
    private func describe(_ item: Item) {
        let url = item.url
        loadThumbnail(of: url) { [weak self] in self?.primary?.url == url && self?.phase != .done }
        Task { @MainActor [weak self] in
            // A "movie" file with no picture (an .mp4 of just sound) is audio.
            if item.kind == .video, (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video))?.isEmpty == true {
                guard let self, self.primary?.url == url, self.phase == .choosing else { return }
                self.items = self.items.map { $0.url == url ? Item(url: url, kind: .audio) : $0 }
                self.updateLayout()
                print("convert: \(url.lastPathComponent) has no picture; treating it as audio")
            }
            guard item.kind != .folder else { return }
            let current = self?.items.first { $0.url == url } ?? item
            if current.kind == .video {
                let facts = await Self.videoFacts(url)
                guard let self, self.primary?.url == url else { return }
                self.video = facts
            }
            let extra = await Self.extraDetails(for: current)
            guard let self, self.primary?.url == url else { return }
            let count = self.items.count > 1 ? " · \(self.items.count) files" : ""
            let format = url.pathExtension.isEmpty ? item.kind.label : url.pathExtension.uppercased()
            self.details = ([format, Self.size(url)] + extra).joined(separator: " · ") + count
        }
    }

    /// Quick Look's thumbnail (the Finder icon if there is none); `stillWanted` is asked when it
    /// arrives, since the files on show may have changed by then.
    private func loadThumbnail(of url: URL, stillWanted: @escaping () -> Bool) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self, stillWanted() else { return }
                self.thumbnail = representation?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }

    /// The short edge (after rotation) and whether there's sound.
    private static func videoFacts(_ url: URL) async -> VideoFacts {
        let asset = AVURLAsset(url: url)
        var facts = VideoFacts()
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = size.applying(transform)
            facts.shortEdge = Int(min(abs(shown.width), abs(shown.height)))
        }
        facts.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio))?.isEmpty ?? true)
        return facts
    }

    private static func extraDetails(for item: Item) async -> [String] {
        switch item.kind {
        case .video, .audio:
            guard let seconds = try? await AVURLAsset(url: item.url).load(.duration).seconds, seconds.isFinite else { return [] }
            let total = Int(seconds.rounded())
            return [total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)]
        case .image, .animatedGIF:
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return [] }
            return ["\(w)×\(h)"]
        case .pdf:
            guard let pages = CGPDFDocument(item.url as CFURL)?.numberOfPages else { return [] }
            return [pages == 1 ? "1 page" : "\(pages) pages"]
        default:
            return []
        }
    }

    private static func folderDetails(_ url: URL) -> String {
        let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count) ?? 0
        return "Folder · \(count == 1 ? "1 item" : "\(count) items")"
    }

    private static func size(_ url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: ConversionRunner.size(of: url), countStyle: .file)
    }

    // MARK: Buttons

    /// A button: runs its action, or opens its choices.
    func press(_ button: ActionButton) {
        guard phase == .choosing else { return }
        switch button.kind {
        case .run(let action):
            run(action)
        case .choose:
            hint = nil
            choosing = button
        }
    }

    func pick(_ choice: ActionChoice) {
        guard choice.isEnabled else { return }
        choosing = nil
        run(choice.action)
    }

    /// Back from the choices to the buttons. False if no choices were showing.
    @discardableResult
    func closeChoices() -> Bool {
        guard choosing != nil else { return false }
        choosing = nil
        return true
    }

    /// The number keys: 1 is the first button (or choice), and so on.
    @discardableResult
    func pressNumber(_ number: Int) -> Bool {
        guard phase == .choosing, number >= 1 else { return false }
        if case .choose(let choices)? = choosing?.kind {
            guard number <= choices.count, choices[number - 1].isEnabled else { return false }
            pick(choices[number - 1])
            return true
        }
        guard number <= buttons.count else { return false }
        press(buttons[number - 1])
        return true
    }

    func run(_ action: ConvertAction) {
        guard !isWorking, !items.isEmpty else { return }
        var runnable: [(Item, ConversionPlan)] = []
        var refused: [String] = []
        for item in items {
            switch ConversionPlanner.plan(action, for: item.url, kind: item.kind) {
            case .success(let plan): runnable.append((item, plan))
            case .failure(let error): refused.append(error.message)
            }
        }
        guard let first = runnable.first else {
            hint = Hint(text: refused.first ?? "That doesn't fit this file.", style: .error)
            return
        }
        let source = first.0.url.pathExtension.isEmpty ? first.0.kind.label : first.0.url.pathExtension.uppercased()
        job = Job(from: source, to: first.1.target.label, summary: action.summary)
        choosing = nil
        hint = nil
        note = nil
        outputs = []
        progress.reset()
        phase = .working
        print("convert: \(action.summary) for \(runnable.count) file(s)")

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var made: [ConversionOutput] = []
            var failures: [ConversionFailure] = refused.map { ConversionFailure($0) }
            for (index, (item, plan)) in runnable.enumerated() {
                self.progress.step = runnable.count > 1 ? "\(index + 1) of \(runnable.count)" : nil
                let throttle = ProgressThrottle { fraction in
                    self.progress.fraction = fraction.map { (Double(index) + $0) / Double(runnable.count) }
                }
                do {
                    made.append(try await ConversionRunner.run(plan, on: item.url, progress: throttle.report))
                } catch is CancellationError {
                    print("convert: cancelled")
                    self.phase = .choosing
                    self.hint = Hint(text: "Cancelled. Nothing was saved.", style: .info)
                    self.onFinished?()
                    return
                } catch let failure as ConversionFailure {
                    failures.append(failure)
                    print("convert: \(item.name) — \(failure.message)")
                } catch {
                    failures.append(ConversionFailure("The conversion didn't work."))
                    print("convert: \(item.name) failed — \(error)")
                }
            }
            self.task = nil
            if made.isEmpty {
                self.phase = .choosing
                let first = failures.first ?? ConversionFailure("The conversion didn't work.")
                self.hint = Hint(text: first.message, style: first.isNotice ? .info : .error)
            } else {
                self.outputs = made
                // The ticket becomes the new file: its own thumbnail.
                if let first = made.first, !first.isFolder {
                    self.loadThumbnail(of: first.url) { [weak self] in self?.outputs.first?.url == first.url }
                }
                let problems = failures.count
                self.note = problems > 0 ? "\(problems) of \(self.items.count) not converted" + (failures.first.map { ": \($0.message)" } ?? ".") : nil
                self.phase = .done
            }
            self.onFinished?()
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Afterwards

    func showInFinder() {
        let urls = outputs.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        print("convert: shown in Finder")
    }

    /// Back to the buttons for the same files ("Convert again").
    func again() {
        guard phase == .done else { return }
        outputs = []
        note = nil
        choosing = nil
        phase = .choosing
    }

    func keepInShelf() {
        guard !isWorking else { return }
        let urls = items.map(\.url)
        reset()
        onKeepInShelf?(urls)
    }

    func close() {
        guard !isWorking else { return }
        reset()
        onClose?()
    }

    /// Forgets the files (the island closed). A running conversion carries on.
    func reset() {
        guard !isWorking else { return }
        items = []
        choosing = nil
        video = VideoFacts()
        hint = nil
        note = nil
        outputs = []
        job = nil
        thumbnail = nil
        phase = .idle
    }

    /// One line about the result: "1.8 MB → 420 KB · 77% smaller".
    var resultLine: String {
        guard let first = outputs.first else { return "" }
        if outputs.count > 1 { return "\(outputs.count) files saved beside the originals" }
        let before = ByteCountFormatter.string(fromByteCount: first.sourceBytes, countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: first.bytes, countStyle: .file)
        if first.isFolder { return "\(first.pageCount) pages · \(after)" }
        guard first.sourceBytes > 0 else { return after }
        let saving = Double(first.sourceBytes - first.bytes) / Double(first.sourceBytes)
        return "\(before) → \(after)" + (saving >= 0.01 ? " · \(min(99, Int((saving * 100).rounded())))% smaller" : "")
    }

    var resultShrank: Bool {
        guard let first = outputs.first, outputs.count == 1 else { return false }
        return first.bytes < first.sourceBytes
    }

    /// Rows of buttons (or of choices, or the "isn't supported" line) the panel needs.
    var buttonRows: Int {
        if choosing != nil || buttons.isEmpty { return 1 }
        return ConvertLayout.rows(for: buttons.count)
    }

    private func updateLayout() {
        let height = ConvertLayout.height(phase: phase, rows: buttonRows, hasHint: hint != nil, hasNote: note != nil)
        if layout.height != height { layout.height = height }
        let tint = kind.accent
        if layout.tint != tint { layout.tint = tint }
    }
}

/// The running conversion's progress: nil while it can't tell how far along it is.
final class ConvertProgress: ObservableObject {
    @Published var fraction: Double?
    /// "2 of 3" in a batch.
    @Published var step: String?

    func reset() {
        fraction = 0
        step = nil
    }
}

final class ConvertLayoutState: ObservableObject {
    @Published var height: CGFloat = ConvertLayout.height(phase: .idle, rows: 1)
    /// The dropped file's kind colour, for the island's edge.
    @Published var tint: Color = FileKind.other.accent
}

/// Engines report progress from their own queues, often per frame: this passes on at most one
/// update every 1/30 s (and every switch to or from "can't tell"), on the main thread.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private var wasIndeterminate = false
    private let deliver: @MainActor (Double?) -> Void

    init(_ deliver: @escaping @MainActor (Double?) -> Void) { self.deliver = deliver }

    var report: ProgressHandler {
        { [self] fraction in
            lock.lock()
            let now = Date()
            let switched = (fraction == nil) != wasIndeterminate
            let due = switched || now.timeIntervalSince(last) >= 1.0 / 30 || fraction == 1
            if due { last = now; wasIndeterminate = fraction == nil }
            lock.unlock()
            guard due else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(fraction) } }
        }
    }
}
