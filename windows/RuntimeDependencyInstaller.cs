using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace DynamicWallpaperStudio;

public readonly record struct DependencyInstallProgress(string Status, double Fraction);

/// <summary>
/// Installs the external video tools on first run. The public portable archive
/// intentionally does not redistribute mpv or FFmpeg binaries: they are fetched
/// from pinned upstream archives and accepted only after an SHA-256 check.
/// </summary>
public static class RuntimeDependencyInstaller
{
    private const string BundleId = "mpv-0.41.0+ffmpeg-9.0.1";
    private const string StampFileName = ".runtime-dependencies.json";
    private const long MaximumArchiveBytes = 600L * 1024 * 1024;
    private const long MaximumExtractedFileBytes = 600L * 1024 * 1024;
    private const long MinimumFreeSpaceBytes = 1500L * 1024 * 1024;

    private static readonly DependencyArchive Mpv = new(
        "mpv 0.41.0",
        "https://github.com/mpv-player/mpv/releases/download/v0.41.0/mpv-v0.41.0-x86_64-pc-windows-msvc.zip",
        "4e197f729f5071c6772f35fffd96e0f36e3e8a044bd9479b136bb09b7c6a80ff",
        ["mpv.exe", "vulkan-1.dll"]);

    private static readonly DependencyArchive Ffmpeg = new(
        "FFmpeg 9.0.1 Essentials",
        "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.1-essentials_build.zip",
        "fec81ae03971d9dd4be3ebe02e263bd2ec1d789483f931bdba5f5715e65da2e9",
        ["ffmpeg.exe", "ffprobe.exe"]);

    private static readonly string[] RequiredFiles = ["mpv.exe", "vulkan-1.dll", "ffmpeg.exe", "ffprobe.exe"];

    public static string ToolsDirectory => Path.Combine(AppContext.BaseDirectory, "tools");

    public static string ConsentMessage =>
        "这个公开便携包不直接附带第三方视频组件。首次使用需要联网下载：\n\n" +
        "• mpv 0.41.0（GitHub 官方 Release）\n" +
        "• FFmpeg 9.0.1 Essentials（FFmpeg 官网列出的 Windows 构建站 gyan.dev）\n\n" +
        "下载量约 190 MB，首次准备建议预留 2 GB 空间。程序会先核验固定 SHA-256，再把所需文件安装到软件目录的 tools 文件夹；不会上传你的壁纸或其他文件。\n\n" +
        "是否现在下载？";

    public static bool IsInstalled
    {
        get
        {
            try
            {
                if (RequiredFiles.Any(name =>
                    !File.Exists(Path.Combine(ToolsDirectory, name)) ||
                    new FileInfo(Path.Combine(ToolsDirectory, name)).Length == 0)) return false;
                var stampPath = Path.Combine(ToolsDirectory, StampFileName);
                if (!File.Exists(stampPath)) return false;
                using var stamp = JsonDocument.Parse(File.ReadAllText(stampPath));
                return stamp.RootElement.TryGetProperty("bundleId", out var value)
                    && string.Equals(value.GetString(), BundleId, StringComparison.Ordinal);
            }
            catch { return false; }
        }
    }

    public static async Task InstallAsync(
        IProgress<DependencyInstallProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        EnsureInstallDirectoryIsWritable();
        var temporaryRoot = Path.Combine(Path.GetTempPath(), "dynamic-wallpaper-studio-dependencies-" + Guid.NewGuid().ToString("N"));
        EnsureFreeDiskSpace(ToolsDirectory, temporaryRoot);
        var extractedRoot = Path.Combine(temporaryRoot, "extracted");
        Directory.CreateDirectory(extractedRoot);

        try
        {
            using var client = new HttpClient(new HttpClientHandler { AutomaticDecompression = System.Net.DecompressionMethods.All })
            {
                Timeout = Timeout.InfiniteTimeSpan
            };
            client.DefaultRequestHeaders.UserAgent.ParseAdd("DynamicWallpaperStudio/1.0.5");

            var mpvArchive = Path.Combine(temporaryRoot, "mpv.zip");
            var ffmpegArchive = Path.Combine(temporaryRoot, "ffmpeg.zip");

            await DownloadAndVerifyAsync(client, Mpv, mpvArchive, 0.00, 0.36, progress, cancellationToken)
                .ConfigureAwait(false);
            await DownloadAndVerifyAsync(client, Ffmpeg, ffmpegArchive, 0.36, 0.52, progress, cancellationToken)
                .ConfigureAwait(false);

            progress?.Report(new("正在安全解压视频组件…", 0.89));
            await ExtractSelectedFilesAsync(mpvArchive, Mpv.Files, extractedRoot, cancellationToken).ConfigureAwait(false);
            await ExtractSelectedFilesAsync(ffmpegArchive, Ffmpeg.Files, extractedRoot, cancellationToken).ConfigureAwait(false);

            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(new("正在完成安装…", 0.96));
            Directory.CreateDirectory(ToolsDirectory);
            foreach (var name in RequiredFiles)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var source = Path.Combine(extractedRoot, name);
                if (!File.Exists(source) || new FileInfo(source).Length == 0)
                    throw new InvalidDataException($"经过校验的压缩包中缺少 {name}。");

                var staged = Path.Combine(ToolsDirectory, $".{name}.{Guid.NewGuid():N}.tmp");
                try
                {
                    await CopyFileAsync(source, staged, cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    File.Move(staged, Path.Combine(ToolsDirectory, name), true);
                }
                finally { TryDeleteFile(staged); }
            }

            cancellationToken.ThrowIfCancellationRequested();
            var stamp = JsonSerializer.Serialize(new
            {
                bundleId = BundleId,
                installedAtUtc = DateTimeOffset.UtcNow,
                archives = new Dictionary<string, string>
                {
                    [Mpv.Name] = Mpv.Sha256,
                    [Ffmpeg.Name] = Ffmpeg.Sha256
                }
            }, new JsonSerializerOptions { WriteIndented = true });
            var stampPath = Path.Combine(ToolsDirectory, StampFileName);
            var temporaryStamp = stampPath + ".tmp";
            File.WriteAllText(temporaryStamp, stamp);
            File.Move(temporaryStamp, stampPath, true);

            if (!IsInstalled) throw new InvalidOperationException("组件文件写入后未能通过完整性状态检查。");
            progress?.Report(new("视频组件安装完成", 1.0));
            DiagnosticsLog.Write("首次运行视频组件安装完成", detail: $"Bundle={BundleId}; Directory={ToolsDirectory}");
        }
        finally
        {
            TryDeleteDirectory(temporaryRoot);
        }
    }

    private static async Task DownloadAndVerifyAsync(
        HttpClient client,
        DependencyArchive archive,
        string destination,
        double progressStart,
        double progressWeight,
        IProgress<DependencyInstallProgress>? progress,
        CancellationToken cancellationToken)
    {
        progress?.Report(new($"正在下载 {archive.Name}…", progressStart));
        using var response = await client.GetAsync(archive.Uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var announcedLength = response.Content.Headers.ContentLength;
        if (announcedLength is > MaximumArchiveBytes)
            throw new InvalidDataException($"{archive.Name} 下载大小异常，已拒绝接收。");

        await using (var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
        await using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024,
                         FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            var buffer = new byte[1024 * 1024];
            long received = 0;
            while (true)
            {
                var count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (count == 0) break;
                received += count;
                if (received > MaximumArchiveBytes)
                    throw new InvalidDataException($"{archive.Name} 下载超过安全大小限制。");
                await output.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                if (announcedLength is > 0)
                    progress?.Report(new($"正在下载 {archive.Name}… {received * 100d / announcedLength:0}%",
                        progressStart + progressWeight * Math.Clamp(received / (double)announcedLength, 0, 1)));
            }
        }

        progress?.Report(new($"正在校验 {archive.Name}…", progressStart + progressWeight));
        await using var file = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var actualHash = Convert.ToHexString(await SHA256.HashDataAsync(file, cancellationToken).ConfigureAwait(false)).ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(
                Convert.FromHexString(actualHash), Convert.FromHexString(archive.Sha256)))
            throw new InvalidDataException($"{archive.Name} 的 SHA-256 不匹配。文件已丢弃，请检查网络后重试。");
    }

    private static async Task ExtractSelectedFilesAsync(
        string archivePath,
        IReadOnlyCollection<string> requiredFiles,
        string destination,
        CancellationToken cancellationToken)
    {
        using var archive = ZipFile.OpenRead(archivePath);
        foreach (var requiredFile in requiredFiles)
        {
            var matches = archive.Entries.Where(entry =>
                !string.IsNullOrEmpty(entry.Name) &&
                string.Equals(entry.Name, requiredFile, StringComparison.OrdinalIgnoreCase)).ToList();
            if (matches.Count != 1)
                throw new InvalidDataException($"压缩包中应该恰好包含一个 {requiredFile}，实际找到 {matches.Count} 个。");
            var entry = matches[0];
            if (entry.Length <= 0 || entry.Length > MaximumExtractedFileBytes)
                throw new InvalidDataException($"{requiredFile} 解压大小异常。");

            await using var input = entry.Open();
            await using var output = new FileStream(Path.Combine(destination, requiredFile), FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            await input.CopyToAsync(output, 1024 * 1024, cancellationToken).ConfigureAwait(false);
        }
    }

    private static void EnsureInstallDirectoryIsWritable()
    {
        try
        {
            Directory.CreateDirectory(ToolsDirectory);
            var probe = Path.Combine(ToolsDirectory, $".write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException)
        {
            throw new InvalidOperationException(
                "软件所在文件夹不可写。请先把整个便携版解压到桌面、文档或其他普通文件夹，再重新运行。", error);
        }
    }

    private static void EnsureFreeDiskSpace(params string[] paths)
    {
        foreach (var root in paths.Select(Path.GetPathRoot)
                     .Where(root => !string.IsNullOrWhiteSpace(root))
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                var drive = new DriveInfo(root!);
                if (drive.IsReady && drive.AvailableFreeSpace < MinimumFreeSpaceBytes)
                    throw new InvalidOperationException(
                        $"磁盘 {drive.Name} 可用空间不足。首次准备至少需要约 1.5 GB 可用空间，建议先预留 2 GB 后重试。");
            }
            catch (ArgumentException)
            {
                // Some writable UNC/network locations cannot be represented by
                // DriveInfo. The normal I/O error remains the fallback there.
            }
        }
    }

    private static async Task CopyFileAsync(string source, string destination, CancellationToken cancellationToken)
    {
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await input.CopyToAsync(output, 1024 * 1024, cancellationToken).ConfigureAwait(false);
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void TryDeleteDirectory(string path)
    {
        try { if (Directory.Exists(path)) Directory.Delete(path, true); } catch { }
    }

    private sealed record DependencyArchive(string Name, string Uri, string Sha256, string[] Files);
}
