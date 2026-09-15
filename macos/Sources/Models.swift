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

struct WallpaperItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var lastUsedAt: Date?
    var isFavorite: Bool
    var sourceFilename: String
    var playbackFilename: String
    var posterFilename: String?
    var sourceWidth: Int
    var sourceHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var duration: Double
    var fps: Double
    var codec: String
    var fileSize: Int64
    var sourceSHA256: String

    var resolutionText: String {
        "\(outputWidth) × \(outputHeight)"
    }

    var sourceResolutionText: String {
        "\(sourceWidth) × \(sourceHeight)"
    }

    var durationText: String {
        let seconds = max(0, Int(duration.rounded()))
        if seconds >= 60 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return "\(seconds) 秒"
    }

    var aspectText: String {
        guard outputHeight > 0 else { return "—" }
        let divisor = Self.greatestCommonDivisor(outputWidth, outputHeight)
        return "\(outputWidth / divisor):\(outputHeight / divisor)"
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(a, 1)
    }
}

struct DisplayAssignment: Codable, Hashable {
    var wallpaperID: UUID
    var aspectMode: AspectMode
}

struct StudioSettings: Codable, Hashable {
    var pauseOnDisplaySleep = true
    var pauseOnSessionLock = true
    var showMenuBarControl = true
}

struct LibraryState: Codable {
    var schemaVersion = 1
    var wallpapers: [WallpaperItem] = []
    var assignments: [String: DisplayAssignment] = [:]
    var defaultWallpaperID: UUID?
    var defaultAspectMode: AspectMode = .fit
    var settings = StudioSettings()
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
    case display(String)
    case settings

    var title: String {
        switch self {
        case .all: return "全部壁纸"
        case .favorites: return "收藏"
        case .recent: return "最近导入"
        case .display: return "显示器"
        case .settings: return "设置"
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
