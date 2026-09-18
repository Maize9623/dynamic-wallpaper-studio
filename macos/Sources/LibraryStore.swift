import Foundation

final class LibraryStore {
    static let bundleIdentifier = "local.baiyaoyu.dynamicwallpaperstudio"
    static let rootPointerFileName = "library-root.txt"

    private(set) var baseURL: URL
    private(set) var mediaURL: URL
    private(set) var stagingURL: URL
    private(set) var booksURL: URL
    private(set) var webProfileURL: URL
    private(set) var logsURL: URL
    private(set) var stateURL: URL

    let defaultRootURL: URL
    let pointerURL: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        defaultRootURL = support.appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
        pointerURL = defaultRootURL.appendingPathComponent(Self.rootPointerFileName)
        let resolved = Self.resolveRoot(defaultRoot: defaultRootURL, pointerURL: pointerURL)
        baseURL = resolved
        mediaURL = resolved.appendingPathComponent("Media", isDirectory: true)
        stagingURL = resolved.appendingPathComponent("Staging", isDirectory: true)
        booksURL = resolved.appendingPathComponent("Books", isDirectory: true)
        webProfileURL = resolved.appendingPathComponent("WebProfile", isDirectory: true)
        logsURL = resolved.appendingPathComponent("Logs", isDirectory: true)
        stateURL = resolved.appendingPathComponent("Library.json")
    }

    func prepareDirectories() throws {
        try ensureWritableLayout(baseURL)
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
        do {
            return try decoder.decode(LibraryState.self, from: data)
        } catch {
            let backup = stateURL.deletingLastPathComponent()
                .appendingPathComponent("Library.broken-\(Self.stamp()).json")
            try? FileManager.default.copyItem(at: stateURL, to: backup)
            throw error
        }
    }

    func save(_ state: LibraryState) throws {
        var writable = state
        writable.settings.libraryRoot = baseURL.path
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(writable)
        try data.write(to: stateURL, options: .atomic)
    }

    func relocate(to newRoot: URL) throws {
        let resolved = newRoot.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path == baseURL.path { return }
        try ensureWritableLayout(resolved)
        try FileManager.default.createDirectory(at: defaultRootURL, withIntermediateDirectories: true)
        try resolved.path.write(to: pointerURL, atomically: true, encoding: .utf8)
        applyRoot(resolved)
        try prepareDirectories()
    }

    func directory(for id: UUID) -> URL {
        mediaURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func bookDirectory(for id: UUID) -> URL {
        booksURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for item: WallpaperItem, filename: String) -> URL {
        directory(for: item.id).appendingPathComponent(filename)
    }

    func sourceURL(for item: WallpaperItem) -> URL {
        if !item.sourcePath.isEmpty {
            return URL(fileURLWithPath: item.sourcePath)
        }
        return url(for: item, filename: item.sourceFilename)
    }

    func playbackURL(for item: WallpaperItem) -> URL {
        if item.isManagedVideo, !item.playbackFilename.isEmpty {
            return url(for: item, filename: item.playbackFilename)
        }
        if !item.sourcePath.isEmpty {
            return URL(fileURLWithPath: item.sourcePath)
        }
        if !item.playbackFilename.isEmpty {
            return url(for: item, filename: item.playbackFilename)
        }
        return sourceURL(for: item)
    }

    func posterURL(for item: WallpaperItem) -> URL? {
        guard let posterFilename = item.posterFilename else { return nil }
        return url(for: item, filename: posterFilename)
    }

    func bookURL(for item: BookItem) -> URL {
        if item.sourcePath.hasPrefix("/") {
            return URL(fileURLWithPath: item.sourcePath)
        }
        return baseURL.appendingPathComponent(item.sourcePath)
    }

    func relativeToRoot(_ url: URL) -> String {
        let root = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        if url.path.hasPrefix(root) {
            return String(url.path.dropFirst(root.count))
        }
        return url.path
    }

    func removeFiles(for item: WallpaperItem) throws {
        let target = directory(for: item.id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    func removeManagedBook(_ item: BookItem) throws {
        guard item.isManagedCopy else { return }
        let target = bookDirectory(for: item.id)
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
        let webPrefix = webProfileURL.path
        for case let url as URL in enumerator {
            if url.path.hasPrefix(webPrefix) { continue }
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

    private func applyRoot(_ root: URL) {
        baseURL = root
        mediaURL = root.appendingPathComponent("Media", isDirectory: true)
        stagingURL = root.appendingPathComponent("Staging", isDirectory: true)
        booksURL = root.appendingPathComponent("Books", isDirectory: true)
        webProfileURL = root.appendingPathComponent("WebProfile", isDirectory: true)
        logsURL = root.appendingPathComponent("Logs", isDirectory: true)
        stateURL = root.appendingPathComponent("Library.json")
    }

    private func ensureWritableLayout(_ root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Media", isDirectory: true), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Staging", isDirectory: true), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Books", isDirectory: true), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("WebProfile", isDirectory: true), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Logs", isDirectory: true), withIntermediateDirectories: true)
        let probe = root.appendingPathComponent(".write-test-\(UUID().uuidString)")
        try Data("ok".utf8).write(to: probe)
        try manager.removeItem(at: probe)
    }

    private static func resolveRoot(defaultRoot: URL, pointerURL: URL) -> URL {
        guard let text = try? String(contentsOf: pointerURL, encoding: .utf8) else {
            return defaultRoot
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultRoot }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
