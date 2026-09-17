using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace DynamicWallpaperStudio;

public sealed record WebPlaybackSnapshot(
    bool Ready,
    bool Live,
    bool Paused,
    bool CanPlay,
    bool CanSeek,
    bool CanRate,
    bool Muted,
    double Position,
    double Duration);

public sealed class WebSession : IDisposable
{
    private static readonly WebPlaybackSnapshot Empty = new(false, false, true, false, false, false, true, 0, 0);
    private readonly WebView2 _view = new() { DefaultBackgroundColor = System.Drawing.Color.Black };
    private readonly Dispatcher _dispatcher;
    private CoreWebView2Environment? _environment;
    private string? _profilePath;
    private bool _ready;
    private bool _disposed;
    private bool _hooked;
    private WebPlaybackSnapshot _snapshot = Empty;

    public WebSession()
    {
        _dispatcher = System.Windows.Application.Current?.Dispatcher ?? Dispatcher.CurrentDispatcher;
        _view.HorizontalAlignment = HorizontalAlignment.Stretch;
        _view.VerticalAlignment = VerticalAlignment.Stretch;
    }

    public WebView2 View => _view;
    public bool IsReady => _ready && _view.CoreWebView2 != null;
    public bool PinnedToDesktop { get; set; }
    public WebPlaybackSnapshot LastSnapshot => _snapshot;
    public bool IsPaused => _snapshot.Paused;

    public string CurrentUrl
    {
        get
        {
            try
            {
                if (_view.CoreWebView2 != null && !string.IsNullOrWhiteSpace(_view.CoreWebView2.Source))
                    return _view.CoreWebView2.Source;
                return _view.Source?.ToString() ?? "";
            }
            catch { return ""; }
        }
    }

    public bool HasHttpDocument
        => Uri.TryCreate(CurrentUrl, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);

    public event Action? LocationChanged;

    public async Task EnsureAsync(string profilePath)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_ready && _view.CoreWebView2 != null) return;
        if (!_dispatcher.CheckAccess())
        {
            await _dispatcher.InvokeAsync(() => EnsureAsync(profilePath)).Task.Unwrap();
            return;
        }

        Directory.CreateDirectory(profilePath);
        _profilePath = profilePath;
        _environment ??= await CoreWebView2Environment.CreateAsync(userDataFolder: profilePath);
        await _view.EnsureCoreWebView2Async(_environment);
        var core = _view.CoreWebView2 ?? throw new InvalidOperationException("WebView2 未能初始化。");
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        if (!_hooked)
        {
            core.NavigationCompleted += (_, _) =>
            {
                _ = InstallAndApplyAsync();
                LocationChanged?.Invoke();
            };
            core.SourceChanged += (_, _) => LocationChanged?.Invoke();
            _hooked = true;
        }
        _ready = true;
    }

    public async Task NavigateAsync(string url)
    {
        await EnsureReadyCoreAsync();
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
            throw new InvalidOperationException("请输入以 http:// 或 https:// 开头的完整网页地址。");
        await _dispatcher.InvokeAsync(() => _view.CoreWebView2!.Navigate(uri.ToString()));
    }

    public void PlaceIn(Panel host, bool hitTest)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        Detach();
        host.Children.Add(_view);
        _view.IsHitTestVisible = hitTest;
        ApplyHostSettings(hitTest);
    }

    public void Detach()
    {
        switch (_view.Parent)
        {
            case Panel panel:
                panel.Children.Remove(_view);
                break;
            case Decorator decorator:
                decorator.Child = null;
                break;
            case ContentControl content:
                content.Content = null;
                break;
        }
    }

    public void ApplyHostSettings(bool interactive)
    {
        if (_view.CoreWebView2 == null) return;
        _view.CoreWebView2.Settings.AreDefaultContextMenusEnabled = interactive;
        _view.IsHitTestVisible = interactive;
    }

    public Task SetMutedAsync(bool muted) => CommandAsync("mute", new { muted });
    public Task SetVolumeAsync(double volume) => CommandAsync("volume", new { volume = Math.Clamp(volume, 0, 100) / 100.0 });
    public Task SetPausedAsync(bool paused) => CommandAsync("pause", new { paused });
    public Task SetSpeedAsync(double speed) => CommandAsync("rate", new { rate = speed });
    public Task SeekAsync(double seconds) => CommandAsync("seek", new { seconds });

    public async Task ApplyTransportAsync(bool muted, double volume, double speed)
    {
        await CommandAsync("transport", new
        {
            muted,
            volume = Math.Clamp(volume, 0, 100) / 100.0,
            rate = speed
        });
        await RefreshStateAsync();
    }

    public async Task RefreshStateAsync()
    {
        if (!IsReady) { _snapshot = Empty; return; }
        try
        {
            var json = await ExecuteAsync(QueryScript);
            _snapshot = ParseSnapshot(json, CurrentUrl);
        }
        catch
        {
            _snapshot = Empty with { Ready = IsReady, Live = LooksLive(CurrentUrl) };
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        PinnedToDesktop = false;
        try { Detach(); } catch { }
        try { _view.Dispose(); } catch { }
        _ready = false;
    }

    private Task EnsureReadyCoreAsync()
    {
        if (_ready && _view.CoreWebView2 != null) return Task.CompletedTask;
        if (string.IsNullOrWhiteSpace(_profilePath))
            throw new InvalidOperationException("网页会话尚未初始化。");
        return EnsureAsync(_profilePath);
    }

    private async Task InstallAndApplyAsync()
    {
        try { await ExecuteAsync(InstallScript); }
        catch (Exception ex) { DiagnosticsLog.Write("网页媒体控制脚本未装上", ex); }
    }

    private async Task CommandAsync(string op, object payload)
    {
        if (!IsReady) return;
        var map = new Dictionary<string, object?> { ["op"] = op };
        foreach (var property in payload.GetType().GetProperties())
        {
            var value = property.GetValue(payload);
            if (value != null) map[property.Name] = value;
        }
        await ExecuteAsync(InstallScript + "window.__dwpsCommand(" + JsonSerializer.Serialize(map) + ");");
        await RefreshStateAsync();
    }

    private async Task<string> ExecuteAsync(string script)
    {
        if (_view.CoreWebView2 == null) return "null";
        if (!_dispatcher.CheckAccess())
            return await _dispatcher.InvokeAsync(() => ExecuteAsync(script)).Task.Unwrap();
        var result = await _view.CoreWebView2.ExecuteScriptAsync(script);
        return result;
    }

    private static WebPlaybackSnapshot ParseSnapshot(string json, string url)
    {
        var liveHint = LooksLive(url);
        if (string.IsNullOrWhiteSpace(json) || json == "null")
            return Empty with { Ready = true, Live = liveHint };
        try
        {
            using var doc = JsonDocument.Parse(json.StartsWith('\"') ? JsonSerializer.Deserialize<string>(json) ?? json : json);
            var root = doc.RootElement;
            if (root.ValueKind == JsonValueKind.String)
            {
                using var inner = JsonDocument.Parse(root.GetString() ?? "{}");
                root = inner.RootElement.Clone();
            }
            var live = ReadBool(root, "live") || liveHint;
            var has = ReadBool(root, "has");
            return new WebPlaybackSnapshot(
                Ready: true,
                Live: live,
                Paused: ReadBool(root, "paused"),
                CanPlay: has && !live,
                CanSeek: has && !live && ReadBool(root, "canSeek"),
                CanRate: has && !live,
                Muted: ReadBool(root, "muted"),
                Position: ReadDouble(root, "position"),
                Duration: ReadDouble(root, "duration"));
        }
        catch
        {
            return Empty with { Ready = true, Live = liveHint };
        }
    }

    public static bool LooksLive(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return false;
        var host = uri.Host.ToLowerInvariant();
        var path = uri.AbsolutePath.ToLowerInvariant();
        if (host.Contains("live.bilibili") || host.Contains("live.douyin") || host.Contains("live.kuaishou"))
            return true;
        if (host.Contains("huya.com") || host.Contains("douyu.com") || host.Contains("twitch.tv")
            || host.Contains("cc.163.com") || host.Contains("live.qq.com"))
            return true;
        if (path.Contains("/live") || path.Contains("/room/")) return true;
        return false;
    }

    private static bool ReadBool(JsonElement root, string name)
        => root.TryGetProperty(name, out var node) && node.ValueKind is JsonValueKind.True;

    private static double ReadDouble(JsonElement root, string name)
        => root.TryGetProperty(name, out var node) && node.TryGetDouble(out var value) && double.IsFinite(value) ? value : 0;

    private const string InstallScript =
        """
        (() => {
          if (window.__dwpsReady) return;
          window.__dwpsState = Object.assign({ muted: true, volume: 0, rate: 1, paused: null }, window.__dwpsState || {});
          function collect(root, list) {
            if (!root) return;
            try {
              root.querySelectorAll('video,audio').forEach(m => list.push(m));
              root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) collect(el.shadowRoot, list); });
              root.querySelectorAll('iframe').forEach(f => { try { collect(f.contentDocument, list); } catch (e) {} });
            } catch (e) {}
          }
          function media() {
            const list = [];
            collect(document, list);
            return list.filter((m, i, a) => a.indexOf(m) === i);
          }
          function apply() {
            const s = window.__dwpsState;
            media().forEach(m => {
              try { m.muted = !!s.muted; } catch (e) {}
              try { m.volume = Math.max(0, Math.min(1, s.volume)); } catch (e) {}
              const live = !isFinite(m.duration) || m.duration === Infinity;
              if (!live && s.rate) { try { m.playbackRate = s.rate; } catch (e) {} }
              if (s.paused === true) { try { m.pause(); } catch (e) {} }
              if (s.paused === false) { try { m.play().catch(() => {}); } catch (e) {} }
            });
          }
          window.__dwpsCommand = function (cmd) {
            const s = window.__dwpsState;
            if (cmd.op === 'mute' || cmd.op === 'transport') s.muted = !!cmd.muted;
            if (cmd.op === 'volume' || cmd.op === 'transport') s.volume = Number(cmd.volume);
            if (cmd.op === 'rate' || cmd.op === 'transport') s.rate = Number(cmd.rate);
            if (cmd.op === 'pause') s.paused = !!cmd.paused;
            if (cmd.op === 'seek') media().forEach(m => { try { if (isFinite(m.duration)) m.currentTime = Number(cmd.seconds); } catch (e) {} });
            apply();
            return window.__dwpsQuery();
          };
          window.__dwpsQuery = function () {
            const list = media();
            const m = list.find(x => x.readyState > 0) || list[0];
            if (!m) return { has: false, live: false, paused: true, canSeek: false, muted: !!window.__dwpsState.muted, position: 0, duration: 0 };
            const live = !isFinite(m.duration) || m.duration === Infinity || (m.seekable && m.seekable.length === 0 && m.duration > 0);
            return {
              has: true,
              live: !!live,
              paused: !!m.paused,
              canSeek: !live && isFinite(m.duration) && m.duration > 0,
              muted: !!m.muted,
              position: isFinite(m.currentTime) ? m.currentTime : 0,
              duration: isFinite(m.duration) ? m.duration : 0
            };
          };
          new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
          apply();
          window.__dwpsReady = true;
        })();
        """;

    private const string QueryScript = InstallScript + "window.__dwpsQuery();";
}
