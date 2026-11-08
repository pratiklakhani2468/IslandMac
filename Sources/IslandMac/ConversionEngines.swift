import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A conversion that didn't work, in words for the island.
struct ConversionFailure: Error, Equatable {
    let message: String
    /// Nothing went wrong; there was just nothing worth saving ("Already well compressed").
    let isNotice: Bool
    init(_ message: String, isNotice: Bool = false) {
        self.message = message
        self.isNotice = isNotice
    }
}

/// What a finished conversion made.
struct ConversionOutput: Equatable {
    let url: URL
    let bytes: Int64
    let sourceBytes: Int64
    /// A folder of pages rather than a single file.
    let isFolder: Bool
    var pageCount = 1
}

typealias ProgressHandler = (Double?) -> Void

/// Runs one plan on one file: writes into a hidden temporary file beside the original, then moves
/// it to a name that's free, so the original is never overwritten and nothing half-written is
/// left behind if it fails or is cancelled. Everything runs on this Mac with macOS's own
/// frameworks (or LibreOffice, if installed, for office documents); nothing touches the network.
enum ConversionRunner {
    /// Compressing has to save at least this much, or nothing is saved.
    static let minimumSaving = 0.05

    static func run(_ plan: ConversionPlan, on source: URL, progress: @escaping ProgressHandler) async throws -> ConversionOutput {
        let sourceBytes = Self.size(of: source)
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = plan.target.fileExtension
        var pageCount = 1
        if case .pdfToImages = plan { pageCount = PDFDocument(url: source)?.pageCount ?? 1 }
        // A PDF of several pages becomes a folder named after it, one picture per page.
        let isFolder = pageCount > 1
        let name = isFolder ? base : base + (Self.tag(for: plan).map { " (\($0))" } ?? "")
        let temp = folder.appendingPathComponent(".\(base).islandmac-\(UUID().uuidString.prefix(8))" + (isFolder ? "" : ".\(ext)"))
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            try await write(plan, source: source, to: temp, progress: progress)
        } catch let error as ConversionFailure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.explain(error, folder: folder)
        }
        try Task.checkCancellation()

        let bytes = Self.size(of: temp)
        if plan.isCompression, Double(bytes) > Double(sourceBytes) * (1 - minimumSaving) {
            print("convert: \(source.lastPathComponent) only went from \(sourceBytes) to \(bytes) bytes; nothing saved")
            throw ConversionFailure("Already well compressed", isNotice: true)
        }
        let destination = OutputPlacement.free(name: name, ext: isFolder ? nil : ext, in: folder, avoiding: source)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            throw Self.explain(error, folder: folder)
        }
        print("convert: \(source.lastPathComponent) → \(destination.lastPathComponent) (\(sourceBytes) → \(bytes) bytes)")
        return ConversionOutput(url: destination, bytes: bytes, sourceBytes: sourceBytes, isFolder: isFolder, pageCount: pageCount)
    }

    private static func write(_ plan: ConversionPlan, source: URL, to temp: URL, progress: @escaping ProgressHandler) async throws {
        switch plan {
        case .remux(let format, let mute):
            do {
                try await VideoTools.remux(source, to: temp, fileType: format.avFileType, mute: mute, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The streams don't fit the new container as they are (ProRes in MP4…): re-encode.
                print("convert: stream copy failed (\(error.localizedDescription)); re-encoding")
                try? FileManager.default.removeItem(at: temp)
                var settings = VideoTools.Settings(fileType: format.avFileType)
                settings.mute = mute
                try await VideoTools.transcode(source, to: temp, settings: settings, progress: progress)
            }
        case .compressVideo(let format, let level):
            var settings = VideoTools.Settings(fileType: format.avFileType)
            // Fewer bits per pixel, and for the stronger levels fewer pixels too.
            settings.bitsPerPixel = [CompressLevel.light: 0.09, .medium: 0.06, .strong: 0.04][level]!
            settings.shortEdge = [CompressLevel.light: nil, .medium: 1080, .strong: 720][level]!
            settings.audioCompression = [CompressLevel.light: 0.9, .medium: 0.7, .strong: 0.5][level]!
            try await VideoTools.transcode(source, to: temp, settings: settings, progress: progress)
        case .resizeVideo(let format, let edge):
            var settings = VideoTools.Settings(fileType: format.avFileType)
            settings.shortEdge = edge
            try await VideoTools.transcode(source, to: temp, settings: settings, progress: progress)
        case .videoToGIF:
            try await GIFTools.fromVideo(source, to: temp, progress: progress)
        case .gifToVideo(let format):
            try await GIFTools.toVideo(source, to: temp, fileType: format.avFileType, progress: progress)
        case .compressGIF(let level):
            try await GIFTools.compress(source, to: temp, scale: [CompressLevel.light: 0.85, .medium: 0.7, .strong: 0.5][level]!, progress: progress)
        case .convertImage(let format):
            progress(nil)
            try await Task.detached(priority: .userInitiated) { try ImageWriter.convert(source, to: temp, format: format) }.value
        case .compressImage(let format, let level):
            progress(nil)
            try await Task.detached(priority: .userInitiated) {
                if format == .png {
                    try PNGCompressor.compress(source, to: temp, level: level)
                } else {
                    try ImageWriter.compressLossy(source, to: temp, format: format, level: level)
                }
            }.value
        case .pdfToImages(let format):
            try await PDFTools.pages(of: source, to: temp, format: format, progress: progress)
        case .pdfToWord:
            try await PDFTools.toWord(source, to: temp, progress: progress)
        case .compressPDF:
            progress(nil)
            try await Task.detached(priority: .userInitiated) { try PDFTools.compress(source, to: temp) }.value
        case .documentToPDF:
            progress(nil)
            try await DocumentTools.toPDF(source, to: temp)
        case .audioToM4A:
            var settings = VideoTools.Settings(fileType: .m4a)
            settings.includeVideo = false
            settings.audioBitrate = 192_000
            try await VideoTools.transcode(source, to: temp, settings: settings, progress: progress)
        case .compressAudio(let level):
            var settings = VideoTools.Settings(fileType: .m4a)
            settings.includeVideo = false
            settings.audioCompression = [CompressLevel.light: 0.8, .medium: 0.6, .strong: 0.4][level]!
            try await VideoTools.transcode(source, to: temp, settings: settings, progress: progress)
        }
    }

    /// A word or two in the new file's name when it keeps the original's format ("photo (compressed).jpg").
    private static func tag(for plan: ConversionPlan) -> String? {
        switch plan {
        case .compressVideo, .compressGIF, .compressImage, .compressPDF, .compressAudio: "compressed"
        case .resizeVideo(_, let edge): "\(edge)p"
        case .remux(_, let mute): mute ? "no audio" : nil
        default: nil
        }
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory == true {
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let file = files?.nextObject() as? URL { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    /// File-system errors in plain words (never a raw error string).
    private static func explain(_ error: Error, folder: URL) -> ConversionFailure {
        let ns = error as NSError
        print("convert: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        let denied = (ns.domain == NSCocoaErrorDomain && [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(ns.code))
            || (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains($0.code) } == true
        if denied {
            return ConversionFailure("macOS didn't let IslandMac save in “\(folder.lastPathComponent)”. Allow it in System Settings › Privacy & Security › Files & Folders.")
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return ConversionFailure("There isn't enough disk space.")
        }
        if ns.domain == AVFoundationErrorDomain {
            return ConversionFailure("macOS couldn't read or encode this file.")
        }
        return ConversionFailure("The conversion didn't work.")
    }
}

/// Free names next to the original: "clip.gif", then "clip 2.gif", "clip 3.gif"… Never the original.
enum OutputPlacement {
    static func free(name: String, ext: String?, in folder: URL, avoiding source: URL) -> URL {
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? name : "\(name) \(n)"
            let url = folder.appendingPathComponent(stem, isDirectory: ext == nil)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var n = 1
        while true {
            let url = candidate(n)
            if !FileManager.default.fileExists(atPath: url.path), url.standardizedFileURL != source.standardizedFileURL { return url }
            n += 1
        }
    }
}

extension TargetFormat {
    var avFileType: AVFileType {
        switch self {
        case .mov: .mov
        case .m4a: .m4a
        default: .mp4
        }
    }

    var utType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .gif: .gif
        case .png: .png
        case .jpg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        case .m4a: .mpeg4Audio
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        }
    }
}

// MARK: - Video and audio

/// Video and audio with AVFoundation: a stream copy when nothing needs re-encoding, otherwise
/// H.264 + AAC through a reader and writer (which is what makes sizes and bitrates controllable).
enum VideoTools {
    struct Settings {
        var fileType: AVFileType
        var includeVideo = true
        var shortEdge: Int?
        /// Average video bitrate; when nil, from `bitsPerPixel`.
        var videoBitrate: Int?
        var bitsPerPixel = 0.11
        var mute = false
        var audioBitrate = 160_000
        /// Keep the picture exactly as it is (only the sound is re-encoded).
        var copyVideo = false
        /// Aim the sound at this fraction of its current bitrate (rather than at `audioBitrate`).
        var audioCompression: Double?
    }

    /// An AAC setup the encoder accepts for about `bitrate`: stereo down to 64 kbit/s, then mono,
    /// then mono at half the sample rate for very small targets.
    static func aacFormat(for bitrate: Int) -> (sampleRate: Int, channels: Int, bitrate: Int) {
        if bitrate >= 64_000 { return (44_100, 2, min(bitrate / 16_000 * 16_000, 256_000)) }
        if bitrate >= 32_000 { return (44_100, 1, bitrate / 8_000 * 8_000) }
        return (22_050, 1, max(bitrate / 4_000 * 4_000, 16_000))
    }

    /// Sound formats an MP4 can hold; anything else (PCM, for one) has to be re-encoded.
    private static let mp4AudioFormats: Set<FourCharCode> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEG4AAC_ELD, kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatAppleLossless, kAudioFormatOpus,
        kAudioFormatMPEGD_USAC, kAudioFormatFLAC,
    ]

    /// Container change, or dropping the sound, without re-encoding (except sound an MP4 can't hold,
    /// which becomes AAC while the picture is still copied as is).
    static func remux(_ source: URL, to output: URL, fileType: AVFileType, mute: Bool, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        if fileType == .mp4, !mute {
            var needsAAC = false
            for track in try await asset.loadTracks(withMediaType: .audio) {
                for format in try await track.load(.formatDescriptions) where !mp4AudioFormats.contains(CMFormatDescriptionGetMediaSubType(format)) {
                    needsAAC = true
                }
            }
            if needsAAC {
                print("convert: sound can't go in an MP4 as is; copying the picture, re-encoding the sound")
                var settings = Settings(fileType: fileType)
                settings.copyVideo = true
                try await transcode(source, to: output, settings: settings, progress: progress)
                return
            }
        }
        var exported: AVAsset = asset
        if mute {
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            for track in try await asset.loadTracks(withMediaType: .video) {
                guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                copy.preferredTransform = try await track.load(.preferredTransform)
            }
            exported = composition
        }
        guard let session = AVAssetExportSession(asset: exported, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionFailure("This video can't be copied as is.")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        try await export(session, progress: progress)
    }

    static func export(_ session: AVAssetExportSession, progress: @escaping ProgressHandler) async throws {
        let watcher = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { watcher.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        if Task.isCancelled || session.status == .cancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw session.error ?? ConversionFailure("The video couldn't be saved.")
        }
    }

    static func transcode(_ source: URL, to output: URL, settings: Settings, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let videoTrack = settings.includeVideo ? try await asset.loadTracks(withMediaType: .video).first : nil
        if settings.includeVideo, videoTrack == nil { throw ConversionFailure("This video has no picture.") }
        let audioTrack = settings.mute ? nil : try await asset.loadTracks(withMediaType: .audio).first
        if !settings.includeVideo, audioTrack == nil { throw ConversionFailure("There's no sound in this file.") }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = true
        var lanes: [Lane] = []

        if let videoTrack, settings.copyVideo {
            let (transform, formats) = try await videoTrack.load(.preferredTransform, .formatDescriptions)
            let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw ConversionFailure("This video's picture can't go in that format.") }
            reader.add(readerOutput)
            writer.add(input)
            lanes.append(Lane(output: readerOutput, input: input, isVideo: true))
        } else if let videoTrack {
            let (natural, transform, fps) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let size = Self.outputSize(natural: natural, transform: transform, shortEdge: settings.shortEdge)
            let rate = Double(fps > 0 ? min(fps, 60) : 30)
            let bitrate = settings.videoBitrate ?? Int(Double(size.width * size.height) * rate * settings.bitsPerPixel)
            let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            readerOutput.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(bitrate, 40_000),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: Int(rate * 2),
                ],
            ])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw ConversionFailure("macOS can't re-encode this video.") }
            reader.add(readerOutput)
            writer.add(input)
            lanes.append(Lane(output: readerOutput, input: input, isVideo: true))
            print("convert: H.264 \(size.width)×\(size.height) at \(bitrate / 1000) kbit/s")
        }
        if let audioTrack {
            var target = settings.audioBitrate
            if let fraction = settings.audioCompression {
                let current = Double(try await audioTrack.load(.estimatedDataRate))
                target = Int(min(256_000, max(32_000, (current > 0 ? current : 160_000) * fraction)))
            }
            let aac = Self.aacFormat(for: target)
            // The reader hands over plain samples already at the encoder's rate and channel count.
            let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: aac.sampleRate, AVNumberOfChannelsKey: aac.channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: aac.sampleRate, AVNumberOfChannelsKey: aac.channels,
                AVEncoderBitRateKey: aac.bitrate,
            ])
            print("convert: AAC \(aac.channels == 2 ? "stereo" : "mono") \(aac.sampleRate) Hz at \(aac.bitrate / 1000) kbit/s")
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(readerOutput), writer.canAdd(input) else { throw ConversionFailure("macOS can't re-encode this sound.") }
            reader.add(readerOutput)
            writer.add(input)
            lanes.append(Lane(output: readerOutput, input: input, isVideo: false))
        }

        guard reader.startReading() else { throw reader.error ?? ConversionFailure("This file couldn't be read.") }
        guard writer.startWriting() else { throw writer.error ?? ConversionFailure("The new file couldn't be written.") }
        writer.startSession(atSourceTime: .zero)

        let cancelled = CancelFlag()
        let length = max(duration, 0.001)
        // The video lane reports progress; an audio-only file reports from its audio.
        let reportingVideo = lanes.contains { $0.isVideo }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                for lane in lanes {
                    group.enter()
                    let queue = DispatchQueue(label: "islandmac.convert.\(lane.isVideo ? "video" : "audio")")
                    var done = false
                    lane.input.requestMediaDataWhenReady(on: queue) {
                        while !done && lane.input.isReadyForMoreMediaData {
                            guard !cancelled.isSet, let sample = lane.output.copyNextSampleBuffer() else {
                                done = true
                                lane.input.markAsFinished()
                                group.leave()
                                return
                            }
                            if lane.isVideo == reportingVideo {
                                progress(min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / length, 0.99))
                            }
                            if !lane.input.append(sample) {
                                done = true
                                lane.input.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }
                group.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ConversionFailure("This file couldn't be read.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionFailure("The new file couldn't be written.") }
        progress(1)
    }

    /// One track being re-encoded: what it's read from and written to. Each is only touched on its
    /// own queue, once encoding starts.
    private struct Lane: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
    }

    /// The encoded size, in the track's own orientation (the rotation stays as metadata): never
    /// larger than the source, even numbers for H.264.
    static func outputSize(natural: CGSize, transform: CGAffineTransform, shortEdge: Int?) -> (width: Int, height: Int) {
        let display = natural.applying(transform)
        let short = min(abs(display.width), abs(display.height))
        var factor = 1.0
        if let shortEdge, Double(short) > Double(shortEdge) { factor = Double(shortEdge) / Double(short) }
        func even(_ v: CGFloat) -> Int { max(2, Int((Double(v) * factor / 2).rounded()) * 2) }
        return (even(abs(natural.width)), even(abs(natural.height)))
    }

}

/// Set from a cancellation handler, read on the encoding queues.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - GIF

enum GIFTools {
    /// The longest a GIF made from a video may be, in frames.
    static let maxFrames = 600

    static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Frames from the video at a rate that suits its length, 480 px on the long edge.
    static func fromVideo(_ source: URL, to output: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ConversionFailure("This video has no picture.") }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = natural.applying(transform)
        let long = max(abs(display.width), abs(display.height))
        let fps: Double = duration <= 6 ? 15 : duration <= 15 ? 12 : duration <= 40 ? 10 : 8
        guard duration * fps <= Double(maxFrames) else {
            throw ConversionFailure("That's too long for a GIF (over \(Int(Double(maxFrames) / fps)) seconds). Trim it first.")
        }
        try await render(asset, duration: duration, fps: fps, longEdge: min(Double(long), 480), to: output) { progress($0) }
    }

    private static func render(_ asset: AVAsset, duration: Double, fps: Double, longEdge: Double, to output: URL, progress: (Double) -> Void) async throws {
        let count = max(1, Int(duration * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionFailure("The GIF couldn't be written.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            CGImageDestinationAddImage(destination, image, frame)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure("The GIF couldn't be written.") }
    }

    private struct Frames {
        let source: CGImageSource
        let count: Int
        let delays: [Double]
        let size: CGSize
    }

    private static func frames(of url: URL) throws -> Frames {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionFailure("This GIF couldn't be read.") }
        let count = CGImageSourceGetCount(source)
        let delays = (0..<count).map { i -> Double in
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // Browsers treat tiny delays as 0.1 s; so does this.
            return delay < 0.02 ? 0.1 : delay
        }
        return Frames(source: source, count: count, delays: delays, size: CGSize(width: first.width, height: first.height))
    }

    /// An animated GIF as an H.264 video (on white, since video has no transparency).
    static func toVideo(_ source: URL, to output: URL, fileType: AVFileType, progress: @escaping ProgressHandler) async throws {
        let frames = try frames(of: source)
        // H.264 needs even dimensions.
        let width = max(2, Int((frames.size.width / 2).rounded()) * 2)
        let height = max(2, Int((frames.size.height / 2).rounded()) * 2)

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(Int(Double(width * height) * 30 * 0.12), 200_000)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ConversionFailure("The video couldn't be written.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionFailure("The video couldn't be written.") }
        writer.startSession(atSourceTime: .zero)

        var time = 0.0
        for i in 0..<frames.count {
            if Task.isCancelled { writer.cancelWriting(); throw CancellationError() }
            guard let image = CGImageSourceCreateImageAtIndex(frames.source, i, nil), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.setFillColor(.white)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += frames.delays[i]
            progress(Double(i + 1) / Double(frames.count))
        }
        input.markAsFinished()
        // Hold the last frame for its full delay.
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionFailure("The video couldn't be written.") }
    }

    /// The same animation, smaller: frames scaled by `scale`, the original timing.
    static func compress(_ source: URL, to output: URL, scale: Double, progress: @escaping ProgressHandler) async throws {
        let frames = try frames(of: source)
        let edge = max(2, Double(max(frames.size.width, frames.size.height)) * scale)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ConversionFailure("The GIF couldn't be written.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames.count {
            try Task.checkCancellation()
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: edge] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(frames.source, i, options) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frames.delays[i]]] as CFDictionary)
            progress(Double(i + 1) / Double(frames.count))
            if i % 10 == 0 { await Task.yield() }
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure("The GIF couldn't be written.") }
    }
}

// MARK: - Images

enum ImageWriter {
    static let canWriteHEIC = ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(UTType.heic.identifier)

    /// Another format at full quality: upright (EXIF orientation applied), same pixels; JPG gets
    /// a white background, since it has no transparency.
    static func convert(_ source: URL, to output: URL, format: TargetFormat) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              var image = thumbnail(imageSource, longEdge: Double(max(width, height))) else {
            throw ConversionFailure("This picture couldn't be read.")
        }
        if format == .heic, !canWriteHEIC { throw ConversionFailure("This Mac can't write HEIC. Try JPG.") }
        if format == .jpg, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            image = flattened(image) ?? image
        }
        try encode(image, as: format, quality: 0.92).write(to: output)
    }

    /// Quality for each level when a JPG or HEIC is compressed (it stays JPG or HEIC).
    static func quality(for level: CompressLevel) -> Double {
        [CompressLevel.light: 0.9, .medium: 0.8, .strong: 0.65][level]!
    }

    /// The same JPG or HEIC re-encoded at a lower quality, with its metadata (orientation, colour
    /// profile, camera details) carried over.
    static func compressLossy(_ source: URL, to output: URL, format: TargetFormat, level: CompressLevel) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 else {
            throw ConversionFailure("This picture couldn't be read.")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionFailure("\(format.label) can't be written here.")
        }
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, [kCGImageDestinationLossyCompressionQuality: quality(for: level)] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure("\(format.label) couldn't be written.") }
    }

    static func encode(_ image: CGImage, as format: TargetFormat, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ConversionFailure("\(format.label) can't be written here.")
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if format == .tiff { options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] } // LZW
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailure("\(format.label) couldn't be written.") }
        return data as Data
    }

    /// Upright (EXIF orientation applied) and no longer than `longEdge`; never enlarged.
    private static func thumbnail(_ source: CGImageSource, longEdge: Double) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longEdge.rounded())),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// JPG has no transparency: put the picture on white.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

// MARK: - PDF

enum PDFTools {
    /// Images re-saved as JPEG at screen resolution (PDFKit's own option).
    static func compress(_ source: URL, to output: URL) throws {
        guard let document = PDFDocument(url: source) else { throw ConversionFailure("This PDF couldn't be read.") }
        if document.isLocked { throw ConversionFailure("This PDF is password-protected.") }
        guard document.write(to: output, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]) else {
            throw ConversionFailure("The PDF couldn't be written.")
        }
    }

    /// The PDF's text as a Word document: each page's text with its fonts (as PDFKit reads them),
    /// in order, with a page break between pages. A PDF with no text at all (a scan) is refused
    /// rather than saved as an empty document. No OCR, nothing leaves the Mac.
    static func toWord(_ source: URL, to output: URL, progress: @escaping ProgressHandler) async throws {
        guard let document = PDFDocument(url: source) else { throw ConversionFailure("This PDF couldn't be read.") }
        if document.isLocked { throw ConversionFailure("This PDF is password-protected.") }
        let count = document.pageCount
        let combined = NSMutableAttributedString()
        var hasText = false
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { continue }
            let text = page.attributedString ?? NSAttributedString()
            if !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
            if i > 0 {
                // A form feed: the Word writer turns it into a real page break.
                combined.append(NSAttributedString(string: "\u{000C}"))
            }
            combined.append(text)
            progress(Double(i + 1) / Double(count))
            if i % 8 == 0 { await Task.yield() }
        }
        guard hasText else { throw ConversionFailure("This PDF is scanned. Text can't be extracted.") }
        let data = try combined.data(from: NSRange(location: 0, length: combined.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: output)
    }

    /// Each page as a picture at twice its size (144 dpi): one file for a one-page PDF, otherwise
    /// a folder named after the PDF, with "Page 01.png"… inside.
    static func pages(of source: URL, to output: URL, format: TargetFormat, progress: @escaping ProgressHandler) async throws {
        guard let document = PDFDocument(url: source) else { throw ConversionFailure("This PDF couldn't be read.") }
        if document.isLocked { throw ConversionFailure("This PDF is password-protected.") }
        let count = document.pageCount
        guard count > 0 else { throw ConversionFailure("This PDF has no pages.") }
        if count > 1 { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false) }
        let digits = String(count).count
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            let size = CGSize(width: (rotated ? bounds.height : bounds.width) * 2, height: (rotated ? bounds.width : bounds.height) * 2)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let data = try ImageWriter.encode(cgImage, as: format, quality: 0.9)
            let file = count == 1 ? output
                : output.appendingPathComponent("Page \(String(repeating: "0", count: digits - String(i + 1).count))\(i + 1)").appendingPathExtension(format.fileExtension)
            try data.write(to: file)
            progress(Double(i + 1) / Double(count))
            await Task.yield()
        }
    }
}

// MARK: - Documents

/// Documents to PDF: with LibreOffice when it's installed (Word, PowerPoint, Excel and
/// OpenDocument at full fidelity), otherwise macOS's own text system (Word, RTF, OpenDocument
/// text and plain text; simpler layout, no PowerPoint or Excel).
enum DocumentTools {
    /// LibreOffice's command-line program, if it's installed.
    static var libreOffice: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/LibreOffice.app/Contents/MacOS/soffice", home + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func toPDF(_ source: URL, to output: URL) async throws {
        let ext = source.pathExtension.lowercased()
        if let soffice = libreOffice {
            try await viaLibreOffice(soffice, source: source, output: output)
        } else if FileKind.libreOfficeOnly.contains(ext) {
            throw ConversionFailure("PowerPoint and Excel files need LibreOffice. Install it once (brew install --cask libreoffice), then try again.")
        } else {
            try await MainActor.run { try builtIn(source, output: output) }
        }
    }

    /// `soffice --headless --convert-to pdf`, with a private profile so it never collides with an
    /// open LibreOffice window.
    private static func viaLibreOffice(_ soffice: URL, source: URL, output: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("islandmac-office-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let process = Process()
        process.executableURL = soffice
        process.arguments = ["-env:UserInstallation=\(work.appendingPathComponent("profile").absoluteString)",
                             "--headless", "--norestore", "--nolockcheck", "--nodefault",
                             "--convert-to", "pdf", "--outdir", work.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        print("convert: LibreOffice → PDF for \(source.lastPathComponent)")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        let made = work.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: made.path) else {
            throw ConversionFailure("LibreOffice couldn't convert this document.")
        }
        try FileManager.default.moveItem(at: made, to: output)
    }

    /// Lays the text out on pages with AppKit and prints them to a PDF file.
    @MainActor
    private static func builtIn(_ source: URL, output: URL) throws {
        let ext = source.pathExtension.lowercased()
        let text: NSAttributedString
        switch ext {
        case "txt", "text", "md", "markdown":
            guard let string = (try? String(contentsOf: source, encoding: .utf8)) ?? (try? String(contentsOf: source, encoding: .macOSRoman)) else {
                throw ConversionFailure("This text file couldn't be read.")
            }
            // A real document font: the system UI font has a private name that other apps reading
            // the PDF can't resolve (they fall back to Times).
            let font = NSFont(name: "Helvetica Neue", size: 11) ?? NSFont.userFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11)
            text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black])
        default:
            let types: [String: NSAttributedString.DocumentType] = ["docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd]
            guard let type = types[ext], let read = try? NSAttributedString(url: source, options: [.documentType: type], documentAttributes: nil) else {
                throw ConversionFailure("This document couldn't be read without LibreOffice.")
            }
            text = read
        }

        let a4 = Locale.current.region.map { !["US", "CA", "MX", "PH"].contains($0.identifier) } ?? true
        let info = NSPrintInfo(dictionary: [.jobSavingURL: output])
        info.jobDisposition = .save
        info.paperSize = a4 ? NSSize(width: 595, height: 842) : NSSize(width: 612, height: 792)
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = .zero
        view.backgroundColor = .white
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            view.frame.size.height = max(layout.usedRect(for: container).height, 10)
        }
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionFailure("The PDF couldn't be written.")
        }
    }
}
