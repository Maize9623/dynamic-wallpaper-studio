<p align="center">
  <img src="macos/Resources/AppIcon-1024.png" width="112" alt="动态壁纸工作室图标">
</p>

<h1 align="center">动态壁纸工作室</h1>

<p align="center">
  本地优先的 macOS 与 Windows 视频动态壁纸管理器。
</p>

<p align="center">
  <a href="README.en.md">English</a> ·
  <a href="https://github.com/Maize9623/dynamic-wallpaper-studio/issues">问题反馈</a> ·
  <a href="https://github.com/Maize9623/dynamic-wallpaper-studio/security/policy">安全策略</a>
</p>

![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Windows](https://img.shields.io/badge/Windows-11-0078D4?logo=windows)
[![CI](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml)

动态壁纸工作室可以把本地视频变成桌面背景，并集中完成导入、转换、收藏、多显示器分配和画面适配。视频处理与资料库都留在本机，不需要账号，也不会上传媒体文件。

`feature/macos-1.1-moyushenqi` 把 macOS 源码升到 **2.1.0 Preview（摸鱼神器）**，与本仓库 Windows 1.1 对齐产品约定：连续播放条、引用导入、子库、TXT/MD/PDF、独立网页同步、短视频刷条、客厅伪装与老板键。**不要改 `main`，也不要把本分支合并进 `main`，除非另有明确要求。** 两边共享产品约定，不共享 UI 代码。

## 功能

- 拖拽或批量导入 MP4、MOV、M4V 视频
- 原始尺寸、显示器尺寸、1080p、2K、4K与自定义分辨率
- “完整显示”和“填满屏幕”两种模式，始终保持原始宽高比
- 为不同显示器分别选择壁纸
- 收藏、搜索、切换与删除壁纸
- 导入和导出可分享的动态壁纸包
- macOS 菜单栏控制；Windows 通知区域控制与安全模式

### 1.1.0 摸鱼神器（本分支）

- 播放条：播放/暂停、上一首/下一首、进度、音量、静音、倍速（1 / 1.25 / 1.5 / 2）；默认静音
- 列表按顺序播完即停；关闭列表后当前壁纸循环
- 资料库路径可自选；导入默认只引用原文件，不强制复制进资料库
- 侧栏可新建子库；可导入一整部剧的文件夹并按文件名排好。右键子库全部导入播放台时，二次确认替换或追加；播放台可批量移除
- 本地 TXT（UTF-8 / GB18030）、Markdown、PDF：字号、浅色/深色，并记住位置。TXT/MD 可在自动翻页和自动滚动之间切换，滚动速度可调，两者都有暂停
- 电子书上一页 / 下一页 / 暂停可设全局快捷键（默认 Control+Option+Left / Right / Space）
- 网页/直播：独立页面里登录、网页全屏、开关弹幕，再「同步到桌面」；桌面层不能点击
- 短视频模式：复用电子书快捷键刷上一条 / 下一条（抖音等）。「保持清屏」在换条和同步到桌面后继续藏点赞、收藏
- 客厅电视里的网页会略微上移，减少抖音顶部黑边，并露出底部字幕
- 直播时播放条同步静音/音量；B 站、腾讯等点播可再控制播放与倍速
- 独立网页配置（资料库 `WebProfile`：Windows 用 WebView2，macOS 用 `WKWebsiteDataStore`），不读取系统浏览器 Cookie，不破解 DRM
- 客厅电视伪装：客厅背景 + 电视框，macOS 可选居中或右下角（左边坐人、右侧大屏）方案；关电视冻结进度；老板键立刻隐藏（Windows 默认 Ctrl+Alt+B，macOS 默认 Control+Option+B）
- 资料库预览按视频方向排：横的横着显示，竖的竖着显示，不再强行竖卡留大黑框
- Windows 11 Raised Desktop 下客厅背景走与视频相同的原生分层窗口，避免只剩一块浮动画面
- macOS 用已有桌面 `NSWindow` + `AVQueuePlayer` / PDFKit / `WKWebView`，不搬 Win32、mpv IPC 或 WebView2。兼容标识 `local.baiyaoyu.dynamicwallpaperstudio`，旧资料库里已经拷过的条目不会丢

## 平台状态

| 平台 | 当前源码版本 | 技术栈 | 状态 |
|---|---:|---|---|
| macOS（本分支） | 2.1.0 Preview | SwiftUI、AppKit、AVFoundation、PDFKit、WebKit | macOS 15+；Apple Silicon 与 Intel；摸鱼神器 Preview |
| macOS（`main`） | 2.0.0 | SwiftUI、AppKit、AVFoundation | macOS 15+；Apple Silicon 与 Intel |
| Windows（`main`） | 1.0.5 | .NET 10 WPF、mpv、FFmpeg | Windows 11 x64 推荐；Preview |
| Windows（本仓库） | 1.1.0 | .NET 10 WPF、mpv、FFmpeg、WebView2 | Windows 11 x64 推荐；摸鱼神器 Preview |

两个版本共享产品目标，但不是同一套 UI 代码。Windows 版仍标记为 Preview：Explorer 更新、Raised Desktop、混合 DPI 或特殊多屏排列可能影响桌面嵌入。Windows 10 仅尽力兼容，不再作为正式支持目标。

## 下载安装包

前往 [最新 Release](https://github.com/Maize9623/dynamic-wallpaper-studio/releases/latest) 下载：

| 平台 | 下载文件 | 使用方式 |
|---|---|---|
| macOS（官方 Release） | `DynamicWallpaperStudio-macOS-2.0.0-Universal.dmg` | 打开 DMG，把应用拖入“应用程序” |
| macOS 2.1.0 Preview（摸鱼神器） | [预发布 `macos-2.1.0-moyushenqi`](https://github.com/Maize9623/dynamic-wallpaper-studio/releases/tag/macos-2.1.0-moyushenqi) 的 `DynamicWallpaperStudio-macOS-2.1.0-Universal.dmg` | 打开 DMG，把应用拖入“应用程序”。这是预发布，**不替换** `main` 上 Latest 的 2.0.0 |
| macOS 备用 | `DynamicWallpaperStudio-macOS-2.0.0-Universal.zip` | 解压后把应用拖入“应用程序” |
| Windows（官方 Release） | `DynamicWallpaperStudio-Windows-x64-1.0.5-OnlinePortable.zip` | 完整解压，运行 `DynamicWallpaperStudio.exe` |
| Windows 1.1.0 | 本分支源码构建 | 从本分支按下方「从源码开始」编译；尚未作为正式 Release 替换 `main` 的 1.0.5 安装包 |

Windows 便携包已自带带安全更新的 .NET 10 运行环境，不需要管理员权限。为避免直接再分发许可材料不完整的静态媒体工具，应用首次启动时会征求同意，再从固定且公开记录的分发来源下载约 190 MB 运行组件：mpv 官方 GitHub Release，以及 FFmpeg 官网列出的 gyan.dev 构建站。应用会先校验 SHA-256，随后继续打开；首次准备需要联网并建议预留 1–2 GB 临时空间。安全模式不会联网。

> [!IMPORTANT]
> 当前安装包没有正式代码签名。macOS 可能拦截未公证应用，请确认下载来源后在 Finder 中右键应用并选择“打开”，或前往“系统设置 → 隐私与安全性”选择“仍要打开”；不要全局关闭 Gatekeeper。Windows 可能显示 SmartScreen，请先核对 Release 页面中的 `SHA256SUMS.txt`，确认来源后再选择“更多信息”→“仍要运行”。Smart App Control 或企业策略可能不允许放行，请不要关闭系统防护，可改为自行审阅并构建源码。

## 从源码开始

### macOS

需要 macOS 15+、Xcode 16+ 与 Command Line Tools。

```bash
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
cd dynamic-wallpaper-studio
git checkout feature/macos-1.1-moyushenqi
./macos/scripts/build.sh
```

脚本会分别编译 Apple Silicon 与 Intel 程序，合并为 Universal 应用并进行本地 ad-hoc 签名。详细说明见 [macOS 构建文档](macos/README.md)。

### Windows

建议使用 Windows 11 x64，需要 PowerShell 7 与仓库 `global.json` 固定的 .NET SDK 10.0.401。

```powershell
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
Set-Location dynamic-wallpaper-studio
./windows/scripts/build.ps1 -CreateZip
```

默认公开构建不内置 FFmpeg 或 mpv，用户首次运行时再确认下载。仅制作内部测试包时可显式使用 `./windows/scripts/build.ps1 -IncludeThirdPartyTools`；该模式会从记录的上游地址下载固定版本并校验 SHA-256，不应直接用于公开 Release。详细说明见 [Windows 构建文档](windows/README.md)。要对齐 macOS 2.1 多出来的功能，请看 [Windows 交接稿](windows/WINDOWS_1.1_HANDOFF.md)。

## 壁纸包

- macOS 使用 `.dwallpaper` 目录包。
- Windows 使用 `.dwallpaper.zip` 压缩包。
- 当前跨平台传递不是完全一键式：Windows 导出的压缩包在 macOS 使用前需先解压为 `.dwallpaper` 目录。
- 仓库不包含示例视频或人物素材；请只分享你拥有再分发权的媒体。

## 性能与存储

长视频不会一次性全部载入内存，而是按需解码；时长主要影响磁盘空间。4K、高帧率、多屏同时播放，或编码格式不利于硬件解码时，仍会增加 CPU、GPU 与内存占用。

- 1.1 起 macOS 与 Windows 导入都默认只引用原文件；勾选复制或需要转换时，资料库才会留下播放副本。
- Windows 对兼容的 H.264 MP4 可以只保存原文件引用；需要转换时，资料库会保存一份 H.264/YUV420P、最高 30 fps 的成品。
- 主动导出的壁纸包是额外副本。

删除或移动引用模式下的原视频会使该壁纸失效。删除已复制到资料库的条目会删除应用管理的本地副本，但不会删除引用条目的原文件。

## 隐私

应用没有账号、云同步、遥测或媒体上传功能。资料库索引、缩略图与诊断日志均保存在本机。Windows 日志可能包含原视频的完整路径；公开提交日志前请先检查并脱敏。更多信息见 [隐私说明](PRIVACY.md)。

## 已知限制

- 应用必须在后台运行；它不会替换登录界面或锁屏壁纸。
- 当前 macOS 构建未使用 Developer ID 签名，也未经过 Apple 公证，手动构建或非官方包可能触发 Gatekeeper。
- 当前 Windows 构建没有 Authenticode 签名，可能触发 SmartScreen。
- Windows 开机启动只启动管理程序，目前不承诺自动恢复上一次播放。
- 桌面嵌入依赖系统内部窗口层级，系统更新后可能需要兼容性修复。
- 部分 Widevine 站点（例如部分腾讯视频）可能黑屏或提示换浏览器；页面会停在站点提示，不会伪装成播放成功。
- 抖音清屏只对当前一条有效；请勾选「保持清屏」。客厅电视里的网页会略微上移以露出字幕。

## 项目结构

```text
.
├── macos/                  # SwiftUI/AppKit 应用与 Universal 构建脚本
├── windows/                # .NET WPF 应用、依赖与发布脚本
├── .github/workflows/      # 源码构建检查
├── CONTRIBUTING.md
├── PRIVACY.md
├── SECURITY.md
└── THIRD_PARTY_NOTICES.md
```

## 参与贡献

欢迎提交问题、复现日志和 Pull Request。请先阅读 [贡献指南](CONTRIBUTING.md)；报告安全问题请遵循 [安全策略](SECURITY.md)。

## 许可与致谢

项目代码以 [GNU GPL 3.0 或更高版本](LICENSE)发布。Windows 桌面嵌入实现参考并改编自 GPL-3.0 的 [Lively Wallpaper](https://github.com/rocksdanister/lively)。FFmpeg、mpv、Vulkan Loader 与 .NET 仍分别适用各自许可证；版本、来源与分发说明见 [第三方声明](THIRD_PARTY_NOTICES.md) 和 `windows/LICENSES/`。
