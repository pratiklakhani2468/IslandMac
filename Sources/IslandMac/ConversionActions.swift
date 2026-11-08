import Foundation
import UniformTypeIdentifiers

/// What a dropped file is, as far as converting it goes.
enum FileKind: Equatable {
    case video, animatedGIF, image, audio, pdf, document, folder, other

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, ext != "rtfd" {
            return .folder
        }
        if Self.documentExtensions.contains(ext) { return .document }
        guard let type = UTType(filenameExtension: ext) ?? (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .gif) { return GIFTools.isAnimated(url) ? .animatedGIF : .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        return .other
    }

    /// Documents that can become a PDF (built in, or with LibreOffice).
    static let documentExtensions: Set<String> = [
        "doc", "docx", "odt", "rtf", "rtfd", "txt", "text", "md", "markdown",
        "ppt", "pptx", "odp", "xls", "xlsx", "ods", "csv",
    ]
    /// The ones only LibreOffice can open.
    static let libreOfficeOnly: Set<String> = ["ppt", "pptx", "odp", "xls", "xlsx", "ods", "csv"]

    var label: String {
        switch self {
        case .video: "Video"
        case .animatedGIF: "Animated GIF"
        case .image: "Image"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Document"
        case .folder: "Folder"
        case .other: "File"
        }
    }
}

/// Formats the converter can write.
enum TargetFormat: String, CaseIterable {
    case mp4, mov, gif, png, jpg, heic, tiff, pdf, m4a, docx

    var fileExtension: String { rawValue }
    var label: String { self == .docx ? "Word" : rawValue.uppercased() }
}

/// How hard to compress. Compressing always keeps the file's format.
enum CompressLevel: String, CaseIterable, Equatable {
    case light, medium, strong

    var title: String { rawValue.capitalized }
}

/// One thing the converter can do to a file, chosen with a button.
enum ConvertAction: Equatable {
    /// A different format.
    case convert(TargetFormat)
    /// The same format, smaller.
    case compress(CompressLevel)
    /// A video without its sound (same format).
    case removeAudio
    /// A video at a smaller resolution (same format): the short edge, in pixels.
    case resolution(Int)

    /// A few words for the progress line.
    var summary: String {
        switch self {
        case .convert(let format): format.label
        case .compress(let level): "Compress · \(level.title)"
        case .removeAudio: "Remove audio"
        case .resolution(let edge): "\(edge)p"
        }
    }
}

/// A button in the panel: it either does something, or opens a few choices (Compress → Light,
/// Medium, Strong).
struct ActionButton: Identifiable, Equatable {
    enum Kind: Equatable {
        case run(ConvertAction)
        case choose([ActionChoice])
    }

    let title: String
    let kind: Kind
    var id: String { title }
}

struct ActionChoice: Identifiable, Equatable {
    let title: String
    let action: ConvertAction
    /// Unavailable choices show, dimmed (a resolution the video is already below).
    var isEnabled = true
    var id: String { title }
}

/// What the app knows about a video once it has looked inside it.
struct VideoFacts: Equatable {
    var shortEdge: Int?
    var hasAudio = true
}

/// One concrete job for one file.
enum ConversionPlan: Equatable {
    /// Same streams in another container, or with the sound dropped: fast, no re-encoding.
    case remux(TargetFormat, mute: Bool)
    case compressVideo(TargetFormat, CompressLevel)
    case resizeVideo(TargetFormat, shortEdge: Int)
    case videoToGIF
    case gifToVideo(TargetFormat)
    case compressGIF(CompressLevel)
    case convertImage(TargetFormat)
    case compressImage(TargetFormat, CompressLevel)
    case pdfToImages(TargetFormat)
    case pdfToWord
    case compressPDF
    case documentToPDF
    case audioToM4A
    case compressAudio(CompressLevel)

    var target: TargetFormat {
        switch self {
        case .remux(let f, _), .compressVideo(let f, _), .resizeVideo(let f, _), .gifToVideo(let f), .convertImage(let f),
             .compressImage(let f, _), .pdfToImages(let f): f
        case .videoToGIF, .compressGIF: .gif
        case .pdfToWord: .docx
        case .compressPDF, .documentToPDF: .pdf
        case .audioToM4A, .compressAudio: .m4a
        }
    }

    /// Compressing: the result only counts if it's clearly smaller than the original.
    var isCompression: Bool {
        switch self {
        case .compressVideo, .compressGIF, .compressImage, .compressPDF, .compressAudio: true
        default: false
        }
    }
}

/// The buttons each kind of file gets, and what each one does to a given file. Only actions the
/// app can really do appear; compressing always keeps the format.
enum ConversionPlanner {
    static let resolutions = [1080, 720, 480]

    static func buttons(for url: URL, kind: FileKind, video: VideoFacts = VideoFacts()) -> [ActionButton] {
        let ext = Self.normalized(url.pathExtension)
        func convert(_ format: TargetFormat) -> ActionButton { ActionButton(title: format.label, kind: .run(.convert(format))) }
        let compress = ActionButton(title: "Compress", kind: .choose(CompressLevel.allCases.map { ActionChoice(title: $0.title, action: .compress($0)) }))
        switch kind {
        case .video:
            var buttons: [ActionButton] = []
            if ext != "mp4" { buttons.append(convert(.mp4)) }
            buttons += [convert(.gif), compress]
            if video.hasAudio { buttons.append(ActionButton(title: "Remove audio", kind: .run(.removeAudio))) }
            let sizes = resolutions.map { edge in
                ActionChoice(title: "\(edge)p", action: .resolution(edge), isEnabled: video.shortEdge.map { $0 > edge } ?? true)
            }
            if sizes.contains(where: \.isEnabled) { buttons.append(ActionButton(title: "Resolution", kind: .choose(sizes))) }
            return buttons
        case .animatedGIF:
            return [convert(.mp4), compress]
        case .image:
            switch ext {
            case "png": return [convert(.jpg), compress]
            case "jpg": return [convert(.png), compress]
            case "heic": return [convert(.jpg), convert(.png), compress]
            default: return [convert(.png), convert(.jpg)]
            }
        case .audio:
            return ext == "m4a" ? [compress] : [convert(.m4a)]
        case .pdf:
            return [convert(.docx), convert(.png), convert(.jpg), ActionButton(title: "Compress", kind: .run(.compress(.medium)))]
        case .document:
            return [convert(.pdf)]
        case .folder, .other:
            return []
        }
    }

    static func plan(_ action: ConvertAction, for url: URL, kind: FileKind) -> Result<ConversionPlan, PlanError> {
        let ext = Self.normalized(url.pathExtension)
        let own = TargetFormat(rawValue: ext)
        switch (kind, action) {
        case (.video, .convert(.gif)):
            return .success(.videoToGIF)
        case (.video, .convert(let format)) where format == .mp4 || format == .mov:
            return format == own ? .failure(.init("It's already \(format.label).")) : .success(.remux(format, mute: false))
        case (.video, .compress(let level)):
            return .success(.compressVideo(Self.videoContainer(ext), level))
        case (.video, .removeAudio):
            return .success(.remux(Self.videoContainer(ext), mute: true))
        case (.video, .resolution(let edge)):
            return .success(.resizeVideo(Self.videoContainer(ext), shortEdge: edge))
        case (.animatedGIF, .convert(let format)) where format == .mp4 || format == .mov:
            return .success(.gifToVideo(format))
        case (.animatedGIF, .compress(let level)):
            return .success(.compressGIF(level))
        case (.image, .convert(let format)) where [.png, .jpg, .heic, .tiff].contains(format):
            return format == own ? .failure(.init("It's already \(format.label).")) : .success(.convertImage(format))
        case (.image, .compress(let level)):
            guard let own, [.png, .jpg, .heic].contains(own) else { return .failure(.init("\(ext.uppercased()) can't be compressed here.")) }
            return .success(.compressImage(own, level))
        case (.pdf, .convert(.docx)):
            return .success(.pdfToWord)
        case (.pdf, .convert(let format)) where format == .png || format == .jpg:
            return .success(.pdfToImages(format))
        case (.pdf, .compress):
            return .success(.compressPDF)
        case (.document, .convert(.pdf)):
            return .success(.documentToPDF)
        case (.audio, .convert(.m4a)):
            return .success(.audioToM4A)
        case (.audio, .compress(let level)) where ext == "m4a":
            return .success(.compressAudio(level))
        case (.folder, _):
            return .failure(.init("Folders can't be converted."))
        default:
            return .failure(.init("This file type isn't supported for that."))
        }
    }

    /// "jpeg" is "jpg", "heif" is "heic".
    static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "heif": "heic"
        case "tif": "tiff"
        case let other: other
        }
    }

    /// Video edits keep the container: MOV stays MOV; anything else becomes MP4.
    private static func videoContainer(_ ext: String) -> TargetFormat { ext == "mov" ? .mov : .mp4 }
}

struct PlanError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
