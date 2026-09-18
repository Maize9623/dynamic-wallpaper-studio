# 动态壁纸工作室 · macOS

macOS 版使用 Swift、SwiftUI、AppKit、AVFoundation、PDFKit 与 WebKit 编写，不依赖第三方包。本分支源码版本为 **2.1.0 Preview（摸鱼神器）**，与 Windows 1.1 对齐产品约定，不共享 UI 代码。不要改 `main`。

## 系统要求

- macOS 15.0 或更高版本
- Apple Silicon 或 Intel Mac
- Xcode Command Line Tools（从源码构建时需要）

安装命令行工具：

```bash
xcode-select --install
```

## 从源码构建

在仓库根目录执行：

```bash
git checkout feature/macos-1.1-moyushenqi
./macos/scripts/build.sh
```

脚本会分别编译 `arm64` 与 `x86_64`，合并为 Universal 2 可执行文件，组装应用包并进行 ad-hoc 签名。构建结果位于：

```text
macos/dist/动态壁纸工作室.app
```

可以这样检查架构：

```bash
file "macos/dist/动态壁纸工作室.app/Contents/MacOS/DynamicWallpaperStudio"
```

如需生成与 Release 同名的 Universal ZIP、DMG 和 SHA-256 文件，请确保 `macos/artifacts/` 中没有同名旧产物，然后执行：

```bash
./macos/scripts/package.sh
```

打包脚本会重新构建应用，检查 `arm64`/`x86_64` 架构与签名，解压或挂载成品复验，并默认排除本地示例视频。它会拒绝覆盖已有产物。当前正式 GitHub Release 仍可能是 2.0.0；本分支以源码构建为准。

## 1.1 摸鱼神器

- 播放条：播放 / 暂停、上一首 / 下一首、进度、音量、静音、倍速（1 / 1.25 / 1.5 / 2）；默认静音
- 列表按用户顺序播完即停；关闭列表后当前壁纸循环
- 资料库路径可自选；导入默认引用原文件，勾选后才复制
- 侧栏可新建子库；拖入或导入一整个剧集文件夹会按文件名排好。右键子库可全部导入播放台，二次确认替换或追加。播放台可勾选批量移除
- 本地 TXT（UTF-8 / GB18030）、Markdown 与 PDF：字号、浅色 / 深色、翻页；TXT/MD 可在自动翻页和自动滚动之间切换，滚动速度可拖条调节，两者都有暂停；上一页 / 下一页 / 暂停可在电子书和设置里改全局快捷键（默认 Control+Option+Left / Right / Space）
- 网页 / 直播：独立窗口登录、网页全屏、开关弹幕，再「同步到桌面」；桌面层 `ignoresMouseEvents`
- 短视频模式：复用电子书上一条 / 下一条 / 暂停快捷键刷抖音。勾选「保持清屏」后，换条和同步到桌面都会再清一次点赞收藏
- 客厅电视里的网页默认上移约 7% 电视高度，避开抖音顶部黑边，露出底部字幕
- 直播只保证静音 / 音量；点播再开放播放与倍速。独立 `WKWebsiteDataStore`，不读系统浏览器 Cookie，不破解 DRM
- 客厅电视伪装、关电视冻结进度、老板键（默认 Control+Option+B）
- 兼容标识 `local.baiyaoyu.dynamicwallpaperstudio`，旧资料库里已经拷过的条目不会丢

## 可选的内置示例壁纸

公开源码不附带示例视频。若希望首次启动时自动导入一段视频，可在构建时指定 MP4：

```bash
STARTER_WALLPAPER="/绝对路径/示例.mp4" ./macos/scripts/build.sh
```

也可以自行放置 `macos/Resources/StarterWallpaper.mp4` 后再运行构建脚本。该文件只会被复制进应用包；构建过程不会修改原视频，也不会联网下载资源。请确保你有权分发所使用的视频。

## 运行与安装

把构建出的 `.app` 拖入“应用程序”即可。应用通过桌面层窗口播放内容，因此使用动态壁纸时需要保持应用在运行；关闭管理窗口不会退出，仍可从菜单栏图标控制。

本地构建仅进行 ad-hoc 签名，没有使用 Apple Developer ID，也没有经过 Apple 公证。若从其他电脑收到应用包，macOS 可能显示安全提示；请在确认来源可信后，通过 Finder 右键应用并选择“打开”。不要全局关闭 Gatekeeper。

## 支持的文件与数据位置

- 视频：MP4、MOV、M4V
- 电子书：TXT、Markdown、PDF
- 可移植壁纸包：`.dwallpaper`
- 默认资料库：`~/Library/Application Support/local.baiyaoyu.dynamicwallpaperstudio/`
- 网页配置：资料库下 `WebProfile/`
- 自定义资料库指针：上述目录中的 `library-root.txt`
- 登录启动配置：`~/Library/LaunchAgents/local.baiyaoyu.dynamicwallpaperstudio.plist`

上述 `local.baiyaoyu` 标识为已发布版本的兼容标识。源码暂时保留它，以确保升级后仍能找到已有资料库和登录项。

导入默认只引用原文件；勾选「复制到资料库」或选择转换分辨率时，才会在资料库里留下播放副本。删除引用条目只删记录和封面，不删用户原视频。长视频转换会显著增加磁盘占用。

## 当前限制

- 仅支持 macOS 15 及以上版本。
- 源码构建不是面向终端用户的正式签名/公证发行包。
- 动态内容只显示在已登录的桌面，不会替换系统登录或锁定界面。
- 视频转换使用系统 AVFoundation；最终可用编码取决于系统与硬件能力。
- 部分 Widevine 站点（例如部分腾讯视频）可能黑屏或提示换浏览器，页面会停在站点提示，不会伪装成播放成功。
- 客厅 + 内容默认跟主屏。
- 抖音自带清屏只对当前一条有效，请勾选「保持清屏」。客厅电视里的网页会略微上移。

项目整体的许可证、隐私说明与贡献方式请参阅仓库根目录文档。移植说明见 [MACOS_1.1_HANDOFF.md](MACOS_1.1_HANDOFF.md)。
