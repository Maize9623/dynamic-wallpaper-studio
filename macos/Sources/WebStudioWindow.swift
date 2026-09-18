import AppKit
import WebKit

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WebStudioWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let model: AppModel
    private let hostView = WebHostView()
    private let addressField = NSTextField()
    private var overlay: NSView?
    private var isEditingAddress = false

    init(model: AppModel) {
        self.model = model

        let chrome = NSView()
        chrome.wantsLayer = true
        chrome.layer?.backgroundColor = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1).cgColor

        let hint = Self.wrappingLabel(
            "在这个独立页面里登录、开网页全屏、开关弹幕。调好后点「同步到桌面」，桌面会保持这一页，不必在壁纸上点鼠标。登录只存在资料库的 WebProfile，不读系统浏览器 Cookie，不破解 DRM。",
            size: 13,
            color: NSColor(srgbRed: 208 / 255, green: 213 / 255, blue: 221 / 255, alpha: 1)
        )
        let warning = Self.wrappingLabel(
            "腾讯视频等 Widevine 站点可能黑屏或提示换浏览器，这是站点限制。",
            size: 12,
            color: NSColor(srgbRed: 247 / 255, green: 144 / 255, blue: 9 / 255, alpha: 1)
        )

        addressField.placeholderString = "https://"
        addressField.bezelStyle = .roundedBezel
        addressField.isEditable = true
        addressField.isSelectable = true
        addressField.font = .systemFont(ofSize: 13)
        addressField.lineBreakMode = .byTruncatingMiddle

        let goButton = Self.chromeButton(title: "前往", prominent: false)
        let prevButton = Self.chromeButton(title: "上一条", prominent: false)
        let nextButton = Self.chromeButton(title: "下一条", prominent: false)
        let syncButton = Self.chromeButton(title: "同步到桌面", prominent: true)
        let recallButton = Self.chromeButton(title: "取回编辑", prominent: false)
        goButton.action = #selector(go)
        prevButton.action = #selector(shortPrevious)
        nextButton.action = #selector(shortNext)
        syncButton.action = #selector(syncToDesktop)
        recallButton.action = #selector(recallFromDesktop)

        let buttons = NSStackView(views: [addressField, goButton, prevButton, nextButton, syncButton, recallButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [hint, warning, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)

        let root = NSView()
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "网页直播 · 独立页面"
        window.contentView = root
        window.minSize = NSSize(width: 800, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        window.acceptsMouseMovedEvents = true

        root.addSubview(chrome)
        root.addSubview(hostView)
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.black.cgColor
        chrome.translatesAutoresizingMaskIntoConstraints = false
        hostView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -12),
            addressField.heightAnchor.constraint(equalToConstant: 24),
            chrome.topAnchor.constraint(equalTo: root.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hostView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        super.init(window: window)
        window.delegate = self
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(go)
        goButton.target = self
        prevButton.target = self
        nextButton.target = self
        syncButton.target = self
        recallButton.target = self
        model.webStudioHost = hostView
        model.onWebStudioRefresh = { [weak self] in
            self?.refreshOverlay()
            self?.syncAddressIfIdle()
        }
        syncAddressIfIdle()
        refreshOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    var host: NSView { hostView }

    func windowDidBecomeKey(_ notification: Notification) {
        focusPageIfNeeded()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingAddress = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditingAddress = false
        syncAddressIfIdle()
    }

    func refreshOverlay() {
        overlay?.removeFromSuperview()
        overlay = nil
        guard model.web.pinnedToDesktop else {
            focusPageIfNeeded()
            return
        }
        let cover = NSView(frame: hostView.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 0.9).cgColor
        cover.autoresizingMask = [.width, .height]
        let label = NSTextField(labelWithString: "已同步到桌面")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let detail = NSTextField(wrappingLabelWithString: "这一页正在桌面层播放，壁纸上不能点。要改全屏、弹幕或换房间，先点「取回编辑」，改完再同步。")
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = NSColor(srgbRed: 208 / 255, green: 213 / 255, blue: 221 / 255, alpha: 1)
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 520
        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])
        hostView.addSubview(cover)
        overlay = cover
    }

    func windowWillClose(_ notification: Notification) {
        model.onWebStudioRefresh = nil
        model.notifyWebStudioClosed()
    }

    @objc private func shortPrevious() {
        model.webShortAdvance(-1)
    }

    @objc private func shortNext() {
        model.webShortAdvance(1)
    }

    @objc private func go() {
        isEditingAddress = false
        window?.makeFirstResponder(nil)
        let text = addressField.stringValue
        Task { @MainActor in
            await model.navigateWebStudio(text)
            self.syncAddressIfIdle()
            self.focusPageIfNeeded()
        }
    }

    @objc private func syncToDesktop() {
        Task { @MainActor in
            await model.syncWebToDesktop()
            self.refreshOverlay()
        }
    }

    @objc private func recallFromDesktop() {
        model.recallWebFromDesktop()
        refreshOverlay()
        focusPageIfNeeded()
    }

    private func syncAddressIfIdle() {
        guard !isEditingAddress, addressField.currentEditor() == nil else { return }
        let current = model.web.currentURL
        addressField.stringValue = current.isEmpty
            ? (model.state.settings.webURL.isEmpty ? "https://live.bilibili.com" : model.state.settings.webURL)
            : current
    }

    private func focusPageIfNeeded() {
        guard !model.web.pinnedToDesktop, let window else { return }
        if window.firstResponder is NSTextView { return }
        window.makeFirstResponder(model.web.webView)
    }

    private static func chromeButton(title: String, prominent: Bool) -> NSButton {
        let button = ChromeButton()
        button.title = title
        button.isBordered = false
        button.focusRingType = .none
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if prominent {
            button.fillColor = NSColor(srgbRed: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1)
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
            ])
        } else {
            button.fillColor = NSColor(srgbRed: 241 / 255, green: 245 / 255, blue: 249 / 255, alpha: 1)
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor(srgbRed: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1),
                .font: NSFont.systemFont(ofSize: 13, weight: .medium)
            ])
        }
        return button
    }

    private static func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

final class ChromeButton: NSButton {
    var fillColor = NSColor.white

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 22, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let titleSize = attributedTitle.size()
        let origin = NSPoint(
            x: ((bounds.width - titleSize.width) / 2).rounded(.down),
            y: ((bounds.height - titleSize.height) / 2).rounded(.down)
        )
        attributedTitle.draw(at: origin)
    }
}

final class WebHostView: NSView {
    override func layout() {
        super.layout()
        for subview in subviews {
            if subview is WKWebView {
                subview.frame = bounds
            }
        }
    }
}
