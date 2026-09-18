import AppKit
import Combine
import SwiftUI

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let root = MainView().environmentObject(model)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "摸鱼神器 · 动态壁纸工作室"
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 1000, height: 640)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.isDropTarget = false
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?
    private let bossHotkey = BossHotkeyService()
    private var playbackTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        createMainWindow()
        createStatusItem()
        installSystemObservers()

        model.onChange = { [weak self] in
            self?.updateStatusItem()
        }
        model.onOpenWindow = { [weak self] in
            self?.showMainWindow()
        }
        model.onHotkeyChange = { [weak self] in
            self?.applyHotkeys()
        }
        model.start()
        applyHotkeys()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.pollPlayback()
            }
        }

        let launchedInBackground = ProcessInfo.processInfo.arguments.contains("--background")
        if !launchedInBackground {
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        playbackTimer?.invalidate()
        playbackTimer = nil
        bossHotkey.unregister()
        model.applicationWillTerminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.enqueueImports(urls)
        showMainWindow()
    }

    private func createMainWindow() {
        mainWindowController = MainWindowController(model: model)
    }

    @objc private func showMainWindow() {
        guard let window = mainWindowController?.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "关于摸鱼神器", action: #selector(openAbout), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "隐藏动态壁纸工作室", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "退出动态壁纸工作室", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let importItem = NSMenuItem(title: "导入视频或电子书…", action: #selector(openImport), keyEquivalent: "o")
        importItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(importItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openImport() {
        showMainWindow()
        model.openImportPanel()
    }

    @objc private func openAbout() {
        model.filter = .settings
        showMainWindow()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "动态壁纸工作室"
        )
        item.button?.toolTip = "摸鱼神器 · 动态壁纸工作室"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "动态壁纸工作室", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let currentID = model.state.defaultWallpaperID,
           let current = model.state.wallpapers.first(where: { $0.id == currentID }) {
            let currentItem = NSMenuItem(title: "\(current.name) · \(current.resolutionText)", action: nil, keyEquivalent: "")
            currentItem.isEnabled = false
            menu.addItem(currentItem)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem(
            model.isPaused ? "继续播放" : "暂停动态壁纸",
            action: #selector(togglePause),
            symbol: model.isPaused ? "play.fill" : "pause.fill"
        ))
        menu.addItem(actionItem("上一张收藏", action: #selector(previousFavorite), symbol: "backward.end.fill"))
        menu.addItem(actionItem("下一张收藏", action: #selector(nextFavorite), symbol: "forward.end.fill"))
        menu.addItem(actionItem(
            model.state.settings.audioMuted ? "取消静音" : "静音",
            action: #selector(toggleMute),
            symbol: model.state.settings.audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        ))
        menu.addItem(actionItem(
            model.state.settings.televisionOff ? "打开电视" : "关电视",
            action: #selector(toggleTelevision),
            symbol: "tv"
        ))
        menu.addItem(actionItem(
            model.state.settings.bossHidden ? "恢复桌面内容" : "老板键隐藏",
            action: #selector(toggleBoss),
            symbol: "eye.slash"
        ))

        let modeItem = NSMenuItem(title: "画面适配", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let fit = NSMenuItem(title: "完整显示", action: #selector(selectFit), keyEquivalent: "")
        fit.state = model.state.defaultAspectMode == .fit ? .on : .off
        let fill = NSMenuItem(title: "填满屏幕", action: #selector(selectFill), keyEquivalent: "")
        fill.state = model.state.defaultAspectMode == .fill ? .on : .off
        modeMenu.addItem(fit)
        modeMenu.addItem(fill)
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())
        menu.addItem(actionItem("打开动态壁纸工作室…", action: #selector(showMainWindow), symbol: "photo.stack"))
        menu.addItem(actionItem("导入视频或电子书…", action: #selector(openImport), symbol: "plus"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出动态壁纸工作室", action: #selector(quitApp), keyEquivalent: "q"))
    }

    private func actionItem(_ title: String, action: Selector, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func updateStatusItem() {
        statusItem?.isVisible = model.state.settings.showMenuBarControl
        statusItem?.button?.image = NSImage(
            systemSymbolName: model.isPaused ? "photo.on.rectangle.angled" : "photo.on.rectangle.angled",
            accessibilityDescription: "动态壁纸工作室"
        )
    }

    @objc private func togglePause() { model.togglePause() }
    @objc private func previousFavorite() { model.switchFavorite(direction: -1) }
    @objc private func nextFavorite() { model.switchFavorite(direction: 1) }
    @objc private func toggleMute() { model.toggleMuted() }
    @objc private func toggleTelevision() { model.toggleTelevision() }
    @objc private func toggleBoss() { model.toggleBossKey() }

    private func applyHotkeys() {
        bossHotkey.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .boss:
                self.model.toggleBossKey()
            case .readerPrev:
                self.model.handleSharedAdvanceHotkey(next: false)
            case .readerNext:
                self.model.handleSharedAdvanceHotkey(next: true)
            case .readerPause:
                self.model.handleSharedPauseHotkey()
            }
        }
        do {
            try bossHotkey.apply([
                (.boss, model.state.settings.bossHotkey, model.state.settings.bossHotkeyEnabled),
                (.readerPrev, model.state.settings.readerPreviousHotkey, model.state.settings.readerHotkeysEnabled),
                (.readerNext, model.state.settings.readerNextHotkey, model.state.settings.readerHotkeysEnabled),
                (.readerPause, model.state.settings.readerPauseHotkey, model.state.settings.readerHotkeysEnabled)
            ])
        } catch {
            model.alert = StudioAlert(title: "无法注册快捷键", message: error.localizedDescription)
        }
    }
    @objc private func selectFit() { model.setAspectMode(.fit) }
    @objc private func selectFill() { model.setAspectMode(.fill) }
    @objc private func quitApp() { model.quit() }

    private func installSystemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        model.refreshDisplays()
    }

    @objc private func screensDidSleep() {
        guard model.state.settings.pauseOnDisplaySleep else { return }
        model.systemPause(true)
    }

    @objc private func screensDidWake() {
        guard model.state.settings.pauseOnDisplaySleep else { return }
        if model.isContentHidden { return }
        model.systemPause(false)
    }

    @objc private func sessionDidResignActive() {
        guard model.state.settings.pauseOnSessionLock else { return }
        model.systemPause(true)
    }

    @objc private func sessionDidBecomeActive() {
        guard model.state.settings.pauseOnSessionLock else { return }
        if model.isContentHidden { return }
        model.systemPause(false)
    }
}

@main
struct DynamicWallpaperStudioMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
