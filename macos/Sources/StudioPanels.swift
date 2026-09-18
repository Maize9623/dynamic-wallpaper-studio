import SwiftUI

struct StudioHostView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.filter {
                case .player:
                    PlayerPanel()
                case .reader:
                    ReaderPanel()
                case .web:
                    WebPanel()
                case .scene:
                    ScenePanel()
                default:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(model.filterTitle)
    }
}

struct PlayerPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        studioCard(title: "连续播放", symbol: "play.square.stack") {
            Text("排好顺序后按列表播完即停，不会整表循环。单条壁纸循环请关闭「列表播放」。")
                .foregroundStyle(.secondary)
            Toggle("列表播放（关闭则为当前壁纸循环）", isOn: Binding(
                get: { model.state.settings.playlistMode },
                set: model.setPlaylistMode
            ))
            if model.playlistItems.isEmpty {
                Text("播放列表是空的。从壁纸详情里点「加入播放列表」，或右键子库全部导入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(model.selectedPlaylistIDs.count == model.playlistItems.count ? "取消全选" : "全选") {
                        model.selectAllPlaylistItems()
                    }
                    Button("移除所选", role: .destructive) {
                        model.removeSelectedPlaylistItems()
                    }
                    .disabled(model.selectedPlaylistIDs.isEmpty)
                    Button("清空播放台", role: .destructive) {
                        confirmClear = true
                    }
                    Spacer()
                    Text("已选 \(model.selectedPlaylistIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.playlistItems.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Button {
                                model.togglePlaylistSelection(item.id)
                            } label: {
                                Image(systemName: model.selectedPlaylistIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(model.selectedPlaylistIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            Text(item.name)
                                .fontWeight(index == model.state.settings.playlistIndex ? .semibold : .regular)
                            Spacer()
                            if index == model.state.settings.playlistIndex {
                                Text("正在播").font(.caption).foregroundStyle(.green)
                            }
                            Button("上移") { model.movePlaylist(from: index, offset: -1) }
                                .disabled(index == 0)
                            Button("下移") { model.movePlaylist(from: index, offset: 1) }
                                .disabled(index == model.playlistItems.count - 1)
                            Button("从此播放") { model.playPlaylistIndex(index) }
                            Button("移除", role: .destructive) { model.removePlaylistItem(at: index) }
                        }
                    }
                }
            }
            if let selected = model.selectedWallpaper {
                Button("加入当前选中") { model.addToPlaylist(selected) }
            }
        }
        .confirmationDialog("清空播放台？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { model.clearPlaylist() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是从连续播放列表里拿掉，不会删除资料库里的视频。")
        }
    }
}

struct ReaderPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var autoSeconds: Double = 8
    @State private var pickingBook = false

    private var advanceMode: ReaderAdvanceMode {
        model.activeBook?.position.advanceMode ?? .off
    }

    private var scrollSpeed: Double {
        model.activeBook?.position.scrollSpeed ?? 36
    }

    var body: some View {
        studioCard(title: "电子书", symbol: "book") {
            Text("本地 TXT（UTF-8 / GB18030）、Markdown 和 PDF。阅读位置记在资料库，不改原文件，也不会上传。")
                .foregroundStyle(.secondary)
            HStack {
                Button("导入 TXT / MD / PDF") { pickingBook = true }
                    .buttonStyle(.borderedProminent)
                if let book = model.selectedBook {
                    Button("打开到桌面") { model.openBook(book) }
                    Button("删除记录", role: .destructive) { model.requestDeleteBook(book) }
                }
            }
            .zIndex(1)
            if model.state.books.isEmpty {
                Text("还没有电子书。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.state.books) { book in
                        Button {
                            model.openBook(book)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.name)
                                    Text(book.kind.title + (book.isManagedCopy ? " · 资料库副本" : " · 引用原文件"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.state.settings.activeBookID == book.id,
                                   model.state.settings.contentMode == .reader {
                                    Text("使用中").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(model.selectedBookID == book.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            Text(model.readerPageLabel)
                .font(.headline)
            HStack {
                Button("上一页") { model.readerPrevious() }
                Button("下一页") { model.readerNext() }
                Button("字号 −") { model.readerAdjustFont(-2) }
                Button("字号 ＋") { model.readerAdjustFont(2) }
                Button("浅色") { model.readerSetTheme(.light) }
                Button("深色") { model.readerSetTheme(.dark) }
            }
            .buttonStyle(.bordered)

            Picker("自动阅读", selection: Binding(
                get: { advanceMode },
                set: { model.readerSetAdvance($0, pageSeconds: autoSeconds) }
            )) {
                ForEach(ReaderAdvanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.activeBook == nil)

            if advanceMode == .page {
                HStack {
                    Text("翻页间隔")
                    Slider(
                        value: Binding(
                            get: { autoSeconds },
                            set: { autoSeconds = $0 }
                        ),
                        in: 3...120,
                        step: 1
                    )
                    TextField("8", value: $autoSeconds, format: .number)
                        .frame(width: 52)
                        .onSubmit { model.readerSetAdvance(.page, pageSeconds: autoSeconds) }
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
                .onChange(of: autoSeconds) { _, value in
                    guard advanceMode == .page, model.state.settings.contentMode == .reader else { return }
                    model.readerSetAdvance(.page, pageSeconds: value)
                }
            }

            if advanceMode == .scroll {
                if model.readerCanAutoScroll {
                    HStack {
                        Text("滚动速度")
                        Slider(
                            value: Binding(
                                get: { scrollSpeed },
                                set: { model.readerSetScrollSpeed($0) }
                            ),
                            in: 8...80,
                            step: 1
                        )
                        Text("\(Int(scrollSpeed.rounded())) 点/秒")
                            .monospacedDigit()
                            .frame(width: 78, alignment: .trailing)
                    }
                } else {
                    Text("PDF 没有连续文本流，不能自动滚动。请改用自动翻页。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if advanceMode != .off {
                Button(model.activeBook?.position.autoAdvancePaused == true ? "继续" : "暂停") {
                    model.readerTogglePause()
                }
                .buttonStyle(.borderedProminent)
            }

            ReaderHotkeyEditor()
        }
        .fileImporter(
            isPresented: $pickingBook,
            allowedContentTypes: BookFile.contentTypes,
            allowsMultipleSelection: true
        ) { result in
            Task { @MainActor in
                switch result {
                case .success(let urls):
                    model.enqueueImports(urls)
                case .failure(let error):
                    model.alert = StudioAlert(title: "无法导入电子书", message: error.localizedDescription)
                }
            }
        }
        .onAppear {
            autoSeconds = model.activeBook?.position.autoTurnSeconds ?? 8
        }
        .onChange(of: model.activeBook?.id) { _, _ in
            autoSeconds = model.activeBook?.position.autoTurnSeconds ?? 8
        }
    }
}

struct ReaderHotkeyEditor: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "启用电子书 / 短视频全局快捷键",
                isOn: Binding(
                    get: { model.state.settings.readerHotkeysEnabled },
                    set: { enabled in
                        model.setReaderHotkeys(
                            previous: model.draftReaderPreviousHotkey,
                            next: model.draftReaderNextHotkey,
                            pause: model.draftReaderPauseHotkey,
                            enabled: enabled
                        )
                    }
                )
            )
            hotkeyRow("上一页 / 上一条", text: $model.draftReaderPreviousHotkey, placeholder: "Control+Option+Left")
            hotkeyRow("下一页 / 下一条", text: $model.draftReaderNextHotkey, placeholder: "Control+Option+Right")
            hotkeyRow("暂停 / 继续", text: $model.draftReaderPauseHotkey, placeholder: "Control+Option+Space")
            Button("应用快捷键") {
                model.setReaderHotkeys(
                    previous: model.draftReaderPreviousHotkey,
                    next: model.draftReaderNextHotkey,
                    pause: model.draftReaderPauseHotkey,
                    enabled: model.state.settings.readerHotkeysEnabled
                )
            }
            Text("默认 Control+Option+Left / Right / Space。可写字母、数字、方向键、空格、Esc、F1–F12，前面加上 Control、Option、Shift 或 Command。电子书打开到桌面时翻页；网页勾了短视频模式时变成上一条 / 下一条。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func hotkeyRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 88, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct FolderImportSheet: View {
    let pending: PendingFolderImport
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let folderID = pending.existingFolderID, let folder = model.folder(folderID) {
                Text("导入到子库「\(folder.name)」")
                    .font(.title2.weight(.semibold))
                Text("找到 \(pending.videos.count) 个视频，按文件名排序后加入这个子库。资料库里已经有的会复用，不会再做一份。")
                    .foregroundStyle(.secondary)
            } else {
                Text("新建子库「\(pending.suggestedName)」")
                    .font(.title2.weight(.semibold))
                Text("找到 \(pending.videos.count) 个视频。会按文件名排好，方便一整部剧连续播。默认只引用原文件。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("只引用") { model.confirmFolderImport(copyToLibrary: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("复制到资料库") { model.confirmFolderImport(copyToLibrary: true) }
                Button("取消", role: .cancel) { model.cancelFolderImport() }
            }
        }
        .padding(28)
        .frame(minWidth: 460)
    }
}

struct BookImportSheet: View {
    let pending: PendingBookImport
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入电子书「\(pending.name)」")
                .font(.title2.weight(.semibold))
            Text("默认只引用原文件，不复制，也不会上传。复制一份到资料库后，删记录时只会删副本。")
                .foregroundStyle(.secondary)
            HStack {
                Button("只引用") { model.confirmBookImport(copyToLibrary: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("复制到资料库") { model.confirmBookImport(copyToLibrary: true) }
                Button("取消", role: .cancel) { model.cancelBookImport() }
            }
        }
        .padding(28)
        .frame(minWidth: 420)
    }
}

struct WebPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = ""

    var body: some View {
        studioCard(title: "网页 / 直播", symbol: "dot.radiowaves.left.and.right") {
            Text("先打开独立页面：登录、网页全屏、弹幕都在那里设。设好后点「同步到桌面」，壁纸只保持这一页，不能在桌面上点。播放条的静音对直播有效；B 站 / 腾讯等点播还可以用播放和倍速。配置在资料库 WebProfile，不读系统浏览器 Cookie，不破解 DRM。")
                .foregroundStyle(.secondary)
            TextField("https://live.bilibili.com", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setWebURL(url) }
            Button("打开独立页面") {
                model.setWebURL(url)
                model.openWebStudio()
            }
            .buttonStyle(.borderedProminent)
            Toggle(
                "短视频模式",
                isOn: Binding(
                    get: { model.state.settings.shortVideoMode },
                    set: model.setShortVideoMode
                )
            )
            Text("勾选后，电子书的上一页 / 下一页 / 暂停快捷键在网页模式下变成上一条 / 下一条 / 暂停。独立页面里也有这两个按钮。先点进一条视频，或在推荐页直接按下一条进入播放器。直播不用开。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.state.settings.shortVideoMode {
                Toggle(
                    "保持清屏",
                    isOn: Binding(
                        get: { model.state.settings.keepWebCleanScreen },
                        set: model.setKeepWebCleanScreen
                    )
                )
                Text("抖音自己的清屏只对当前这一条有效，换视频或同步到桌面后点赞收藏会重新出来。勾选后会跟着刷下去，并在桌面上继续藏掉。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("上一条") { model.webShortAdvance(-1) }
                    Button("下一条") { model.webShortAdvance(1) }
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            url = model.state.settings.webURL.isEmpty ? "https://live.bilibili.com" : model.state.settings.webURL
        }
    }
}

struct ScenePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        studioCard(title: "客厅电视伪装", symbol: "tv") {
            Text("勾选后点「应用」才会切换客厅样板。视频、电子书或网页只出现在电视屏幕里。居中适合专心看；右下角把中间桌面留给办公。关电视会停声、停画面并冻结进度，背景留下。")
                .foregroundStyle(.secondary)
            HStack {
                Toggle("启用客厅伪装", isOn: $model.pendingSceneEnabled)
                    .toggleStyle(.checkbox)
                Button("应用") { model.applyScene() }
                    .buttonStyle(.borderedProminent)
            }
            .zIndex(1)
            HStack(alignment: .top, spacing: 12) {
                ForEach(SceneScheme.allCases) { scheme in
                    Button {
                        model.pendingSceneScheme = scheme
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            if let image = DesktopLayer.livingRoomImage(scheme) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 92)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Text(scheme.title)
                                .font(.headline)
                            Text(scheme.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    model.pendingSceneScheme == scheme ? Color.accentColor : Color.secondary.opacity(0.18),
                                    lineWidth: model.pendingSceneScheme == scheme ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("关电视（冻结进度，只留背景或桌面）", isOn: Binding(
                get: { model.state.settings.televisionOff },
                set: model.setTelevisionOff
            ))
            Button(model.state.settings.bossHidden ? "老板键：恢复显示" : "老板键：立刻隐藏 / 恢复") {
                model.toggleBossKey()
            }
        }
    }
}

@ViewBuilder
func studioCard<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
        Label(title, systemImage: symbol)
            .font(.title2.weight(.semibold))
        content()
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.secondary.opacity(0.15))
    }
}
