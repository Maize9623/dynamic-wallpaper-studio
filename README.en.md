<p align="center">
  <img src="macos/Resources/AppIcon-1024.png" width="112" alt="Dynamic Wallpaper Studio icon">
</p>

<h1 align="center">Dynamic Wallpaper Studio</h1>

<p align="center">
  A local-first video wallpaper manager for macOS and Windows.
</p>

<p align="center">
  <a href="README.md">简体中文</a> ·
  <a href="https://github.com/Maize9623/dynamic-wallpaper-studio/issues">Issues</a> ·
  <a href="https://github.com/Maize9623/dynamic-wallpaper-studio/security/policy">Security</a>
</p>

![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)
![Windows](https://img.shields.io/badge/Windows-11-0078D4?logo=windows)
[![CI](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml)

Dynamic Wallpaper Studio turns local videos into desktop backgrounds and provides one place to import, convert, favorite, assign and scale them. Media processing and the wallpaper library stay on your computer. No account or upload is required.

The `feature/windows-1.1-moyushenqi` branch upgrades the Windows source to **1.1.0 “摸鱼神器” Preview**: a transport HUD, optional library path, TXT/PDF reader, isolated live/web sync, and a living-room TV camouflage. `main` is unchanged. macOS is not ported yet; implement it on a Mac from [macos/MACOS_1.1_HANDOFF.md](macos/MACOS_1.1_HANDOFF.md) on a new `feature/macos-1.1-moyushenqi` branch.

## Features

- Drag-and-drop and batch import for MP4, MOV and M4V videos
- Original, display, 1080p, 2K, 4K and custom output resolutions
- Fit and Fill modes that preserve the source aspect ratio
- Per-display wallpaper assignment
- Favorites, search, switching and library cleanup
- Muted seamless looping
- Import and export of shareable wallpaper packages
- Menu bar controls on macOS; notification area controls and safe mode on Windows

### Windows 1.1.0 (this branch)

- Transport HUD: play/pause, previous/next, seek, volume, mute, speed (1 / 1.25 / 1.5 / 2); muted by default
- Playlist plays in order and stops on the last item; turn playlist mode off to loop the current wallpaper
- User-chosen library path; imports default to referencing the original file instead of copying to the C: drive
- Local TXT / PDF reader with font size, light/dark theme, manual or auto page turns, and remembered position
- Web/live: log in, enter page-fullscreen, and toggle danmaku in an independent window, then Sync to desktop; the wallpaper layer is not clickable
- Live streams: HUD mute/volume apply to the page; Bilibili/Tencent-style VOD can also use play and speed
- Isolated WebView2 profile under the library `WebProfile` folder; no system Edge cookies and no DRM circumvention
- Living-room TV camouflage, freeze-on-TV-off, and a boss key (default Ctrl+Alt+B)
- On Windows 11 Raised Desktop the living-room backdrop uses the same native layered path as video, so it is not just a floating rectangle

## Platform status

| Platform | Source version | Stack | Status |
|---|---:|---|---|
| macOS | 2.0.0 | SwiftUI, AppKit, AVFoundation | macOS 15+; Apple Silicon and Intel |
| Windows (`main`) | 1.0.5 | .NET 10 WPF, mpv, FFmpeg | Windows 11 x64 recommended; Preview |
| Windows (this branch) | 1.1.0 | .NET 10 WPF, mpv, FFmpeg, WebView2 | Windows 11 x64 recommended; 摸鱼神器 Preview |

The two applications share a product goal, not a UI codebase. The Windows build remains a preview because Explorer updates, Raised Desktop, mixed DPI and unusual multi-monitor layouts can affect desktop embedding. Windows 10 is best-effort compatibility rather than a formally supported target.

## Download an app package

Open the [latest release](https://github.com/Maize9623/dynamic-wallpaper-studio/releases/latest) and download:

| Platform | File | How to use it |
|---|---|---|
| macOS | `DynamicWallpaperStudio-macOS-2.0.0-Universal.dmg` | Open the DMG and drag the app to Applications |
| macOS alternative | `DynamicWallpaperStudio-macOS-2.0.0-Universal.zip` | Extract and drag the app to Applications |
| Windows (official Release) | `DynamicWallpaperStudio-Windows-x64-1.0.5-OnlinePortable.zip` | Extract everything, then run `DynamicWallpaperStudio.exe` |
| Windows 1.1.0 | Build this branch from source | Follow “Build from source” below; this branch does not replace the 1.0.5 Release on `main` |

The Windows portable package includes the security-patched .NET 10 runtime and needs no administrator access. To avoid directly redistributing static media-tool binaries without complete corresponding-source materials, the app asks for consent on first launch and downloads about 190 MB from fixed, documented distributors: mpv's official GitHub release and the gyan.dev build site listed by FFmpeg. It verifies SHA-256 before continuing. First-time setup needs internet access and 1–2 GB of temporary free space. Safe mode never downloads components.

> [!IMPORTANT]
> Current packages do not have production code signatures. macOS can block an unnotarized app; after verifying the download, right-click it in Finder and choose Open, or use Open Anyway in System Settings → Privacy & Security—do not disable Gatekeeper globally. Windows can show SmartScreen; compare the file with `SHA256SUMS.txt` before choosing More info → Run anyway. Smart App Control or an organization policy can block it without an override; do not disable system protection, and build the reviewed source instead.

## Build from source

### macOS

Requires macOS 15+, Xcode 16+ and the Command Line Tools.

```bash
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
cd dynamic-wallpaper-studio
./macos/scripts/build.sh
```

The script builds Apple Silicon and Intel executables, merges them into a Universal app, and applies a local ad-hoc signature. See the [macOS build guide](macos/README.md).

### Windows

Windows 11 x64 is recommended. Building requires PowerShell 7 and the exact .NET SDK 10.0.401 pinned by the repository's `global.json`.

```powershell
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
Set-Location dynamic-wallpaper-studio
./windows/scripts/build.ps1 -CreateZip
```

The default public build excludes FFmpeg and mpv; users consent to downloading them on first launch. Use `./windows/scripts/build.ps1 -IncludeThirdPartyTools` only for an internal test package. That mode downloads pinned upstream builds and verifies SHA-256, and it should not be published directly as a public Release. See the [Windows build guide](windows/README.md).

## Wallpaper packages

- macOS uses `.dwallpaper` directory packages.
- Windows uses `.dwallpaper.zip` archives.
- Cross-platform transfer is not yet one-click: extract a Windows archive into a `.dwallpaper` directory before importing it on macOS.
- No demo video or character artwork is included. Only redistribute media you have permission to share.

## Performance and storage

Long videos are decoded on demand rather than loaded wholly into memory, so duration mainly affects disk usage. 4K, high-frame-rate or multi-display playback—and formats that cannot use hardware decoding—can still increase CPU, GPU and memory use.

- macOS copies every imported source into its managed library; choosing a converted resolution also creates a converted copy.
- Windows may reference a compatible H.264 MP4 in place. When conversion is required, the library stores one H.264/YUV420P output capped at 30 fps.
- A wallpaper package you explicitly export is an additional copy.

Moving or deleting a source used by Windows reference mode breaks that library item. Removing a macOS library item deletes the app-managed local copy.

## Privacy

The apps have no account system, cloud sync, telemetry or media upload. Library indexes, thumbnails and diagnostics remain local. Windows logs can contain full source-video paths; inspect and redact them before posting publicly. See the [privacy notice](PRIVACY.md).

## Known limitations

- The app must keep running in the background; it does not replace the login or lock-screen wallpaper.
- Current macOS builds are not Developer ID signed or Apple-notarized, so local or unofficial builds can trigger Gatekeeper.
- Current Windows builds are not Authenticode signed and can trigger SmartScreen.
- Windows launch-at-login starts the manager but does not currently promise automatic playback restoration.
- Desktop embedding relies on system window hierarchies that can change in operating-system updates.

## Repository layout

```text
.
├── macos/                  # SwiftUI/AppKit app and Universal build script
├── windows/                # .NET WPF app, dependency and publish scripts
├── .github/workflows/      # Source build checks
├── CONTRIBUTING.md
├── PRIVACY.md
├── SECURITY.md
└── THIRD_PARTY_NOTICES.md
```

## Contributing

Issues, reproducible diagnostics and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and use [SECURITY.md](SECURITY.md) for vulnerability reports.

## License and credits

Project code is released under the [GNU GPL version 3 or later](LICENSE). The Windows desktop integration references and adapts techniques from the GPL-3.0 [Lively Wallpaper](https://github.com/rocksdanister/lively) project. FFmpeg, mpv, Vulkan Loader and .NET remain under their respective licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `windows/LICENSES/` for versions, sources and distribution notes.
