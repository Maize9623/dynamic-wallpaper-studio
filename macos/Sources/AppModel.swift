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
    @Published var selectedBookID: UUID?
    @Published var searchText = ""
    @Published var isDropTarget = false
    @Published var pendingImport: ImportCandidate?
    @Published var importProgress: ImportProgressState?
    @Published var alert: StudioAlert?
    @Published var pendingDeletion: WallpaperItem?
    @Published var pendingBookDeletion: BookItem?
    @Published var pendingBookImport: PendingBookImport?
    @Published var pendingFolderImport: PendingFolderImport?
    @Published var pendingPlaylistImport: PendingPlaylistImport?
    @Published var pendingFolderDeletion: WallpaperFolder?
    @Published var pendingFolderRename: WallpaperFolder?
    @Published var isCreatingFolder = false
    @Published var draftFolderName = ""
    @Published var selectedPlaylistIDs: Set<UUID> = []
    @Published private(set) var isReady = false
    @Published private(set) var loginAtLaunchEnabled = LaunchAtLoginController.isEnabled
    @Published private(set) var storageBytes: Int64 = 0
    @Published var pendingSceneEnabled = false
    @Published var draftBossHotkey = "Control+Option+B"
    @Published var draftReaderPreviousHotkey = "Control+Option+Left"
    @Published var draftReaderNextHotkey = "Control+Option+Right"
    @Published var draftReaderPauseHotkey = "Control+Option+Space"
    @Published var playbackPosition = 0.0
    @Published var playbackDuration = 0.0
    @Published var isSeeking = false
    @Published var webSnapshot = WebPlaybackSnapshot.empty
    @Published private(set) var readerProgressPercent = 0

    let store = LibraryStore()
    let engine = WallpaperEngine()
    let web = WebSession()

    var onChange: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onHotkeyChange: (() -> Void)?
    var onWebStudioRefresh: (() -> Void)?

    var webStudioHost: NSView?
    private var webStudio: WebStudioWindowController?
    private var importQueue: [URL] = []
    private var folderImportQueue: [URL] = []
    private var importTargetFolderID: UUID?
    private var isAnalyzing = false

    private init() {
        engine.web = web
        engine.onMediaEnded = { [weak self] in
            self?.handleMediaEnded()
        }
        engine.onApplied = { [weak self] in
            self?.hookReader()
            Task { @MainActor in
                guard let self, self.state.settings.contentMode == .reader else { return }
                self.loadActiveBook()
            }
        }
        web.onLocationChanged = { [weak self] in
            guard let self else { return }
            self.state.settings.webURL = self.web.currentURL
            self.notifyChanged()
        }
        web.onCleanScreenChanged = { [weak self] clean in
            guard let self, self.state.settings.keepWebCleanScreen != clean else { return }
            self.state.settings.keepWebCleanScreen = clean
            try? self.persistAndNotify()
        }
    }

    var selectedWallpaper: WallpaperItem? {
        guard let selectedWallpaperID else { return nil }
        return state.wallpapers.first(where: { $0.id == selectedWallpaperID })
    }

    var selectedBook: BookItem? {
        if let selectedBookID, let book = state.books.first(where: { $0.id == selectedBookID }) {
            return book
        }
        return activeBook
    }

    var activeBook: BookItem? {
        if let id = state.settings.activeBookID {
            return state.books.first(where: { $0.id == id })
        }
        return state.books.first
    }

    var visibleWallpapers: [WallpaperItem] {
        var values: [WallpaperItem]
        var preserveOrder = false
        switch filter {
        case .all, .settings, .player, .reader, .web, .scene:
            values = state.wallpapers
        case .favorites:
            values = state.wallpapers.filter(\.isFavorite)
        case .recent:
            values = Array(state.wallpapers.sorted { $0.createdAt > $1.createdAt }.prefix(20))
            preserveOrder = true
        case .folder(let folderID):
            values = folder(folderID)?.itemIDs.compactMap { id in
                state.wallpapers.first(where: { $0.id == id })
            } ?? []
            preserveOrder = true
        case .display(let displayID):
            if let id = state.assignments[displayID]?.wallpaperID,
               let item = state.wallpapers.first(where: { $0.id == id }) {
                values = [item]
            } else {
                values = []
            }
        }

        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values = values.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        if preserveOrder { return values }
        return values.sorted {
            let left = $0.lastUsedAt ?? $0.createdAt
            let right = $1.lastUsedAt ?? $1.createdAt
            return left > right
        }
    }

    var filterTitle: String {
        if case .folder(let id) = filter {
            return folder(id)?.name ?? "子库"
        }
        return filter.title
    }

    func folder(_ id: UUID) -> WallpaperFolder? {
        state.folders.first(where: { $0.id == id })
    }

    func foldersContaining(_ item: WallpaperItem) -> [WallpaperFolder] {
        state.folders.filter { $0.itemIDs.contains(item.id) }
    }

    var playlistItems: [WallpaperItem] {
        state.settings.playlist.compactMap { id in state.wallpapers.first(where: { $0.id == id }) }
    }

    var activeWallpaperIDs: Set<UUID> {
        var ids = Set(displays.compactMap { state.assignments[$0.id]?.wallpaperID })
        if let defaultWallpaperID = state.defaultWallpaperID { ids.insert(defaultWallpaperID) }
        return ids
    }

    var isPaused: Bool { engine.isPaused }
    var isWallpaperEnabled: Bool { state.settings.wallpaperEnabled }
    var isContentHidden: Bool { state.settings.bossHidden || state.settings.televisionOff }
    var isLiveWeb: Bool { state.settings.contentMode == .web && (webSnapshot.live || WebSession.looksLive(state.settings.webURL)) }

    var canUseTransport: Bool {
        if state.settings.contentMode == .web { return !isLiveWeb && webSnapshot.canPlay }
        return state.settings.contentMode == .video
    }

    var canSeek: Bool {
        if state.settings.contentMode == .web { return webSnapshot.canSeek }
        return state.settings.contentMode == .video
    }

    var canChangeRate: Bool {
        if state.settings.contentMode == .web { return webSnapshot.canRate }
        return state.settings.contentMode == .video
    }

    func start() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            try store.prepareDirectories()
            state = try store.load()
            displays = WallpaperEngine.displays()
            pendingSceneEnabled = state.settings.sceneEnabled
            draftBossHotkey = state.settings.bossHotkey
            syncReaderHotkeyDrafts()
            if state.wallpapers.isEmpty {
                try await importStarterWallpaperIfAvailable()
                importProgress = nil
            }
            repairAssignmentsForCurrentDisplays()
            sanitizePlaylist()
            sanitizeFolders()
            engine.apply(state: state, store: store)
            hookReader()
            selectedWallpaperID = state.defaultWallpaperID ?? state.wallpapers.first?.id
            selectedBookID = state.settings.activeBookID ?? state.books.first?.id
            storageBytes = store.librarySize()
            isReady = true
            notifyChanged()
            onHotkeyChange?()
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
            targetDisplayID: nil,
            copyToLibrary: true
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
        if state.settings.wallpaperEnabled {
            engine.apply(state: state, store: store)
            hookReader()
        }
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
        unpinWeb(returnToStudio: webStudio != nil)
        state.settings.contentMode = .video
        state.settings.playlistMode = false
        state.defaultWallpaperID = item.id
        state.defaultAspectMode = selectedMode
        if let targetDisplayID {
            state.assignments[targetDisplayID] = DisplayAssignment(wallpaperID: item.id, aspectMode: selectedMode)
        } else {
            for display in displays {
                state.assignments[display.id] = DisplayAssignment(wallpaperID: item.id, aspectMode: selectedMode)
            }
        }
        if let index = state.wallpapers.firstIndex(where: { $0.id == item.id }) {
            state.wallpapers[index].lastUsedAt = Date()
        }
        selectedWallpaperID = item.id
        state.settings.wallpaperEnabled = true
        state.settings.bossHidden = false
        state.settings.televisionOff = false
        try? persist()
        engine.apply(state: state, store: store)
        hookReader()
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

    func toggleWallpaperEnabled() {
        if state.settings.wallpaperEnabled {
            state.settings.wallpaperEnabled = false
            engine.stop()
        } else {
            do {
                try ensureContentReady()
                state.settings.wallpaperEnabled = true
                state.settings.bossHidden = false
                state.settings.televisionOff = false
                engine.apply(state: state, store: store)
                hookReader()
            } catch {
                alert = StudioAlert(title: "无法启动动态壁纸", message: error.localizedDescription)
            }
        }
        try? persistAndNotify()
    }

    func togglePause() {
        if state.settings.contentMode == .web {
            if isLiveWeb { return }
            let pause = !webSnapshot.paused
            web.setPaused(pause)
            engine.setManualPaused(pause)
            notifyChanged()
            return
        }
        engine.toggleManualPause()
        notifyChanged()
    }

    func systemPause(_ paused: Bool) {
        if paused == false, isContentHidden { return }
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

    func setMuted(_ muted: Bool) {
        state.settings.audioMuted = muted
        engine.setMuted(muted, volume: state.settings.volume)
        try? persistAndNotify()
    }

    func toggleMuted() {
        setMuted(!state.settings.audioMuted)
    }

    func setVolume(_ volume: Double) {
        state.settings.volume = min(max(volume, 0), 100)
        if state.settings.volume > 0 { state.settings.audioMuted = false }
        engine.setVolume(state.settings.volume, muted: state.settings.audioMuted)
        try? persistAndNotify()
    }

    func setSpeed(_ speed: Double) {
        state.settings.playbackSpeed = speed
        engine.setSpeed(speed)
        try? persistAndNotify()
    }

    func seek(_ seconds: Double) {
        engine.seek(seconds)
        playbackPosition = seconds
    }

    func playRelative(_ delta: Int) {
        if state.settings.contentMode == .web { return }
        if state.settings.playlist.isEmpty {
            switchFavorite(direction: delta)
            return
        }
        let next = state.settings.playlistIndex + delta
        if next < 0 { return }
        if next >= state.settings.playlist.count {
            engine.setManualPaused(true)
            notifyChanged()
            return
        }
        playPlaylistIndex(next)
    }

    func setPlaylistMode(_ enabled: Bool) {
        state.settings.playlistMode = enabled
        if enabled, state.settings.playlist.isEmpty, let id = state.defaultWallpaperID {
            state.settings.playlist.append(id)
        }
        try? persist()
        if state.settings.wallpaperEnabled, state.settings.contentMode == .video {
            engine.apply(state: state, store: store)
        }
        notifyChanged()
    }

    func addToPlaylist(_ item: WallpaperItem) {
        if !state.settings.playlist.contains(item.id) {
            state.settings.playlist.append(item.id)
            try? persistAndNotify()
        }
    }

    func requestPlaylistImport(from folder: WallpaperFolder) {
        let ids = folder.itemIDs.filter { id in state.wallpapers.contains(where: { $0.id == id }) }
        guard !ids.isEmpty else {
            alert = StudioAlert(title: "子库是空的", message: "先把视频导入「\(folder.name)」，再送到播放台。")
            return
        }
        pendingPlaylistImport = PendingPlaylistImport(folderName: folder.name, itemIDs: ids)
    }

    func confirmPlaylistImport(replace: Bool) {
        guard let pending = pendingPlaylistImport else { return }
        if replace {
            state.settings.playlist = pending.itemIDs
            state.settings.playlistIndex = 0
        } else {
            for id in pending.itemIDs where !state.settings.playlist.contains(id) {
                state.settings.playlist.append(id)
            }
        }
        state.settings.playlistMode = true
        selectedPlaylistIDs = []
        pendingPlaylistImport = nil
        filter = .player
        try? persist()
        if replace || engine.tryGetPlayback() == nil {
            playPlaylistIndex(state.settings.playlistIndex)
        } else {
            notifyChanged()
        }
    }

    func cancelPlaylistImport() {
        pendingPlaylistImport = nil
    }

    func togglePlaylistSelection(_ id: UUID) {
        if selectedPlaylistIDs.contains(id) {
            selectedPlaylistIDs.remove(id)
        } else {
            selectedPlaylistIDs.insert(id)
        }
    }

    func selectAllPlaylistItems() {
        if selectedPlaylistIDs.count == playlistItems.count {
            selectedPlaylistIDs = []
        } else {
            selectedPlaylistIDs = Set(playlistItems.map(\.id))
        }
    }

    func removeSelectedPlaylistItems() {
        guard !selectedPlaylistIDs.isEmpty else { return }
        state.settings.playlist.removeAll { selectedPlaylistIDs.contains($0) }
        if state.settings.playlistIndex >= state.settings.playlist.count {
            state.settings.playlistIndex = max(0, state.settings.playlist.count - 1)
        }
        selectedPlaylistIDs = []
        try? persistAndNotify()
    }

    func clearPlaylist() {
        state.settings.playlist = []
        state.settings.playlistIndex = 0
        state.settings.playlistMode = false
        selectedPlaylistIDs = []
        try? persistAndNotify()
    }

    func movePlaylist(from index: Int, offset: Int) {
        let destination = index + offset
        guard state.settings.playlist.indices.contains(index),
              state.settings.playlist.indices.contains(destination) else { return }
        state.settings.playlist.swapAt(index, destination)
        if state.settings.playlistIndex == index {
            state.settings.playlistIndex = destination
        } else if state.settings.playlistIndex == destination {
            state.settings.playlistIndex = index
        }
        try? persistAndNotify()
    }

    func removePlaylistItem(at index: Int) {
        guard state.settings.playlist.indices.contains(index) else { return }
        let removed = state.settings.playlist.remove(at: index)
        selectedPlaylistIDs.remove(removed)
        if state.settings.playlistIndex >= state.settings.playlist.count {
            state.settings.playlistIndex = max(0, state.settings.playlist.count - 1)
        }
        try? persistAndNotify()
    }

    func playPlaylistIndex(_ index: Int) {
        guard state.settings.playlist.indices.contains(index) else { return }
        state.settings.playlistIndex = index
        state.settings.playlistMode = true
        unpinWeb(returnToStudio: webStudio != nil)
        state.settings.contentMode = .video
        let id = state.settings.playlist[index]
        guard let item = state.wallpapers.first(where: { $0.id == id }) else { return }
        state.defaultWallpaperID = item.id
        if let wallpaperIndex = state.wallpapers.firstIndex(where: { $0.id == item.id }) {
            state.wallpapers[wallpaperIndex].lastUsedAt = Date()
        }
        selectedWallpaperID = item.id
        state.settings.wallpaperEnabled = true
        try? persist()
        let url = store.playbackURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert = StudioAlert(title: "视频不存在", message: "找不到「\(item.name)」的原文件。")
            return
        }
        if engine.tryGetPlayback() == nil {
            engine.apply(state: state, store: store)
        } else {
            engine.loadMedia(
                url: url,
                wallpaperID: item.id,
                loop: false,
                mode: state.defaultAspectMode,
                settings: state.settings
            )
        }
        notifyChanged()
    }

    func pollPlayback() {
        if state.settings.contentMode == .web, web.isReady {
            web.refreshState { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let snapshot = self.web.lastSnapshot
                    let transportChanged = snapshot.paused != self.webSnapshot.paused
                        || snapshot.muted != self.webSnapshot.muted
                        || snapshot.live != self.webSnapshot.live
                        || snapshot.canPlay != self.webSnapshot.canPlay
                        || snapshot.canSeek != self.webSnapshot.canSeek
                        || snapshot.canRate != self.webSnapshot.canRate
                    self.webSnapshot = snapshot
                    if !self.isSeeking {
                        self.playbackPosition = snapshot.position
                        self.playbackDuration = snapshot.duration
                    }
                    if transportChanged {
                        self.onChange?()
                    }
                }
            }
            return
        }
        if state.settings.contentMode == .reader, let reader = engine.activeReader, !reader.isHidden {
            let percent = Int((reader.scrollProgress() * 100).rounded())
            if percent != readerProgressPercent {
                readerProgressPercent = percent
            }
        }
        if let playback = engine.tryGetPlayback(), !isSeeking {
            playbackPosition = playback.0
            playbackDuration = playback.1
        }
    }

    func openImportPanel(into folderID: UUID? = nil) {
        if let folderID {
            importTargetFolderID = folderID
        } else if case .folder(let id) = filter {
            importTargetFolderID = id
        }
        presentOpenPanel(
            title: "导入视频或电子书",
            types: [
                .mpeg4Movie,
                .quickTimeMovie,
                UTType(filenameExtension: "m4v") ?? .movie,
                UTType(exportedAs: "local.baiyaoyu.dynamicwallpaper", conformingTo: .package)
            ] + BookFile.contentTypes,
            allowDirectories: true
        )
    }

    func openBookImportPanel() {
        filter = .reader
        onOpenWindow?()
        presentOpenPanel(
            title: "导入电子书",
            types: BookFile.contentTypes,
            allowDirectories: false
        )
    }

    private func presentOpenPanel(title: String, types: [UTType], allowDirectories: Bool) {
        onOpenWindow?()
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "导入"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = allowDirectories
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = types
        let owner = NSApp.keyWindow ?? NSApp.mainWindow
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.enqueueImports(panel.urls)
        }
        if let owner {
            panel.beginSheetModal(for: owner, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func enqueueImports(_ urls: [URL]) {
        var files: [URL] = []
        var directories: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == PortablePackageService.packageExtension {
                files.append(url)
                continue
            }
            if isDirectory(url) {
                directories.append(url)
                continue
            }
            files.append(url)
        }
        if !files.isEmpty, importTargetFolderID == nil, case .folder(let id) = filter {
            importTargetFolderID = id
        }
        folderImportQueue.append(contentsOf: directories)
        importQueue.append(contentsOf: files)
        processFolderImportIfNeeded()
        processNextImportIfNeeded()
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map {
            $0.isDirectory == true && $0.isPackage != true
        } ?? url.hasDirectoryPath
    }

    private func processFolderImportIfNeeded() {
        guard pendingFolderImport == nil, pendingImport == nil, pendingBookImport == nil,
              importProgress == nil, !isAnalyzing, !folderImportQueue.isEmpty else { return }
        let directory = folderImportQueue.removeFirst()
        let accessed = directory.startAccessingSecurityScopedResource()
        defer {
            if accessed { directory.stopAccessingSecurityScopedResource() }
        }
        let videos = VideoAnalyzer.collectVideos(in: directory)
        guard !videos.isEmpty else {
            alert = StudioAlert(title: "文件夹里没有视频", message: "「\(directory.lastPathComponent)」里没有 MP4、MOV 或 M4V。")
            processFolderImportIfNeeded()
            processNextImportIfNeeded()
            return
        }
        pendingFolderImport = PendingFolderImport(
            directoryURL: directory,
            videos: videos,
            existingFolderID: importTargetFolderID
        )
        notifyChanged()
    }

    func cancelFolderImport() {
        pendingFolderImport = nil
        processFolderImportIfNeeded()
        processNextImportIfNeeded()
        clearImportTargetIfIdle()
    }

    func confirmFolderImport(copyToLibrary: Bool) {
        guard let pending = pendingFolderImport else { return }
        pendingFolderImport = nil
        Task {
            await importFolderVideos(pending, copyToLibrary: copyToLibrary)
        }
    }

    private func importFolderVideos(_ pending: PendingFolderImport, copyToLibrary: Bool) async {
        let accessed = pending.directoryURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { pending.directoryURL.stopAccessingSecurityScopedResource() }
        }
        let folderID: UUID
        if let existing = pending.existingFolderID, folder(existing) != nil {
            folderID = existing
        } else {
            folderID = createFolder(named: pending.suggestedName, select: true)
        }
        var imported = 0
        var reused = 0
        var failed = 0
        let total = pending.videos.count
        for (index, url) in pending.videos.enumerated() {
            importProgress = ImportProgressState(
                title: pending.suggestedName,
                phase: "正在导入 \(index + 1) / \(total)",
                fraction: Double(index) / Double(max(total, 1))
            )
            let fileAccessed = url.startAccessingSecurityScopedResource()
            defer {
                if fileAccessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let metadata = try await VideoAnalyzer.analyze(url: url)
                if let duplicate = state.wallpapers.first(where: { $0.sourceSHA256 == metadata.sha256 }) {
                    addToFolder(duplicate.id, folderID: folderID)
                    reused += 1
                    continue
                }
                let candidate = ImportCandidate(
                    url: url,
                    suggestedName: url.deletingPathExtension().lastPathComponent,
                    metadata: metadata
                )
                let options = ImportOptions(
                    name: candidate.suggestedName,
                    resolution: .original,
                    customWidth: metadata.width,
                    customHeight: metadata.height,
                    aspectMode: .fit,
                    applyAfterImport: false,
                    favorite: false,
                    targetDisplayID: nil,
                    copyToLibrary: copyToLibrary
                )
                let item = try await createLibraryItem(candidate: candidate, options: options)
                state.wallpapers.insert(item, at: 0)
                addToFolder(item.id, folderID: folderID)
                imported += 1
            } catch {
                failed += 1
            }
        }
        storageBytes = store.librarySize()
        importProgress = nil
        try? persist()
        notifyChanged()
        alert = StudioAlert(
            title: "已导入「\(folder(folderID)?.name ?? pending.suggestedName)」",
            message: "新增 \(imported) 个，复用资料库已有 \(reused) 个，失败 \(failed) 个。按文件名排好了顺序。"
        )
        processFolderImportIfNeeded()
        processNextImportIfNeeded()
        clearImportTargetIfIdle()
    }

    private func processNextImportIfNeeded() {
        guard pendingImport == nil, pendingBookImport == nil, pendingFolderImport == nil,
              importProgress == nil, !isAnalyzing, !importQueue.isEmpty else {
            clearImportTargetIfIdle()
            return
        }
        let url = importQueue.removeFirst()
        let ext = url.pathExtension.lowercased()
        if BookFile.isSupported(url) {
            importBook(url: url)
            return
        }
        if ext == PortablePackageService.packageExtension {
            importPackage(url)
            return
        }

        isAnalyzing = true
        importProgress = ImportProgressState(title: url.deletingPathExtension().lastPathComponent, phase: "正在读取视频", fraction: 0.08)
        Task {
            do {
                let metadata = try await VideoAnalyzer.analyze(url: url)
                if let duplicate = state.wallpapers.first(where: { $0.sourceSHA256 == metadata.sha256 }) {
                    if let folderID = importTargetFolderID {
                        addToFolder(duplicate.id, folderID: folderID)
                        try? persist()
                    }
                    if duplicate.isReference, !FileManager.default.fileExists(atPath: store.playbackURL(for: duplicate).path) {
                        reconnect(duplicate, to: url)
                        importProgress = nil
                        isAnalyzing = false
                        processNextImportIfNeeded()
                        return
                    }
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

    private func reconnect(_ item: WallpaperItem, to url: URL) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == item.id }) else { return }
        state.wallpapers[index].sourcePath = url.path
        try? persistAndNotify()
        alert = StudioAlert(title: "视频已恢复", message: "已重新连接原视频：\(item.name)")
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

        importProgress = ImportProgressState(title: options.name, phase: options.copyToLibrary ? "正在复制原视频" : "正在生成封面", fraction: 0.12)
        Task {
            do {
                var mutableOptions = options
                mutableOptions.customWidth = dimensions.0
                mutableOptions.customHeight = dimensions.1
                let item = try await createLibraryItem(candidate: candidate, options: mutableOptions)
                importProgress = ImportProgressState(title: options.name, phase: "正在加入资料库", fraction: 0.92)
                state.wallpapers.insert(item, at: 0)
                selectedWallpaperID = item.id
                if let folderID = importTargetFolderID {
                    addToFolder(item.id, folderID: folderID)
                }
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
            let targetWidth = options.customWidth
            let targetHeight = options.customHeight
            let needsTranscode = targetWidth != candidate.metadata.width || targetHeight != candidate.metadata.height
            let shouldCopy = options.copyToLibrary || needsTranscode

            await updateImportProgress(title: options.name, phase: "正在生成缩略图", fraction: 0.28)
            let posterName = "poster.jpg"
            let stagedPoster = temporary.appendingPathComponent(posterName)
            try VideoTranscoder.makePoster(inputURL: candidate.url, outputURL: stagedPoster)

            var playbackName = ""
            let sourcePath = candidate.url.path
            var managed = false
            if needsTranscode {
                await updateImportProgress(title: options.name, phase: "正在转换视频", fraction: 0.48)
                playbackName = "wallpaper-\(targetWidth)x\(targetHeight).mp4"
                try await VideoTranscoder.transcode(
                    inputURL: candidate.url,
                    outputURL: temporary.appendingPathComponent(playbackName),
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    mode: options.aspectMode
                )
                managed = true
            } else if shouldCopy {
                await updateImportProgress(title: options.name, phase: "正在复制原视频", fraction: 0.48)
                try manager.copyItem(at: candidate.url, to: temporary.appendingPathComponent(sourceName))
                playbackName = sourceName
                managed = true
            }

            let playbackURL = managed
                ? temporary.appendingPathComponent(playbackName)
                : candidate.url
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
                sourcePath: sourcePath,
                isManagedVideo: managed,
                sourceWidth: candidate.metadata.width,
                sourceHeight: candidate.metadata.height,
                outputWidth: targetWidth,
                outputHeight: targetHeight,
                duration: candidate.metadata.duration,
                fps: candidate.metadata.fps,
                codec: needsTranscode ? "H.264" : candidate.metadata.codec,
                fileSize: Int64(size),
                sourceSHA256: candidate.metadata.sha256,
                hasAudio: candidate.metadata.hasAudio
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
                    targetDisplayID: nil,
                    copyToLibrary: true
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
        removeItemFromAllFolders(item.id)
        state.assignments = state.assignments.filter { $0.value.wallpaperID != item.id }
        state.settings.playlist.removeAll { $0 == item.id }
        if state.settings.playlistIndex >= state.settings.playlist.count {
            state.settings.playlistIndex = max(0, state.settings.playlist.count - 1)
        }
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

    func beginCreateFolder() {
        draftFolderName = ""
        isCreatingFolder = true
    }

    @discardableResult
    func createFolder(named name: String, select: Bool = true) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = WallpaperFolder(name: trimmed.isEmpty ? "未命名子库" : trimmed)
        state.folders.append(folder)
        if select {
            filter = .folder(folder.id)
        }
        try? persistAndNotify()
        isCreatingFolder = false
        draftFolderName = ""
        return folder.id
    }

    func confirmCreateFolder() {
        createFolder(named: draftFolderName)
    }

    func beginRenameFolder(_ folder: WallpaperFolder) {
        draftFolderName = folder.name
        pendingFolderRename = folder
    }

    func confirmRenameFolder() {
        guard let folder = pendingFolderRename,
              let index = state.folders.firstIndex(where: { $0.id == folder.id }) else {
            pendingFolderRename = nil
            return
        }
        let trimmed = draftFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        state.folders[index].name = trimmed.isEmpty ? folder.name : trimmed
        pendingFolderRename = nil
        draftFolderName = ""
        try? persistAndNotify()
    }

    func requestDeleteFolder(_ folder: WallpaperFolder) {
        pendingFolderDeletion = folder
    }

    func confirmDeleteFolder(_ folder: WallpaperFolder) {
        state.folders.removeAll { $0.id == folder.id }
        if case .folder(let id) = filter, id == folder.id {
            filter = .all
        }
        pendingFolderDeletion = nil
        try? persistAndNotify()
    }

    func addWallpaper(_ item: WallpaperItem, toFolder folderID: UUID) {
        addToFolder(item.id, folderID: folderID)
        try? persistAndNotify()
    }

    func addToFolder(_ itemID: UUID, folderID: UUID) {
        guard let index = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
        if !state.folders[index].itemIDs.contains(itemID) {
            state.folders[index].itemIDs.append(itemID)
        }
    }

    func removeFromFolder(_ item: WallpaperItem, folderID: UUID) {
        guard let index = state.folders.firstIndex(where: { $0.id == folderID }) else { return }
        state.folders[index].itemIDs.removeAll { $0 == item.id }
        try? persistAndNotify()
    }

    func assign(_ item: WallpaperItem, toFolder folderID: UUID?) {
        removeItemFromAllFolders(item.id)
        if let folderID {
            addToFolder(item.id, folderID: folderID)
        }
        try? persistAndNotify()
    }

    private func removeItemFromAllFolders(_ itemID: UUID) {
        for index in state.folders.indices {
            state.folders[index].itemIDs.removeAll { $0 == itemID }
        }
    }

    private func clearImportTargetIfIdle() {
        guard importQueue.isEmpty, folderImportQueue.isEmpty,
              pendingFolderImport == nil, pendingImport == nil,
              importProgress == nil, !isAnalyzing else { return }
        importTargetFolderID = nil
    }

    func importBook(url: URL) {
        guard BookFile.isSupported(url) else {
            alert = StudioAlert(title: "无法导入", message: "电子书目前支持 TXT、Markdown 和 PDF。")
            processNextImportIfNeeded()
            return
        }
        pendingBookImport = PendingBookImport(url: url)
        filter = .reader
        onOpenWindow?()
        notifyChanged()
    }

    func confirmBookImport(copyToLibrary: Bool) {
        guard let pending = pendingBookImport else { return }
        pendingBookImport = nil
        do {
            try addBook(url: pending.url, kind: pending.kind, copyToLibrary: copyToLibrary)
        } catch {
            alert = StudioAlert(title: "无法导入电子书", message: error.localizedDescription)
        }
        processNextImportIfNeeded()
    }

    func cancelBookImport() {
        pendingBookImport = nil
        processNextImportIfNeeded()
    }

    private func addBook(url: URL, kind: BookKind, copyToLibrary: Bool) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let id = UUID()
        var stored = url.path
        var managed = false
        if copyToLibrary {
            let directory = store.bookDirectory(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("book.\(url.pathExtension.lowercased())")
            try FileManager.default.copyItem(at: url, to: destination)
            stored = store.relativeToRoot(destination)
            managed = true
        }
        let book = BookItem(
            name: url.deletingPathExtension().lastPathComponent,
            sourcePath: stored,
            kind: kind,
            isManagedCopy: managed
        )
        state.books.insert(book, at: 0)
        selectedBookID = book.id
        openBook(book)
    }

    func openBook(_ book: BookItem) {
        unpinWeb(returnToStudio: webStudio != nil)
        if let index = state.books.firstIndex(where: { $0.id == book.id }) {
            state.books[index].lastUsedAt = Date()
        }
        state.settings.activeBookID = book.id
        state.settings.contentMode = .reader
        selectedBookID = book.id
        state.settings.wallpaperEnabled = true
        state.settings.bossHidden = false
        state.settings.televisionOff = false
        try? persist()
        engine.apply(state: state, store: store)
        hookReader()
        loadActiveBook()
        notifyChanged()
    }

    func requestDeleteBook(_ book: BookItem) {
        pendingBookDeletion = book
    }

    func confirmDeleteBook(_ book: BookItem) {
        state.books.removeAll { $0.id == book.id }
        if state.settings.activeBookID == book.id {
            state.settings.activeBookID = state.books.first?.id
        }
        try? store.removeManagedBook(book)
        try? persist()
        if state.settings.contentMode == .reader, state.settings.wallpaperEnabled {
            engine.apply(state: state, store: store)
            hookReader()
            loadActiveBook()
        }
        pendingBookDeletion = nil
        selectedBookID = state.books.first?.id
        storageBytes = store.librarySize()
        notifyChanged()
    }

    var readerCanAutoScroll: Bool {
        let kind = selectedBook?.kind ?? activeBook?.kind
        return kind == .text || kind == .markdown
    }

    func handleSharedAdvanceHotkey(next: Bool) {
        if state.settings.contentMode == .web, state.settings.shortVideoMode {
            webShortAdvance(next ? 1 : -1)
            return
        }
        if next {
            readerNext(fromHotkey: true)
        } else {
            readerPrevious(fromHotkey: true)
        }
    }

    func handleSharedPauseHotkey() {
        if state.settings.contentMode == .web, state.settings.shortVideoMode {
            web.setPaused(!webSnapshot.paused)
            notifyChanged()
            return
        }
        readerTogglePause(fromHotkey: true)
    }

    func webShortAdvance(_ direction: Int) {
        guard state.settings.contentMode == .web else { return }
        web.shortAdvance(direction, keepClean: shouldKeepWebClean)
    }

    var shouldKeepWebClean: Bool {
        state.settings.shortVideoMode && state.settings.keepWebCleanScreen
    }

    func setShortVideoMode(_ enabled: Bool) {
        state.settings.shortVideoMode = enabled
        web.applyCleanScreen(shouldKeepWebClean)
        try? persistAndNotify()
    }

    func setKeepWebCleanScreen(_ enabled: Bool) {
        state.settings.keepWebCleanScreen = enabled
        web.applyCleanScreen(shouldKeepWebClean)
        try? persistAndNotify()
    }

    func readerNext(fromHotkey: Bool = false) {
        if fromHotkey {
            guard state.settings.contentMode == .reader,
                  let reader = engine.activeReader,
                  !reader.isHidden else { return }
            _ = reader.nextPage()
            notifyChanged()
            return
        }
        guard prepareReader() else { return }
        if engine.activeReader?.nextPage() != true {
            if engine.activeReader?.usesContinuousScroll == true {
                alert = StudioAlert(title: "已经到结尾", message: "这本电子书已经滚到最后了。")
            } else {
                alert = StudioAlert(title: "已经是最后一页", message: "这本电子书没有下一页了。")
            }
            return
        }
        notifyChanged()
    }

    func readerPrevious(fromHotkey: Bool = false) {
        if fromHotkey {
            guard state.settings.contentMode == .reader,
                  let reader = engine.activeReader,
                  !reader.isHidden else { return }
            _ = reader.previousPage()
            notifyChanged()
            return
        }
        guard prepareReader() else { return }
        if engine.activeReader?.previousPage() != true {
            if engine.activeReader?.usesContinuousScroll == true {
                alert = StudioAlert(title: "已经到开头", message: "这本电子书已经在最上面了。")
            } else {
                alert = StudioAlert(title: "已经是第一页", message: "这本电子书没有上一页了。")
            }
            return
        }
        notifyChanged()
    }

    func readerAdjustFont(_ delta: Double) {
        guard prepareReader(), let reader = engine.activeReader else { return }
        reader.applyFontSize(reader.capture().fontSize + delta)
    }

    func readerSetTheme(_ theme: ReaderTheme) {
        guard prepareReader() else { return }
        engine.activeReader?.applyTheme(theme)
    }

    func readerSetAutoTurn(_ enabled: Bool, seconds: Double) {
        readerSetAdvance(enabled ? .page : .off, pageSeconds: seconds)
    }

    func readerSetAdvance(_ mode: ReaderAdvanceMode, pageSeconds: Double? = nil, scrollSpeed: Double? = nil) {
        guard prepareReader(), let reader = engine.activeReader else { return }
        if mode == .scroll, !readerCanAutoScroll {
            alert = StudioAlert(title: "PDF 不能自动滚动", message: "PDF 请用自动翻页。TXT 和 Markdown 才能自动滚动。")
            return
        }
        let current = reader.capture()
        reader.setAdvance(
            mode,
            pageSeconds: pageSeconds ?? current.autoTurnSeconds,
            scrollSpeed: scrollSpeed ?? current.scrollSpeed
        )
        notifyChanged()
    }

    func readerSetScrollSpeed(_ speed: Double) {
        guard prepareReader() else { return }
        engine.activeReader?.setScrollSpeed(speed)
        notifyChanged()
    }

    func readerTogglePause(fromHotkey: Bool = false) {
        if fromHotkey {
            guard state.settings.contentMode == .reader, let reader = engine.activeReader else { return }
            guard reader.capture().advanceMode != .off else { return }
            reader.toggleAutoAdvancePaused()
            notifyChanged()
            return
        }
        guard prepareReader(), let reader = engine.activeReader else { return }
        guard reader.capture().advanceMode != .off else {
            alert = StudioAlert(title: "还没有自动阅读", message: "先选择自动翻页或自动滚动，再暂停。")
            return
        }
        reader.toggleAutoAdvancePaused()
        notifyChanged()
    }

    var readerPageLabel: String {
        guard state.settings.contentMode == .reader,
              let reader = engine.activeReader,
              !reader.isHidden else {
            return "还没有打开到桌面"
        }
        let paused = reader.isAutoAdvancePaused && reader.capture().advanceMode != .off
        let suffix = paused ? " · 已暂停" : ""
        if reader.usesContinuousScroll {
            let percent = readerProgressPercent
            return "已滚动 \(percent)%\(suffix)"
        }
        let info = reader.pageInfo()
        return "第 \(info.current) / \(info.total) 页\(suffix)"
    }

    private func prepareReader() -> Bool {
        if state.settings.contentMode == .reader,
           let reader = engine.activeReader,
           !reader.isHidden {
            return true
        }
        guard let book = selectedBook ?? activeBook else {
            alert = StudioAlert(title: "还没有电子书", message: "请先导入 TXT、Markdown 或 PDF。")
            return false
        }
        openBook(book)
        return engine.activeReader != nil
    }

    func updateActiveBookPosition(_ position: ReaderPosition) {
        guard let id = state.settings.activeBookID,
              let index = state.books.firstIndex(where: { $0.id == id }) else { return }
        state.books[index].position = position
        try? persist()
    }

    func setWebURL(_ url: String) {
        state.settings.webURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.contentMode = .web
        try? persistAndNotify()
    }

    func openWebStudio() {
        state.settings.contentMode = .web
        if state.settings.webURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.settings.webURL = "https://live.bilibili.com"
        }
        try? persist()
        if webStudio == nil {
            webStudio = WebStudioWindowController(model: self)
        }
        web.ensure(profileURL: store.webProfileURL)
        webStudio?.showWindow(nil)
        webStudio?.window?.makeKeyAndOrderFront(nil)
        webStudio?.window?.layoutIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        if !web.pinnedToDesktop, let host = webStudio?.host {
            web.place(in: host, hitTest: true)
        }
        if !web.hasHTTPDocument {
            try? web.navigate(state.settings.webURL)
        }
        web.applyTransport(muted: state.settings.audioMuted, volume: state.settings.volume, speed: state.settings.playbackSpeed)
        web.applyCleanScreen(shouldKeepWebClean)
        webStudio?.window?.makeFirstResponder(web.pinnedToDesktop ? nil : web.webView)
        webStudio?.refreshOverlay()
        notifyChanged()
    }

    func navigateWebStudio(_ url: String) async {
        do {
            web.ensure(profileURL: store.webProfileURL)
            if let host = webStudio?.host, !web.pinnedToDesktop {
                web.place(in: host, hitTest: true)
            }
            try web.navigate(url)
            state.settings.webURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            state.settings.contentMode = .web
            try persist()
            notifyChanged()
        } catch {
            alert = StudioAlert(title: "无法打开网页", message: error.localizedDescription)
        }
    }

    func syncWebToDesktop() async {
        guard web.hasHTTPDocument else {
            alert = StudioAlert(title: "还不能同步", message: "请先在独立页面打开直播间或网页，把全屏和弹幕设好，再同步到桌面。")
            return
        }
        state.settings.webURL = web.currentURL
        state.settings.contentMode = .web
        web.pinnedToDesktop = true
        state.settings.wallpaperEnabled = true
        state.settings.bossHidden = false
        state.settings.televisionOff = false
        engine.apply(state: state, store: store)
        web.applyTransport(muted: state.settings.audioMuted, volume: state.settings.volume, speed: state.settings.playbackSpeed)
        web.applyCleanScreen(shouldKeepWebClean)
        try? persist()
        webStudio?.refreshOverlay()
        notifyChanged()
    }

    func recallWebFromDesktop() {
        web.pinnedToDesktop = false
        engine.releaseSharedWeb()
        if let host = webStudio?.host ?? webStudioHost {
            web.place(in: host, hitTest: true)
            web.applyHostSettings(interactive: true)
        }
        try? persist()
        webStudio?.refreshOverlay()
        notifyChanged()
    }

    func notifyWebStudioClosed() {
        webStudio = nil
    }

    func applyScene() {
        state.settings.sceneEnabled = pendingSceneEnabled
        try? persist()
        if state.settings.wallpaperEnabled {
            engine.apply(state: state, store: store)
            hookReader()
            if state.settings.contentMode == .reader {
                loadActiveBook()
            }
        }
        notifyChanged()
    }

    func setTelevisionOff(_ off: Bool) {
        state.settings.televisionOff = off
        if off { state.settings.bossHidden = false }
        try? persist()
        applyContentHidden()
    }

    func toggleTelevision() {
        setTelevisionOff(!state.settings.televisionOff)
    }

    func toggleBossKey() {
        state.settings.bossHidden.toggle()
        state.settings.televisionOff = state.settings.bossHidden
        try? persist()
        applyContentHidden()
    }

    func setBossHotkey(gesture: String, enabled: Bool) {
        state.settings.bossHotkey = gesture.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.bossHotkeyEnabled = enabled
        draftBossHotkey = state.settings.bossHotkey
        try? persistAndNotify()
        onHotkeyChange?()
    }

    func setReaderHotkeys(
        previous: String,
        next: String,
        pause: String,
        enabled: Bool
    ) {
        state.settings.readerPreviousHotkey = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.readerNextHotkey = next.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.readerPauseHotkey = pause.trimmingCharacters(in: .whitespacesAndNewlines)
        state.settings.readerHotkeysEnabled = enabled
        syncReaderHotkeyDrafts()
        try? persistAndNotify()
        onHotkeyChange?()
    }

    private func syncReaderHotkeyDrafts() {
        draftReaderPreviousHotkey = state.settings.readerPreviousHotkey
        draftReaderNextHotkey = state.settings.readerNextHotkey
        draftReaderPauseHotkey = state.settings.readerPauseHotkey
    }

    func setImportMode(_ mode: ImportStorageMode) {
        state.settings.importMode = mode
        try? persistAndNotify()
    }

    func setContentMode(_ mode: ContentMode) {
        if mode != .web {
            unpinWeb(returnToStudio: webStudio != nil)
        }
        state.settings.contentMode = mode
        if mode == .video {
            state.settings.playlistMode = state.settings.playlist.count > 1 && state.settings.playlistMode
        }
        try? persist()
        if state.settings.wallpaperEnabled {
            engine.apply(state: state, store: store)
            hookReader()
            if mode == .reader { loadActiveBook() }
        }
        notifyChanged()
    }

    func relocateLibrary() {
        let panel = NSOpenPanel()
        panel.title = "选择资料库文件夹"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let wasEnabled = state.settings.wallpaperEnabled
            if wasEnabled { engine.stop() }
            webStudio?.close()
            webStudio = nil
            web.detach()
            try store.relocate(to: url)
            state = try store.load()
            state.settings.libraryRoot = store.baseURL.path
            pendingSceneEnabled = state.settings.sceneEnabled
            draftBossHotkey = state.settings.bossHotkey
            syncReaderHotkeyDrafts()
            sanitizePlaylist()
            sanitizeFolders()
            try persist()
            storageBytes = store.librarySize()
            if wasEnabled {
                engine.apply(state: state, store: store)
                hookReader()
                if state.settings.contentMode == .reader { loadActiveBook() }
            }
            notifyChanged()
        } catch {
            alert = StudioAlert(title: "无法更改资料库", message: error.localizedDescription)
        }
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

    private func handleMediaEnded() {
        guard state.settings.playlistMode else { return }
        if state.settings.playlistIndex >= state.settings.playlist.count - 1 {
            engine.setManualPaused(true)
            notifyChanged()
            return
        }
        playRelative(1)
    }

    private func applyContentHidden() {
        guard state.settings.wallpaperEnabled else {
            notifyChanged()
            return
        }
        if state.settings.bossHidden && !state.settings.sceneEnabled {
            engine.setContentHidden(true, keepScene: false, settings: state.settings)
        } else {
            engine.setContentHidden(
                state.settings.bossHidden || state.settings.televisionOff,
                keepScene: state.settings.sceneEnabled,
                settings: state.settings
            )
        }
        notifyChanged()
    }

    private func unpinWeb(returnToStudio: Bool) {
        web.pinnedToDesktop = false
        engine.releaseSharedWeb()
        if returnToStudio, let host = webStudio?.host {
            web.place(in: host, hitTest: true)
            web.applyHostSettings(interactive: true)
        } else if !returnToStudio {
            web.detach()
        }
        webStudio?.refreshOverlay()
    }

    private func hookReader() {
        engine.activeReader?.onPositionChanged = { [weak self] position in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.activeBook?.position
                self.updateActiveBookPosition(position)
                if previous?.autoAdvancePaused != position.autoAdvancePaused
                    || previous?.advanceMode != position.advanceMode {
                    self.notifyChanged()
                }
            }
        }
    }

    private func loadActiveBook() {
        guard let book = activeBook, let reader = engine.activeReader else { return }
        let url = store.bookURL(for: book)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            if book.kind == .pdf {
                try reader.loadPDF(url: url, position: book.position)
            } else {
                let text = try TextEncodingDetector.readAllText(url: url)
                let display = book.kind == .markdown || BookFile.kind(for: url) == .markdown
                    ? MarkdownDisplay.readableText(text)
                    : text
                reader.loadText(display, position: book.position, kind: book.kind)
            }
            reader.layout()
            reader.needsDisplay = true
        } catch {
            alert = StudioAlert(title: "无法打开电子书", message: error.localizedDescription)
        }
    }

    private func ensureContentReady() throws {
        switch state.settings.contentMode {
        case .reader:
            if activeBook == nil { throw NSError(domain: "Studio", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先导入一本 TXT、Markdown 或 PDF。"]) }
        case .web:
            if !web.hasHTTPDocument {
                throw NSError(domain: "Studio", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先打开独立页面，在里面设置好后再点「同步到桌面」。"])
            }
        case .video:
            if state.defaultWallpaperID == nil { throw NSError(domain: "Studio", code: 3, userInfo: [NSLocalizedDescriptionKey: "请先选择一张壁纸。"]) }
        }
    }

    private func sanitizePlaylist() {
        state.settings.playlist = state.settings.playlist.filter { id in
            state.wallpapers.contains(where: { $0.id == id })
        }
        if state.settings.playlistIndex >= state.settings.playlist.count {
            state.settings.playlistIndex = max(0, state.settings.playlist.count - 1)
        }
    }

    private func sanitizeFolders() {
        for index in state.folders.indices {
            state.folders[index].itemIDs = state.folders[index].itemIDs.filter { id in
                state.wallpapers.contains(where: { $0.id == id })
            }
        }
    }

    private func persist() throws {
        try store.save(state)
    }

    private func persistAndNotify() throws {
        try persist()
        notifyChanged()
    }

    func notifyChanged() {
        objectWillChange.send()
        onChange?()
        onWebStudioRefresh?()
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
