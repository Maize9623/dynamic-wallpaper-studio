using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Forms = System.Windows.Forms;

namespace DynamicWallpaperStudio;

/// <summary>
/// Hosts mpv's native D3D11 window in the Explorer wallpaper layer. mpv is
/// deliberately started idle: its HWND is made a transparent layered child and
/// sized first, then the media is loaded over JSON IPC. The window is revealed
/// only after mpv reports a playback restart and its render target is verified.
/// </summary>
public sealed class NativeWallpaperPlayer : IDisposable
{
    private static readonly TimeSpan IpcCommandTimeout = TimeSpan.FromSeconds(2);
    private readonly Forms.Screen _screen;
    private readonly string _mediaPath;
    private readonly AspectMode _aspectMode;
    private readonly string _windowTitle = $"DWPS-{Guid.NewGuid():N}";
    private readonly string _pipeName = $"dwps-mpv-{Guid.NewGuid():N}";
    private readonly ManualResetEventSlim _fileLoaded = new(false);
    private readonly ManualResetEventSlim _playbackRestart = new(false);
    private readonly ManualResetEventSlim _loadFailed = new(false);
    private readonly ManualResetEventSlim _ipcDisconnected = new(false);
    private readonly ManualResetEventSlim _processExited = new(false);
    private readonly CancellationTokenSource _stderrCancellation = new();
    private readonly object _tailGate = new();
    private readonly object _eventGate = new();
    private readonly Queue<string> _stderrTail = new();
    private readonly HashSet<long> _loadedEntries = [];
    private readonly HashSet<long> _restartedEntries = [];
    private readonly Dictionary<long, string> _endedEntries = [];
    private Process? _process;
    private MpvIpcClient? _ipc;
    private IntPtr _handle;
    private Exception? _ipcFailure;
    private string? _loadFailureDetail;
    private bool _prepared;
    private bool _visible;
    private bool _paused;
    private bool _startupPaused = true;
    private bool _armed;
    private bool _reattachHealthy = true;
    private bool _stopping;
    private bool _disposed;
    private readonly bool _useLayeredPresentation = true;
    private int _failureReported;
    private int _observedVoConfigured;
    private int _observedOsdWidth;
    private int _observedOsdHeight;
    private long _activePlaylistEntryId = -1;
    private long _eventPlaylistEntryId = -1;

    public NativeWallpaperPlayer(Forms.Screen screen, string mediaPath, AspectMode aspectMode)
    {
        _screen = screen;
        _mediaPath = mediaPath;
        _aspectMode = aspectMode;
    }

    public event EventHandler<Exception>? PlaybackFailed;

    public bool IsAlive
    {
        get
        {
            try
            {
                return _process is { HasExited: false }
                    && NativeDesktop.IsValidWindow(_handle)
                    && NativeDesktop.IsWindowOwnedByProcess(_handle, (uint)_process.Id);
            }
            catch { return false; }
        }
    }

    public bool IsAttachedToDesktop => _reattachHealthy
        && IsAlive
        && _process != null
        && NativeDesktop.IsAttached(_handle, _screen.Bounds, (uint)_process.Id, _useLayeredPresentation);

    public void Prepare()
    {
        if (_prepared) return;
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!File.Exists(_mediaPath)) throw new FileNotFoundException("视频文件不存在。", _mediaPath);

        var mpv = Path.Combine(AppContext.BaseDirectory, "tools", "mpv.exe");
        if (!File.Exists(mpv)) throw new FileNotFoundException("播放器组件 mpv.exe 不存在。请重新启动软件并按提示安装视频组件。", mpv);

        var start = new ProcessStartInfo
        {
            FileName = mpv,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = false,
            WorkingDirectory = AppContext.BaseDirectory,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        AddArguments(start);

        try
        {
            _process = new Process { StartInfo = start, EnableRaisingEvents = true };
            _process.Exited += ProcessExited;
            if (!_process.Start()) throw new InvalidOperationException("Windows 未能启动 mpv 视频播放器。");
            try { ChildProcessJob.Assign(_process); }
            catch
            {
                try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { }
                throw;
            }
            try { _process.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
            _ = Task.Run(ReadStandardErrorAsync);

            DiagnosticsLog.Write("mpv 原生壁纸播放器已启动",
                detail: $"Pid={_process.Id}; Display={_screen.DeviceName}; Bounds={_screen.Bounds}; Mode={_aspectMode}; File={_mediaPath}");

            _ipc = MpvIpcClient.ConnectAsync(_pipeName, TimeSpan.FromSeconds(10))
                .GetAwaiter().GetResult();
            _ipc.MessageReceived += IpcMessageReceived;
            _ipc.Disconnected += IpcDisconnected;

            _handle = WaitForPlayerWindow(TimeSpan.FromSeconds(10));
            if (_handle == IntPtr.Zero)
                throw new TimeoutException("10 秒内没有找到 mpv 原生视频窗口。" + ErrorTail());

            // Hide the idle top-level window before changing its native hierarchy.
            // Attach adds WS_EX_LAYERED and alpha=0 before SetParent; after that we
            // show it logically (still alpha=0) so the VO can resize and present.
            _ = NativeDesktop.SetPresentationVisible(_handle, false);
            if (!NativeDesktop.Attach(_handle, _screen.Bounds, _useLayeredPresentation, (uint)_process.Id))
                throw new InvalidOperationException($"无法把 mpv 附着到桌面层：{_screen.DeviceName}" + ErrorTail());
            EnsureTransparentWindowIsShown();
            WaitForNativeGeometry(TimeSpan.FromSeconds(4), requireMpvDimensions: false);

            ObserveRenderProperties();
            ApplyAspectModeOverIpc();
            _fileLoaded.Reset();
            _playbackRestart.Reset();
            _loadFailed.Reset();
            var loadResult = IpcCommand(["loadfile", _mediaPath, "replace"]);
            if (loadResult.ValueKind != JsonValueKind.Object
                || !loadResult.TryGetProperty("playlist_entry_id", out var entryNode)
                || !entryNode.TryGetInt64(out var entryId))
                throw new InvalidOperationException("mpv loadfile 没有返回 playlist_entry_id。" + ErrorTail());
            SelectActivePlaylistEntry(entryId);

            WaitForMpvSignal(_fileLoaded, "完成文件加载", TimeSpan.FromSeconds(15));
            // File-local options can be reset when a new entry starts. Re-apply the
            // requested Fit/Fill mode after file-loaded through the supported IPC.
            ApplyAspectModeOverIpc();
            WaitForMpvSignal(_playbackRestart, "提交首个视频帧", TimeSpan.FromSeconds(15));

            // A VO reconfiguration must not be allowed to restore top-level styles
            // or a source-sized window. Reassert the desktop parent and 4K bounds
            // while alpha remains zero, then wait for mpv's swapchain to follow it.
            if (!NativeDesktop.Attach(_handle, _screen.Bounds, _useLayeredPresentation, (uint)_process.Id))
                throw new InvalidOperationException("视频加载后无法重新确认桌面窗口层级。" + ErrorTail());
            EnsureTransparentWindowIsShown();
            WaitForNativeGeometry(TimeSpan.FromSeconds(10), requireMpvDimensions: true);

            _prepared = true;
            DiagnosticsLog.Write("mpv 首帧与渲染尺寸校验通过",
                detail: $"Pid={_process.Id}; Hwnd=0x{_handle.ToInt64():X}; Display={_screen.DeviceName}; "
                    + $"Client={_screen.Bounds.Width}x{_screen.Bounds.Height}; "
                    + $"Osd={Volatile.Read(ref _observedOsdWidth)}x{Volatile.Read(ref _observedOsdHeight)}");
        }
        catch
        {
            StopPlayback();
            throw;
        }
    }

    public bool Reveal()
    {
        if (!_prepared || !IsAttachedToDesktop) return false;
        try { WaitForNativeGeometry(TimeSpan.FromSeconds(2), requireMpvDimensions: true); }
        catch (Exception ex)
        {
            DiagnosticsLog.Write("mpv 显示前渲染尺寸复核失败", ex);
            return false;
        }
        // Preparation decodes one frame while paused so sequential multi-monitor
        // staging cannot drift by several seconds. The reveal pass runs for all
        // monitors back-to-back, making their playback starts effectively atomic.
        if (_startupPaused)
        {
            try
            {
                if (!_paused) IpcSetProperty("pause", false);
                _startupPaused = false;
            }
            catch (Exception ex)
            {
                DiagnosticsLog.Write("mpv 显示前恢复首帧播放失败", ex);
                return false;
            }
        }
        if (!NativeDesktop.SetPresentationVisible(_handle, true)) return false;
        if (!IsAttachedToDesktop || !HasExpectedClientSize())
        {
            _ = NativeDesktop.SetPresentationVisible(_handle, false);
            return false;
        }
        _visible = true;
        _armed = true;
        DiagnosticsLog.Write("mpv 动态壁纸已显示",
            detail: $"Pid={_process?.Id}; Hwnd=0x{_handle.ToInt64():X}; Display={_screen.DeviceName}");
        return true;
    }

    public void HidePresentation()
    {
        _visible = false;
        // Hidden staging/rollback windows must never be reported as a healthy
        // running presentation to the periodic desktop repair loop.
        _reattachHealthy = false;
        try { if (_handle != IntPtr.Zero) _ = NativeDesktop.SetPresentationVisible(_handle, false); } catch { }
    }

    public bool AttachToDesktop()
    {
        if (!IsAlive || _process == null || _ipc == null) return false;
        var wasVisible = _visible;
        // Once a repair attempt starts, IsAttachedToDesktop must stay false until
        // parent/Z-order, renderer geometry and the previous presentation state
        // have all been restored. Otherwise the next repair tick could mistake a
        // correctly parented but permanently alpha-zero window for a healthy one.
        _reattachHealthy = false;
        _ = NativeDesktop.SetPresentationVisible(_handle, false);
        var attached = NativeDesktop.Attach(_handle, _screen.Bounds, _useLayeredPresentation, (uint)_process.Id);
        if (attached)
        {
            try
            {
                EnsureTransparentWindowIsShown();
                WaitForNativeGeometry(TimeSpan.FromSeconds(3), requireMpvDimensions: true);
            }
            catch (Exception ex)
            {
                DiagnosticsLog.Write("mpv 重新附着后的渲染尺寸校验失败", ex);
                attached = false;
            }
        }
        if (attached && wasVisible) attached = NativeDesktop.SetPresentationVisible(_handle, true);
        if (attached)
        {
            _visible = wasVisible;
            _reattachHealthy = true;
        }
        else _visible = false;
        return attached;
    }

    public void PausePlayback()
    {
        if (_paused || !IsAlive || _ipc == null) return;
        try
        {
            IpcSetProperty("pause", true);
            _paused = true;
        }
        catch (Exception ex) { DiagnosticsLog.Write("通过 mpv IPC 暂停播放失败", ex); }
    }

    public void ResumePlayback()
    {
        if (!_paused || !IsAlive || _ipc == null) return;
        try
        {
            IpcSetProperty("pause", false);
            _paused = false;
        }
        catch (Exception ex) { DiagnosticsLog.Write("通过 mpv IPC 恢复播放失败", ex); }
    }

    public void StopPlayback()
    {
        if (_stopping) return;
        _stopping = true;
        _armed = false;
        _visible = false;
        _stderrCancellation.Cancel();
        try { if (_handle != IntPtr.Zero) _ = NativeDesktop.SetPresentationVisible(_handle, false); } catch { }
        try
        {
            if (_ipc != null)
                _ipc.SendCommandAsync(["quit"]).Wait(400);
        }
        catch { }
        try
        {
            if (_process is { HasExited: false })
            {
                if (!_process.WaitForExit(1500))
                {
                    try { if (_handle != IntPtr.Zero) _ = NativeDesktop.RequestWindowClose(_handle); } catch { }
                    if (!_process.WaitForExit(500)) _process.Kill(entireProcessTree: true);
                }
                _process.WaitForExit(1200);
            }
        }
        catch { }
        try
        {
            if (_ipc != null)
            {
                _ipc.MessageReceived -= IpcMessageReceived;
                _ipc.Disconnected -= IpcDisconnected;
                _ipc.Dispose();
            }
        }
        catch { }
        _ipc = null;
        _handle = IntPtr.Zero;
    }

    public void Close() => StopPlayback();

    private void AddArguments(ProcessStartInfo start)
    {
        string[] arguments =
        [
            "--no-config",
            "--idle=yes",
            "--force-window=immediate",
            "--keep-open=yes",
            "--loop-file=inf",
            "--pause=yes",
            "--audio=no",
            "--sub=no",
            "--aid=no",
            "--sid=no",
            "--autoload-files=no",
            "--load-scripts=no",
            "--osc=no",
            "--osd-level=0",
            "--input-default-bindings=no",
            "--input-terminal=no",
            "--input-cursor=no",
            "--input-media-keys=no",
            "--input-vo-keyboard=no",
            "--media-controls=no",
            "--cursor-autohide=always",
            "--drag-and-drop=no",
            "--border=no",
            "--show-in-taskbar=no",
            "--taskbar-progress=no",
            "--window-dragging=no",
            "--window-corners=donotround",
            "--geometry=-9999:0",
            "--auto-window-resize=no",
            "--force-window-position=no",
            "--keepaspect=yes",
            "--keepaspect-window=no",
            "--video-unscaled=no",
            $"--panscan={(_aspectMode == AspectMode.Fill ? "1.0" : "0.0")}",
            "--hidpi-window-scale=no",
            "--vo=gpu-next",
            "--gpu-api=d3d11",
            "--d3d11-output-mode=window",
            // Flip-discard presentation is unreliable after a native D3D HWND is
            // converted to a WS_EX_LAYERED Explorer child. Bitblt presentation is
            // the documented D3D11 path compatible with background transparency.
            "--d3d11-flip=no",
            "--video-latency-hacks=no",
            "--hwdec=auto-safe",
            "--background=color",
            "--background-color=#000000",
            "--stop-screensaver=no",
            $"--title={_windowTitle}",
            $"--input-ipc-server=\\\\.\\pipe\\{_pipeName}"
        ];
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
    }

    private void ObserveRenderProperties()
    {
        if (_ipc == null) throw new InvalidOperationException("mpv IPC 尚未连接。");
        _ipc.ObservePropertyAsync(1, "vo-configured", IpcCommandTimeout).GetAwaiter().GetResult();
        _ipc.ObservePropertyAsync(2, "osd-dimensions", IpcCommandTimeout).GetAwaiter().GetResult();
    }

    private void ApplyAspectModeOverIpc()
    {
        IpcSetProperty("keepaspect", true);
        IpcSetProperty("keepaspect-window", false);
        IpcSetProperty("video-unscaled", false);
        IpcSetProperty("panscan", _aspectMode == AspectMode.Fill ? 1.0 : 0.0);
        IpcSetProperty("video-zoom", 0.0);
        IpcSetProperty("video-pan-x", 0.0);
        IpcSetProperty("video-pan-y", 0.0);
    }

    private JsonElement IpcCommand(object?[] command)
    {
        if (_ipc == null) throw new InvalidOperationException("mpv IPC 尚未连接。");
        return _ipc.CommandAsync(command, IpcCommandTimeout).GetAwaiter().GetResult();
    }

    private void IpcSetProperty(string name, object? value)
    {
        if (_ipc == null) throw new InvalidOperationException("mpv IPC 尚未连接。");
        _ipc.SetPropertyAsync(name, value, IpcCommandTimeout).GetAwaiter().GetResult();
    }

    private IntPtr WaitForPlayerWindow(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            ThrowIfPlayerUnavailable();
            var hwnd = GetMpvWindowFromIpc();
            if (IsExpectedMpvWindow(hwnd)) return hwnd;

            // Very early mpv builds can expose window-id a few messages after the
            // Win32 HWND exists. PID enumeration remains a safe fallback, but only
            // after verifying both ownership and our unique title.
            hwnd = NativeDesktop.FindUniqueTopLevelWindowForProcess((uint)_process!.Id);
            if (IsExpectedMpvWindow(hwnd)) return hwnd;
            Thread.Sleep(30);
        }
        return IntPtr.Zero;
    }

    private IntPtr GetMpvWindowFromIpc()
    {
        try
        {
            var value = _ipc!.GetPropertyAsync("window-id", TimeSpan.FromMilliseconds(350))
                .GetAwaiter().GetResult();
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var numeric))
                return new IntPtr(numeric);
            if (value.ValueKind == JsonValueKind.String
                && long.TryParse(value.GetString(), out numeric))
                return new IntPtr(numeric);
        }
        catch { }
        return IntPtr.Zero;
    }

    private bool IsExpectedMpvWindow(IntPtr hwnd)
        => hwnd != IntPtr.Zero
            && _process != null
            && NativeDesktop.IsValidWindow(hwnd)
            && NativeDesktop.IsWindowOwnedByProcess(hwnd, (uint)_process.Id)
            && NativeDesktop.WindowTitleEquals(hwnd, _windowTitle);

    private void WaitForMpvSignal(ManualResetEventSlim signal, string phase, TimeSpan timeout)
    {
        var result = WaitHandle.WaitAny(
            [signal.WaitHandle, _processExited.WaitHandle, _loadFailed.WaitHandle, _ipcDisconnected.WaitHandle],
            timeout);
        switch (result)
        {
            case 0: return;
            case 1: throw PlayerExitedDuringPreparation();
            case 2: throw new InvalidOperationException(
                $"mpv 无法{phase}：{_loadFailureDetail ?? "媒体加载失败"}。" + ErrorTail());
            case 3: throw new InvalidOperationException($"mpv IPC 在{phase}前中断。", _ipcFailure);
            default: throw new TimeoutException($"mpv 在 {timeout.TotalSeconds:0} 秒内没有{phase}。" + ErrorTail());
        }
    }

    private void WaitForNativeGeometry(TimeSpan timeout, bool requireMpvDimensions)
    {
        var deadline = DateTime.UtcNow + timeout;
        var lastDetail = "尚未收到尺寸";
        while (DateTime.UtcNow < deadline)
        {
            ThrowIfPlayerUnavailable();
            if (!IsAttachedToDesktop)
            {
                lastDetail = "桌面父窗口、Z-order 或外框尺寸不匹配";
                Thread.Sleep(40);
                continue;
            }
            if (!TryGetClientSize(_handle, out var clientWidth, out var clientHeight)
                || !ApproximatelyEquals(clientWidth, _screen.Bounds.Width)
                || !ApproximatelyEquals(clientHeight, _screen.Bounds.Height))
            {
                lastDetail = $"Client={clientWidth}x{clientHeight}, Expected={_screen.Bounds.Width}x{_screen.Bounds.Height}";
                Thread.Sleep(40);
                continue;
            }
            if (!IsWindowVisible(_handle))
            {
                lastDetail = "mpv HWND 仍是隐藏状态，VO 无法可靠提交帧";
                Thread.Sleep(40);
                continue;
            }
            if (!requireMpvDimensions) return;

            try
            {
                var vo = _ipc!.GetPropertyAsync("vo-configured", TimeSpan.FromMilliseconds(700))
                    .GetAwaiter().GetResult();
                if (vo.ValueKind != JsonValueKind.True)
                {
                    lastDetail = $"vo-configured={vo}";
                    Thread.Sleep(40);
                    continue;
                }
                var dimensions = _ipc.GetPropertyAsync("osd-dimensions", TimeSpan.FromMilliseconds(700))
                    .GetAwaiter().GetResult();
                if (!TryReadOsdDimensions(dimensions, out var osdWidth, out var osdHeight)
                    || !ApproximatelyEquals(osdWidth, _screen.Bounds.Width)
                    || !ApproximatelyEquals(osdHeight, _screen.Bounds.Height))
                {
                    lastDetail = $"osd-dimensions={osdWidth}x{osdHeight}, Expected={_screen.Bounds.Width}x{_screen.Bounds.Height}";
                    Thread.Sleep(40);
                    continue;
                }
                Volatile.Write(ref _observedVoConfigured, 1);
                Volatile.Write(ref _observedOsdWidth, osdWidth);
                Volatile.Write(ref _observedOsdHeight, osdHeight);
                return;
            }
            catch (Exception ex)
            {
                lastDetail = ex.Message;
                Thread.Sleep(40);
            }
        }
        throw new TimeoutException(
            $"mpv 渲染目标尺寸校验超时：{lastDetail}。Hwnd=0x{_handle.ToInt64():X}; "
            + $"Display={_screen.DeviceName}; Bounds={_screen.Bounds}" + ErrorTail());
    }

    private void EnsureTransparentWindowIsShown()
    {
        if (!NativeDesktop.SetPresentationVisible(_handle, false))
            throw new InvalidOperationException("无法保持 mpv 分层窗口透明。" + ErrorTail());
        if (!IsWindowVisible(_handle)) _ = ShowWindow(_handle, SwShowNoActivate);
        if (!IsWindowVisible(_handle))
            throw new InvalidOperationException("无法让透明的 mpv 窗口进入可渲染状态。" + ErrorTail());
        // ShowWindow cannot change per-window alpha; reaffirm zero after the window
        // becomes logically visible so no black frame can flash on the desktop.
        if (!NativeDesktop.SetPresentationVisible(_handle, false))
            throw new InvalidOperationException("无法确认 mpv 透明呈现状态。" + ErrorTail());
    }

    private bool HasExpectedClientSize()
        => TryGetClientSize(_handle, out var width, out var height)
            && ApproximatelyEquals(width, _screen.Bounds.Width)
            && ApproximatelyEquals(height, _screen.Bounds.Height);

    private static bool TryGetClientSize(IntPtr hwnd, out int width, out int height)
    {
        width = 0;
        height = 0;
        if (hwnd == IntPtr.Zero || !GetClientRect(hwnd, out var rect)) return false;
        width = rect.Right - rect.Left;
        height = rect.Bottom - rect.Top;
        return width > 0 && height > 0;
    }

    private static bool TryReadOsdDimensions(JsonElement value, out int width, out int height)
    {
        width = 0;
        height = 0;
        if (value.ValueKind != JsonValueKind.Object
            || !value.TryGetProperty("w", out var widthNode)
            || !value.TryGetProperty("h", out var heightNode)
            || !widthNode.TryGetDouble(out var widthValue)
            || !heightNode.TryGetDouble(out var heightValue)
            || !double.IsFinite(widthValue)
            || !double.IsFinite(heightValue))
            return false;
        width = (int)Math.Round(widthValue);
        height = (int)Math.Round(heightValue);
        return width > 0 && height > 0;
    }

    private static bool ApproximatelyEquals(int actual, int expected) => Math.Abs(actual - expected) <= 2;

    private void IpcMessageReceived(JsonElement message)
    {
        if (!message.TryGetProperty("event", out var eventNode)) return;
        var eventName = eventNode.GetString();
        switch (eventName)
        {
            case "start-file":
                if (message.TryGetProperty("playlist_entry_id", out var startEntryNode)
                    && startEntryNode.TryGetInt64(out var startEntryId))
                {
                    lock (_eventGate) _eventPlaylistEntryId = startEntryId;
                }
                break;
            case "file-loaded":
                lock (_eventGate)
                {
                    if (_eventPlaylistEntryId >= 0)
                    {
                        _loadedEntries.Add(_eventPlaylistEntryId);
                        if (_eventPlaylistEntryId == _activePlaylistEntryId) _fileLoaded.Set();
                    }
                }
                break;
            case "playback-restart":
                lock (_eventGate)
                {
                    if (_eventPlaylistEntryId >= 0)
                    {
                        _restartedEntries.Add(_eventPlaylistEntryId);
                        if (_eventPlaylistEntryId == _activePlaylistEntryId) _playbackRestart.Set();
                    }
                }
                break;
            case "property-change":
                ProcessPropertyChange(message);
                break;
            case "end-file":
                if (message.TryGetProperty("playlist_entry_id", out var endEntryNode)
                    && endEntryNode.TryGetInt64(out var endEntryId))
                {
                    var reason = message.TryGetProperty("reason", out var reasonNode)
                        ? reasonNode.GetString() ?? "unknown"
                        : "unknown";
                    var fileError = message.TryGetProperty("file_error", out var fileErrorNode)
                        ? fileErrorNode.GetString()
                        : null;
                    var detail = fileError == null ? $"end-file reason={reason}" : $"{reason}: {fileError}";
                    var isActive = false;
                    lock (_eventGate)
                    {
                        _endedEntries[endEntryId] = detail;
                        isActive = endEntryId == _activePlaylistEntryId;
                        if (isActive)
                        {
                            _loadFailureDetail = detail;
                            _loadFailed.Set();
                        }
                        if (_eventPlaylistEntryId == endEntryId) _eventPlaylistEntryId = -1;
                    }
                    if (isActive && _armed && !_stopping)
                        ReportPlaybackFailure(new InvalidOperationException(
                            $"mpv 当前壁纸媒体已结束：{detail}。" + ErrorTail()));
                }
                break;
        }
    }

    private void SelectActivePlaylistEntry(long entryId)
    {
        lock (_eventGate)
        {
            _activePlaylistEntryId = entryId;
            if (_loadedEntries.Contains(entryId)) _fileLoaded.Set();
            if (_restartedEntries.Contains(entryId)) _playbackRestart.Set();
            if (_endedEntries.TryGetValue(entryId, out var failure))
            {
                _loadFailureDetail = failure;
                _loadFailed.Set();
            }
        }
    }

    private void ProcessPropertyChange(JsonElement message)
    {
        if (!message.TryGetProperty("name", out var nameNode)
            || !message.TryGetProperty("data", out var data)) return;
        switch (nameNode.GetString())
        {
            case "vo-configured":
                Volatile.Write(ref _observedVoConfigured, data.ValueKind == JsonValueKind.True ? 1 : 0);
                break;
            case "osd-dimensions":
                if (TryReadOsdDimensions(data, out var width, out var height))
                {
                    Volatile.Write(ref _observedOsdWidth, width);
                    Volatile.Write(ref _observedOsdHeight, height);
                }
                break;
        }
    }

    private void IpcDisconnected(Exception exception)
    {
        _ipcFailure = exception;
        try { _ipcDisconnected.Set(); } catch (ObjectDisposedException) { return; }
        if (_armed && !_stopping)
            ReportPlaybackFailure(new InvalidOperationException("mpv IPC 意外中断，动态壁纸无法继续受控。", exception));
    }

    private async Task ReadStandardErrorAsync()
    {
        if (_process == null) return;
        try
        {
            while (!_stderrCancellation.IsCancellationRequested)
            {
                var line = await _process.StandardError.ReadLineAsync(_stderrCancellation.Token);
                if (line == null) break;
                line = line.Trim();
                if (line.Length == 0) continue;
                lock (_tailGate)
                {
                    _stderrTail.Enqueue(line);
                    while (_stderrTail.Count > 12) _stderrTail.Dequeue();
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!_stopping) DiagnosticsLog.Write("读取 mpv 错误信息失败", ex);
        }
    }

    private void ThrowIfPlayerUnavailable()
    {
        if (_process == null || _process.HasExited) throw PlayerExitedDuringPreparation();
        if (_ipcDisconnected.IsSet)
            throw new InvalidOperationException("mpv IPC 已中断。", _ipcFailure);
        if (_loadFailed.IsSet)
            throw new InvalidOperationException($"mpv 媒体加载失败：{_loadFailureDetail ?? "未知错误"}。" + ErrorTail());
    }

    private string ErrorTail()
    {
        lock (_tailGate)
            return _stderrTail.Count == 0 ? "" : "\n\n播放器信息：\n" + string.Join("\n", _stderrTail);
    }

    private void ProcessExited(object? sender, EventArgs e)
    {
        try { _processExited.Set(); }
        catch (ObjectDisposedException) { return; }
        if (!_armed || _stopping) return;
        var code = 0;
        try { code = _process?.ExitCode ?? 0; } catch { }
        ReportPlaybackFailure(
            new InvalidOperationException($"mpv 壁纸播放器意外退出（ExitCode={code}）。" + ErrorTail()));
    }

    private void ReportPlaybackFailure(Exception exception)
    {
        if (Interlocked.Exchange(ref _failureReported, 1) != 0) return;
        PlaybackFailed?.Invoke(this, exception);
    }

    private Exception PlayerExitedDuringPreparation()
    {
        var code = 0;
        try { code = _process?.ExitCode ?? 0; } catch { }
        return new InvalidOperationException($"mpv 在准备阶段提前退出（ExitCode={code}）。" + ErrorTail());
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        StopPlayback();
        if (_process != null) _process.Exited -= ProcessExited;
        _fileLoaded.Dispose();
        _playbackRestart.Dispose();
        _loadFailed.Dispose();
        _ipcDisconnected.Dispose();
        _processExited.Dispose();
        _stderrCancellation.Dispose();
        _process?.Dispose();
    }

    private const int SwShowNoActivate = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct RectNative
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(IntPtr hwnd, out RectNative rect);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool ShowWindow(IntPtr hwnd, int command);
}
