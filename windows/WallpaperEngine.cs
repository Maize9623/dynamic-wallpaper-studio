using Microsoft.Win32;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

public sealed class WallpaperEngine : IDisposable
{
    private readonly LibraryStore _store;
    private readonly DispatcherTimer _repairTimer;
    private readonly Dispatcher _dispatcher;
    private readonly List<NativeWallpaperPlayer> _windows = [];
    private LibraryState? _state;
    private bool _pausedBySystem;
    private bool _failing;
    private int _reattachFailures;
    public bool IsPaused { get; private set; }

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

    public void Apply(LibraryState state)
    {
        _state = state;
        CloseWindows();
        if (!state.Settings.WallpaperEnabled) return;
        var staged = new List<NativeWallpaperPlayer>();
        try
        {
            foreach (var screen in Forms.Screen.AllScreens)
            {
                var assignment = state.Assignments.FirstOrDefault(x => x.DisplayId == screen.DeviceName);
                var id = assignment?.WallpaperId ?? state.DefaultWallpaperId;
                var item = id == null ? null : state.Wallpapers.FirstOrDefault(x => x.Id == id.Value);
                if (item == null) continue;
                var path = _store.ResolveMediaPath(item.PlaybackPath);
                if (!File.Exists(path))
                    throw new FileNotFoundException($"显示器 {screen.DeviceName} 对应的视频文件不存在。", path);
                var mode = assignment?.AspectMode ?? item.AspectMode;
                NativeWallpaperPlayer? player = null;
                try
                {
                    player = new NativeWallpaperPlayer(screen, path, mode);
                    player.PlaybackFailed += (_, ex) => _dispatcher.BeginInvoke(() =>
                        HandleFailure("原生视频播放器意外停止，动态壁纸已自动关闭。", ex));
                    player.Prepare();
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

            // All displays remain alpha=0 until every player has opened a video and
            // passed its parent/style/Z-order checks. This avoids a partial multi-screen commit.
            foreach (var player in staged)
            {
                if (!player.Reveal())
                {
                    foreach (var rollback in staged) rollback.HidePresentation();
                    throw new InvalidOperationException("原生播放器首帧完成后无法安全显示在桌面层。");
                }
            }
            _windows.AddRange(staged);
            if (IsPaused) foreach (var player in _windows) player.PausePlayback();
        }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("创建原生动态壁纸失败", ex);
            foreach (var player in staged)
            {
                try { player.StopPlayback(); } catch { }
                try { player.Dispose(); } catch { }
            }
            throw;
        }
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
    }

    public void Resume()
    {
        IsPaused = false;
        foreach (var window in _windows) window.ResumePlayback();
    }

    private void ReattachAll()
    {
        try
        {
            if (_windows.Any(x => !x.IsAlive))
            {
                if (_state != null) Apply(_state);
                return;
            }
            var failedThisCycle = false;
            foreach (var window in _windows)
                if (!window.IsAttachedToDesktop && !window.AttachToDesktop()) failedThisCycle = true;
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
                Resume();
            }
        });
    }

    private void CloseWindows()
    {
        foreach (var window in _windows.ToList())
        {
            try { window.StopPlayback(); } catch (Exception ex) { DiagnosticsLog.Write("停止壁纸播放失败", ex); }
            try { window.Dispose(); } catch (Exception ex) { DiagnosticsLog.Write("释放原生壁纸播放器失败", ex); }
        }
        _windows.Clear();
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
