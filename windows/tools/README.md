# Runtime tools

This directory intentionally contains no third-party executables in the source
repository. A runnable Windows package needs these four files:

- `mpv.exe`
- `vulkan-1.dll`
- `ffmpeg.exe`
- `ffprobe.exe`

From Windows PowerShell, install the pinned files with:

```powershell
.\scripts\fetch-dependencies.ps1
```

The script downloads mpv 0.41.0 and the FFmpeg 9.0.1 essentials build from their
upstream distributors, verifies each archive against a hard-coded SHA-256 digest,
checks ZIP paths before extraction, and copies only the four named runtime files.

Do not commit downloaded binaries. See [`../LICENSES`](../LICENSES) for upstream
source and license information.
