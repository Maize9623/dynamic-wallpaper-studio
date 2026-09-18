import AppKit
import WebKit

final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private(set) var webView: WKWebView
    private(set) var lastSnapshot = WebPlaybackSnapshot.empty
    private var profileURL: URL?
    var pinnedToDesktop = false
    var onLocationChanged: (() -> Void)?
    var onCleanScreenChanged: ((Bool) -> Void)?
    private var cleanRetryWork: DispatchWorkItem?
    private var wantsCleanScreen = false

    var currentURL: String {
        webView.url?.absoluteString ?? ""
    }

    var hasHTTPDocument: Bool {
        guard let url = webView.url else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    var isReady: Bool { webView.url != nil }

    override init() {
        webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        configure(webView)
    }

    func ensure(profileURL: URL) {
        if self.profileURL == profileURL { return }
        self.profileURL = profileURL
        try? FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        let idURL = profileURL.appendingPathComponent("store-id.txt")
        let identifier: UUID
        if let text = try? String(contentsOf: idURL, encoding: .utf8),
           let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            identifier = uuid
        } else {
            identifier = UUID()
            try? identifier.uuidString.write(to: idURL, atomically: true, encoding: .utf8)
        }

        let store = WKWebsiteDataStore(forIdentifier: identifier)
        let replacement = WKWebView(frame: webView.frame, configuration: Self.makeConfiguration(store: store))
        configure(replacement)
        if let parent = webView.superview {
            replacement.frame = webView.frame
            replacement.autoresizingMask = webView.autoresizingMask
            parent.replaceSubview(webView, with: replacement)
        }
        webView = replacement
    }

    func navigate(_ raw: String) throws {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw NSError(domain: "WebSession", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请输入以 http:// 或 https:// 开头的完整网页地址。"
            ])
        }
        webView.load(URLRequest(url: url))
    }

    func place(in host: NSView, hitTest: Bool) {
        detach()
        host.layoutSubtreeIfNeeded()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        host.autoresizesSubviews = true
        host.addSubview(webView, positioned: .below, relativeTo: nil)
        webView.frame = host.bounds.isEmpty
            ? NSRect(origin: .zero, size: NSSize(width: max(host.frame.width, 800), height: max(host.frame.height, 400)))
            : host.bounds
        applyHostSettings(interactive: hitTest)
    }

    func detach() {
        webView.removeFromSuperview()
    }

    func applyHostSettings(interactive: Bool) {
        webView.isHidden = false
    }

    func setMuted(_ muted: Bool) {
        command(op: "mute", payload: ["muted": muted])
    }

    func setVolume(_ volume: Double) {
        command(op: "volume", payload: ["volume": min(max(volume, 0), 100) / 100.0])
    }

    func setPaused(_ paused: Bool) {
        command(op: "pause", payload: ["paused": paused])
    }

    func setSpeed(_ speed: Double) {
        command(op: "rate", payload: ["rate": speed])
    }

    func seek(_ seconds: Double) {
        command(op: "seek", payload: ["seconds": seconds])
    }

    func shortAdvance(_ direction: Int, keepClean: Bool = true) {
        wantsCleanScreen = keepClean
        let dir = direction >= 0 ? 1 : -1
        let clean = keepClean ? "true" : "false"
        evaluate(Self.installScript + "window.__dwpsClean=\(clean);window.__dwpsShort(\(dir));")
        if keepClean {
            scheduleCleanRetries(true)
        }
    }

    func applyCleanScreen(_ enabled: Bool) {
        wantsCleanScreen = enabled
        let clean = enabled ? "true" : "false"
        evaluate(Self.installScript + "window.__dwpsSetClean && window.__dwpsSetClean(\(clean));")
        if enabled {
            scheduleCleanRetries(true)
        } else {
            cleanRetryWork?.cancel()
        }
    }

    private func scheduleCleanRetries(_ enabled: Bool) {
        cleanRetryWork?.cancel()
        guard enabled else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.evaluate(Self.installScript + "window.__dwpsScheduleClean && window.__dwpsScheduleClean();")
        }
        cleanRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func applyTransport(muted: Bool, volume: Double, speed: Double) {
        command(op: "transport", payload: [
            "muted": muted,
            "volume": min(max(volume, 0), 100) / 100.0,
            "rate": speed
        ])
    }

    func refreshState(completion: (() -> Void)? = nil) {
        evaluate(Self.installScript + "window.__dwpsQuery();") { [weak self] result in
            guard let self else { return }
            self.lastSnapshot = Self.parseSnapshot(result, url: self.currentURL)
            completion?()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        evaluate(Self.installScript + "window.__dwpsKick && window.__dwpsKick();") { [weak self] result in
            guard let self else { return }
            self.lastSnapshot = Self.parseSnapshot(result, url: self.currentURL)
            if self.wantsCleanScreen {
                self.applyCleanScreen(true)
            }
        }
        onLocationChanged?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onLocationChanged?()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    static func looksLive(_ url: String) -> Bool {
        guard let uri = URL(string: url) else { return false }
        let host = uri.host?.lowercased() ?? ""
        let path = uri.path.lowercased()
        if host.contains("live.bilibili") || host.contains("live.douyin") || host.contains("live.kuaishou") {
            return true
        }
        if host.contains("huya.com") || host.contains("douyu.com") || host.contains("twitch.tv")
            || host.contains("cc.163.com") || host.contains("live.qq.com") {
            return true
        }
        if path.contains("/live") || path.contains("/room/") {
            return true
        }
        return false
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.customUserAgent = Self.safariUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        if #available(macOS 12.0, *) {
            view.underPageBackgroundColor = .black
        }
        if #available(macOS 13.3, *) {
            view.isInspectable = false
        }
        view.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        view.configuration.userContentController.add(self, name: Self.messageName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let clean = body["clean"] as? Bool else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCleanScreenChanged?(clean)
        }
    }

    private static func makeConfiguration(store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        if let store {
            configuration.websiteDataStore = store
        }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = false
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let script = WKUserScript(source: installScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(script)
        return configuration
    }

    private func command(op: String, payload: [String: Any]) {
        var map = payload
        map["op"] = op
        guard JSONSerialization.isValidJSONObject(map),
              let data = try? JSONSerialization.data(withJSONObject: map, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate(Self.installScript + "window.__dwpsCommand(\(json));") { [weak self] result in
            guard let self else { return }
            self.lastSnapshot = Self.parseSnapshot(result, url: self.currentURL)
        }
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(script) { result, _ in
            completion?(result)
        }
    }

    private static func parseSnapshot(_ raw: Any?, url: String) -> WebPlaybackSnapshot {
        let liveHint = looksLive(url)
        guard let object = raw as? [String: Any] else {
            return WebPlaybackSnapshot(ready: true, live: liveHint, paused: true, muted: true)
        }
        let live = bool(object["live"]) || liveHint
        let has = bool(object["has"])
        return WebPlaybackSnapshot(
            ready: true,
            live: live,
            paused: bool(object["paused"]),
            canPlay: has && !live,
            canSeek: has && !live && bool(object["canSeek"]),
            canRate: has && !live,
            muted: bool(object["muted"]),
            position: number(object["position"]),
            duration: number(object["duration"])
        )
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return false
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return 0
    }

    private static let messageName = "dwps"

    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    private static let installScript = """
    (() => {
      function collect(root, list) {
        if (!root) return;
        try {
          root.querySelectorAll('video,audio').forEach(m => list.push(m));
          root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) collect(el.shadowRoot, list); });
          root.querySelectorAll('iframe').forEach(f => { try { collect(f.contentDocument, list); } catch (e) {} });
        } catch (e) {}
      }
      function media() {
        const list = [];
        collect(document, list);
        return list.filter((m, i, a) => a.indexOf(m) === i);
      }
      function docs(root) {
        const out = [root];
        try {
          root.querySelectorAll('iframe').forEach(f => {
            try {
              if (f.contentDocument) docs(f.contentDocument).forEach(d => out.push(d));
            } catch (e) {}
          });
        } catch (e) {}
        return out;
      }
      function visible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 10 || r.height < 10) return false;
        const view = (el.ownerDocument && el.ownerDocument.defaultView) || window;
        const style = view.getComputedStyle ? view.getComputedStyle(el) : null;
        if (style && (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0)) return false;
        const vh = view.innerHeight || 800;
        const vw = view.innerWidth || 1200;
        return r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
      }
      function click(el) {
        if (!el) return false;
        try { el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true })); } catch (e) {}
        try { el.click(); return true; } catch (e) { return false; }
      }
      function largestVideo(root) {
        let best = null, area = 0;
        media().forEach(v => {
          if (!v || v.tagName !== 'VIDEO') return;
          const r = v.getBoundingClientRect();
          const a = Math.max(0, r.width) * Math.max(0, r.height);
          if (a > area) { area = a; best = v; }
        });
        return best;
      }
      function scrollable(el) {
        let node = el;
        while (node && node !== document.documentElement && node !== document.body) {
          const style = window.getComputedStyle(node);
          const oy = style.overflowY;
          if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') && node.scrollHeight > node.clientHeight + 24) return node;
          node = node.parentElement;
        }
        return document.scrollingElement || document.documentElement;
      }
      function fireWheel(target, delta) {
        if (!target) return;
        const opts = { bubbles: true, cancelable: true, composed: true, deltaY: delta, deltaMode: 0 };
        try { target.dispatchEvent(new WheelEvent('wheel', opts)); } catch (e) {}
      }
      function fireKey(target, down) {
        const key = down ? 'ArrowDown' : 'ArrowUp';
        const keyCode = down ? 40 : 38;
        const opts = { key: key, code: key, keyCode: keyCode, which: keyCode, bubbles: true, cancelable: true, composed: true };
        ['keydown', 'keyup'].forEach(type => {
          try { target.dispatchEvent(new KeyboardEvent(type, opts)); } catch (e) {}
        });
      }
      function labelOf(el) {
        return ((el.getAttribute && el.getAttribute('aria-label')) || '') + ((el.getAttribute && el.getAttribute('title')) || '') + (el.textContent || '');
      }
      function compact(text) {
        return String(text || '').split(' ').join('').split('\\n').join('');
      }
      function isCleanButton(el) {
        if (!el) return false;
        const t = compact(labelOf(el));
        return t === '清屏' || t === '退出清屏' || t === '清屏模式';
      }
      function findCleanButton() {
        for (const doc of docs(document)) {
          const nodes = Array.from(doc.querySelectorAll('button, [role="button"], div, span, p'));
          for (const el of nodes) {
            if (!visible(el) || !isCleanButton(el)) continue;
            return { el: el, on: compact(labelOf(el)) === '退出清屏' };
          }
        }
        return null;
      }
      function inPlayer() {
        const video = largestVideo(document);
        if (!video) return false;
        const box = video.getBoundingClientRect();
        return box.height > window.innerHeight * 0.42 && box.width > window.innerWidth * 0.22;
      }
      function restoreHidden() {
        for (const doc of docs(document)) {
          doc.querySelectorAll('[data-dwps-clean]').forEach(el => {
            el.style.removeProperty('display');
            el.removeAttribute('data-dwps-clean');
          });
        }
      }
      function hideSocialNodes() {
        if (!window.__dwpsClean || !inPlayer()) return;
        const words = ['点赞', '收藏', '评论', '分享', '喜欢', '关注'];
        for (const doc of docs(document)) {
          const nodes = Array.from(doc.querySelectorAll('button, [role="button"], [data-e2e], span, div'));
          for (const el of nodes) {
            if (!visible(el) || el.getAttribute('data-dwps-clean')) continue;
            const t = compact(labelOf(el));
            if (t.length === 0 || t.length > 6) continue;
            if (t.indexOf('清屏') >= 0) continue;
            if (!words.some(w => t === w || t.indexOf(w) === 0)) continue;
            const r = el.getBoundingClientRect();
            if (r.left < window.innerWidth * 0.58) continue;
            let target = el.parentElement && el.parentElement.childElementCount <= 8 ? el.parentElement : el;
            target.style.setProperty('display', 'none', 'important');
            target.setAttribute('data-dwps-clean', '1');
          }
        }
      }
      function socialVisible() {
        const sels = ['[data-e2e="feed-like-icon"]', '[data-e2e="like-icon"]', '[data-e2e="feed-collect-icon"]', 'button[aria-label*="点赞"]', 'button[aria-label*="收藏"]'];
        for (const doc of docs(document)) {
          for (const sel of sels) {
            if (Array.from(doc.querySelectorAll(sel)).some(visible)) return true;
          }
        }
        return false;
      }
      function ensureCleanStyle(on) {
        let el = document.getElementById('__dwpsCleanStyle');
        if (!on || !inPlayer()) {
          if (el) el.remove();
          restoreHidden();
          return;
        }
        if (!el) {
          el = document.createElement('style');
          el.id = '__dwpsCleanStyle';
          (document.head || document.documentElement).appendChild(el);
        }
        el.textContent = [
          '[data-e2e="feed-like-icon"],[data-e2e="feed-comment-icon"],[data-e2e="feed-collect-icon"],[data-e2e="feed-share-icon"],',
          '[data-e2e="like-icon"],[data-e2e="comment-icon"],[data-e2e="collect-icon"],[data-e2e="share-icon"],',
          '[data-e2e="video-player-digg"],[data-e2e="browse-like"],[data-e2e="browse-favorite"],',
          '[data-e2e="video-info"],[data-e2e="video-desc"],[data-e2e="video-player-detaill"],',
          '[class*="videoSideBar"],[class*="positionSideBar"],[class*="actionBar"],[class*="ActionBar"],',
          '[class*="right-action"],[class*="interaction-panel"],[class*="PlayerAction"],',
          '.xgplayer-controls,.xgplayer-progress,[class*="related-video"]',
          '{display:none !important;visibility:hidden !important;opacity:0 !important;pointer-events:none !important;}'
        ].join('');
      }
      function notifyClean(on) {
        try { window.webkit.messageHandlers.dwps.postMessage({ clean: !!on }); } catch (e) {}
      }
      window.__dwpsApplyClean = function () {
        if (!window.__dwpsClean) {
          ensureCleanStyle(false);
          return { ok: true, clean: false };
        }
        ensureCleanStyle(true);
        hideSocialNodes();
        const btn = findCleanButton();
        if (btn && !btn.on && socialVisible()) click(btn.el);
        return { ok: true, clean: true };
      };
      window.__dwpsScheduleClean = function () {
        if (!window.__dwpsClean) return;
        [50, 240, 640, 1300, 2200].forEach(ms => setTimeout(() => window.__dwpsApplyClean(), ms));
      };
      window.__dwpsSetClean = function (on) {
        window.__dwpsClean = !!on;
        if (on) {
          window.__dwpsApplyClean();
          window.__dwpsScheduleClean();
        } else {
          ensureCleanStyle(false);
          const btn = findCleanButton();
          if (btn && btn.on) click(btn.el);
        }
        return { ok: true, clean: !!on };
      };
      window.__dwpsShort = function (dir) {
        const result = window.__dwpsShortGo(dir);
        window.__dwpsScheduleClean();
        return result;
      };
      window.__dwpsShortGo = function (dir) {
        const down = Number(dir) >= 0;
        const nextSels = [
          '[data-e2e="arrow-down"]', '[data-e2e="video-switch-next"]', '[data-e2e="browse-next"]',
          '[data-e2e="arrow-right"]', '.xgplayer-playswitch-next', '[class*="arrow-down"]',
          '[class*="ArrowDown"]', 'button[aria-label*="下一个"]', 'button[aria-label*="下一条"]',
          'button[title*="下一个"]', 'button[title*="下一条"]'
        ];
        const prevSels = [
          '[data-e2e="arrow-up"]', '[data-e2e="video-switch-prev"]', '[data-e2e="browse-prev"]',
          '[data-e2e="arrow-left"]', '.xgplayer-playswitch-prev', '[class*="arrow-up"]',
          '[class*="ArrowUp"]', 'button[aria-label*="上一个"]', 'button[aria-label*="上一条"]',
          'button[title*="上一个"]', 'button[title*="上一条"]'
        ];
        const sels = down ? nextSels : prevSels;
        for (const doc of docs(document)) {
          for (const sel of sels) {
            const nodes = Array.from(doc.querySelectorAll(sel)).filter(visible);
            if (nodes.length && click(nodes[0])) return { ok: true, via: sel };
          }
        }
        const labels = down
          ? ['下一个视频', '下一条视频', '下一个作品', '下一条', '下一个']
          : ['上一个视频', '上一条视频', '上一个作品', '上一条', '上一个'];
        for (const doc of docs(document)) {
          const nodes = Array.from(doc.querySelectorAll('button, [role="button"], div[class*="arrow"], span[class*="arrow"]'));
          for (const el of nodes) {
            if (!visible(el)) continue;
            const t = ((el.getAttribute('aria-label') || '') + (el.getAttribute('title') || '') + (el.innerText || '')).split(' ').join('');
            if (labels.some(label => t.indexOf(label) >= 0) && click(el)) return { ok: true, via: t };
          }
        }
        const video = largestVideo(document);
        const box = video ? video.getBoundingClientRect() : { width: 0, height: 0 };
        const inPlayer = box.height > window.innerHeight * 0.42 && box.width > window.innerWidth * 0.22;
        if (!inPlayer) {
          if (video) {
            let node = video;
            for (let i = 0; i < 10 && node; i++) {
              const href = (node.getAttribute && (node.getAttribute('href') || '')) || '';
              const e2e = (node.getAttribute && (node.getAttribute('data-e2e') || '')) || '';
              const cls = (node.className && String(node.className)) || '';
              if (node.tagName === 'A' || href.indexOf('/video') >= 0 || e2e.indexOf('video') >= 0 || e2e.indexOf('feed') >= 0 || cls.indexOf('card') >= 0) {
                if (visible(node) && click(node)) return { ok: true, via: 'card-ancestor' };
              }
              node = node.parentElement;
            }
            if (click(video)) return { ok: true, via: 'video-el' };
          }
          const cards = Array.from(document.querySelectorAll(
            '[data-e2e="recommend-list-item-container"], [data-e2e="feed-item"], [data-e2e*="video-card"], a[href*="/video/"], a[href*="/note/"], a[href*="/jingxuan"]'
          )).filter(visible);
          if (cards.length && click(cards[down ? 0 : cards.length - 1])) return { ok: true, via: 'card' };
        }
        const delta = down ? 920 : -920;
        if (video) {
          fireWheel(video, delta);
          fireWheel(video.parentElement, delta);
          const sc = scrollable(video);
          if (sc) {
            try { sc.scrollBy(0, down ? sc.clientHeight : -sc.clientHeight); } catch (e) {}
          }
        }
        try {
          const page = document.scrollingElement || document.documentElement;
          page.scrollBy(0, down ? window.innerHeight * 0.94 : -window.innerHeight * 0.94);
        } catch (e) {}
        [window, document, document.activeElement, video, document.body].filter(Boolean).forEach(t => fireKey(t, down));
        return { ok: true, via: 'combo' };
      };
      if (window.__dwpsReady) return;
      window.__dwpsClean = !!window.__dwpsClean;
      window.__dwpsState = Object.assign({ muted: true, volume: 0.7, rate: 1, paused: null }, window.__dwpsState || {});
      function apply() {
        const s = window.__dwpsState;
        media().forEach(m => {
          try {
            if (m.muted !== !!s.muted) m.muted = !!s.muted;
          } catch (e) {}
          if (!s.muted) {
            try {
              const v = Math.max(0, Math.min(1, Number(s.volume)));
              if (Math.abs((m.volume || 0) - v) > 0.02) m.volume = v;
            } catch (e) {}
          }
          const live = !isFinite(m.duration) || m.duration === Infinity;
          if (!live && s.rate) {
            try {
              if (Math.abs(m.playbackRate - s.rate) > 0.02) m.playbackRate = s.rate;
            } catch (e) {}
          }
          if (s.paused === true && !m.paused) { try { m.pause(); } catch (e) {} }
          if (s.paused === false && m.paused) { try { m.play().catch(() => {}); } catch (e) {} }
        });
      }
      let applyTimer = null;
      function scheduleApply() {
        if (applyTimer) return;
        applyTimer = setTimeout(() => { applyTimer = null; apply(); }, 240);
      }
      function looksMedia(node) {
        if (!node) return false;
        const name = node.tagName;
        if (name === 'VIDEO' || name === 'AUDIO') return true;
        if (node.nodeType === 1 && node.querySelector) {
          try { return !!node.querySelector('video,audio'); } catch (e) { return false; }
        }
        return false;
      }
      window.__dwpsCommand = function (cmd) {
        const s = window.__dwpsState;
        if (cmd.op === 'mute' || cmd.op === 'transport') s.muted = !!cmd.muted;
        if (cmd.op === 'volume' || cmd.op === 'transport') s.volume = Number(cmd.volume);
        if (cmd.op === 'rate' || cmd.op === 'transport') s.rate = Number(cmd.rate);
        if (cmd.op === 'pause') s.paused = !!cmd.paused;
        if (cmd.op === 'seek') media().forEach(m => { try { if (isFinite(m.duration)) m.currentTime = Number(cmd.seconds); } catch (e) {} });
        apply();
        return window.__dwpsQuery();
      };
      window.__dwpsQuery = function () {
        const list = media();
        const m = list.find(x => x.readyState > 0) || list[0];
        if (!m) return { has: false, live: false, paused: true, canSeek: false, muted: !!window.__dwpsState.muted, position: 0, duration: 0 };
        const live = !isFinite(m.duration) || m.duration === Infinity || (m.seekable && m.seekable.length === 0 && m.duration > 0);
        return {
          has: true,
          live: !!live,
          paused: !!m.paused,
          canSeek: !live && isFinite(m.duration) && m.duration > 0,
          muted: !!m.muted,
          position: isFinite(m.currentTime) ? m.currentTime : 0,
          duration: isFinite(m.duration) ? m.duration : 0
        };
      };
      window.__dwpsKick = function () {
        const href = (location && location.href) || '';
        const livePage = href.indexOf('live.') >= 0 || href.indexOf('/live') >= 0 || href.indexOf('/room/') >= 0;
        media().forEach(m => {
          try {
            const live = livePage || !isFinite(m.duration) || m.duration === Infinity;
            if (m.paused && live) {
              if (m.muted !== !!window.__dwpsState.muted) m.muted = !!window.__dwpsState.muted;
              m.play().catch(() => {});
            }
          } catch (e) {}
        });
        apply();
        return window.__dwpsQuery();
      };
      if (document.documentElement) {
        new MutationObserver(muts => {
          for (const m of muts) {
            for (const n of m.addedNodes) {
              if (looksMedia(n)) { scheduleApply(); break; }
            }
          }
          if (window.__dwpsClean) {
            if (!window.__dwpsCleanMutTimer) {
              window.__dwpsCleanMutTimer = setTimeout(() => {
                window.__dwpsCleanMutTimer = null;
                window.__dwpsApplyClean();
              }, 320);
            }
          }
        }).observe(document.documentElement, { childList: true, subtree: true });
      }
      document.addEventListener('click', ev => {
        if (!ev.isTrusted) return;
        let node = ev.target;
        for (let i = 0; i < 6 && node; i++) {
          if (isCleanButton(node)) {
            setTimeout(() => {
              const btn = findCleanButton();
              const on = btn ? btn.on : true;
              window.__dwpsClean = on;
              notifyClean(on);
              window.__dwpsSetClean(on);
            }, 60);
            return;
          }
          node = node.parentElement;
        }
      }, true);
      window.addEventListener('resize', () => {
        if (window.__dwpsClean) window.__dwpsScheduleClean();
      });
      apply();
      window.__dwpsReady = true;
    })();
    """
}
