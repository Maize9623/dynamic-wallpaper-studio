using Microsoft.Win32;
using System.Drawing;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

public sealed class WallpaperEngine : IDisposable
{
    private readonly LibraryStore _store;
    private readonly DispatcherTimer _repairTimer;
    private readonly Dispatcher _dispatcher;
    private readonly List<NativeWallpaperPlayer> _windows = [];
    private DesktopLayerHost? _layer;
    private NativeSceneBackdrop? _sceneBackdrop;
    private LibraryState? _state;
    public WebSession? SharedWeb { get; set; }
    private bool _pausedBySystem;
    private bool _failing;
    private int _reattachFailures;
    private bool _contentHidden;
    public bool IsPaused { get; private set; }
    public bool IsContentHidden => _contentHidden;

    public WallpaperEngine(LibraryStore store)
    {
        _store = store;
        _dispatcher = System.Windows.Application.Current.Dispatcher;
        _repairTimer = new DispatcherTimer(DispatcherPriority.Normal, _dispatcher)
            { Interval = TimeSpan.FromSeconds(3) };
        _repairTimer.Tick += (_, _) => ReattachAll();
        _repairTimer.Start();
        SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        SystemEvents.SessionSwitch += SessionSwitch;
        SystemEvents.PowerModeChanged += PowerModeChanged;
    }

    public static IReadOnlyList<DisplayInfo> EnumerateDisplays() => Forms.Screen.AllScreens.Select(screen =>
        new DisplayInfo(screen.DeviceName, screen.DeviceName.Replace("\\\\.\\", ""), screen.Bounds.X, screen.Bounds.Y,
            screen.Bounds.Width, screen.Bounds.Height, screen.Primary)).ToList();
    public IReadOnlyList<DisplayInfo> Displays => EnumerateDisplays();
    public event Action? DisplaysChanged;
    public event Action<string>? Failed;
    public event Action? MediaEnded;

    public void Apply(LibraryState state)
    {
        _state = state;
        CloseWindows();
        if (!state.Settings.WallpaperEnabled) return;
        _contentHidden = state.Settings.BossHidden || state.Settings.TelevisionOff;
        var screen = PrimaryScreen();
        var scene = state.Settings.SceneEnabled;
        var mode = state.Settings.ContentMode;
        var suppressContent = _contentHidden;
        var keepSceneOnly = suppressContent && scene;
        var hideEverything = suppressContent && !scene;

        if (hideEverything) return;

        try
        {
            var sceneReady = false;
            if (scene)
            {
                CreateSceneBackdrop(screen);
                sceneReady = _sceneBackdrop != null;
            }

            if (mode is ContentMode.Reader or ContentMode.Web)
                CreateLayer(
                    screen,
                    scene && _sceneBackdrop == null,
                    mode,
                    suppressContent,
                    state,
                    scene ? SceneLayout.TelevisionBounds(screen.Bounds) : null);

            if (mode == ContentMode.Web && !suppressContent)
                AttachSharedWeb();

            if (mode == ContentMode.Video && !suppressContent)
                CreateVideoPlayers(state, sceneReady);

            if (keepSceneOnly)
            {
                if (_sceneBackdrop == null || !_sceneBackdrop.Reveal())
                    throw new InvalidOperationException("客厅背景无法显示在桌面层。");
                _dispatcher.Invoke(() => _layer?.HideTelevisionContent());
            }
        }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("创建桌面内容层失败", ex);
            CloseWindows();
            throw;
        }

        if (IsPaused) Pause();
    }

    public void Stop()
    {
        _state = null;
        CloseWindows();
    }

    public void Pause()
    {
        IsPaused = true;
        foreach (var window in _windows) window.PausePlayback();
        _dispatcher.Invoke(() => _layer?.Reader.PauseAutoTurn());
        if (SharedWeb != null) _ = SharedWeb.SetPausedAsync(true);
    }

    public void Resume()
    {
        if (_contentHidden) return;
        IsPaused = false;
        foreach (var window in _windows) window.ResumePlayback();
        _dispatcher.Invoke(() => _layer?.Reader.ResumeAutoTurn());
        if (SharedWeb != null) _ = SharedWeb.SetPausedAsync(false);
    }

    public void SetMuted(bool muted)
    {
        foreach (var window in _windows) window.SetMuted(muted);
        if (SharedWeb != null) _ = SharedWeb.SetMutedAsync(muted);
    }

    public void SetVolume(double volume)
    {
        foreach (var window in _windows) window.SetVolume(volume);
        if (SharedWeb != null) _ = SharedWeb.SetVolumeAsync(volume);
    }

    public void SetSpeed(double speed)
    {
        foreach (var window in _windows) window.SetSpeed(speed);
        if (SharedWeb != null) _ = SharedWeb.SetSpeedAsync(speed);
    }

    public void Seek(double seconds)
    {
        foreach (var window in _windows) window.Seek(seconds);
        if (SharedWeb != null) _ = SharedWeb.SeekAsync(seconds);
    }

    public bool TryGetPlayback(out double position, out double duration, out bool paused)
    {
        if (SharedWeb is { PinnedToDesktop: true, LastSnapshot.Ready: true } web)
        {
            position = web.LastSnapshot.Position;
            duration = web.LastSnapshot.Duration;
            paused = web.LastSnapshot.Paused;
            return true;
        }
        foreach (var window in _windows)
            if (window.TryGetPlayback(out position, out duration, out paused))
                return true;
        position = 0;
        duration = 0;
        paused = IsPaused;
        return false;
    }

    public void LoadMedia(string path, bool loopFile)
    {
        if (_windows.Count == 0) throw new InvalidOperationException("当前没有正在运行的视频壁纸。");
        foreach (var window in _windows) window.LoadMedia(path, loopFile);
        ApplyTransport(_state?.Settings);
        if (IsPaused || _contentHidden) foreach (var window in _windows) window.PausePlayback();
    }

    public ReaderSurface? Reader => _layer?.Reader;

    public void AttachSharedWeb()
    {
        var web = SharedWeb;
        if (web == null || !web.PinnedToDesktop || !web.HasHttpDocument) return;
        _dispatcher.Invoke(() =>
        {
            if (_layer == null) return;
            web.Detach();
            _layer.AttachWeb(web.View);
            web.ApplyHostSettings(interactive: false);
        });
        _ = web.ApplyTransportAsync(
            _state?.Settings.AudioMuted ?? true,
            _state?.Settings.Volume ?? 70,
            _state?.Settings.PlaybackSpeed ?? 1);
    }

    public void ReleaseSharedWeb()
    {
        void release() => _layer?.ReleaseWeb();
        if (_dispatcher.CheckAccess()) release();
        else _dispatcher.Invoke(release);
    }

    public void SetContentHidden(bool hidden, bool keepScene)
    {
        _contentHidden = hidden;
        if (_state == null) return;
        if (hidden)
        {
            foreach (var window in _windows)
            {
                window.PausePlayback();
                window.SetMuted(true);
                window.HidePresentation();
            }
            _dispatcher.Invoke(() =>
            {
                if (keepScene)
                {
                    _ = _sceneBackdrop?.Reveal();
                    SharedWeb?.SetMutedAsync(true);
                    if (_layer == null) return;
                    _layer.HideTelevisionContent();
                    _ = _layer.Reveal();
                }
                else
                {
                    _sceneBackdrop?.HidePresentation();
                    SharedWeb?.SetMutedAsync(true);
                    _layer?.HidePresentation();
                }
            });
            return;
        }

        ApplyTransport(_state.Settings);
        foreach (var window in _windows)
        {
            _ = window.Reveal();
            if (!IsPaused) window.ResumePlayback();
        }
        _dispatcher.Invoke(() =>
        {
            if (_state.Settings.SceneEnabled)
                _ = _sceneBackdrop?.Reveal();
            if (_state.Settings.ContentMode == ContentMode.Web)
            {
                AttachSharedWeb();
                _ = SharedWeb?.ApplyTransportAsync(_state.Settings.AudioMuted, _state.Settings.Volume, _state.Settings.PlaybackSpeed);
            }
            if (_layer == null) return;
            _layer.SetScene(_state.Settings.SceneEnabled && _sceneBackdrop == null);
            if (_state.Settings.ContentMode == ContentMode.Video)
                _layer.HideTelevisionContent();
            else
                _layer.ShowTelevisionContent(_state.Settings.ContentMode);
            _ = _layer.Reveal();
        });
    }

    private void CreateVideoPlayers(LibraryState state, bool scene)
    {
        var staged = new List<NativeWallpaperPlayer>();
        try
        {
            foreach (var screen in Forms.Screen.AllScreens)
            {
                if (scene && !screen.Primary) continue;
                var assignment = state.Assignments.FirstOrDefault(x => x.DisplayId == screen.DeviceName);
                var id = assignment?.WallpaperId ?? state.DefaultWallpaperId;
                if (state.Settings.PlaylistMode && state.Settings.Playlist.Count > 0)
                {
                    var index = Math.Clamp(state.Settings.PlaylistIndex, 0, state.Settings.Playlist.Count - 1);
                    id = state.Settings.Playlist[index];
                }
                var item = id == null ? null : state.Wallpapers.FirstOrDefault(x => x.Id == id.Value);
                if (item == null) continue;
                var path = _store.ResolveMediaPath(item.PlaybackPath);
                if (!File.Exists(path))
                    throw new FileNotFoundException($"显示器 {screen.DeviceName} 对应的视频文件不存在。", path);
                var mode = assignment?.AspectMode ?? item.AspectMode;
                var bounds = scene ? SceneLayout.TelevisionBounds(screen.Bounds) : screen.Bounds;
                NativeWallpaperPlayer? player = null;
                try
                {
                    player = new NativeWallpaperPlayer(screen, path, mode, bounds, loopFile: !state.Settings.PlaylistMode);
                    player.PlaybackFailed += (_, ex) => _dispatcher.BeginInvoke(() =>
                        HandleFailure("原生视频播放器意外停止，动态壁纸已自动关闭。", ex));
                    player.MediaEnded += (_, _) => _dispatcher.BeginInvoke(() => MediaEnded?.Invoke());
                    player.Prepare();
                    player.SetMuted(state.Settings.AudioMuted);
                    player.SetVolume(state.Settings.Volume);
                    player.SetSpeed(state.Settings.PlaybackSpeed);
                    staged.Add(player);
                }
                catch
                {
                    try { player?.Dispose(); } catch { }
                    throw;
                }
            }

            if (staged.Count == 0)
                throw new InvalidOperationException("没有任何显示器可以创建动态壁纸播放器。");

            foreach (var player in staged)
            {
                if (!player.Reveal())
                {
                    foreach (var rollback in staged) rollback.HidePresentation();
                    throw new InvalidOperationException("原生播放器首帧完成后无法安全显示在桌面层。");
                }
            }
            _windows.AddRange(staged);
        }
        catch
        {
            foreach (var player in staged)
            {
                try { player.StopPlayback(); } catch { }
                try { player.Dispose(); } catch { }
            }
            throw;
        }
    }

    private void CreateSceneBackdrop(Forms.Screen screen)
    {
        var backdrop = new NativeSceneBackdrop(screen);
        try
        {
            backdrop.Prepare();
            if (!backdrop.Reveal())
                throw new InvalidOperationException("客厅伪装背景无法显示在桌面层。");
            _sceneBackdrop = backdrop;
        }
        catch
        {
            backdrop.Dispose();
            throw;
        }
    }

    private void CreateLayer(
        Forms.Screen screen,
        bool scene,
        ContentMode mode,
        bool suppressContent,
        LibraryState state,
        Rectangle? bounds = null)
    {
        _dispatcher.Invoke(() =>
        {
            _layer = new DesktopLayerHost(screen, bounds);
            _layer.Prepare();
            _layer.SetScene(scene);
            if (suppressContent)
            {
                _layer.HideTelevisionContent();
            }
            else if (mode == ContentMode.Reader)
            {
                _layer.ShowReader();
                BeginLoadReader(state);
            }
            else if (mode == ContentMode.Web)
            {
                _layer.ShowWeb();
            }
            else
            {
                _layer.HideTelevisionContent();
            }

            if (!_layer.Reveal())
                throw new InvalidOperationException("桌面内容层无法安全显示。");
        });
    }

    private void BeginLoadReader(LibraryState state)
    {
        var book = ResolveBook(state);
        if (book == null) throw new InvalidOperationException("还没有可阅读的电子书。请先导入 TXT 或 PDF。");
        var path = _store.ResolveMediaPath(book.SourcePath);
        if (!File.Exists(path)) throw new FileNotFoundException("电子书文件不存在。", path);
        if (book.Kind == BookKind.Pdf)
        {
            _ = _layer!.Reader.LoadPdfAsync(path, book.Position).ContinueWith(task =>
            {
                if (task.IsFaulted)
                    DiagnosticsLog.Write("打开 PDF 失败", task.Exception?.GetBaseException());
            }, TaskScheduler.Default);
        }
        else
            _layer!.Reader.LoadText(TextEncodingDetector.ReadAllText(path), book.Position);
    }

    private static BookItem? ResolveBook(LibraryState state)
    {
        if (state.Settings.ActiveBookId is { } id)
            return state.Books.FirstOrDefault(x => x.Id == id);
        return state.Books.FirstOrDefault();
    }

    private void ApplyTransport(AppSettings? settings)
    {
        if (settings == null) return;
        foreach (var window in _windows)
        {
            window.SetMuted(settings.AudioMuted);
            window.SetVolume(settings.Volume);
            window.SetSpeed(settings.PlaybackSpeed);
            window.SetLoopFile(!settings.PlaylistMode);
        }
    }

    private static Forms.Screen PrimaryScreen()
        => Forms.Screen.PrimaryScreen ?? Forms.Screen.AllScreens[0];

    private void ReattachAll()
    {
        try
        {
            if (_windows.Any(x => !x.IsAlive)
                || (_layer != null && !_layer.IsAlive)
                || (_sceneBackdrop != null && !_sceneBackdrop.IsAlive))
            {
                if (_state != null) Apply(_state);
                return;
            }
            var failedThisCycle = false;
            if (_sceneBackdrop != null && !_sceneBackdrop.IsAttachedToDesktop && !_sceneBackdrop.AttachToDesktop())
                failedThisCycle = true;
            foreach (var window in _windows)
                if (!window.IsAttachedToDesktop && !window.AttachToDesktop()) failedThisCycle = true;
            if (_layer != null && !_layer.IsAttachedToDesktop && !_layer.AttachToDesktop()) failedThisCycle = true;
            _reattachFailures = failedThisCycle ? _reattachFailures + 1 : 0;
            if (_reattachFailures >= 3)
                throw new InvalidOperationException("连续三次无法重新附着到 Windows 桌面层。");
        }
        catch (Exception ex) { HandleFailure("桌面层恢复失败，动态壁纸已自动关闭。", ex); }
    }

    private void DisplaySettingsChanged(object? sender, EventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            try { if (_state != null) Apply(_state); }
            catch (Exception ex) { HandleFailure("显示器变化后无法恢复动态壁纸，已自动关闭。", ex); }
            DisplaysChanged?.Invoke();
        });
    }

    private void SessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (_state?.Settings.PauseWhenSessionLocked != true) return;
        _dispatcher.BeginInvoke(() =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff)
            {
                _pausedBySystem = !IsPaused;
                if (_pausedBySystem) Pause();
            }
            else if ((e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon) && _pausedBySystem)
            {
                _pausedBySystem = false;
                if (_contentHidden) return;
                Resume();
            }
        });
    }

    private void PowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        _dispatcher.BeginInvoke(() =>
        {
            if (e.Mode == PowerModes.Suspend)
            {
                _pausedBySystem = !IsPaused;
                if (_pausedBySystem) Pause();
            }
            else if (e.Mode == PowerModes.Resume && _pausedBySystem)
            {
                _pausedBySystem = false;
                if (_contentHidden) return;
                Resume();
            }
        });
    }

    private void CloseWindows()
    {
        ReleaseSharedWeb();
        foreach (var window in _windows.ToList())
        {
            try { window.StopPlayback(); } catch (Exception ex) { DiagnosticsLog.Write("停止壁纸播放失败", ex); }
            try { window.Dispose(); } catch (Exception ex) { DiagnosticsLog.Write("释放原生壁纸播放器失败", ex); }
        }
        _windows.Clear();
        CloseLayerOnly();
        CloseSceneBackdrop();
    }

    private void CloseSceneBackdrop()
    {
        try { _sceneBackdrop?.Dispose(); }
        catch (Exception ex) { DiagnosticsLog.Write("关闭客厅伪装失败", ex); }
        _sceneBackdrop = null;
    }

    private void CloseLayerOnly()
    {
        _dispatcher.Invoke(() =>
        {
            try { _layer?.CloseSurface(); } catch (Exception ex) { DiagnosticsLog.Write("关闭桌面内容层失败", ex); }
            _layer = null;
        });
    }

    private void HandleFailure(string message, Exception error)
    {
        if (_failing) return;
        _failing = true;
        try
        {
            DiagnosticsLog.Write(message, error);
            CloseWindows();
            Failed?.Invoke(message);
        }
        finally { _failing = false; }
    }

    public void Dispose()
    {
        _repairTimer.Stop();
        SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
        SystemEvents.SessionSwitch -= SessionSwitch;
        SystemEvents.PowerModeChanged -= PowerModeChanged;
        CloseWindows();
    }
}
