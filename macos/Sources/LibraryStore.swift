import Foundation

final class LibraryStore {
    static let bundleIdentifier = "local.baiyaoyu.dynamicwallpaperstudio"

    let baseURL: URL
    let mediaURL: URL
    let stagingURL: URL
    let stateURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseURL = support.appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
        mediaURL = baseURL.appendingPathComponent("Media", isDirectory: true)
        stagingURL = baseURL.appendingPathComponent("Staging", isDirectory: true)
        stateURL = baseURL.appendingPathComponent("Library.json")
    }

    func prepareDirectories() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try manager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try cleanupStaging()
    }

    func cleanupStaging() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: stagingURL.path) else { return }
        for url in try manager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) {
            try? manager.removeItem(at: url)
        }
    }

    func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return LibraryState()
        }
        let data = try Data(contentsOf: stateURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryState.self, from: data)
    }

    func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func directory(for id: UUID) -> URL {
        mediaURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for item: WallpaperItem, filename: String) -> URL {
        directory(for: item.id).appendingPathComponent(filename)
    }

    func sourceURL(for item: WallpaperItem) -> URL {
        url(for: item, filename: item.sourceFilename)
    }

    func playbackURL(for item: WallpaperItem) -> URL {
        url(for: item, filename: item.playbackFilename)
    }

    func posterURL(for item: WallpaperItem) -> URL? {
        guard let posterFilename = item.posterFilename else { return nil }
        return url(for: item, filename: posterFilename)
    }

    func removeFiles(for item: WallpaperItem) throws {
        let target = directory(for: item.id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    func librarySize() -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            size += Int64(values.fileSize ?? 0)
        }
        return size
    }

    func uniqueFilename(preferred: String, in directory: URL) -> String {
        let manager = FileManager.default
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        var candidate = preferred
        var counter = 2
        while manager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            candidate = "\(base)-\(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }
}
