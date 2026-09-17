# macOS 1.1「摸鱼神器」交接稿

给明天在 **MacBook + Cursor** 上做移植的人用。Windows 1.1 已经在分支 `feature/windows-1.1-moyushenqi`，**不要改 `main`**。建议从该分支再开：

```text
feature/macos-1.1-moyushenqi
```

只推这条新分支。做完后更新本文件顶部的「完成情况」，并改 `macos/README.md`。

## 你要达成的产品

Windows 上已经能用的「摸鱼神器」行为，用 **Swift / SwiftUI / AppKit** 在 macOS 15+ 重做一遍。两边共享产品约定，**不共享 UI 代码**。

同一时刻只激活一种桌面内容：视频、电子书、网页/直播。都可以套客厅电视框。控制只走管理窗口、菜单栏、老板键，**桌面层不接收鼠标和键盘**。

## 先拉哪份代码

```bash
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
cd dynamic-wallpaper-studio
git fetch origin
git checkout feature/windows-1.1-moyushenqi
git checkout -b feature/macos-1.1-moyushenqi
```

对照实现时以 Windows 源码为准，不要猜：

| 主题 | 先看 |
|---|---|
| 状态与资料库字段 | `windows/Models.cs`、`windows/LibraryStore.cs` |
| 播放条 / 列表 / 音量 | `windows/AppController.cs`、`windows/MainWindow.xaml` |
| 阅读 | `windows/ReaderSurface.cs` |
| 网页独立页 + 同步桌面 | `windows/WebSession.cs`、`windows/WebLoginWindow.xaml` |
| 客厅框与老板键 | `windows/SceneLayout.cs`、`windows/NativeSceneBackdrop.cs`、`windows/BossHotkeyService.cs` |
| 现有 Mac 壁纸窗 | `macos/Sources/WallpaperEngine.swift`（`ignoresMouseEvents = true`，桌面层级） |
| 现有 Mac 资料库 | `macos/Sources/LibraryStore.swift`（`~/Library/Application Support/local.baiyaoyu.dynamicwallpaperstudio/`） |

Windows 桌面嵌入、mpv IPC、WebView2、Win32 `Progman/WorkerW` **全部不要搬**。

## 不要做的事

- 不要用 WebView2、Win32、mpv JSON IPC、Raised Desktop。
- 不要读系统 Safari / Chrome Cookie，不要注入脚本破解会员或 DRM。
- 不要让桌面层变成可点击的浏览器。全屏、弹幕、登录只在独立窗口里做，再同步到桌面。
- 不要随机循环整表。列表按顺序播，**最后一条播完停住**。
- 不要默认外放声音。默认静音；用户开声后切条目、暂停恢复都保持用户选择。
- 不要把用户视频、`Library.json`、网页配置目录、Cookie 提交进 git。
- 不要改 `main`，不要强推 `main`。
- 宽视窗 DRM 站点（部分腾讯视频）黑屏或提示换浏览器时，停在页面本身，不要伪装成播放成功。

## 建议映射（Mac 原生）

| Windows | macOS |
|---|---|
| mpv 桌面窗 | 已有 `AVQueuePlayer` + `NSWindow` 桌面层 |
| 客厅 JPEG 分层窗 | 同一桌面 `NSWindow` 上的 `NSImageView` 背景；电视洞里放视频 / PDF / WKWebView |
| WebView2 + `WebProfile` | `WKWebView` + 独立 `WKWebsiteDataStore`（资料库下 `WebProfile/`，非 `.default()`） |
| 独立页面再同步 | 普通 `NSWindow` 里同一套 `WKWebView`（或同步 URL + 同 store）；点「同步到桌面」再挂到桌面层且 `ignoresMouseEvents = true` |
| TXT / PDF | `NSTextView` + 编码探测（UTF-8 / GB18030）；PDF 用 **PDFKit** |
| 老板键 | 可配置的全局热键（默认 Control+Option+B，对标 Windows 的 Ctrl+Alt+B）；可关闭 |
| 资料库改路径 | 允许自选目录；默认仍可留在 Application Support。导入默认 **引用原文件**，不要再强制 copy 进资料库 |

现有 Mac 导入会把视频拷进 Application Support。1.1 起默认改成引用；用户勾选「复制到资料库」才 copy。不要弄丢旧资料库里已经拷过的条目。

## 功能规格（必须对齐 Windows 1.1）

### 1. 播放条

管理窗口底部（以及菜单栏对应项）：

- 播放 / 暂停、上一首 / 下一首、进度、音量、静音
- 倍速：1 / 1.25 / 1.5 / 2
- 默认静音，音量默认约 70（静音时不要突然外放）
- 单条循环：关闭「列表播放」
- 列表播放：按用户顺序，播完自动下一条，**最后一条停止**（不要随机、不要整表循环）

现有 `AVPlayerLooper` 只适合单条无限循环。上列表后不要对「列表模式」再用 looper 把第一条卡死；用 `AVPlayerItem` 结束通知切下一条。

### 2. 资料库路径

- 设置里可选资料库根目录
- 导入默认引用原路径；复制是可选项
- 删除「引用」条目只删记录和封面，不删用户原视频
- 兼容标识 `local.baiyaoyu.dynamicwallpaperstudio` 先留着，避免旧用户丢库

### 3. 电子书

- 仅本地 TXT、PDF
- TXT：UTF-8 / GB18030（或 CFString 编码探测），不要假设全是 UTF-8
- 字号、浅色 / 深色、上一页 / 下一页、可选自动翻页（默认约 8 秒，可暂停）
- 位置写入资料库：`pageIndex`、`scrollOffset`、`fontSize`、`theme`、`autoTurn`、`autoTurnSeconds`
- 不做 EPUB、在线书城、DRM 书

### 4. 网页 / 直播

工作流（不要做「打开到桌面就丢一个裸网页」）：

1. 「打开独立页面」：普通窗口，用户可点。登录、网页全屏、弹幕都在这里设。
2. 「同步到桌面」：把**当前这一页的状态**放到桌面层（同一 `WKWebsiteDataStore`，能挪 WebView 就挪，避免刷新丢掉全屏/弹幕）。
3. 桌面层 `ignoresMouseEvents = true`。要改设置先「取回编辑」，改完再同步。
4. 关掉「打开到桌面」这种会绕过独立页的入口。

播放条：

- **直播**（URL 含 `live.`、`/live`、`/room/`，或 `video.duration` 为 Infinity）：只保证**静音和音量**作用到页面里的 `video/audio`；播放、进度、倍速、上一首/下一首关掉。
- **点播**（B 站稿件、腾讯视频等能拿到有限时长的媒体）：再启用播放 / 暂停、倍速；进度能拖再用。
- 用页面里的媒体元素控制即可，不要写破解脚本。站点重建 `<video>` 时要能再次套上静音（Windows 用了 MutationObserver，Mac 可用同样思路的 `WKUserScript`，仍然只动 mute/volume/play/rate/seek）。

配置目录：`{LibraryRoot}/WebProfile`。不读系统浏览器 Cookie。

### 5. 客厅伪装 + 老板键

- 一张客厅图铺满桌面，内容只出现在电视黑框里。Windows 资源：`windows/Assets/LivingRoom.jpg`。
- 电视框相对桌面的归一化矩形（已按该图测过内屏）：

```text
x = 0.3078, y = 0.2056, w = 0.3859, h = 0.3847
```

先抄这组，再按实机微调。图和框对不齐时优先改框，不要把视频缩在屏幕正中间却没有客厅。

- 勾选「启用客厅伪装」后要有 **「应用」**，不要只打勾立刻切换。
- **关电视**：停声、停画面、进度冻结，客厅留下；再开从原进度继续。
- **老板键**：立刻隐藏内容（可只留客厅，或整段桌面内容都藏）。再按恢复。这是展示切换，不是对抗监控。
- 关电视 / 老板隐藏优先于睡眠唤醒后的自动恢复。
- 场景 + 视频：客厅必须是真正画出来的背景，不要只剩电视洞里一块浮动视频、后面是系统壁纸。

### 6. 管理窗口

同一时刻一种模式。窗口默认固定常用大小，全屏/最大化可以，不必做成随意拖边缩放（Windows 管理窗锁在约 1180×760）。菜单栏保留暂停、收藏切换、静音、关电视、老板键。

## 建议实现顺序

1. 播放条 + 列表结束逻辑（改现有 `AVPlayerLooper` 行为）
2. 资料库路径 + 默认引用导入（兼容旧 copy 条目）
3. TXT/PDF 阅读画在已有桌面窗里
4. 独立 `WKWebView` 窗口 + 同步到桌面 + 静音脚本
5. 客厅图 + 电视框 + 关电视 + 老板键
6. 真机验收后更新 `macos/README.md` 和根 README 的 macOS 版本行

每做完一块就在真机上看桌面，不要只看 SwiftUI 预览。

## 真机验收（必须）

在目标 Mac 上用真实桌面走一遍，不要只编译通过：

- [ ] 视频：播放条、静音默认、倍速、列表最后一条停止
- [ ] 引用导入的原视频：删库记录后原文件还在
- [ ] TXT（含非 UTF-8）、PDF：翻页、换字号、重启后位置还在
- [ ] 独立页登录某直播间 → 网页全屏/关弹幕 → 同步到桌面：桌面能看见，点桌面点不到播放器
- [ ] 直播：管理窗静音/音量有效；播放/进度是灰的
- [ ] 点播页：播放和倍速可用
- [ ] 客厅应用后：整桌是客厅，视频/书/网页在电视里，不是系统壁纸上漂一块
- [ ] 关电视：客厅在、内容停；再开进度还在
- [ ] 老板键：立刻藏；再按恢复；桌面图标仍可点
- [ ] DRM 失败页就停在站点提示，不要假成功
- [ ] 多屏：客厅+内容默认跟主屏；不要挡菜单栏点不到的程度超出桌面层常规行为

改了布局或状态写入后，把所有读同一状态的页面再点一遍，防止只在一个模式好用。

## 版本与文档

- macOS 源码版本建议标 **2.1.0 Preview**（或与产品一起叫 1.1 摸鱼神器 Mac 预览，但不要假装和 Windows 安装包是同一个 zip）
- 更新 `macos/README.md`、根目录 `README.md` / `README.en.md` 的 macOS 行
- 官方 Release 仍以 GitHub Releases 为准；没出包就写「本分支源码构建」

## 完成情况

- [ ] 播放条 / 列表
- [ ] 资料库路径与引用导入
- [ ] TXT / PDF
- [ ] 独立页 + 同步桌面 + 静音
- [ ] 客厅 / 关电视 / 老板键
- [ ] 真机验收
- [ ] 文档
- [ ] 已推 `feature/macos-1.1-moyushenqi`（未合并 `main`）
