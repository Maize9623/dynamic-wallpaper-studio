import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var state = LibraryState()
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var filter: LibraryFilter = .all
    @Published var selectedWallpaperID: UUID?
    @Published var searchText = ""
    @Published var isDropTarget = false
    @Published var pendingImport: ImportCandidate?
    @Published var importProgress: ImportProgressState?
    @Published var alert: StudioAlert?
    @Published var pendingDeletion: WallpaperItem?
    @Published private(set) var isReady = false
    @Published private(set) var loginAtLaunchEnabled = LaunchAtLoginController.isEnabled
    @Published private(set) var storageBytes: Int64 = 0

    let store = LibraryStore()
    let engine = WallpaperEngine()

    var onChange: (() -> Void)?
    var onOpenWindow: (() -> Void)?

    private var importQueue: [URL] = []
    private var isAnalyzing = false

    private init() {}

    var selectedWallpaper: WallpaperItem? {
        guard let selectedWallpaperID else { return nil }
        return state.wallpapers.first(where: { $0.id == selectedWallpaperID })
    }

    var visibleWallpapers: [WallpaperItem] {
        var values: [WallpaperItem]
        switch filter {
        case .all, .settings:
            values = state.wallpapers
        case .favorites:
            values = state.wallpapers.filter(\.isFavorite)
        case .recent:
            values = Array(state.wallpapers.sorted { $0.createdAt > $1.createdAt }.prefix(20))
        case .display(let displayID):
            if let id = state.assignments[displayID]?.wallpaperID,
               let item = state.wallpapers.first(where: { $0.id == id }) {
                values = [item]
            } else {
                values = []
            }
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values = values.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        return values.sorted {
            let left = $0.lastUsedAt ?? $0.createdAt
            let right = $1.lastUsedAt ?? $1.createdAt
            return left > right
        }
    }

    var activeWallpaperIDs: Set<UUID> {
        var ids = Set(displays.compactMap { state.assignments[$0.id]?.wallpaperID })
        if let defaultWallpaperID = state.defaultWallpaperID { ids.insert(defaultWallpaperID) }
        return ids
    }

    var isPaused: Bool { engine.isPaused }

    func start() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            try store.prepareDirectories()
            state = try store.load()
            displays = WallpaperEngine.displays()

            if state.wallpapers.isEmpty {
                try await importStarterWallpaperIfAvailable()
                importProgress = nil
            }

            repairAssignmentsForCurrentDisplays()
            engine.apply(state: state, store: store)
            selectedWallpaperID = state.defaultWallpaperID ?? state.wallpapers.first?.id
            storageBytes = store.librarySize()
            isReady = true
            notifyChanged()
        } catch {
            isReady = true
            alert = StudioAlert(title: "无法打开资料库", message: error.localizedDescription)
        }
    }

    private func importStarterWallpaperIfAvailable() async throws {
        let manager = FileManager.default
        let oldApp = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/竖屏视频壁纸.app/Contents/Resources/Wallpaper.mp4")
        let bundled = Bundle.main.url(forResource: "StarterWallpaper", withExtension: "mp4")
        let source = manager.fileExists(atPath: oldApp.path) ? oldApp : bundled
        guard let source else { return }

        let metadata = try await VideoAnalyzer.analyze(url: source)
        let candidate = ImportCandidate(url: source, suggestedName: "三幕竖屏壁纸", metadata: metadata)
        let options = ImportOptions(
            name: "三幕竖屏壁纸",
            customWidth: metadata.width,
            customHeight: metadata.height,
            aspectMode: .fit,
            applyAfterImport: true,
            favorite: true,
            targetDisplayID: nil
        )
        let item = try await createLibraryItem(candidate: candidate, options: options)
        state.wallpapers = [item]
        state.defaultWallpaperID = item.id
        state.defaultAspectMode = .fit
        for display in displays {
            state.assignments[display.id] = DisplayAssignment(wallpaperID: item.id, aspectMode: .fit)
        }
        try persist()
    }

    func refreshDisplays() {
        displays = WallpaperEngine.displays()
        repairAssignmentsForCurrentDisplays()
        engine.apply(state: state, store: store)
        notifyChanged()
    }

    private func repairAssignmentsForCurrentDisplays() {
        guard let fallbackID = state.defaultWallpaperID ?? state.wallpapers.first?.id else { return }
        if state.defaultWallpaperID == nil { state.defaultWallpaperID = fallbackID }
        for display in displays where state.assignments[display.id] == nil {
            state.assignments[display.id] = DisplayAssignment(
                wallpaperID: fallbackID,
                aspectMode: state.defaultAspectMode
            )
        }
        try? persist()
    }

    func select(_ item: WallpaperItem) {
        selectedWallpaperID = item.id
    }

    func isActive(_ item: WallpaperItem) -> Bool {
        activeWallpaperIDs.contains(item.id)
    }

    func toggleFavorite(_ item: WallpaperItem) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
        state.wallpapers[index].isFavorite.toggle()
        try? persistAndNotify()
    }

    func setWallpaper(_ item: WallpaperItem, targetDisplayID: String? = nil, mode: AspectMode? = nil) {
        let selectedMode = mode ?? currentAspectMode(for: targetDisplayID)
        state.defaultWallpaperID = item.id
        state.defaultAspectMode = selectedMode
        if let targetDisplayID {
            state.assignments[targetDisplayID] = DisplayAssignment(
                wallpaperID: item.id,
                aspectMode: selectedMode
            )
        } else {
            for display in displays {
                state.assignments[display.id] = DisplayAssignment(
                    wallpaperID: item.id,
                    aspectMode: selectedMode
                )
            }
        }
        if let index = state.wallpapers.firstIndex(where: { $0.id == item.id }) {
            state.wallpapers[index].lastUsedAt = Date()
        }
        selectedWallpaperID = item.id
        try? persist()
        engine.apply(state: state, store: store)
        notifyChanged()
    }

    func currentAspectMode(for displayID: String? = nil) -> AspectMode {
        if let displayID, let assignment = state.assignments[displayID] {
            return assignment.aspectMode
        }
        return state.defaultAspectMode
    }

    func setAspectMode(_ mode: AspectMode, displayID: String? = nil) {
        state.defaultAspectMode = mode
        if let displayID {
            if var assignment = state.assignments[displayID] {
                assignment.aspectMode = mode
                state.assignments[displayID] = assignment
            }
        } else {
            for display in displays {
                if var assignment = state.assignments[display.id] {
                    assignment.aspectMode = mode
                    state.assignments[display.id] = assignment
                }
            }
        }
        try? persist()
        engine.apply(state: state, store: store)
        notifyChanged()
    }

    func togglePause() {
        engine.toggleManualPause()
        notifyChanged()
    }

    func systemPause(_ paused: Bool) {
        engine.setSystemPaused(paused)
        notifyChanged()
    }

    func switchFavorite(direction: Int) {
        let favorites = state.wallpapers
            .filter(\.isFavorite)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !favorites.isEmpty else {
            alert = StudioAlert(title: "还没有收藏", message: "点击壁纸卡片上的心形按钮，把常用壁纸加入收藏。")
            return
        }
        let activeID = state.defaultWallpaperID
        let currentIndex = favorites.firstIndex(where: { $0.id == activeID }) ?? (direction > 0 ? -1 : 0)
        let next = (currentIndex + direction + favorites.count) % favorites.count
        setWallpaper(favorites[next])
    }

    func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "导入视频"
        panel.prompt = "导入"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [
            .mpeg4Movie,
            .quickTimeMovie,
            UTType(filenameExtension: "m4v") ?? .movie,
            UTType(exportedAs: "local.baiyaoyu.dynamicwallpaper", conformingTo: .package)
        ]
        if panel.runModal() == .OK {
            enqueueImports(panel.urls)
        }
    }

    func enqueueImports(_ urls: [URL]) {
        importQueue.append(contentsOf: urls)
        processNextImportIfNeeded()
    }

    private func processNextImportIfNeeded() {
        guard pendingImport == nil, importProgress == nil, !isAnalyzing, !importQueue.isEmpty else { return }
        let url = importQueue.removeFirst()
        if url.pathExtension.lowercased() == PortablePackageService.packageExtension {
            importPackage(url)
            return
        }

        isAnalyzing = true
        importProgress = ImportProgressState(title: url.deletingPathExtension().lastPathComponent, phase: "正在读取视频", fraction: 0.08)
        Task {
            do {
                let metadata = try await VideoAnalyzer.analyze(url: url)
                if let duplicate = state.wallpapers.first(where: { $0.sourceSHA256 == metadata.sha256 }) {
                    throw VideoServiceError.duplicate(duplicate)
                }
                let name = url.deletingPathExtension().lastPathComponent
                pendingImport = ImportCandidate(url: url, suggestedName: name, metadata: metadata)
                importProgress = nil
                isAnalyzing = false
            } catch {
                importProgress = nil
                isAnalyzing = false
                alert = StudioAlert(title: "无法导入", message: error.localizedDescription)
                processNextImportIfNeeded()
            }
        }
    }

    func cancelPendingImport() {
        pendingImport = nil
        processNextImportIfNeeded()
    }

    func confirmImport(candidate: ImportCandidate, options: ImportOptions) {
        pendingImport = nil
        let dimensions = options.resolution.dimensions(
            candidate: candidate,
            display: displayForImport(options.targetDisplayID),
            customWidth: options.customWidth,
            customHeight: options.customHeight
        )
        guard dimensions.0 >= 480,
              dimensions.1 >= 480,
              dimensions.0.isMultiple(of: 2),
              dimensions.1.isMultiple(of: 2) else {
            alert = StudioAlert(title: "分辨率无效", message: VideoServiceError.invalidDimensions.localizedDescription)
            processNextImportIfNeeded()
            return
        }

        importProgress = ImportProgressState(title: options.name, phase: "正在复制原视频", fraction: 0.12)
        Task {
            do {
                var mutableOptions = options
                mutableOptions.customWidth = dimensions.0
                mutableOptions.customHeight = dimensions.1
                let item = try await createLibraryItem(candidate: candidate, options: mutableOptions)
                importProgress = ImportProgressState(title: options.name, phase: "正在加入资料库", fraction: 0.92)
                state.wallpapers.insert(item, at: 0)
                selectedWallpaperID = item.id
                if options.applyAfterImport {
                    setWallpaper(item, targetDisplayID: options.targetDisplayID, mode: options.aspectMode)
                } else {
                    try persist()
                }
                storageBytes = store.librarySize()
                importProgress = nil
                notifyChanged()
                processNextImportIfNeeded()
            } catch {
                importProgress = nil
                alert = StudioAlert(title: "制作失败", message: "\(error.localizedDescription)\n\n原视频没有被修改。")
                processNextImportIfNeeded()
            }
        }
    }

    private func createLibraryItem(candidate: ImportCandidate, options: ImportOptions) async throws -> WallpaperItem {
        let id = UUID()
        let temporary = store.stagingURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let final = store.directory(for: id)
        let manager = FileManager.default
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let sourceExtension = candidate.url.pathExtension.isEmpty ? "mp4" : candidate.url.pathExtension.lowercased()
            let sourceName = "original.\(sourceExtension)"
            let stagedSource = temporary.appendingPathComponent(sourceName)
            try manager.copyItem(at: candidate.url, to: stagedSource)

            await updateImportProgress(title: options.name, phase: "正在生成缩略图", fraction: 0.28)
            let posterName = "poster.jpg"
            let stagedPoster = temporary.appendingPathComponent(posterName)
            try VideoTranscoder.makePoster(inputURL: stagedSource, outputURL: stagedPoster)

            let targetWidth = options.customWidth
            let targetHeight = options.customHeight
            let needsTranscode = targetWidth != candidate.metadata.width || targetHeight != candidate.metadata.height
            let playbackName: String
            if needsTranscode {
                await updateImportProgress(title: options.name, phase: "正在转换视频", fraction: 0.48)
                playbackName = "wallpaper-\(targetWidth)x\(targetHeight).mp4"
                try await VideoTranscoder.transcode(
                    inputURL: stagedSource,
                    outputURL: temporary.appendingPathComponent(playbackName),
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    mode: options.aspectMode
                )
            } else {
                playbackName = sourceName
            }

            let playbackURL = temporary.appendingPathComponent(playbackName)
            let size = try playbackURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let item = WallpaperItem(
                id: id,
                name: options.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? candidate.suggestedName : options.name,
                createdAt: Date(),
                lastUsedAt: options.applyAfterImport ? Date() : nil,
                isFavorite: options.favorite,
                sourceFilename: sourceName,
                playbackFilename: playbackName,
                posterFilename: posterName,
                sourceWidth: candidate.metadata.width,
                sourceHeight: candidate.metadata.height,
                outputWidth: targetWidth,
                outputHeight: targetHeight,
                duration: candidate.metadata.duration,
                fps: candidate.metadata.fps,
                codec: needsTranscode ? "H.264" : candidate.metadata.codec,
                fileSize: Int64(size),
                sourceSHA256: candidate.metadata.sha256
            )
            if manager.fileExists(atPath: final.path) {
                try manager.removeItem(at: final)
            }
            try manager.moveItem(at: temporary, to: final)
            return item
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private func updateImportProgress(title: String, phase: String, fraction: Double) async {
        importProgress = ImportProgressState(title: title, phase: phase, fraction: fraction)
        await Task.yield()
    }

    private func displayForImport(_ id: String?) -> DisplayInfo? {
        if let id, let display = displays.first(where: { $0.id == id }) { return display }
        return displays.first(where: \.isMain) ?? displays.first
    }

    private func importPackage(_ url: URL) {
        importProgress = ImportProgressState(title: url.deletingPathExtension().lastPathComponent, phase: "正在读取壁纸包", fraction: 0.1)
        Task {
            do {
                let (manifest, videoURL, sourcePoster) = try PortablePackageService.readPackage(url)
                let metadata = try await VideoAnalyzer.analyze(url: videoURL)
                if let duplicate = state.wallpapers.first(where: { $0.sourceSHA256 == metadata.sha256 }) {
                    throw VideoServiceError.duplicate(duplicate)
                }
                let candidate = ImportCandidate(url: videoURL, suggestedName: manifest.name, metadata: metadata)
                var options = ImportOptions(
                    name: manifest.name,
                    customWidth: manifest.outputWidth,
                    customHeight: manifest.outputHeight,
                    aspectMode: manifest.preferredAspectMode,
                    applyAfterImport: true,
                    favorite: true,
                    targetDisplayID: nil
                )
                options.resolution = .custom
                var item = try await createLibraryItem(candidate: candidate, options: options)

                if let sourcePoster, FileManager.default.fileExists(atPath: sourcePoster.path) {
                    let target = store.directory(for: item.id).appendingPathComponent("poster.jpg")
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: sourcePoster, to: target)
                    item.posterFilename = "poster.jpg"
                }

                state.wallpapers.insert(item, at: 0)
                selectedWallpaperID = item.id
                setWallpaper(item, mode: manifest.preferredAspectMode)
                storageBytes = store.librarySize()
                importProgress = nil
                processNextImportIfNeeded()
            } catch {
                importProgress = nil
                alert = StudioAlert(title: "无法导入壁纸包", message: error.localizedDescription)
                processNextImportIfNeeded()
            }
        }
    }

    func exportPackage(_ item: WallpaperItem) {
        let panel = NSSavePanel()
        panel.title = "导出动态壁纸包"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizedFilename(item.name) + ".dwallpaper"
        let packageType = UTType(exportedAs: "local.baiyaoyu.dynamicwallpaper", conformingTo: .package)
        panel.allowedContentTypes = [packageType]
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != PortablePackageService.packageExtension {
            url.appendPathExtension(PortablePackageService.packageExtension)
        }
        do {
            try PortablePackageService.export(
                item: item,
                preferredMode: state.defaultAspectMode,
                store: store,
                destination: url
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            alert = StudioAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    func reveal(_ item: WallpaperItem) {
        NSWorkspace.shared.activateFileViewerSelecting([store.playbackURL(for: item)])
    }

    func requestDelete(_ item: WallpaperItem) {
        pendingDeletion = item
    }

    func confirmDelete(_ item: WallpaperItem) {
        let wasActive = activeWallpaperIDs.contains(item.id)
        state.wallpapers.removeAll { $0.id == item.id }
        state.assignments = state.assignments.filter { $0.value.wallpaperID != item.id }

        if state.defaultWallpaperID == item.id {
            state.defaultWallpaperID = state.wallpapers.first?.id
        }
        if let fallback = state.defaultWallpaperID {
            for display in displays where state.assignments[display.id] == nil {
                state.assignments[display.id] = DisplayAssignment(
                    wallpaperID: fallback,
                    aspectMode: state.defaultAspectMode
                )
            }
        }

        try? store.removeFiles(for: item)
        try? persist()
        if wasActive { engine.apply(state: state, store: store) }
        selectedWallpaperID = state.wallpapers.first?.id
        pendingDeletion = nil
        storageBytes = store.librarySize()
        notifyChanged()
    }

    func rename(_ item: WallpaperItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = state.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
        state.wallpapers[index].name = trimmed
        try? persistAndNotify()
    }

    func updateSettings(_ update: (inout StudioSettings) -> Void) {
        update(&state.settings)
        try? persistAndNotify()
    }

    func setLoginAtLaunch(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            loginAtLaunchEnabled = LaunchAtLoginController.isEnabled
        } catch {
            loginAtLaunchEnabled = LaunchAtLoginController.isEnabled
            alert = StudioAlert(title: "无法更新登录启动", message: error.localizedDescription)
        }
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([store.baseURL])
    }

    func openStudio() {
        onOpenWindow?()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate() {
        engine.stop()
    }

    private func persist() throws {
        try store.save(state)
    }

    private func persistAndNotify() throws {
        try persist()
        notifyChanged()
    }

    private func notifyChanged() {
        objectWillChange.send()
        onChange?()
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
