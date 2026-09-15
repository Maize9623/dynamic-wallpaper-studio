# 动态壁纸工作室 · Windows

Windows 版使用 .NET 10 WPF 构建，通过 mpv 的 JSON IPC 播放视频，并通过 FFmpeg 检查媒体与按需转换。壁纸窗口会附着到 Explorer 的 Progman/WorkerW 桌面层；Windows 11 Raised Desktop 另有兼容路径。

当前版本为 **1.0.4 Preview**。

## 系统要求

- Windows 10 22H2 或 Windows 11，x64
- PowerShell 7
- .NET 10 SDK（从源码构建时）
- 构建依赖脚本可访问 GitHub Releases 与 gyan.dev

## 获取第三方运行工具

在仓库根目录的 PowerShell 中执行：

```powershell
./windows/scripts/fetch-dependencies.ps1
```

脚本下载并校验：

- mpv 0.41.0：`mpv.exe`、`vulkan-1.dll`
- FFmpeg 9.0.1 Essentials：`ffmpeg.exe`、`ffprobe.exe`

文件只会安装到 `windows/tools/`，并已被 Git 忽略。固定 URL、SHA-256 和安全解压逻辑都保存在脚本中。许可证与源码获取说明位于 `windows/LICENSES/` 和仓库根目录的 `THIRD_PARTY_NOTICES.md`。

## 构建可运行版本

```powershell
./windows/scripts/build.ps1
```

默认会先获取依赖，再生成 self-contained 的 Windows x64 目录：

```text
windows/artifacts/DynamicWallpaperStudio-Windows-x64/
```

如果已经获取依赖，可以跳过下载：

```powershell
./windows/scripts/build.ps1 -SkipDependencyDownload
```

指定空的输出目录：

```powershell
./windows/scripts/build.ps1 -OutputDirectory "D:\Builds\DynamicWallpaperStudio"
```

脚本故意拒绝覆盖非空目录，以免误删本地文件。

只检查源码能否编译而不运行播放器时，可以执行：

```powershell
dotnet build ./windows/DynamicWallpaperStudio.Windows.csproj -c Release
```

## 运行与故障恢复

从发布目录运行 `DynamicWallpaperStudio.exe`。应用为便携模式时，资料库与日志位于程序旁的 `Data/`；其他构建可使用用户的本地应用数据目录。

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

本地构建未使用 Authenticode 代码签名，Windows 可能显示 SmartScreen 提示。公开分发 self-contained 成品时，还必须一并处理：

- 对应 .NET 发行版的 `LICENSE.txt` 与 `ThirdPartyNotices.txt`
- FFmpeg 和 mpv 精确二进制对应的源码、构建信息及许可证义务
- 你自己的代码签名与私钥安全

当前仓库提供可复现的源码获取与本地构建流程，但不会自动生成可公开再分发的签名安装包。
