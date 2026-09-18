import AppKit
import AVFoundation
import CoreGraphics

final class WallpaperView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        guard let playerLayer = layer as? AVPlayerLayer else {
            fatalError("WallpaperView requires AVPlayerLayer")
        }
        return playerLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }
}

final class DisplayPlayback {
    let displayID: String
    private(set) var wallpaperID: UUID
    let window: NSWindow
    let player: AVQueuePlayer
    let wallpaperView: WallpaperView
    private(set) var mode: AspectMode
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    var onEnded: (() -> Void)?

    init(displayID: String, wallpaperID: UUID, videoURL: URL, screen: NSScreen, mode: AspectMode, loop: Bool) {
        self.displayID = displayID
        self.wallpaperID = wallpaperID
        self.mode = mode

        player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false

        wallpaperView = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        wallpaperView.autoresizingMask = [.width, .height]
        wallpaperView.playerLayer.player = player
        wallpaperView.playerLayer.videoGravity = mode == .fit ? .resizeAspect : .resizeAspectFill

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = wallpaperView
        window.setFrame(screen.frame, display: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        load(url: videoURL, wallpaperID: wallpaperID, loop: loop)
    }

    func load(url: URL, wallpaperID: UUID, loop: Bool) {
        self.wallpaperID = wallpaperID
        clearLooper()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if loop {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            observeEnd(of: item)
        }
    }

    func setMode(_ newMode: AspectMode) {
        mode = newMode
        wallpaperView.playerLayer.videoGravity = newMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    func applyTransport(muted: Bool, volume: Double, speed: Double, paused: Bool) {
        player.isMuted = muted
        player.volume = muted ? 0 : Float(min(max(volume, 0), 100) / 100)
        if paused {
            player.pause()
        } else {
            player.rate = Float(speed)
        }
    }

    func pause() { player.pause() }
    func play(speed: Double = 1) { player.rate = Float(speed) }

    func seek(_ seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playback() -> (Double, Double, Bool) {
        let item = player.currentItem
        let position = item?.currentTime().seconds ?? 0
        let duration = item?.duration.seconds ?? 0
        return (position.isFinite ? position : 0, duration.isFinite ? duration : 0, player.rate == 0)
    }

    func hide() {
        window.orderOut(nil)
    }

    func reveal() {
        window.orderFrontRegardless()
    }

    func close() {
        clearLooper()
        player.pause()
        wallpaperView.playerLayer.player = nil
        window.close()
    }

    private func clearLooper() {
        looper?.disableLooping()
        looper = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        }
    }
}

final class DesktopLayer {
    let window: NSWindow
    let root = FlippedView()
    let sceneView = NSImageView()
    let contentHost = FlippedView()
    let wallpaperView = WallpaperView()
    let reader = ReaderSurface()
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    var onEnded: (() -> Void)?
    private(set) var wallpaperID: UUID?
    private var sceneEnabled = false

    init(screen: NSScreen) {
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false

        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        sceneView.imageScaling = .scaleAxesIndependently
        sceneView.image = Self.livingRoomImage()
        sceneView.wantsLayer = true

        wallpaperView.playerLayer.player = player
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.black.cgColor
        contentHost.addSubview(wallpaperView)
        contentHost.addSubview(reader)

        root.addSubview(sceneView)
        root.addSubview(contentHost)

        window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = root
        window.setFrame(screen.frame, display: true)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        layout(scene: false, screen: screen)
    }

    func layout(scene: Bool, screen: NSScreen) {
        sceneEnabled = scene
        window.setFrame(screen.frame, display: true)
        root.frame = NSRect(origin: .zero, size: screen.frame.size)
        sceneView.frame = root.bounds
        sceneView.isHidden = !scene
        if scene {
            contentHost.frame = SceneLayout.televisionFrame(in: root.bounds)
        } else {
            contentHost.frame = root.bounds
        }
        contentHost.clipsToBounds = scene
        wallpaperView.frame = contentHost.bounds
        reader.frame = contentHost.bounds
        for subview in contentHost.subviews where subview !== wallpaperView && subview !== reader {
            placeWeb(subview)
        }
    }

    func showVideo(url: URL, wallpaperID: UUID, mode: AspectMode, loop: Bool) {
        self.wallpaperID = wallpaperID
        reader.isHidden = true
        wallpaperView.isHidden = false
        wallpaperView.playerLayer.videoGravity = mode == .fit ? .resizeAspect : .resizeAspectFill
        clearLooper()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if loop {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                self?.onEnded?()
            }
        }
    }

    func showReader() {
        wallpaperID = nil
        wallpaperView.isHidden = true
        reader.isHidden = false
        player.pause()
    }

    func showWeb() {
        wallpaperID = nil
        wallpaperView.isHidden = true
        reader.isHidden = true
        player.pause()
    }

    func hideContent() {
        contentHost.isHidden = true
        player.pause()
        reader.pauseAutoTurn()
    }

    func revealContent() {
        contentHost.isHidden = false
    }

    func attachWeb(_ view: NSView) {
        if view.superview !== contentHost {
            contentHost.addSubview(view)
        }
        placeWeb(view)
        showWeb()
    }

    private func placeWeb(_ view: NSView) {
        if sceneEnabled {
            view.autoresizingMask = []
            view.frame = SceneLayout.liftedWebFrame(in: contentHost.bounds)
        } else {
            view.autoresizingMask = [.width, .height]
            view.frame = contentHost.bounds
        }
    }

    func applyTransport(muted: Bool, volume: Double, speed: Double, paused: Bool) {
        player.isMuted = muted
        player.volume = muted ? 0 : Float(min(max(volume, 0), 100) / 100)
        if paused {
            player.pause()
        } else if !wallpaperView.isHidden {
            player.rate = Float(speed)
        }
    }

    func seek(_ seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playback() -> (Double, Double, Bool) {
        let item = player.currentItem
        let position = item?.currentTime().seconds ?? 0
        let duration = item?.duration.seconds ?? 0
        return (position.isFinite ? position : 0, duration.isFinite ? duration : 0, player.rate == 0)
    }

    func hide() { window.orderOut(nil) }
    func reveal() { window.orderFrontRegardless() }

    func close() {
        clearLooper()
        player.pause()
        wallpaperView.playerLayer.player = nil
        reader.clear()
        window.close()
    }

    private func clearLooper() {
        looper?.disableLooping()
        looper = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    static func livingRoomImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "LivingRoom", withExtension: "jpg") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

@MainActor
final class WallpaperEngine {
    private var playbacks: [String: DisplayPlayback] = [:]
    private var layer: DesktopLayer?
    private(set) var isManuallyPaused = false
    private var isSystemPaused = false
    private(set) var isContentHidden = false
    var web: WebSession?
    var onMediaEnded: (() -> Void)?
    var onApplied: (() -> Void)?
    private var lastSpeed = 1.0

    var isPaused: Bool { isManuallyPaused || isSystemPaused || isContentHidden }
    var activeReader: ReaderSurface? { layer?.reader }

    func apply(state: LibraryState, store: LibraryStore) {
        guard state.settings.wallpaperEnabled else {
            stop()
            return
        }

        isContentHidden = state.settings.bossHidden || state.settings.televisionOff
        let keepSceneOnly = isContentHidden && state.settings.sceneEnabled
        let hideEverything = isContentHidden && !state.settings.sceneEnabled
        let mainScreen = NSScreen.main ?? NSScreen.screens.first

        if hideEverything {
            closeVideos()
            layer?.hide()
            return
        }

        guard let mainScreen else {
            closeVideos()
            return
        }

        let scene = state.settings.sceneEnabled
        let mode = state.settings.contentMode
        ensureLayer(on: mainScreen, scene: scene)

        if keepSceneOnly {
            closeVideos()
            layer?.hideContent()
            layer?.reveal()
            web?.setMuted(true)
            return
        }

        layer?.revealContent()

        switch mode {
        case .video:
            applyVideo(state: state, store: store, scene: scene, mainScreen: mainScreen)
        case .reader:
            closeVideos()
            layer?.showReader()
            layer?.reveal()
        case .web:
            closeVideos()
            if let web, web.pinnedToDesktop, web.hasHTTPDocument {
                layer?.attachWeb(web.webView)
                web.applyTransport(
                    muted: state.settings.audioMuted,
                    volume: state.settings.volume,
                    speed: state.settings.playbackSpeed
                )
            }
            layer?.reveal()
        }

        applyTransport(state.settings)
        if isPaused {
            pauseAll()
        }
        onApplied?()
    }

    func setContentHidden(_ hidden: Bool, keepScene: Bool, settings: StudioSettings) {
        isContentHidden = hidden
        if hidden {
            pauseAll()
            playbacks.values.forEach { $0.hide() }
            if keepScene {
                layer?.hideContent()
                layer?.reveal()
                web?.setMuted(true)
            } else {
                layer?.hide()
                web?.setMuted(true)
            }
            return
        }

        playbacks.values.forEach { $0.reveal() }
        layer?.revealContent()
        layer?.reveal()
        applyTransport(settings)
        if !isManuallyPaused && !isSystemPaused {
            resumeAll(speed: settings.playbackSpeed)
        }
    }

    func loadMedia(url: URL, wallpaperID: UUID, loop: Bool, mode: AspectMode, settings: StudioSettings) {
        if let layer, !layer.sceneView.isHidden || playbacks.isEmpty {
            layer.showVideo(url: url, wallpaperID: wallpaperID, mode: mode, loop: loop)
            layer.onEnded = { [weak self] in self?.onMediaEnded?() }
        }
        for playback in playbacks.values {
            playback.load(url: url, wallpaperID: wallpaperID, loop: loop)
            playback.onEnded = { [weak self] in self?.onMediaEnded?() }
        }
        applyTransport(settings)
        if isPaused {
            pauseAll()
        }
    }

    func toggleManualPause() {
        isManuallyPaused.toggle()
        updatePlaybackState()
    }

    func setManualPaused(_ paused: Bool) {
        isManuallyPaused = paused
        updatePlaybackState()
    }

    func setSystemPaused(_ paused: Bool) {
        isSystemPaused = paused
        updatePlaybackState()
    }

    func setMuted(_ muted: Bool, volume: Double) {
        playbacks.values.forEach { $0.applyTransport(muted: muted, volume: volume, speed: 1, paused: $0.player.rate == 0) }
        layer?.applyTransport(muted: muted, volume: volume, speed: 1, paused: layer?.player.rate == 0)
        web?.setMuted(muted)
    }

    func setVolume(_ volume: Double, muted: Bool) {
        playbacks.values.forEach { $0.applyTransport(muted: muted, volume: volume, speed: 1, paused: $0.player.rate == 0) }
        layer?.applyTransport(muted: muted, volume: volume, speed: 1, paused: layer?.player.rate == 0)
        web?.setVolume(volume)
        if !muted { web?.setMuted(false) }
    }

    func setSpeed(_ speed: Double) {
        lastSpeed = speed
        if !isPaused {
            playbacks.values.forEach { $0.play(speed: speed) }
            layer?.applyTransport(muted: layer?.player.isMuted ?? true, volume: Double((layer?.player.volume ?? 0) * 100), speed: speed, paused: false)
        }
        web?.setSpeed(speed)
    }

    func seek(_ seconds: Double) {
        playbacks.values.forEach { $0.seek(seconds) }
        layer?.seek(seconds)
        web?.seek(seconds)
    }

    func tryGetPlayback() -> (Double, Double, Bool)? {
        if let web, web.pinnedToDesktop, web.lastSnapshot.ready {
            return (web.lastSnapshot.position, web.lastSnapshot.duration, web.lastSnapshot.paused)
        }
        if let layer, layer.window.isVisible, !layer.wallpaperView.isHidden {
            return layer.playback()
        }
        if let first = playbacks.values.first {
            return first.playback()
        }
        return nil
    }

    func stop() {
        closeVideos()
        if let web {
            web.detach()
        }
        layer?.close()
        layer = nil
    }

    func releaseSharedWeb() {
        web?.webView.removeFromSuperview()
    }

    static func displays() -> [DisplayInfo] {
        NSScreen.screens.map(describe)
    }

    static func describe(screen: NSScreen) -> DisplayInfo {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let width = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        let height = Int((screen.frame.height * screen.backingScaleFactor).rounded())
        let stableName = screen.localizedName.replacingOccurrences(of: "/", with: "-")
        let id = "\(stableName)|\(width)x\(height)"
        return DisplayInfo(
            id: id,
            name: screen.localizedName,
            pixelWidth: width,
            pixelHeight: height,
            isMain: screen == NSScreen.main,
            screenNumber: number
        )
    }

    private func ensureLayer(on screen: NSScreen, scene: Bool) {
        if layer == nil {
            let created = DesktopLayer(screen: screen)
            created.onEnded = { [weak self] in self?.onMediaEnded?() }
            layer = created
        }
        layer?.layout(scene: scene, screen: screen)
        layer?.reveal()
    }

    private func applyVideo(state: LibraryState, store: LibraryStore, scene: Bool, mainScreen: NSScreen) {
        let loop = !state.settings.playlistMode
        if scene {
            closeVideos()
            guard let item = currentItem(in: state),
                  FileManager.default.fileExists(atPath: store.playbackURL(for: item).path) else {
                return
            }
            layer?.showVideo(
                url: store.playbackURL(for: item),
                wallpaperID: item.id,
                mode: state.defaultAspectMode,
                loop: loop
            )
            layer?.reveal()
            return
        }

        layer?.hide()
        let screens = NSScreen.screens
        var retained = Set<String>()
        for screen in screens {
            let display = Self.describe(screen: screen)
            retained.insert(display.id)
            let assignment = state.assignments[display.id]
                ?? state.defaultWallpaperID.map { DisplayAssignment(wallpaperID: $0, aspectMode: state.defaultAspectMode) }
            guard let assignment,
                  let item = state.wallpapers.first(where: { $0.id == assignment.wallpaperID }) else {
                playbacks.removeValue(forKey: display.id)?.close()
                continue
            }
            let videoURL = store.playbackURL(for: item)
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                playbacks.removeValue(forKey: display.id)?.close()
                continue
            }
            if let existing = playbacks[display.id], existing.wallpaperID == item.id {
                existing.setMode(assignment.aspectMode)
                existing.window.setFrame(screen.frame, display: true)
                existing.reveal()
            } else {
                playbacks.removeValue(forKey: display.id)?.close()
                let playback = DisplayPlayback(
                    displayID: display.id,
                    wallpaperID: item.id,
                    videoURL: videoURL,
                    screen: screen,
                    mode: assignment.aspectMode,
                    loop: loop
                )
                playback.onEnded = { [weak self] in self?.onMediaEnded?() }
                playbacks[display.id] = playback
            }
        }
        for id in playbacks.keys where !retained.contains(id) {
            playbacks.removeValue(forKey: id)?.close()
        }
    }

    private func currentItem(in state: LibraryState) -> WallpaperItem? {
        if state.settings.playlistMode,
           state.settings.playlist.indices.contains(state.settings.playlistIndex) {
            let id = state.settings.playlist[state.settings.playlistIndex]
            if let item = state.wallpapers.first(where: { $0.id == id }) {
                return item
            }
        }
        if let id = state.defaultWallpaperID {
            return state.wallpapers.first(where: { $0.id == id })
        }
        return state.wallpapers.first
    }

    private func applyTransport(_ settings: StudioSettings) {
        lastSpeed = settings.playbackSpeed
        let paused = isPaused
        playbacks.values.forEach {
            $0.applyTransport(muted: settings.audioMuted, volume: settings.volume, speed: settings.playbackSpeed, paused: paused)
        }
        layer?.applyTransport(muted: settings.audioMuted, volume: settings.volume, speed: settings.playbackSpeed, paused: paused)
        web?.applyTransport(muted: settings.audioMuted, volume: settings.volume, speed: settings.playbackSpeed)
        if paused {
            web?.setPaused(true)
        }
    }

    private func updatePlaybackState() {
        if isPaused {
            pauseAll()
        } else {
            resumeAll(speed: lastSpeed)
        }
    }

    private func pauseAll() {
        playbacks.values.forEach { $0.pause() }
        layer?.player.pause()
        layer?.reader.pauseAutoTurn()
        web?.setPaused(true)
    }

    private func resumeAll(speed: Double) {
        guard !isContentHidden else { return }
        playbacks.values.forEach { $0.play(speed: speed) }
        layer?.applyTransport(
            muted: layer?.player.isMuted ?? true,
            volume: Double((layer?.player.volume ?? 0) * 100),
            speed: speed,
            paused: false
        )
        layer?.reader.resumeAutoTurn()
        web?.setPaused(false)
    }

    private func closeVideos() {
        playbacks.values.forEach { $0.close() }
        playbacks.removeAll()
    }
}
