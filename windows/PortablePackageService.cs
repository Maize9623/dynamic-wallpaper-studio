using System.IO.Compression;
using System.Text.Json;

namespace DynamicWallpaperStudio;

public sealed class PortablePackageService
{
    private const int MaximumEntries = 64;
    private const long MaximumManifestBytes = 1024 * 1024;
    private const long MaximumEntryBytes = 20L * 1024 * 1024 * 1024;
    private const long MaximumTotalBytes = 21L * 1024 * 1024 * 1024;
    private const long FreeSpaceReserveBytes = 512L * 1024 * 1024;
    private const long CompressionRatioCheckThreshold = 64L * 1024 * 1024;
    private const long MaximumCompressionRatio = 200;

    private readonly JsonSerializerOptions _json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public async Task ExportAsync(WallpaperItem item, string videoPath, string posterPath, string destinationZip, CancellationToken cancellationToken = default)
    {
        var packageName = Sanitize(item.Name) + ".dwallpaper";
        var temporaryZip = destinationZip + $".tmp-{Guid.NewGuid():N}";
        try
        {
            var extension = Path.GetExtension(videoPath).ToLowerInvariant();
            if (extension is not ".mp4" and not ".mov" and not ".m4v") extension = ".mp4";
            var videoName = "wallpaper" + extension;
            var posterName = "poster.jpg";
            var manifest = new PortableManifest
            {
                Name = item.Name,
                VideoFilename = videoName,
                PosterFilename = posterName,
                SourceWidth = item.SourceWidth,
                SourceHeight = item.SourceHeight,
                OutputWidth = item.OutputWidth,
                OutputHeight = item.OutputHeight,
                Duration = item.Duration,
                Fps = item.Fps,
                Codec = item.Codec,
                PreferredAspectMode = item.AspectMode == AspectMode.Fill ? "fill" : "fit"
            };
            await using (var output = new FileStream(temporaryZip, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1024 * 1024,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            using (var archive = new ZipArchive(output, ZipArchiveMode.Create, false))
            {
                await AddFileAsync(archive, videoPath, $"{packageName}/{videoName}", cancellationToken);
                if (File.Exists(posterPath)) await AddFileAsync(archive, posterPath, $"{packageName}/{posterName}", cancellationToken);
                var manifestEntry = archive.CreateEntry($"{packageName}/manifest.json", CompressionLevel.Fastest);
                await using var manifestOutput = manifestEntry.Open();
                await JsonSerializer.SerializeAsync(manifestOutput, manifest, _json, cancellationToken);
            }
            File.Move(temporaryZip, destinationZip, true);
        }
        finally
        {
            try { if (File.Exists(temporaryZip)) File.Delete(temporaryZip); } catch { }
        }
    }

    public async Task<(PortableManifest Manifest, string Video, string? Poster, string TemporaryRoot)> ExtractAsync(string packagePath, CancellationToken cancellationToken = default)
    {
        var temporary = Path.Combine(Path.GetTempPath(), $"dwallpaper-import-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporary);
        try
        {
            string root;
            if (Directory.Exists(packagePath))
            {
                root = packagePath;
            }
            else
            {
                using var archive = ZipFile.OpenRead(packagePath);
                var totalBytes = ValidateArchive(archive, temporary, cancellationToken);
                EnsureFreeSpace(temporary, totalBytes);

                foreach (var entry in archive.Entries)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var destination = SafeArchiveDestination(temporary, entry.FullName);
                    if (string.IsNullOrEmpty(entry.Name)) Directory.CreateDirectory(destination);
                    else
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                        await using var input = entry.Open();
                        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024,
                            FileOptions.Asynchronous | FileOptions.SequentialScan);
                        await input.CopyToAsync(output, cancellationToken);
                    }
                }
                root = temporary;
            }

            var manifestPath = FindManifest(root);
            if (new FileInfo(manifestPath).Length > MaximumManifestBytes)
                throw new InvalidDataException("壁纸包的 manifest.json 过大。");

            await using var manifestStream = new FileStream(manifestPath, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var manifest = await JsonSerializer.DeserializeAsync<PortableManifest>(manifestStream,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }, cancellationToken)
                ?? throw new InvalidDataException("无法读取壁纸包信息。");
            if (manifest.FormatVersion != 1)
                throw new InvalidDataException("不支持这个壁纸包版本。");

            var packageDirectory = Path.GetDirectoryName(manifestPath)!;
            var video = SafeLeafFile(packageDirectory, manifest.VideoFilename);
            if (!File.Exists(video)) throw new FileNotFoundException("壁纸包中缺少视频。", video);
            var extension = Path.GetExtension(video).ToLowerInvariant();
            if (extension is not ".mp4" and not ".mov" and not ".m4v")
                throw new InvalidDataException("壁纸包中的视频格式不受支持。");

            var poster = SafeLeafFile(packageDirectory, manifest.PosterFilename);
            return (manifest, video, File.Exists(poster) ? poster : null, temporary);
        }
        catch
        {
            try { Directory.Delete(temporary, true); } catch { }
            throw;
        }
    }

    private static async Task AddFileAsync(ZipArchive archive, string source, string entryName, CancellationToken token)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.NoCompression);
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = entry.Open();
        await input.CopyToAsync(output, token);
    }

    private static long ValidateArchive(ZipArchive archive, string destinationRoot, CancellationToken cancellationToken)
    {
        if (archive.Entries.Count is 0 or > MaximumEntries)
            throw new InvalidDataException("壁纸包的文件数量异常。");

        long totalBytes = 0;
        foreach (var entry in archive.Entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _ = SafeArchiveDestination(destinationRoot, entry.FullName);

            var unixFileType = (entry.ExternalAttributes >> 16) & 0xF000;
            var windowsAttributes = (FileAttributes)(entry.ExternalAttributes & 0xFFFF);
            if (unixFileType == 0xA000 || windowsAttributes.HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidDataException("壁纸包包含不支持的链接文件。");

            if (entry.Length < 0 || entry.Length > MaximumEntryBytes || totalBytes > MaximumTotalBytes - entry.Length)
                throw new InvalidDataException("壁纸包解压后的文件大小异常，已停止导入。");
            totalBytes += entry.Length;

            if (entry.Name.Equals("manifest.json", StringComparison.OrdinalIgnoreCase) && entry.Length > MaximumManifestBytes)
                throw new InvalidDataException("壁纸包的 manifest.json 过大。");
            if (entry.Length >= CompressionRatioCheckThreshold &&
                (entry.CompressedLength == 0 || entry.Length / entry.CompressedLength > MaximumCompressionRatio))
                throw new InvalidDataException("壁纸包的压缩比例异常，已停止导入。");
        }
        return totalBytes;
    }

    private static void EnsureFreeSpace(string path, long requiredBytes)
    {
        var root = Path.GetPathRoot(Path.GetFullPath(path));
        if (string.IsNullOrWhiteSpace(root))
            throw new InvalidDataException("无法确认临时目录所在磁盘。");

        var availableBytes = new DriveInfo(root).AvailableFreeSpace;
        if (availableBytes < requiredBytes || availableBytes - requiredBytes < FreeSpaceReserveBytes)
            throw new IOException("磁盘可用空间不足，无法安全解压壁纸包。");
    }

    private static string SafeArchiveDestination(string root, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) || relative.Contains('\0'))
            throw new InvalidDataException("壁纸包包含不安全的路径。");

        string full;
        try
        {
            full = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        }
        catch (Exception exception) when (exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new InvalidDataException("壁纸包包含无效路径。", exception);
        }

        var prefix = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("壁纸包包含不安全的路径。");
        return full;
    }

    private static string FindManifest(string root)
    {
        var rootFull = Path.GetFullPath(root);
        if (!Directory.Exists(rootFull))
            throw new DirectoryNotFoundException("壁纸包目录不存在。");
        if (File.GetAttributes(rootFull).HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidDataException("壁纸包目录不能是链接。");

        var candidates = new List<string>();
        var direct = Path.Combine(rootFull, "manifest.json");
        if (File.Exists(direct)) candidates.Add(direct);

        foreach (var directory in Directory.EnumerateDirectories(rootFull, "*", SearchOption.TopDirectoryOnly))
        {
            if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidDataException("壁纸包包含不支持的链接目录。");
            var nested = Path.Combine(directory, "manifest.json");
            if (File.Exists(nested)) candidates.Add(nested);
        }

        return candidates.Count switch
        {
            1 => candidates[0],
            0 => throw new InvalidDataException("壁纸包中缺少 manifest.json。"),
            _ => throw new InvalidDataException("壁纸包中包含多个 manifest.json。")
        };
    }

    private static string SafeLeafFile(string root, string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative) ||
            !string.Equals(relative, Path.GetFileName(relative), StringComparison.Ordinal) ||
            relative is "." or ".." || relative.Contains('\0'))
            throw new InvalidDataException("壁纸包使用了不安全的文件名。");

        var full = SafeArchiveDestination(root, relative);
        if (File.Exists(full))
        {
            var attributes = File.GetAttributes(full);
            if (attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidDataException("壁纸包引用了不支持的文件类型。");
        }
        return full;
    }

    private static string Sanitize(string value)
    {
        foreach (var character in Path.GetInvalidFileNameChars()) value = value.Replace(character, '_');
        value = value.Trim();
        return string.IsNullOrWhiteSpace(value) ? "动态壁纸" : value;
    }
}
