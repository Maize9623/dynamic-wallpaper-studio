using System.Diagnostics;
using System.Windows;
using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

public sealed class AppController : IDisposable
{
    private readonly LibraryStore _store = new();
    private readonly FfmpegService _ffmpeg = new();
    private readonly PortablePackageService _packages = new();
    private WallpaperEngine? _engine;
    private bool _safeMode;
    private CancellationTokenSource? _importCancellation;
    private readonly Queue<(string Path, Window? Owner)> _importQueue = new();
    private bool _isProcessingQueue;

    public LibraryState State { get; private set; }
    public IReadOnlyList<DisplayInfo> Displays => WallpaperEngine.EnumerateDisplays();
    public string LibraryPath => _store.RootPath;
    public long LibrarySize => _store.LibrarySize();
    public bool IsPaused => _engine?.IsPaused == true;
    public bool IsWallpaperEnabled => !_safeMode && State.Settings.WallpaperEnabled && _engine != null;
    public bool IsSafeMode => _safeMode;
    public string DiagnosticsPath => DiagnosticsLog.LatestLogPath;
    public WallpaperItem? CurrentWallpaper => State.DefaultWallpaperId is { } id ? State.Wallpapers.FirstOrDefault(x => x.Id == id) : null;
    public event Action? StateChanged;
    public event Action? DisplaysChanged;
    public event Action<string, double>? ProgressChanged;
    public event Action<bool>? BusyChanged;
    public event Action<string>? WallpaperFailed;

    public AppController()
    {
        State = _store.Load();
    }

    public async Task InitializeAsync(bool safeMode = false)
    {
        _safeMode = safeMode;
        try
        {
            var launchCommand = LaunchAtLogin.CurrentCommand;
            State.Settings.StartWithWindows = !string.IsNullOrWhiteSpace(launchCommand);
        }
        catch (Exception ex) { DiagnosticsLog.Write("读取开机启动设置失败", ex); }
        try { _store.CleanupOrphanedMedia(State); }
        catch (Exception ex) { DiagnosticsLog.Write("清理资料库失败", ex); }
        try { await BootstrapStarterAsync(); }
        catch (Exception ex) { DiagnosticsLog.Write("初始化示例壁纸失败", ex); }
        State.Settings.WallpaperEnabled = false;
        _store.Save(State);
    }

    private async Task BootstrapStarterAsync()
    {
        var starterVideo = Path.Combine(AppContext.BaseDirectory, "Samples", "StarterWallpaper.mp4");
        var starterPoster = Path.Combine(AppContext.BaseDirectory, "Samples", "StarterPoster.jpg");
        var existingStarter = State.Wallpapers.FirstOrDefault(x => x.SourceFingerprint.StartsWith("starter:", StringComparison.Ordinal));
        if (existingStarter != null)
        {
            existingStarter.SourcePath = starterVideo;
            existingStarter.PlaybackPath = starterVideo;
            existingStarter.PosterPath = starterPoster;
            return;
        }
        if (State.Wallpapers.Count != 0 || !File.Exists(starterVideo)) return;
        var metadata = await _ffmpeg.AnalyzeAsync(starterVideo);
        var item = new WallpaperItem
        {
            Id = Guid.NewGuid(), Name = "三幕竖屏壁纸 · 1080p", CreatedAt = DateTime.UtcNow, LastUsedAt = DateTime.UtcNow,
            IsFavorite = true, SourcePath = starterVideo, PlaybackPath = starterVideo, PosterPath = starterPoster,
            IsManagedVideo = false, SourceWidth = metadata.Width, SourceHeight = metadata.Height,
            OutputWidth = metadata.Width, OutputHeight = metadata.Height, Duration = metadata.Duration, Fps = metadata.Fps,
            Codec = metadata.Codec, FileSize = metadata.FileSize, SourceFingerprint = "starter:" + metadata.Fingerprint,
            AspectMode = AspectMode.Fit
        };
        State.Wallpapers.Add(item);
        State.DefaultWallpaperId = item.Id;
    }

    public void QueueImport(string path, Window? owner)
    {
        _importQueue.Enqueue((path, owner));
        _ = ProcessImportQueueAsync();
    }

    private async Task ProcessImportQueueAsync()
    {
        if (_isProcessingQueue) return;
        _isProcessingQueue = true;
        try
        {
            while (_importQueue.Count > 0)
            {
                var next = _importQueue.Dequeue();
                await ProcessImportAsync(next.Path, next.Owner);
            }
        }
        finally { _isProcessingQueue = false; }
    }

    private async Task ProcessImportAsync(string path, Window? owner)
    {
        try
        {
            _importCancellation = new CancellationTokenSource();
            var token = _importCancellation.Token;
            if (Directory.Exists(path) && path.EndsWith(".dwallpaper", StringComparison.OrdinalIgnoreCase) ||
                File.Exists(path) && path.EndsWith(".dwallpaper.zip", StringComparison.OrdinalIgnoreCase))
            {
                await ImportPackageAsync(path, owner, token);
                return;
            }
            if (!File.Exists(path)) return;
            BusyChanged?.Invoke(true);
            ProgressChanged?.Invoke("正在读取视频", 0.05);
            var metadata = await _ffmpeg.AnalyzeAsync(path, token);
            var duplicate = State.Wallpapers.FirstOrDefault(x => x.SourceFingerprint == metadata.Fingerprint);
            if (duplicate != null)
            {
                if (!duplicate.IsManagedVideo && !File.Exists(_store.ResolveMediaPath(duplicate.PlaybackPath)))
                {
                    duplicate.SourcePath = path;
                    duplicate.PlaybackPath = path;
                    SaveAndNotify();
                    if (IsWallpaperEnabled) _engine?.Apply(State);
                    System.Windows.MessageBox.Show(owner, $"已重新连接原视频：\n\n{duplicate.Name}", "视频已恢复", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }
                System.Windows.MessageBox.Show(owner, $"这个视频已经在资料库中：\n\n{duplicate.Name}", "重复的视频", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            BusyChanged?.Invoke(false);
            var dialog = new ImportDialog(metadata, Displays) { Owner = owner };
            if (dialog.ShowDialog() != true || dialog.Options == null) return;
            if (dialog.Options.Resolution == ResolutionChoice.OriginalReference &&
                (!string.Equals(metadata.Codec, "h264", StringComparison.OrdinalIgnoreCase) ||
                 !string.Equals(Path.GetExtension(metadata.Path), ".mp4", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException("这个视频不是 Windows 可稳定直接播放的 H.264 MP4。请选择 1080p、2K、4K、匹配显示器或自定义分辨率，让应用先转换为兼容格式。");
            await CreateWallpaperAsync(metadata, dialog.Options, token);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { System.Windows.MessageBox.Show(owner, $"无法导入：\n\n{ex.Message}", "动态壁纸工作室", MessageBoxButton.OK, MessageBoxImage.Error); }
        finally
        {
            BusyChanged?.Invoke(false);
            _importCancellation?.Dispose();
            _importCancellation = null;
        }
    }

    public void CancelImport() => _importCancellation?.Cancel();

    private async Task CreateWallpaperAsync(VideoMetadata metadata, ImportOptions options, CancellationToken token)
    {
        BusyChanged?.Invoke(true);
        var id = Guid.NewGuid();
        var staging = Path.Combine(_store.StagingPath, id.ToString("N"));
        var final = _store.MediaDirectory(id);
        Directory.CreateDirectory(staging);
        try
        {
            ProgressChanged?.Invoke("正在生成封面", 0.12);
            var poster = Path.Combine(staging, "poster.jpg");
            await _ffmpeg.MakePosterAsync(metadata.Path, poster, token);

            var (width, height) = ResolveDimensions(metadata, options);
            string playback;
            var managed = options.Resolution != ResolutionChoice.OriginalReference;
            if (managed)
            {
                playback = Path.Combine(staging, "wallpaper.mp4");
                var progress = new Progress<double>(value => ProgressChanged?.Invoke("正在转换视频", 0.18 + value * 0.74));
                await _ffmpeg.TranscodeAsync(metadata.Path, playback, width, height, options.AspectMode, metadata.Duration, progress, token);
            }
            else playback = metadata.Path;

            token.ThrowIfCancellationRequested();
            ProgressChanged?.Invoke("正在加入资料库", 0.95);
            Directory.Move(staging, final);
            var finalPoster = Path.Combine(final, "poster.jpg");
            var finalPlayback = managed ? Path.Combine(final, "wallpaper.mp4") : playback;
            var item = new WallpaperItem
            {
                Id = id,
                Name = string.IsNullOrWhiteSpace(options.Name) ? Path.GetFileNameWithoutExtension(metadata.Path) : options.Name.Trim(),
                CreatedAt = DateTime.UtcNow,
                LastUsedAt = options.ApplyAfterImport ? DateTime.UtcNow : null,
                IsFavorite = options.Favorite,
                SourcePath = metadata.Path,
                PlaybackPath = managed ? _store.RelativeToRoot(finalPlayback) : finalPlayback,
                PosterPath = _store.RelativeToRoot(finalPoster),
                IsManagedVideo = managed,
                SourceWidth = metadata.Width,
                SourceHeight = metadata.Height,
                OutputWidth = width,
                OutputHeight = height,
                Duration = metadata.Duration,
                Fps = managed ? Math.Min(metadata.Fps, 30) : metadata.Fps,
                Codec = managed ? "H.264" : metadata.Codec,
                FileSize = new FileInfo(finalPlayback).Length,
                SourceFingerprint = metadata.Fingerprint,
                AspectMode = options.AspectMode
            };
            State.Wallpapers.Insert(0, item);
            if (options.ApplyAfterImport) SetWallpaper(item, options.TargetDisplayId, options.AspectMode, false);
            SaveAndNotify();
            ProgressChanged?.Invoke("制作完成", 1);
        }
        catch
        {
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { }
            throw;
        }
        finally { BusyChanged?.Invoke(false); }
    }

    private (int Width, int Height) ResolveDimensions(VideoMetadata metadata, ImportOptions options)
    {
        var portrait = metadata.Height >= metadata.Width;
        return options.Resolution switch
        {
            ResolutionChoice.OriginalReference => (metadata.Width, metadata.Height),
            ResolutionChoice.FullHd => portrait ? (1080, 1920) : (1920, 1080),
            ResolutionChoice.TwoK => portrait ? (1440, 2560) : (2560, 1440),
            ResolutionChoice.FourK => portrait ? (2160, 3840) : (3840, 2160),
            ResolutionChoice.MatchDisplay => ResolveDisplayDimensions(options.TargetDisplayId),
            ResolutionChoice.Custom => (options.CustomWidth / 2 * 2, options.CustomHeight / 2 * 2),
            _ => (metadata.Width, metadata.Height)
        };
    }

    private (int Width, int Height) ResolveDisplayDimensions(string id)
    {
        var display = id == "all" ? Displays.FirstOrDefault(x => x.IsPrimary) ?? Displays.First() : Displays.FirstOrDefault(x => x.Id == id) ?? Displays.First();
        return (display.Width / 2 * 2, display.Height / 2 * 2);
    }

    public void SetWallpaper(WallpaperItem item, string targetDisplayId = "all", AspectMode? mode = null, bool save = true)
    {
        item.LastUsedAt = DateTime.UtcNow;
        item.AspectMode = mode ?? item.AspectMode;
        if (targetDisplayId == "all")
        {
            State.DefaultWallpaperId = item.Id;
            State.DefaultAspectMode = item.AspectMode;
            State.Assignments.Clear();
        }
        else
        {
            var assignment = State.Assignments.FirstOrDefault(x => x.DisplayId == targetDisplayId);
            if (assignment == null) State.Assignments.Add(new DisplayAssignment { DisplayId = targetDisplayId, WallpaperId = item.Id, AspectMode = item.AspectMode });
            else { assignment.WallpaperId = item.Id; assignment.AspectMode = item.AspectMode; }
            if (State.DefaultWallpaperId == null) State.DefaultWallpaperId = item.Id;
        }
        if (save) SaveAndNotify(); else _store.Save(State);
        EnableWallpaper();
    }

    public void EnableWallpaper()
    {
        if (_safeMode) throw new InvalidOperationException("当前处于安全模式。请正常退出并重新启动软件后再启用动态壁纸。");
        if (State.DefaultWallpaperId == null) throw new InvalidOperationException("请先选择一张壁纸。");
        try
        {
            _engine ??= CreateEngine();
            State.Settings.WallpaperEnabled = true;
            _engine.Apply(State);
            _store.Save(State);
            StateChanged?.Invoke();
        }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("启动动态壁纸失败", ex);
            try { _engine?.Stop(); } catch { }
            State.Settings.WallpaperEnabled = false;
            try { _store.Save(State); } catch { }
            StateChanged?.Invoke();
            throw new InvalidOperationException($"无法启动动态壁纸，已经恢复普通桌面。\n\n诊断日志：{DiagnosticsLog.LatestLogPath}", ex);
        }
    }

    public void DisableWallpaper()
    {
        State.Settings.WallpaperEnabled = false;
        _engine?.Stop();
        SaveAndNotify();
    }

    public void EmergencyStop()
    {
        try
        {
            State.Settings.WallpaperEnabled = false;
            _engine?.Stop();
            _store.Save(State);
            StateChanged?.Invoke();
        }
        catch (Exception ex) { DiagnosticsLog.Write("紧急停止壁纸失败", ex); }
    }

    public void ToggleFavorite(WallpaperItem item)
    {
        item.IsFavorite = !item.IsFavorite;
        SaveAndNotify();
    }

    public void Rename(WallpaperItem item, string name)
    {
        if (!string.IsNullOrWhiteSpace(name)) item.Name = name.Trim();
        SaveAndNotify();
    }

    public string? Delete(WallpaperItem item)
    {
        var wasDefault = State.DefaultWallpaperId == item.Id;
        State.Assignments.RemoveAll(x => x.WallpaperId == item.Id);
        State.Wallpapers.Remove(item);
        if (wasDefault) State.DefaultWallpaperId = State.Wallpapers.FirstOrDefault()?.Id;
        _store.Save(State);
        if (IsWallpaperEnabled) _engine?.Apply(State); else _engine?.Stop();
        string? warning = null;
        try { _store.DeleteManagedFiles(item); }
        catch (IOException) { warning = "壁纸已从资料库移除，但 Windows 仍占用旧视频。应用会在下次启动时自动清理它。"; }
        catch (UnauthorizedAccessException) { warning = "壁纸已从资料库移除，但旧文件暂时无法删除。应用会在下次启动时再次清理。"; }
        StateChanged?.Invoke();
        return warning;
    }

    public void TogglePause()
    {
        if (!IsWallpaperEnabled || _engine == null) return;
        if (_engine.IsPaused) _engine.Resume(); else _engine.Pause();
        StateChanged?.Invoke();
    }

    public void SwitchFavorite(int direction)
    {
        var favorites = State.Wallpapers.Where(x => x.IsFavorite && File.Exists(_store.ResolveMediaPath(x.PlaybackPath))).ToList();
        if (favorites.Count == 0) return;
        var current = State.DefaultWallpaperId is { } id ? favorites.FindIndex(x => x.Id == id) : -1;
        var next = (current + direction + favorites.Count) % favorites.Count;
        SetWallpaper(favorites[next]);
    }

    public void SetStartWithWindows(bool enabled)
    {
        LaunchAtLogin.SetEnabled(enabled);
        State.Settings.StartWithWindows = enabled;
        SaveAndNotify();
    }

    public void EnsureLaunchPathCurrent()
    {
        if (!State.Settings.StartWithWindows) return;
        LaunchAtLogin.SetEnabled(true);
    }

    public void RevealLibrary() => Process.Start(new ProcessStartInfo("explorer.exe", _store.RootPath) { UseShellExecute = true });
    public string ResolvePoster(WallpaperItem item) => _store.ResolveMediaPath(item.PosterPath);
    public string ResolvePlayback(WallpaperItem item) => _store.ResolveMediaPath(item.PlaybackPath);

    public async Task ExportAsync(WallpaperItem item, string destination, CancellationToken token = default)
    {
        await _packages.ExportAsync(item, ResolvePlayback(item), ResolvePoster(item), destination, token);
    }

    private async Task ImportPackageAsync(string path, Window? owner, CancellationToken token)
    {
        BusyChanged?.Invoke(true);
        ProgressChanged?.Invoke("正在读取壁纸包", 0.1);
        var extracted = await _packages.ExtractAsync(path, token);
        string? createdDirectory = null;
        try
        {
            var metadata = await _ffmpeg.AnalyzeAsync(extracted.Video, token);
            if (!string.Equals(metadata.Codec, "h264", StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(Path.GetExtension(extracted.Video), ".mp4", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("这个壁纸包不是 Windows 可稳定播放的 H.264 MP4。请先导入原视频并选择一种输出分辨率，让应用转换为兼容格式。");
            if (State.Wallpapers.Any(x => x.SourceFingerprint == metadata.Fingerprint))
            {
                System.Windows.MessageBox.Show(owner, "这张壁纸已经在资料库中。", "重复的壁纸", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            var id = Guid.NewGuid();
            var final = _store.MediaDirectory(id);
            Directory.CreateDirectory(final);
            createdDirectory = final;
            var videoExtension = Path.GetExtension(extracted.Video);
            var videoFinal = Path.Combine(final, "wallpaper" + videoExtension);
            ProgressChanged?.Invoke("正在复制壁纸视频", 0.35);
            await CopyFileAsync(extracted.Video, videoFinal, token);
            var posterFinal = Path.Combine(final, "poster.jpg");
            if (extracted.Poster != null) await CopyFileAsync(extracted.Poster, posterFinal, token);
            else await _ffmpeg.MakePosterAsync(videoFinal, posterFinal, token);
            var item = new WallpaperItem
            {
                Id = id, Name = extracted.Manifest.Name, CreatedAt = DateTime.UtcNow, IsManagedVideo = true,
                SourcePath = "", PlaybackPath = _store.RelativeToRoot(videoFinal), PosterPath = _store.RelativeToRoot(posterFinal),
                SourceWidth = extracted.Manifest.SourceWidth > 0 ? extracted.Manifest.SourceWidth : metadata.Width,
                SourceHeight = extracted.Manifest.SourceHeight > 0 ? extracted.Manifest.SourceHeight : metadata.Height,
                OutputWidth = metadata.Width, OutputHeight = metadata.Height, Duration = metadata.Duration, Fps = metadata.Fps,
                Codec = metadata.Codec, FileSize = metadata.FileSize, SourceFingerprint = metadata.Fingerprint,
                AspectMode = string.Equals(extracted.Manifest.PreferredAspectMode, "fill", StringComparison.OrdinalIgnoreCase) ? AspectMode.Fill : AspectMode.Fit
            };
            State.Wallpapers.Insert(0, item);
            SaveAndNotify();
            createdDirectory = null;
        }
        catch
        {
            try { if (createdDirectory != null && Directory.Exists(createdDirectory)) Directory.Delete(createdDirectory, true); } catch { }
            throw;
        }
        finally
        {
            try { if (Directory.Exists(extracted.TemporaryRoot)) Directory.Delete(extracted.TemporaryRoot, true); } catch { }
            BusyChanged?.Invoke(false);
        }
    }

    private static async Task CopyFileAsync(string source, string destination, CancellationToken token)
    {
        await using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await input.CopyToAsync(output, token);
    }

    private void SaveAndNotify()
    {
        _store.Save(State);
        StateChanged?.Invoke();
    }

    private WallpaperEngine CreateEngine()
    {
        var engine = new WallpaperEngine(_store);
        engine.DisplaysChanged += () => DisplaysChanged?.Invoke();
        engine.Failed += message =>
        {
            EmergencyStop();
            WallpaperFailed?.Invoke(message);
        };
        return engine;
    }

    public void Dispose()
    {
        _importCancellation?.Cancel();
        _engine?.Dispose();
    }
}
