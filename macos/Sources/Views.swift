import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            Group {
                if model.filter == .settings {
                    SettingsView()
                } else {
                    LibraryView()
                }
            }
            .frame(minWidth: 620, minHeight: 520)
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("搜索壁纸", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button {
                    model.openImportPanel()
                } label: {
                    Label("导入视频", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $model.isDropTarget,
            perform: handleDrop
        )
        .overlay {
            if model.isDropTarget {
                DropOverlayView()
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let progress = model.importProgress {
                ProgressOverlayView(progress: progress)
            }
        }
        .sheet(item: $model.pendingImport) { candidate in
            ImportSheet(candidate: candidate)
                .environmentObject(model)
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .alert(
            "删除这张动态壁纸？",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            presenting: model.pendingDeletion
        ) { item in
            Button("取消", role: .cancel) {
                model.pendingDeletion = nil
            }
            Button(model.isActive(item) ? "删除并切换" : "删除", role: .destructive) {
                model.confirmDelete(item)
            }
        } message: { item in
            Text(model.isActive(item)
                 ? "“\(item.name)”正在使用。删除后将切换到资料库中的下一张壁纸。"
                 : "“\(item.name)”及其本地副本将被移除，此操作无法撤销。")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        model.isDropTarget = false
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                } else {
                    url = nil
                }
                if let url {
                    DispatchQueue.main.async {
                        model.enqueueImports([url])
                    }
                }
            }
        }
        return accepted
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.filter) {
            Section("资料库") {
                sidebarRow("全部壁纸", symbol: "photo.stack", count: model.state.wallpapers.count, value: .all)
                sidebarRow("收藏", symbol: "heart", count: model.state.wallpapers.filter(\.isFavorite).count, value: .favorites)
                sidebarRow("最近导入", symbol: "clock", value: .recent)
            }

            Section("显示器") {
                ForEach(model.displays) { display in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.name)
                            Text(display.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: display.isMain ? "display.2" : "display")
                    }
                    .tag(LibraryFilter.display(display.id))
                }
            }

            Section {
                Label("设置", systemImage: "gearshape")
                    .tag(LibraryFilter.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(model.isPaused ? "动态壁纸已暂停" : "动态壁纸正在运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ title: String, symbol: String, count: Int? = nil, value: LibraryFilter) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(value)
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 18)
    ]

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if !model.isReady {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在打开资料库…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.visibleWallpapers.isEmpty {
                    EmptyLibraryView()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(model.visibleWallpapers) { item in
                                WallpaperCard(item: item)
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let item = model.selectedWallpaper {
                Divider()
                WallpaperInspector(item: item)
                    .frame(width: 292)
            }
        }
        .navigationTitle(model.filter.title)
    }
}

struct WallpaperCard: View {
    @EnvironmentObject private var model: AppModel
    let item: WallpaperItem
    @State private var hovering = false

    private var selected: Bool { model.selectedWallpaperID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PosterImage(url: model.store.posterURL(for: item))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipped()

                if model.isActive(item) {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(.white)
                        .background(Color.green.opacity(0.92), in: Capsule())
                        .padding(10)
                }

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            model.toggleFavorite(item)
                        } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(item.isFavorite ? Color.pink : Color.white)
                                .padding(8)
                                .background(.black.opacity(0.42), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(item.isFavorite ? "移出收藏" : "加入收藏")
                    }
                    Spacer()
                }
                .padding(8)
            }
            .background(Color.black)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(item.resolutionText) · \(item.durationText) · \(item.aspectText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(item.codec) · \(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(hovering ? 0.32 : 0.16), lineWidth: selected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            model.setWallpaper(item, targetDisplayID: displayIDFromFilter)
        }
        .onTapGesture {
            model.select(item)
        }
        .contextMenu {
            Button("设为动态壁纸") {
                model.setWallpaper(item, targetDisplayID: displayIDFromFilter)
            }
            Button(item.isFavorite ? "移出收藏" : "加入收藏") {
                model.toggleFavorite(item)
            }
            Divider()
            Button("导出壁纸包…") { model.exportPackage(item) }
            Button("在 Finder 中显示") { model.reveal(item) }
            Divider()
            Button("删除壁纸…", role: .destructive) { model.requestDelete(item) }
        }
    }

    private var displayIDFromFilter: String? {
        if case .display(let id) = model.filter { return id }
        return nil
    }
}

struct PosterImage: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.black, Color(nsColor: .darkGray)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "film")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }
}

struct WallpaperInspector: View {
    @EnvironmentObject private var model: AppModel
    let item: WallpaperItem
    @State private var editedName = ""
    @State private var targetDisplayID = "all"
    @State private var selectedMode: AspectMode = .fit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PosterImage(url: model.store.posterURL(for: item))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                TextField("名称", text: $editedName)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { model.rename(item, to: editedName) }

                if model.isActive(item) {
                    Label("正在桌面播放", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.weight(.medium))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("应用到")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("应用到", selection: $targetDisplayID) {
                        Text("所有显示器").tag("all")
                        ForEach(model.displays) { display in
                            Text(display.isMain ? "\(display.name)（主显示器）" : display.name)
                                .tag(display.id)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("画面适配")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("画面适配", selection: $selectedMode) {
                        ForEach(AspectMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(selectedMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    model.setWallpaper(
                        item,
                        targetDisplayID: targetDisplayID == "all" ? nil : targetDisplayID,
                        mode: selectedMode
                    )
                } label: {
                    Text("设为动态壁纸")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack {
                    Button("导出…") { model.exportPackage(item) }
                    Button("在 Finder 中显示") { model.reveal(item) }
                }

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    informationRow("原始尺寸", item.sourceResolutionText)
                    informationRow("输出尺寸", item.resolutionText)
                    informationRow("时长", item.durationText)
                    informationRow("帧率", String(format: "%.2f fps", item.fps))
                    informationRow("编码", item.codec)
                    informationRow("文件大小", ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file))
                }
                .font(.caption)

                Button("删除壁纸…", role: .destructive) {
                    model.requestDelete(item)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .onAppear { syncState() }
        .onChange(of: item.id) { _ in syncState() }
        .onChange(of: targetDisplayID) { _ in
            selectedMode = model.currentAspectMode(for: targetDisplayID == "all" ? nil : targetDisplayID)
        }
    }

    private func syncState() {
        editedName = item.name
        selectedMode = model.currentAspectMode(for: targetDisplayID == "all" ? nil : targetDisplayID)
    }

    private func informationRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptySymbol)
        } description: {
            Text(emptyDescription)
        } actions: {
            if model.filter == .all || model.filter == .recent {
                Button("导入视频") { model.openImportPanel() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyTitle: String {
        switch model.filter {
        case .favorites: return "还没有收藏"
        case .display: return "这台显示器尚未设置壁纸"
        default: return "制作你的第一张动态壁纸"
        }
    }

    private var emptyDescription: String {
        switch model.filter {
        case .favorites: return "点击壁纸卡片上的心形按钮，以后就能快速切换。"
        case .display: return "从全部壁纸中选择一张并应用到这台显示器。"
        default: return "把 MP4、MOV 或 M4V 视频拖到这里，视频只保存在本机。"
        }
    }

    private var emptySymbol: String {
        model.filter == .favorites ? "heart" : "photo.stack"
    }
}

struct DropOverlayView: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
                .ignoresSafeArea()
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                .padding(22)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                Text("松开以导入视频")
                    .font(.title2.weight(.semibold))
                Text("支持 MP4、MOV、M4V 和 .dwallpaper\n视频只保存在这台 Mac，不会上传")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}

struct ProgressOverlayView: View {
    let progress: ImportProgressState

    var body: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                Text("正在制作“\(progress.title)”")
                    .font(.headline)
                Text(progress.phase)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 24)
        }
    }
}

struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let candidate: ImportCandidate

    @State private var name: String
    @State private var resolution: ResolutionChoice = .original
    @State private var customWidth: Int
    @State private var customHeight: Int
    @State private var aspectMode: AspectMode = .fit
    @State private var applyAfterImport = true
    @State private var favorite = false
    @State private var targetDisplayID = "all"

    init(candidate: ImportCandidate) {
        self.candidate = candidate
        _name = State(initialValue: candidate.suggestedName)
        _customWidth = State(initialValue: candidate.metadata.width)
        _customHeight = State(initialValue: candidate.metadata.height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                VideoStillPreview(url: candidate.url)
                    .frame(width: 250, height: 310)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(candidate.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(candidate.metadata.resolutionText) · \(formatDuration(candidate.metadata.duration)) · \(candidate.metadata.codec)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("制作动态壁纸")
                        .font(.title2.weight(.semibold))
                    Text("原视频不会被修改，制作过程全部在本机完成。")
                        .foregroundStyle(.secondary)
                }

                Form {
                    TextField("名称", text: $name)

                    Picker("应用到", selection: $targetDisplayID) {
                        Text("所有显示器").tag("all")
                        Text("先不应用").tag("none")
                        ForEach(model.displays) { display in
                            Text(display.isMain ? "\(display.name)（主显示器）" : display.name)
                                .tag(display.id)
                        }
                    }

                    Picker("输出分辨率", selection: $resolution) {
                        ForEach(ResolutionChoice.allCases) { choice in
                            Text(choice.title(candidate: candidate, display: selectedDisplay))
                                .tag(choice)
                        }
                    }

                    if resolution == .custom {
                        HStack {
                            TextField("宽度", value: $customWidth, format: .number)
                            Text("×").foregroundStyle(.secondary)
                            TextField("高度", value: $customHeight, format: .number)
                            Text("像素").foregroundStyle(.secondary)
                        }
                    }

                    Picker("画面适配", selection: $aspectMode) {
                        ForEach(AspectMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(aspectMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("加入收藏", isOn: $favorite)
                    if targetDisplayID != "none" {
                        Toggle("导入后立即设为壁纸", isOn: $applyAfterImport)
                    }
                }
                .formStyle(.grouped)

                Spacer()

                HStack {
                    Text(outputSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") {
                        dismiss()
                        model.cancelPendingImport()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("开始制作") {
                        let options = ImportOptions(
                            name: name,
                            resolution: resolution,
                            customWidth: customWidth,
                            customHeight: customHeight,
                            aspectMode: aspectMode,
                            applyAfterImport: targetDisplayID != "none" && applyAfterImport,
                            favorite: favorite,
                            targetDisplayID: targetDisplayID == "all" || targetDisplayID == "none" ? nil : targetDisplayID
                        )
                        dismiss()
                        model.confirmImport(candidate: candidate, options: options)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dimensionsAreValid || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(width: 410)
        }
        .padding(26)
        .frame(width: 730, height: 610)
        .interactiveDismissDisabled()
        .onChange(of: resolution) { choice in
            guard choice != .custom else { return }
            let dimensions = choice.dimensions(
                candidate: candidate,
                display: selectedDisplay,
                customWidth: customWidth,
                customHeight: customHeight
            )
            customWidth = dimensions.0
            customHeight = dimensions.1
        }
        .onChange(of: targetDisplayID) { _ in
            guard resolution == .display else { return }
            let dimensions = resolution.dimensions(
                candidate: candidate,
                display: selectedDisplay,
                customWidth: customWidth,
                customHeight: customHeight
            )
            customWidth = dimensions.0
            customHeight = dimensions.1
        }
    }

    private var selectedDisplay: DisplayInfo? {
        if targetDisplayID != "all", targetDisplayID != "none" {
            return model.displays.first(where: { $0.id == targetDisplayID })
        }
        return model.displays.first(where: \.isMain) ?? model.displays.first
    }

    private var chosenDimensions: (Int, Int) {
        resolution.dimensions(
            candidate: candidate,
            display: selectedDisplay,
            customWidth: customWidth,
            customHeight: customHeight
        )
    }

    private var dimensionsAreValid: Bool {
        chosenDimensions.0 >= 480 && chosenDimensions.1 >= 480
            && chosenDimensions.0.isMultiple(of: 2) && chosenDimensions.1.isMultiple(of: 2)
    }

    private var outputSummary: String {
        let dimensions = chosenDimensions
        return dimensionsAreValid
            ? "输出 \(dimensions.0) × \(dimensions.1) · 静音循环"
            : "宽度和高度需为 ≥480 的偶数"
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds) 秒"
    }
}

struct VideoStillPreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            image = await PreviewLoader.image(url: url)
        }
    }
}

enum PreviewLoader {
    static func image(url: URL) async -> NSImage? {
        await Task.detached {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            var actual = CMTime.zero
            guard let cg = try? generator.copyCGImage(
                at: CMTime(seconds: 0.5, preferredTimescale: 600),
                actualTime: &actual
            ) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("设置")
                    .font(.largeTitle.weight(.semibold))

                SettingsGroup(title: "通用", symbol: "gearshape") {
                    Toggle(
                        "登录时启动动态壁纸工作室",
                        isOn: Binding(
                            get: { model.loginAtLaunchEnabled },
                            set: { model.setLoginAtLaunch($0) }
                        )
                    )
                    Text(model.loginAtLaunchEnabled ? "将在下次登录时自动在后台启动。" : "关闭后仍可手动打开应用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsGroup(title: "播放", symbol: "play.circle") {
                    Toggle(
                        "显示器休眠时暂停",
                        isOn: settingBinding(\.pauseOnDisplaySleep)
                    )
                    Toggle(
                        "锁定 Mac 时暂停",
                        isOn: settingBinding(\.pauseOnSessionLock)
                    )
                    Text("所有动态壁纸始终静音循环播放，唤醒后会从暂停状态恢复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsGroup(title: "存储", symbol: "externaldrive") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("资料库占用")
                            Text(ByteCountFormatter.string(fromByteCount: model.storageBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("在 Finder 中显示") { model.revealLibrary() }
                    }
                    Text(model.store.baseURL.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                SettingsGroup(title: "关于", symbol: "info.circle") {
                    HStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("动态壁纸工作室")
                                .font(.headline)
                            Text("版本 2.0 · 本地处理 · 不上传视频")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("支持 MP4、MOV、M4V、收藏切换、多显示器、不同输出分辨率和便携壁纸包。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
        }
        .navigationTitle("设置")
    }

    private func settingBinding(_ keyPath: WritableKeyPath<StudioSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.state.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
