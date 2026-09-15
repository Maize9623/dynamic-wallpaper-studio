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
    let wallpaperID: UUID
    let window: NSWindow
    let player: AVQueuePlayer
    let looper: AVPlayerLooper
    let wallpaperView: WallpaperView
    private(set) var mode: AspectMode

    init(displayID: String, wallpaperID: UUID, videoURL: URL, screen: NSScreen, mode: AspectMode) {
        self.displayID = displayID
        self.wallpaperID = wallpaperID
        self.mode = mode

        player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: videoURL)
        looper = AVPlayerLooper(player: player, templateItem: item)

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
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        player.play()
    }

    func setMode(_ newMode: AspectMode) {
        mode = newMode
        wallpaperView.playerLayer.videoGravity = newMode == .fit ? .resizeAspect : .resizeAspectFill
    }

    func pause() { player.pause() }
    func play() { player.play() }

    func close() {
        player.pause()
        wallpaperView.playerLayer.player = nil
        window.close()
    }
}

@MainActor
final class WallpaperEngine {
    private var playbacks: [String: DisplayPlayback] = [:]
    private(set) var isManuallyPaused = false
    private var isSystemPaused = false

    var isPaused: Bool { isManuallyPaused || isSystemPaused }

    func apply(state: LibraryState, store: LibraryStore) {
        let screens = NSScreen.screens
        var retainedIDs = Set<String>()

        for screen in screens {
            let display = Self.describe(screen: screen)
            retainedIDs.insert(display.id)
            let assignment = state.assignments[display.id]
                ?? state.defaultWallpaperID.map {
                    DisplayAssignment(wallpaperID: $0, aspectMode: state.defaultAspectMode)
                }

            guard let assignment,
                  let item = state.wallpapers.first(where: { $0.id == assignment.wallpaperID }) else {
                if let existing = playbacks.removeValue(forKey: display.id) {
                    existing.close()
                }
                continue
            }

            let videoURL = store.playbackURL(for: item)
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                if let existing = playbacks.removeValue(forKey: display.id) {
                    existing.close()
                }
                continue
            }

            if let existing = playbacks[display.id], existing.wallpaperID == item.id {
                existing.setMode(assignment.aspectMode)
                existing.window.setFrame(screen.frame, display: true)
            } else {
                playbacks.removeValue(forKey: display.id)?.close()
                playbacks[display.id] = DisplayPlayback(
                    displayID: display.id,
                    wallpaperID: item.id,
                    videoURL: videoURL,
                    screen: screen,
                    mode: assignment.aspectMode
                )
            }
        }

        for id in playbacks.keys where !retainedIDs.contains(id) {
            playbacks.removeValue(forKey: id)?.close()
        }

        if isPaused {
            playbacks.values.forEach { $0.pause() }
        } else {
            playbacks.values.forEach { $0.play() }
        }
    }

    func toggleManualPause() {
        isManuallyPaused.toggle()
        updatePlaybackState()
    }

    func setSystemPaused(_ paused: Bool) {
        isSystemPaused = paused
        updatePlaybackState()
    }

    func stop() {
        playbacks.values.forEach { $0.close() }
        playbacks.removeAll()
    }

    private func updatePlaybackState() {
        if isPaused {
            playbacks.values.forEach { $0.pause() }
        } else {
            playbacks.values.forEach { $0.play() }
        }
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
}
