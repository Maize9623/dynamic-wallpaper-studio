# Runtime tools

This directory intentionally contains no third-party executables in the source
repository or public portable archive. A runnable Windows installation needs
these four files:

- `mpv.exe`
- `vulkan-1.dll`
- `ffmpeg.exe`
- `ffprobe.exe`

The app's normal first-run setup installs them automatically. From a source
checkout, Windows PowerShell can install the same pinned files with:

```powershell
.\scripts\fetch-dependencies.ps1
```

The script downloads mpv 0.41.0 and the FFmpeg 9.0.1 essentials build from their
upstream distributors, verifies each archive against a hard-coded SHA-256 digest,
checks ZIP paths before extraction, and copies only the four named runtime files.
Public portable builds leave the directory empty so each user obtains the
binaries from their fixed upstream distributor.

Do not commit downloaded binaries. See [`../LICENSES`](../LICENSES) for upstream
source and license information.
