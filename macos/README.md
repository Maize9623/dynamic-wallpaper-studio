# 动态壁纸工作室 · macOS

macOS 版使用 Swift、SwiftUI、AppKit 与 AVFoundation 编写，不依赖第三方包。它可以导入常见视频，按显示器尺寸转换，在多显示器之间分配壁纸，并在菜单栏中暂停或切换收藏。

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

打包脚本会重新构建应用，检查 `arm64`/`x86_64` 架构与签名，解压或挂载成品复验，并默认排除本地示例视频。它会拒绝覆盖已有产物。

## 可选的内置示例壁纸

公开源码不附带示例视频。若希望首次启动时自动导入一段视频，可在构建时指定 MP4：

```bash
STARTER_WALLPAPER="/绝对路径/示例.mp4" ./macos/scripts/build.sh
```

也可以自行放置 `macos/Resources/StarterWallpaper.mp4` 后再运行构建脚本。该文件只会被复制进应用包；构建过程不会修改原视频，也不会联网下载资源。请确保你有权分发所使用的视频。

## 运行与安装

把构建出的 `.app` 拖入“应用程序”即可。应用通过桌面层窗口播放视频，因此使用动态壁纸时需要保持应用在运行；关闭管理窗口不会退出，仍可从菜单栏图标控制。

本地构建仅进行 ad-hoc 签名，没有使用 Apple Developer ID，也没有经过 Apple 公证。若从其他电脑收到应用包，macOS 可能显示安全提示；请在确认来源可信后，通过 Finder 右键应用并选择“打开”。不要全局关闭 Gatekeeper。

## 支持的文件与数据位置

- 视频：MP4、MOV、M4V
- 可移植壁纸包：`.dwallpaper`
- 本地资料库：`~/Library/Application Support/local.baiyaoyu.dynamicwallpaperstudio/`
- 登录启动配置：`~/Library/LaunchAgents/local.baiyaoyu.dynamicwallpaperstudio.plist`

上述 `local.baiyaoyu` 标识为已发布版本的兼容标识。源码暂时保留它，以确保升级后仍能找到已有资料库和登录项。

导入时应用会把用于播放的素材复制到本地资料库；若选择转换分辨率，还会产生转换后的副本。长视频会显著增加磁盘占用。删除壁纸前请保留自己的原始素材备份。

## 当前限制

- 仅支持 macOS 15 及以上版本。
- 源码构建不是面向终端用户的正式签名/公证发行包。
- 动态内容只显示在已登录的桌面，不会替换系统登录或锁定界面。
- 视频转换使用系统 AVFoundation；最终可用编码取决于系统与硬件能力。

项目整体的许可证、隐私说明与贡献方式请参阅仓库根目录文档。
