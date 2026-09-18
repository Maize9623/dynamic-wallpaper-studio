# Windows 对齐 macOS 2.1.0「摸鱼神器」交接稿

今晚在 **Windows + Cursor** 上用。macOS 2.1.0 Preview 已经在分支 `feature/macos-1.1-moyushenqi` 做出若干 Windows 1.1 **还没有**的能力。这份单只列要对齐的增量，不要把整份 Mac 工程重写一遍。

**不要改 `main`。** 从现有 Windows 分支再开一条，只推新分支：

```powershell
git fetch origin
git checkout feature/windows-1.1-moyushenqi
git checkout -b feature/windows-1.1-align-macos-21
```

对照产品时看 Mac 分支当前代码，不要猜。Windows 继续用 **WPF + mpv + WebView2 + 现有桌面嵌入**，不要搬 Swift、WKWebView、`NSWindow`。

macOS 预发布包（不替换 `main` 的 Latest）：

https://github.com/Maize9623/dynamic-wallpaper-studio/releases/tag/macos-2.1.0-moyushenqi

交接文档本体在 Mac 分支：

https://github.com/Maize9623/dynamic-wallpaper-studio/blob/feature/macos-1.1-moyushenqi/windows/WINDOWS_1.1_HANDOFF.md

## 先拉哪份代码

| 主题 | 先看 Mac | 先看 Windows |
|---|---|---|
| 子库 / 播放台 | `macos/Sources/Models.swift`（`WallpaperFolder`）、`AppModel.swift`、`Views.swift` 侧栏 | `windows/Models.cs`（还没有 Folder） |
| 阅读滚动与快捷键 | `Models.swift`（`ReaderAdvanceMode`）、电子书面板 | `windows/ReaderSurface.cs`、`BossHotkeyService.cs` |
| 短视频 / 清屏 | `WebSession.swift`、`WebStudioWindow.swift`、`StudioSettings.shortVideoMode` | `windows/WebSession.cs`、`WebLoginWindow.xaml` |
| 客厅两套方案 | `SceneScheme`、`SceneLayout.swift`、`LivingRoomCorner.jpg` | `windows/SceneLayout.cs`、`LivingRoomView.cs`、`Assets/LivingRoom.jpg` |
| 资料库预览方向 | `Views.swift`（`FittedPoster`、`previewAspectRatio`） | `windows/MainWindow.xaml` 卡片 |

同一时刻只激活一种桌面内容：视频 / 电子书 / 网页。桌面层不能点。默认静音。列表顺序播、最后一条停。导入默认引用。不要读系统浏览器 Cookie，不要破解 DRM。

## Windows 1.1 已经有、不要重做

- 播放条、列表播完即停、默认静音、倍速
- 资料库路径、引用导入
- TXT / PDF、字号、浅色深色、自动翻页
- 独立网页 → 同步到桌面；直播只管静音/音量
- 居中客厅 + 关电视 + 老板键（Ctrl+Alt+B）
- Raised Desktop 下客厅走原生分层窗

## 必须补上的增量

### 1. 子库 + 播放台

Mac 侧栏可以新建子库。拖入或导入一个剧集文件夹会按文件名排序进子库。右键子库「全部导入播放台」，二次确认 **替换** 或 **追加**。播放台可勾选批量移除。

Windows 现在只有整库 + 播放列表，没有 `Folder`。建议：

```csharp
public sealed class WallpaperFolder
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "未命名子库";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public List<Guid> ItemIds { get; set; } = [];
}
```

挂到 `LibraryState.Folders`。旧 `Library.json` 没有该字段时当空数组。

### 2. Markdown、自动滚动、阅读快捷键

Mac 电子书支持 TXT / **Markdown** / PDF。TXT/MD 可在自动翻页和自动滚动之间切换，速度 8–80，两者都能暂停。

全局快捷键（Windows 建议对标现有老板键风格）：

| 动作 | macOS | Windows 建议默认 |
|---|---|---|
| 上一页 / 上一条 | Control+Option+Left | Ctrl+Alt+Left |
| 下一页 / 下一条 | Control+Option+Right | Ctrl+Alt+Right |
| 暂停 / 继续 | Control+Option+Space | Ctrl+Alt+Space |

设置里可改，和老板键一样要「应用」后再生效。只在电子书已打开到桌面时翻页；勾了短视频模式则改去刷视频。

`ReaderPosition` 请补：`AdvanceMode`（off / page / scroll）、`ScrollSpeed`、`AutoAdvancePaused`。旧的 `AutoTurn` 可继续当 `page` 的兼容字段，Mac 就是这么解码的。

### 3. 短视频模式 + 保持清屏

网页面板增加：

- **短视频模式**：复用上面那组阅读快捷键刷上一条 / 下一条（抖音）。直播不要开。独立页地址栏旁也要有「上一条 / 下一条」。
- **保持清屏**（默认开）：抖音自带清屏只对当前一条有效。勾选后，换条、同步到桌面、窗口缩放都要再藏一次点赞 / 收藏。

Mac 实现：独立 `WKWebsiteDataStore` + 用户脚本。Windows 用现有 WebView2 用户脚本即可，**只动 DOM 显示和站点自己的清屏按钮**，不要注入破解。换条后站点常会重建节点，要能再次套上。

脚本入口可对：`macos/Sources/WebSession.swift` 里 `__dwpsShort`、`__dwpsClean`。

### 4. 客厅网页上移

抖音在电视洞里会顶上留黑边、底下字幕被裁。Mac 只对 **网页模式 + 客厅开启** 把 WebView 相对电视框上移 `7%` 电视高度，最少 8px（小电视不要再用 24px）。视频和电子书仍铺满电视框。

```text
macos/Sources/SceneLayout.swift
    televisionWebLift = 0.07
    liftedWebFrame: y = -lift, height = tvHeight + lift
    contentHost.clipsToBounds = true
```

Windows 对 WebView2 做同样的 margin/clip，不要改 mpv 或 PDF 的框。

### 5. 客厅两套方案

Mac「客厅伪装」里可选：

| 方案 | 资源 | 电视内屏（已按图测过） |
|---|---|---|
| 居中电视 | `LivingRoom.jpg` | `0.3078, 0.2056, 0.3859, 0.3847` |
| 右下角电视 | `LivingRoomCorner.jpg` | `0.5055, 0.3125, 0.3445, 0.3528` |

右下角这张是更近的构图：左边坐着一个人看电视，右边大屏 + 电视柜 + 植物。中间墙面留空方便办公。

请把 `macos/Resources/LivingRoomCorner.jpg` 拷到 `windows/Assets/LivingRoomCorner.jpg`，并做成可切换的 `SceneScheme`。勾选「启用客厅伪装」后必须再点 **「应用」** 才换图和换框。视频 / 书 / 网页都跟当前方案的电视洞。

现有 `SceneLayout.TelevisionBounds` 有 `Math.Max(320, …)`。右下角方案在 1080p 上 320 会撑破电视洞。改成跟 Mac 一样：至少 2px，并收成偶数。不要把视频缩到屏幕正中却没有客厅。

关电视、老板键逻辑保持不变。

### 6. 资料库预览按视频方向

Mac 资料库以前用固定竖卡 / 16:10，横版视频会留下大黑框。现在卡片、右侧详情、导入预览都按 `outputWidth / outputHeight` 排：

- 横的横着显示
- 竖的竖着显示
- 同一行高低不同就顶对齐，不要把短卡拉高再填黑

实现见 `macos/Sources/Views.swift` 的 `FittedPoster`、`WallpaperItem.previewAspectRatio`。比例夹在 9:21 和 21:9 之间即可。

## 不要搬的东西

- SwiftUI / AppKit / WKWebView / `ignoresMouseEvents`（Windows 已有自己的桌面点击穿透）
- 系统 Safari / Chrome Cookie
- 破解会员、DRM、伪装播放成功
- 随机循环整表
- 默认外放声音
- 把用户视频、`Library.json`、`WebProfile`、Cookie 提交进 git
- 改 `main`、强推 `main`

B 站直播黑屏是 Mac 上 WKWebView 脚本按太勤造成的。Windows 若 WebView2 已经能播，不要为了「对齐」去抄那套静音 Observer 的过猛写法；只在出现新媒体时同步 mute/volume。

## 建议顺序

1. 子库 + 播放台批量（先打通资料库结构）
2. Markdown + 滚动 + 阅读快捷键
3. 短视频模式 + 保持清屏
4. 客厅网页上移
5. 右下角客厅方案（拷图、换框、去掉 320 下限）
6. 资料库预览按方向排
7. 真机：视频 / 书 / 抖音 / 客厅两套 / 老板键各走一遍

每做完一块就看真实桌面，不要只看 WPF 设计器。

## 真机验收

- [ ] 子库：建库、导入剧集文件夹、全部进播放台（替换 / 追加）、批量移除
- [ ] TXT（含 GB18030）、MD、PDF；自动滚动可暂停；快捷键可改
- [ ] 短视频模式：独立页能刷上一条 / 下一条；同步到桌面后桌面不能点
- [ ] 保持清屏：换条和同步后点赞收藏不再冒出来
- [ ] 客厅 + 抖音：字幕看得见，头顶不要大黑边
- [ ] 居中 / 右下角两套都能套视频、书、网页；应用后才切换
- [ ] 右下角方案里电视洞和 `LivingRoomCorner.jpg` 黑屏对齐，1080p 不溢出
- [ ] 资料库横视频横卡、竖视频竖卡，没有强迫竖框大黑边
- [ ] 关电视、老板键、默认静音、列表最后一条停止仍可用

## 版本

Windows 源码建议标 **1.1.1 Preview**（或继续 1.1.0 并在 README 写清「对齐 macOS 2.1」）。不要假装和 macOS 2.1.0 DMG 是同一个安装包。官方 `main` Latest 仍是 Windows 1.0.5 / macOS 2.0.0。
