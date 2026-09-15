# Third-party notices

This source repository does not commit third-party player or codec binaries, and the public Windows portable archive does not bundle them. The Windows first-run installer and developer dependency script download pinned upstream archives and verify their hashes. If you redistribute a compiled application or make a separate bundle containing those tools, you are responsible for preserving notices and satisfying every applicable source-code and license obligation.

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

The first-run installer and convenience download script are not substitutes for the complete corresponding-source obligations that apply when redistributing FFmpeg binaries. Consult `windows/LICENSES/` and the upstream distributor before publishing a bundle that directly contains those binaries.

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

The Windows application targets .NET 10 WPF. The public Windows portable release is a self-contained publish built with .NET SDK 10.0.401 and includes the .NET 10.0.12 Runtime and Windows Desktop (WPF) Runtime files.

- Runtime upstream: [dotnet/runtime v10.0.12](https://github.com/dotnet/runtime/tree/v10.0.12)
- WPF upstream: [dotnet/wpf v10.0.12](https://github.com/dotnet/wpf/tree/v10.0.12)
- Most runtime and WPF files: MIT License
- `coreclr.dll`, `Microsoft.DiaSymReader.Native.*.dll`, `PresentationNative_cor3.dll`, `vcruntime140_cor3.dll` and `wpfgfx_cor3.dll`: Microsoft .NET Library License, as identified by Microsoft's version-pinned Windows mapping
- `D3DCompiler_47_cor3.dll`: Microsoft Windows SDK License, as identified by the same mapping

The release build copies the matching SDK-root `LICENSE.txt` and `ThirdPartyNotices.txt`, and also includes the version-pinned WPF license/notices plus Microsoft's general and Windows-specific license mappings. See `windows/LICENSES/dotnet-10.0.12-SOURCES.md` for the exact upstream locations and applicable Microsoft license links.
