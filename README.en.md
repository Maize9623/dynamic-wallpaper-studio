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
![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
[![CI](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/Maize9623/dynamic-wallpaper-studio/actions/workflows/ci.yml)

Dynamic Wallpaper Studio turns local videos into desktop backgrounds and provides one place to import, convert, favorite, assign and scale them. Media processing and the wallpaper library stay on your computer. No account or upload is required.

## Features

- Drag-and-drop and batch import for MP4, MOV and M4V videos
- Original, display, 1080p, 2K, 4K and custom output resolutions
- Fit and Fill modes that preserve the source aspect ratio
- Per-display wallpaper assignment
- Favorites, search, switching and library cleanup
- Muted seamless looping
- Import and export of shareable wallpaper packages
- Menu bar controls on macOS; notification area controls and safe mode on Windows

## Platform status

| Platform | Source version | Stack | Status |
|---|---:|---|---|
| macOS | 2.0.0 | SwiftUI, AppKit, AVFoundation | macOS 15+; Apple Silicon and Intel |
| Windows | 1.0.4 | .NET 10 WPF, mpv, FFmpeg | Windows 10/11 x64; Preview |

The two applications share a product goal, not a UI codebase. The Windows build remains a preview because Explorer updates, Raised Desktop, mixed DPI and unusual multi-monitor layouts can affect desktop embedding.

## Downloads

The initial public release provides the latest cleaned and build-verified source. Existing prebuilt packages are intentionally not uploaded yet: the macOS bundle still needs Developer ID signing and notarization, while a redistributable Windows bundle needs a complete corresponding-source archive for its static FFmpeg/mpv builds. GitHub source snapshots and the build scripts below are unaffected.

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

Requires Windows 10/11 x64, PowerShell 7 and the .NET 10 SDK.

```powershell
git clone https://github.com/Maize9623/dynamic-wallpaper-studio.git
Set-Location dynamic-wallpaper-studio
./windows/scripts/fetch-dependencies.ps1
./windows/scripts/build.ps1
```

The dependency script downloads pinned FFmpeg and mpv builds from their upstream distributors and verifies SHA-256 before extraction. Third-party binaries are deliberately excluded from Git history. See the [Windows build guide](windows/README.md).

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
