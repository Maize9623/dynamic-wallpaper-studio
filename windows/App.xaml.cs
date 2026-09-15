using System.Threading;
using System.Windows;
using System.Windows.Forms;

namespace DynamicWallpaperStudio;

public partial class App : System.Windows.Application
{
    private Mutex? _mutex;
    private bool _ownsMutex;
    private MainWindow? _mainWindow;
    private NotifyIcon? _tray;
    private AppController? _controller;
    private StartupGuard? _startupGuard;
    private bool _startupFailed;
    private bool _handlingCrash;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
        DiagnosticsLog.Write("应用启动", detail: $"Args: {string.Join(' ', e.Args)}");
        _mutex = new Mutex(true, @"Local\Baiyaoyu.DynamicWallpaperStudio", out var createdNew);
        _ownsMutex = createdNew;
        if (!createdNew)
        {
            System.Windows.MessageBox.Show("动态壁纸工作室已经在运行。请从任务栏通知区域打开它。", "动态壁纸工作室");
            Shutdown();
            return;
        }

        _startupGuard = new StartupGuard();
        DiagnosticsLog.Write("已取得单实例锁", detail: $"PreviousStartFailed={_startupGuard.PreviousStartFailed}");

        try
        {
            _startupGuard.UpdatePhase("initializing-controller");
            _controller = new AppController();
            var requestedSafeMode = e.Args.Any(x => string.Equals(x, "--safe-mode", StringComparison.OrdinalIgnoreCase));
            var safeMode = requestedSafeMode || _startupGuard.PreviousStartFailed;
            await _controller.InitializeAsync(safeMode);
            _controller.EnsureLaunchPathCurrent();
            _startupGuard.UpdatePhase("creating-main-window");
            _mainWindow = new MainWindow(_controller);
            MainWindow = _mainWindow;
            var trayReady = TryCreateTrayIcon();

            var background = e.Args.Any(x => string.Equals(x, "--background", StringComparison.OrdinalIgnoreCase));
            if (!background || !trayReady || safeMode) ShowMainWindow();

            if (safeMode)
            {
                System.Windows.MessageBox.Show(_mainWindow,
                    _startupGuard.PreviousStartFailed
                        ? "检测到上一次启动没有正常完成，本次已进入安全模式。动态壁纸没有自动启动，你的收藏和视频都保留着。"
                        : "已进入安全模式。动态壁纸没有启动，你可以先打开设置或查看日志。",
                    "动态壁纸工作室 · 安全模式", MessageBoxButton.OK, MessageBoxImage.Information);
            }

            _startupGuard.UpdatePhase("main-window-ready");
            _startupGuard.StartHealthyTimer();

            foreach (var path in e.Args.Where(File.Exists))
                _controller.QueueImport(path, _mainWindow);
        }
        catch (Exception ex)
        {
            _startupFailed = true;
            _startupGuard?.MarkCrash("startup-exception");
            DiagnosticsLog.Write("应用启动失败", ex);
            _controller?.EmergencyStop();
            System.Windows.MessageBox.Show($"应用启动失败：\n\n{ex.Message}\n\n日志：{DiagnosticsLog.LatestLogPath}", "动态壁纸工作室", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
        }
    }

    private bool TryCreateTrayIcon()
    {
        try
        {
            var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
            _tray = new NotifyIcon
            {
                Text = "动态壁纸工作室",
                Visible = true,
                Icon = File.Exists(iconPath) ? new System.Drawing.Icon(iconPath) : System.Drawing.SystemIcons.Application
            };
            _tray.DoubleClick += (_, _) => ShowMainWindow();
            RebuildTrayMenu();
            if (_controller != null) _controller.StateChanged += RebuildTrayMenu;
            return true;
        }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("创建通知区域图标失败", ex);
            return false;
        }
    }

    private void RebuildTrayMenu()
    {
        if (_tray == null || _controller == null) return;
        var menu = new ContextMenuStrip();
        var current = _controller.CurrentWallpaper;
        menu.Items.Add(new ToolStripMenuItem(current == null ? "没有正在播放的壁纸" : current.Name) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_controller.IsPaused ? "继续播放" : "暂停动态壁纸", null, (_, _) => _controller.TogglePause());
        menu.Items.Add("上一张收藏", null, (_, _) => _controller.SwitchFavorite(-1));
        menu.Items.Add("下一张收藏", null, (_, _) => _controller.SwitchFavorite(1));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("打开动态壁纸工作室", null, (_, _) => ShowMainWindow());
        menu.Items.Add("退出", null, (_, _) => ExitApplication());
        _tray.ContextMenuStrip = menu;
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;
        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized) _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private void ExitApplication()
    {
        _mainWindow?.AllowApplicationClose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { _tray?.Dispose(); } catch (Exception ex) { DiagnosticsLog.Write("退出时释放托盘失败", ex); }
        try { _controller?.Dispose(); } catch (Exception ex) { DiagnosticsLog.Write("退出时释放控制器失败", ex); }
        try { if (_ownsMutex) _mutex?.ReleaseMutex(); } catch (Exception ex) { DiagnosticsLog.Write("退出时释放单实例锁失败", ex); }
        try { _mutex?.Dispose(); } catch { }
        try { if (!_startupFailed) _startupGuard?.MarkCleanExit(); } catch { }
        try { _startupGuard?.Dispose(); } catch { }
        DispatcherUnhandledException -= OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException -= OnDomainUnhandledException;
        TaskScheduler.UnobservedTaskException -= OnUnobservedTaskException;
        base.OnExit(e);
    }

    private void OnDispatcherUnhandledException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
    {
        DiagnosticsLog.Write("UI 未处理异常", e.Exception);
        _controller?.EmergencyStop();
        e.Handled = true;
        if (_handlingCrash) return;
        _handlingCrash = true;
        try
        {
            ShowMainWindow();
            System.Windows.MessageBox.Show(_mainWindow,
                $"动态壁纸已为安全起见停止。\n\n{e.Exception.Message}\n\n请把日志发给我：\n{DiagnosticsLog.LatestLogPath}",
                "动态壁纸已安全停止", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally { _handlingCrash = false; }
    }

    private void OnDomainUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        _startupFailed = true;
        _startupGuard?.MarkCrash("domain-exception");
        DiagnosticsLog.Write("进程未处理异常", e.ExceptionObject as Exception, e.ExceptionObject?.ToString());
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        DiagnosticsLog.Write("后台任务未观察异常", e.Exception);
        e.SetObserved();
    }
}
