# 动态壁纸工作室 · Windows

Windows 版使用 .NET 10 WPF 构建，通过 mpv 的 JSON IPC 播放视频，并通过 FFmpeg 检查媒体与按需转换。壁纸窗口会附着到 Explorer 的 Progman/WorkerW 桌面层；Windows 11 Raised Desktop 另有兼容路径。

当前版本为 **1.0.5 Preview**。

## 系统要求

- Windows 11，x64（推荐并作为公开便携版的正式测试目标）
- 首次准备建议预留 2 GB 可用空间（下载、校验和临时解压完成后会自动清理缓存）
- 首次正常启动需要访问 GitHub Releases 与 gyan.dev

最终用户不需要自行安装 .NET、PowerShell、FFmpeg 或 mpv。便携包已包含 .NET 运行时；视频组件由软件首次启动时获取。

普通消费版 Windows 10 22H2 已结束支持，也不在 [.NET 10 当前支持的 Windows 客户端列表](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md)中。本程序仍保留 Windows 10 API 兼容目标，可能可以运行，但只提供尽力兼容，不作为公开版本的正式支持承诺；仍处于生命周期内的 Windows 10 Enterprise/IoT LTSC 版本以微软列表为准。

## 便携包首次启动

公开 Release 不直接附带 mpv/FFmpeg 二进制。下载 ZIP 后：

1. 将整个 ZIP 解压到桌面、文档或其他可写文件夹，不能直接在压缩包预览窗口中运行。
2. 双击 `DynamicWallpaperStudio.exe`。
3. 阅读首次联网提醒并选择“是”。当前固定下载量约 190 MB，建议先预留 2 GB 空间。
4. 软件会显示进度，校验两个压缩包的 SHA-256，校验成功后仅提取 `mpv.exe`、`vulkan-1.dll`、`ffmpeg.exe` 和 `ffprobe.exe` 到程序旁的 `tools/`。

下载来源固定为 mpv 0.41.0 的 GitHub 官方 Release，以及 FFmpeg 官网列出的 Windows 构建提供方 gyan.dev 的 FFmpeg 9.0.1 Essentials。URL 和 SHA-256 编译在程序内，下载内容不匹配时会立即丢弃，不会执行。

首次下载失败时可以重试；取消后软件会退出，下次正常启动仍会重新询问。`安全模式启动.cmd` 不会联网，便于在组件缺失或网络不可用时进入管理界面。

软件本身及首次组件下载都不会上传视频、资料库或使用数据。诊断日志可能包含本地视频路径，公开反馈前请先检查并遮盖私人信息。

## 开发者获取第三方运行工具

从源码构建需要仓库 `global.json` 固定的 .NET SDK 10.0.401 与 PowerShell 7；该 SDK 对应当前 .NET 10.0.12 安全运行时。仅编译源码不需要下载播放器组件。需要本地运行源码目录时，可在仓库根目录的 PowerShell 中执行：

```powershell
./windows/scripts/fetch-dependencies.ps1
```

脚本下载并校验：

- mpv 0.41.0：`mpv.exe`、`vulkan-1.dll`
- FFmpeg 9.0.1 Essentials：`ffmpeg.exe`、`ffprobe.exe`

文件只会安装到 `windows/tools/`，并已被 Git 忽略。固定 URL、SHA-256 和安全解压逻辑都保存在脚本中。许可证与源码获取说明位于 `windows/LICENSES/` 和仓库根目录的 `THIRD_PARTY_NOTICES.md`。

如需制作一个已内置这些工具的内部测试目录，请直接执行：

```powershell
./windows/scripts/build.ps1 -IncludeThirdPartyTools
```

## 构建公开便携版本

```powershell
./windows/scripts/build.ps1
```

默认生成 self-contained 的 Windows x64 目录，但**不会**把 mpv/FFmpeg 放进产物；最终用户首次运行时由应用获取：

```text
windows/artifacts/DynamicWallpaperStudio-Windows-x64-1.0.5-OnlinePortable/
```

生成可上传到 Release 的 ZIP 与同名 SHA-256 文件：

```powershell
./windows/scripts/build.ps1 -CreateZip
```

默认文件名为 `DynamicWallpaperStudio-Windows-x64-1.0.5-OnlinePortable.zip`，并同时生成同名 `.zip.sha256` 文件。正式 Release 还会把各平台哈希合并公布为 `SHA256SUMS.txt`。

仅在内部测试确实需要把已下载工具放进构建目录时，显式执行：

```powershell
./windows/scripts/build.ps1 -IncludeThirdPartyTools
```

不要把带 `-IncludeThirdPartyTools` 生成的目录直接作为公开 Release，除非已经完成相应二进制的完整许可证、构建信息和对应源码义务。

指定空的输出目录：

```powershell
./windows/scripts/build.ps1 -OutputDirectory "D:\Builds\DynamicWallpaperStudio"
```

脚本故意拒绝覆盖非空目录，以免误删本地文件。它还会把所用 .NET SDK 旁的 `LICENSE.txt` 与 `ThirdPartyNotices.txt` 复制到发布目录的 `LICENSES/`；制作公开 ZIP 前应确认这两个文件存在。

只检查源码能否编译而不运行播放器时，可以执行：

```powershell
dotnet build ./windows/DynamicWallpaperStudio.Windows.csproj -c Release
```

## 运行与故障恢复

从发布目录运行 `DynamicWallpaperStudio.exe`。应用为便携模式时，资料库、下载的视频组件与日志均位于程序目录；其他构建可使用用户的本地应用数据目录。

如果桌面变黑、窗口位置异常或 Explorer 桌面层无法附着：

1. 运行 `紧急关闭动态壁纸.cmd` 停止播放器。
2. 运行 `安全模式启动.cmd` 打开管理界面但不启动动态壁纸。
3. 检查 `Data/Logs/latest.log`，公开提交前先删除私人路径。

Windows 桌面层不是微软提供的正式动态壁纸 API。Explorer 更新、Raised Desktop、多显示器混合 DPI 或非标准排列都可能需要额外兼容处理。

## 可选示例

公开仓库不附带示例媒体。私有构建可自行放入：

```text
windows/Samples/StarterWallpaper.mp4
windows/Samples/StarterPoster.jpg
```

请只分发你拥有相应权利的媒体。

## 签名与再分发

当前便携版未使用 Authenticode 代码签名，Windows 可能显示 SmartScreen 提示。请只从本项目 GitHub Release 下载，并先核对 Release 中公布的 SHA-256；确认来源后可在提示中点击“更多信息”再选择“仍要运行”。Smart App Control 或企业安全策略可能完全禁止运行且不提供放行入口；请不要为此关闭系统防护，可改为自行审阅并构建源码。

公开便携包包含 self-contained .NET 运行时，因此必须保留 `LICENSES/dotnet-LICENSE.txt` 与 `LICENSES/dotnet-ThirdPartyNotices.txt`。它不直接包含 mpv、FFmpeg 或 Vulkan Loader 二进制；这些组件由最终用户从固定上游地址下载并校验。

如果制作另一种把第三方工具直接放入 ZIP 的发行包，还必须自行处理：

- FFmpeg 和 mpv 精确二进制对应的源码、构建信息及许可证义务
- 对应 Vulkan Loader 的许可证声明
- 你自己的代码签名与私钥安全

`1.0.5` 仍是 Preview：播放器内核和 Windows 桌面层兼容性没有变成微软支持的正式 API，建议先在非关键电脑上试用。退出软件或运行 `紧急关闭动态壁纸.cmd` 可恢复普通桌面。
