import AppKit
import PDFKit

final class ReaderSurface: FlippedView {
    var onPositionChanged: ((ReaderPosition) -> Void)?

    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let scrollTextView = NSTextView()
    private let pdfView = PDFView()
    private var position = ReaderPosition()
    private var kind: BookKind = .text
    private var rawText = ""
    private var textPages: [String] = []
    private var pageTimer: Timer?
    private var scrollTimer: Timer?
    private var lastEmittedOffset = 0.0
    private var isNotifying = false
    private var lastPageSize: CGSize = .zero

    var usesContinuousScroll: Bool {
        kind != .pdf && position.advanceMode == .scroll
    }

    var isAutoAdvancePaused: Bool { position.autoAdvancePaused }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        configure(textView)
        configure(scrollTextView)
        scrollTextView.isVerticallyResizable = true
        scrollTextView.isHorizontallyResizable = false
        scrollTextView.minSize = .zero
        scrollTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollTextView.autoresizingMask = [.width]
        if let container = scrollTextView.textContainer {
            container.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
            container.heightTracksTextView = false
        }

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = scrollTextView

        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.backgroundColor = .clear
        pdfView.autoresizingMask = [.width, .height]

        addSubview(textView)
        addSubview(scrollView)
        addSubview(pdfView)
        applyTheme(.dark, notify: false)
        applyFontSize(22, notify: false)
        layoutChildren()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unsupported")
    }

    override func layout() {
        super.layout()
        layoutChildren()
        if usesContinuousScroll {
            applyScrollLayout(restoreOffset: false)
            return
        }
        let size = pageSize()
        if kind != .pdf, !rawText.isEmpty, abs(size.width - lastPageSize.width) > 2 || abs(size.height - lastPageSize.height) > 2 {
            paginateText()
            showCurrent()
        }
    }

    func loadText(_ text: String, position: ReaderPosition, kind: BookKind = .text) {
        self.kind = kind == .pdf ? .text : kind
        rawText = text
        self.position = position
        pdfView.isHidden = true
        applyTheme(position.theme, notify: false)
        applyFontSize(position.fontSize, notify: false)
        layoutChildren()
        applyPresentation(notify: false)
        startAdvanceIfNeeded()
        needsDisplay = true
        emit()
    }

    func loadPDF(url: URL, position: ReaderPosition) throws {
        kind = .pdf
        self.position = position
        if self.position.advanceMode == .scroll {
            self.position.advanceMode = .page
        }
        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "ReaderSurface", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法打开这份 PDF。"
            ])
        }
        guard document.pageCount > 0 else {
            throw NSError(domain: "ReaderSurface", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "这份 PDF 没有可显示的页面。"
            ])
        }
        pdfView.document = document
        pdfView.isHidden = false
        textView.isHidden = true
        scrollView.isHidden = true
        applyTheme(position.theme, notify: false)
        self.position.pageIndex = min(max(0, position.pageIndex), document.pageCount - 1)
        if let page = document.page(at: self.position.pageIndex) {
            pdfView.go(to: page)
        }
        startAdvanceIfNeeded()
        emit()
    }

    func nextPage() -> Bool {
        if usesContinuousScroll {
            return jumpScroll(by: pageStride())
        }
        let last = lastPageIndex()
        guard position.pageIndex < last else { return false }
        position.pageIndex += 1
        showCurrent()
        emit()
        return true
    }

    func previousPage() -> Bool {
        if usesContinuousScroll {
            return jumpScroll(by: -pageStride())
        }
        guard position.pageIndex > 0 else { return false }
        position.pageIndex -= 1
        showCurrent()
        emit()
        return true
    }

    func pageInfo() -> (current: Int, total: Int) {
        (position.pageIndex + 1, lastPageIndex() + 1)
    }

    func scrollProgress() -> Double {
        let maximum = maxScrollOffset()
        guard maximum > 0 else { return 0 }
        return min(max(currentScrollOffset() / maximum, 0), 1)
    }

    func applyFontSize(_ size: Double, notify: Bool = true) {
        position.fontSize = min(max(size, 14), 48)
        let font = NSFont.systemFont(ofSize: position.fontSize)
        let style = paragraphStyle(lineHeight: position.fontSize * 1.55)
        textView.font = font
        textView.defaultParagraphStyle = style
        scrollTextView.font = font
        scrollTextView.defaultParagraphStyle = style
        if usesContinuousScroll {
            applyScrollLayout(restoreOffset: true)
        } else if kind != .pdf {
            paginateText()
            showCurrent()
        }
        if notify { emit() }
    }

    func applyTheme(_ theme: ReaderTheme, notify: Bool = true) {
        position.theme = theme
        let background: NSColor
        let foreground: NSColor
        if theme == .light {
            background = NSColor(srgbRed: 244 / 255, green: 238 / 255, blue: 226 / 255, alpha: 1)
            foreground = NSColor(srgbRed: 48 / 255, green: 40 / 255, blue: 32 / 255, alpha: 1)
        } else {
            background = NSColor(srgbRed: 20 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
            foreground = NSColor(srgbRed: 232 / 255, green: 220 / 255, blue: 200 / 255, alpha: 1)
        }
        layer?.backgroundColor = background.cgColor
        textView.backgroundColor = background
        textView.textColor = foreground
        scrollTextView.backgroundColor = background
        scrollTextView.textColor = foreground
        scrollView.backgroundColor = background
        pdfView.backgroundColor = background
        if notify { emit() }
    }

    func setAdvance(
        _ mode: ReaderAdvanceMode,
        pageSeconds: Double,
        scrollSpeed: Double,
        notify: Bool = true
    ) {
        let previous = position.advanceMode
        position.advanceMode = mode
        position.autoTurn = mode == .page
        position.autoTurnSeconds = min(max(pageSeconds, 3), 120)
        position.scrollSpeed = min(max(scrollSpeed, 8), 80)
        if mode == .off {
            position.autoAdvancePaused = false
        }
        if previous != mode {
            applyPresentation(notify: false)
        }
        startAdvanceIfNeeded()
        if notify { emit() }
    }

    func setAutoTurn(_ enabled: Bool, seconds: Double, notify: Bool = true) {
        setAdvance(enabled ? .page : .off, pageSeconds: seconds, scrollSpeed: position.scrollSpeed, notify: notify)
    }

    func setScrollSpeed(_ speed: Double, notify: Bool = true) {
        position.scrollSpeed = min(max(speed, 8), 80)
        if usesContinuousScroll, !position.autoAdvancePaused, position.advanceMode == .scroll {
            startAdvanceIfNeeded()
        }
        if notify { emit() }
    }

    func setAutoAdvancePaused(_ paused: Bool, notify: Bool = true) {
        position.autoAdvancePaused = paused
        if paused {
            stopTimers()
            captureScrollOffset()
        } else {
            startAdvanceIfNeeded()
        }
        if notify { emit() }
    }

    func toggleAutoAdvancePaused() {
        guard position.advanceMode != .off else { return }
        setAutoAdvancePaused(!position.autoAdvancePaused)
    }

    func pauseAutoTurn() {
        stopTimers()
    }

    func resumeAutoTurn() {
        startAdvanceIfNeeded()
    }

    func capture() -> ReaderPosition {
        captureScrollOffset()
        return position
    }

    func clear() {
        stopTimers()
        rawText = ""
        textPages = []
        textView.string = ""
        scrollTextView.string = ""
        pdfView.document = nil
    }

    private func configure(_ view: NSTextView) {
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.font = NSFont.systemFont(ofSize: 22)
        if let container = view.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
        }
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.autoresizingMask = [.width, .height]
    }

    private func applyPresentation(notify: Bool) {
        if usesContinuousScroll {
            textView.isHidden = true
            scrollView.isHidden = false
            pdfView.isHidden = true
            applyScrollContent()
            applyScrollLayout(restoreOffset: false)
            if position.scrollOffset <= 0, position.pageIndex > 0 {
                scrollTo(min(Double(position.pageIndex) * Double(pageStride()), maxScrollOffset()), emitChange: false)
            } else {
                scrollTo(position.scrollOffset, emitChange: false)
            }
        } else {
            if kind != .pdf, !scrollView.isHidden {
                let stride = max(Double(pageStride()), 1)
                position.pageIndex = Int((currentScrollOffset() / stride).rounded(.down))
            }
            scrollView.isHidden = true
            if kind == .pdf {
                textView.isHidden = true
                pdfView.isHidden = false
                showCurrent()
            } else {
                textView.isHidden = false
                pdfView.isHidden = true
                paginateText()
                showCurrent()
            }
        }
        if notify { emit() }
    }

    private func applyScrollContent() {
        scrollTextView.string = rawText.isEmpty ? "没有可显示的文本。" : rawText
        lastEmittedOffset = position.scrollOffset
    }

    private func applyScrollLayout(restoreOffset: Bool) {
        let width = max(120, bounds.width)
        scrollTextView.frame.size.width = width
        if let container = scrollTextView.textContainer {
            container.containerSize = NSSize(width: max(80, width - 8), height: CGFloat.greatestFiniteMagnitude)
            container.widthTracksTextView = true
        }
        scrollTextView.sizeToFit()
        if restoreOffset {
            scrollTo(position.scrollOffset, emitChange: false)
        }
    }

    private func startAdvanceIfNeeded() {
        stopTimers()
        guard !position.autoAdvancePaused else { return }
        switch position.advanceMode {
        case .off:
            return
        case .page:
            guard kind == .pdf || !usesContinuousScroll else { return }
            let timer = Timer(timeInterval: position.autoTurnSeconds, repeats: true) { [weak self] _ in
                _ = self?.nextPage()
            }
            RunLoop.main.add(timer, forMode: .common)
            pageTimer = timer
        case .scroll:
            guard usesContinuousScroll else { return }
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tickScroll()
            }
            RunLoop.main.add(timer, forMode: .common)
            scrollTimer = timer
        }
    }

    private func stopTimers() {
        pageTimer?.invalidate()
        pageTimer = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func tickScroll() {
        let maximum = maxScrollOffset()
        guard maximum > 0 else { return }
        let next = currentScrollOffset() + (position.scrollSpeed / 30.0)
        if next >= maximum - 0.5 {
            scrollTo(maximum, emitChange: true)
            stopTimers()
            return
        }
        scrollTo(next, emitChange: false)
        maybeEmitScroll()
    }

    @discardableResult
    private func jumpScroll(by delta: CGFloat) -> Bool {
        let maximum = maxScrollOffset()
        let current = currentScrollOffset()
        if delta > 0, current >= maximum - 0.5 { return false }
        if delta < 0, current <= 0.5 { return false }
        let next = min(max(current + Double(delta), 0), maximum)
        scrollTo(next, emitChange: true)
        return true
    }

    private func pageStride() -> CGFloat {
        max(80, scrollView.contentView.bounds.height * 0.92)
    }

    private func currentScrollOffset() -> Double {
        Double(scrollView.contentView.bounds.origin.y)
    }

    private func maxScrollOffset() -> Double {
        let documentHeight = scrollTextView.bounds.height
        let clipHeight = scrollView.contentView.bounds.height
        return max(0, Double(documentHeight - clipHeight))
    }

    private func scrollTo(_ offset: Double, emitChange: Bool) {
        let clamped = min(max(offset, 0), maxScrollOffset())
        position.scrollOffset = clamped
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if emitChange {
            lastEmittedOffset = clamped
            emit()
        }
    }

    private func captureScrollOffset() {
        guard usesContinuousScroll else { return }
        position.scrollOffset = currentScrollOffset()
    }

    private func maybeEmitScroll() {
        captureScrollOffset()
        if abs(position.scrollOffset - lastEmittedOffset) >= 24 {
            lastEmittedOffset = position.scrollOffset
            emit()
        }
    }

    private func lastPageIndex() -> Int {
        if kind == .pdf {
            return max(0, (pdfView.document?.pageCount ?? 1) - 1)
        }
        return max(0, textPages.count - 1)
    }

    private func showCurrent() {
        if kind == .pdf {
            guard let document = pdfView.document, document.pageCount > 0 else { return }
            position.pageIndex = min(max(0, position.pageIndex), document.pageCount - 1)
            if let page = document.page(at: position.pageIndex) {
                pdfView.go(to: page)
            }
            return
        }
        if textPages.isEmpty {
            textView.string = "没有可显示的文本。"
            return
        }
        position.pageIndex = min(max(0, position.pageIndex), textPages.count - 1)
        textView.string = textPages[position.pageIndex]
    }

    private func pageSize() -> CGSize {
        CGSize(
            width: max(200, bounds.width - 56),
            height: max(200, bounds.height - 48)
        )
    }

    private func paginateText() {
        let size = pageSize()
        lastPageSize = size
        textPages = Self.pages(for: rawText, size: size, fontSize: position.fontSize)
        if !textPages.isEmpty {
            position.pageIndex = min(max(0, position.pageIndex), textPages.count - 1)
        }
    }

    private func layoutChildren() {
        pdfView.frame = bounds
        textView.frame = bounds
        scrollView.frame = bounds
    }

    private func paragraphStyle(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    private func emit() {
        guard !isNotifying else { return }
        isNotifying = true
        captureScrollOffset()
        onPositionChanged?(position)
        isNotifying = false
    }

    static func pages(for text: String, size: CGSize, fontSize: Double) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [""] }

        let font = NSFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = fontSize * 1.55
        style.maximumLineHeight = fontSize * 1.55
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: style
        ]

        var remaining = normalized as NSString
        var pages: [String] = []
        var guardCounter = 0
        while remaining.length > 0, guardCounter < 4000 {
            guardCounter += 1
            let fit = charactersThatFit(remaining, size: size, attributes: attributes)
            if fit <= 0 {
                pages.append(remaining as String)
                break
            }
            let take = min(fit, remaining.length)
            pages.append(remaining.substring(to: take).trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
            remaining = remaining.substring(from: take) as NSString
        }
        return pages.isEmpty ? [""] : pages
    }

    private static func charactersThatFit(_ text: NSString, size: CGSize, attributes: [NSAttributedString.Key: Any]) -> Int {
        if text.length == 0 { return 0 }
        let fontSize = (attributes[.font] as? NSFont)?.pointSize ?? 22
        let lineHeight = max(fontSize * 1.55, 8)
        let glyphWidth = max(fontSize * 0.62, 6)
        let lines = max(1, Int(floor(size.height / lineHeight)))
        let perLine = max(2, Int(floor(size.width / glyphWidth)))
        let estimate = max(40, lines * perLine)
        let cap = min(text.length, estimate * 3)

        if text.length <= cap {
            let box = NSAttributedString(string: text as String, attributes: attributes).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            if box.height <= size.height { return text.length }
        }

        var low = 1
        var high = cap
        var fit = 1
        while low <= high {
            let mid = (low + high) / 2
            let slice = text.substring(to: mid)
            let rect = NSAttributedString(string: slice, attributes: attributes).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            if rect.height <= size.height {
                fit = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        if fit < text.length {
            let breakAt = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: fit)).location
            if breakAt != NSNotFound, breakAt >= fit / 3 {
                return breakAt + 1
            }
        }
        return max(1, fit)
    }
}
