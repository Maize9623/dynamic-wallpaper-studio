import AppKit
import Foundation

enum AspectMode: String, Codable, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "完整显示"
        case .fill: return "填满屏幕"
        }
    }

    var detail: String {
        switch self {
        case .fit: return "保持全部画面，边缘可能留白"
        case .fill: return "铺满显示器，画面边缘可能被裁掉"
        }
    }
}

enum ContentMode: String, Codable, CaseIterable, Identifiable {
    case video
    case reader
    case web

    var id: String { rawValue }
}

enum ImportStorageMode: String, Codable, CaseIterable, Identifiable {
    case reference
    case copyToLibrary

    var id: String { rawValue }
}

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

enum BookKind: String, Codable, CaseIterable, Identifiable {
    case text
    case markdown
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "TXT"
        case .markdown: return "Markdown"
        case .pdf: return "PDF"
        }
    }
}

struct WallpaperItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var isFavorite: Bool
    var sourceFilename: String
    var playbackFilename: String
    var posterFilename: String?
    var sourcePath: String
    var isManagedVideo: Bool
    var sourceWidth: Int
    var sourceHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var duration: Double
    var fps: Double
    var codec: String
    var fileSize: Int64
    var sourceSHA256: String
    var hasAudio: Bool

    var isReference: Bool { !isManagedVideo && !sourcePath.isEmpty }

    var resolutionText: String {
        "\(outputWidth) × \(outputHeight)"
    }

    var sourceResolutionText: String {
        "\(sourceWidth) × \(sourceHeight)"
    }

    var durationText: String {
        Self.formatDuration(duration)
    }

    var aspectText: String {
        guard outputHeight > 0 else { return "—" }
        let divisor = Self.greatestCommonDivisor(outputWidth, outputHeight)
        return "\(outputWidth / divisor):\(outputHeight / divisor)"
    }

    static func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        if seconds >= 60 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return "\(seconds) 秒"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        isFavorite: Bool,
        sourceFilename: String,
        playbackFilename: String,
        posterFilename: String? = nil,
        sourcePath: String = "",
        isManagedVideo: Bool = true,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        duration: Double,
        fps: Double,
        codec: String,
        fileSize: Int64,
        sourceSHA256: String,
        hasAudio: Bool = true
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isFavorite = isFavorite
        self.sourceFilename = sourceFilename
        self.playbackFilename = playbackFilename
        self.posterFilename = posterFilename
        self.sourcePath = sourcePath
        self.isManagedVideo = isManagedVideo
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.duration = duration
        self.fps = fps
        self.codec = codec
        self.fileSize = fileSize
        self.sourceSHA256 = sourceSHA256
        self.hasAudio = hasAudio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        sourceFilename = try container.decodeIfPresent(String.self, forKey: .sourceFilename) ?? ""
        playbackFilename = try container.decodeIfPresent(String.self, forKey: .playbackFilename) ?? sourceFilename
        posterFilename = try container.decodeIfPresent(String.self, forKey: .posterFilename)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath) ?? ""
        isManagedVideo = try container.decodeIfPresent(Bool.self, forKey: .isManagedVideo) ?? true
        sourceWidth = try container.decode(Int.self, forKey: .sourceWidth)
        sourceHeight = try container.decode(Int.self, forKey: .sourceHeight)
        outputWidth = try container.decode(Int.self, forKey: .outputWidth)
        outputHeight = try container.decode(Int.self, forKey: .outputHeight)
        duration = try container.decode(Double.self, forKey: .duration)
        fps = try container.decode(Double.self, forKey: .fps)
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? ""
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        sourceSHA256 = try container.decodeIfPresent(String.self, forKey: .sourceSHA256) ?? ""
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? true
    }
}

struct DisplayAssignment: Codable, Hashable {
    var wallpaperID: UUID
    var aspectMode: AspectMode
}

struct WallpaperFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var itemIDs: [UUID]

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), itemIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.itemIDs = itemIDs
    }
}

enum ReaderAdvanceMode: String, Codable, CaseIterable, Identifiable {
    case off
    case page
    case scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .page: return "自动翻页"
        case .scroll: return "自动滚动"
        }
    }
}

struct ReaderPosition: Codable, Hashable {
    var pageIndex = 0
    var scrollOffset = 0.0
    var fontSize = 22.0
    var theme: ReaderTheme = .dark
    var autoTurn = false
    var autoTurnSeconds = 8.0
    var advanceMode: ReaderAdvanceMode = .off
    var scrollSpeed = 36.0
    var autoAdvancePaused = false

    enum CodingKeys: String, CodingKey {
        case pageIndex, scrollOffset, fontSize, theme, autoTurn, autoTurnSeconds, advanceMode, scrollSpeed, autoAdvancePaused
    }

    init(
        pageIndex: Int = 0,
        scrollOffset: Double = 0,
        fontSize: Double = 22,
        theme: ReaderTheme = .dark,
        autoTurn: Bool = false,
        autoTurnSeconds: Double = 8,
        advanceMode: ReaderAdvanceMode = .off,
        scrollSpeed: Double = 36,
        autoAdvancePaused: Bool = false
    ) {
        self.pageIndex = pageIndex
        self.scrollOffset = scrollOffset
        self.fontSize = fontSize
        self.theme = theme
        self.autoTurn = autoTurn
        self.autoTurnSeconds = autoTurnSeconds
        self.advanceMode = advanceMode
        self.scrollSpeed = scrollSpeed
        self.autoAdvancePaused = autoAdvancePaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = try container.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0
        scrollOffset = try container.decodeIfPresent(Double.self, forKey: .scrollOffset) ?? 0
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 22
        theme = try container.decodeIfPresent(ReaderTheme.self, forKey: .theme) ?? .dark
        autoTurn = try container.decodeIfPresent(Bool.self, forKey: .autoTurn) ?? false
        autoTurnSeconds = try container.decodeIfPresent(Double.self, forKey: .autoTurnSeconds) ?? 8
        scrollSpeed = min(max(try container.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 36, 8), 80)
        autoAdvancePaused = try container.decodeIfPresent(Bool.self, forKey: .autoAdvancePaused) ?? false
        if let mode = try container.decodeIfPresent(ReaderAdvanceMode.self, forKey: .advanceMode) {
            advanceMode = mode
        } else {
            advanceMode = autoTurn ? .page : .off
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(scrollOffset, forKey: .scrollOffset)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(theme, forKey: .theme)
        try container.encode(advanceMode == .page, forKey: .autoTurn)
        try container.encode(autoTurnSeconds, forKey: .autoTurnSeconds)
        try container.encode(advanceMode, forKey: .advanceMode)
        try container.encode(scrollSpeed, forKey: .scrollSpeed)
        try container.encode(autoAdvancePaused, forKey: .autoAdvancePaused)
    }
}

struct BookItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var sourcePath: String
    var kind: BookKind
    var isManagedCopy: Bool
    var position: ReaderPosition

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        sourcePath: String,
        kind: BookKind,
        isManagedCopy: Bool,
        position: ReaderPosition = ReaderPosition()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sourcePath = sourcePath
        self.kind = kind
        self.isManagedCopy = isManagedCopy
        self.position = position
    }
}

struct StudioSettings: Codable, Hashable {
    var pauseOnDisplaySleep = true
    var pauseOnSessionLock = true
    var showMenuBarControl = true
    var wallpaperEnabled = true
    var contentMode: ContentMode = .video
    var sceneEnabled = false
    var televisionOff = false
    var bossHidden = false
    var playlistMode = false
    var playlist: [UUID] = []
    var playlistIndex = 0
    var audioMuted = true
    var volume = 70.0
    var playbackSpeed = 1.0
    var webURL = ""
    var bossHotkey = "Control+Option+B"
    var bossHotkeyEnabled = true
    var readerHotkeysEnabled = true
    var readerPreviousHotkey = "Control+Option+Left"
    var readerNextHotkey = "Control+Option+Right"
    var readerPauseHotkey = "Control+Option+Space"
    var shortVideoMode = false
    var keepWebCleanScreen = true
    var importMode: ImportStorageMode = .reference
    var libraryRoot: String?
    var activeBookID: UUID?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnDisplaySleep = try container.decodeIfPresent(Bool.self, forKey: .pauseOnDisplaySleep) ?? true
        pauseOnSessionLock = try container.decodeIfPresent(Bool.self, forKey: .pauseOnSessionLock) ?? true
        showMenuBarControl = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarControl) ?? true
        wallpaperEnabled = try container.decodeIfPresent(Bool.self, forKey: .wallpaperEnabled) ?? true
        contentMode = try container.decodeIfPresent(ContentMode.self, forKey: .contentMode) ?? .video
        sceneEnabled = try container.decodeIfPresent(Bool.self, forKey: .sceneEnabled) ?? false
        televisionOff = try container.decodeIfPresent(Bool.self, forKey: .televisionOff) ?? false
        bossHidden = try container.decodeIfPresent(Bool.self, forKey: .bossHidden) ?? false
        playlistMode = try container.decodeIfPresent(Bool.self, forKey: .playlistMode) ?? false
        playlist = try container.decodeIfPresent([UUID].self, forKey: .playlist) ?? []
        playlistIndex = try container.decodeIfPresent(Int.self, forKey: .playlistIndex) ?? 0
        audioMuted = try container.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? true
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 70
        playbackSpeed = try container.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1
        webURL = try container.decodeIfPresent(String.self, forKey: .webURL) ?? ""
        bossHotkey = try container.decodeIfPresent(String.self, forKey: .bossHotkey) ?? "Control+Option+B"
        bossHotkeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .bossHotkeyEnabled) ?? true
        readerHotkeysEnabled = try container.decodeIfPresent(Bool.self, forKey: .readerHotkeysEnabled) ?? true
        readerPreviousHotkey = try container.decodeIfPresent(String.self, forKey: .readerPreviousHotkey) ?? "Control+Option+Left"
        readerNextHotkey = try container.decodeIfPresent(String.self, forKey: .readerNextHotkey) ?? "Control+Option+Right"
        readerPauseHotkey = try container.decodeIfPresent(String.self, forKey: .readerPauseHotkey) ?? "Control+Option+Space"
        shortVideoMode = try container.decodeIfPresent(Bool.self, forKey: .shortVideoMode) ?? false
        keepWebCleanScreen = try container.decodeIfPresent(Bool.self, forKey: .keepWebCleanScreen) ?? true
        importMode = try container.decodeIfPresent(ImportStorageMode.self, forKey: .importMode) ?? .reference
        libraryRoot = try container.decodeIfPresent(String.self, forKey: .libraryRoot)
        activeBookID = try container.decodeIfPresent(UUID.self, forKey: .activeBookID)
    }
}

struct LibraryState: Codable {
    var schemaVersion = 1
    var wallpapers: [WallpaperItem] = []
    var books: [BookItem] = []
    var folders: [WallpaperFolder] = []
    var assignments: [String: DisplayAssignment] = [:]
    var defaultWallpaperID: UUID?
    var defaultAspectMode: AspectMode = .fit
    var settings = StudioSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        wallpapers = try container.decodeIfPresent([WallpaperItem].self, forKey: .wallpapers) ?? []
        books = try container.decodeIfPresent([BookItem].self, forKey: .books) ?? []
        folders = try container.decodeIfPresent([WallpaperFolder].self, forKey: .folders) ?? []
        assignments = try container.decodeIfPresent([String: DisplayAssignment].self, forKey: .assignments) ?? [:]
        defaultWallpaperID = try container.decodeIfPresent(UUID.self, forKey: .defaultWallpaperID)
        defaultAspectMode = try container.decodeIfPresent(AspectMode.self, forKey: .defaultAspectMode) ?? .fit
        settings = try container.decodeIfPresent(StudioSettings.self, forKey: .settings) ?? StudioSettings()
    }
}

struct DisplayInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let isMain: Bool
    let screenNumber: UInt32

    var resolutionText: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    var subtitle: String {
        isMain ? "主显示器 · \(resolutionText)" : resolutionText
    }
}

enum LibraryFilter: Hashable {
    case all
    case favorites
    case recent
    case folder(UUID)
    case player
    case reader
    case web
    case scene
    case display(String)
    case settings

    var title: String {
        switch self {
        case .all: return "全部壁纸"
        case .favorites: return "收藏"
        case .recent: return "最近导入"
        case .folder: return "子库"
        case .player: return "播放台"
        case .reader: return "电子书"
        case .web: return "网页直播"
        case .scene: return "客厅伪装"
        case .display: return "显示器"
        case .settings: return "设置"
        }
    }

    var isStudio: Bool {
        switch self {
        case .player, .reader, .web, .scene:
            return true
        default:
            return false
        }
    }
}

struct VideoMetadata: Hashable {
    let width: Int
    let height: Int
    let duration: Double
    let fps: Double
    let codec: String
    let fileSize: Int64
    let sha256: String
    let hasAudio: Bool

    var resolutionText: String { "\(width) × \(height)" }
    var isPortrait: Bool { height >= width }
}

struct ImportCandidate: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let suggestedName: String
    let metadata: VideoMetadata

    init(url: URL, suggestedName: String, metadata: VideoMetadata) {
        id = UUID()
        self.url = url
        self.suggestedName = suggestedName
        self.metadata = metadata
    }
}

enum ResolutionChoice: String, CaseIterable, Identifiable {
    case original
    case display
    case fullHD
    case twoK
    case fourK
    case custom

    var id: String { rawValue }

    func title(candidate: ImportCandidate, display: DisplayInfo?) -> String {
        switch self {
        case .original:
            return "保持原始（\(candidate.metadata.resolutionText)）"
        case .display:
            if let display {
                return "匹配 \(display.name)（\(display.resolutionText)）"
            }
            return "匹配当前显示器"
        case .fullHD:
            return candidate.metadata.isPortrait ? "全高清竖屏（1080 × 1920）" : "全高清横屏（1920 × 1080）"
        case .twoK:
            return candidate.metadata.isPortrait ? "2K 竖屏（1440 × 2560）" : "2K 横屏（2560 × 1440）"
        case .fourK:
            return candidate.metadata.isPortrait ? "4K 竖屏（2160 × 3840）" : "4K 横屏（3840 × 2160）"
        case .custom:
            return "自定义…"
        }
    }

    func dimensions(candidate: ImportCandidate, display: DisplayInfo?, customWidth: Int, customHeight: Int) -> (Int, Int) {
        switch self {
        case .original:
            return (candidate.metadata.width, candidate.metadata.height)
        case .display:
            return (display?.pixelWidth ?? candidate.metadata.width, display?.pixelHeight ?? candidate.metadata.height)
        case .fullHD:
            return candidate.metadata.isPortrait ? (1080, 1920) : (1920, 1080)
        case .twoK:
            return candidate.metadata.isPortrait ? (1440, 2560) : (2560, 1440)
        case .fourK:
            return candidate.metadata.isPortrait ? (2160, 3840) : (3840, 2160)
        case .custom:
            return (customWidth, customHeight)
        }
    }
}

struct ImportOptions {
    var name: String
    var resolution: ResolutionChoice = .original
    var customWidth: Int
    var customHeight: Int
    var aspectMode: AspectMode = .fit
    var applyAfterImport = true
    var favorite = false
    var targetDisplayID: String?
    var copyToLibrary = false
}

struct ImportProgressState: Equatable {
    var title: String
    var phase: String
    var fraction: Double
}

struct StudioAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PendingFolderImport: Identifiable, Hashable {
    let id = UUID()
    let directoryURL: URL
    let videos: [URL]
    var existingFolderID: UUID?

    var suggestedName: String {
        directoryURL.lastPathComponent
    }
}

struct PendingPlaylistImport: Identifiable, Hashable {
    let id = UUID()
    let folderName: String
    let itemIDs: [UUID]
}

struct PendingBookImport: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    var kind: BookKind { BookFile.kind(for: url) }
}

struct WebPlaybackSnapshot: Equatable {
    var ready = false
    var live = false
    var paused = true
    var canPlay = false
    var canSeek = false
    var canRate = false
    var muted = true
    var position = 0.0
    var duration = 0.0

    static let empty = WebPlaybackSnapshot()
}

struct PortableManifest: Codable {
    var formatVersion = 1
    var name: String
    var sourceWidth: Int
    var sourceHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var duration: Double
    var fps: Double
    var codec: String
    var videoFilename: String
    var posterFilename: String?
    var preferredAspectMode: AspectMode
}
