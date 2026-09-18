import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VideoServiceError: LocalizedError {
    case unreadable
    case noVideoTrack
    case protectedContent
    case invalidDimensions
    case duplicate(WallpaperItem)
    case exportFailed(String)
    case invalidPackage
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取这个视频。文件可能已损坏或尚未完整下载。"
        case .noVideoTrack:
            return "文件中没有可播放的视频轨道。"
        case .protectedContent:
            return "这个视频受版权保护，无法制作成动态壁纸。"
        case .invalidDimensions:
            return "输出宽度和高度必须是大于等于 480 的偶数。"
        case .duplicate(let item):
            return "这个视频已经在资料库中：\(item.name)"
        case .exportFailed(let reason):
            return "视频转换失败：\(reason)"
        case .invalidPackage:
            return "这个动态壁纸包缺少必要文件或格式不正确。"
        case .unsupportedFile:
            return "请选择 MP4、MOV、M4V 视频或 .dwallpaper 壁纸包。"
        }
    }
}

enum VideoAnalyzer {
    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func collectVideos(in root: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return isSupported(root) ? [root] : []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var videos: [URL] = []
        for case let file as URL in enumerator {
            guard isSupported(file) else { continue }
            videos.append(file)
        }
        return videos.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    static func validateSupportedURL(_ url: URL) throws {
        if url.pathExtension.lowercased() == "dwallpaper" { return }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw VideoServiceError.unsupportedFile
        }
    }

    static func analyze(url: URL) async throws -> VideoMetadata {
        try validateSupportedURL(url)
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let protected = try await asset.load(.hasProtectedContent)
        guard playable else { throw VideoServiceError.unreadable }
        guard !protected else { throw VideoServiceError.protectedContent }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoServiceError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let duration = try await asset.load(.duration).seconds
        let fps = Double(try await track.load(.nominalFrameRate))
        let descriptions = try await track.load(.formatDescriptions)
        let codec = descriptions.first.map { description in
            fourCCString(CMFormatDescriptionGetMediaSubType(description))
        } ?? "未知"
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let sha = try sha256(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        return VideoMetadata(
            width: Int(oriented.width.rounded()),
            height: Int(oriented.height.rounded()),
            duration: duration,
            fps: fps,
            codec: codec,
            fileSize: Int64(values.fileSize ?? 0),
            sha256: sha,
            hasAudio: !audioTracks.isEmpty
        )
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知"
    }

    private static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum VideoTranscoder {
    static func makePoster(inputURL: URL, outputURL: URL) throws {
        let asset = AVURLAsset(url: inputURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        var actual = CMTime.zero
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: time, actualTime: &actual)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw VideoServiceError.exportFailed("无法创建预览图")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw VideoServiceError.exportFailed("无法写入预览图")
        }
    }

    static func transcode(
        inputURL: URL,
        outputURL: URL,
        targetWidth: Int,
        targetHeight: Int,
        mode: AspectMode
    ) async throws {
        guard targetWidth >= 480,
              targetHeight >= 480,
              targetWidth.isMultiple(of: 2),
              targetHeight.isMultiple(of: 2) else {
            throw VideoServiceError.invalidDimensions
        }

        let asset = AVURLAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoServiceError.noVideoTrack
        }

        let naturalSize = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let minimumFrameDuration = try await sourceTrack.load(.minFrameDuration)
        let orientedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let fitScale = min(targetSize.width / orientedRect.width, targetSize.height / orientedRect.height)
        let fillScale = max(targetSize.width / orientedRect.width, targetSize.height / orientedRect.height)
        let scale = mode == .fit ? fitScale : fillScale
        let fittedSize = CGSize(width: orientedRect.width * scale, height: orientedRect.height * scale)
        let offset = CGPoint(
            x: (targetSize.width - fittedSize.width) / 2,
            y: (targetSize.height - fittedSize.height) / 2
        )

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw VideoServiceError.exportFailed("无法创建视频轨道")
        }
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceTrack,
            at: .zero
        )

        let normalize = preferredTransform.concatenating(
            CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY)
        )
        let finalTransform = normalize
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = targetSize
        let secondsPerFrame = minimumFrameDuration.seconds
        videoComposition.frameDuration = minimumFrameDuration.isValid && secondsPerFrame > 0
            ? minimumFrameDuration
            : CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoServiceError.exportFailed("当前 Mac 不支持这个编码任务")
        }
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume(returning: ())
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: VideoServiceError.exportFailed(
                        exporter.error?.localizedDescription ?? "未知错误"
                    ))
                }
            }
        }
    }
}

enum PortablePackageService {
    static let packageExtension = "dwallpaper"
    private static let maximumManifestBytes: Int64 = 1 * 1024 * 1024

    static func export(
        item: WallpaperItem,
        preferredMode: AspectMode,
        store: LibraryStore,
        destination: URL
    ) throws {
        let manager = FileManager.default
        let temporary = store.stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let playbackSource = store.playbackURL(for: item)
        let playbackExtension = playbackSource.pathExtension.isEmpty ? "mp4" : playbackSource.pathExtension
        let videoName = "wallpaper.\(playbackExtension)"
        try manager.copyItem(at: playbackSource, to: temporary.appendingPathComponent(videoName))

        var posterName: String?
        if let sourcePoster = store.posterURL(for: item), manager.fileExists(atPath: sourcePoster.path) {
            posterName = "poster.jpg"
            try manager.copyItem(at: sourcePoster, to: temporary.appendingPathComponent(posterName!))
        }

        let manifest = PortableManifest(
            name: item.name,
            sourceWidth: item.sourceWidth,
            sourceHeight: item.sourceHeight,
            outputWidth: item.outputWidth,
            outputHeight: item.outputHeight,
            duration: item.duration,
            fps: item.fps,
            codec: item.codec,
            videoFilename: videoName,
            posterFilename: posterName,
            preferredAspectMode: preferredMode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)

        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: temporary, to: destination)
    }

    static func readPackage(_ url: URL) throws -> (PortableManifest, URL, URL?) {
        let packageRoot = try validatedPackageRoot(url)
        guard let manifestURL = try validatedPackageFile(
            named: "manifest.json",
            inside: packageRoot,
            required: true
        ) else {
            throw VideoServiceError.invalidPackage
        }

        let manifestValues = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(manifestValues.fileSize ?? 0) <= maximumManifestBytes else {
            throw VideoServiceError.invalidPackage
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PortableManifest.self, from: data)
        guard manifest.formatVersion == 1,
              let videoURL = try validatedPackageFile(
                named: manifest.videoFilename,
                inside: packageRoot,
                required: true
              ) else {
            throw VideoServiceError.invalidPackage
        }

        let posterURL: URL?
        if let posterFilename = manifest.posterFilename {
            posterURL = try validatedPackageFile(
                named: posterFilename,
                inside: packageRoot,
                required: false
            )
        } else {
            posterURL = nil
        }

        return (manifest, videoURL, posterURL)
    }

    /// Resolves the package once and rejects a package whose top-level entry is
    /// itself a symbolic link. Symlinks in an ancestor (for example `/var`) are
    /// resolved so that the containment check below remains reliable.
    private static func validatedPackageRoot(_ url: URL) throws -> URL {
        let manager = FileManager.default
        guard url.isFileURL,
              (try? manager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw VideoServiceError.invalidPackage
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VideoServiceError.invalidPackage
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Returns only a direct, regular child of the package. Exported packages
    /// already use leaf filenames (`wallpaper.mp4`, `poster.jpg`), so this keeps
    /// the existing format compatible while preventing path traversal.
    private static func validatedPackageFile(
        named filename: String,
        inside packageRoot: URL,
        required: Bool
    ) throws -> URL? {
        let manager = FileManager.default
        let path = filename as NSString
        guard !filename.isEmpty,
              !filename.contains("\0"),
              !path.isAbsolutePath,
              path.lastPathComponent == filename,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\") else {
            throw VideoServiceError.invalidPackage
        }

        let candidate = packageRoot
            .appendingPathComponent(filename, isDirectory: false)
            .standardizedFileURL

        // Check the unresolved entry first, including dangling symlinks.
        if (try? manager.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            throw VideoServiceError.invalidPackage
        }

        guard manager.fileExists(atPath: candidate.path) else {
            if required { throw VideoServiceError.invalidPackage }
            return nil
        }

        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VideoServiceError.invalidPackage
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = packageRoot.path.hasSuffix("/")
            ? packageRoot.path
            : packageRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(rootPrefix) else {
            throw VideoServiceError.invalidPackage
        }
        return resolvedCandidate
    }
}
