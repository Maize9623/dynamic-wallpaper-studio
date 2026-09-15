# Third-party notices

This source repository does not commit third-party player, codec or runtime binaries. The Windows dependency script downloads pinned upstream archives and verifies their hashes. If you redistribute a compiled application, you are responsible for preserving notices and satisfying every applicable source-code and license obligation.

## Lively Wallpaper

The Windows desktop integration references and adapts the Progman/WorkerW and Windows 11 Raised Desktop techniques used by [Lively Wallpaper](https://github.com/rocksdanister/lively), by rocksdanister and contributors.

- License: GNU GPL version 3
- Relationship: source-level technique and implementation reference
- Included here: adapted application source; no Lively binary

The project as a whole is consequently distributed under GPL-3.0-or-later.

## FFmpeg

Windows conversion and media inspection invoke `ffmpeg.exe` and `ffprobe.exe` as separate processes.

- Pinned build: FFmpeg 9.0.1 Essentials, distributed by [gyan.dev](https://www.gyan.dev/ffmpeg/builds/)
- Upstream source: [FFmpeg](https://ffmpeg.org/)
- License: the pinned build is GPLv3; exact configuration and bundled-library notices are included by its distributor
- Included here: license and source-location notices only; no executable

The convenience download script is not a substitute for the complete corresponding-source obligations that apply when redistributing FFmpeg binaries. Consult `windows/LICENSES/` and the upstream distributor before publishing a binary bundle.

## mpv

Windows playback invokes `mpv.exe` through its JSON IPC interface.

- Pinned build: mpv v0.41.0 Windows x86-64 MSVC archive from [mpv-player/mpv releases](https://github.com/mpv-player/mpv/releases/tag/v0.41.0)
- Upstream source: [mpv-player/mpv](https://github.com/mpv-player/mpv)
- License: GPLv2-or-later by default; parts can be LGPLv2.1-or-later when built with the documented LGPL configuration
- Included here: copyright, GPL/LGPL texts and source-location notices only; no executable

Official static Windows builds can include statically linked dependencies. Anyone redistributing those binaries must provide the exact corresponding source and notices for mpv and applicable dependencies.

## Vulkan Loader

The pinned mpv archive includes `vulkan-1.dll` for Vulkan runtime loading.

- Upstream source: [KhronosGroup/Vulkan-Loader](https://github.com/KhronosGroup/Vulkan-Loader)
- License: Apache License 2.0
- Included here: license text only; no binary

## Microsoft .NET

The Windows application targets .NET 10 WPF. A framework-dependent local build uses an installed .NET runtime; a self-contained publish includes Microsoft runtime files.

- Upstream: [.NET](https://github.com/dotnet/runtime)
- Licenses and notices: distributed with the .NET SDK/runtime

If you redistribute a self-contained build, include the matching Microsoft `LICENSE.txt` and `ThirdPartyNotices.txt` from that distribution.
